#!/bin/bash
# Iteration distribution helper (used while developing the LAN peer-sync feature).
# Builds Magnatune for Mac Catalyst + iOS device, copies the Catalyst app to the
# Desktop, and installs the device build to every reachable registered device.
#
#   ./dist-iter.sh            # build both, then distribute
#   ./dist-iter.sh --no-build # distribute the existing builds only
#
# NOT a release build (Debug, signed for development, not notarized).

set -u
cd "$(dirname "$0")"

# Registered dev devices to install to — CoreDevice IDs (`xcrun devicectl list devices`).
# These are per-developer, so they live in an untracked file rather than in git.
# Create dist-devices.local beside this script with lines like:
#   DEVICES+=("XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX")   # my iPad
DEVICES=()
[[ -f dist-devices.local ]] && source dist-devices.local

CAT_APP="build/Build/Products/Debug-maccatalyst/Magnatune.app"
IOS_APP="build-ios/Build/Products/Debug-iphoneos/Magnatune.app"
DESKTOP_APP="$HOME/Desktop/Magnatune.app"

if [[ "${1:-}" != "--no-build" ]]; then
  echo "▶ xcodegen generate"
  xcodegen generate >/dev/null || { echo "✗ xcodegen failed"; exit 1; }

  echo "▶ building Mac Catalyst…"
  xcodebuild -project Magnatune.xcodeproj -scheme Magnatune \
    -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
    -derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages \
    -allowProvisioningUpdates build >/tmp/mag-cat-build.log 2>&1 \
    || { echo "✗ Catalyst build FAILED (see /tmp/mag-cat-build.log)"; grep -E "error:" /tmp/mag-cat-build.log | head; exit 1; }
  echo "  ✓ Catalyst BUILD SUCCEEDED"

  echo "▶ building iOS device…"
  xcodebuild -project Magnatune.xcodeproj -scheme Magnatune \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build-ios -clonedSourcePackagesDirPath build/SourcePackages \
    -allowProvisioningUpdates build >/tmp/mag-ios-build.log 2>&1 \
    || { echo "✗ iOS build FAILED (see /tmp/mag-ios-build.log)"; grep -E "error:" /tmp/mag-ios-build.log | head; exit 1; }
  echo "  ✓ iOS BUILD SUCCEEDED"
fi

# Desktop copy (the "new version on the Desktop")
echo "▶ refreshing Desktop app…"
pkill -9 -f "Magnatune.app/Contents/MacOS/Magnatune" 2>/dev/null
rm -rf "$DESKTOP_APP"
cp -R "$CAT_APP" "$DESKTOP_APP"
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DESKTOP_APP/Contents/Info.plist" 2>/dev/null)
BLD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$DESKTOP_APP/Contents/Info.plist" 2>/dev/null)
echo "  ✓ ~/Desktop/Magnatune.app  (v$VER build $BLD)"

# Install to every reachable device
echo "▶ installing to devices…"
if [[ ${#DEVICES[@]} -eq 0 ]]; then
  echo "  (no devices configured — see the dist-devices.local note near the top of this script)"
fi
for d in ${DEVICES[@]+"${DEVICES[@]}"}; do
  if xcrun devicectl device install app --device "$d" "$IOS_APP" >/tmp/mag-install-$d.log 2>&1; then
    echo "  ✓ installed → $d"
  else
    echo "  ✗ skipped  → $d (unreachable or not provisioned; /tmp/mag-install-$d.log)"
  fi
done
echo "done."
