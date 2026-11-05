#!/usr/bin/env bash
# Create or update dbops_compliance_role in one account (run with an admin profile).
# Usage: ./create_role.sh --profile P --jumpbox-role-arn ARN [--dry-run]
# Never stores credentials. Does not talk to AWS when --dry-run is set.
set -euo pipefail

ROLE_NAME="dbops_compliance_role"
POLICY_NAME="dbops_compliance_role_policy"
MAX_SESSION=3600
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_FILE="$SCRIPT_DIR/dbops_compliance_role-policy.json"
TRUST_FILE="$SCRIPT_DIR/dbops_compliance_role-trust.json"

PROFILE=""
JUMPBOX_ARN=""
DRY_RUN=0

die() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<'U'
Usage: create_role.sh --profile PROFILE --jumpbox-role-arn ARN [--dry-run]

Creates or updates the IAM role dbops_compliance_role in the account of PROFILE.
Trust: only JUMPBOX_ROLE_ARN may assume it. Inline policy: read-only RDS/Backup/etc.
Max session duration: 3600 seconds. Idempotent.
U
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) [[ $# -ge 2 ]] || die "--profile needs a value"; PROFILE="$2"; shift 2 ;;
    --jumpbox-role-arn) [[ $# -ge 2 ]] || die "--jumpbox-role-arn needs a value"; JUMPBOX_ARN="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -n "$PROFILE" ]] || die "Missing --profile"
[[ -n "$JUMPBOX_ARN" ]] || die "Missing --jumpbox-role-arn"
[[ -f "$POLICY_FILE" ]] || die "Missing policy file: $POLICY_FILE"
[[ -f "$TRUST_FILE" ]] || die "Missing trust file: $TRUST_FILE"

# IAM role ARN: arn:aws:iam::ACCOUNT:role/NAME  (path optional: role/path/NAME)
[[ "$JUMPBOX_ARN" =~ ^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_-]+(/[A-Za-z0-9+=,.@_/-]+)?$ ]] \
  || die "Invalid jump box role ARN (expected arn:aws:iam::ACCOUNT:role/NAME): $JUMPBOX_ARN"

TRUST_TMP="$(mktemp)"
POLICY_TMP="$(mktemp)"
trap 'rm -f "$TRUST_TMP" "$POLICY_TMP"' EXIT

jq --arg arn "$JUMPBOX_ARN" '
  .Statement[0].Principal.AWS = $arn
' "$TRUST_FILE" >"$TRUST_TMP" || die "Failed to build trust policy with jq"
cp "$POLICY_FILE" "$POLICY_TMP"
jq empty "$TRUST_TMP" || die "Trust JSON invalid after substitution"
jq empty "$POLICY_TMP" || die "Policy JSON invalid"

run() {
  if (( DRY_RUN )); then
    printf 'DRY-RUN:'; printf ' %q' "$@"; printf '\n'
    return 0
  fi
  "$@"
}

echo "Profile : $PROFILE"
echo "Role    : $ROLE_NAME"
echo "Trust   : $JUMPBOX_ARN"
echo "Policy  : $POLICY_FILE"
echo "Max sess: ${MAX_SESSION}s"

EXISTS=0
if (( DRY_RUN )); then
  echo "DRY-RUN: would check whether role exists (aws iam get-role)"
else
  if aws --profile "$PROFILE" iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    EXISTS=1
  fi
fi

if (( EXISTS )); then
  echo "Role exists; updating trust and inline policy"
  run aws --profile "$PROFILE" iam update-assume-role-policy \
    --role-name "$ROLE_NAME" --policy-document "file://$TRUST_TMP"
  run aws --profile "$PROFILE" iam update-role \
    --role-name "$ROLE_NAME" --max-session-duration "$MAX_SESSION"
else
  echo "Creating role"
  run aws --profile "$PROFILE" iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST_TMP" \
    --max-session-duration "$MAX_SESSION" \
    --description "Read-only role for DBA compliance reports (RDS, Backup, account alias)"
fi

run aws --profile "$PROFILE" iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "file://$POLICY_TMP"

if (( DRY_RUN )); then
  echo "Role ARN (expected): arn:aws:iam::ACCOUNT:role/${ROLE_NAME}"
  echo "DRY-RUN complete; no AWS calls made"
  exit 0
fi

ARN="$(aws --profile "$PROFILE" iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"
echo "Role ARN: $ARN"
