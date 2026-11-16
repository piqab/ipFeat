#!/bin/zsh
set -euo pipefail

if [[ $EUID -ne 0 || $# -ne 1 || ( "$1" != "--install" && "$1" != "--remove" ) ]]; then
    echo "Usage: sudo $0 --install|--remove"
    exit 1
fi

SCRIPT_DIR="${0:A:h}"
RESOURCE_DIR="${SCRIPT_DIR:h}"
ENGINES="/Library/Application Support/IPInformer/engines"
CURRENT="$ENGINES/current"
PATCH_TARGET="$ENGINES/1.14.4-ipinformer-4/sing-box"
LEGACY_TARGETS=("$ENGINES/1.14.4-ipinformer-1/sing-box" "$ENGINES/1.14.4-ipinformer-2/sing-box" "$ENGINES/1.14.4-ipinformer-3/sing-box")
PREVIOUS_FILE="$ENGINES/ipinformer-previous"
INSTALLER="$SCRIPT_DIR/install-network-service.sh"
TARGET_USER="${SUDO_USER:-$(/usr/bin/stat -f %Su /dev/console)}"
TARGET_HOME=$(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | /usr/bin/awk '{print $2}')
USER_CONFIG="$TARGET_HOME/Library/Application Support/IPInformer"

switch_current() {
    /bin/rm -f "$CURRENT.new"
    /bin/ln -s "$1" "$CURRENT.new"
    /bin/mv -f "$CURRENT.new" "$CURRENT"
}

is_legacy_target() {
    local candidate
    for candidate in "${LEGACY_TARGETS[@]}"; do
        [[ "$1" == "$candidate" ]] && return 0
    done
    return 1
}

if [[ "$1" == "--install" ]]; then
    BUNDLED="$RESOURCE_DIR/engines/sing-box-1.14.4-ipinformer-4"
    HASH_FILE="$RESOURCE_DIR/engines/sing-box-1.14.4-ipinformer-4.sha256"
    [[ -x "$BUNDLED" && -f "$HASH_FILE" ]] || { echo "Patched sing-box is not bundled"; exit 1; }
    EXPECTED=$(/bin/cat "$HASH_FILE")
    ACTUAL=$(/usr/bin/shasum -a 256 "$BUNDLED" | /usr/bin/awk '{print $1}')
    [[ "$EXPECTED" == "$ACTUAL" ]] || { echo "Patched sing-box checksum mismatch"; exit 1; }
    "$BUNDLED" version | /usr/bin/grep -Fq 'IPInformer patch: 1.14.4-4' || {
        echo "Wrong patched sing-box version"; exit 1
    }
    [[ -f "$USER_CONFIG/sing-box-base.json" && -f "$USER_CONFIG/sing-box-policy.json" ]] || {
        echo "Open IP Informer once to create live configuration"; exit 1
    }
    "$BUNDLED" check -c "$USER_CONFIG/sing-box-base.json" \
        --ipinformer-policy "$USER_CONFIG/sing-box-policy.json"
    CURRENT_BEFORE=""
    if [[ -L "$CURRENT" ]]; then
        CURRENT_BEFORE=$(/usr/bin/readlink "$CURRENT")
        if [[ "$CURRENT_BEFORE" == "$PATCH_TARGET" ]]; then
            echo "IP Informer sing-box patch 1.14.4-4 is already active"
            exit 0
        fi
        if is_legacy_target "$CURRENT_BEFORE"; then
            [[ -f "$PREVIOUS_FILE" ]] || { echo "Official rollback path is missing"; exit 1; }
            PREVIOUS=$(/bin/cat "$PREVIOUS_FILE")
        else
            PREVIOUS="$CURRENT_BEFORE"
        fi
    elif [[ -x "$CURRENT" ]]; then
        /usr/bin/install -d -m 755 "$ENGINES/ipinformer-before-patch"
        /usr/bin/install -o root -g wheel -m 755 "$CURRENT" "$ENGINES/ipinformer-before-patch/sing-box"
        PREVIOUS="$ENGINES/ipinformer-before-patch/sing-box"
    elif [[ -x /opt/homebrew/bin/sing-box ]]; then
        PREVIOUS=/opt/homebrew/bin/sing-box
    elif [[ -x /usr/local/bin/sing-box ]]; then
        PREVIOUS=/usr/local/bin/sing-box
    else
        echo "No official sing-box is available for rollback"; exit 1
    fi
    [[ -x "$PREVIOUS" ]] || { echo "Previous sing-box is missing"; exit 1; }
    /usr/bin/install -d -m 755 "$ENGINES/1.14.4-ipinformer-4"
    /usr/bin/install -o root -g wheel -m 755 "$BUNDLED" "$PATCH_TARGET"
    /bin/echo "$PREVIOUS" > "$PREVIOUS_FILE"
    /bin/chmod 600 "$PREVIOUS_FILE"
    switch_current "$PATCH_TARGET"
    if ! /bin/zsh "$INSTALLER"; then
        switch_current "${CURRENT_BEFORE:-$PREVIOUS}"
        /bin/zsh "$INSTALLER" || true
        echo "Patch installation failed; previous sing-box restored"
        exit 1
    fi
    if is_legacy_target "$CURRENT_BEFORE"; then
        /bin/rm -rf "$ENGINES/1.14.4-ipinformer-1" "$ENGINES/1.14.4-ipinformer-2" "$ENGINES/1.14.4-ipinformer-3"
    fi
    echo "IP Informer sing-box patch is active"
else
    [[ -f "$PREVIOUS_FILE" ]] || { echo "Previous sing-box path is missing"; exit 1; }
    PREVIOUS=$(/bin/cat "$PREVIOUS_FILE")
    [[ -x "$PREVIOUS" ]] || { echo "Previous sing-box binary is missing: $PREVIOUS"; exit 1; }
    ACTIVE_TARGET=$(/usr/bin/readlink "$CURRENT")
    switch_current "$PREVIOUS"
    if ! /bin/zsh "$INSTALLER"; then
        switch_current "$ACTIVE_TARGET"
        /bin/zsh "$INSTALLER" || true
        echo "Official sing-box could not start; patch restored"
        exit 1
    fi
    /bin/rm -f "$PREVIOUS_FILE"
    /bin/rm -rf "$ENGINES/1.14.4-ipinformer-1" "$ENGINES/1.14.4-ipinformer-2" "$ENGINES/1.14.4-ipinformer-3" "$ENGINES/1.14.4-ipinformer-4"
    echo "Official sing-box is active"
fi
