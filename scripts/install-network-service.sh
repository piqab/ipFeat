#!/bin/zsh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0"
    exit 1
fi

SCRIPT_DIR="${0:A:h}"
SERVICE_SOURCE="$SCRIPT_DIR/service"
REQUESTED_VERSION=""
if [[ $# -gt 0 ]]; then
    if [[ $# -ne 2 || "$1" != "--version" || ! "$2" =~ '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$' ]]; then
        echo "Usage: sudo $0 [--version X.Y.Z]"
        exit 1
    fi
    REQUESTED_VERSION="$2"
fi
TARGET_USER="${SUDO_USER:-$(/usr/bin/stat -f %Su /dev/console)}"
TARGET_HOME=$(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | /usr/bin/awk '{print $2}')
CONFIG="$TARGET_HOME/Library/Application Support/IPInformer/sing-box.json"
POLICY="$TARGET_HOME/Library/Application Support/IPInformer/engine-policy.json"
SING_BOX=""
PLIST="/Library/LaunchDaemons/com.ipinformer.network.plist"
UPDATER_PLIST="/Library/LaunchDaemons/com.ipinformer.updater.plist"
INSTALL_DIR="/Library/Application Support/IPInformer"
MANAGED_BINARY="$INSTALL_DIR/engines/current"
UPDATER_SOURCE="$SCRIPT_DIR/../../MacOS/IPInformerUpdater"
if [[ ! -x "$UPDATER_SOURCE" ]]; then
    UPDATER_SOURCE="$SCRIPT_DIR/../dist/IP Informer.app/Contents/MacOS/IPInformerUpdater"
fi

for candidate in /opt/homebrew/bin/sing-box /usr/local/bin/sing-box; do
    if [[ -x "$candidate" ]]; then
        SING_BOX="$candidate"
        break
    fi
done

if [[ -z "$SING_BOX" && -z "$REQUESTED_VERSION" && ! -x "$MANAGED_BINARY" ]]; then
    echo "sing-box not found. Install it first: brew install sing-box"
    exit 1
fi
if [[ ! -f "$CONFIG" ]]; then
    echo "Generated configuration not found: $CONFIG"
    echo "Open IP Informer settings once before installing the service."
    exit 1
fi
if [[ -n "$SING_BOX" ]] && ! "$SING_BOX" check -c "$CONFIG"; then
    echo "sing-box rejected the configuration. Nothing was installed."
    exit 1
fi

LOG_DIR="/Library/Logs/IPInformer"
/bin/mkdir -p "$INSTALL_DIR" "$LOG_DIR" /usr/local/bin
if [[ -x "$UPDATER_SOURCE" ]]; then
    /usr/bin/install -o root -g wheel -m 755 "$UPDATER_SOURCE" "$INSTALL_DIR/IPInformerUpdater"
fi
if [[ -n "$REQUESTED_VERSION" && ! -x "$MANAGED_BINARY" && -n "$SING_BOX" ]]; then
    # Preserve the existing Homebrew engine as a root-owned rollback point.
    INSTALLED_VERSION=$("$SING_BOX" version | /usr/bin/head -n 1 | /usr/bin/awk '{print $3}')
    if [[ "$INSTALLED_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$' ]]; then
        /bin/mkdir -p "$INSTALL_DIR/engines/$INSTALLED_VERSION-imported"
        /usr/bin/install -o root -g wheel -m 755 "$SING_BOX" "$INSTALL_DIR/engines/$INSTALLED_VERSION-imported/sing-box"
        /bin/ln -s "$INSTALL_DIR/engines/$INSTALLED_VERSION-imported/sing-box" "$MANAGED_BINARY"
        /bin/echo "{\"activeVersion\":\"$INSTALLED_VERSION\"}" > "$INSTALL_DIR/engine-status.json"
        /bin/chmod 644 "$INSTALL_DIR/engine-status.json"
        /usr/bin/install -o root -g wheel -m 600 "$CONFIG" "$INSTALL_DIR/engine-active-config.json"
    fi
fi
if [[ -n "$REQUESTED_VERSION" ]]; then
    if [[ ! -x "$INSTALL_DIR/IPInformerUpdater" ]]; then
        echo "IPInformerUpdater is missing from the application bundle."
        exit 1
    fi
    "$INSTALL_DIR/IPInformerUpdater" --config "$CONFIG" --install-version "$REQUESTED_VERSION" --no-restart
fi
if [[ -x "$MANAGED_BINARY" ]]; then
    SING_BOX="$MANAGED_BINARY"
fi
if [[ -z "$SING_BOX" ]] || ! "$SING_BOX" check -c "$CONFIG"; then
    echo "The selected sing-box version rejected the configuration."
    exit 1
fi

# A single TUN owner is mandatory. Stop our previous installation first, then
# refuse to compete with a Homebrew service or a manually started sing-box.
/bin/launchctl bootout system "$PLIST" 2>/dev/null || true
for _ in {1..10}; do
    /usr/bin/pgrep -x sing-box >/dev/null 2>&1 || break
    /bin/sleep 0.2
done
EXTERNAL_PIDS=$(/usr/bin/pgrep -x sing-box 2>/dev/null || true)
if [[ -n "$EXTERNAL_PIDS" ]]; then
    echo "Another sing-box instance is running (PID: $EXTERNAL_PIDS)."
    echo "Stop its service/process, then run this installer again."
    exit 1
fi
if /sbin/ifconfig utun100 >/dev/null 2>&1; then
    echo "utun100 is already in use. Stop the program that owns it and retry."
    exit 1
fi

PF_MAIN="/etc/pf.conf"
PF_ANCHOR="/etc/pf.anchors/com.ipinformer"

/usr/bin/install -o root -g wheel -m 755 "$SERVICE_SOURCE/ipinformer-supervisor.sh" "$INSTALL_DIR/ipinformer-supervisor.sh"
/usr/bin/install -o root -g wheel -m 755 "$SERVICE_SOURCE/ipinformer-recover.sh" /usr/local/bin/ipinformer-recover
/usr/bin/install -o root -g wheel -m 644 "$SERVICE_SOURCE/com.ipinformer.pf" "$PF_ANCHOR"

TEMP_PLIST=$(/usr/bin/mktemp)
/usr/bin/sed -e "s|__SING_BOX__|$SING_BOX|g" -e "s|__CONFIG__|$CONFIG|g" \
    "$SERVICE_SOURCE/com.ipinformer.network.plist" > "$TEMP_PLIST"
/usr/bin/plutil -lint "$TEMP_PLIST"
/usr/bin/install -o root -g wheel -m 644 "$TEMP_PLIST" "$PLIST"
/bin/rm -f "$TEMP_PLIST"

if [[ -x "$INSTALL_DIR/IPInformerUpdater" ]]; then
    TEMP_UPDATER_PLIST=$(/usr/bin/mktemp)
    /usr/bin/sed -e "s|__CONFIG__|$CONFIG|g" -e "s|__POLICY__|$POLICY|g" \
        "$SERVICE_SOURCE/com.ipinformer.updater.plist" > "$TEMP_UPDATER_PLIST"
    /usr/bin/plutil -lint "$TEMP_UPDATER_PLIST"
    /usr/bin/install -o root -g wheel -m 644 "$TEMP_UPDATER_PLIST" "$UPDATER_PLIST"
    /bin/rm -f "$TEMP_UPDATER_PLIST"
fi

ANCHOR_DECL='anchor "com.ipinformer"'
ANCHOR_LOAD='load anchor "com.ipinformer" from "/etc/pf.anchors/com.ipinformer"'
if ! /usr/bin/grep -q 'anchor "com.ipinformer"' "$PF_MAIN"; then
    TEMP_PF=$(/usr/bin/mktemp)
    /bin/cp "$PF_MAIN" "$PF_MAIN.ipinformer-backup"
    /bin/cp "$PF_MAIN" "$TEMP_PF"
    echo "$ANCHOR_DECL" >> "$TEMP_PF"
    echo "$ANCHOR_LOAD" >> "$TEMP_PF"
    /sbin/pfctl -nf "$TEMP_PF"
    /bin/cp "$TEMP_PF" "$PF_MAIN"
    /bin/rm -f "$TEMP_PF"
fi

/bin/launchctl bootout system "$PLIST" 2>/dev/null || true
/sbin/pfctl -f "$PF_MAIN"
/sbin/pfctl -E 2>/dev/null || true
/bin/launchctl bootstrap system "$PLIST"
if [[ -f "$UPDATER_PLIST" ]]; then
    /bin/launchctl bootout system "$UPDATER_PLIST" 2>/dev/null || true
    /bin/launchctl bootstrap system "$UPDATER_PLIST"
fi

TUN_READY=false
for _ in {1..20}; do
    if /sbin/ifconfig utun100 >/dev/null 2>&1; then
        TUN_READY=true
        break
    fi
    /bin/sleep 0.25
done
if [[ "$TUN_READY" != true ]]; then
    /bin/launchctl bootout system "$PLIST" 2>/dev/null || true
    /sbin/pfctl -a com.ipinformer -F all 2>/dev/null || true
    echo "sing-box did not create utun100; service stopped and kill switch cleared."
    echo "See $LOG_DIR/network.log"
    exit 1
fi

echo "IP Informer network service installed."
echo "Emergency recovery: sudo ipinformer-recover"
