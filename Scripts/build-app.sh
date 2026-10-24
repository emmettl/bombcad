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

# This checkout's build folder linked first (Scripts/build-dir.py: on the Studio, off the boot disk).
python3 Scripts/build-dir.py path >/dev/null
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
# The shaders, compiled at run time: every resource bundle the binary links, read from the
# binary itself, so that a package's new bundle cannot be left behind. SwiftPM's resource
# accessor looks in the app's Resources directory first; nothing may sit at the app's root, or
# signing fails.
bundles="$(python3 Scripts/release.py bundles "$binary_directory/BombCAD")"
for bundle in $bundles; do
  if [ ! -d "$binary_directory/$bundle" ]; then
    echo "The build made no $bundle, which the app links." >&2
    exit 1
  fi
  cp -R "$binary_directory/$bundle" "$app/Contents/Resources/$bundle"
done
# The IFC translator is a separate, checksum-pinned native helper, never a runtime download.
python3 Scripts/prepare-ifc-converter.py
cp .build/ifc-converter/IfcConvert "$app/Contents/MacOS/IfcConvert"
cp -R Support/IFC "$app/Contents/Resources/IFC"
codesign --force --sign - "$app/Contents/MacOS/IfcConvert"
codesign --force --sign - "$app"
echo "Built $app"
