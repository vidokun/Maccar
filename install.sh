#!/bin/sh
set -eu

DEFAULT_PREFIX="/Applications"
DEFAULT_MANIFEST_URL="https://github.com/vidokun/Maccar/releases/latest/download/manifest.json"
EXPECTED_BUNDLE_ID="com.maccar.app"

PREFIX="$DEFAULT_PREFIX"
MANIFEST_URL=""
REQUESTED_VERSION=""
CLEAN_VERSION=""
DRY_RUN=0
ALLOW_LOOPBACK=0
TMP_DIR=""

cleanup() {
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

die() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Install or update Maccar on macOS 14+ with SHA-256 and codesign verification.

Options:
  --version <tag>       Install a specific release version (e.g. 1.4.0 or v1.4.0)
  --prefix <dir>        Target installation directory (default: /Applications)
  --manifest-url <url>  Override release manifest URL (must pass allowlist)
  --dry-run             Verify manifest, OS version, and target permissions only
  -h, --help            Show this help message
EOF
}

is_valid_loopback_url() {
    _lu="$1"
    case "$_lu" in
        http://127.0.0.1:/*)
            return 1
            ;;
        http://127.0.0.1:*/*)
            _lrest="${_lu#http://127.0.0.1:}"
            _lport="${_lrest%%/*}"
            case "$_lport" in
                ""|*[!0-9]*)
                    return 1
                    ;;
                *)
                    if [ "$_lport" -ge 1 ] && [ "$_lport" -le 65535 ] 2>/dev/null; then
                        return 0
                    fi
                    return 1
                    ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

is_allowlisted_url() {
    _au="$1"
    case "$_au" in
        ""|*[[:space:]]*)
            return 1
            ;;
        https://github.com/vidokun/Maccar/*)
            return 0
            ;;
        https://vidokun.github.io/Maccar/*)
            return 0
            ;;
        https://objects.githubusercontent.com/*)
            return 0
            ;;
        https://release-assets.githubusercontent.com/*)
            return 0
            ;;
        https://github-releases.githubusercontent.com/*)
            return 0
            ;;
        http://127.0.0.1:*)
            if [ "$ALLOW_LOOPBACK" -eq 1 ] && is_valid_loopback_url "$_au"; then
                return 0
            fi
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

extract_json_field() {
    _jf="$1"
    _jk="$2"
    _jt=""
    _jt="$(/usr/bin/plutil -type "$_jk" "$_jf" 2>/dev/null || true)"
    case "$_jt" in
        string|integer|real)
            /usr/bin/plutil -extract "$_jk" raw -o - "$_jf" 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

version_gte() {
    _vg_cur="$1"
    _vg_min="$2"

    _vg_cmaj="${_vg_cur%%.*}"
    _vg_crest="${_vg_cur#*.}"
    if [ "$_vg_crest" = "$_vg_cur" ]; then
        _vg_crest="0.0"
    fi
    _vg_cmin="${_vg_crest%%.*}"
    _vg_cpat="${_vg_crest#*.}"
    if [ "$_vg_cpat" = "$_vg_crest" ]; then
        _vg_cpat="0"
    fi
    _vg_cpat="${_vg_cpat%%.*}"

    _vg_mmaj="${_vg_min%%.*}"
    _vg_mrest="${_vg_min#*.}"
    if [ "$_vg_mrest" = "$_vg_min" ]; then
        _vg_mrest="0.0"
    fi
    _vg_mmin="${_vg_mrest%%.*}"
    _vg_mpat="${_vg_mrest#*.}"
    if [ "$_vg_mpat" = "$_vg_mrest" ]; then
        _vg_mpat="0"
    fi
    _vg_mpat="${_vg_mpat%%.*}"

    [ "$_vg_cmaj" -gt "$_vg_mmaj" ] && return 0
    [ "$_vg_cmaj" -lt "$_vg_mmaj" ] && return 1
    [ "$_vg_cmin" -gt "$_vg_mmin" ] && return 0
    [ "$_vg_cmin" -lt "$_vg_mmin" ] && return 1
    [ "$_vg_cpat" -ge "$_vg_mpat" ] && return 0
    return 1
}

fetch_url() {
    _fu_src="$1"
    _fu_dst="$2"
    _fu_proto="=https"
    _fu_proto_redir="=https"
    if [ "$ALLOW_LOOPBACK" -eq 1 ]; then
        _fu_proto="=http,https"
        _fu_proto_redir="=http,https"
    fi

    is_allowlisted_url "$_fu_src" || die "Blocked disallowed URL: $_fu_src"

    _fu_eff=""
    _fu_eff="$(curl -fsSL \
        --proto "$_fu_proto" \
        --proto-redir "$_fu_proto_redir" \
        --max-redirs 5 \
        -o "$_fu_dst" \
        -w '%{url_effective}' \
        "$_fu_src")" || die "Failed to download: $_fu_src"

    is_allowlisted_url "$_fu_eff" || die "Blocked disallowed redirect destination: $_fu_eff"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || die "Missing value for --version"
            REQUESTED_VERSION="$2"
            shift 2
            ;;
        --version=*)
            REQUESTED_VERSION="${1#--version=}"
            shift
            ;;
        --prefix)
            [ "$#" -ge 2 ] || die "Missing value for --prefix"
            PREFIX="$2"
            shift 2
            ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"
            shift
            ;;
        --manifest-url)
            [ "$#" -ge 2 ] || die "Missing value for --manifest-url"
            MANIFEST_URL="$2"
            shift 2
            ;;
        --manifest-url=*)
            MANIFEST_URL="${1#--manifest-url=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1 (use --help for usage)"
            ;;
    esac
done

[ "$(uname -s)" = "Darwin" ] || die "Maccar requires macOS."
[ -x /usr/bin/plutil ] || die "Required macOS utility /usr/bin/plutil is unavailable."

if [ -n "$REQUESTED_VERSION" ]; then
    case "$REQUESTED_VERSION" in
        *[!0-9.v]*)
            die "Invalid --version '$REQUESTED_VERSION'. Expected semantic version like 1.4.0 or v1.4.0."
            ;;
    esac
    if ! printf '%s\n' "$REQUESTED_VERSION" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+$'; then
        die "Invalid --version '$REQUESTED_VERSION'. Expected semantic version like 1.4.0 or v1.4.0."
    fi
    CLEAN_VERSION="${REQUESTED_VERSION#v}"
fi

[ -n "$PREFIX" ] || die "Invalid --prefix: cannot be empty."
PREFIX="${PREFIX%/}"
while [ -n "$PREFIX" ] && [ "${PREFIX%/}" != "$PREFIX" ]; do
    PREFIX="${PREFIX%/}"
done
if [ -z "$PREFIX" ] || [ "$PREFIX" = "/" ]; then
    die "Invalid --prefix: refusing to install into '/'."
fi

[ -d "$PREFIX" ] || die "Target directory does not exist: $PREFIX"
[ -w "$PREFIX" ] || die "Target directory is not writable (run with sudo or specify --prefix): $PREFIX"

TARGET_APP="$PREFIX/Maccar.app"
if [ -e "$TARGET_APP" ] && [ ! -w "$TARGET_APP" ]; then
    die "Existing app bundle is not writable (run with sudo or check permissions): $TARGET_APP"
fi

if [ -z "$MANIFEST_URL" ]; then
    if [ -n "$CLEAN_VERSION" ]; then
        MANIFEST_URL="https://github.com/vidokun/Maccar/releases/download/v${CLEAN_VERSION}/manifest.json"
    else
        MANIFEST_URL="$DEFAULT_MANIFEST_URL"
    fi
fi

case "$MANIFEST_URL" in
    http://127.0.0.1:*)
        if is_valid_loopback_url "$MANIFEST_URL"; then
            ALLOW_LOOPBACK=1
        else
            die "Invalid loopback --manifest-url: $MANIFEST_URL"
        fi
        ;;
esac

is_allowlisted_url "$MANIFEST_URL" || die "Disallowed --manifest-url host or path: $MANIFEST_URL"

TMP_DIR="$(mktemp -d)"
MANIFEST_FILE="$TMP_DIR/manifest.json"

if [ "$DRY_RUN" -eq 1 ]; then
    printf '==> Maccar Installer (macOS 14+) [dry-run]\n'
else
    printf '==> Maccar Installer (macOS 14+)\n'
fi
printf '    Target:   %s\n' "$TARGET_APP"
printf '    Manifest: %s\n' "$MANIFEST_URL"

fetch_url "$MANIFEST_URL" "$MANIFEST_FILE"

MANIFEST_VERSION="$(extract_json_field "$MANIFEST_FILE" "version" || true)"
MIN_OS_VERSION="$(extract_json_field "$MANIFEST_FILE" "minimumSystemVersion" || true)"
ZIP_URL="$(extract_json_field "$MANIFEST_FILE" "artifacts.zip.url" || true)"
ZIP_SHA256="$(extract_json_field "$MANIFEST_FILE" "artifacts.zip.sha256" || true)"
ZIP_SIZE="$(extract_json_field "$MANIFEST_FILE" "artifacts.zip.sizeBytes" || true)"

[ -n "$MANIFEST_VERSION" ] || die "Manifest missing required field: version"
[ -n "$MIN_OS_VERSION" ] || die "Manifest missing required field: minimumSystemVersion"
[ -n "$ZIP_URL" ] || die "Manifest missing required field: artifacts.zip.url"
[ -n "$ZIP_SHA256" ] || die "Manifest missing required field: artifacts.zip.sha256"
[ -n "$ZIP_SIZE" ] || die "Manifest missing required field: artifacts.zip.sizeBytes"

if ! printf '%s\n' "$MANIFEST_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    die "Invalid manifest version: $MANIFEST_VERSION"
fi
if [ -n "$CLEAN_VERSION" ] && [ "$MANIFEST_VERSION" != "$CLEAN_VERSION" ]; then
    die "Manifest version ($MANIFEST_VERSION) does not match requested --version ($CLEAN_VERSION)."
fi
if ! printf '%s\n' "$MIN_OS_VERSION" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
    die "Invalid manifest minimumSystemVersion: $MIN_OS_VERSION"
fi

is_allowlisted_url "$ZIP_URL" || die "Disallowed artifacts.zip.url in manifest: $ZIP_URL"

ZIP_SHA256="$(printf '%s' "$ZIP_SHA256" | tr 'A-F' 'a-f')"
if ! printf '%s\n' "$ZIP_SHA256" | grep -Eq '^[0-9a-f]{64}$'; then
    die "Invalid manifest artifacts.zip.sha256 format."
fi
if ! printf '%s\n' "$ZIP_SIZE" | grep -Eq '^[1-9][0-9]*$'; then
    die "Invalid manifest artifacts.zip.sizeBytes: $ZIP_SIZE"
fi

OS_VERSION="$(sw_vers -productVersion)"
if ! printf '%s\n' "$OS_VERSION" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
    die "Unable to parse macOS version from sw_vers: $OS_VERSION"
fi
if ! version_gte "$OS_VERSION" "$MIN_OS_VERSION"; then
    die "macOS $MIN_OS_VERSION or newer is required (detected $OS_VERSION)."
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf '    [1/4] Fetching release metadata (v%s, macOS %s >= %s)... OK\n' "$MANIFEST_VERSION" "$OS_VERSION" "$MIN_OS_VERSION"
    printf '    [2/4] Would download Maccar-v%s.zip (%s bytes) & verify SHA-256\n' "$MANIFEST_VERSION" "$ZIP_SIZE"
    printf '    [3/4] Would extract bundle & verify codesign\n'
    printf '    [4/4] Would install to %s\n' "$TARGET_APP"
    printf '✓ Dry run passed for Maccar v%s (no files downloaded or modified).\n' "$MANIFEST_VERSION"
    exit 0
fi

printf '    [1/4] Fetching release metadata (v%s)... OK\n' "$MANIFEST_VERSION"

ARCHIVE_FILE="$TMP_DIR/Maccar-v${MANIFEST_VERSION}.zip"
fetch_url "$ZIP_URL" "$ARCHIVE_FILE"

ACTUAL_SIZE="$(wc -c < "$ARCHIVE_FILE" | tr -d '[:space:]')"
if [ "$ACTUAL_SIZE" != "$ZIP_SIZE" ]; then
    die "Downloaded archive size mismatch (expected $ZIP_SIZE bytes, got $ACTUAL_SIZE bytes)."
fi

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE_FILE" | awk '{print $1}' | tr 'A-F' 'a-f')"
if [ "$ACTUAL_SHA256" != "$ZIP_SHA256" ]; then
    die "SHA-256 verification failed (expected $ZIP_SHA256, got $ACTUAL_SHA256)."
fi
printf '    [2/4] Downloading Maccar-v%s.zip & verifying SHA-256... OK\n' "$MANIFEST_VERSION"

EXTRACT_DIR="$TMP_DIR/extract"
mkdir -p "$EXTRACT_DIR"
ditto -x -k "$ARCHIVE_FILE" "$EXTRACT_DIR"

STAGED_APP="$EXTRACT_DIR/Maccar.app"
[ -d "$STAGED_APP" ] || die "Extracted archive does not contain Maccar.app"

EXTRACTED_BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$STAGED_APP/Contents/Info.plist" 2>/dev/null || true)"
if [ "$EXTRACTED_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]; then
    die "Bundle identifier mismatch (expected $EXPECTED_BUNDLE_ID, got '$EXTRACTED_BUNDLE_ID')."
fi

codesign --verify --deep --strict "$STAGED_APP" >/dev/null 2>&1 || die "Code signature verification failed on extracted Maccar.app"
printf '    [3/4] Extracting bundle & verifying codesign... OK\n'

printf '    [4/4] Installing to %s...\n' "$TARGET_APP"
TARGET_EXEC="$TARGET_APP/Contents/MacOS/maccar"
RUNNING_PIDS="$(ps -Ao pid=,args= | awk -v t="$TARGET_EXEC" -v self="$$" '$1 != self && index($0, t) > 0 {print $1}')"
if [ -n "$RUNNING_PIDS" ]; then
    printf '%s\n' "$RUNNING_PIDS" | while IFS= read -r _pid; do
        if [ -n "$_pid" ]; then
            kill "$_pid" >/dev/null 2>&1 || true
        fi
    done
    sleep 1
fi

rm -rf "$TARGET_APP"
ditto "$STAGED_APP" "$TARGET_APP"
codesign --verify --deep --strict "$TARGET_APP" >/dev/null 2>&1 || die "Code signature verification failed after installation to $TARGET_APP"

# Signature validity and Gatekeeper acceptance are different questions: a self-signed or ad-hoc
# bundle verifies fine yet still gets blocked on first launch. Report what macOS actually says,
# but do not fail — an ad-hoc build is legitimate for a local install, and `spctl` also reports
# "rejected" for a perfectly good unnotarized Developer ID build.
GATEKEEPER_VERDICT="$(spctl --assess --type execute -vv "$TARGET_APP" 2>&1 || true)"
GATEKEEPER_SOURCE="$(printf '%s\n' "$GATEKEEPER_VERDICT" | sed -n 's/^source=//p' | head -1)"
if printf '%s\n' "$GATEKEEPER_VERDICT" | grep -q ': accepted'; then
    printf '    Gatekeeper: accepted%s\n' "${GATEKEEPER_SOURCE:+ ($GATEKEEPER_SOURCE)}"
else
    printf '    Gatekeeper: not accepted%s\n' "${GATEKEEPER_SOURCE:+ ($GATEKEEPER_SOURCE)}"
    printf '    This build is not notarized. First launch may need right-click -> Open.\n'
fi

if [ "$PREFIX" = "/Applications" ]; then
    printf '✓ Maccar v%s installed. Launch via Spotlight or: open -a Maccar\n' "$MANIFEST_VERSION"
else
    printf '✓ Maccar v%s installed. Launch via: open "%s"\n' "$MANIFEST_VERSION" "$TARGET_APP"
fi
