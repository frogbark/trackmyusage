#!/bin/bash
#
# Install claudrupled as a login agent so the usage wallpaper stays current.
#
# Records the wallpaper you have now before anything is changed, so
# uninstall-wallpaper-agent.sh can put it back. That record is the only way back:
# macOS keeps no history of what the background used to be.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.claudruple.wallpaper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$HOME/Library/Application Support/Claudruple"
ORIGIN_FILE="$STATE_DIR/original-wallpaper.txt"

# The usage history itself updates about every five minutes, so anything faster redraws
# the same numbers.
INTERVAL="${INTERVAL:-300}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()  { printf '    \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '    \033[33m!\033[0m %s\n' "$1"; }

# ---------------------------------------------------------------- build & install

say "Building"
( cd "$ROOT" && swift build -c release --product claudrupled >/dev/null )

# A stable path: .build/release is wiped by `swift package clean`, and a launch agent
# pointing at a missing binary fails silently every interval.
if [ -w /usr/local/bin ]; then BIN_DIR=/usr/local/bin; else BIN_DIR="$HOME/.local/bin"; fi
mkdir -p "$BIN_DIR"
install -m 0755 "$ROOT/.build/release/claudrupled" "$BIN_DIR/claudrupled"
ok "installed $BIN_DIR/claudrupled"

# ---------------------------------------------------------------- remember the original

say "Recording the current wallpaper"
mkdir -p "$STATE_DIR"
if [ -s "$ORIGIN_FILE" ]; then
    ok "already recorded: $(head -1 "$ORIGIN_FILE")"
else
    current=$(osascript -e 'tell application "System Events" to get picture of current desktop' 2>/dev/null || true)
    case "$current" in
        # Never record one of our own renders as the original: doing so would make the
        # overlay permanent with no way back.
        *"/Caches/Claudruple/"*|"")
            warn "no pristine original to capture — uninstall will not restore"
            ;;
        *)
            # Verify now rather than at restore time. Some wallpaper apps hand macOS a
            # path they then delete or regenerate, so the name it reports can already be
            # dead. Discovering that during an uninstall is discovering it too late.
            if [ -r "$current" ]; then
                printf '%s\n' "$current" > "$ORIGIN_FILE"
                ok "saved to $ORIGIN_FILE"
            else
                warn "the current wallpaper path no longer exists on disk:"
                warn "  $current"
                warn "nothing to restore to — pick a static image in System Settings first"
                warn "if you want uninstall to be able to put it back"
            fi
            ;;
    esac
fi

# ---------------------------------------------------------------- conflict check

if pgrep -qf "iwallpaper|Wallpaper Engine|Plash" 2>/dev/null; then
    warn "another wallpaper app is running — both will set the desktop and fight"
    warn "quit it, or expect the overlay to be replaced on its schedule"
fi

# ---------------------------------------------------------------- agent

say "Installing the login agent"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/Claudruple"
cat > "$PLIST" <<PLI
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DIR/claudrupled</string>
        <string>apply</string>
    </array>
    <key>StartInterval</key><integer>$INTERVAL</integer>
    <key>RunAtLoad</key><true/>
    <!-- Background: this is a redraw on a timer, and it should never compete with
         whatever the person is actually doing. -->
    <key>ProcessType</key><string>Background</string>
    <key>LowPriorityIO</key><true/>
    <!-- No KeepAlive. StartInterval already reruns it; KeepAlive as well would restart a
         one-shot command the instant it exits, in a loop. -->
    <key>StandardOutPath</key><string>$HOME/Library/Logs/Claudruple/wallpaper.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/Claudruple/wallpaper.log</string>
</dict>
</plist>
PLI

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/$LABEL"
ok "every ${INTERVAL}s, and at login"

sleep 3
say "First run"
tail -3 "$HOME/Library/Logs/Claudruple/wallpaper.log" 2>/dev/null | sed 's/^/    /' || true

cat <<NEXT

  Undo:   ~/claudedruple/scripts/uninstall-wallpaper-agent.sh
  Logs:   ~/Library/Logs/Claudruple/wallpaper.log

NEXT
