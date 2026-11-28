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
CONFIG="$TARGET_HOME/Library/Application Support/ipFeat/sing-box.json"
POLICY="$TARGET_HOME/Library/Application Support/ipFeat/engine-policy.json"
SING_BOX=""
PLIST="/Library/LaunchDaemons/com.ipfeat.network.plist"
UPDATER_PLIST="/Library/LaunchDaemons/com.ipfeat.updater.plist"
INSTALL_DIR="/Library/Application Support/ipFeat"
MANAGED_BINARY="$INSTALL_DIR/engines/current"
LEGACY_INSTALL_DIR="/Library/Application Support/IPInformer"
LEGACY_PLIST="/Library/LaunchDaemons/com.ipinformer.network.plist"
LEGACY_UPDATER_PLIST="/Library/LaunchDaemons/com.ipinformer.updater.plist"
UPDATER_SOURCE="$SCRIPT_DIR/../../MacOS/ipFeatUpdater"
if [[ ! -x "$UPDATER_SOURCE" ]]; then
    UPDATER_SOURCE="$SCRIPT_DIR/../dist/ipFeat.app/Contents/MacOS/ipFeatUpdater"
fi

# Copy the previous installation before touching its running service. The old
# directory stays available as a rollback point until the new service is ready.
if [[ -d "$LEGACY_INSTALL_DIR" ]]; then
    /bin/mkdir -p "$INSTALL_DIR"
    for item in "$LEGACY_INSTALL_DIR"/*; do
        [[ -e "$item" || -L "$item" ]] || continue
        target="$INSTALL_DIR/${item:t}"
        [[ -e "$target" || -L "$target" ]] || /usr/bin/ditto "$item" "$target"
    done
fi
if [[ -L "$MANAGED_BINARY" ]]; then
    OLD_TARGET=$(/usr/bin/readlink "$MANAGED_BINARY")
    if [[ "$OLD_TARGET" == "$LEGACY_INSTALL_DIR"/* ]]; then
        NEW_TARGET="$INSTALL_DIR${OLD_TARGET#$LEGACY_INSTALL_DIR}"
        [[ -x "$NEW_TARGET" ]] && /bin/ln -sfn "$NEW_TARGET" "$MANAGED_BINARY"
    fi
fi
if [[ -f "$LEGACY_PLIST" ]] && [[ -x "$MANAGED_BINARY" ]] && \
   "$MANAGED_BINARY" version | /usr/bin/grep -Fq 'IPInformer patch: 1.14.4-'; then
    BUNDLED_PATCH="$SCRIPT_DIR/../../Resources/engines/sing-box-1.14.4-ipfeat-8"
    BUNDLED_HASH="$BUNDLED_PATCH.sha256"
    if [[ ! -x "$BUNDLED_PATCH" || ! -f "$BUNDLED_HASH" ]]; then
        echo "The ipFeat patched engine is missing from the app bundle."
        exit 1
    fi
    EXPECTED_HASH=$(/usr/bin/tr -d '[:space:]' < "$BUNDLED_HASH")
    ACTUAL_HASH=$(/usr/bin/shasum -a 256 "$BUNDLED_PATCH" | /usr/bin/awk '{print $1}')
    [[ "$ACTUAL_HASH" == "$EXPECTED_HASH" ]] || { echo "Bundled patched engine checksum mismatch"; exit 1; }
    PATCH_DIR="$INSTALL_DIR/engines/1.14.4-ipfeat-8"
    /bin/mkdir -p "$PATCH_DIR"
    /usr/bin/install -o root -g wheel -m 755 "$BUNDLED_PATCH" "$PATCH_DIR/sing-box"
    /bin/ln -sfn "$PATCH_DIR/sing-box" "$MANAGED_BINARY"
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
    echo "Open ipFeat settings once before installing the service."
    exit 1
fi
if [[ -n "$SING_BOX" ]] && ! "$SING_BOX" check -c "$CONFIG"; then
    echo "sing-box rejected the configuration. Nothing was installed."
    exit 1
fi

LOG_DIR="/Library/Logs/ipFeat"
/bin/mkdir -p "$INSTALL_DIR" "$LOG_DIR" /usr/local/bin
if [[ -x "$UPDATER_SOURCE" ]]; then
    /usr/bin/install -o root -g wheel -m 755 "$UPDATER_SOURCE" "$INSTALL_DIR/ipFeatUpdater"
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
    if [[ ! -x "$INSTALL_DIR/ipFeatUpdater" ]]; then
        echo "ipFeatUpdater is missing from the application bundle."
        exit 1
    fi
    "$INSTALL_DIR/ipFeatUpdater" --config "$CONFIG" --install-version "$REQUESTED_VERSION" --no-restart
fi
if [[ -x "$MANAGED_BINARY" ]]; then
    SING_BOX="$MANAGED_BINARY"
fi
LIVE_POLICY=""
if [[ -n "$SING_BOX" ]] && "$SING_BOX" version | /usr/bin/grep -Fq 'ipFeat patch: 1.14.4-'; then
    CONFIG="$TARGET_HOME/Library/Application Support/ipFeat/sing-box-base.json"
    LIVE_POLICY="$TARGET_HOME/Library/Application Support/ipFeat/sing-box-policy.json"
    if [[ ! -f "$CONFIG" || ! -f "$LIVE_POLICY" ]]; then
        echo "ipFeat live configuration is missing. Open ipFeat settings and retry."
        exit 1
    fi
fi
CHECK_ARGS=(-c "$CONFIG")
if [[ -n "$LIVE_POLICY" ]]; then
    CHECK_ARGS+=(--ipfeat-policy "$LIVE_POLICY")
fi
if [[ -z "$SING_BOX" ]] || ! "$SING_BOX" check "${CHECK_ARGS[@]}"; then
    echo "The selected sing-box version rejected the configuration."
    exit 1
fi

PF_MAIN="/etc/pf.conf"
PF_ANCHOR="/etc/pf.anchors/com.ipfeat"
ENGINE_GROUP="_ipfeat_engine"
if ! /usr/bin/dscl . -read "/Groups/$ENGINE_GROUP" PrimaryGroupID >/dev/null 2>&1; then
    ENGINE_GID=$(/usr/bin/dscl . -list /Groups PrimaryGroupID | /usr/bin/awk '
        $2 ~ /^[0-9]+$/ { used[$2] = 1 }
        END { for (gid = 30000; gid < 40000; gid++) if (!(gid in used)) { print gid; exit } }
    ')
    [[ -n "$ENGINE_GID" ]] || { echo "No free group ID for the sing-box service"; exit 1; }
    /usr/bin/dscl . -create "/Groups/$ENGINE_GROUP" PrimaryGroupID "$ENGINE_GID"
    /usr/bin/dscl . -create "/Groups/$ENGINE_GROUP" Password '*'
fi
ENGINE_GID=$(/usr/bin/dscl . -read "/Groups/$ENGINE_GROUP" PrimaryGroupID | /usr/bin/awk '$1 == "PrimaryGroupID:" { print $2 }')
[[ "$ENGINE_GID" =~ '^[0-9]+$' ]] || { echo "The sing-box service group has no numeric ID"; exit 1; }
PF_SNAPSHOT=$(/usr/bin/mktemp)
/bin/cp "$PF_MAIN" "$PF_SNAPSHOT"
PF_ANCHOR_SNAPSHOT=$(/usr/bin/mktemp)
PF_ANCHOR_EXISTED=false
if [[ -f "$PF_ANCHOR" ]]; then
    /bin/cp "$PF_ANCHOR" "$PF_ANCHOR_SNAPSHOT"
    PF_ANCHOR_EXISTED=true
fi
PLIST_SNAPSHOT=$(/usr/bin/mktemp)
PLIST_EXISTED=false
if [[ -f "$PLIST" ]]; then
    /bin/cp "$PLIST" "$PLIST_SNAPSHOT"
    PLIST_EXISTED=true
fi
OLD_SERVICE_STOPPED=false
CURRENT_SERVICE_STOPPED=false
MIGRATION_COMMITTED=false
restore_on_failure() {
    if [[ "$MIGRATION_COMMITTED" != true ]]; then
        if [[ "$CURRENT_SERVICE_STOPPED" == true ]]; then
            /bin/launchctl bootout system "$PLIST" 2>/dev/null || true
        fi
        if [[ "$PLIST_EXISTED" == true ]]; then
            /bin/cp "$PLIST_SNAPSHOT" "$PLIST" 2>/dev/null || true
        else
            /bin/rm -f "$PLIST"
        fi
        if [[ "$PF_ANCHOR_EXISTED" == true ]]; then
            /bin/cp "$PF_ANCHOR_SNAPSHOT" "$PF_ANCHOR" 2>/dev/null || true
        else
            /bin/rm -f "$PF_ANCHOR"
        fi
        /bin/cp "$PF_SNAPSHOT" "$PF_MAIN" 2>/dev/null || true
        /sbin/pfctl -f "$PF_MAIN" >/dev/null 2>&1 || true
        if [[ "$CURRENT_SERVICE_STOPPED" == true && "$PLIST_EXISTED" == true ]]; then
            /bin/launchctl bootstrap system "$PLIST" 2>/dev/null || true
        fi
        if [[ "$OLD_SERVICE_STOPPED" == true ]]; then
            /bin/launchctl bootstrap system "$LEGACY_PLIST" 2>/dev/null || true
            /bin/launchctl bootstrap system "$LEGACY_UPDATER_PLIST" 2>/dev/null || true
            echo "The prior IP Informer service was restored." >&2
        fi
    fi
    /bin/rm -f "$PF_SNAPSHOT" "$PF_ANCHOR_SNAPSHOT" "$PLIST_SNAPSHOT"
}
trap restore_on_failure EXIT

/usr/bin/install -o root -g wheel -m 755 "$SERVICE_SOURCE/ipfeat-supervisor.sh" "$INSTALL_DIR/ipfeat-supervisor.sh"
/usr/bin/install -o root -g wheel -m 755 "$SERVICE_SOURCE/ipfeat-recover.sh" /usr/local/bin/ipfeat-recover
/usr/bin/install -o root -g wheel -m 644 "$SERVICE_SOURCE/com.ipfeat.pf" "$PF_ANCHOR"

TEMP_PLIST=$(/usr/bin/mktemp)
/usr/bin/sed -e "s|__SING_BOX__|$SING_BOX|g" -e "s|__CONFIG__|$CONFIG|g" \
    -e "s|__LIVE_POLICY__|$LIVE_POLICY|g" \
    "$SERVICE_SOURCE/com.ipfeat.network.plist" > "$TEMP_PLIST"
/usr/bin/plutil -lint "$TEMP_PLIST"
/usr/bin/install -o root -g wheel -m 644 "$TEMP_PLIST" "$PLIST"
/bin/rm -f "$TEMP_PLIST"

if [[ -x "$INSTALL_DIR/ipFeatUpdater" ]]; then
    TEMP_UPDATER_PLIST=$(/usr/bin/mktemp)
    /usr/bin/sed -e "s|__CONFIG__|$CONFIG|g" -e "s|__POLICY__|$POLICY|g" \
        "$SERVICE_SOURCE/com.ipfeat.updater.plist" > "$TEMP_UPDATER_PLIST"
    /usr/bin/plutil -lint "$TEMP_UPDATER_PLIST"
    /usr/bin/install -o root -g wheel -m 644 "$TEMP_UPDATER_PLIST" "$UPDATER_PLIST"
    /bin/rm -f "$TEMP_UPDATER_PLIST"
fi

ANCHOR_DECL='anchor "com.ipfeat"'
ANCHOR_LOAD='load anchor "com.ipfeat" from "/etc/pf.anchors/com.ipfeat"'
TEMP_PF=$(/usr/bin/mktemp)
/usr/bin/sed -e '/^anchor "com.ipinformer"$/d' \
    -e '/^load anchor "com.ipinformer" from "\/etc\/pf.anchors\/com.ipinformer"$/d' \
    "$PF_MAIN" > "$TEMP_PF"
if ! /usr/bin/grep -q 'anchor "com.ipfeat"' "$TEMP_PF"; then
    echo "$ANCHOR_DECL" >> "$TEMP_PF"
    echo "$ANCHOR_LOAD" >> "$TEMP_PF"
fi
/sbin/pfctl -nf "$TEMP_PF"
/bin/cp "$TEMP_PF" "$PF_MAIN"
/bin/rm -f "$TEMP_PF"

# A single TUN owner is mandatory. Stop the previous installation only after
# validating the new configuration, installing its files and staging PF.
/bin/launchctl bootout system "$PLIST" 2>/dev/null || true
CURRENT_SERVICE_STOPPED=true
if [[ -f "$LEGACY_PLIST" ]]; then
    /bin/launchctl bootout system "$LEGACY_UPDATER_PLIST" 2>/dev/null || true
    /bin/launchctl bootout system "$LEGACY_PLIST" 2>/dev/null || true
    OLD_SERVICE_STOPPED=true
fi
for _ in {1..20}; do
    /usr/bin/pgrep -x sing-box >/dev/null 2>&1 || break
    /bin/sleep 0.2
done
EXTERNAL_PIDS=$(/usr/bin/pgrep -x sing-box 2>/dev/null || true)
if [[ -n "$EXTERNAL_PIDS" ]]; then
    echo "Another sing-box instance is running (PID: $EXTERNAL_PIDS)."
    exit 1
fi
if /sbin/ifconfig utun100 >/dev/null 2>&1; then
    echo "utun100 is already in use. Stop the program that owns it and retry."
    exit 1
fi
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
    echo "sing-box did not create utun100; the previous service will be restored if present."
    echo "See $LOG_DIR/network.log"
    exit 1
fi

MIGRATION_COMMITTED=true
if [[ "$OLD_SERVICE_STOPPED" == true ]]; then
    /sbin/pfctl -a com.ipinformer -F all 2>/dev/null || true
    /bin/rm -f "$LEGACY_PLIST" "$LEGACY_UPDATER_PLIST" /usr/local/bin/ipinformer-recover
    echo "Previous IP Informer service migrated to ipFeat. Old support files were retained as a backup."
fi

echo "ipFeat network service installed."
echo "Emergency recovery: sudo ipfeat-recover"
