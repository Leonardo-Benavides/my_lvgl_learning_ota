#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release_ota.sh [options]

Build and publish a new OTA release.

Defaults:
  - app root: ../my_lvgl_learning
  - build dir: build
  - version bump: patch
  - git: commit and push OTA artifacts
  - after push: fetch and print the remote manifest state

Options:
  --version X.Y.Z       Use an exact version instead of bumping manifest version.
  --bump patch|minor|major
                        Version part to bump when --version is not provided.
  --min-version X.Y.Z   Also update manifest min_version.
  --app-root PATH       ESP-IDF project root.
  --build-dir DIR       ESP-IDF build directory, relative to app root.
  --firmware PATH       Use a prebuilt firmware .bin and skip idf.py build.
  --idf-path PATH       ESP-IDF root used to source export.sh when needed.
  --no-build            Skip idf.py build and use the existing build artifact.
  --no-git              Do not commit or push.
  --no-push             Commit locally but do not push.
  --allow-dirty         Allow overwriting local manifest/firmware changes.
  -h, --help            Show this help.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

note() {
  echo "==> $*"
}

require_arg() {
  local opt=$1
  local value=${2-}
  [[ -n "$value" ]] || die "$opt requires an argument"
}

semver_re='^[0-9]+\.[0-9]+\.[0-9]+$'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
OTA_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)

APP_ROOT=${APP_ROOT:-"$OTA_ROOT/../my_lvgl_learning"}
BUILD_DIR=${BUILD_DIR:-build}
FIRMWARE_NAME=${FIRMWARE_NAME:-my_lvgl_learning.bin}
MANIFEST_REL=manifest.json
DEST_BIN_REL="firmware/$FIRMWARE_NAME"
MANIFEST="$OTA_ROOT/$MANIFEST_REL"
DEST_BIN="$OTA_ROOT/$DEST_BIN_REL"

BUMP=patch
VERSION=
MIN_VERSION=
SOURCE_BIN=
IDF_PATH_OVERRIDE=
DO_BUILD=1
DO_GIT=1
DO_PUSH=1
ALLOW_DIRTY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      require_arg "$1" "${2-}"
      VERSION=$2
      shift 2
      ;;
    --bump)
      require_arg "$1" "${2-}"
      BUMP=$2
      shift 2
      ;;
    --min-version)
      require_arg "$1" "${2-}"
      MIN_VERSION=$2
      shift 2
      ;;
    --app-root)
      require_arg "$1" "${2-}"
      APP_ROOT=$2
      shift 2
      ;;
    --build-dir)
      require_arg "$1" "${2-}"
      BUILD_DIR=$2
      shift 2
      ;;
    --firmware)
      require_arg "$1" "${2-}"
      SOURCE_BIN=$2
      DO_BUILD=0
      shift 2
      ;;
    --idf-path)
      require_arg "$1" "${2-}"
      IDF_PATH_OVERRIDE=$2
      shift 2
      ;;
    --no-build)
      DO_BUILD=0
      shift
      ;;
    --no-git)
      DO_GIT=0
      DO_PUSH=0
      shift
      ;;
    --no-push)
      DO_PUSH=0
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ "$BUMP" == patch || "$BUMP" == minor || "$BUMP" == major ]] || die "--bump must be patch, minor, or major"
[[ -z "$VERSION" || "$VERSION" =~ $semver_re ]] || die "--version must look like X.Y.Z"
[[ -z "$MIN_VERSION" || "$MIN_VERSION" =~ $semver_re ]] || die "--min-version must look like X.Y.Z"

APP_ROOT=$(cd -- "$APP_ROOT" && pwd -P)
APP_SDKCONFIG="$APP_ROOT/sdkconfig"

[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"
[[ -f "$APP_SDKCONFIG" ]] || die "sdkconfig not found: $APP_SDKCONFIG"

if (( DO_GIT && ! ALLOW_DIRTY )); then
  if ! git -C "$OTA_ROOT" diff --quiet -- "$MANIFEST_REL" "$DEST_BIN_REL"; then
    die "manifest or firmware already has local changes; commit/stash them or rerun with --allow-dirty"
  fi
  if ! git -C "$OTA_ROOT" diff --cached --quiet -- "$MANIFEST_REL" "$DEST_BIN_REL"; then
    die "manifest or firmware already has staged changes; commit/unstage them or rerun with --allow-dirty"
  fi
fi

current_version=$(
  python - "$MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    print(json.load(fh)["version"])
PY
)

[[ "$current_version" =~ $semver_re ]] || die "manifest version must look like X.Y.Z: $current_version"

if [[ -n "$VERSION" ]]; then
  next_version=$VERSION
else
  IFS=. read -r major minor patch <<<"$current_version"
  case "$BUMP" in
    patch) patch=$((patch + 1)) ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    major) major=$((major + 1)); minor=0; patch=0 ;;
  esac
  next_version="$major.$minor.$patch"
fi

note "Preparing OTA release $current_version -> $next_version"

python - "$APP_SDKCONFIG" "$next_version" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text(encoding="utf-8")

text = re.sub(
    r"(?m)^# CONFIG_APP_PROJECT_VER_FROM_CONFIG is not set$",
    "CONFIG_APP_PROJECT_VER_FROM_CONFIG=y",
    text,
)

if not re.search(r"(?m)^CONFIG_APP_PROJECT_VER_FROM_CONFIG=y$", text):
    text += "\nCONFIG_APP_PROJECT_VER_FROM_CONFIG=y\n"

replacement = f'CONFIG_APP_PROJECT_VER="{version}"'
text, count = re.subn(r'(?m)^CONFIG_APP_PROJECT_VER=".*"$', replacement, text)
if count == 0:
    text += replacement + "\n"

path.write_text(text, encoding="utf-8")
PY

source_idf() {
  if command -v idf.py >/dev/null 2>&1; then
    if command -v esptool.py >/dev/null 2>&1 || command -v esptool >/dev/null 2>&1; then
      return
    fi
  fi

  local idf_path=${IDF_PATH_OVERRIDE:-${IDF_PATH:-}}
  if [[ -z "$idf_path" ]]; then
    for candidate in "$HOME/esp/esp-idf" "/home/l/esp/esp-idf"; do
      if [[ -f "$candidate/export.sh" ]]; then
        idf_path=$candidate
        break
      fi
    done
  fi

  [[ -n "$idf_path" && -f "$idf_path/export.sh" ]] || die "ESP-IDF export.sh not found; pass --idf-path PATH"
  # shellcheck source=/dev/null
  . "$idf_path/export.sh" >/dev/null
}

manifest_url_from_local_manifest() {
  python - "$MANIFEST" "$DEST_BIN_REL" "$MANIFEST_REL" <<'PY'
import json
import sys

manifest_path, firmware_rel, manifest_rel = sys.argv[1:4]
with open(manifest_path, "r", encoding="utf-8") as fh:
    manifest = json.load(fh)

firmware_url = manifest.get("firmware", {}).get("url", "")
suffix = "/" + firmware_rel.replace("\\", "/")
if firmware_url.endswith(suffix):
    print(firmware_url[: -len(suffix)] + "/" + manifest_rel)
    raise SystemExit(0)

raise SystemExit(1)
PY
}

manifest_url_from_git_remote() {
  local remote_url=$1
  local branch=$2
  local repo_path=

  remote_url=${remote_url%.git}
  case "$remote_url" in
    git@github.com:*)
      repo_path=${remote_url#git@github.com:}
      ;;
    https://github.com/*)
      repo_path=${remote_url#https://github.com/}
      ;;
    http://github.com/*)
      repo_path=${remote_url#http://github.com/}
      ;;
    ssh://git@github.com/*)
      repo_path=${remote_url#ssh://git@github.com/}
      ;;
    *)
      return 1
      ;;
  esac

  [[ -n "$repo_path" ]] || return 1
  printf 'https://raw.githubusercontent.com/%s/%s/%s\n' "$repo_path" "$branch" "$MANIFEST_REL"
}

check_remote_manifest() {
  local manifest_url=$1
  local expected_version=$2
  local expected_size=$3
  local expected_sha256=$4
  local check_url
  local remote_manifest

  if [[ -z "$manifest_url" ]]; then
    note "Remote manifest URL could not be inferred; skipping remote check"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    note "curl not found; skipping remote manifest check"
    return 0
  fi

  case "$manifest_url" in
    *\?*) check_url="${manifest_url}&release_check=$(date +%s)" ;;
    *) check_url="${manifest_url}?release_check=$(date +%s)" ;;
  esac

  note "Checking remote manifest: $manifest_url"
  if ! remote_manifest=$(curl -fsSL --connect-timeout 10 --max-time 30 -H 'Cache-Control: no-cache' "$check_url"); then
    note "Remote manifest request failed; GitHub may still be updating"
    return 0
  fi

  python - "$remote_manifest" "$expected_version" "$expected_size" "$expected_sha256" <<'PY'
import json
import sys

remote_json, expected_version, expected_size, expected_sha256 = sys.argv[1:5]
try:
    manifest = json.loads(remote_json)
except json.JSONDecodeError as exc:
    print(f"remote manifest: invalid JSON ({exc})")
    raise SystemExit(0)

firmware = manifest.get("firmware", {})
remote_version = manifest.get("version")
remote_size = firmware.get("size")
remote_sha256 = firmware.get("sha256")

checks = [
    ("version", remote_version, expected_version),
    ("size", str(remote_size), expected_size),
    ("sha256", remote_sha256, expected_sha256),
]

matched = True
for label, actual, expected in checks:
    ok = actual == expected
    matched = matched and ok
    status = "OK" if ok else "STALE"
    print(f"remote {label}: {actual} (expected {expected}) [{status}]")

if matched:
    print("remote manifest matches this release")
else:
    print("remote manifest does not match this release yet")
PY
}

source_idf

if (( DO_BUILD )); then
  note "Building firmware in $APP_ROOT"
  (cd "$APP_ROOT" && idf.py -B "$BUILD_DIR" build)
fi

if [[ -z "$SOURCE_BIN" ]]; then
  SOURCE_BIN="$APP_ROOT/$BUILD_DIR/$FIRMWARE_NAME"
fi

[[ -f "$SOURCE_BIN" ]] || die "firmware binary not found: $SOURCE_BIN"

note "Copying firmware to $DEST_BIN_REL"
mkdir -p -- "$(dirname -- "$DEST_BIN")"
cp -- "$SOURCE_BIN" "$DEST_BIN"

if command -v esptool.py >/dev/null 2>&1; then
  ESPTOOL_CMD=esptool.py
elif command -v esptool >/dev/null 2>&1; then
  ESPTOOL_CMD=esptool
else
  die "esptool not found after loading ESP-IDF"
fi

image_info=$("$ESPTOOL_CMD" image-info "$DEST_BIN")
image_version=$(printf '%s\n' "$image_info" | sed -n 's/^App version: //p' | head -n 1)
validation_hash=$(printf '%s\n' "$image_info" | sed -n 's/^Validation hash: \([0-9a-fA-F]\{64\}\).*/\1/p' | head -n 1)
firmware_size=$(wc -c <"$DEST_BIN" | tr -d ' ')

[[ -n "$image_version" ]] || die "could not read App version from firmware image"
[[ -n "$validation_hash" ]] || die "could not read Validation hash from firmware image"
[[ "$image_version" == "$next_version" ]] || die "firmware App version is $image_version, expected $next_version"

note "Updating manifest size=$firmware_size sha256=$validation_hash"
python - "$MANIFEST" "$next_version" "$firmware_size" "$validation_hash" "$MIN_VERSION" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
version = sys.argv[2]
size = int(sys.argv[3])
sha256 = sys.argv[4]
min_version = sys.argv[5]

manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["version"] = version
if min_version:
    manifest["min_version"] = min_version
manifest["firmware"]["size"] = size
manifest["firmware"]["sha256"] = sha256
path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY

if (( DO_GIT )); then
  if git -C "$OTA_ROOT" diff --quiet -- "$MANIFEST_REL" "$DEST_BIN_REL"; then
    note "No OTA artifact changes to commit"
  else
    note "Committing OTA artifacts"
    git -C "$OTA_ROOT" add -- "$MANIFEST_REL" "$DEST_BIN_REL"
    git -C "$OTA_ROOT" commit -m "Release OTA $next_version"
  fi

  if (( DO_PUSH )); then
    branch=$(git -C "$OTA_ROOT" branch --show-current)
    [[ -n "$branch" ]] || die "cannot push from detached HEAD"
    remote=$(git -C "$OTA_ROOT" config "branch.$branch.remote" || true)
    if [[ -z "$remote" ]] || ! git -C "$OTA_ROOT" remote get-url "$remote" >/dev/null 2>&1; then
      remote=$(git -C "$OTA_ROOT" remote | head -n 1)
    fi
    [[ -n "$remote" ]] || die "no git remote configured"
    note "Pushing $branch to $remote"
    git -C "$OTA_ROOT" push "$remote" "$branch"
    remote_url=$(git -C "$OTA_ROOT" remote get-url "$remote")
    manifest_url=$(manifest_url_from_local_manifest || manifest_url_from_git_remote "$remote_url" "$branch" || true)
    check_remote_manifest "$manifest_url" "$next_version" "$firmware_size" "$validation_hash"
  fi
fi

note "OTA release $next_version ready"
