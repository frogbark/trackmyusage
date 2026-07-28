#!/bin/bash
#
# Remove Parall once both TrackMyUsage instances are confirmed working.
#
# Deliberately a separate script from finish-repair.sh: the migrated data is the only
# copy of account 2's extensions and sessions outside the backups, so nothing is deleted
# until you have actually seen both accounts load.
#
# Removing the app does not affect the Mac App Store purchase — it can be reinstalled
# from Purchases at any time.
#
set -euo pipefail

SUPPORT="$HOME/Library/Application Support"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

TARGETS=(
  "/Applications/Parall.app"
  "/Applications/Claude 2.app"
  "$HOME/Library/Containers/app.parall.mac"
  "$SUPPORT/Parall"
)

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()  { printf '    \033[32m✓\033[0m %s\n' "$1"; }

say "Safety check"
if ! pgrep -f "Claude Two Bin" >/dev/null 2>&1; then
  echo "    The TrackMyUsage instance is not running." >&2
  echo "    Start it and confirm account 2 loads before removing the migrated source." >&2
  exit 1
fi
ok "TrackMyUsage instance is running"

ext=$(ls -1 "$SUPPORT/TrackMyUsage/Claude Two/Claude Extensions" 2>/dev/null | wc -l | tr -d ' ')
[ "$ext" -gt 0 ] || { echo "    No extensions in the migrated profile — aborting." >&2; exit 1; }
ok "migrated profile holds $ext extensions"

say "About to delete"
for t in "${TARGETS[@]}"; do
  [ -e "$t" ] && printf '    %s  (%s)\n' "$t" "$(du -sh "$t" 2>/dev/null | cut -f1)"
done
printf '\nProceed? [y/N] '
read -r reply
[[ "$reply" =~ ^[Yy]$ ]] || { echo "aborted"; exit 0; }

say "Final backup"
BK="$HOME/TrackMyUsage-Backups/parall-removal-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
[ -d "$SUPPORT/Parall" ] && cp -Rc "$SUPPORT/Parall" "$BK/Parall-data"
ok "backed up to $BK"

say "Removing"
osascript -e 'tell application "Parall" to quit' 2>/dev/null || true
sleep 2
for t in "${TARGETS[@]}"; do
  if [ -e "$t" ]; then
    [[ "$t" == *.app ]] && "$LSREG" -u "$t" 2>/dev/null || true
    rm -rf "$t"
    ok "removed $t"
  fi
done

say "Rebuilding the LaunchServices database"
"$LSREG" -kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true
for a in "/Applications/Claude.app" "/Applications/Claudruple/Claude Two.app" \
         "/Applications/Claudruple/TrackMyUsage Link.app"; do
  "$LSREG" -f "$a" 2>/dev/null || true
done
launchctl kickstart -k "gui/$UID/com.trackmyusage.link" 2>/dev/null || true
ok "rebuilt"

printf '\n\033[1mParall removed.\033[0m Backup retained at %s\n\n' "$BK"
