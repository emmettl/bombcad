#!/bin/bash
# Builds dist/BombCAD-iPad.app, BombCAD as an iPad's viewer of runs kept on a Mac nearby
# (emmettl/bombcad-work#43): the package's BombCAD target built for iPadOS, its executable and
# resource bundles put in an app bundle with Support/Viewer-Info.plist.
#
# For the iOS Simulator, ad hoc signed:
#   Scripts/build-ipad-viewer.sh [debug|release]
#   xcrun simctl install booted dist/BombCAD-iPad.app && xcrun simctl launch booted dev.bombcad.viewer
#
# For a real iPad, signed for development by the team (BOMBCAD_IPAD_TEAM, UCF9FS9FWW) with its
# "Apple Development" certificate and a development provisioning profile that Xcode keeps for it
# (one for dev.bombcad.viewer, or the team's wildcard), which must list the iPad:
#   Scripts/build-ipad-viewer.sh --device [debug|release]
#   xcrun devicectl device install app --device <id> dist/BombCAD-iPad-device.app
#   xcrun devicectl device process launch --device <id> dev.bombcad.viewer
# BOMBCAD_IPAD_PROFILE names a .mobileprovision to use instead; BOMBCAD_IPAD_IDENTITY a signing
# identity (its name or SHA-1) instead of the team's Apple Development one.
set -euo pipefail
cd "$(dirname "$0")/.."

device=0
if [ "${1:-}" = "--device" ]; then
  device=1
  shift
fi
configuration="${1:-release}"
case "$configuration" in
  debug) xcode_configuration=Debug ;;
  release) xcode_configuration=Release ;;
  *) echo "Usage: $0 [--device] [debug|release]" >&2; exit 1 ;;
esac

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Support/Viewer-Info.plist)
team="${BOMBCAD_IPAD_TEAM:-UCF9FS9FWW}"

# Xcode's derived data in the build folder, linked first (Scripts/build-dir.py: on the Studio, off the
# boot disk).
python3 Scripts/build-dir.py path >/dev/null

if [ "$device" = 1 ]; then
  derived="${BOMBCAD_IPAD_DERIVED:-.build/ipad-device}"
  xcodebuild build -scheme BombCAD -configuration "$xcode_configuration" \
    -destination 'generic/platform=iOS' -derivedDataPath "$derived" ARCHS=arm64 \
    CODE_SIGNING_ALLOWED=NO -quiet
  products="$derived/Build/Products/$xcode_configuration-iphoneos"
  app="dist/BombCAD-iPad-device.app"
  platform=iPhoneOS
  sdk=iphoneos
else
  derived="${BOMBCAD_IPAD_DERIVED:-.build/ipad}"
  xcodebuild build -scheme BombCAD -configuration "$xcode_configuration" \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" ARCHS=arm64 -quiet
  products="$derived/Build/Products/$xcode_configuration-iphonesimulator"
  app="dist/BombCAD-iPad.app"
  platform=iPhoneSimulator
  sdk=iphonesimulator
fi

rm -rf "$app"
mkdir -p "$app"
cp "$products/BombCAD" "$app/BombCAD"
cp Support/Viewer-Info.plist "$app/Info.plist"
# What Xcode's own app builds say of the platform and SDK, which installing on a device checks.
/usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" \
  -c "Add :CFBundleSupportedPlatforms:0 string $platform" \
  -c "Add :DTPlatformName string $sdk" \
  -c "Add :DTSDKName string $sdk$(xcrun --sdk "$sdk" --show-sdk-version)" \
  -c "Add :DTPlatformVersion string $(xcrun --sdk "$sdk" --show-sdk-version)" "$app/Info.plist"
cp LICENSE "$app/LICENSE"
# The shaders, compiled at run time, in the resource bundles SwiftPM's accessor finds at the
# app's root on iPadOS.
for bundle in "$products"/*.bundle; do
  cp -R "$bundle" "$app/$(basename "$bundle")"
done

if [ "$device" = 0 ]; then
  codesign --force --sign - "$app"
  echo "Built $app"
  exit 0
fi

# The development profile for this app: BOMBCAD_IPAD_PROFILE, else the latest-expiring one Xcode
# keeps for the team that names this bundle id, else the team's wildcard.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
profile="${BOMBCAD_IPAD_PROFILE:-}"
if [ -z "$profile" ]; then
  profile=$(python3 -I - "$team" "$bundle_id" <<'PY'
import datetime, glob, os, plistlib, subprocess, sys
team, bundle = sys.argv[1], sys.argv[2]
best = None
for path in glob.glob(os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.mobileprovision")) \
        + glob.glob(os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles/*.mobileprovision")):
    raw = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True).stdout
    try:
        p = plistlib.loads(raw)
    except Exception:
        continue
    e = p.get("Entitlements", {})
    if team not in p.get("TeamIdentifier", []) or "iOS" not in p.get("Platform", []):
        continue
    if not e.get("get-task-allow") or p["ExpirationDate"] < datetime.datetime.now():
        continue
    app_id = e.get("application-identifier", "")
    rank = 2 if app_id == f"{team}.{bundle}" else 1 if app_id == f"{team}.*" else 0
    if rank and (best is None or (rank, p["ExpirationDate"]) > best[0]):
        best = ((rank, p["ExpirationDate"]), path)
print(best[1] if best else "")
PY
)
fi
if [ -z "$profile" ]; then
  echo "No development provisioning profile of team $team for $bundle_id or its wildcard." >&2
  echo "Open any iOS project of the team in Xcode, run it on the iPad once, and build again." >&2
  exit 1
fi
cp "$profile" "$app/embedded.mobileprovision"
security cms -D -i "$profile" >"$scratch/profile.plist"
echo "Profile: $(/usr/libexec/PlistBuddy -c 'Print :Name' "$scratch/profile.plist")"

# The entitlements the profile grants, for this bundle id: the Keychain group the pairings go in.
cat >"$scratch/entitlements.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>$team.$bundle_id</string>
	<key>com.apple.developer.team-identifier</key>
	<string>$team</string>
	<key>get-task-allow</key>
	<true/>
	<key>keychain-access-groups</key>
	<array>
		<string>$team.$bundle_id</string>
	</array>
</dict>
</plist>
PLIST

identity="${BOMBCAD_IPAD_IDENTITY:-}"
if [ -z "$identity" ]; then
  # The team's Apple Development certificate: its subject's organisational unit is the team.
  while read -r hash name; do
    subject=$(security find-certificate -c "$name" -p | openssl x509 -noout -subject 2>/dev/null || true)
    if [[ "$subject" == *"OU=$team"* || "$subject" == *"OU = $team"* ]]; then
      identity="$hash"
      break
    fi
  done < <(security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) \([0-9A-F]*\) "\(Apple Development:.*\)"$/\1 \2/p')
fi
if [ -z "$identity" ]; then
  echo "No Apple Development certificate of team $team in the keychain." >&2
  echo "Add the team's account in Xcode ▸ Settings ▸ Accounts and Manage Certificates ▸ +." >&2
  exit 1
fi
codesign --force --sign "$identity" --entitlements "$scratch/entitlements.plist" "$app"
codesign --verify --strict "$app"
echo "Built $app, signed for team $team"
