#!/bin/zsh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0"
    exit 1
fi

/bin/launchctl bootout system /Library/LaunchDaemons/com.ipfeat.network.plist 2>/dev/null || true
/bin/launchctl bootout system /Library/LaunchDaemons/com.ipfeat.updater.plist 2>/dev/null || true
/bin/launchctl bootout system /Library/LaunchDaemons/com.ipinformer.network.plist 2>/dev/null || true
/bin/launchctl bootout system /Library/LaunchDaemons/com.ipinformer.updater.plist 2>/dev/null || true
/sbin/pfctl -a com.ipfeat -F all 2>/dev/null || true
/sbin/pfctl -a com.ipinformer -F all 2>/dev/null || true
/bin/rm -f /Library/LaunchDaemons/com.ipfeat.network.plist
/bin/rm -f /Library/LaunchDaemons/com.ipfeat.updater.plist
/bin/rm -f /Library/LaunchDaemons/com.ipinformer.network.plist
/bin/rm -f /Library/LaunchDaemons/com.ipinformer.updater.plist
/bin/rm -f "/Library/Application Support/ipFeat/ipfeat-supervisor.sh"
/bin/rm -f "/Library/Application Support/ipFeat/ipFeatUpdater"
/bin/rm -f /usr/local/bin/ipfeat-recover
/usr/bin/dscl . -delete /Groups/_ipfeat_engine 2>/dev/null || true

echo "Service removed and kill switch cleared."
echo "The anchor declaration remains in /etc/pf.conf but contains no active rules."
