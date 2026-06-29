#!/usr/bin/env bash
# Build a double-clickable SpotifySanitizer.app around the release binary.
# No Xcode required — just the Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")"

APP="SpotifySanitizer.app"
PRODUCT="SpotifySanitizer"

echo "Building release binary..."
swift build -c release --product "$PRODUCT"
BIN="$(swift build -c release --product "$PRODUCT" --show-bin-path)/$PRODUCT"

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"

echo "Rendering app icon..."
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift Resources/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Spotify Sanitizer</string>
    <key>CFBundleDisplayName</key>     <string>Spotify Sanitizer</string>
    <key>CFBundleIdentifier</key>      <string>nl.defrog.spotify-sanitizer</string>
    <key>CFBundleExecutable</key>      <string>SpotifySanitizer</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "Built $(pwd)/$APP"
echo "Open it with:  open $APP"
