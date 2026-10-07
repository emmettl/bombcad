#!/bin/bash
# Builds dist/RoomCAD.app inside this package, ad-hoc signed, so it can be launched from Finder.
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-release}"
case "$configuration" in
  debug|release) ;;
  *) echo "Usage: $0 [debug|release]" >&2; exit 1 ;;
esac

swift build -c "$configuration" --product RoomCAD
binary_directory="$(swift build -c "$configuration" --show-bin-path)"

app="dist/RoomCAD.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/RoomCAD" "$app/Contents/MacOS/RoomCAD"
cp Support/Info.plist "$app/Contents/Info.plist"
# The MIT licence asks for its notice to travel with every copy.
cp ../LICENSE "$app/Contents/Resources/LICENSE"
codesign --force --sign - "$app"
echo "Built RoomCAD/$app"
