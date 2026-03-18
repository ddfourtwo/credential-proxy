#!/bin/bash
set -euo pipefail

# Credential Proxy installer
# Builds the native macOS app (Swift HTTP server) + thin MCP relay (stdio→HTTP bridge)
# All credential handling happens in compiled Swift — the agent cannot modify it

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Credential Proxy.app"
INSTALL_DIR="$HOME/Applications"
APP_PATH="$INSTALL_DIR/$APP_NAME"
CLAUDE_JSON="$HOME/.claude.json"
MCP_RELAY_DIR="$APP_PATH/Contents/Resources/mcp-relay"

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
NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
if [ "$NODE_VERSION" -lt 20 ]; then
    error "Node.js 20+ is required (found v$(node -v))"
fi

echo ""
echo "Installing Credential Proxy..."
echo ""

# --- Step 1: Build Node.js MCP relay ---

info "Building MCP relay (stdio → HTTP bridge)..."
cd "$SCRIPT_DIR"

if [ ! -d node_modules ]; then
    npm install --silent 2>/dev/null
fi
npm run build --silent 2>/dev/null
success "MCP relay built"

# --- Step 2: Locate pre-built macOS binary ---

PREBUILT_BIN="$SCRIPT_DIR/macos/bin/CredentialProxy"
if [ ! -f "$PREBUILT_BIN" ]; then
    error "Pre-built binary not found at $PREBUILT_BIN. Run 'cd macos && swift build -c release' and copy the binary to macos/bin/ first."
fi
success "Pre-built macOS binary found"

# --- Step 3: Create .app bundle ---

info "Creating app bundle..."
mkdir -p "$INSTALL_DIR"

# Remove old installation
if [ -d "$APP_PATH" ]; then
    pkill -f "$APP_PATH/Contents/MacOS/CredentialProxy" 2>/dev/null || true
    sleep 0.5
    rm -rf "$APP_PATH"
fi

# Create bundle structure
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"
mkdir -p "$MCP_RELAY_DIR"

# Copy app binary (includes native HTTP server — no Node.js server needed)
cp "$PREBUILT_BIN" "$APP_PATH/Contents/MacOS/CredentialProxy"

# Copy Info.plist
cp "$SCRIPT_DIR/macos/Info.plist" "$APP_PATH/Contents/Info.plist"

# Copy MCP relay files (thin stdio→HTTP bridge, never touches secrets)
cp -R "$SCRIPT_DIR/dist/"* "$MCP_RELAY_DIR/"
cp "$SCRIPT_DIR/package.json" "$MCP_RELAY_DIR/"
if [ -f "$SCRIPT_DIR/package-lock.json" ]; then
    cp "$SCRIPT_DIR/package-lock.json" "$MCP_RELAY_DIR/"
fi

# Install production dependencies for relay (just @modelcontextprotocol/sdk)
cd "$MCP_RELAY_DIR"
npm ci --omit=dev --silent 2>/dev/null
cd "$SCRIPT_DIR"

# Ad-hoc sign the binary — Keychain ACLs are bound to this signature.
# A rebuilt binary gets a different signature, so Keychain will prompt
# the user before granting access. This prevents agents from silently
# rebuilding to exfiltrate secrets.
codesign -s - -f "$APP_PATH/Contents/MacOS/CredentialProxy" 2>/dev/null
success "App bundle created and signed at $APP_PATH"

# --- Step 4: Register MCP server in Claude config ---

info "Configuring Claude Code MCP server..."

# MCP stdio server in relay mode: forwards tool calls to the app's HTTP server.
# The stdio server never accesses secrets directly.
MCP_INDEX="$MCP_RELAY_DIR/index.js"

if command -v ctmux-mcp >/dev/null 2>&1; then
    # Use ctmux-mcp registry for multi-backend support
    ctmux-mcp register credential-proxy "{
        \"command\": \"node\",
        \"args\": [\"$MCP_RELAY_DIR/index.js\"],
        \"env\": {\"CREDENTIAL_PROXY_APP_URL\": \"http://127.0.0.1:11111\"},
        \"backendOverrides\": {
            \"claude-code\": {\"type\": \"stdio\"},
            \"pi\": {
                \"lifecycle\": \"keep-alive\",
                \"directTools\": true,
                \"args\": [\"$MCP_RELAY_DIR/index.js\"]
            }
        }
    }"
    ctmux-mcp sync
    success "Registered credential-proxy in MCP registry"
else
    # Fallback: direct ~/.claude.json write
    if [ -f "$CLAUDE_JSON" ]; then
        node -e "
            const fs = require('fs');
            const config = JSON.parse(fs.readFileSync('$CLAUDE_JSON', 'utf8'));
            config.mcpServers = config.mcpServers || {};
            config.mcpServers['credential-proxy'] = {
                type: 'stdio',
                command: 'node',
                args: ['$MCP_INDEX'],
                env: {
                    CREDENTIAL_PROXY_APP_URL: 'http://127.0.0.1:11111'
                }
            };
            fs.writeFileSync('$CLAUDE_JSON', JSON.stringify(config, null, 2));
        "
    else
        node -e "
            const fs = require('fs');
            const config = {
                mcpServers: {
                    'credential-proxy': {
                        type: 'stdio',
                        command: 'node',
                        args: ['$MCP_INDEX'],
                        env: {
                            CREDENTIAL_PROXY_APP_URL: 'http://127.0.0.1:11111'
                        }
                    }
                }
            };
            fs.writeFileSync('$CLAUDE_JSON', JSON.stringify(config, null, 2));
        "
    fi
    success "Claude Code MCP relay configured (stdio → native HTTP server)"
fi

# --- Step 5: Migrate existing secrets to Keychain ---

OLD_DATA_DIR="$HOME/.local/share/credential-proxy"
NEW_DATA_DIR="$HOME/Library/Application Support/credential-proxy"

mkdir -p "$NEW_DATA_DIR"
chmod 700 "$NEW_DATA_DIR"

# Migrate encrypted secrets to Keychain if secrets.json + secrets.key exist
if [ -f "$OLD_DATA_DIR/secrets.json" ] && [ -f "$OLD_DATA_DIR/secrets.key" ]; then
    info "Migrating encrypted secrets to macOS Keychain..."
    node -e "
        const fs = require('fs');
        const crypto = require('crypto');
        const { execFileSync } = require('child_process');

        const secretsFile = '$OLD_DATA_DIR/secrets.json';
        const keyFile = '$OLD_DATA_DIR/secrets.key';
        const store = JSON.parse(fs.readFileSync(secretsFile, 'utf8'));
        const masterKey = fs.readFileSync(keyFile, 'utf8').trim();

        function decrypt(encryptedStr, key) {
            const data = JSON.parse(encryptedStr);
            const derivedKey = crypto.scryptSync(key, Buffer.from(data.salt, 'hex'), 32);
            const decipher = crypto.createDecipheriv('aes-256-gcm', derivedKey, Buffer.from(data.iv, 'hex'));
            decipher.setAuthTag(Buffer.from(data.authTag, 'hex'));
            return decipher.update(data.encrypted, 'hex', 'utf8') + decipher.final('utf8');
        }

        let migrated = 0;
        for (const [name, meta] of Object.entries(store.secrets || {})) {
            const source = meta.source || { type: 'encrypted', encryptedValue: meta.encryptedValue };
            if (source.type !== 'encrypted') continue;
            try {
                const value = decrypt(source.encryptedValue, masterKey);
                // Store in Keychain using security command
                try {
                    execFileSync('security', ['delete-generic-password', '-s', 'com.credential-proxy.secrets', '-a', name], { stdio: 'ignore' });
                } catch {}
                execFileSync('security', ['add-generic-password', '-s', 'com.credential-proxy.secrets', '-a', name, '-w', value, '-l', 'Credential Proxy: ' + name]);
                migrated++;
            } catch (e) {
                console.error('  Failed to migrate ' + name + ': ' + e.message);
            }
        }

        // Copy metadata (without encrypted values) to new data dir
        const metadata = { version: store.version || 2, secrets: {} };
        for (const [name, meta] of Object.entries(store.secrets || {})) {
            metadata.secrets[name] = {
                source: meta.source?.type === '1password' ? meta.source : { type: 'keychain' },
                allowedDomains: meta.allowedDomains,
                allowedPlacements: meta.allowedPlacements,
                allowedCommands: meta.allowedCommands,
                createdAt: meta.createdAt,
                lastUsed: meta.lastUsed,
                usageCount: meta.usageCount
            };
        }
        fs.writeFileSync('$NEW_DATA_DIR/secrets.json', JSON.stringify(metadata, null, 2), { mode: 0o600 });

        if (migrated > 0) console.log('  Migrated ' + migrated + ' secret(s) to Keychain');
    " 2>&1 && success "Secrets migrated to macOS Keychain" || info "No secrets to migrate"

    # Copy logs
    if [ -d "$OLD_DATA_DIR/logs" ]; then
        cp -Rp "$OLD_DATA_DIR/logs" "$NEW_DATA_DIR/" 2>/dev/null || true
    fi
elif [ -d "$NEW_DATA_DIR" ]; then
    info "Existing data directory found (credentials preserved)"
fi

# --- Step 6: Set up Launch Agent ---

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
echo "  Secrets:     macOS Keychain (service: com.credential-proxy.secrets)"
echo "  HTTP Server: Native Swift (compiled into app binary)"
echo "  MCP Relay:   stdio → http://127.0.0.1:11111"
echo ""
echo "  The key icon in your menu bar indicates Credential Proxy is running."
echo "  Click it to manage credentials."
echo ""
echo -e "${DIM}Restart Claude Code to load the MCP server.${RESET}"
