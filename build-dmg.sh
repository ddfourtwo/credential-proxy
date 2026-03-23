#!/bin/bash
set -euo pipefail

# Build a distributable DMG for Credential Proxy.
# Prerequisites: run install.sh first (or have the .app in /Applications).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Credential Proxy"
APP_PATH="/Applications/$APP_NAME.app"
DMG_NAME="CredentialProxy"
VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")
DMG_FILE="$SCRIPT_DIR/$DMG_NAME-$VERSION.dmg"
TEMP_DMG="/tmp/cp-build-temp.dmg"

RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
RESET='\033[0m'

info() { echo -e "${DIM}$1${RESET}"; }
success() { echo -e "${GREEN}✓ $1${RESET}"; }
error() { echo -e "${RED}✗ $1${RESET}"; exit 1; }

cleanup() {
    hdiutil detach "/Volumes/$APP_NAME" -force 2>/dev/null || true
    command rm -f "$TEMP_DMG"
}
trap cleanup EXIT

# --- Preflight ---

if [ ! -d "$APP_PATH" ]; then
    error "$APP_PATH not found. Run install.sh first."
fi

echo ""
echo "Building DMG for $APP_NAME $VERSION..."
echo ""

# --- Calculate size ---

APP_SIZE_MB=$(du -sm "$APP_PATH" | cut -f1)
DMG_SIZE_MB=$(( APP_SIZE_MB + 10 ))  # padding for filesystem overhead + symlink

# --- Create writable DMG, copy contents ---

info "Creating disk image..."
command rm -f "$TEMP_DMG" "$DMG_FILE"
hdiutil create -volname "$APP_NAME" -size "${DMG_SIZE_MB}m" -fs HFS+ "$TEMP_DMG" >/dev/null 2>&1
hdiutil attach "$TEMP_DMG" -nobrowse >/dev/null 2>&1
success "Disk image created"

info "Copying app bundle..."
command cp -R "$APP_PATH" "/Volumes/$APP_NAME/"
ln -s /Applications "/Volumes/$APP_NAME/Applications"
success "App bundle copied"

# --- Convert to compressed DMG ---

info "Compressing..."
hdiutil detach "/Volumes/$APP_NAME" -force >/dev/null 2>&1
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_FILE" -ov >/dev/null 2>&1
success "Compressed"

# --- Done ---

DMG_SIZE=$(du -h "$DMG_FILE" | cut -f1 | xargs)
echo ""
echo -e "${GREEN}Build complete!${RESET}"
echo ""
echo "  DMG:     $DMG_FILE"
echo "  Size:    $DMG_SIZE"
echo "  Version: $VERSION"
echo ""
echo "  To install: Open the DMG, drag $APP_NAME to Applications."
echo "  The app auto-configures Claude Code on first launch."
