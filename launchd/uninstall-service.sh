#!/bin/bash
# Uninstall credential-proxy HTTP server launchd service (macOS)

PLIST_NAME="com.claudetmux.credential-proxy.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

if [ -f "$PLIST_DEST" ]; then
    echo "Stopping and removing service..."
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    rm "$PLIST_DEST"
    echo "✅ Service removed"
else
    echo "Service not installed"
fi
