#!/bin/bash
#
# Remove a TrackMyUsage instance.
#
#   ./remove-instance.sh "Work"              # removes the app, keeps the data
#   ./remove-instance.sh "Work" --purge-data # also deletes the profile
#
# Data is kept by default. The profile holds that account's extensions, MCP config and
# session history, and an app bundle is regenerable in under a second — the data is not.
#
set -euo pipefail

NAME="${1:-}"
[ -n "$NAME" ] || { echo "usage: $0 <instance-name> [--purge-data]" >&2; exit 1; }
PURGE=0; [ "${2:-}" = "--purge-data" ] && PURGE=1

APP="${DEST_DIR:-/Applications/Claudruple}/$NAME.app"
UDD="$HOME/Library/Application Support/Claudruple/$NAME"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

ok() { printf '    \033[32m✓\033[0m %s\n' "$1"; }

[ -e "$APP" ] || { echo "no such instance: $APP" >&2; exit 1; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || echo "")

printf '\n\033[1m==> Removing %s\033[0m\n' "$NAME"

if [ -n "$BUNDLE_ID" ]; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
  sleep 2
fi
pkill -f "$NAME Bin" 2>/dev/null || true
ok "stopped"

"$LSREG" -u "$APP" 2>/dev/null || true
rm -rf "$APP"
ok "removed $APP"

if [ "$PURGE" = "1" ] && [ -d "$UDD" ]; then
  BK="$HOME/TrackMyUsage-Backups/removed-$NAME-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$(dirname "$BK")"
  cp -Rc "$UDD" "$BK"        # APFS clone: a free safety net before an irreversible delete
  rm -rf "$UDD"
  ok "purged profile (backup: $BK)"
elif [ -d "$UDD" ]; then
  ok "profile kept at $UDD"
fi

# The broker re-derives its instance list per callback, so it needs no restart — but the
# LaunchServices cache does need to forget the bundle we just deleted.
"$LSREG" -kill -r -domain local -domain user >/dev/null 2>&1 || true
ok "LaunchServices refreshed"
printf '\n'
