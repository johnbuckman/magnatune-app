#!/bin/bash
# Build the Magnatune Mac Catalyst app into a signed + notarized DMG you can
# hand to anyone (Developer ID, Gatekeeper-clean). Apple Silicon + Intel.
#
# Mirrors John's bping/MySQL-Update approach: build UNSIGNED, then re-sign every
# nested Mach-O explicitly (NOT --deep), then the bundle, all with hardened
# runtime + timestamp + entitlements. Zip for the notary upload, staple the
# unzipped .app, build the DMG, notarize + staple the DMG, drop it on the Desktop.
#
# Env overrides:
#   MAG_SIGN_ID         codesign identity (default: Developer ID Application: Vid Tadel ...)
#   MAG_NOTARY_PROFILE  notarytool keychain profile (default: bping-notary)
#   MAG_NO_NOTARIZE=1   sign only, skip the Apple notary round-trip (for quick local tests)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APPNAME="Magnatune"
ENT="$ROOT/Magnatune/App/Magnatune.entitlements"
DERIVED="$ROOT/build-osx"
PRODUCT="$DERIVED/Build/Products/Release-maccatalyst/$APPNAME.app"
DESKTOP="$HOME/Desktop"

ID="${MAG_SIGN_ID:-Developer ID Application: Vid Tadel (XLS3XF57J8)}"
NOTARY_PROFILE="${MAG_NOTARY_PROFILE:-bping-notary}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :MARKETING_VERSION' /dev/stdin 2>/dev/null <<<"" || true)"
VERSION="$(grep -m1 'MARKETING_VERSION' "$ROOT/project.yml" | sed 's/.*"\(.*\)".*/\1/')"
[ -n "$VERSION" ] || VERSION="0.1.0"
DMG="$DESKTOP/Magnatune-v$VERSION.dmg"

security find-identity -v -p codesigning 2>/dev/null | grep -q "$ID" || {
  echo "Signing identity not in keychain: $ID"; exit 1; }
[ -f "$ENT" ] || { echo "Missing entitlements: $ENT"; exit 1; }

echo "==> Building $APPNAME.app (Release, Mac Catalyst, universal, unsigned)"
xcodebuild -project "$ROOT/Magnatune.xcodeproj" -scheme "$APPNAME" \
  -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$ROOT/build/SourcePackages" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build
[ -d "$PRODUCT" ] || { echo "Build failed: $PRODUCT missing"; exit 1; }

# Work on a copy so the build product stays pristine.
APP="$DERIVED/$APPNAME.app"
rm -rf "$APP"
cp -R "$PRODUCT" "$APP"

# Strip extended attributes / resource forks (codesign rejects "detritus").
xattr -cr "$APP"
find "$APP" -name '._*' -delete 2>/dev/null || true

echo "==> Codesigning every nested Mach-O binary"
while IFS= read -r -d '' f; do
  if file -b "$f" 2>/dev/null | grep -q "Mach-O"; then
    codesign --force --options runtime --timestamp \
      --entitlements "$ENT" --sign "$ID" "$f" >/dev/null
  fi
done < <(find "$APP" -type f -print0)

# Any nested helper apps / frameworks (none today, but be robust).
for h in "$APP/Contents/Frameworks"/*.app; do
  [ -d "$h" ] || continue
  codesign --force --options runtime --timestamp \
    --entitlements "$ENT" --sign "$ID" "$h" >/dev/null
done
for fw in "$APP/Contents/Frameworks"/*.framework; do
  [ -d "$fw" ] || continue
  codesign --force --options runtime --timestamp --sign "$ID" "$fw" >/dev/null
done

echo "==> Codesigning the app bundle"
codesign --force --options runtime --timestamp \
  --entitlements "$ENT" --sign "$ID" "$APP" >/dev/null
codesign --verify --deep --strict --verbose=2 "$APP"
echo "==> Signed."

if [ "${MAG_NO_NOTARIZE:-0}" != "1" ]; then
  echo "==> Notarizing $APPNAME.app (Apple notary queue — typically 1–5 min)…"
  ZIP="$DERIVED/magnatune-for-notary.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  OUT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
  echo "$OUT"
  rm -f "$ZIP"
  echo "$OUT" | grep -q "status: Accepted" || { echo "Notarization NOT accepted"; exit 1; }
  xcrun stapler staple "$APP"
  echo "==> App stapled."
else
  echo "==> Skipping notarization (MAG_NO_NOTARIZE=1)."
fi

echo "==> Building DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APPNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> Signing DMG"
codesign --force --timestamp --sign "$ID" "$DMG"

if [ "${MAG_NO_NOTARIZE:-0}" != "1" ]; then
  echo "==> Notarizing DMG"
  OUT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
  echo "$OUT"
  echo "$OUT" | grep -q "status: Accepted" || { echo "DMG notarization NOT accepted"; exit 1; }
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "==> DMG stapled."
fi

# Also drop a stapled standalone .app on the Desktop for convenience.
rm -rf "$DESKTOP/$APPNAME.app"
cp -R "$APP" "$DESKTOP/$APPNAME.app"

echo ""
echo "==> DONE"
echo "    DMG: $DMG ($(du -h "$DMG" | awk '{print $1}'))"
echo "    App: $DESKTOP/$APPNAME.app"
echo "==> Gatekeeper assessment:"
spctl --assess --type execute --verbose "$DESKTOP/$APPNAME.app" 2>&1 | sed 's/^/    /' || true
