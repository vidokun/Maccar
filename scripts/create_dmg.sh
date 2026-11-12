#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

SIGN_IDENTITY="${MACCAR_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${MACCAR_NOTARY_PROFILE:-}"

# Fail fast if notarization is requested without a non-ad-hoc signing identity
if [ -n "$NOTARY_PROFILE" ] && [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Error: MACCAR_NOTARY_PROFILE is set, but MACCAR_SIGN_IDENTITY is ad-hoc (-)." >&2
    echo "Set MACCAR_SIGN_IDENTITY to a Developer ID Application identity before notarizing." >&2
    exit 1
fi

if [ -n "$NOTARY_PROFILE" ]; then
    if [ -z "${DEVELOPER_DIR:-}" ] && ! xcrun --find notarytool >/dev/null 2>&1 && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
    if ! xcrun --find notarytool >/dev/null 2>&1; then
        echo "Error: xcrun could not locate notarytool. Install Xcode or set DEVELOPER_DIR." >&2
        exit 1
    fi
fi

PLIST_PATH="$DIR/scripts/Info.plist"
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST_PATH")"
if [ -z "$APP_VERSION" ]; then
    echo "Error: Could not read CFBundleShortVersionString from $PLIST_PATH." >&2
    exit 1
fi

# Ensure app bundle is built and signed
"$DIR/scripts/package_app.sh"

BUILD_DIR="$DIR/build"
APP_DIR="$BUILD_DIR/Maccar.app"
NOTARY_TMP_ZIP="$BUILD_DIR/Maccar-notary-tmp.zip"
VERSIONED_ZIP_NAME="Maccar-v${APP_VERSION}.zip"
VERSIONED_DMG_NAME="Maccar-v${APP_VERSION}.dmg"
OUTPUT_ZIP="$BUILD_DIR/$VERSIONED_ZIP_NAME"
OUTPUT_VERSIONED_DMG="$BUILD_DIR/$VERSIONED_DMG_NAME"
OUTPUT_DMG="$BUILD_DIR/Maccar.dmg"
STAGING_DIR="$BUILD_DIR/dmg_staging"
CHECKSUMS_FILE="$BUILD_DIR/SHA256SUMS.txt"

cleanup() {
    rm -rf "$NOTARY_TMP_ZIP" "$STAGING_DIR"
}
trap cleanup EXIT

if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Zipping Maccar.app for Apple notarization..."
    rm -f "$NOTARY_TMP_ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$NOTARY_TMP_ZIP"
    echo "==> Submitting Maccar.app for Apple notarization..."
    xcrun notarytool submit "$NOTARY_TMP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "==> Stapling and validating Maccar.app notarization ticket..."
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    rm -f "$NOTARY_TMP_ZIP"
fi

echo "==> Packaging $VERSIONED_ZIP_NAME from finalized Maccar.app..."
rm -f "$OUTPUT_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$OUTPUT_ZIP"

echo "==> Preparing DMG staging area..."
rm -rf "$STAGING_DIR" "$OUTPUT_VERSIONED_DMG" "$OUTPUT_DMG"
mkdir -p "$STAGING_DIR"

# Copy app bundle preserving permissions, symlinks, code signature, and staple
ditto "$APP_DIR" "$STAGING_DIR/Maccar.app"

# Create symlink to /Applications for easy drag-and-drop
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Creating $VERSIONED_DMG_NAME via hdiutil..."
hdiutil create \
    -volname "Maccar v${APP_VERSION}" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$OUTPUT_VERSIONED_DMG"

rm -rf "$STAGING_DIR"

if [ "$SIGN_IDENTITY" != "-" ]; then
    echo "==> Signing DMG image..."
    codesign --force --timestamp -s "$SIGN_IDENTITY" "$OUTPUT_VERSIONED_DMG"
    codesign --verify --verbose=2 "$OUTPUT_VERSIONED_DMG"
fi

if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Submitting DMG for Apple notarization..."
    xcrun notarytool submit "$OUTPUT_VERSIONED_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "==> Stapling and validating DMG notarization ticket..."
    xcrun stapler staple "$OUTPUT_VERSIONED_DMG"
    xcrun stapler validate "$OUTPUT_VERSIONED_DMG"
    echo "==> Verifying Gatekeeper acceptance..."
    spctl --assess --type open --context context:primary-signature -vv "$OUTPUT_VERSIONED_DMG"
fi

echo "==> Copying finalized DMG to Maccar.dmg..."
cp -f "$OUTPUT_VERSIONED_DMG" "$OUTPUT_DMG"

echo "==> Computing SHA-256 checksums..."
(cd "$BUILD_DIR" && shasum -a 256 "Maccar-v${APP_VERSION}.dmg" "Maccar-v${APP_VERSION}.zip" > SHA256SUMS.txt)

echo "=========================================================="
echo "✓ Maccar v${APP_VERSION} release artifacts created!"
echo "  Versioned DMG: $OUTPUT_VERSIONED_DMG"
echo "  Latest DMG:    $OUTPUT_DMG"
echo "  Versioned ZIP: $OUTPUT_ZIP"
echo "  Checksums:     $CHECKSUMS_FILE"
echo "=========================================================="
