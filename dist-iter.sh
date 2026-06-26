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

DEVICES=(
  "4AEB8C9B-A879-599E-A1F4-FCFCFE7E5B02"  # Bugsy's iPad (Air 5)
  "83BD400B-DBBC-5EA5-9B60-CC210A4D2021"  # Gill iPhone 14 Pro Max
  "6DE2C9EC-36F0-5916-9B87-875E5E310D43"  # Gill iPad (A16)
  "F8B770E6-60A9-5FCE-9266-D63B7BFB0840"  # Gill iPad Pro 11"
)

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
for d in "${DEVICES[@]}"; do
  if xcrun devicectl device install app --device "$d" "$IOS_APP" >/tmp/mag-install-$d.log 2>&1; then
    echo "  ✓ installed → $d"
  else
    echo "  ✗ skipped  → $d (unreachable or not provisioned; /tmp/mag-install-$d.log)"
  fi
done
echo "done."
