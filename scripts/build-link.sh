#!/bin/bash
# Build Claudruple Link.app — the deep-link broker.
#
# Produces a minimal LSUIElement app bundle: no Xcode project, no dependencies,
# just swiftc plus a hand-written Info.plist. Kept deliberately small so it is easy
# to audit — this is the one component that sits in the path of OAuth callbacks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/build}"
IDENTITY="${IDENTITY:--}"

APP="$OUT/Claudruple Link.app"
NAME="Claudruple Link"
BUNDLE_ID="com.claudruple.link"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "==> compiling"
# Built through SPM so the broker shares the package's toolchain settings and can depend
# on ClaudrupleKit as it grows. The .app bundle around it is still assembled by hand —
# a bundle is all this needs, and an Xcode project would be more to maintain than it earns.
( cd "$ROOT" && swift build -c release --product ClaudrupleLink )
cp "$ROOT/.build/release/ClaudrupleLink" "$APP/Contents/MacOS/$NAME"

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

    <!-- Background agent: no Dock icon, no menu bar. -->
    <key>LSUIElement</key><true/>

    <!-- Declaring these is what makes the broker an eligible default handler.
         It claims the role at launch and re-claims it when an instance steals it. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>Claude</string>
            <key>CFBundleURLSchemes</key><array><string>claude</string></array>
        </dict>
        <dict>
            <key>CFBundleURLName</key><string>MSAL</string>
            <key>CFBundleURLSchemes</key>
            <array><string>msauth.com.anthropic.claudefordesktop</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> signing ($IDENTITY)"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP" && echo "    signature valid"

echo "==> built: $APP"
