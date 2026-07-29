#!/bin/sh
set -eu
umask 077

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Endel Focus Menu Bar.app"
APP_PARENT=${APP_PARENT:-"$HOME/Applications"}
BUNDLE_ID="local.endel.focus-menubar"
EXECUTABLE_NAME="EndelFocusMenuBar"

AWK=${AWK:-/usr/bin/awk}
CODESIGN=${CODESIGN:-/usr/bin/codesign}
MKDIR=${MKDIR:-/bin/mkdir}
MV=${MV:-/bin/mv}
OPEN=${OPEN:-/usr/bin/open}
OSASCRIPT=${OSASCRIPT:-/usr/bin/osascript}
PGREP=${PGREP:-/usr/bin/pgrep}
PKILL=${PKILL:-/usr/bin/pkill}
PLUTIL=${PLUTIL:-/usr/bin/plutil}
RM=${RM:-/bin/rm}
SECURITY=${SECURITY:-/usr/bin/security}
SHASUM=${SHASUM:-/usr/bin/shasum}
SLEEP=${SLEEP:-/bin/sleep}
SWIFTC=${SWIFTC:-/usr/bin/swiftc}
SIGNING_IDENTITY=${SIGNING_IDENTITY:-}

fail() {
  printf 'build_app.sh: %s\n' "$*" >&2
  exit 1
}

case "$APP_PARENT" in
  /*) ;;
  *) fail "APP_PARENT must be an absolute path: $APP_PARENT" ;;
esac
[ "$APP_PARENT" != "/" ] || fail "refusing APP_PARENT=/"

"$MKDIR" -p "$APP_PARENT"
APP_PARENT=$(
  CDPATH=
  export CDPATH
  cd "$APP_PARENT" && pwd -P
) || fail "cannot resolve APP_PARENT"

APP_DIR="$APP_PARENT/$APP_NAME"

validate_destination() {
  [ ! -L "$APP_DIR" ] || fail "refusing symlink destination: $APP_DIR"
  if [ -e "$APP_DIR" ] && [ ! -d "$APP_DIR" ]; then
    fail "destination exists but is not a directory: $APP_DIR"
  fi
}

validate_destination

TXN_DIR=
index=0
while [ "$index" -lt 100 ]; do
  candidate="$APP_PARENT/.endel-focus-build.$$.$index"
  if "$MKDIR" "$candidate" 2>/dev/null; then
    TXN_DIR=$candidate
    break
  fi
  index=$((index + 1))
done
[ -n "$TXN_DIR" ] || fail "cannot create build transaction directory"

CANDIDATE_APP="$TXN_DIR/$APP_NAME"
CANDIDATE_CONTENTS="$CANDIDATE_APP/Contents"
CANDIDATE_MACOS="$CANDIDATE_CONTENTS/MacOS"
BACKUP_APP="$TXN_DIR/previous.app"
COMMITTED=0

cleanup() {
  status=$?
  trap - 0 1 2 15
  set +e
  preserve_transaction=0

  if [ "$COMMITTED" -eq 0 ] && [ -d "$BACKUP_APP" ]; then
    if [ -e "$APP_DIR" ] || [ -L "$APP_DIR" ]; then
      if ! "$MV" "$APP_DIR" "$TXN_DIR/failed-candidate.app"; then
        preserve_transaction=1
      fi
    fi
    if [ "$preserve_transaction" -eq 0 ]; then
      if ! "$MV" "$BACKUP_APP" "$APP_DIR"; then
        preserve_transaction=1
      fi
    fi
  fi

  case "$TXN_DIR" in
    "$APP_PARENT"/.endel-focus-build.*)
      if [ "$preserve_transaction" -eq 0 ]; then
        "$RM" -rf "$TXN_DIR" ||
          printf 'build_app.sh: failed to remove %s\n' "$TXN_DIR" >&2
      else
        printf 'build_app.sh: rollback incomplete; recovery data preserved at %s\n' \
          "$TXN_DIR" >&2
      fi
      ;;
    *)
      printf 'build_app.sh: refusing unsafe cleanup target: %s\n' "$TXN_DIR" >&2
      ;;
  esac

  exit "$status"
}

trap cleanup 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

"$MKDIR" -p "$CANDIDATE_MACOS"

"$SWIFTC" \
  "$ROOT/EndelFocusMenuBar.swift" \
  -o "$CANDIDATE_MACOS/$EXECUTABLE_NAME" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -framework ServiceManagement \
  -framework Vision

cat > "$CANDIDATE_CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>EndelFocusMenuBar</string>
  <key>CFBundleIdentifier</key>
  <string>local.endel.focus-menubar</string>
  <key>CFBundleName</key>
  <string>Endel Focus Menu Bar</string>
  <key>CFBundleDisplayName</key>
  <string>Endel Focus Menu Bar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Endel Focus Menu Bar uses Apple Events to control Flow sessions.</string>
  <key>NSAccessibilityUsageDescription</key>
  <string>Endel Focus Menu Bar may need Accessibility permission for fallback timer controls.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Endel Focus Menu Bar may read visible timer text to refresh the menu-bar countdown.</string>
</dict>
</plist>
PLIST

"$PLUTIL" -lint "$CANDIDATE_CONTENTS/Info.plist" >/dev/null
[ -x "$CANDIDATE_MACOS/$EXECUTABLE_NAME" ] ||
  fail "compiler did not produce an executable"

SELECTED_SIGNING_IDENTITY=$SIGNING_IDENTITY
if [ -z "$SELECTED_SIGNING_IDENTITY" ] && [ -d "$APP_DIR" ]; then
  if "$CODESIGN" -d \
       --extract-certificates="$TXN_DIR/installed-cert" \
       "$APP_DIR" >/dev/null 2>&1 &&
     [ -f "$TXN_DIR/installed-cert0" ]; then
    SELECTED_SIGNING_IDENTITY="$(
      "$SHASUM" -a 1 "$TXN_DIR/installed-cert0" |
        "$AWK" '{ print toupper($1); exit }'
    )"
  else
    installed_signature="$("$CODESIGN" -d --verbose=4 "$APP_DIR" 2>&1 || true)"
    if printf '%s\n' "$installed_signature" |
         "$AWK" '/^Signature=adhoc$/ { found=1 } END { exit !found }'; then
      SELECTED_SIGNING_IDENTITY=-
    fi
  fi
fi
if [ -z "$SELECTED_SIGNING_IDENTITY" ]; then
  SELECTED_SIGNING_IDENTITY="$(
    "$SECURITY" find-identity -v -p codesigning 2>/dev/null |
      "$AWK" '/Apple Development/ { print $2; exit }'
  )"
fi

if [ -n "$SELECTED_SIGNING_IDENTITY" ]; then
  "$CODESIGN" --force --sign "$SELECTED_SIGNING_IDENTITY" "$CANDIDATE_APP" >/dev/null
else
  "$CODESIGN" --force --sign - "$CANDIDATE_APP" >/dev/null
fi
"$CODESIGN" --verify --deep --strict "$CANDIDATE_APP" >/dev/null

quit_running_helper() {
  "$OSASCRIPT" -e "tell application id \"$BUNDLE_ID\" to quit" \
    >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    if ! "$PGREP" -qx "$EXECUTABLE_NAME" >/dev/null 2>&1; then
      return
    fi
    "$SLEEP" 0.2
  done
  if "$PGREP" -qx "$EXECUTABLE_NAME" >/dev/null 2>&1; then
    "$PKILL" -x "$EXECUTABLE_NAME" || true
  fi
}

# Recheck immediately before replacement in case the destination changed while
# the candidate was being built and signed.
validate_destination
quit_running_helper

if [ -d "$APP_DIR" ]; then
  "$MV" "$APP_DIR" "$BACKUP_APP"
fi
"$MV" "$CANDIDATE_APP" "$APP_DIR"
COMMITTED=1

launch_attempt=1
while ! "$OPEN" "$APP_DIR"; do
  [ "$launch_attempt" -lt 3 ] ||
    fail "installed app but could not launch it: $APP_DIR"
  launch_attempt=$((launch_attempt + 1))
  "$SLEEP" 0.5
done
printf '%s\n' "$APP_DIR"
