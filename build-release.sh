#!/bin/bash
# build-release.sh — Build SilenciApp and bundle Python module for standalone distribution.
#
# Output: dist/SilenciApp.app/
#
# The app bundle includes:
#   Contents/MacOS/SilenciApp     — the Swift executable
#   Contents/Resources/silence_cutter/  — the Python module
#   Contents/Resources/pyproject.toml   — dependency metadata
#   Contents/Info.plist                 — app metadata

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
SWIFT_PKG="$PROJECT_ROOT/SilenciApp"
DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/SilenciApp.app"
CONTENTS="$APP_BUNDLE/Contents"

echo "=== Building SilenciApp release ==="

# 1. Build release binary
echo "[1/4] Building Swift release binary…"
cd "$SWIFT_PKG"
swift build -c release 2>&1
BINARY="$SWIFT_PKG/.build/release/SilenciApp"

if [ ! -f "$BINARY" ]; then
    echo "❌ Build failed — binary not found at $BINARY"
    exit 1
fi
echo "  ✅ Binary: $BINARY"

# 2. Create .app bundle structure
echo "[2/4] Creating app bundle…"
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"

cp "$BINARY" "$CONTENTS/MacOS/SilenciApp"

# 3. Copy Python module
echo "[3/5] Bundling Python module…"
rsync -a --exclude='__pycache__' "$PROJECT_ROOT/silence_cutter/" "$CONTENTS/Resources/silence_cutter/"
cp "$PROJECT_ROOT/pyproject.toml" "$CONTENTS/Resources/pyproject.toml"
echo "  ✅ silence_cutter/ → Resources/"

# 4. Copy SwiftPM resource bundle (localization strings etc.)
echo "[4/5] Bundling SwiftPM resources…"
RESOURCE_BUNDLE=$(find "$SWIFT_PKG/.build" -name "SilenciApp_SilenciApp.bundle" -type d | head -1)
if [ -n "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$CONTENTS/Resources/"
    echo "  ✅ $(basename "$RESOURCE_BUNDLE") → Resources/"
else
    echo "  ⚠️ No SwiftPM resource bundle found (localization may not work)"
fi

# Copy app icon
ICON_FILE="$SWIFT_PKG/Sources/Resources/AppIcon.icns"
if [ -f "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$CONTENTS/Resources/AppIcon.icns"
    echo "  ✅ AppIcon.icns → Resources/"
fi

# 5. Write Info.plist
echo "[5/5] Writing Info.plist…"
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Silenci</string>
    <key>CFBundleDisplayName</key>
    <string>Silenci</string>
    <key>CFBundleIdentifier</key>
    <string>com.genelab.silenci</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>SilenciApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

echo ""
echo "=== ✅ Build complete ==="
echo "App bundle: $APP_BUNDLE"
du -sh "$APP_BUNDLE"

# 6. Create DMG installer
if command -v create-dmg &>/dev/null; then
    echo ""
    echo "[6/6] Creating DMG installer…"
    DMG_PATH="$DIST_DIR/Silenci-v0.2.0-macOS.dmg"
    rm -f "$DMG_PATH"

    create-dmg \
        --volname "Silenci" \
        --volicon "$SWIFT_PKG/Sources/Resources/AppIcon.icns" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 128 \
        --icon "SilenciApp.app" 180 200 \
        --app-drop-link 480 200 \
        --hide-extension "SilenciApp.app" \
        --no-internet-enable \
        "$DMG_PATH" \
        "$APP_BUNDLE" \
        2>&1 | tail -5

    if [ -f "$DMG_PATH" ]; then
        echo "  ✅ DMG: $DMG_PATH"
        du -sh "$DMG_PATH"
    else
        echo "  ⚠️ DMG creation failed — app bundle is still available"
    fi
else
    echo ""
    echo "ℹ️  Install create-dmg for DMG packaging: brew install create-dmg"
fi

echo ""
echo "To run:"
echo "  open $APP_BUNDLE"
