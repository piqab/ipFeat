#!/bin/zsh
set -euo pipefail

LABEL="com.ipfeat.network"
ANCHOR="com.ipfeat"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo ipfeat-recover"
    exit 1
fi

/bin/launchctl bootout system "/Library/LaunchDaemons/$LABEL.plist" 2>/dev/null || true
/sbin/pfctl -a "$ANCHOR" -F all 2>/dev/null || true
/sbin/pfctl -a com.ipinformer -F all 2>/dev/null || true
echo "ipFeat network service stopped and kill switch cleared."
