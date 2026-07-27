#!/bin/bash
# Build Claudruple.app — the menu bar app.
#
# SPM produces a bare executable; MenuBarExtra, notifications and window restoration all
# need a real bundle with an Info.plist, so it is assembled here rather than adding an
# Xcode project to maintain alongside the package.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/build}"
IDENTITY="${IDENTITY:--}"

APP="$OUT/Claudruple.app"
NAME="Claudruple"
BUNDLE_ID="com.claudruple.app"

echo "==> building"
( cd "$ROOT" && swift build -c release --product ClaudrupleApp )

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/ClaudrupleApp" "$APP/Contents/MacOS/$NAME"

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
    <key>LSMinimumSystemVersion</key><string>13.0</string>

    <!-- Menu bar resident: no Dock icon. The window is opened from the menu when wanted,
         and an app whose whole point is an always-visible gauge should not also occupy
         the Dock. -->
    <key>LSUIElement</key><true/>

    <key>NSHumanReadableCopyright</key><string>Apache-2.0</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> signing ($IDENTITY)"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP" && echo "    signature valid"

echo "==> built: $APP"
