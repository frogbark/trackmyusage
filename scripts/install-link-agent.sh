#!/bin/bash
# Install Claudruple Link as a login agent.
#
# The broker must be running before any callback arrives, and must come back after a
# reboot — otherwise the first sign-in after restarting lands wherever LaunchServices
# happens to point. KeepAlive also restarts it if it ever dies mid-session.
set -euo pipefail

LABEL="com.claudruple.link"
APP="${APP:-/Applications/Claudruple/Claudruple Link.app}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$APP/Contents/MacOS/Claudruple Link"

[ -x "$BIN" ] || { echo "error: not found: $BIN" >&2; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLI
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$BIN</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/Claudruple/link.stderr.log</string>
</dict>
</plist>
PLI

mkdir -p "$HOME/Library/Logs/Claudruple"

# bootout is expected to fail when nothing is loaded yet; that is not an error.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/$LABEL"

echo "installed: $PLIST"
launchctl print "gui/$UID/$LABEL" 2>/dev/null | grep -E '^\s+(state|pid) ' | sed 's/^/  /' || true
