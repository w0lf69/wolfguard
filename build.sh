#!/bin/bash
# WolfGuard build script — creates .txz package and .plg installer
set -euo pipefail

PLUGIN_NAME="wolfguard"
VERSION="${1:-$(date +%Y.%m.%d)}"
BUILD_DIR="./build"
SRC_DIR="./src"

echo "Building WolfGuard v${VERSION}..."

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Copy source to build directory
cp -R "$SRC_DIR"/* "$BUILD_DIR/"

# Set permissions
find "$BUILD_DIR" -type d -exec chmod 755 {} \;
find "$BUILD_DIR" -type f -exec chmod 644 {} \;
find "$BUILD_DIR" -name "*.sh" -exec chmod 755 {} \;
find "$BUILD_DIR" -name "*.php" -exec chmod 644 {} \;
find "$BUILD_DIR" -path "*/event/*" -type f -exec chmod 755 {} \;
chmod 755 "$BUILD_DIR/etc/rc.d/rc.wolfguard"

# Convert line endings (safety)
find "$BUILD_DIR" -type f \( -name "*.sh" -o -name "*.page" -o -name "*.php" -o -name "*.cfg" \) \
    -exec sed -i 's/\r$//' {} \;

# Create Slackware package
cd "$BUILD_DIR"
TXZ_FILE="../${PLUGIN_NAME}-${VERSION}.txz"
tar -cJf "$TXZ_FILE" .
cd ..

# Generate SHA256
TXZ_SHA256=$(sha256sum "${PLUGIN_NAME}-${VERSION}.txz" | cut -d' ' -f1)

echo "Package: ${PLUGIN_NAME}-${VERSION}.txz"
echo "SHA256:  ${TXZ_SHA256}"
echo "Size:    $(du -h "${PLUGIN_NAME}-${VERSION}.txz" | cut -f1)"

# Generate PLG file
GITHUB_BASE="https://github.com/w0lf69/wolfguard/releases/download/v${VERSION}"

sed -e "s|%%VERSION%%|${VERSION}|g" \
    -e "s|%%TXZ_SHA256%%|${TXZ_SHA256}|g" \
    -e "s|%%TXZ_URL%%|${GITHUB_BASE}/${PLUGIN_NAME}-${VERSION}.txz|g" \
    wolfguard.plg.template > "${PLUGIN_NAME}.plg"

echo "PLG:     ${PLUGIN_NAME}.plg"
echo ""
echo "Build complete. Files:"
echo "  ${PLUGIN_NAME}-${VERSION}.txz  (upload to GitHub release)"
echo "  ${PLUGIN_NAME}.plg             (install URL for Unraid)"

# Clean build dir
rm -rf "$BUILD_DIR"
