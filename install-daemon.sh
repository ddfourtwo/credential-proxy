#!/bin/bash
# Install credential-proxy headless daemon as a LaunchAgent (macOS)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_NAME="com.credential-proxy.daemon.plist"
PLIST_SRC="$SCRIPT_DIR/launchd/$PLIST_NAME"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
BINARY_DEST="$HOME/.local/bin/credential-proxy-daemon"
LOG_PATH="$HOME/Library/Logs/credential-proxy-daemon.log"
DATA_DIR="$HOME/Library/Application Support/credential-proxy"

# Check daemon key exists
if [ ! -f "$DATA_DIR/daemon.key" ]; then
    echo "❌ daemon.key not found at $DATA_DIR/daemon.key"
    echo "   Enable daemon mode in the GUI app first (Enable Daemon Mode menu item)"
    exit 1
fi

# Build daemon
echo "Building daemon..."
cd "$SCRIPT_DIR/macos"
swift build -c release --product CredentialProxyDaemon
cd "$SCRIPT_DIR"

# Install binary
echo "Installing binary..."
mkdir -p "$HOME/.local/bin"
cp "$SCRIPT_DIR/macos/.build/release/CredentialProxyDaemon" "$BINARY_DEST"
codesign -s - --force "$BINARY_DEST"

# Stop existing service if running
if launchctl list 2>/dev/null | grep -q "com.credential-proxy.daemon"; then
    echo "Stopping existing daemon..."
    launchctl bootout "gui/$(id -u)/com.credential-proxy.daemon" 2>/dev/null || true
    sleep 1
fi

# Install plist with correct paths
echo "Installing LaunchAgent..."
sed -e "s|__BINARY_PATH__|$BINARY_DEST|g" \
    -e "s|__LOG_PATH__|$LOG_PATH|g" \
    "$PLIST_SRC" > "$PLIST_DEST"

# Load service
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"

# Verify
sleep 2
if curl -s http://127.0.0.1:11111/health | grep -q "ok"; then
    echo ""
    echo "✅ credential-proxy daemon running on port 11111"
    echo ""
    echo "Service commands:"
    echo "  Stop:    launchctl bootout gui/$(id -u)/com.credential-proxy.daemon"
    echo "  Start:   launchctl bootstrap gui/$(id -u) $PLIST_DEST"
    echo "  Logs:    tail -f $LOG_PATH"
else
    echo ""
    echo "⚠️  Daemon installed but health check failed"
    echo "Check logs: tail -f $LOG_PATH"
    exit 1
fi
