#!/bin/bash
set -euo pipefail

# Credential Proxy installer
# Builds the macOS app + Node.js MCP server and installs them

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Credential Proxy.app"
INSTALL_DIR="$HOME/Applications"
APP_PATH="$INSTALL_DIR/$APP_NAME"
CLAUDE_JSON="$HOME/.claude.json"
MCP_SERVER_DIR="$APP_PATH/Contents/Resources/mcp-server"

RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
RESET='\033[0m'

info() { echo -e "${DIM}$1${RESET}"; }
success() { echo -e "${GREEN}✓ $1${RESET}"; }
error() { echo -e "${RED}✗ $1${RESET}"; exit 1; }

# --- Preflight checks ---

command -v node >/dev/null 2>&1 || error "Node.js is required. Install it from https://nodejs.org"
command -v npm >/dev/null 2>&1 || error "npm is required"
command -v swift >/dev/null 2>&1 || error "Swift is required. Install Xcode Command Line Tools: xcode-select --install"

NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
if [ "$NODE_VERSION" -lt 20 ]; then
    error "Node.js 20+ is required (found v$(node -v))"
fi

echo ""
echo "Installing Credential Proxy..."
echo ""

# --- Step 1: Build Node.js MCP server ---

info "Building Node.js MCP server..."
cd "$SCRIPT_DIR"

if [ ! -d node_modules ]; then
    npm install --silent 2>/dev/null
fi
npm run build --silent 2>/dev/null
success "Node.js server built"

# --- Step 2: Build Swift macOS app ---

info "Building macOS app..."
cd "$SCRIPT_DIR/macos"
swift build -c release --quiet 2>/dev/null
SWIFT_BIN="$(swift build -c release --show-bin-path)/CredentialProxy"
success "macOS app built"

# --- Step 3: Create .app bundle ---

info "Creating app bundle..."
mkdir -p "$INSTALL_DIR"

# Remove old installation
if [ -d "$APP_PATH" ]; then
    # Kill running instance
    pkill -f "$APP_PATH/Contents/MacOS/CredentialProxy" 2>/dev/null || true
    sleep 0.5
    rm -rf "$APP_PATH"
fi

# Create bundle structure
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"
mkdir -p "$MCP_SERVER_DIR"

# Copy binary
cp "$SWIFT_BIN" "$APP_PATH/Contents/MacOS/CredentialProxy"

# Copy Info.plist
cp "$SCRIPT_DIR/macos/Info.plist" "$APP_PATH/Contents/Info.plist"

# Copy Node.js server files
cp -R "$SCRIPT_DIR/dist/"* "$MCP_SERVER_DIR/"
cp "$SCRIPT_DIR/package.json" "$MCP_SERVER_DIR/"
if [ -f "$SCRIPT_DIR/package-lock.json" ]; then
    cp "$SCRIPT_DIR/package-lock.json" "$MCP_SERVER_DIR/"
fi

# Install production dependencies in bundle
cd "$MCP_SERVER_DIR"
npm ci --omit=dev --silent 2>/dev/null
cd "$SCRIPT_DIR"

success "App bundle created at $APP_PATH"

# --- Step 4: Register MCP server in Claude config ---

info "Configuring Claude Code MCP server..."

# The MCP server entry points to the bundled server inside the app
MCP_INDEX="$MCP_SERVER_DIR/index.js"

if [ -f "$CLAUDE_JSON" ]; then
    # Update existing config
    node -e "
        const fs = require('fs');
        const config = JSON.parse(fs.readFileSync('$CLAUDE_JSON', 'utf8'));
        config.mcpServers = config.mcpServers || {};
        config.mcpServers['credential-proxy'] = {
            type: 'stdio',
            command: 'node',
            args: ['$MCP_INDEX']
        };
        fs.writeFileSync('$CLAUDE_JSON', JSON.stringify(config, null, 2));
    "
else
    # Create new config
    node -e "
        const fs = require('fs');
        const config = {
            mcpServers: {
                'credential-proxy': {
                    type: 'stdio',
                    command: 'node',
                    args: ['$MCP_INDEX']
                }
            }
        };
        fs.writeFileSync('$CLAUDE_JSON', JSON.stringify(config, null, 2));
    "
fi
success "Claude Code MCP server configured"

# --- Step 5: Migrate existing data if present ---

OLD_DATA_DIR="$HOME/.local/share/credential-proxy"
NEW_DATA_DIR="$HOME/Library/Application Support/CredentialProxy"

if [ -d "$OLD_DATA_DIR" ] && [ ! -d "$NEW_DATA_DIR" ]; then
    info "Migrating existing credentials..."
    mkdir -p "$NEW_DATA_DIR"
    chmod 700 "$NEW_DATA_DIR"
    cp -p "$OLD_DATA_DIR"/* "$NEW_DATA_DIR/" 2>/dev/null || true
    if [ -d "$OLD_DATA_DIR/logs" ]; then
        cp -Rp "$OLD_DATA_DIR/logs" "$NEW_DATA_DIR/" 2>/dev/null || true
    fi
    success "Migrated credentials from $OLD_DATA_DIR"
elif [ -d "$NEW_DATA_DIR" ]; then
    info "Existing data directory found (credentials preserved)"
fi

# --- Step 6: Set up Login Item (launch at login) ---

LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS/com.credential-proxy.app.plist"

mkdir -p "$LAUNCH_AGENTS"
cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.credential-proxy.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>open</string>
        <string>-a</string>
        <string>$APP_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
PLIST
success "Launch agent configured (starts at login)"

# --- Step 7: Launch the app ---

info "Launching Credential Proxy..."
open "$APP_PATH"
success "Credential Proxy is running"

echo ""
echo -e "${GREEN}Installation complete!${RESET}"
echo ""
echo "  App:         $APP_PATH"
echo "  Data:        $NEW_DATA_DIR"
echo "  MCP Server:  $MCP_INDEX"
echo ""
echo "  The key icon in your menu bar indicates Credential Proxy is running."
echo "  Click it to manage credentials."
echo ""
echo -e "${DIM}Restart Claude Code to load the MCP server.${RESET}"
