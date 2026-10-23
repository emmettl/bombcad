#!/bin/bash
# Builds dist/BombCAD-iPad.app, BombCAD as an iPad's viewer of runs kept on a Mac nearby
# (emmettl/bombcad-work#43), for the iOS Simulator, ad-hoc signed. The package's BombCAD target
# built for iPadOS, its executable and resource bundles put in an app bundle with
# Support/Viewer-Info.plist. A real iPad needs a development team's signing; this script does not
# do that.
#
#   Scripts/build-ipad-viewer.sh [debug|release]
#   xcrun simctl install booted dist/BombCAD-iPad.app && xcrun simctl launch booted dev.bombcad.viewer
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-release}"
case "$configuration" in
  debug) xcode_configuration=Debug ;;
  release) xcode_configuration=Release ;;
  *) echo "Usage: $0 [debug|release]" >&2; exit 1 ;;
esac

derived="${BOMBCAD_IPAD_DERIVED:-.build/ipad}"
xcodebuild build -scheme BombCAD -configuration "$xcode_configuration" \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" ARCHS=arm64 -quiet
products="$derived/Build/Products/$xcode_configuration-iphonesimulator"

app="dist/BombCAD-iPad.app"
rm -rf "$app"
mkdir -p "$app"
cp "$products/BombCAD" "$app/BombCAD"
cp Support/Viewer-Info.plist "$app/Info.plist"
cp LICENSE "$app/LICENSE"
# The shaders, compiled at run time, in the resource bundles SwiftPM's accessor finds at the
# app's root on iPadOS.
for bundle in "$products"/*.bundle; do
  cp -R "$bundle" "$app/$(basename "$bundle")"
done
codesign --force --sign - "$app"
echo "Built $app"
