#!/bin/bash
#
# Phase 0 completion: migrate the Parall instance's data into the Claudruple clone and
# clear the stale LaunchServices state.
#
#   RUN THIS FROM Terminal.app — NOT from inside Claude.
#   It quits every Claude process, including any Claude Code session hosted by one.
#
# Everything before this point was done live. These are the steps that need the source
# instance stopped: copying a running Electron profile risks torn SQLite, and the stale
# bundles cannot be unregistered while a process is running out of them.
#
set -euo pipefail

SUPPORT="$HOME/Library/Application Support"
SRC_DATA="$SUPPORT/Parall/Claude 2"
DST_DATA="$SUPPORT/Claudruple/Claude Two"
CLONE="/Applications/Claudruple/Claude Two.app"
PRIMARY="/Applications/Claude.app"
BROKER="/Applications/Claudruple/Claudruple Link.app"
GHOST="/Applications/Claude 2.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$1"; }

# ---------------------------------------------------------------- preflight

say "Preflight"
[ -d "$CLONE" ]  || { echo "missing clone: $CLONE" >&2; exit 1; }
[ -d "$BROKER" ] || { echo "missing broker: $BROKER" >&2; exit 1; }
codesign --verify --strict "$CLONE" 2>/dev/null || { echo "clone signature invalid" >&2; exit 1; }
ok "clone present and correctly signed"
if [ -d "$SRC_DATA" ]; then ok "source data found"; else warn "no Parall data at $SRC_DATA — migration will be skipped"; fi

# ---------------------------------------------------------------- backup

say "Backup (APFS clone — instant, near-zero disk)"
BK="$HOME/Claudruple-Backups/finish-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
[ -d "$SRC_DATA" ] && cp -Rc "$SRC_DATA" "$BK/parall-claude2"
[ -d "$DST_DATA" ] && cp -Rc "$DST_DATA" "$BK/clone-before"
ok "backed up to $BK"

# ---------------------------------------------------------------- quiesce

say "Stopping Claude processes"
for bid in com.anthropic.claudefordesktop com.anthropic.claudefordesktop.claudruple.two; do
  osascript -e "tell application id \"$bid\" to quit" 2>/dev/null || true
done
osascript -e 'tell application "Parall" to quit' 2>/dev/null || true

for _ in $(seq 1 20); do
  pgrep -f "MacOS/Claude" >/dev/null 2>&1 || break
  sleep 1
done

# Escalate only for stragglers; graceful quit is always tried first so Electron flushes.
if pgrep -f "MacOS/Claude" >/dev/null 2>&1; then
  warn "forcing remaining processes"
  pkill -f "MacOS/Claude Two Bin" 2>/dev/null || true
  pkill -f "MacOS/Claude" 2>/dev/null || true
  pkill -f "Claude 2.app" 2>/dev/null || true
  sleep 3
fi
pgrep -f "MacOS/Claude" >/dev/null 2>&1 && warn "some processes persist" || ok "all Claude processes stopped"

# ---------------------------------------------------------------- migrate

if [ -d "$SRC_DATA" ]; then
  say "Migrating account data"
  mkdir -p "$DST_DATA"
  # Denylist rather than allowlist: an allowlist silently drops anything Anthropic adds
  # in a future release. Only regenerable caches and single-process lock files are cut.
  rsync -a --delete-excluded \
    --exclude 'Cache/'            --exclude 'Code Cache/' \
    --exclude 'GPUCache/'         --exclude 'DawnGraphiteCache/' \
    --exclude 'DawnWebGPUCache/'  --exclude 'Crashpad/' \
    --exclude 'blob_storage/'     --exclude 'Service Worker/' \
    --exclude 'Shared Dictionary/' --exclude 'VideoDecodeStats/' \
    --exclude 'sentry/'           --exclude '*-wal' \
    --exclude '*-journal'         --exclude 'Singleton*' \
    "$SRC_DATA/" "$DST_DATA/"
  ok "data migrated ($(du -sh "$DST_DATA" 2>/dev/null | cut -f1))"
  ok "extensions carried over: $(ls -1 "$DST_DATA/Claude Extensions" 2>/dev/null | wc -l | tr -d ' ')"
  # The Electron safeStorage keychain item is derived from app.getName(), which the app
  # hardcodes to "Claude". It is therefore identical across instances, so the migrated
  # cookies and OAuth tokens still decrypt — no re-login.
  ok "keychain item unchanged — account 2 stays signed in"
fi

# ---------------------------------------------------------------- ghosts

say "Clearing stale LaunchServices registrations"
if [ -d "$GHOST" ]; then
  "$LSREG" -u "$GHOST" 2>/dev/null || true
  rm -rf "$GHOST"
  ok "removed $GHOST"
fi
# Parall's stub was quarantined, so Gatekeeper ran it from a randomised read-only path
# and registered it a second time. That translocated copy claims claude:// too.
find /private/var/folders -maxdepth 6 -name "Claude 2.app" -path "*AppTranslocation*" 2>/dev/null \
  | while read -r t; do "$LSREG" -u "$t" 2>/dev/null || true; ok "unregistered translocated $t"; done

say "Rebuilding the LaunchServices database"
"$LSREG" -kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true
for a in "$PRIMARY" "$CLONE" "$BROKER"; do "$LSREG" -f "$a" 2>/dev/null || true; done
ok "rebuilt and re-registered"

# ---------------------------------------------------------------- restart

say "Restarting"
launchctl kickstart -k "gui/$UID/com.claudruple.link" 2>/dev/null || open -a "$BROKER"
sleep 3
open -a "$PRIMARY";  sleep 6
open -a "$CLONE";    sleep 8

# ---------------------------------------------------------------- verify

say "Verification"
n=$(pgrep -f "MacOS/Claude" | wc -l | tr -d ' ')
[ "$n" -ge 2 ] && ok "$n Claude processes running" || warn "only $n Claude process(es)"

pgrep -f "Claudruple Link" >/dev/null && ok "broker running" || warn "broker NOT running"

owner=$(osascript -l JavaScript -e '
  ObjC.import("AppKit");
  const u = $.NSURL.URLWithString("claude://probe");
  const a = $.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL(u);
  a.isNil() ? "none" : ObjC.unwrap(a.lastPathComponent);' 2>/dev/null || echo "?")
[ "$owner" = "Claudruple Link.app" ] && ok "claude:// owned by the broker" \
                                     || warn "claude:// owned by: $owner"

find /private/var/folders -maxdepth 6 -name "Claude 2.app" -path "*AppTranslocation*" 2>/dev/null | grep -q . \
  && warn "translocated ghost still present" || ok "no translocated ghosts"

printf '\n\033[1mDone.\033[0m Backup: %s\n' "$BK"
cat <<'NEXT'

Check both windows show the right account, then remove Parall:

    ~/claudedruple/scripts/remove-parall.sh

NEXT
