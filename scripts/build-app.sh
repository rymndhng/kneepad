#!/bin/bash
# Wraps the `tuner` executable in a .app bundle so it can be launched from
# Finder or Spotlight rather than a terminal.
#
# A bare SwiftPM executable can draw a window, but macOS treats it as a
# faceless process: no Dock icon, no menu bar ownership, and it cannot be
# focused properly. The bundle is what makes it a real app.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Teach Touch Tuner.app"
VERSION="1.0"

echo "Building tuner (release)…"
swift build -c release --product tuner

echo "Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/tuner "$APP/Contents/MacOS/tuner"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>            <string>tuner</string>
    <key>CFBundleIdentifier</key>            <string>dev.rymndhng.teach-touch.tuner</string>
    <key>CFBundleName</key>                  <string>Teach Touch Tuner</string>
    <key>CFBundleDisplayName</key>           <string>Teach Touch Tuner</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>${VERSION}</string>
    <key>CFBundleVersion</key>               <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <!-- Writes a config file only; it needs no Input Monitoring or
         Accessibility permission. touchd is the one that needs those. -->
    <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Without any signature at all, Gatekeeper is more awkward
# about a freshly built binary than it needs to be.
codesign --force --sign - "$APP" 2>/dev/null || \
    echo "  (codesign unavailable — the app still runs)"

echo
echo "Built: ${PWD}/${APP}"
echo
echo "  open '${APP}'                     launch it now"
echo "  cp -R '${APP}' /Applications/     to keep it"
echo
echo "It writes ~/Library/Application Support/teach-touch/tuning.json."
echo "Run touchd alongside it and changes apply without restarting."
