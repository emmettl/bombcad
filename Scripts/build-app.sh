#!/bin/bash
# Builds dist/BombCAD.app, ad-hoc signed, so it can be launched from Finder. Release builds for
# distribution are signed and notarized by Scripts/release.py.
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-release}"
case "$configuration" in
  debug|release) ;;
  *) echo "Usage: $0 [debug|release]" >&2; exit 1 ;;
esac

swift build -c "$configuration" --product BombCAD
binary_directory="$(swift build -c "$configuration" --show-bin-path)"

app="dist/BombCAD.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/BombCAD" "$app/Contents/MacOS/BombCAD"
cp Support/Info.plist "$app/Contents/Info.plist"
# The icon is drawn by Scripts/make-icon.swift.
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# The MIT licence asks for its notice to travel with every copy.
cp LICENSE "$app/Contents/Resources/LICENSE"
# The shaders, compiled at run time. SwiftPM's resource accessor looks for its bundles in the
# app's Resources directory first; nothing may sit at the app's root, or signing fails.
for bundle in BombCAD_BlastCore.bundle BombCAD_BlastRender.bundle SimulationKit_SceneRender.bundle; do
  cp -R "$binary_directory/$bundle" "$app/Contents/Resources/$bundle"
done
# The IFC translator is a separate, checksum-pinned native helper, never a runtime download.
python3 Scripts/prepare-ifc-converter.py
cp .build/ifc-converter/IfcConvert "$app/Contents/MacOS/IfcConvert"
cp -R Support/IFC "$app/Contents/Resources/IFC"
codesign --force --sign - "$app/Contents/MacOS/IfcConvert"
codesign --force --sign - "$app"
echo "Built $app"
