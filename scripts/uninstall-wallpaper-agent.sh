#!/bin/bash
#
# Stop the wallpaper agent and put the original background back.
#
# The restore is the point. macOS keeps no history of what the desktop used to be, so
# without the path recorded at install time there is nothing to return to.
#
set -euo pipefail

LABEL="com.claudruple.wallpaper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
ORIGIN_FILE="$HOME/Library/Application Support/Claudruple/original-wallpaper.txt"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()  { printf '    \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '    \033[33m!\033[0m %s\n' "$1"; }

say "Stopping the agent"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null && ok "unloaded" || ok "was not running"
rm -f "$PLIST"
ok "removed $PLIST"

say "Restoring the wallpaper"
if [ -s "$ORIGIN_FILE" ]; then
    original=$(head -1 "$ORIGIN_FILE")
    if [ -f "$original" ]; then
        osascript -e "tell application \"System Events\" to set picture of every desktop to \"$original\"" \
            && ok "restored $original"
    else
        warn "recorded original no longer exists: $original"
        warn "set a wallpaper yourself in System Settings → Wallpaper"
    fi
else
    warn "no original was recorded — set one in System Settings → Wallpaper"
fi

printf '\n  The renders in ~/Library/Caches/Claudruple/wallpaper are left in place.\n'
printf '  Remove them with: rm -rf ~/Library/Caches/Claudruple\n\n'
