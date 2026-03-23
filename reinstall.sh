#!/bin/bash
set -euo pipefail

# Reinstall credential-proxy: pull, build, and replace the running app + MCP server.
# Requires the macOS app to be in "Ready for Update" mode (Prepare for Update button).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="/Applications/Credential Proxy.app"
MIGRATION_FILE="$HOME/Library/Application Support/credential-proxy/seal.migration"

RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
RESET='\033[0m'

info() { echo -e "${DIM}$1${RESET}"; }
success() { echo -e "${GREEN}✓ $1${RESET}"; }
error() { echo -e "${RED}✗ $1${RESET}"; exit 1; }

# --- Preflight: require "Ready for Update" mode ---

if [ ! -f "$MIGRATION_FILE" ]; then
    error "App is not in 'Ready for Update' mode. Click 'Prepare for Update' in the menu bar first."
fi
success "App is ready for update"

# --- Pull latest ---

cd "$SCRIPT_DIR"
info "Pulling latest changes..."
git pull
success "Pulled latest"

# --- Build MCP server ---

info "Building MCP server..."
npm run build --silent 2>/dev/null
success "MCP server built"

# --- Install MCP server ---

info "Installing MCP server..."
node dist/cli/index.js install
success "MCP server installed"

# --- Replace binary and relaunch ---

PREBUILT_BIN="$SCRIPT_DIR/macos/bin/CredentialProxy"
if [ ! -f "$PREBUILT_BIN" ]; then
    error "Pre-built binary not found at $PREBUILT_BIN. Run 'cd macos && swift build -c release' and copy the binary to macos/bin/ first."
fi

info "Stopping app..."
pkill -x CredentialProxy || true
sleep 1

cp "$PREBUILT_BIN" "$APP_PATH/Contents/MacOS/CredentialProxy"
success "Binary replaced"

info "Relaunching app..."
open "$APP_PATH"
success "App relaunched"

echo ""
echo -e "${GREEN}Update complete!${RESET}"
echo -e "${DIM}Enter your PIN in the menu bar to complete migration and unlock.${RESET}"
echo -e "${DIM}Restart Claude Code to load the updated MCP server.${RESET}"
