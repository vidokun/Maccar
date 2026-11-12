#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

BUILD_DIR="$DIR/build"
BUNDLED_PLIST="$BUILD_DIR/Maccar.app/Contents/Info.plist"
SOURCE_PLIST="$DIR/scripts/Info.plist"
DEFAULT_OUTPUT="$BUILD_DIR/manifest.json"
DEFAULT_KEY_ID="maccar-release-v1"
RELEASE_PAGE="https://github.com/vidokun/Maccar/releases"
DOWNLOAD_BASE="https://github.com/vidokun/Maccar/releases/download"

OUT_COPY=""
MODE="generate"

usage() {
    cat <<'EOF'
Usage: scripts/generate_manifest.sh [options]

Generates build/manifest.json from the packaged Maccar.app (or scripts/Info.plist
when no build exists). Never writes into docs/ unless --out-copy points there.

Options:
  --help                 Show this help and exit.
  --keygen               Print a fresh Curve25519 keypair (private, public) and exit.
  --out-copy <path>      Also copy the generated manifest to <path> (used by CI).
EOF
}

log() { echo "==> $*"; }
fail() { echo "Error: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --keygen) MODE="keygen"; shift ;;
        --out-copy)
            [ "$#" -ge 2 ] || fail "--out-copy requires a path argument."
            OUT_COPY="$2"; shift 2 ;;
        *) fail "Unknown argument: $1. Run --help for usage." ;;
    esac
done

run_swift() {
    # Standard input keeps the crypto helper out of the working tree entirely.
    xcrun swift - "$@" 2>/dev/null
}

if [ "$MODE" = "keygen" ]; then
    run_swift <<'SWIFT' || fail "CryptoKit key generation failed."
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
    exit 0
fi

PLIST="$SOURCE_PLIST"
if [ -f "$BUNDLED_PLIST" ]; then PLIST="$BUNDLED_PLIST"; fi
[ -f "$PLIST" ] || fail "Cannot find an Info.plist at $BUNDLED_PLIST or $SOURCE_PLIST."

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true
}

VERSION="$(plist_value CFBundleShortVersionString)"
BUILD_NUMBER="$(plist_value CFBundleVersion)"
BUNDLE_ID="$(plist_value CFBundleIdentifier)"
MIN_OS="$(plist_value LSMinimumSystemVersion)"
PUBLIC_KEY="$(plist_value MaccarUpdatePublicKey)"
KEY_ID="$(plist_value MaccarUpdateKeyId)"

[ -n "$VERSION" ] || fail "CFBundleShortVersionString is empty in $PLIST."
[ -n "$BUILD_NUMBER" ] || fail "CFBundleVersion is empty in $PLIST."
[ -n "$BUNDLE_ID" ] || fail "CFBundleIdentifier is empty in $PLIST."
[ -n "$MIN_OS" ] || fail "LSMinimumSystemVersion is empty in $PLIST."
case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) fail "CFBundleShortVersionString '$VERSION' is not semantic major.minor.patch." ;;
esac
case "$BUILD_NUMBER" in
    ''|*[!0-9]*) fail "CFBundleVersion '$BUILD_NUMBER' must be a positive integer." ;;
esac

PRIVATE_KEY="${MACCAR_UPDATE_PRIVATE_KEY:-}"
SIGNATURE_BASE64=""
if [ -n "$PRIVATE_KEY" ] && [ -z "$PUBLIC_KEY" ]; then
    fail "MACCAR_UPDATE_PRIVATE_KEY is set but MaccarUpdatePublicKey is empty in $PLIST. Refusing an unsigned public key."
fi
if [ -z "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ]; then
    fail "MaccarUpdatePublicKey is pinned but MACCAR_UPDATE_PRIVATE_KEY is not set. A pinned build cannot ship unsigned."
fi

ZIP_NAME="Maccar-v${VERSION}.zip"
DMG_NAME="Maccar-v${VERSION}.dmg"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
[ -f "$ZIP_PATH" ] || fail "Missing $ZIP_PATH. Run scripts/create_dmg.sh first."
[ -f "$DMG_PATH" ] || fail "Missing $DMG_PATH. Run scripts/create_dmg.sh first."

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
size_of() { stat -f%z "$1"; }

ZIP_SHA="$(sha256_of "$ZIP_PATH")"
DMG_SHA="$(sha256_of "$DMG_PATH")"
ZIP_SIZE="$(size_of "$ZIP_PATH")"
DMG_SIZE="$(size_of "$DMG_PATH")"
ZIP_URL="$DOWNLOAD_BASE/v${VERSION}/${ZIP_NAME}"
DMG_URL="$DOWNLOAD_BASE/v${VERSION}/${DMG_NAME}"
RELEASE_URL="$RELEASE_PAGE/tag/v${VERSION}"
SUMMARY="${MACCAR_RELEASE_SUMMARY:-Maccar v${VERSION} (build ${BUILD_NUMBER}) for macOS ${MIN_OS} and newer.}"
PUBLISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ -n "$PRIVATE_KEY" ]; then
    [ -n "$KEY_ID" ] || KEY_ID="$DEFAULT_KEY_ID"
    # Must match ReleaseUpdater.resolveTrustLevel exactly: 9 fields joined by "|".
    CANONICAL="Maccar|${BUNDLE_ID}|${VERSION}|${BUILD_NUMBER}|${MIN_OS}|${ZIP_URL}|${ZIP_SHA}|${ZIP_SIZE}|${DMG_SHA}"
    SIGNATURE_BASE64="$(
        MACCAR_CANONICAL="$CANONICAL" MACCAR_KEY="$PRIVATE_KEY" MACCAR_PUBLIC="$PUBLIC_KEY" run_swift <<'SWIFT'
import CryptoKit
import Foundation

let environment = ProcessInfo.processInfo.environment
let canonical = environment["MACCAR_CANONICAL"] ?? ""
let keyBase64 = environment["MACCAR_KEY"] ?? ""
let expectedPublic = environment["MACCAR_PUBLIC"] ?? ""

guard let rawKey = Data(base64Encoded: keyBase64), rawKey.count == 32 else {
    FileHandle.standardError.write(Data("private key is not 32 base64 bytes\n".utf8))
    exit(2)
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
guard key.publicKey.rawRepresentation.base64EncodedString() == expectedPublic else {
    FileHandle.standardError.write(Data("derived public key does not match MaccarUpdatePublicKey\n".utf8))
    exit(3)
}
let signature = try key.signature(for: Data(canonical.utf8))
print(signature.base64EncodedString())
SWIFT
    )" || fail "Ed25519 signing failed; the private key does not match MaccarUpdatePublicKey."
fi

TMP_MANIFEST="$(mktemp -t maccar-manifest)"
trap 'rm -f "$TMP_MANIFEST"' EXIT

MACCAR_MANIFEST_PATH="$TMP_MANIFEST" \
MACCAR_BUNDLE_ID="$BUNDLE_ID" MACCAR_VERSION="$VERSION" MACCAR_BUILD="$BUILD_NUMBER" \
MACCAR_MIN_OS="$MIN_OS" MACCAR_PUBLISHED_AT="$PUBLISHED_AT" MACCAR_RELEASE_URL="$RELEASE_URL" \
MACCAR_SUMMARY="$SUMMARY" MACCAR_ZIP_URL="$ZIP_URL" MACCAR_ZIP_SHA="$ZIP_SHA" MACCAR_ZIP_SIZE="$ZIP_SIZE" \
MACCAR_DMG_URL="$DMG_URL" MACCAR_DMG_SHA="$DMG_SHA" MACCAR_DMG_SIZE="$DMG_SIZE" \
MACCAR_KEY_ID="$KEY_ID" MACCAR_SIGNATURE="$SIGNATURE_BASE64" \
python3 -I - <<'PY'
import json
import os

env = os.environ
manifest = {
    "schemaVersion": 1,
    "product": "Maccar",
    "bundleIdentifier": env["MACCAR_BUNDLE_ID"],
    "version": env["MACCAR_VERSION"],
    "build": int(env["MACCAR_BUILD"]),
    "publishedAt": env["MACCAR_PUBLISHED_AT"],
    "minimumSystemVersion": env["MACCAR_MIN_OS"],
    "releaseNotesUrl": env["MACCAR_RELEASE_URL"],
    "releaseNotesSummary": env["MACCAR_SUMMARY"],
    "artifacts": {
        "zip": {
            "url": env["MACCAR_ZIP_URL"],
            "sha256": env["MACCAR_ZIP_SHA"],
            "sizeBytes": int(env["MACCAR_ZIP_SIZE"]),
        },
        "dmg": {
            "url": env["MACCAR_DMG_URL"],
            "sha256": env["MACCAR_DMG_SHA"],
            "sizeBytes": int(env["MACCAR_DMG_SIZE"]),
        },
    },
    "signature": None,
}
signature = env["MACCAR_SIGNATURE"]
if signature:
    manifest["signature"] = {
        "algorithm": "ed25519",
        "keyId": env["MACCAR_KEY_ID"],
        "zipSignatureBase64": signature,
    }
with open(env["MACCAR_MANIFEST_PATH"], "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

python3 -I -m json.tool "$TMP_MANIFEST" >/dev/null || fail "Generated manifest is not valid JSON."
/usr/bin/plutil -extract schemaVersion raw -o - "$TMP_MANIFEST" >/dev/null || fail "plutil could not read schemaVersion from the manifest."

mkdir -p "$BUILD_DIR"
cp -f "$TMP_MANIFEST" "$DEFAULT_OUTPUT"
log "Wrote $DEFAULT_OUTPUT (v${VERSION} build ${BUILD_NUMBER})"

if [ -n "$OUT_COPY" ]; then
    mkdir -p "$(dirname "$OUT_COPY")"
    cp -f "$TMP_MANIFEST" "$OUT_COPY"
    log "Copied manifest to $OUT_COPY"
fi

if [ -z "$SIGNATURE_BASE64" ]; then
    log "No signing key supplied: manifest ships unsigned (ad-hoc trust tier)."
else
    log "Manifest signed with keyId '$KEY_ID'."
fi
