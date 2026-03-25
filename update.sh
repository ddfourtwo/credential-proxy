#!/bin/bash
set -euo pipefail

# Update credential-proxy: pull latest, rebuild MCP relay, replace binary.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Credential Proxy.app"
APP_PATH="/Applications/$APP_NAME"
MCP_RELAY_DIR="$APP_PATH/Contents/Resources/mcp-relay"
APP_PORT=11111

RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
RESET='\033[0m'

info() { echo -e "${DIM}$1${RESET}"; }
success() { echo -e "${GREEN}✓ $1${RESET}"; }
error() { echo -e "${RED}✗ $1${RESET}"; exit 1; }

# Register credential-proxy MCP server in a JSON config file.
# Usage: register_mcp <config_path> <relay_index_path> [extra_fields_json]
register_mcp() {
    local config_path="$1"
    local relay_index="$2"
    local extra="${3}"
    : "${extra:="{}"}"

    node - "$config_path" "$relay_index" "$APP_PORT" "$extra" <<'REGISTER_SCRIPT'
const fs = require('fs');
const path = require('path');
const [,, configPath, relayIndex, portStr, extraJson] = process.argv;
const port = parseInt(portStr, 10);
const extra = JSON.parse(extraJson);

fs.mkdirSync(path.dirname(configPath), { recursive: true });

let config = {};
try { config = JSON.parse(fs.readFileSync(configPath, 'utf8')); } catch {}

const key = config['mcp-servers'] && !config.mcpServers ? 'mcp-servers' : 'mcpServers';
if (!config[key]) config[key] = {};

const entry = {
    ...config[key]['credential-proxy'],
    command: 'node',
    args: [relayIndex],
    env: { CREDENTIAL_PROXY_APP_URL: 'http://127.0.0.1:' + port },
    ...extra,
};
config[key]['credential-proxy'] = entry;

fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
REGISTER_SCRIPT
}

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

# --- Fix MCP configs ---

RELAY_INDEX="$MCP_RELAY_DIR/index.js"

register_mcp "$HOME/.claude.json" "$RELAY_INDEX"

PI_MCP="$HOME/.pi/agent/mcp.json"
if [ -d "$HOME/.pi/agent" ] || [ -f "$PI_MCP" ]; then
    register_mcp "$PI_MCP" "$RELAY_INDEX" '{"lifecycle":"keep-alive","directTools":true}'
fi

success "MCP configs updated"

# --- Relaunch ---

info "Launching app..."
open "$APP_PATH"
success "App running"

echo ""
echo -e "${GREEN}Update complete!${RESET}"
echo -e "${DIM}Enter your PIN to unlock. Restart Claude Code to pick up changes.${RESET}"
