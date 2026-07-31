#!/bin/bash
# Assemble and sign TMUWidgetExtension.appex.
#
# Called by build-app.sh, which embeds the result in TrackMyUsage.app/Contents/PlugIns and
# then signs the app around it. Runnable alone for iteration.
#
# Every non-obvious key below was established empirically, and each one fails silently when
# wrong — there is no error message anywhere for a widget that simply never appears.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/widget-identity.sh
. "$ROOT/scripts/lib/widget-identity.sh"

OUT="${OUT:-$ROOT/build}"
IDENTITY="${IDENTITY:--}"
APP="${APP:-$OUT/TrackMyUsage.app}"
APPEX="$APP/Contents/PlugIns/TMUWidgetExtension.appex"
NAME="TMUWidgetExtension"

GROUP="$(tmu_app_group "$IDENTITY")"

if [ -z "$GROUP" ]; then
    # Not a failure. An ad-hoc signature cannot carry com.apple.security.application-groups,
    # and without a group container the widget has nothing to read. The app is still complete
    # and still works; `tmu doctor` reports this case as a build without a signing identity
    # rather than as damage.
    echo "==> widget: skipped (no signing identity; set IDENTITY= to build it)"
    exit 0
fi

echo "==> building $NAME"
( cd "$ROOT" && swift build -c release --product "$NAME" >/dev/null )

rm -rf "$APPEX"
mkdir -p "$APPEX/Contents/MacOS"
cp "$ROOT/.build/release/$NAME" "$APPEX/Contents/MacOS/$NAME"

echo "==> writing appex Info.plist (group: $GROUP)"
cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>Usage</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$TMU_WIDGET_BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>

    <!-- XPC! rather than APPL: an app extension is not an application, and LaunchServices
         files it by this. -->
    <key>CFBundlePackageType</key><string>XPC!</string>

    <!-- These two look like boilerplate Xcode emits for tidiness. They are not. Without
         either of them PlugInKit registers nothing at all, logs nothing at all, and the
         widget is simply missing from the picker with no diagnostic anywhere. Established by
         diffing this plist against Calculator's working one. -->
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>

    <!-- Read by SharedContainer at runtime. Written here rather than compiled in because it
         contains the signing team's ID, which differs per developer. -->
    <key>TMUAppGroupIdentifier</key><string>$GROUP</string>

    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
PLIST

# The extension is sandboxed because macOS requires it of widget extensions, not by choice.
# That is the whole reason an App Group exists here: a sandboxed process cannot read the
# caches directory the app keeps its snapshots in.
#
# Note that app-sandbox only works inside a bundle. Signing a bare executable with it produces
# a process the kernel SIGTRAPs at launch, which presents as an entitlement problem and is
# not one.
ENT="$(mktemp -t tmu-widget-ent)"
trap 'rm -f "$ENT"' EXIT
cat > "$ENT" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.application-groups</key>
    <array><string>$GROUP</string></array>
</dict>
</plist>
ENTITLEMENTS

echo "==> signing appex ($IDENTITY)"
codesign --force --sign "$IDENTITY" --entitlements "$ENT" \
    --options runtime --timestamp=none "$APPEX"
codesign --verify --strict "$APPEX" && echo "    appex signature valid"

echo "==> built: $APPEX"
