#!/bin/bash
# Remove the touchd LaunchAgent and put the trackpad back in mouse mode.

set -uo pipefail

LABEL="dev.rymndhng.teach-touch"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
    echo "Stopping agent…"
    launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
else
    echo "Agent is not loaded."
fi

[ -f "$PLIST" ] && rm -f "$PLIST" && echo "Removed $PLIST"

# touchd restores mouse mode on SIGTERM, but if it was killed hard the device
# is still in multitouch mode with no cursor. Put it back explicitly.
echo "Restoring mouse mode…"
RESTORED=0
for candidate in \
    "$BIN_DIR/hid-stream" \
    "$REPO/.build/debug/hid-stream" \
    "$(cd "$REPO" && swift build -c release --show-bin-path 2>/dev/null)/hid-stream"
do
    if [ -x "$candidate" ]; then
        "$candidate" --restore && RESTORED=1 && break
    fi
done
if [ "$RESTORED" != "1" ]; then
    echo "  ⚠️  could not find hid-stream — if the cursor is dead, run:"
    echo "      cd $REPO && swift run hid-stream --restore"
fi

if [ "${KEEP_BINARY:-0}" != "1" ]; then
    rm -f "$BIN_DIR/touchd" "$BIN_DIR/hid-stream"
    echo "Removed binaries from $BIN_DIR"
fi

echo "Done. Logs left in ~/Library/Logs/teach-touch."
