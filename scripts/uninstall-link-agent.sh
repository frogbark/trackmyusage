#!/bin/bash
#
# Stop the deep-link broker and hand claude:// back.
#
# The counterpart to install-link-agent.sh, which did not have one. Installing the broker
# takes ownership of a URL scheme and adds a KeepAlive login agent that restarts it if it
# dies — both of which are exactly what you want while it is in use and neither of which a
# person should have to reverse by hand, out of a plist they did not write.
#
# Handing the scheme back is the part that matters. With the broker gone and nothing
# re-registered, claude:// resolves to whichever instance last claimed it — which is the
# tug-of-war the broker exists to settle, and the first sign-in afterwards would land in
# whichever account LaunchServices happens to be pointing at.
#
set -euo pipefail

# Overridable for the same reason install-link-agent.sh takes APP=: so this can be
# exercised against a throwaway agent rather than only against the one you are relying on.
# The process pattern is derived from APP, so a test run cannot match the real broker.
LABEL="${LABEL:-com.trackmyusage.link}"
APP="${APP:-/Applications/TrackMyUsage Link.app}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PRIMARY="${PRIMARY:-/Applications/Claude.app}"
BROKER_PATTERN="$APP/Contents/MacOS"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$1"; }

say "Stopping the broker"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null && ok "unloaded" || ok "was not running"
if [ -f "$PLIST" ]; then
    rm -f "$PLIST"
    ok "removed $PLIST"
else
    ok "no launch agent installed"
fi

# KeepAlive means launchd restarts it, so the process can outlive the bootout by a moment.
# Killing it after the agent is gone is the order that sticks.
if pgrep -f "$BROKER_PATTERN" >/dev/null 2>&1; then
    pkill -f "$BROKER_PATTERN" 2>/dev/null || true
    sleep 1
    pgrep -f "$BROKER_PATTERN" >/dev/null 2>&1 \
        && warn "a broker process is still running; kill it by hand" \
        || ok "broker stopped"
fi

say "Handing claude:// back"
if [ -d "$PRIMARY" ]; then
    "$LSREG" -f "$PRIMARY" 2>/dev/null && ok "re-registered $PRIMARY"
    warn "launch it once to make it the handler — Claude claims the scheme on startup,"
    warn "and so does every instance, which is the whole reason the broker existed"
else
    warn "no Claude at $PRIMARY, so nothing was re-registered"
    warn "claude:// now resolves to whichever instance last claimed it"
fi

printf '\n  The broker app itself is left in place. Remove it with:\n'
printf '    rm -rf "%s"\n' "$APP"
printf '  Instances are untouched. Remove them with ./scripts/remove-instance.sh\n\n'
