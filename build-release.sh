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

# 4. Copy localization resources manually (no SwiftPM resource bundle)
echo "[4/5] Bundling localization resources…"
LPROJ_SRC="$SWIFT_PKG/Sources/Resources"
LPROJ_BUNDLE="$CONTENTS/MacOS/SilenciApp_SilenciApp.bundle"
mkdir -p "$LPROJ_BUNDLE"
for lproj in "$LPROJ_SRC"/*.lproj; do
    if [ -d "$lproj" ]; then
        cp -R "$lproj" "$LPROJ_BUNDLE/"
    fi
done
# Write minimal Info.plist for the bundle (required for code signing)
cat > "$LPROJ_BUNDLE/Info.plist" << 'BPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.genelab.silenci.resources</string>
    <key>CFBundleName</key>
    <string>SilenciApp_SilenciApp</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
</dict>
</plist>
BPLIST
# Also copy to Resources for compatibility
cp -R "$LPROJ_BUNDLE" "$CONTENTS/Resources/"
echo "  ✅ Localizations → MacOS/ + Resources/"

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

# 6. Code sign the app bundle
echo ""
echo "[6/7] Code signing…"
codesign --force --deep --sign "Apple Development: Youngchan Lee (K295R764SP)" "$APP_BUNDLE" 2>&1
if [ $? -eq 0 ]; then
    echo "  ✅ Code signed"
else
    echo "  ⚠️ Code signing failed — app will require xattr -cr on first launch"
fi

# 7. Create DMG installer
if command -v create-dmg &>/dev/null; then
    echo ""
    echo "[7/8] Creating DMG installer…"
    DMG_PATH="$DIST_DIR/Silenci-v0.4.0-macOS.dmg"
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

# 7. Remove quarantine attribute from app bundle
echo ""
echo "[8/8] Removing quarantine attribute…"
xattr -cr "$APP_BUNDLE" 2>/dev/null
echo "  ✅ Quarantine removed"

echo ""
echo "To run:"
echo "  open $APP_BUNDLE"
echo ""
echo "⚠️  First launch on another Mac:"
echo "  If macOS says 'damaged', run: xattr -cr /Applications/SilenciApp.app"
