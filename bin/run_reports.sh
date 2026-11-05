#!/usr/bin/env bash
# Run scheduled DBA compliance reports under /opt/dba-reports.
# Usage: run_reports.sh daily|weekly [--config FILE] [--dry-run]
# Config is key=value (parsed, never sourced). All settings default from comments
# in conf/run_reports.conf.example; nothing is emailed until alert_emails is set.
set -euo pipefail

SCHEDULE=""
CONFIG=""
DRY_RUN=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<'U'
Usage: run_reports.sh daily|weekly [--config FILE] [--dry-run]

Reads conf/run_reports.conf (or --config). Runs each enabled report for the
schedule with flock, writes a per-run log, optionally mails a summary via mailx,
and optionally deletes old files under output/ and logs/ only.
Exit: 0 all reports ok, 1 usage, 2 pre-check, 5 one or more reports failed.
U
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    daily|weekly) SCHEDULE="$1"; shift ;;
    --config) [[ $# -ge 2 ]] || die "--config needs a value"; CONFIG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ -n "$SCHEDULE" ]] || { usage; exit 1; }

# --- defaults ---
BASE_DIR="${DBA_REPORTS_BASE:-/opt/dba-reports}"
TOOLS_DIR=""
OUTPUT_DIR=""
DATA_DIR=""
LOGS_DIR=""
CONF_DIR=""
PROFILES=""
DAILY_REPORTS="rds-patch-compliance,rds-backup-compliance"
WEEKLY_REPORTS="rds-inventory-explorer"
FORMATS="html,csv"
ALL_REGIONS="yes"
TZ_NAME="Asia/Kolkata"
SAVE_DATA="no"
PATCH_SUMMARY="yes"
RETENTION_DAYS=0
RETENTION_LOGS_DAYS=0
ALERT_EMAILS=""
ALERT_FROM=""
MAIL_ATTACH="no"
MAIL_LOG_LINES=40
MAIL_SUBJECT_PREFIX="[dba-reports]"

declare -A TOOL_FOR=()
declare -A SCRIPT_FOR=()
declare -A ARGS_FOR=()
TOOL_FOR[rds-patch-compliance]="rds-patch-compliance"
TOOL_FOR[rds-backup-compliance]="rds-backup-compliance"
TOOL_FOR[rds-inventory-explorer]="rds-inventory-explorer"
SCRIPT_FOR[rds-patch-compliance]="rds_patch_compliance_report.sh"
SCRIPT_FOR[rds-backup-compliance]="rds_backup_compliance_report.sh"
SCRIPT_FOR[rds-inventory-explorer]="rds_inventory_explorer.sh"
SCRIPT_FOR[rds-patch-compliance-summary]="rds_patch_compliance_summary.sh"

is_true() { case "${1,,}" in 1|y|yes|true|on) return 0 ;; *) return 1 ;; esac; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Strip optional matching quotes
unquote() {
  local s="$1"
  if [[ "$s" =~ ^\".*\"$ ]]; then s="${s:1:${#s}-2}"
  elif [[ "$s" =~ ^\'.*\'$ ]]; then s="${s:1:${#s}-2}"; fi
  printf '%s' "$s"
}

load_conf() {
  local f="$1" line key val
  [[ -f "$f" ]] || die "Config not found: $f"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" == *"="* ]] || die "Bad config line in $f: $line"
    key="$(trim "${line%%=*}")"
    val="$(trim "${line#*=}")"
    val="$(unquote "$val")"
    case "$key" in
      base_dir) BASE_DIR="$val" ;;
      tools_dir) TOOLS_DIR="$val" ;;
      output_dir) OUTPUT_DIR="$val" ;;
      data_dir) DATA_DIR="$val" ;;
      logs_dir) LOGS_DIR="$val" ;;
      conf_dir) CONF_DIR="$val" ;;
      profiles) PROFILES="$val" ;;
      daily) DAILY_REPORTS="$val" ;;
      weekly) WEEKLY_REPORTS="$val" ;;
      formats) FORMATS="$val" ;;
      all_regions) ALL_REGIONS="$val" ;;
      tz) TZ_NAME="$val" ;;
      save_data) SAVE_DATA="$val" ;;
      patch_summary) PATCH_SUMMARY="$val" ;;
      retention_days) RETENTION_DAYS="$val" ;;
      retention_logs_days) RETENTION_LOGS_DAYS="$val" ;;
      alert_emails) ALERT_EMAILS="$val" ;;
      alert_from) ALERT_FROM="$val" ;;
      mail_attach) MAIL_ATTACH="$val" ;;
      mail_log_lines) MAIL_LOG_LINES="$val" ;;
      mail_subject_prefix) MAIL_SUBJECT_PREFIX="$val" ;;
      tool.*) TOOL_FOR["${key#tool.}"]="$val" ;;
      script.*) SCRIPT_FOR["${key#script.}"]="$val" ;;
      args.*) ARGS_FOR["${key#args.}"]="$val" ;;
      check_schedules|check_lookback_hours|check_mail_on_ok|check_error_patterns) ;; # check_logs only
      *) die "Unknown config key: $key" ;;
    esac
  done <"$f"
}

# Resolve config path
if [[ -z "$CONFIG" ]]; then
  if [[ -f "$SCRIPT_DIR/../conf/run_reports.conf" ]]; then
    CONFIG="$(cd "$SCRIPT_DIR/../conf" && pwd)/run_reports.conf"
  elif [[ -f "${DBA_REPORTS_BASE:-/opt/dba-reports}/conf/run_reports.conf" ]]; then
    CONFIG="${DBA_REPORTS_BASE:-/opt/dba-reports}/conf/run_reports.conf"
  else
    # Allow running with built-in defaults only (tests / first dry-run)
    CONFIG=""
  fi
fi
[[ -n "$CONFIG" ]] && load_conf "$CONFIG"

TOOLS_DIR="${TOOLS_DIR:-$BASE_DIR/tools}"
OUTPUT_DIR="${OUTPUT_DIR:-$BASE_DIR/output}"
DATA_DIR="${DATA_DIR:-$BASE_DIR/data}"
LOGS_DIR="${LOGS_DIR:-$BASE_DIR/logs}"
CONF_DIR="${CONF_DIR:-$BASE_DIR/conf}"

case "$SCHEDULE" in
  daily) REPORTS_CSV="$DAILY_REPORTS" ;;
  weekly) REPORTS_CSV="$WEEKLY_REPORTS" ;;
esac

IFS=',' read -r -a REPORTS <<<"$REPORTS_CSV"
# trim each
_tmp=()
for r in "${REPORTS[@]}"; do
  r="$(trim "$r")"
  [[ -n "$r" ]] && _tmp+=("$r")
done
REPORTS=("${_tmp[@]}")
(( ${#REPORTS[@]} )) || die "No reports configured for schedule '$SCHEDULE'"

mkdir -p "$LOGS_DIR" "$OUTPUT_DIR" "$DATA_DIR"
STAMP="$(date '+%Y%m%d_%H%M%S')"
DAY="$(date '+%Y')"
MONTH="$(date '+%m')"
RUN_LOG="$LOGS_DIR/run_${SCHEDULE}_${STAMP}.log"
STATUS_FILE="$LOGS_DIR/run_${SCHEDULE}_${STAMP}.status"
LOCK_FILE="${DBA_REPORTS_LOCK:-/tmp/dba-reports.lock}"

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  printf '%s\n' "$line" | tee -a "$RUN_LOG" >&2
}

# Acquire lock (non-blocking). Skip if DBA_REPORTS_NO_LOCK=1 (tests).
if [[ "${DBA_REPORTS_NO_LOCK:-0}" != 1 ]]; then
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    die "Another run_reports.sh holds $LOCK_FILE"
  fi
fi

log "START schedule=$SCHEDULE config=${CONFIG:-<defaults>} base=$BASE_DIR"
log "Run log: $RUN_LOG"

if [[ -z "$PROFILES" ]]; then
  log "ERROR: profiles is not set in config (uncomment profiles = ...)"
  echo "failed" >"$STATUS_FILE"
  exit 2
fi

FAILED=0
declare -a OUTPUT_PATHS=()
declare -a REPORT_RESULTS=()

run_one() {
  local report="$1"
  local tool script_rel current script out_sub
  tool="${TOOL_FOR[$report]:-$report}"
  script_rel="${SCRIPT_FOR[$report]:-}"
  [[ -n "$script_rel" ]] || { log "ERROR: no script mapping for $report"; return 1; }
  current="$TOOLS_DIR/$tool/current"
  script="$current/$script_rel"
  if [[ ! -x "$script" && ! -f "$script" ]]; then
    log "ERROR: script not found: $script"
    return 1
  fi
  out_sub="$OUTPUT_DIR/$report/$DAY/$MONTH"
  mkdir -p "$out_sub"
  local -a cmd=("$script" -P "$PROFILES")
  if is_true "$ALL_REGIONS"; then
    cmd+=(-A)
  fi
  cmd+=(-F "$FORMATS" -o "$out_sub" --tz "$TZ_NAME")
  # -l/--log-file: patch + backup support it; inventory does not
  case "$report" in
    rds-patch-compliance|rds-backup-compliance) cmd+=(-l "$RUN_LOG") ;;
  esac
  if is_true "$SAVE_DATA"; then
    cmd+=(--save-data)
  fi
  # inventory uses -c for config; others --config. We do not pass a per-tool conf by default.
  if [[ -n "${ARGS_FOR[$report]:-}" ]]; then
    local -a extra=()
    # Read space-separated tokens; do not eval
    read -r -a extra <<<"${ARGS_FOR[$report]}"
    cmd+=("${extra[@]}")
  fi

  log "RUN $report: ${cmd[*]}"
  log "Output dir: $out_sub"
  if (( DRY_RUN )); then
    log "DRY-RUN: skipped execution"
    REPORT_RESULTS+=("$report:DRY-RUN")
    return 0
  fi

  local rc=0
  # Capture new files created under out_sub
  local before after
  before="$(mktemp)"
  after="$(mktemp)"
  find "$out_sub" -type f -print 2>/dev/null | sort >"$before" || true
  set +e
  "${cmd[@]}" >>"$RUN_LOG" 2>&1
  rc=$?
  set -e
  find "$out_sub" -type f -print 2>/dev/null | sort >"$after" || true
  local newf
  while IFS= read -r newf; do
    [[ -n "$newf" ]] || continue
    OUTPUT_PATHS+=("$newf")
    log "Output: $newf"
  done < <(comm -13 "$before" "$after")
  rm -f "$before" "$after"

  # Exit 5 = non-compliant with --fail-on-noncompliant; treat as failure for the wrapper
  if [[ $rc -ne 0 ]]; then
    log "FAIL $report exit=$rc"
    REPORT_RESULTS+=("$report:FAIL:$rc")
    return 1
  fi
  log "OK $report"
  REPORT_RESULTS+=("$report:OK")
  return 0
}

for report in "${REPORTS[@]}"; do
  if ! run_one "$report"; then
    FAILED=1
  fi
  # Optional patch summary after full patch report
  if [[ "$report" == "rds-patch-compliance" ]] && is_true "$PATCH_SUMMARY"; then
    # run summary with same options into same month folder
    tool="${TOOL_FOR[rds-patch-compliance]}"
    current="$TOOLS_DIR/$tool/current"
    sum_script="$current/${SCRIPT_FOR[rds-patch-compliance-summary]}"
    if [[ -f "$sum_script" ]]; then
      out_sub="$OUTPUT_DIR/rds-patch-compliance/$DAY/$MONTH"
      mkdir -p "$out_sub"
      scmd=("$sum_script" -P "$PROFILES")
      if is_true "$ALL_REGIONS"; then scmd+=(-A); fi
      scmd+=(-F "$FORMATS" -o "$out_sub" --tz "$TZ_NAME")
      log "RUN rds-patch-compliance-summary: ${scmd[*]}"
      if (( ! DRY_RUN )); then
        before="$(mktemp)"; after="$(mktemp)"
        find "$out_sub" -type f -print 2>/dev/null | sort >"$before" || true
        set +e
        "${scmd[@]}" >>"$RUN_LOG" 2>&1
        src=$?
        set -e
        find "$out_sub" -type f -print 2>/dev/null | sort >"$after" || true
        while IFS= read -r newf; do
          [[ -n "$newf" ]] || continue
          OUTPUT_PATHS+=("$newf")
          log "Output: $newf"
        done < <(comm -13 "$before" "$after")
        rm -f "$before" "$after"
        if [[ $src -ne 0 ]]; then
          log "FAIL rds-patch-compliance-summary exit=$src"
          REPORT_RESULTS+=("rds-patch-compliance-summary:FAIL:$src")
          FAILED=1
        else
          log "OK rds-patch-compliance-summary"
          REPORT_RESULTS+=("rds-patch-compliance-summary:OK")
        fi
      fi
    else
      log "WARN patch summary script missing: $sum_script"
    fi
  fi
done

# --- retention (off unless days > 0) ---
retain() {
  local dir="$1" days="$2" label="$3"
  [[ "$days" =~ ^[0-9]+$ ]] || { log "ERROR: bad retention days: $days"; return 1; }
  (( days > 0 )) || return 0
  # Only delete files under dir, never the dir itself; mindepth 1
  log "Retention: deleting files under $dir older than $days days ($label)"
  if (( DRY_RUN )); then
    find "$dir" -mindepth 1 -type f -mtime "+$days" -print || true
    return 0
  fi
  find "$dir" -mindepth 1 -type f -mtime "+$days" -print -delete || true
}
retain "$OUTPUT_DIR" "$RETENTION_DAYS" "output"
retain "$LOGS_DIR" "$RETENTION_LOGS_DAYS" "logs"

# --- mail ---
send_mail() {
  local subject="$1" body_file="$2"
  [[ -n "$ALERT_EMAILS" ]] || { log "Mail skipped (alert_emails not set)"; return 0; }
  command -v mailx >/dev/null 2>&1 || { log "ERROR: mailx not found"; return 1; }
  local -a recipients=()
  IFS=',' read -r -a recipients <<<"$ALERT_EMAILS"
  local -a recs=()
  local r
  for r in "${recipients[@]}"; do
    r="$(trim "$r")"
    [[ -n "$r" ]] && recs+=("$r")
  done
  (( ${#recs[@]} )) || return 0

  local -a mail_cmd=(mailx -s "$subject")
  if [[ -n "$ALERT_FROM" ]]; then
    mail_cmd+=(-r "$ALERT_FROM")
  fi
  if is_true "$MAIL_ATTACH"; then
    local p
    for p in "${OUTPUT_PATHS[@]}"; do
      [[ -f "$p" ]] || continue
      # Prefer -A (attachment); fall back to -a
      mail_cmd+=(-A "$p")
    done
  fi
  mail_cmd+=("${recs[@]}")
  log "Mail: subject=$subject to=${recs[*]}"
  if (( DRY_RUN )); then
    log "DRY-RUN: mail not sent"
    return 0
  fi
  # Body via stdin — never interpolate into a shell string
  "${mail_cmd[@]}" <"$body_file" || log "WARN: mailx returned non-zero"
}

BODY="$(mktemp)"
{
  echo "Schedule : $SCHEDULE"
  echo "Host     : $(hostname 2>/dev/null || echo unknown)"
  echo "When     : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Run log  : $RUN_LOG"
  echo
  echo "Results:"
  for rr in "${REPORT_RESULTS[@]}"; do
    echo "  $rr"
  done
  echo
  echo "Output files:"
  if (( ${#OUTPUT_PATHS[@]} )); then
    for p in "${OUTPUT_PATHS[@]}"; do
      echo "  $p"
    done
  else
    echo "  (none)"
  fi
  echo
  echo "---- last ${MAIL_LOG_LINES} log lines ----"
  tail -n "$MAIL_LOG_LINES" "$RUN_LOG" 2>/dev/null || true
} >"$BODY"

if (( FAILED )); then
  OVERALL="FAILED"
  echo "failed" >"$STATUS_FILE"
else
  OVERALL="OK"
  echo "ok" >"$STATUS_FILE"
fi
SUBJECT="${MAIL_SUBJECT_PREFIX} ${OVERALL} ${SCHEDULE} (${REPORTS_CSV})"
send_mail "$SUBJECT" "$BODY" || true
rm -f "$BODY"

log "DONE overall=$OVERALL"
# Always print paths for the operator
echo "Run log: $RUN_LOG"
echo "Status file: $STATUS_FILE"
for p in "${OUTPUT_PATHS[@]}"; do
  echo "Output: $p"
done

if (( FAILED )); then
  exit 5
fi
exit 0
