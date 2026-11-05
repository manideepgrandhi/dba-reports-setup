#!/usr/bin/env bash
# Check recent run_reports.sh logs and mail only when something is wrong
# (unless check_mail_on_ok=yes). Usage: check_logs.sh [--config FILE] [--dry-run]
set -euo pipefail

CONFIG=""
DRY_RUN=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<'U'
Usage: check_logs.sh [--config FILE] [--dry-run]

Flags: missing run log for today, status file saying failed / missing,
ERROR|AccessDenied|ExpiredToken in the log, or missing output files listed
in the log. Mails via mailx only on problems (optional OK mail).
U
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) [[ $# -ge 2 ]] || die "--config needs a value"; CONFIG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

BASE_DIR="${DBA_REPORTS_BASE:-/opt/dba-reports}"
LOGS_DIR=""
OUTPUT_DIR=""
ALERT_EMAILS=""
ALERT_FROM=""
MAIL_SUBJECT_PREFIX="[dba-reports]"
CHECK_SCHEDULES="daily,weekly"
CHECK_LOOKBACK_HOURS=26
CHECK_MAIL_ON_OK="no"
CHECK_ERROR_PATTERNS="ERROR|AccessDenied|ExpiredToken"

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
unquote() {
  local s="$1"
  if [[ "$s" =~ ^\".*\"$ ]]; then s="${s:1:${#s}-2}"
  elif [[ "$s" =~ ^\'.*\'$ ]]; then s="${s:1:${#s}-2}"; fi
  printf '%s' "$s"
}
is_true() { case "${1,,}" in 1|y|yes|true|on) return 0 ;; *) return 1 ;; esac; }

load_conf() {
  local f="$1" line key val
  [[ -f "$f" ]] || die "Config not found: $f"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" == *"="* ]] || continue
    key="$(trim "${line%%=*}")"
    val="$(unquote "$(trim "${line#*=}")")"
    case "$key" in
      base_dir) BASE_DIR="$val" ;;
      logs_dir) LOGS_DIR="$val" ;;
      output_dir) OUTPUT_DIR="$val" ;;
      alert_emails) ALERT_EMAILS="$val" ;;
      alert_from) ALERT_FROM="$val" ;;
      mail_subject_prefix) MAIL_SUBJECT_PREFIX="$val" ;;
      check_schedules) CHECK_SCHEDULES="$val" ;;
      check_lookback_hours) CHECK_LOOKBACK_HOURS="$val" ;;
      check_mail_on_ok) CHECK_MAIL_ON_OK="$val" ;;
      check_error_patterns) CHECK_ERROR_PATTERNS="$val" ;;
    esac
  done <"$f"
}

if [[ -z "$CONFIG" ]]; then
  if [[ -f "$SCRIPT_DIR/../conf/run_reports.conf" ]]; then
    CONFIG="$(cd "$SCRIPT_DIR/../conf" && pwd)/run_reports.conf"
  elif [[ -f "${DBA_REPORTS_BASE:-/opt/dba-reports}/conf/run_reports.conf" ]]; then
    CONFIG="${DBA_REPORTS_BASE:-/opt/dba-reports}/conf/run_reports.conf"
  fi
fi
[[ -n "$CONFIG" ]] && load_conf "$CONFIG"

LOGS_DIR="${LOGS_DIR:-$BASE_DIR/logs}"
OUTPUT_DIR="${OUTPUT_DIR:-$BASE_DIR/output}"

LOOKBACK_MIN=$(( CHECK_LOOKBACK_HOURS * 60 ))

declare -a PROBLEMS=()
declare -a NOTES=()

IFS=',' read -r -a SCHEDULES <<<"$CHECK_SCHEDULES"
for raw in "${SCHEDULES[@]}"; do
  sched="$(trim "$raw")"
  [[ -n "$sched" ]] || continue

  # Newest run log for this schedule within lookback
  mapfile -t logs < <(find "$LOGS_DIR" -maxdepth 1 -type f -name "run_${sched}_*.log" -mmin "-${LOOKBACK_MIN}" 2>/dev/null | sort)
  if (( ${#logs[@]} == 0 )); then
    PROBLEMS+=("missing run log for schedule '$sched' in last ${CHECK_LOOKBACK_HOURS}h under $LOGS_DIR")
    continue
  fi
  latest="${logs[-1]}"
  NOTES+=("latest $sched log: $latest")
  status="${latest%.log}.status"
  if [[ ! -f "$status" ]]; then
    PROBLEMS+=("missing status file: $status")
  else
    st="$(trim "$(cat "$status")")"
    if [[ "$st" != "ok" ]]; then
      PROBLEMS+=("status not ok ($st): $status")
    fi
  fi

  # Pattern scan
  if grep -E -q "$CHECK_ERROR_PATTERNS" "$latest" 2>/dev/null; then
    # Show up to 5 matching lines
    matches="$(grep -E -n "$CHECK_ERROR_PATTERNS" "$latest" 2>/dev/null | head -5 || true)"
    PROBLEMS+=("error patterns in $latest:"$'\n'"$matches")
  fi

  # Output files mentioned in the log must still exist
  while IFS= read -r line; do
    path="$(trim "${line#*Output:}")"
    path="$(trim "$path")"
    [[ -n "$path" ]] || continue
    if [[ ! -f "$path" ]]; then
      PROBLEMS+=("missing output file listed in log: $path")
    fi
  done < <(grep -E '^.*Output: ' "$latest" 2>/dev/null || true)
done

BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
{
  echo "Host: $(hostname 2>/dev/null || echo unknown)"
  echo "When: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "Logs dir: $LOGS_DIR"
  echo
  if (( ${#NOTES[@]} )); then
    echo "Notes:"
    for n in "${NOTES[@]}"; do echo "  $n"; done
    echo
  fi
  if (( ${#PROBLEMS[@]} )); then
    echo "Problems:"
    for p in "${PROBLEMS[@]}"; do echo "  - $p"; done
  else
    echo "All checks OK."
  fi
} >"$BODY"

send() {
  local subject="$1"
  [[ -n "$ALERT_EMAILS" ]] || { echo "Mail skipped (alert_emails not set)"; return 0; }
  command -v mailx >/dev/null 2>&1 || { echo "ERROR: mailx not found" >&2; return 1; }
  local -a recipients=() recs=()
  IFS=',' read -r -a recipients <<<"$ALERT_EMAILS"
  local r
  for r in "${recipients[@]}"; do
    r="$(trim "$r")"
    [[ -n "$r" ]] && recs+=("$r")
  done
  (( ${#recs[@]} )) || return 0
  local -a mail_cmd=(mailx -s "$subject")
  [[ -n "$ALERT_FROM" ]] && mail_cmd+=(-r "$ALERT_FROM")
  mail_cmd+=("${recs[@]}")
  echo "Mail: $subject -> ${recs[*]}"
  if (( DRY_RUN )); then
    echo "DRY-RUN: mail not sent; body:"
    cat "$BODY"
    return 0
  fi
  "${mail_cmd[@]}" <"$BODY"
}

if (( ${#PROBLEMS[@]} )); then
  cat "$BODY"
  send "${MAIL_SUBJECT_PREFIX} LOG-CHECK FAILED" || true
  exit 5
fi

echo "All checks OK."
for n in "${NOTES[@]}"; do echo "  $n"; done
if is_true "$CHECK_MAIL_ON_OK"; then
  send "${MAIL_SUBJECT_PREFIX} LOG-CHECK OK" || true
fi
exit 0
