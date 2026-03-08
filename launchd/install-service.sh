#!/bin/bash
# Install credential-proxy HTTP server as a launchd service (macOS)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_NAME="com.claudetmux.credential-proxy.plist"
PLIST_SRC="$SCRIPT_DIR/$PLIST_NAME"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

# Find node
NODE_PATH=$(which node 2>/dev/null || echo "/opt/homebrew/bin/node")
if [ ! -x "$NODE_PATH" ]; then
    echo "Error: node not found. Install Node.js first."
    exit 1
fi

# Create logs directory
mkdir -p "$HOME/.local/share/credential-proxy/logs"

# Stop existing service if running
if launchctl list | grep -q "com.claudetmux.credential-proxy"; then
    echo "Stopping existing service..."
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
fi

# Generate plist with correct paths
echo "Installing launchd service..."
sed -e "s|__NODE_PATH__|$NODE_PATH|g" \
    -e "s|__HOME__|$HOME|g" \
    "$PLIST_SRC" > "$PLIST_DEST"

# Load and start service
launchctl load "$PLIST_DEST"

# Verify
sleep 2
if curl -s http://127.0.0.1:8787/health | grep -q "ok"; then
    echo "✅ credential-proxy HTTP server running on port 8787"
    echo ""
    echo "Service commands:"
    echo "  Stop:    launchctl unload ~/Library/LaunchAgents/$PLIST_NAME"
    echo "  Start:   launchctl load ~/Library/LaunchAgents/$PLIST_NAME"
    echo "  Logs:    tail -f ~/.local/share/credential-proxy/logs/http-server.log"
else
    echo "❌ Service started but health check failed"
    echo "Check logs: ~/.local/share/credential-proxy/logs/http-server.err"
    exit 1
fi
