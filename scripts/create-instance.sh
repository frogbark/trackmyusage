#!/bin/bash
#
# Create an additional Claude Desktop instance with its own OS-level identity.
#
#   ./create-instance.sh "Work"            # -> /Applications/Claudruple/Work.app
#   ./create-instance.sh "Work" --launch
#
# Design notes, each earned the hard way on a real install:
#
#  * CFBundleIdentifier is the only thing that actually separates two instances.
#    macOS keys activation, Dock, notifications, TCC and LaunchServices off it. Two
#    processes sharing one identifier collide no matter how their data is separated —
#    that is why launching the stock app "does nothing" when a wrapper is already up.
#
#  * CFBundleName must stay "Claude". Electron locates its XPC helpers at
#    Contents/Frameworks/<CFBundleName> Helper.app; renaming it makes the app abort at
#    startup with "Unable to find helper app". CFBundleDisplayName carries the label
#    instead, which is what the Finder and Dock show anyway.
#
#  * The app hardcodes app.setName("Claude"), so CFBundleName cannot steer Electron's
#    userData either. Without --user-data-dir a clone opens the *primary's* profile.
#    An in-bundle shim injects the flag; exec'ing a sibling keeps this bundle's identity,
#    whereas exec'ing another app's binary (what Parall does) is precisely what collapses
#    two instances onto one identity.
#
#  * app.asar is never modified, so ElectronAsarIntegrity stays valid and no Anthropic
#    code is altered or redistributed.
#
set -euo pipefail

NAME="${1:-}"
[ -n "$NAME" ] || { echo "usage: $0 <instance-name> [--launch]" >&2; exit 1; }
LAUNCH=0; [ "${2:-}" = "--launch" ] && LAUNCH=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SRC:-/Applications/Claude.app}"
DEST_DIR="${DEST_DIR:-/Applications/Claudruple}"
IDENTITY="${IDENTITY:--}"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

slug=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')
APP="$DEST_DIR/$NAME.app"
BUNDLE_ID="com.anthropic.claudefordesktop.claudruple.$slug"
UDD="$HOME/Library/Application Support/Claudruple/$NAME"
REALBIN="$NAME Bin"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()  { printf '    \033[32m✓\033[0m %s\n' "$1"; }

say "Preflight"
[ -d "$SRC" ] || { echo "source app not found: $SRC" >&2; exit 1; }
codesign --verify --strict "$SRC" 2>/dev/null \
  || echo "    ! source signature does not verify; continuing"
[ -e "$APP" ] && { echo "already exists: $APP" >&2; exit 1; }
ok "source: $SRC ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Contents/Info.plist"))"

say "Cloning"
mkdir -p "$DEST_DIR"
# -c uses APFS clonefile: copy-on-write, so a 556 MB bundle costs well under a second
# and effectively no additional disk until one of the copies diverges.
cp -Rpc "$SRC" "$APP"
codesign --verify --deep --strict "$APP" 2>/dev/null \
  || { echo "clone is not byte-faithful; aborting" >&2; rm -rf "$APP"; exit 1; }
ok "cloned and verified faithful"

say "Stamping identity"
PL="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PL"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $NAME"     "$PL"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $NAME"      "$PL"
# CFBundleName intentionally left as "Claude" — see header.
rm -f "$APP/Contents/embedded.provisionprofile"
ok "$BUNDLE_ID"

say "Installing launcher shim"
mv "$APP/Contents/MacOS/Claude" "$APP/Contents/MacOS/$REALBIN"
mkdir -p "$UDD"
clang -arch arm64 -O2 -Wall -Wextra \
  -DREAL_BINARY="\"$REALBIN\"" -DUSER_DATA_DIR="\"$UDD\"" \
  -o "$APP/Contents/MacOS/$NAME" "$ROOT/src/launcher/launcher.c"
ok "data dir: $UDD"

say "Signing"
DST="$APP" SRC="$SRC" IDENTITY="$IDENTITY" "$ROOT/scripts/sign-clone.sh" 2>&1 \
  | grep -E 'RESULT|FAILED' | sed 's/^ */    /'

say "Registering"
# Without this the bundle inherits quarantine and Gatekeeper runs it from a randomised
# read-only AppTranslocation path — the failure mode that breaks Parall's stub.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
"$LSREG" -f "$APP"
ok "registered, quarantine cleared"

if [ "$LAUNCH" = "1" ]; then
  say "Launching"
  open -a "$APP"; sleep 8
  pgrep -f "$REALBIN" >/dev/null && ok "running" || echo "    ! did not start — see ~/Library/Logs/DiagnosticReports"
fi

printf '\n\033[1mCreated %s\033[0m\n  bundle id: %s\n  data dir:  %s\n\n' "$APP" "$BUNDLE_ID" "$UDD"
