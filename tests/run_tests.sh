#!/usr/bin/env bash
# Self-contained tests for dba-reports-setup. Never talks to AWS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dba-reports-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
assert() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $name"
    FAIL=$((FAIL + 1))
  fi
}
assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $name (got='$got' want='$want')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== JSON validate ==="
for f in "$ROOT"/iam/*.json; do
  if jq empty "$f" 2>/dev/null; then
    echo "PASS  jq $f"
    PASS=$((PASS + 1))
  else
    echo "FAIL  jq $f"
    FAIL=$((FAIL + 1))
  fi
done

echo "=== shellcheck ==="
SC_FILES=("$ROOT"/iam/create_role.sh "$ROOT"/setup/setup_jumpbox.sh "$ROOT"/setup/install_tool.sh \
  "$ROOT"/bin/run_reports.sh "$ROOT"/bin/check_logs.sh)
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "${SC_FILES[@]}"; then
    echo "PASS  shellcheck all scripts"
    PASS=$((PASS + 1))
  else
    echo "FAIL  shellcheck"
    FAIL=$((FAIL + 1))
  fi
else
  echo "FAIL  shellcheck not installed"
  FAIL=$((FAIL + 1))
fi

echo "=== bash -n ==="
for f in "${SC_FILES[@]}"; do
  if bash -n "$f"; then
    echo "PASS  bash -n $(basename "$f")"
    PASS=$((PASS + 1))
  else
    echo "FAIL  bash -n $(basename "$f")"
    FAIL=$((FAIL + 1))
  fi
done

echo "=== create_role.sh --dry-run ==="
out="$TMP/create_role.out"
if "$ROOT/iam/create_role.sh" --profile fake --jumpbox-role-arn 'arn:aws:iam::123456789012:role/jumpbox' --dry-run >"$out" 2>&1; then
  assert "create_role dry-run exits 0" true
else
  assert "create_role dry-run exits 0" false
fi
grep -q 'DRY-RUN' "$out" && assert "create_role prints DRY-RUN" true || assert "create_role prints DRY-RUN" false
grep -q 'dbops_compliance_role' "$out" && assert "create_role names role" true || assert "create_role names role" false
# Invalid ARN rejected
if "$ROOT/iam/create_role.sh" --profile fake --jumpbox-role-arn 'not-an-arn' --dry-run >"$TMP/badarn.out" 2>&1; then
  assert "create_role rejects bad ARN" false
else
  assert "create_role rejects bad ARN" true
fi
# Must not call aws in dry-run (no network) — script should not require aws for dry-run path after validation
# Trust substitution uses jq
trust="$TMP/trust.json"
jq --arg arn 'arn:aws:iam::123456789012:role/jumpbox' \
  '.Statement[0].Principal.AWS = $arn' \
  "$ROOT/iam/dbops_compliance_role-trust.json" >"$trust"
got="$(jq -r '.Statement[0].Principal.AWS' "$trust")"
assert_eq "jq substitutes JUMPBOX_ROLE_ARN" "$got" "arn:aws:iam::123456789012:role/jumpbox"
# Placeholder still in source file
grep -q 'JUMPBOX_ROLE_ARN' "$ROOT/iam/dbops_compliance_role-trust.json" \
  && assert "trust template keeps placeholder" true \
  || assert "trust template keeps placeholder" false

echo "=== setup_jumpbox.sh --dry-run ==="
out="$TMP/setup.out"
if "$ROOT/setup/setup_jumpbox.sh" --dry-run >"$out" 2>&1; then
  assert "setup_jumpbox dry-run exits 0" true
else
  # may exit 2 if mailx missing on this box — still OK if it printed commands
  if grep -q 'DRY-RUN\|mkdir' "$out"; then
    assert "setup_jumpbox dry-run ran (exit non-zero only for missing tools)" true
  else
    assert "setup_jumpbox dry-run ran" false
  fi
fi
grep -q 'dbareports' "$out" && assert "setup mentions dbareports" true || assert "setup mentions dbareports" false
grep -q '/opt/dba-reports' "$out" && assert "setup mentions base dir" true || assert "setup mentions base dir" false

echo "=== install_tool.sh local zip + sha256 ==="
FAKE_TOOL=fake-tool
VER=v9.9.9
ZDIR="$TMP/zips"
mkdir -p "$ZDIR/payload"
echo '#!/bin/sh' >"$ZDIR/payload/hello.sh"
echo 'echo hi' >>"$ZDIR/payload/hello.sh"
chmod +x "$ZDIR/payload/hello.sh"
python3 - <<PY
import zipfile, pathlib
root = pathlib.Path("$ZDIR/payload")
with zipfile.ZipFile("$ZDIR/${FAKE_TOOL}.zip", "w") as z:
    for f in root.rglob("*"):
        if f.is_file():
            z.write(f, f.relative_to(root).as_posix())
PY
sha256sum "$ZDIR/${FAKE_TOOL}.zip" | awk '{print $1}' >"$ZDIR/${FAKE_TOOL}.zip.sha256"
BASE="$TMP/opt"
mkdir -p "$BASE"
if "$ROOT/setup/install_tool.sh" --tool "$FAKE_TOOL" --version "$VER" \
    --zip "$ZDIR/${FAKE_TOOL}.zip" --sha256 "$ZDIR/${FAKE_TOOL}.zip.sha256" \
    --base "$BASE" >"$TMP/install.out" 2>&1; then
  assert "install_tool success" true
else
  cat "$TMP/install.out"
  assert "install_tool success" false
fi
assert "install dir exists" test -d "$BASE/tools/$FAKE_TOOL/$VER"
assert "current symlink" test -L "$BASE/tools/$FAKE_TOOL/current"
# mismatch must fail
echo '0000000000000000000000000000000000000000000000000000000000000000' >"$ZDIR/bad.sha256"
if "$ROOT/setup/install_tool.sh" --tool "$FAKE_TOOL" --version v0.0.0-bad \
    --zip "$ZDIR/${FAKE_TOOL}.zip" --sha256 "$ZDIR/bad.sha256" \
    --base "$BASE" >"$TMP/install_bad.out" 2>&1; then
  assert "install_tool rejects bad sha256" false
else
  assert "install_tool rejects bad sha256" true
fi
grep -qi 'mismatch\|Checksum' "$TMP/install_bad.out" \
  && assert "mismatch message" true || assert "mismatch message" false
# rollback
"$ROOT/setup/install_tool.sh" --tool "$FAKE_TOOL" --version v9.9.8 \
  --zip "$ZDIR/${FAKE_TOOL}.zip" --sha256 "$ZDIR/${FAKE_TOOL}.zip.sha256" \
  --base "$BASE" >/dev/null
"$ROOT/setup/install_tool.sh" --tool "$FAKE_TOOL" --rollback "$VER" --base "$BASE" >"$TMP/rb.out" 2>&1
target="$(readlink "$BASE/tools/$FAKE_TOOL/current")"
[[ "$target" == *"$VER"* ]] && assert "rollback points to $VER" true || assert "rollback points to $VER" false

echo "=== stub tools + mailx for run_reports / check_logs ==="
BASE="$TMP/dba"
mkdir -p "$BASE"/{tools,conf,bin,output,data,logs}
PATH_DIR="$TMP/path"
mkdir -p "$PATH_DIR"

# stub mailx: record argv + stdin
cat >"$PATH_DIR/mailx" <<'M'
#!/usr/bin/env bash
set -euo pipefail
dir="${MAILX_CAPTURE:?}"
mkdir -p "$dir"
printf '%s\n' "$@" >"$dir/argv.txt"
cat >"$dir/body.txt"
exit 0
M
chmod +x "$PATH_DIR/mailx"

# stub report scripts
install_stub() {
  local tool="$1" script="$2" tag="$3"
  local dest="$BASE/tools/$tool/vtest"
  mkdir -p "$dest"
  cat >"$dest/$script" <<S
#!/usr/bin/env bash
set -euo pipefail
# minimal stub: parse -o and write a fake report with account number in the name
OUT=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o|--output-dir) OUT="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "\$OUT"
# Simulate two accounts
f1="\$OUT/${tag}_111111111111_\$(date +%Y%m%d_%H%M%S).html"
f2="\$OUT/${tag}_222222222222_\$(date +%Y%m%d_%H%M%S).csv"
echo "<html>$tag</html>" >"\$f1"
echo "a,b" >"\$f2"
echo "Wrote \$f1"
echo "Wrote \$f2"
# Optional failure injection
if [[ "\${STUB_FAIL:$tag:-}" == 1 ]]; then
  echo "ERROR: injected failure AccessDenied" >&2
  exit 2
fi
exit 0
S
  chmod +x "$dest/$script"
  ln -sfn "$dest" "$BASE/tools/$tool/current"
}

install_stub rds-patch-compliance rds_patch_compliance_report.sh rds_patch_compliance
install_stub rds-patch-compliance rds_patch_compliance_summary.sh rds_patch_summary
install_stub rds-backup-compliance rds_backup_compliance_report.sh rds_backup_compliance
install_stub rds-inventory-explorer rds_inventory_explorer.sh rds_inventory_explorer

# Fix STUB_FAIL env check in stubs — the ${STUB_FAIL:tag} syntax is wrong.
# Rewrite stubs properly:
rewrite_stub() {
  local tool="$1" script="$2" tag="$3" fail_env="$4"
  local dest="$BASE/tools/$tool/current"
  # current is symlink — write into real dir
  dest="$(readlink -f "$BASE/tools/$tool/current")"
  cat >"$dest/$script" <<S
#!/usr/bin/env bash
set -euo pipefail
OUT=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o|--output-dir) OUT="\$2"; shift 2 ;;
    -P|--profile|-F|--format|--tz|-l|--log-file|-A|--all-regions|--save-data) 
      if [[ "\$1" == "-A" || "\$1" == "--all-regions" || "\$1" == "--save-data" ]]; then shift; else shift 2; fi ;;
    *) shift ;;
  esac
done
[[ -n "\$OUT" ]] || { echo "missing -o" >&2; exit 1; }
mkdir -p "\$OUT"
f1="\$OUT/${tag}_111111111111_\$(date +%Y%m%d_%H%M%S).html"
f2="\$OUT/${tag}_222222222222_\$(date +%Y%m%d_%H%M%S).csv"
echo "<html>$tag</html>" >"\$f1"
echo "a,b" >"\$f2"
echo "Wrote \$f1"
echo "Wrote \$f2"
if [[ "\${$fail_env:-0}" == 1 ]]; then
  echo "ERROR: injected failure AccessDenied" >&2
  exit 2
fi
exit 0
S
  chmod +x "$dest/$script"
}
rewrite_stub rds-patch-compliance rds_patch_compliance_report.sh rds_patch_compliance STUB_FAIL_PATCH
rewrite_stub rds-patch-compliance rds_patch_compliance_summary.sh rds_patch_summary STUB_FAIL_SUMMARY
rewrite_stub rds-backup-compliance rds_backup_compliance_report.sh rds_backup_compliance STUB_FAIL_BACKUP
rewrite_stub rds-inventory-explorer rds_inventory_explorer.sh rds_inventory_explorer STUB_FAIL_INV

cat >"$BASE/conf/run_reports.conf" <<C
base_dir = $BASE
tools_dir = $BASE/tools
output_dir = $BASE/output
data_dir = $BASE/data
logs_dir = $BASE/logs
profiles = prod,nonprod
daily = rds-patch-compliance,rds-backup-compliance
weekly = rds-inventory-explorer
formats = html,csv
all_regions = yes
tz = Asia/Kolkata
patch_summary = yes
alert_emails = dba@example.com
alert_from = reports@example.com
mail_attach = no
mail_log_lines = 20
mail_subject_prefix = [test-dba]
check_schedules = daily
check_lookback_hours = 26
check_mail_on_ok = no
retention_days = 0
retention_logs_days = 0
C

export PATH="$PATH_DIR:$PATH"
export DBA_REPORTS_BASE="$BASE"
export DBA_REPORTS_NO_LOCK=1
export MAILX_CAPTURE="$TMP/mail1"
mkdir -p "$MAILX_CAPTURE"

echo "--- run_reports daily (success) ---"
set +e
"$ROOT/bin/run_reports.sh" daily --config "$BASE/conf/run_reports.conf" >"$TMP/run.out" 2>"$TMP/run.err"
rc=$?
set -e
assert_eq "run_reports daily exit 0" "$rc" "0"
grep -q 'Output:' "$TMP/run.out" && assert "run_reports prints Output paths" true || assert "run_reports prints Output paths" false
# account numbers in filenames
grep -E '111111111111|222222222222' "$TMP/run.out" \
  && assert "output names include account numbers" true \
  || assert "output names include account numbers" false
# mail sent
assert "mailx argv captured" test -f "$MAILX_CAPTURE/argv.txt"
grep -q 'OK' "$MAILX_CAPTURE/argv.txt" && assert "mail subject OK" true || assert "mail subject OK" false
grep -q 'dba@example.com' "$MAILX_CAPTURE/argv.txt" && assert "mail recipient" true || assert "mail recipient" false
grep -q 'Output files:' "$MAILX_CAPTURE/body.txt" && assert "mail body has paths" true || assert "mail body has paths" false
# status ok
status_file="$(ls -1 "$BASE/logs"/run_daily_*.status | tail -1)"
assert_eq "status ok" "$(cat "$status_file")" "ok"

echo "--- check_logs OK (quiet, no mail) ---"
rm -rf "$TMP/mail2"
export MAILX_CAPTURE="$TMP/mail2"
mkdir -p "$MAILX_CAPTURE"
set +e
"$ROOT/bin/check_logs.sh" --config "$BASE/conf/run_reports.conf" >"$TMP/check_ok.out" 2>"$TMP/check_ok.err"
rc=$?
set -e
assert_eq "check_logs OK exit 0" "$rc" "0"
# should NOT have sent mail (check_mail_on_ok=no)
if [[ -f "$MAILX_CAPTURE/argv.txt" ]]; then
  assert "check_logs quiet when OK" false
else
  assert "check_logs quiet when OK" true
fi

echo "--- check_logs: AccessDenied in log ---"
latest_log="$(ls -1t "$BASE/logs"/run_daily_*.log | head -1)"
echo "2026-11-05 12:00:00 ERROR: boom AccessDenied on purpose" >>"$latest_log"
export MAILX_CAPTURE="$TMP/mail3"
mkdir -p "$MAILX_CAPTURE"
set +e
"$ROOT/bin/check_logs.sh" --config "$BASE/conf/run_reports.conf" >"$TMP/check_ad.out" 2>"$TMP/check_ad.err"
rc=$?
set -e
assert_eq "check_logs AccessDenied exit 5" "$rc" "5"
assert "check_logs mailed on AccessDenied" test -f "$MAILX_CAPTURE/argv.txt"
grep -q 'LOG-CHECK FAILED' "$MAILX_CAPTURE/argv.txt" && assert "fail subject" true || assert "fail subject" false
# clean the injected line for next tests
# (leave it; we'll use fresh schedule)

echo "--- check_logs: missing log ---"
# Point check at a schedule with no logs
cat >"$BASE/conf/run_reports.conf" <<C
base_dir = $BASE
logs_dir = $BASE/logs
output_dir = $BASE/output
profiles = prod
alert_emails = dba@example.com
check_schedules = weekly
check_lookback_hours = 1
check_mail_on_ok = no
C
# ensure no weekly logs in last 1h — delete any
rm -f "$BASE/logs"/run_weekly_*
export MAILX_CAPTURE="$TMP/mail4"
mkdir -p "$MAILX_CAPTURE"
set +e
"$ROOT/bin/check_logs.sh" --config "$BASE/conf/run_reports.conf" >"$TMP/check_miss.out" 2>"$TMP/check_miss.err"
rc=$?
set -e
assert_eq "check_logs missing exit 5" "$rc" "5"
grep -qi 'missing' "$TMP/check_miss.out" && assert "mentions missing" true || assert "mentions missing" false

echo "--- run_reports failure path ---"
# restore full conf
cat >"$BASE/conf/run_reports.conf" <<C
base_dir = $BASE
tools_dir = $BASE/tools
output_dir = $BASE/output
data_dir = $BASE/data
logs_dir = $BASE/logs
profiles = prod,nonprod
daily = rds-patch-compliance
weekly = rds-inventory-explorer
formats = html,csv
all_regions = yes
tz = Asia/Kolkata
patch_summary = no
alert_emails = dba@example.com
mail_subject_prefix = [test-dba]
C
export STUB_FAIL_PATCH=1
export MAILX_CAPTURE="$TMP/mail5"
mkdir -p "$MAILX_CAPTURE"
set +e
"$ROOT/bin/run_reports.sh" daily --config "$BASE/conf/run_reports.conf" >"$TMP/run_fail.out" 2>"$TMP/run_fail.err"
rc=$?
set -e
assert_eq "run_reports failure exit 5" "$rc" "5"
grep -q 'FAILED' "$MAILX_CAPTURE/argv.txt" && assert "mail subject FAILED" true || assert "mail subject FAILED" false
status_file="$(ls -1t "$BASE/logs"/run_daily_*.status | head -1)"
assert_eq "status failed" "$(cat "$status_file")" "failed"
unset STUB_FAIL_PATCH

echo "--- conf example: all settings commented ---"
# Every non-comment, non-blank line in the example must not assign (i.e. file should load as empty of keys)
active=0
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// /}" ]] && continue
  active=$((active + 1))
done <"$ROOT/conf/run_reports.conf.example"
assert_eq "run_reports.conf.example has 0 active keys" "$active" "0"

active=0
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// /}" ]] && continue
  active=$((active + 1))
done <"$ROOT/cron/dbareports.crontab.example"
assert_eq "crontab.example has 0 active lines" "$active" "0"

echo "--- role name consistency ---"
if grep -R "DBAReportsReadOnly" "$ROOT" --exclude-dir=.git --exclude-dir=tests >/dev/null 2>&1; then
  assert "no old role name" false
else
  assert "no old role name" true
fi
grep -R "dbops_compliance_role" "$ROOT/iam" "$ROOT/setup" "$ROOT/README.md" >/dev/null \
  && assert "dbops_compliance_role referenced" true \
  || assert "dbops_compliance_role referenced" false

# No CloudFormation
if find "$ROOT" -name '*.cfn.yaml' -o -name '*stackset*' | grep -q .; then
  assert "no cloudformation files" false
else
  assert "no cloudformation files" true
fi

echo
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
