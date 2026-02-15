#!/bin/bash
set -euo pipefail

# Build and bundle Careless Whisper as a macOS .app
# Usage: ./scripts/bundle.sh [--release]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Careless Whisper"
BUNDLE_ID="com.carelesswhisper.app"
BUILD_CONFIG="debug"

if [[ "${1:-}" == "--release" ]]; then
    BUILD_CONFIG="release"
fi

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

# Create Info.plist
cat > "$CONTENTS_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Careless Whisper</string>
    <key>CFBundleDisplayName</key>
    <string>Careless Whisper</string>
    <key>CFBundleIdentifier</key>
    <string>com.carelesswhisper.app</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
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
