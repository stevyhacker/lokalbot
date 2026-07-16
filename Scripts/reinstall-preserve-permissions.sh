#!/usr/bin/env bash
# Rebuild and reinstall LokalBot without changing the permission-bearing app
# identity. This intentionally updates the existing /Applications bundle in
# place instead of deleting it first, so macOS TCC grants keep pointing at the
# same signed app identity.
#
# Usage:
#   Scripts/reinstall-preserve-permissions.sh
#   Scripts/reinstall-preserve-permissions.sh --no-relaunch
#   CONFIGURATION=Release Scripts/reinstall-preserve-permissions.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="LokalBot"
PROJECT="LokalBot.xcodeproj"
SCHEME="LokalBot"
CONFIGURATION="${CONFIGURATION:-Debug}"
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-me.dotenv.LokalBot}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-K96P3M3997}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Apple Development}"
INSTALLED_APP="${LOKALBOT_APP:-/Applications/LokalBot.app}"

TMP_ROOT="/private/tmp"
DERIVED_DATA="$TMP_ROOT/lokalbot-preserve-permissions-DerivedData"
SPM_CACHE="$TMP_ROOT/lokalbot-preserve-permissions-SPM"
BUILD_LOG="$TMP_ROOT/lokalbot-preserve-permissions-xcodebuild.log"
LOCK_DIR="$TMP_ROOT/lokalbot-preserve-permissions.lock"

RELAUNCH=1

usage() {
  cat <<EOF
Usage: Scripts/reinstall-preserve-permissions.sh [--no-relaunch] [--help]

Environment:
  CONFIGURATION        Xcode configuration to build. Default: Debug
  LOKALBOT_APP         Installed app path. Default: /Applications/LokalBot.app
  EXPECTED_BUNDLE_ID   Expected bundle id. Default: me.dotenv.LokalBot
  EXPECTED_TEAM_ID     Expected Apple Team ID. Default: K96P3M3997
  SIGNING_IDENTITY     Xcode signing selector. Default: Apple Development
EOF
}

log() {
  printf '== %s\n' "$*"
}

note() {
  printf '   %s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-relaunch)
      RELAUNCH=0
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
  shift
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

plist_raw() {
  /usr/bin/plutil -extract "$2" raw -o - "$1"
}

codesign_display() {
  /usr/bin/codesign -dv -r- "$1" 2>&1
}

codesign_field() {
  local path="$1"
  local field="$2"
  codesign_display "$path" | /usr/bin/awk -F= -v field="$field" '
    $1 == field && value == "" { value = $2 }
    END { if (value != "") print value }
  '
}

designated_requirement() {
  codesign_display "$1" | /usr/bin/awk '
    /^designated => / && value == "" {
      sub(/^designated => /, "")
      value = $0
    }
    END { if (value != "") print value }
  '
}

verify_app_identity() {
  local app_path="$1"
  local label="$2"
  local bundle_id
  local team_id
  local requirement

  [ -d "$app_path" ] || fail "$label app is missing: $app_path"
  [ -f "$app_path/Contents/Info.plist" ] || fail "$label app has no Info.plist: $app_path"

  bundle_id="$(plist_raw "$app_path/Contents/Info.plist" CFBundleIdentifier)"
  [ "$bundle_id" = "$EXPECTED_BUNDLE_ID" ] || fail "$label bundle id is '$bundle_id', expected '$EXPECTED_BUNDLE_ID'"

  /usr/bin/codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 || fail "$label app fails codesign verification: $app_path"

  team_id="$(codesign_field "$app_path" TeamIdentifier)"
  [ "$team_id" = "$EXPECTED_TEAM_ID" ] || fail "$label TeamIdentifier is '$team_id', expected '$EXPECTED_TEAM_ID'"

  requirement="$(designated_requirement "$app_path")"
  [ -n "$requirement" ] || fail "$label app has no designated signing requirement"

  printf '%s\n' "$requirement"
}

cleanup_old_temp_dirs() {
  local removed=0
  local path

  shopt -s nullglob
  for path in \
    "$TMP_ROOT"/lokalbot-reinstall-DerivedData \
    "$TMP_ROOT"/lokalbotfable-DerivedData-* \
    "$TMP_ROOT"/lokalbot-preserve-permissions-DerivedData.old.*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ "$path" = "$DERIVED_DATA" ] && continue
    log "Removing old temp dir: $path"
    rm -rf "$path"
    removed=$((removed + 1))
  done
  shopt -u nullglob

  if [ "$removed" -eq 0 ]; then
    note "no old LokalBot reinstall temp dirs found"
  else
    note "removed $removed old temp dir(s)"
  fi
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another reinstall appears to be running: $LOCK_DIR"
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

need_cmd xcodegen
need_cmd xcodebuild

log "Prechecking installed app identity"
note "installed app: $INSTALLED_APP"
installed_requirement="$(verify_app_identity "$INSTALLED_APP" installed)"
installed_signed_time="$(codesign_field "$INSTALLED_APP" "Signed Time")"
note "bundle id: $EXPECTED_BUNDLE_ID"
note "team id: $EXPECTED_TEAM_ID"
note "installed signed time: ${installed_signed_time:-unknown}"

log "Regenerating Xcode project"
xcodegen generate >/dev/null

log "Building signed $CONFIGURATION app"
note "derived data: $DERIVED_DATA"
note "package cache: $SPM_CACHE"
note "build log: $BUILD_LOG"
rm -rf "$DERIVED_DATA"
mkdir -p "$SPM_CACHE"

if ! xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SPM_CACHE" \
  -destination 'platform=macOS' \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$EXPECTED_TEAM_ID" \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  -quiet \
  build >"$BUILD_LOG" 2>&1; then
  /usr/bin/tail -80 "$BUILD_LOG" >&2 || true
  fail "xcodebuild failed; full log: $BUILD_LOG"
fi

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"

log "Checking built app identity"
note "built app: $BUILT_APP"
built_requirement="$(verify_app_identity "$BUILT_APP" built)"
built_signed_time="$(codesign_field "$BUILT_APP" "Signed Time")"
note "built signed time: ${built_signed_time:-unknown}"

if [ "$built_requirement" != "$installed_requirement" ]; then
  fail "built app signing requirement differs from installed app; refusing to replace because TCC permissions may not survive"
fi

log "Stopping running app"
/usr/bin/pkill -x "$APP_NAME" 2>/dev/null || true
/usr/bin/pkill -x "LokalBotV3" 2>/dev/null || true
/bin/sleep 1

log "Syncing app bundle in place"
note "source: $BUILT_APP/"
note "dest:   $INSTALLED_APP/"
/usr/bin/rsync -a --delete "$BUILT_APP/" "$INSTALLED_APP/"

log "Verifying installed app after copy"
post_requirement="$(verify_app_identity "$INSTALLED_APP" installed)"
[ "$post_requirement" = "$installed_requirement" ] || fail "post-copy signing requirement changed unexpectedly"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"

if [ "$RELAUNCH" -eq 1 ]; then
  log "Relaunching $INSTALLED_APP"
  /usr/bin/open -n "$INSTALLED_APP"

  app_pid=""
  for _ in $(seq 1 20); do
    app_pid="$(/usr/bin/pgrep -x "$APP_NAME" | /usr/bin/head -1 || true)"
    [ -n "$app_pid" ] && break
    /bin/sleep 0.5
  done

  [ -n "$app_pid" ] || fail "$APP_NAME did not appear to launch"
  note "running pid: $app_pid"
else
  note "relaunch skipped"
fi

log "Cleaning old reinstall temp dirs"
cleanup_old_temp_dirs

log "Done"
note "installed app: $INSTALLED_APP"
note "bundle id: $EXPECTED_BUNDLE_ID"
note "team id: $EXPECTED_TEAM_ID"
note "signed time: $(codesign_field "$INSTALLED_APP" "Signed Time")"
note "kept current derived data: $DERIVED_DATA"
note "kept package cache: $SPM_CACHE"
note "build log: $BUILD_LOG"
