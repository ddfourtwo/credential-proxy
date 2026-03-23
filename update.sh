#!/bin/bash
set -euo pipefail

# Update credential-proxy: pull latest, rebuild MCP relay, replace binary.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Credential Proxy.app"
APP_PATH="/Applications/$APP_NAME"
MCP_RELAY_DIR="$APP_PATH/Contents/Resources/mcp-relay"

RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
RESET='\033[0m'

info() { echo -e "${DIM}$1${RESET}"; }
success() { echo -e "${GREEN}✓ $1${RESET}"; }
error() { echo -e "${RED}✗ $1${RESET}"; exit 1; }

# --- Preflight ---

if [ ! -d "$APP_PATH" ]; then
    error "App not found at $APP_PATH. Run install.sh first."
fi

echo ""
echo "Updating Credential Proxy..."
echo ""

# --- Stop all instances ---

info "Stopping app..."
pkill -x CredentialProxy 2>/dev/null || true
sleep 1

# --- Pull latest ---

cd "$SCRIPT_DIR"
info "Pulling latest changes..."
git pull
success "Pulled latest"

# --- Verify pre-built binary ---

PREBUILT_BIN="$SCRIPT_DIR/macos/bin/CredentialProxy"
if [ ! -f "$PREBUILT_BIN" ]; then
    error "Pre-built binary not found at $PREBUILT_BIN"
fi

# --- Build MCP relay ---

info "Building MCP relay..."
npm run build --silent 2>/dev/null
success "MCP relay built"

# --- Replace binary ---

cp "$PREBUILT_BIN" "$APP_PATH/Contents/MacOS/CredentialProxy"
codesign -s - -f "$APP_PATH/Contents/MacOS/CredentialProxy" 2>/dev/null
success "Binary updated"

# --- Update MCP relay ---

rm -rf "$MCP_RELAY_DIR"
mkdir -p "$MCP_RELAY_DIR"
cp -R "$SCRIPT_DIR/dist/"* "$MCP_RELAY_DIR/"
cp "$SCRIPT_DIR/package.json" "$MCP_RELAY_DIR/"
if [ -f "$SCRIPT_DIR/package-lock.json" ]; then
    cp "$SCRIPT_DIR/package-lock.json" "$MCP_RELAY_DIR/"
fi
cd "$MCP_RELAY_DIR"
npm ci --omit=dev --silent 2>/dev/null
cd "$SCRIPT_DIR"
success "MCP relay updated"

# --- Relaunch ---

info "Launching app..."
open "$APP_PATH"
success "App running"

echo ""
echo -e "${GREEN}Update complete!${RESET}"
echo -e "${DIM}Enter your PIN to unlock. Restart Claude Code to pick up changes.${RESET}"
