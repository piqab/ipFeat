#!/bin/zsh
set -euo pipefail

LABEL="com.ipinformer.network"
ANCHOR="com.ipinformer"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo ipinformer-recover"
    exit 1
fi

/bin/launchctl bootout system "/Library/LaunchDaemons/$LABEL.plist" 2>/dev/null || true
/sbin/pfctl -a "$ANCHOR" -F all 2>/dev/null || true
echo "IP Informer network service stopped and kill switch cleared."
