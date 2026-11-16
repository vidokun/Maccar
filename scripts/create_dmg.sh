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

# Attaches the notarization ticket, retrying on transient failure.
#
# `stapler staple` downloads the ticket from Apple, so a flaky runner network can fail it. A
# retry is safe: stapling the same ticket twice is a no-op.
staple_ticket() {
    local target="$1" attempt
    for attempt in 1 2 3; do
        if xcrun stapler staple "$target"; then return 0; fi
        echo "    stapler staple failed (attempt $attempt/3); retrying in 5s..." >&2
        sleep 5
    done
    echo "Error: could not staple a notarization ticket to $target after 3 attempts." >&2
    return 1
}

# Confirms the ticket is present, without failing on a network blip.
#
# `stapler validate` contacts api.apple-cloudkit.com to re-check the ticket. On a runner whose
# connection drops mid-release that produces `NSURLErrorDomain -1005` / `Error 68` even though
# the staple above succeeded — which is exactly how the v1.4.2 release failed once. Retrying
# first distinguishes a blip from a real problem; if the network stays down, the local Gatekeeper
# assessment is the authoritative offline check, so we fall back to it instead of failing the
# release over a verification the user's Mac would pass anyway.
verify_stapled() {
    local target="$1" attempt
    for attempt in 1 2 3; do
        if xcrun stapler validate "$target"; then return 0; fi
        echo "    stapler validate failed (attempt $attempt/3); retrying in 5s..." >&2
        sleep 5
    done

    echo "    stapler validate could not reach Apple; falling back to the local Gatekeeper assessment." >&2
    if spctl --assess --type open --context context:primary-signature -vv "$target" 2>&1 | tee /dev/stderr | grep -q ': accepted'; then
        echo "    Gatekeeper accepts the ticket locally, so the staple is present." >&2
        return 0
    fi
    echo "Error: the ticket could not be validated locally either." >&2
    return 1
}

if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Zipping Maccar.app for Apple notarization..."
    rm -f "$NOTARY_TMP_ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$NOTARY_TMP_ZIP"
    echo "==> Submitting Maccar.app for Apple notarization..."
    xcrun notarytool submit "$NOTARY_TMP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "==> Stapling Maccar.app notarization ticket..."
    staple_ticket "$APP_DIR"
    verify_stapled "$APP_DIR"
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
    echo "==> Stapling DMG notarization ticket..."
    staple_ticket "$OUTPUT_VERSIONED_DMG"
    verify_stapled "$OUTPUT_VERSIONED_DMG"
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
