#!/bin/bash -x
# Wraps the `tuner` executable in a .app bundle so it can be launched from
# Finder or Spotlight rather than a terminal.
#
# The app is the whole product now: it drives the trackpad for as long as it is
# open, and the sliders tune the driver running inside it. `touchd` remains as
# the headless front end for a LaunchAgent.
#
# A bare SwiftPM executable can draw a window, but macOS treats it as a
# faceless process: no Dock icon, no menu bar ownership, and it cannot be
# focused properly. The bundle is what makes it a real app — and TCC will not
# hold a permission grant for an unbundled binary in a build directory.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Kneepad.app"
VERSION="1.0"
# Stamped into the bundle so the window title and About panel say which build
# is running — rebuilds are frequent and otherwise indistinguishable.
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILD_NUMBER="$(date +%Y%m%d.%H%M)"

echo "Building the app (release)…"
swift build -c release --product tuner

# This toolchain puts release output under .build/out/Products/Release rather
# than .build/release, so ask rather than assume.
RELEASE_DIR="$(swift build -c release --show-bin-path)"

echo "Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$RELEASE_DIR/tuner" "$APP/Contents/MacOS/tuner"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>            <string>tuner</string>
    <key>CFBundleIdentifier</key>            <string>dev.rymndhng.kneepad.app</string>
    <key>CFBundleName</key>                  <string>Kneepad</string>
    <key>CFBundleDisplayName</key>           <string>Kneepad</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>${VERSION}</string>
    <key>CFBundleVersion</key>               <string>${BUILD_NUMBER}</string>
    <key>TTBuildDate</key>                   <string>${BUILD_DATE}</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>
    <!-- Shown in the Input Monitoring prompt. The app reads the trackpad
         directly over HID; without this grant the device will not open. -->
    <key>NSInputMonitoringUsageDescription</key>
    <string>Kneepad reads your ZSA trackpad directly to turn its raw touch reports into cursor movement, clicks and scrolling.</string>
</dict>
</plist>
PLIST

# Sign with the local identity if it exists, so TCC keeps its grants across
# rebuilds. Ad-hoc signing names the code hash in the designated requirement,
# which changes with every build, so every build looks like a different app and
# has to be granted Accessibility and Input Monitoring again.
#
# See scripts/create-signing-identity.sh — it is a one-time setup, and this
# falls back to ad-hoc if it has not been run.
IDENTITY="Teach Touch"
KEYCHAIN="$HOME/Library/Keychains/teach-touch-signing.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    security unlock-keychain -p teach-touch "$KEYCHAIN" 2>/dev/null || true
    codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$APP"
    echo "Signed with \"$IDENTITY\" — permissions survive rebuilds."
else
    codesign --force --sign - "$APP" 2>/dev/null || \
        echo "  (codesign unavailable — the app still runs)"
    cat <<'SIGN'

⚠️  Ad-hoc signed, so macOS will treat this build as a new app and ask for
    Accessibility and Input Monitoring again. To stop that, run once:

      ./scripts/create-signing-identity.sh
SIGN
fi

echo
echo "Built: ${PWD}/${APP}"
echo
echo "  open '${APP}'                     launch it now"
echo "  cp -R '${APP}' /Applications/     to keep it"
echo
cat <<'NOTES'
The trackpad works for as long as the app is open; quitting it puts the pad
back in mouse mode.

FIRST RUN — it needs two permissions, in System Settings ▸ Privacy & Security:

  • Input Monitoring   to read the pad     (relaunch the app after granting)
  • Accessibility      to move the cursor  (takes effect immediately)

TCC is per-binary, so a grant given to your terminal for `swift run` does not
carry over, and neither does one given to a copy in build/ once you move it to
/Applications. Grant them to the copy you actually use.

Settings are written to ~/Library/Application Support/kneepad/tuning.json,
so a headless `touchd` LaunchAgent picks up the same values. Don't run both at
once — the app detects a running LaunchAgent and leaves the pad to it.

If the cursor ever stops responding entirely:

  swift run hid-stream --restore
NOTES
