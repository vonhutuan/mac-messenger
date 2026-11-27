#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="MacMessenger"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALL_TO_APPS=false

for arg in "$@"; do
    case "$arg" in
        --install)
            INSTALL_TO_APPS=true
            ;;
        --debug)
            BUILD_CONFIG="debug"
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $0 [--debug] [--install]" >&2
            exit 1
            ;;
    esac
done

ARCH="$(uname -m)"
SWIFT_OPT_FLAG="-O"
if [[ "$BUILD_CONFIG" == "debug" ]]; then
    SWIFT_OPT_FLAG="-Onone -g"
fi

echo "==> Building $APP_NAME ($BUILD_CONFIG, $ARCH)..."
mkdir -p "$ROOT_DIR/.build/$BUILD_CONFIG"
BIN_PATH="$ROOT_DIR/.build/$BUILD_CONFIG/$APP_NAME"

# Compile directly with swiftc for fast, reliable builds with Command Line Tools
# shellcheck disable=SC2086
swiftc $SWIFT_OPT_FLAG \
    -parse-as-library \
    -target "${ARCH}-apple-macosx13.0" \
    "$ROOT_DIR"/Sources/MacMessenger/*.swift \
    -framework AppKit \
    -framework WebKit \
    -framework UserNotifications \
    -framework AVFoundation \
    -o "$BIN_PATH"

echo "==> Packaging $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Generate AppIcon.icns directly in Swift
swift "$ROOT_DIR/scripts/generate-icon.swift" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> Signing bundle (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"

if [[ "$INSTALL_TO_APPS" == "true" ]]; then
    echo "==> Installing to /Applications/$APP_NAME.app..."
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
    echo "==> Installed to /Applications/$APP_NAME.app"
fi
