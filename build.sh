#!/bin/bash
# Build ClipKeep.app from main.swift. Requires the Xcode command line
# tools (for swiftc): if swiftc is missing, run `xcode-select --install`.
set -e
cd "$(dirname "$0")"

APP="ClipKeep.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -o "$APP/Contents/MacOS/ClipKeep" main.swift \
    -framework Cocoa -framework Carbon -framework ApplicationServices \
    -framework Vision -framework UniformTypeIdentifiers

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ClipKeep</string>
    <key>CFBundleDisplayName</key>
    <string>ClipKeep</string>
    <key>CFBundleIdentifier</key>
    <string>io.starterdev.clipkeep</string>
    <key>CFBundleVersion</key>
    <string>2.9.0</string>
    <key>CFBundleShortVersionString</key>
    <string>2.9.0</string>
    <key>CFBundleExecutable</key>
    <string>ClipKeep</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature so Gatekeeper treats it as a local build.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $APP — drag it into Applications and double-click to run."
echo "First launch: if macOS blocks it, right-click the app and choose Open."
