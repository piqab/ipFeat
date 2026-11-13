#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/IP Informer.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$ROOT_DIR"
swift build -c release --disable-sandbox --product IPInformer
swift build -c release --disable-sandbox --product IPInformerUpdater

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/.build/release/IPInformer" "$CONTENTS_DIR/MacOS/IPInformer"
cp "$ROOT_DIR/.build/release/IPInformerUpdater" "$CONTENTS_DIR/MacOS/IPInformerUpdater"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
mkdir -p "$CONTENTS_DIR/Resources/scripts"
cp "$ROOT_DIR/scripts/install-network-service.sh" "$CONTENTS_DIR/Resources/scripts/"
cp "$ROOT_DIR/scripts/install-patched-engine.sh" "$CONTENTS_DIR/Resources/scripts/"
mkdir -p "$CONTENTS_DIR/Resources/scripts/service"
cp -R "$ROOT_DIR/scripts/service/." "$CONTENTS_DIR/Resources/scripts/service/"
chmod +x "$CONTENTS_DIR/Resources/scripts/install-patched-engine.sh"
mkdir -p "$CONTENTS_DIR/Resources/engines"
/bin/rm -f "$CONTENTS_DIR/Resources/engines/sing-box-1.14.4-ipinformer-1" \
    "$CONTENTS_DIR/Resources/engines/sing-box-1.14.4-ipinformer-1.sha256"
PATCH_BINARY="$CONTENTS_DIR/Resources/engines/sing-box-1.14.4-ipinformer-2"
if [[ -n "${IPINFORMER_PATCHED_BINARY:-}" ]]; then
    cp "$IPINFORMER_PATCHED_BINARY" "$PATCH_BINARY"
else
    "$ROOT_DIR/scripts/build-patched-sing-box.sh" "$PATCH_BINARY"
fi
chmod +x "$PATCH_BINARY"
/usr/bin/shasum -a 256 "$PATCH_BINARY" | /usr/bin/awk '{print $1}' > "$PATCH_BINARY.sha256"
chmod +x "$CONTENTS_DIR/MacOS/IPInformer"
chmod +x "$CONTENTS_DIR/MacOS/IPInformerUpdater"

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
