#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

if [ -z "${DEVELOPER_DIR:-}" ]; then
    ACTIVE_DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
    if { [ "$ACTIVE_DEV_DIR" = "/Library/Developer/CommandLineTools" ] || [ ! -d "$ACTIVE_DEV_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]; } && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi

echo "==> [1/4] Compiling Maccar (Release binary)..."
swift build -c release

APP_NAME="Maccar.app"
BUILD_DIR="$DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> [2/4] Constructing macOS App Bundle structure..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy binary
cp ".build/release/maccar" "$MACOS_DIR/maccar"
chmod +x "$MACOS_DIR/maccar"

# Generate AppIcon.icns if needed
if [ ! -f "$DIR/Resources/AppIcon.icns" ]; then
    echo "==> Generating AppIcon.icns from SVG..."
    swift "$DIR/scripts/generate_icns.swift" || true
fi

# Copy Info.plist and Resources
cp "$DIR/scripts/Info.plist" "$CONTENTS_DIR/Info.plist"
if [ -n "${MACCAR_UPDATE_PUBLIC_KEY:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :MaccarUpdatePublicKey $MACCAR_UPDATE_PUBLIC_KEY" "$CONTENTS_DIR/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :MaccarUpdatePublicKey string $MACCAR_UPDATE_PUBLIC_KEY" "$CONTENTS_DIR/Info.plist"
fi
if [ -n "${MACCAR_UPDATE_KEY_ID:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :MaccarUpdateKeyId $MACCAR_UPDATE_KEY_ID" "$CONTENTS_DIR/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :MaccarUpdateKeyId string $MACCAR_UPDATE_KEY_ID" "$CONTENTS_DIR/Info.plist"
fi
if [ -f "$DIR/Resources/AppIcon.icns" ]; then
    cp "$DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
if [ -d "$DIR/Resources/BrandLogos" ]; then
    mkdir -p "$RESOURCES_DIR/BrandLogos"
    cp -R "$DIR/Resources/BrandLogos/." "$RESOURCES_DIR/BrandLogos/"
fi

SIGN_IDENTITY="${MACCAR_SIGN_IDENTITY:--}"

echo "==> [3/4] Code signing..."
# Strip Finder/quarantine extended attributes so notarization will not reject the bundle
xattr -cr "$APP_DIR" 2>/dev/null || true
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "    Using ad-hoc signing (-)"
    codesign --force --deep -s - "$APP_DIR"
else
    echo "    Signing with Hardened Runtime ($SIGN_IDENTITY)"
    codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$APP_DIR"
fi
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "==> [4/4] Maccar.app bundle created successfully at:"
echo "    $APP_DIR"

if [ "${1:-}" = "install" ]; then
    echo "==> Installing Maccar to /Applications..."
    # Close any running Maccar instance
    killall maccar 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME"
    ditto "$APP_DIR" "/Applications/$APP_NAME"
    codesign --verify --deep --strict "/Applications/$APP_NAME"
    echo "✓ Successfully installed to /Applications/$APP_NAME"
fi
