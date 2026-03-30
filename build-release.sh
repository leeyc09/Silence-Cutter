#!/bin/bash
# build-release.sh — Build SilenceCutterApp and bundle Python module for standalone distribution.
#
# Output: dist/SilenceCutterApp.app/
#
# The app bundle includes:
#   Contents/MacOS/SilenceCutterApp     — the Swift executable
#   Contents/Resources/silence_cutter/  — the Python module
#   Contents/Resources/pyproject.toml   — dependency metadata
#   Contents/Info.plist                 — app metadata

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
SWIFT_PKG="$PROJECT_ROOT/SilenceCutterApp"
DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/SilenceCutterApp.app"
CONTENTS="$APP_BUNDLE/Contents"

echo "=== Building SilenceCutterApp release ==="

# 1. Build release binary
echo "[1/4] Building Swift release binary…"
cd "$SWIFT_PKG"
swift build -c release 2>&1
BINARY="$SWIFT_PKG/.build/release/SilenceCutterApp"

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

cp "$BINARY" "$CONTENTS/MacOS/SilenceCutterApp"

# 3. Copy Python module
echo "[3/5] Bundling Python module…"
rsync -a --exclude='__pycache__' "$PROJECT_ROOT/silence_cutter/" "$CONTENTS/Resources/silence_cutter/"
cp "$PROJECT_ROOT/pyproject.toml" "$CONTENTS/Resources/pyproject.toml"
echo "  ✅ silence_cutter/ → Resources/"

# 4. Copy SwiftPM resource bundle (localization strings etc.)
echo "[4/5] Bundling SwiftPM resources…"
RESOURCE_BUNDLE=$(find "$SWIFT_PKG/.build" -name "SilenceCutterApp_SilenceCutterApp.bundle" -type d | head -1)
if [ -n "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$CONTENTS/Resources/"
    echo "  ✅ $(basename "$RESOURCE_BUNDLE") → Resources/"
else
    echo "  ⚠️ No SwiftPM resource bundle found (localization may not work)"
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
    <string>SilenceCutter</string>
    <key>CFBundleDisplayName</key>
    <string>SilenceCutter</string>
    <key>CFBundleIdentifier</key>
    <string>com.genelab.silencecutter</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>SilenceCutterApp</string>
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
echo ""
echo "To run:"
echo "  open $APP_BUNDLE"
echo ""
echo "To distribute: zip the .app or create a DMG."
du -sh "$APP_BUNDLE"
