#!/bin/bash
set -e

APP_NAME="Leif"
BUNDLE_ID="com.leif.loginspector"
BUILD_DIR=".build/release"
APP_DIR="dist/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "Building ${APP_NAME} (universal: arm64 + x86_64)..."
swift build -c release --arch arm64 2>&1
swift build -c release --arch x86_64 2>&1

echo "Creating app bundle..."
rm -rf dist
mkdir -p "${MACOS}" "${RESOURCES}"

# Universal binary
lipo -create \
    ".build/arm64-apple-macosx/release/${APP_NAME}" \
    ".build/x86_64-apple-macosx/release/${APP_NAME}" \
    -output "${MACOS}/${APP_NAME}"

# App icon
if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${RESOURCES}/AppIcon.icns"
fi

# Info.plist
cat > "${CONTENTS}/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSRequiresAquaSystemAppearance</key>
    <false/>
</dict>
</plist>
PLIST

# Ad-hoc sign so it runs on any Mac (no developer account needed)
codesign --force --deep --sign - "${APP_DIR}"

# Create zip using ditto (preserves execute permissions, unlike Finder Compress)
ditto -c -k --keepParent "${APP_DIR}" "dist/${APP_NAME}.zip"

echo ""
echo "Done! App bundle at: dist/Leif.app"
echo "Zip for sharing:     dist/Leif.zip"
echo ""
echo "To install: cp -r dist/Leif.app /Applications/"
echo "To run:     open dist/Leif.app"
echo ""
echo "Share dist/Leif.zip with teammates (NOT via Finder Compress)."
