#!/bin/bash
#
# Does a Codex Desktop clone still run once its entitlements are stripped?
#
# This is the one question in findings.md §8 that inspection cannot answer. Codex is
# sandboxed and every entitlement that matters is Team-ID-bound: app-sandbox,
# application-groups, aps-environment and keychain-access-groups. An ad-hoc signature can
# claim none of them, so a clone has to lose all four, and whether the app starts without
# its sandbox and app group is not something the bundle will tell you by being read.
#
# Nothing here is a step towards shipping Codex support. It answers one question and undoes
# itself. In particular:
#
#  * /Applications/ChatGPT.app is never modified. It is a clone source and nothing else.
#  * The clone gets its own bundle id, so it cannot take over the real app's LaunchServices
#    registration.
#  * The clone is removed on exit, including on failure or interrupt.
#  * codex:// is handed back to the real ChatGPT afterwards. If the clone starts, it will
#    call setAsDefaultProtocolClient on launch — the same last-launch-wins tug-of-war that
#    made the broker necessary for Claude — and leaving that pointed at a deleted bundle
#    would break deep links into the app somebody actually uses.
#
# Usage:  ./scripts/probe-codex.sh [--keep]
#         --keep leaves the clone in place for poking at. You are then responsible for it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SRC:-/Applications/ChatGPT.app}"
PROBE="${PROBE:-/Applications/TMUCodexProbe.app}"
PROBE_ID="com.openai.codex.tmuprobe"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$1"; }
no()   { printf '    \033[31m✗\033[0m %s\n' "$1"; }
note() { printf '      %s\n' "$1"; }

cleanup() {
    local code=$?
    if [ "$KEEP" = "1" ]; then
        printf '\n    clone kept at %s — remove it yourself\n' "$PROBE"
    else
        say "Cleaning up"
        # Escalate, and confirm. The first version sent SIGTERM, waited two seconds and
        # deleted the bundle regardless — and Chromium does not die on SIGTERM in two
        # seconds. macOS is happy to unlink a running app, so that left a live process
        # executing from a bundle that no longer existed, which the next run's pgrep then
        # matched and reported as a successful launch. Deleting the evidence while the
        # subject is still alive is how a probe lies to you.
        if pgrep -f "TMUCodexProbe" >/dev/null 2>&1; then
            pkill -TERM -f "TMUCodexProbe" 2>/dev/null
            for _ in 1 2 3 4 5; do
                pgrep -f "TMUCodexProbe" >/dev/null 2>&1 || break
                sleep 1
            done
            if pgrep -f "TMUCodexProbe" >/dev/null 2>&1; then
                pkill -KILL -f "TMUCodexProbe" 2>/dev/null
                sleep 2
            fi
        fi
        if pgrep -f "TMUCodexProbe" >/dev/null 2>&1; then
            no "processes survived SIGKILL — leaving the bundle in place rather than"
            note "unlinking it out from under them. Kill them and rerun."
            pgrep -fl "TMUCodexProbe" | sed 's/^/      /'
        else
            ok "no probe processes remain"
            rm -rf "${TMPDIR:-/tmp}/tmu-codex-probe-profile"
            if [ -e "$PROBE" ]; then
                "$LSREG" -u "$PROBE" 2>/dev/null
                rm -rf "$PROBE" && ok "clone removed"
            fi
        fi
    fi
    # Always, even with --keep: the real app should own its scheme.
    if [ -d "$SRC" ]; then
        "$LSREG" -f "$SRC" 2>/dev/null && ok "codex:// handed back to $SRC"
    fi
    exit $code
}
trap cleanup EXIT INT TERM

say "Preflight"
[ -d "$SRC" ] || { no "no Codex Desktop at $SRC"; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$SRC/Contents/Info.plist" 2>/dev/null || echo "?")
ok "source: $SRC ($version)"

if pgrep -f "$SRC/Contents/MacOS" >/dev/null 2>&1; then
    no "ChatGPT is running. Quit it first — this re-registers codex:// at the end,"
    note "and doing that under a live process is how you get a confused handler."
    exit 1
fi
[ -e "$PROBE" ] && { no "$PROBE already exists"; exit 1; }
if pgrep -f "TMUCodexProbe" >/dev/null 2>&1; then
    no "a previous probe is still running. Its processes would be matched as this run's"
    note "result, which is exactly the mistake that made the first run of this unreliable."
    pgrep -fl "TMUCodexProbe" | sed 's/^/      /'
    exit 1
fi

say "Recording what owns codex:// now"
before=$("$LSREG" -dump 2>/dev/null | grep -A3 'codex:' | grep -o '/Applications/[^ ]*\.app' | head -1)
ok "${before:-nothing registered}"

say "Cloning"
cp -Rpc "$SRC" "$PROBE" 2>/dev/null || { no "clone failed"; exit 1; }
ok "cloned"

say "Stamping a distinct identity"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PROBE_ID" "$PROBE/Contents/Info.plist" \
    || { no "could not stamp"; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Codex Probe" \
    "$PROBE/Contents/Info.plist" 2>/dev/null
rm -f "$PROBE/Contents/embedded.provisionprofile"
ok "$PROBE_ID"

say "Stripping entitlements and re-signing ad-hoc"
# The three sign-clone.sh always removes, plus the three that are specific to Codex being a
# sandboxed, push-capable, app-grouped application.
export STRIP_KEYS="com.apple.application-identifier com.apple.developer.team-identifier \
keychain-access-groups com.apple.security.app-sandbox com.apple.security.application-groups \
com.apple.developer.aps-environment"
DST="$PROBE" SRC="$SRC" IDENTITY="-" "$ROOT/scripts/sign-clone.sh" 2>&1 \
    | grep -E 'RESULT|FAILED' | sed 's/^ */    /'

say "What the clone ended up with"
codesign -d --entitlements :- "$PROBE" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null \
    | grep '<key>' | sed 's/.*<key>/      /; s|</key>||' || note "(none)"

say "Launching"
xattr -dr com.apple.quarantine "$PROBE" 2>/dev/null
# Into a profile of its own. The first run of this went to
# ~/Library/Application Support/Codex — the real app's profile — because the clone inherits
# the compiled-in Chromium product name and nothing had told it otherwise. It was only open
# for twelve seconds and ChatGPT was not running, but a probe that writes into the profile
# of the app it is impersonating is a bad probe. --user-data-dir is a Chromium flag, which
# is the same reason the Claude shim works, so this doubles as a test of that.
PROBE_PROFILE="${TMPDIR:-/tmp}/tmu-codex-probe-profile"
rm -rf "$PROBE_PROFILE"; mkdir -p "$PROBE_PROFILE"
# -n forces a new instance. Without it `open` re-activates whatever is already running
# under this bundle and silently drops --args, so the flag under test never arrives.
open -n -a "$PROBE" --args --user-data-dir="$PROBE_PROFILE" 2>/dev/null
sleep 12

if pgrep -f "$PROBE/Contents/MacOS" >/dev/null 2>&1; then
    ok "IT RUNS — a stripped Codex clone starts"
    note "pid $(pgrep -f "$PROBE/Contents/MacOS" | head -1)"
    say "Did --user-data-dir take?"
    if [ -n "$(ls -A "$PROBE_PROFILE" 2>/dev/null)" ]; then
        ok "the clone wrote to its own profile — the shim approach transfers"
        note "$(ls -A "$PROBE_PROFILE" | wc -l | tr -d ' ') entries in $PROBE_PROFILE"
    else
        no "its own profile is empty — it is using the primary's, as Claude does without a shim"
    fi
    [ -d "$HOME/Library/Containers/$PROBE_ID" ] \
        && note "sandbox container exists: ~/Library/Containers/$PROBE_ID"
else
    no "IT DOES NOT RUN — the clone exits or never starts"
    say "Most recent crash reports"
    # shellcheck disable=SC2012
    ls -t "$HOME/Library/Logs/DiagnosticReports/"*.ips 2>/dev/null | head -3 | while read -r r; do
        case "$(basename "$r")" in
            ChatGPT*|Codex*)
                note "$(basename "$r")"
                grep -m1 -oE '"termination".*|"exception".*' "$r" 2>/dev/null \
                    | cut -c1-160 | sed 's/^/        /'
                ;;
        esac
    done
fi

say "Done"
