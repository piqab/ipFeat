#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 OUTPUT_BINARY"
    exit 1
fi

ROOT_DIR="${0:A:h:h}"
OUTPUT="$1"
WORK=$(/usr/bin/mktemp -d -t ipinformer-sing-box)
trap '/bin/rm -rf "$WORK"' EXIT

/usr/bin/git clone --depth 1 --branch v1.14.4 https://github.com/SagerNet/sing-box.git "$WORK/source"
REVISION=$(/usr/bin/git -C "$WORK/source" rev-parse HEAD)
[[ "$REVISION" == c005f35300ce76427dc285481ec5695f5b179cd2 ]] || {
    echo "Unexpected sing-box source revision: $REVISION"
    exit 1
}
/usr/bin/git -C "$WORK/source" apply --check "$ROOT_DIR/patches/sing-box-1.14.4-ipinformer-3.patch"
/usr/bin/git -C "$WORK/source" apply "$ROOT_DIR/patches/sing-box-1.14.4-ipinformer-3.patch"

TAGS='with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_tailscale,with_ccm,with_ocm,with_cloudflared,with_naive_outbound,with_usbip,with_openvpn,with_openconnect'
cd "$WORK/source"
GOTOOLCHAIN=auto go build -trimpath -tags "$TAGS" \
    -ldflags '-X github.com/sagernet/sing-box/constant.Version=1.14.4 -s -w' \
    -o "$OUTPUT" ./cmd/sing-box
"$OUTPUT" version | /usr/bin/grep -F 'IPInformer patch: 1.14.4-3'
