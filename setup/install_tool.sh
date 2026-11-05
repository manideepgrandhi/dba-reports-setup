#!/usr/bin/env bash
# Download a DBA report tool release zip from GitHub, verify sha256, install under
# /opt/dba-reports/tools/<tool>/<version>, and atomically point current -> that version.
# Usage:
#   install_tool.sh --tool NAME --version V [--base DIR] [--repo OWNER/NAME] [--dry-run]
#   install_tool.sh --tool NAME --version V --zip FILE --sha256 FILE [--base DIR] [--dry-run]
#   install_tool.sh --tool NAME --rollback VERSION [--base DIR]
set -euo pipefail

BASE="${DBA_REPORTS_BASE:-/opt/dba-reports}"
TOOL=""
VERSION=""
REPO=""
ZIP=""
SHA_FILE=""
DRY_RUN=0
ROLLBACK=""

die() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<'U'
Usage:
  install_tool.sh --tool NAME --version VER [--repo owner/name] [--base DIR]
  install_tool.sh --tool NAME --version VER --zip FILE.zip --sha256 FILE.sha256 [--base DIR]
  install_tool.sh --tool NAME --rollback VER [--base DIR]

Downloads https://github.com/<repo>/releases/download/<ver>/<tool>.zip (+ .sha256),
verifies the checksum, unpacks to <base>/tools/<tool>/<ver>/, and moves
<base>/tools/<tool>/current -> that directory atomically.
Default repo: manideepgrandhi/<tool>. Prints full paths of the install dir and symlink.
U
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool) [[ $# -ge 2 ]] || die "--tool needs a value"; TOOL="$2"; shift 2 ;;
    --version) [[ $# -ge 2 ]] || die "--version needs a value"; VERSION="$2"; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || die "--repo needs a value"; REPO="$2"; shift 2 ;;
    --base) [[ $# -ge 2 ]] || die "--base needs a value"; BASE="$2"; shift 2 ;;
    --zip) [[ $# -ge 2 ]] || die "--zip needs a value"; ZIP="$2"; shift 2 ;;
    --sha256) [[ $# -ge 2 ]] || die "--sha256 needs a value"; SHA_FILE="$2"; shift 2 ;;
    --rollback) [[ $# -ge 2 ]] || die "--rollback needs a value"; ROLLBACK="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -n "$TOOL" ]] || die "Missing --tool"
[[ "$TOOL" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "Invalid tool name: $TOOL"

TOOLS_DIR="$BASE/tools/$TOOL"
CURRENT="$TOOLS_DIR/current"

run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if (( DRY_RUN )); then return 0; fi
  "$@"
}

if [[ -n "$ROLLBACK" ]]; then
  TARGET="$TOOLS_DIR/$ROLLBACK"
  [[ -d "$TARGET" ]] || die "Version dir not found: $TARGET"
  echo "Rolling back $TOOL to $ROLLBACK"
  if (( DRY_RUN )); then
    echo "+ ln -sfn $TARGET ${CURRENT}.new && mv -Tf ${CURRENT}.new $CURRENT"
  else
    ln -sfn "$TARGET" "${CURRENT}.new"
    mv -Tf "${CURRENT}.new" "$CURRENT"
  fi
  echo "Symlink: $CURRENT -> $TARGET"
  readlink -f "$CURRENT" 2>/dev/null || readlink "$CURRENT" || true
  exit 0
fi

[[ -n "$VERSION" ]] || die "Missing --version (or use --rollback)"
[[ "$VERSION" =~ ^[A-Za-z0-9._+-]+$ ]] || die "Invalid version: $VERSION"
REPO="${REPO:-manideepgrandhi/$TOOL}"
DEST="$TOOLS_DIR/$VERSION"
ZIP_NAME="${TOOL}.zip"
SHA_NAME="${TOOL}.zip.sha256"

mkdir -p "$TOOLS_DIR"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/install_${TOOL}.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

if [[ -n "$ZIP" ]]; then
  [[ -f "$ZIP" ]] || die "Zip not found: $ZIP"
  [[ -n "$SHA_FILE" && -f "$SHA_FILE" ]] || die "--sha256 file required with --zip"
  cp "$ZIP" "$WORKDIR/$ZIP_NAME"
  cp "$SHA_FILE" "$WORKDIR/$SHA_NAME"
else
  BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
  echo "Downloading $BASE_URL/$ZIP_NAME"
  if (( DRY_RUN )); then
    echo "+ curl -fsSL -o $WORKDIR/$ZIP_NAME $BASE_URL/$ZIP_NAME"
    echo "+ curl -fsSL -o $WORKDIR/$SHA_NAME $BASE_URL/$SHA_NAME"
  else
    curl -fsSL -o "$WORKDIR/$ZIP_NAME" "$BASE_URL/$ZIP_NAME" \
      || die "Download failed: $BASE_URL/$ZIP_NAME"
    curl -fsSL -o "$WORKDIR/$SHA_NAME" "$BASE_URL/$SHA_NAME" \
      || die "Download failed: $BASE_URL/$SHA_NAME"
  fi
fi

echo "Verifying sha256"
if (( DRY_RUN )); then
  echo "+ (sha256sum -c against $WORKDIR/$SHA_NAME)"
else
  # Accept either "HASH  file" or "HASH" alone; always check our local zip
  EXPECTED="$(awk 'NF>=1 {print $1; exit}' "$WORKDIR/$SHA_NAME")"
  [[ "$EXPECTED" =~ ^[a-fA-F0-9]{64}$ ]] || die "Bad sha256 file contents: $WORKDIR/$SHA_NAME"
  ACTUAL="$(sha256sum "$WORKDIR/$ZIP_NAME" | awk '{print $1}')"
  if [[ "${EXPECTED,,}" != "${ACTUAL,,}" ]]; then
    die "Checksum mismatch for $ZIP_NAME (expected $EXPECTED, got $ACTUAL)"
  fi
  echo "Checksum OK: $ACTUAL"
fi

if [[ -d "$DEST" ]]; then
  echo "Replacing existing $DEST"
  run rm -rf "$DEST"
fi
run mkdir -p "$DEST"

if (( DRY_RUN )); then
  echo "+ unzip -q $WORKDIR/$ZIP_NAME -d $DEST"
  echo "+ ln -sfn $DEST ${CURRENT}.new && mv -Tf ${CURRENT}.new $CURRENT"
  echo "Install dir: $DEST"
  echo "Symlink: $CURRENT -> $DEST"
  exit 0
fi

unzip -q "$WORKDIR/$ZIP_NAME" -d "$DEST"
# If the zip has a single top-level folder, flatten it
shopt -s nullglob
entries=("$DEST"/*)
if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
  # move contents up
  tmpflat="$DEST.__flat__"
  mv "${entries[0]}" "$tmpflat"
  shopt -s dotglob
  mv "$tmpflat"/* "$DEST"/
  shopt -u dotglob
  rmdir "$tmpflat" 2>/dev/null || rm -rf "$tmpflat"
fi
shopt -u nullglob

ln -sfn "$DEST" "${CURRENT}.new"
mv -Tf "${CURRENT}.new" "$CURRENT"

echo "Install dir: $DEST"
echo "Symlink: $CURRENT -> $(readlink "$CURRENT")"
# List main scripts if present
find "$DEST" -maxdepth 2 -type f -name '*.sh' | sort | while read -r f; do
  echo "Script: $f"
done
