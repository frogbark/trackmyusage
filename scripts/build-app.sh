#!/bin/bash
# Build TrackMyUsage.app — the menu bar app.
#
# SPM produces a bare executable; MenuBarExtra, notifications and window restoration all
# need a real bundle with an Info.plist, so it is assembled here rather than adding an
# Xcode project to maintain alongside the package.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/widget-identity.sh
. "$ROOT/scripts/lib/widget-identity.sh"

OUT="${OUT:-$ROOT/build}"
IDENTITY="${IDENTITY:--}"

APP="$OUT/TrackMyUsage.app"
NAME="TrackMyUsage"
BUNDLE_ID="$TMU_APP_BUNDLE_ID"
GROUP="$(tmu_app_group "$IDENTITY")"

echo "==> building"
( cd "$ROOT" && swift build -c release --product TMUApp )

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/TMUApp" "$APP/Contents/MacOS/$NAME"

# Built with printf rather than inline in the plist heredoc, for two separate reasons that
# both produce silent breakage:
#
#   A ${VAR:+...} spanning several lines inside an expanding heredoc emits its own body
#   verbatim when the variable is empty, yielding a plist containing the literal "$GROUP".
#
#   And $(cat <<HEREDOC) cannot contain an apostrophe. Bash scans the substitution for a
#   matching quote before the heredoc is processed, so one in a comment ends the script with
#   "unexpected EOF" pointing at an unrelated line.
GROUP_KEY=""
if [ -n "$GROUP" ]; then
    GROUP_KEY=$(printf '\n    <!-- Read by SharedContainer: the app writes telemetry where the\n         widget can read it. Written here, not compiled in, because it\n         carries the signing team ID. -->\n    <key>TMUAppGroupIdentifier</key><string>%s</string>' "$GROUP")
fi

echo "==> writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>

    <!-- Menu bar resident: no Dock icon. The window is opened from the menu when wanted,
         and an app whose whole point is an always-visible gauge should not also occupy
         the Dock. -->
    <key>LSUIElement</key><true/>
$GROUP_KEY
    <key>NSHumanReadableCopyright</key><string>Apache-2.0</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# The widget extension, embedded before the app is signed. Skips itself on an ad-hoc build.
OUT="$OUT" APP="$APP" IDENTITY="$IDENTITY" "$ROOT/scripts/build-widget.sh"

# The app declares the App Group but is NOT sandboxed, and must not become so. It reads
# /Applications to find instances, shells out to launchctl, and talks to the keychain; the
# sandbox would take all three away. An unsandboxed process shares a group container with a
# sandboxed one perfectly well — the entitlement grants the path, the sandbox is what makes it
# the *only* path, and only the extension needs that.
ENT=""
if [ -n "$GROUP" ]; then
    ENT="$(mktemp -t tmu-app-ent)"
    trap 'rm -f "$ENT"' EXIT
    cat > "$ENT" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array><string>$GROUP</string></array>
</dict>
</plist>
ENTITLEMENTS
fi

# Inside-out: the appex is nested code and is already signed above. Signing the app first
# would invalidate it — the same rule sign-clone.sh states for the instance launcher.
echo "==> signing ($IDENTITY)"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
    ${ENT:+--entitlements "$ENT"} "$APP"
codesign --verify --deep --strict "$APP" && echo "    signature valid"

echo "==> built: $APP"
