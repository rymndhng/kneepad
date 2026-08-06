#!/bin/bash
# Install touchd as a LaunchAgent so the trackpad works without any app open.
#
# This is the headless option. Teach Touch.app drives the pad itself while it
# is open, so you want one or the other: the app steps aside when it sees this
# agent already running, and touchd refuses to start if the app has the pad.
#
# IMPORTANT: TCC permissions are per-binary, not per-user. The copy installed
# here is a different binary from the one you have been running under your
# terminal, so it needs its OWN Input Monitoring and Accessibility grants. The
# first run will trigger those prompts.

set -euo pipefail

LABEL="dev.rymndhng.teach-touch"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/teach-touch"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Extra arguments for touchd, e.g. TOUCHD_ARGS="--pointer-gain 30 --no-tap"
TOUCHD_ARGS="${TOUCHD_ARGS:-}"

echo "Building release binaries…"
cd "$REPO"
# hid-stream ships too: it is the panic button that puts the device back into
# mouse mode if touchd ever dies without restoring it.
swift build -c release --product touchd
swift build -c release --product hid-stream

mkdir -p "$BIN_DIR" "$LOG_DIR" "$(dirname "$PLIST")"

# This toolchain puts release output under .build/out/Products/Release rather
# than .build/release, so ask rather than assume.
RELEASE_DIR="$(swift build -c release --show-bin-path)"
echo "Installing from $RELEASE_DIR → $BIN_DIR"

# Stop the running agent before replacing the binary it is executing.
if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
    echo "Stopping existing agent…"
    launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
fi

install -m 755 "$RELEASE_DIR/touchd" "$BIN_DIR/touchd"
install -m 755 "$RELEASE_DIR/hid-stream" "$BIN_DIR/hid-stream"

# Build the ProgramArguments array, one <string> per argument.
ARG_XML="        <string>$BIN_DIR/touchd</string>"
for arg in $TOUCHD_ARGS; do
    ARG_XML="$ARG_XML
        <string>$arg</string>"
done

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
$ARG_XML
    </array>

    <key>RunAtLoad</key>
    <true/>

    <!-- Restart if it exits, but back off so a crash loop does not spin. -->
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>

    <key>StandardOutPath</key>
    <string>$LOG_DIR/touchd.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/touchd.err.log</string>

    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST_EOF

echo "Wrote $PLIST"
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart -k "gui/$UID/$LABEL"

cat <<NOTES

Installed and started.

  status:   launchctl print gui/$UID/$LABEL | head -20
  logs:     tail -f $LOG_DIR/touchd.log
  stop:     launchctl bootout gui/$UID/$LABEL
  remove:   $REPO/scripts/uninstall-agent.sh

FIRST RUN — grant permissions to the INSTALLED binary:

  $BIN_DIR/touchd

TCC is per-binary, so approving your terminal earlier does not carry over.
Add that path to both lists in System Settings ▸ Privacy & Security:

  • Input Monitoring   (to read the trackpad)
  • Accessibility      (to post pointer and scroll events)

Then restart it:

  launchctl kickstart -k gui/$UID/$LABEL

If the cursor stops responding entirely, bail out with:

  launchctl bootout gui/$UID/$LABEL
  $BIN_DIR/hid-stream --restore

NOTES
