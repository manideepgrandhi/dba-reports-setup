#!/usr/bin/env bash
# Create the dbareports service user and /opt/dba-reports layout on the jump box.
# Idempotent. --dry-run prints commands and makes no changes.
# Usage: sudo ./setup_jumpbox.sh [--dry-run]
#        ./setup_jumpbox.sh --dry-run   (no root needed)
set -euo pipefail

USER_NAME="dbareports"
BASE="/opt/dba-reports"
DIRS=(tools conf bin output data logs)
DRY_RUN=0

die() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<'U'
Usage: setup_jumpbox.sh [--dry-run]

Creates user dbareports (nologin, no sudo) and /opt/dba-reports/{tools,conf,bin,output,data,logs}.
Checks for: aws (CLI v2), jq, flock, unzip, mailx.
Idempotent. Use --dry-run to print commands without changing anything.
U
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if (( DRY_RUN )); then return 0; fi
  "$@"
}

need_root=1
(( DRY_RUN )) && need_root=0
if (( need_root )) && [[ "$(id -u)" -ne 0 ]]; then
  die "Run as root (or pass --dry-run). Example: sudo $0"
fi

echo "=== User: $USER_NAME ==="
if id "$USER_NAME" >/dev/null 2>&1; then
  echo "User $USER_NAME already exists"
else
  if command -v useradd >/dev/null 2>&1; then
    run useradd --system --shell /usr/sbin/nologin --home-dir "$BASE" --create-home "$USER_NAME" \
      || run useradd -r -s /usr/sbin/nologin -d "$BASE" -m "$USER_NAME"
  elif (( DRY_RUN )); then
    echo "+ useradd --system --shell /usr/sbin/nologin --home-dir $BASE --create-home $USER_NAME"
  else
    die "useradd not found"
  fi
fi

# Ensure no sudo for this user (remove from sudo/wheel if present; best-effort)
if (( ! DRY_RUN )); then
  if command -v gpasswd >/dev/null 2>&1; then
    gpasswd -d "$USER_NAME" sudo 2>/dev/null || true
    gpasswd -d "$USER_NAME" wheel 2>/dev/null || true
  fi
else
  echo "+ (would ensure $USER_NAME is not in sudo/wheel)"
fi

echo "=== Directories under $BASE ==="
run mkdir -p "$BASE"
for d in "${DIRS[@]}"; do
  run mkdir -p "$BASE/$d"
done
run chown -R "$USER_NAME:$USER_NAME" "$BASE"
run chmod 750 "$BASE"
for d in "${DIRS[@]}"; do
  run chmod 750 "$BASE/$d"
done
# conf files will be 640 when installed; seed a .keep so perms are clear
if (( DRY_RUN )); then
  echo "+ (would touch $BASE/conf/.keep and chmod 640)"
else
  touch "$BASE/conf/.keep"
  chown "$USER_NAME:$USER_NAME" "$BASE/conf/.keep"
  chmod 640 "$BASE/conf/.keep"
fi

echo "=== Tool checks ==="
missing=0
check() {
  local name="$1" hint="$2"
  if command -v "$name" >/dev/null 2>&1; then
    echo "OK  $name: $(command -v "$name")"
  else
    echo "MISSING  $name ($hint)"
    missing=1
  fi
}
check jq "install jq"
check flock "util-linux"
check unzip "unzip"
check mailx "mailutils or s-nail (provides mailx)"

if command -v aws >/dev/null 2>&1; then
  ver="$(aws --version 2>&1 || true)"
  echo "OK  aws: $ver"
  if [[ "$ver" != aws-cli/2* ]]; then
    echo "WARN  AWS CLI v2 required (found: $ver)"
    missing=1
  fi
else
  echo "MISSING  aws (install AWS CLI v2)"
  missing=1
fi

echo "=== Layout ==="
echo "Base: $BASE"
for d in "${DIRS[@]}"; do
  echo "  $BASE/$d"
done

if (( missing )); then
  echo "WARN: some tools are missing; install them before scheduling reports"
  (( DRY_RUN )) && exit 0
  exit 2
fi
echo "Done."
(( DRY_RUN )) && echo "DRY-RUN complete; no changes made"
