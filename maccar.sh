#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

chmod +x "$DIR/scripts/"*.sh 2>/dev/null || true

if [ -z "${DEVELOPER_DIR:-}" ]; then
    ACTIVE_DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
    if { [ "$ACTIVE_DEV_DIR" = "/Library/Developer/CommandLineTools" ] || [ ! -d "$ACTIVE_DEV_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]; } && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi

case "${1:-}" in
    "build")
        swift build -c debug
        exit 0
        ;;
    "test")
        shift
        swift test "$@"
        exit 0
        ;;
    "package")
        "$DIR/scripts/package_app.sh"
        exit 0
        ;;
    "install")
        "$DIR/scripts/package_app.sh" install
        exit 0
        ;;
    "cleanup")
        "$DIR/scripts/cleanup_legacy.sh"
        exit 0
        ;;
    "dmg")
        "$DIR/scripts/create_dmg.sh"
        exit 0
        ;;
    *)
        # Always ensure build is up-to-date (incremental build is fast)
        swift build -c debug >&2
        exec .build/debug/maccar "$@"
        ;;
esac
