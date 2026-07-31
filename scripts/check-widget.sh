#!/bin/bash
# Structural check on the assembled widget extension.
#
# `swift build` and `swift test` cannot see any of this: the .appex exists only once
# build-app.sh has assembled it, and every failure mode below is silent. A widget with a
# missing plist key does not warn, does not log, and does not appear — so this is the only
# place a mistake in the bundle can be caught.
#
# Every check here passes under an ad-hoc signature, which is what lets CI run them on a
# runner with no signing identity. The one thing that genuinely needs a real certificate — a
# live round-trip through the group container — is guarded behind IDENTITY at the end.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/widget-identity.sh
. "$ROOT/scripts/lib/widget-identity.sh"

OUT="${OUT:-$ROOT/build}"
IDENTITY="${IDENTITY:--}"
APP="${APP:-$OUT/TrackMyUsage.app}"
APPEX="$APP/Contents/PlugIns/TMUWidgetExtension.appex"
PLIST="$APPEX/Contents/Info.plist"

fail() { echo "  FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

[ -d "$APP" ] || fail "no app at $APP — run ./scripts/build-app.sh first"

GROUP="$(tmu_app_group "$IDENTITY")"
if [ -z "$GROUP" ]; then
    # Mirrors build-widget.sh. An ad-hoc build has no widget by design, so demanding one here
    # would fail every contributor without a certificate for a fault that does not exist.
    if [ -d "$APPEX" ]; then
        fail "an ad-hoc build produced an .appex; it cannot carry an App Group and must be skipped"
    fi
    echo "widget: skipped (no signing identity) — app checked, extension not built"
    codesign --verify --strict "$APP" >/dev/null 2>&1 && ok "app signature valid"
    exit 0
fi

echo "widget: checking $APPEX"

[ -d "$APPEX" ] || fail "no .appex — build-app.sh should have embedded one"
ok "extension present"

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }

# The four keys whose absence registers nothing and says nothing.
[ "$(plist_get 'NSExtension:NSExtensionPointIdentifier')" = "com.apple.widgetkit-extension" ] \
    || fail "NSExtensionPointIdentifier is not com.apple.widgetkit-extension"
ok "extension point"

[ "$(plist_get 'CFBundlePackageType')" = "XPC!" ] || fail "CFBundlePackageType must be XPC!"
ok "package type"

[ -n "$(plist_get 'CFBundleInfoDictionaryVersion')" ] \
    || fail "CFBundleInfoDictionaryVersion missing — PlugInKit registers nothing without it"
ok "info dictionary version"

[ "$(plist_get 'CFBundleSupportedPlatforms:0')" = "MacOSX" ] \
    || fail "CFBundleSupportedPlatforms must list MacOSX — PlugInKit registers nothing without it"
ok "supported platforms"

# An extension whose identifier is not prefixed by its host's is rejected without explanation.
EXT_ID="$(plist_get 'CFBundleIdentifier')"
case "$EXT_ID" in
    "$TMU_APP_BUNDLE_ID".*) ok "bundle id prefixed by host ($EXT_ID)" ;;
    *) fail "extension id '$EXT_ID' is not prefixed by '$TMU_APP_BUNDLE_ID'" ;;
esac

[ "$(plist_get 'TMUAppGroupIdentifier')" = "$GROUP" ] \
    || fail "appex TMUAppGroupIdentifier does not match $GROUP"
[ "$(/usr/libexec/PlistBuddy -c 'Print :TMUAppGroupIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)" = "$GROUP" ] \
    || fail "app TMUAppGroupIdentifier does not match $GROUP"
ok "app and extension agree on the group"

ents() { codesign -d --entitlements :- "$1" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null; }

ents "$APPEX" | grep -q "com.apple.security.app-sandbox" \
    || fail "extension is not sandboxed — macOS requires it of widget extensions"
ents "$APPEX" | grep -q "$GROUP" || fail "extension entitlements lack the app group"
ok "extension entitlements"

# The app must NOT be sandboxed: it reads /Applications, shells out to launchctl and uses the
# keychain. If this ever starts passing, instance management has silently broken.
ents "$APP" | grep -q "com.apple.security.app-sandbox" \
    && fail "the app is sandboxed; it must not be (instance discovery and keychain would break)"
ents "$APP" | grep -q "$GROUP" || fail "app entitlements lack the app group"
ok "app entitlements (unsandboxed, group present)"

codesign --verify --deep --strict "$APP" || fail "nested signature invalid"
ok "nested signature valid"

otool -L "$APPEX/Contents/MacOS/TMUWidgetExtension" 2>/dev/null | grep -q "WidgetKit" \
    || fail "extension does not link WidgetKit"
ok "links WidgetKit"

# Needs a real certificate, so it is not part of the CI gate.
if [ "$IDENTITY" != "-" ]; then
    CONTAINER="$HOME/Library/Group Containers/$GROUP"
    if [ -d "$CONTAINER" ]; then
        ok "group container exists ($CONTAINER)"
    else
        echo "  note: group container not created yet — it appears when the app first runs"
    fi
fi

echo "widget: ok"
