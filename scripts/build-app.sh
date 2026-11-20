#!/bin/bash
# Builds "ScrCapKit.app" into ./build (hardened runtime, signed).
#
#   ./scripts/build-app.sh               release build, ad-hoc signed (for this Mac)
#   ./scripts/build-app.sh --open        build, then launch it
#   ./scripts/build-app.sh --dmg         also make build/ScrCapKit-<version>.dmg
#
# Environment:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"   sign for distribution
#   NOTARY_PROFILE="scrcapkit"   notarize + staple the DMG (create the profile once with
#                                `xcrun notarytool store-credentials scrcapkit`)
#   UNIVERSAL=1                  build for Apple silicon and Intel
set -euo pipefail
cd "$(dirname "$0")/.."

OPEN=0; DMG=0
for arg in "$@"; do
  case "$arg" in
    --open) OPEN=1 ;;
    --dmg) DMG=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

CONFIG="${CONFIG:-release}"
APP="build/ScrCapKit.app"
BUNDLE_ID="com.tawfiq.scrcapkit"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
IDENTITY="${SIGN_IDENTITY:--}"

if [ "${UNIVERSAL:-0}" = "1" ]; then
  ARCHS="arm64 x86_64"
else
  ARCHS="$(uname -m)"
fi

BINARIES=()
for ARCH in $ARCHS; do
  echo "→ Compiling ($CONFIG, $ARCH)..."
  swift build -c "$CONFIG" --arch "$ARCH"
  BINARIES+=("$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)/ScrCapKit")
done

echo "→ Assembling $APP (v$VERSION)..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "${#BINARIES[@]}" -gt 1 ]; then
  lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/ScrCapKit"
else
  cp "${BINARIES[0]}" "$APP/Contents/MacOS/ScrCapKit"
fi
cp Support/Info.plist "$APP/Contents/Info.plist"
if [ -f Support/AppIcon.icns ]; then
  cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null
fi

echo "→ Signing (${IDENTITY/-/ad-hoc}, hardened runtime)..."
SIGN_ARGS=(--force --options runtime --timestamp --entitlements Support/ScrCapKit.entitlements)
if [ "$IDENTITY" = "-" ]; then
  # Ad-hoc: pin the identity to the bundle ID (not the code hash) so macOS keeps the
  # Screen Recording permission across rebuilds. No timestamp for ad-hoc signatures.
  codesign --force --options runtime --entitlements Support/ScrCapKit.entitlements \
    --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
else
  codesign "${SIGN_ARGS[@]}" --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"
echo "✓ Built $APP"

if [ "$DMG" = "1" ]; then
  DMG_PATH="build/ScrCapKit-$VERSION.dmg"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG_PATH"
  hdiutil create -volname "ScrCapKit $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
  rm -rf "$STAGE"
  if [ "$IDENTITY" != "-" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
  fi
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ "$IDENTITY" = "-" ]; then
      echo "Notarization needs SIGN_IDENTITY set to a Developer ID certificate." >&2
      exit 1
    fi
    echo "→ Notarizing (this can take a few minutes)..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
  fi
  echo "✓ Built $DMG_PATH"
fi

if [ "$OPEN" = "1" ]; then
  pkill -x ScrCapKit 2>/dev/null || true
  sleep 0.5
  open "$APP"
fi
