#!/bin/bash
set -euo pipefail

# Build and bundle Careless Whisper as a macOS .app
# Usage: ./scripts/bundle.sh [--release] [--version <version>]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Careless Whisper"
BUNDLE_ID="com.carelesswhisper.app"
BUILD_CONFIG="debug"
VERSION="0.0.0-dev"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            BUILD_CONFIG="release"
            shift
            ;;
        --version)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                echo "Error: --version requires a non-empty value." >&2
                echo "Usage: ./scripts/bundle.sh [--release] [--version <version>]" >&2
                exit 1
            fi
            VERSION="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "Building ($BUILD_CONFIG)..."
cd "$PROJECT_DIR"

if [[ "$BUILD_CONFIG" == "release" ]]; then
    swift build -c release
    BINARY_PATH=".build/release/CarelessWhisper"
else
    swift build
    BINARY_PATH=".build/debug/CarelessWhisper"
fi

# Create .app bundle
APP_DIR="$PROJECT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy binary
cp "$BINARY_PATH" "$MACOS_DIR/CarelessWhisper"

# Copy app icon
cp "$PROJECT_DIR/resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

# Sign with local development identity so macOS accessibility permission
# persists across rebuilds (ad-hoc signatures change every build, which
# invalidates TCC grants like the CGEventTap used for key interception).
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)
if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$MACOS_DIR/CarelessWhisper"
    echo "Signed with: $SIGN_IDENTITY"
else
    echo "Warning: No Apple Development signing identity found — accessibility permission will reset on each rebuild"
fi

# Create Info.plist
cat > "$CONTENTS_DIR/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>CarelessWhisper</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Careless Whisper needs microphone access to record your voice for transcription.</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo ""
echo "App bundle created at: $APP_DIR"
echo ""
echo "To install:"
echo "  cp -r \"$APP_DIR\" /Applications/"
echo ""
echo "To run:"
echo "  open \"$APP_DIR\""
