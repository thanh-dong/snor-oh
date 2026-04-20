#!/bin/bash
# Build snor-oh.app universal release bundle from Swift Package Manager.
# Usage: bash Scripts/build-release.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# --- Configuration ---
APP_NAME="snor-oh"
VERSION="0.6.2"
EXECUTABLE="SnorOhSwift"

BUILD_DIR="$PROJECT_DIR/.build/release-app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

# --- Clean ---
echo "==> Cleaning previous build..."
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# --- Build both architectures ---
echo "==> Building arm64..."
swift build -c release --arch arm64

echo "==> Building x86_64..."
swift build -c release --arch x86_64

ARM_BINARY="$PROJECT_DIR/.build/arm64-apple-macosx/release/$EXECUTABLE"
X86_BINARY="$PROJECT_DIR/.build/x86_64-apple-macosx/release/$EXECUTABLE"

[ -f "$ARM_BINARY" ] || { echo "ERROR: arm64 binary not found"; exit 1; }
[ -f "$X86_BINARY" ] || { echo "ERROR: x86_64 binary not found"; exit 1; }

echo "==> Creating universal binary..."
lipo -create "$ARM_BINARY" "$X86_BINARY" -output "$MACOS_DIR/$EXECUTABLE"
chmod +x "$MACOS_DIR/$EXECUTABLE"
echo "    Archs: $(lipo -archs "$MACOS_DIR/$EXECUTABLE")"

# --- Assemble .app bundle ---
echo "==> Assembling $APP_NAME.app..."
cp "$PROJECT_DIR/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

[ -d "$PROJECT_DIR/Resources/Sprites" ] && cp -R "$PROJECT_DIR/Resources/Sprites" "$RESOURCES_DIR/Sprites"
[ -d "$PROJECT_DIR/Resources/Scripts" ] && cp -R "$PROJECT_DIR/Resources/Scripts" "$RESOURCES_DIR/Scripts"
[ -d "$PROJECT_DIR/Resources/Sounds" ] && cp -R "$PROJECT_DIR/Resources/Sounds" "$RESOURCES_DIR/Sounds"
find "$APP_BUNDLE" -name ".DS_Store" -delete 2>/dev/null || true

# --- Code Sign ---
echo "==> Signing..."
codesign --force --sign - \
    --entitlements "$PROJECT_DIR/Entitlements.plist" \
    --deep \
    "$APP_BUNDLE"

# --- Done ---
echo ""
echo "=== Build Complete ==="
echo "App:   $APP_BUNDLE"
echo "Size:  $(du -sh "$APP_BUNDLE" | cut -f1)"
echo "Archs: $(lipo -archs "$MACOS_DIR/$EXECUTABLE")"
echo ""
echo "To run: open \"$APP_BUNDLE\""
echo "To create DMG: hdiutil create -volname \"$APP_NAME\" -srcfolder \"$APP_BUNDLE\" -ov -format UDZO \"$BUILD_DIR/$APP_NAME-$VERSION.dmg\""
