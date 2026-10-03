#!/bin/sh
# Builds a release binary and wraps it in build/BombCAD.app so it can be launched from Finder.
set -eu

cd "$(dirname "$0")/.."
swift build -c release --product BombCAD
bin="$(swift build -c release --show-bin-path)"

app="build/BombCAD.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/BombCAD" "$app/Contents/MacOS/BombCAD"
cp -R "$bin"/BombCAD_*.bundle "$app/Contents/Resources/"
# The icon is drawn by Scripts/make-icon.swift.
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BombCAD</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>dev.bombcad.BombCAD</string>
    <key>CFBundleName</key>
    <string>BombCAD</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "Built $app"
