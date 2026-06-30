#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Applications/Endel Focus Menu Bar.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
BUNDLE_ID="local.endel.focus-menubar"
EXECUTABLE_NAME="EndelFocusMenuBar"

/usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
  if ! /usr/bin/pgrep -qx "$EXECUTABLE_NAME" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
if /usr/bin/pgrep -qx "$EXECUTABLE_NAME" >/dev/null 2>&1; then
  /usr/bin/pkill -x "$EXECUTABLE_NAME" || true
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

/usr/bin/swiftc \
  "$ROOT/EndelFocusMenuBar.swift" \
  -o "$MACOS_DIR/EndelFocusMenuBar" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -framework ServiceManagement \
  -framework Vision

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
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

SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/awk '/Apple Development/ { print $2; exit }')"
if [ -n "$SIGNING_IDENTITY" ]; then
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null
else
  /usr/bin/codesign --force --sign - "$APP_DIR" >/dev/null
fi
/usr/bin/open "$APP_DIR"
printf '%s\n' "$APP_DIR"
