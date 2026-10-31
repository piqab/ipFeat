#!/bin/zsh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0"
    exit 1
fi

/bin/launchctl bootout system /Library/LaunchDaemons/com.ipinformer.network.plist 2>/dev/null || true
/bin/launchctl bootout system /Library/LaunchDaemons/com.ipinformer.updater.plist 2>/dev/null || true
/sbin/pfctl -a com.ipinformer -F all 2>/dev/null || true
/bin/rm -f /Library/LaunchDaemons/com.ipinformer.network.plist
/bin/rm -f /Library/LaunchDaemons/com.ipinformer.updater.plist
/bin/rm -f "/Library/Application Support/IPInformer/ipinformer-supervisor.sh"
/bin/rm -f "/Library/Application Support/IPInformer/IPInformerUpdater"
/bin/rm -f /usr/local/bin/ipinformer-recover

echo "Service removed and kill switch cleared."
echo "The anchor declaration remains in /etc/pf.conf but contains no active rules."
