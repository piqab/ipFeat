#!/bin/zsh
set -u

SING_BOX="${1:-/opt/homebrew/bin/sing-box}"
CONFIG="${2:-}"
LOG_TAG="IPInformerNetwork"
CHILD_PID=""

log_message() {
    /usr/bin/logger -t "$LOG_TAG" -- "$1"
}

stop_child() {
    if [[ -n "$CHILD_PID" ]] && /bin/kill -0 "$CHILD_PID" 2>/dev/null; then
        /bin/kill -TERM "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
}

trap 'stop_child; exit 0' TERM INT

while true; do
    if [[ ! -x "$SING_BOX" ]]; then
        log_message "sing-box executable not found: $SING_BOX"
        /bin/sleep 5
        continue
    fi
    if [[ -z "$CONFIG" || ! -f "$CONFIG" ]]; then
        log_message "configuration not found: $CONFIG"
        /bin/sleep 3
        continue
    fi
    if ! "$SING_BOX" check -c "$CONFIG" >/dev/null 2>&1; then
        log_message "configuration check failed; kill switch remains active"
        /bin/sleep 3
        continue
    fi

    LAST_HASH=$(/usr/bin/shasum -a 256 "$CONFIG" | /usr/bin/awk '{print $1}')
    log_message "starting sing-box"
    "$SING_BOX" run -c "$CONFIG" &
    CHILD_PID=$!

    while /bin/kill -0 "$CHILD_PID" 2>/dev/null; do
        /bin/sleep 2
        [[ -f "$CONFIG" ]] || continue
        CURRENT_HASH=$(/usr/bin/shasum -a 256 "$CONFIG" | /usr/bin/awk '{print $1}')
        if [[ "$CURRENT_HASH" != "$LAST_HASH" ]]; then
            if "$SING_BOX" check -c "$CONFIG" >/dev/null 2>&1; then
                log_message "reloading checked configuration"
                /bin/kill -HUP "$CHILD_PID" 2>/dev/null || true
                LAST_HASH="$CURRENT_HASH"
            else
                log_message "new configuration rejected; keeping previous configuration"
            fi
        fi
    done

    wait "$CHILD_PID" 2>/dev/null || true
    CHILD_PID=""
    log_message "sing-box stopped; restarting with kill switch active"
    /bin/sleep 1
done
