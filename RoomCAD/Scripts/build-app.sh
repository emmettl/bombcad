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
# Resource bundles, such as the bundled dry recordings. SwiftPM's accessor looks in the app's Resources
# directory; nothing may sit at the app's root, or signing fails.
for bundle in "$binary_directory"/RoomCAD_*.bundle; do
  cp -R "$bundle" "$app/Contents/Resources/"
done
test -f "$app/Contents/Resources/RoomCAD_Audition.bundle/Contents/Resources/Clips/clips.json" || {
  echo "The app is missing its bundled clips." >&2
  exit 1
}
codesign --force --sign - "$app"
echo "Built RoomCAD/$app"
