#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/IP Informer.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$ROOT_DIR"
swift build -c release --product IPInformer
swift build -c release --product IPInformerUpdater

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/.build/release/IPInformer" "$CONTENTS_DIR/MacOS/IPInformer"
cp "$ROOT_DIR/.build/release/IPInformerUpdater" "$CONTENTS_DIR/MacOS/IPInformerUpdater"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
mkdir -p "$CONTENTS_DIR/Resources/scripts"
cp "$ROOT_DIR/scripts/install-network-service.sh" "$CONTENTS_DIR/Resources/scripts/"
cp -R "$ROOT_DIR/scripts/service" "$CONTENTS_DIR/Resources/scripts/"
chmod +x "$CONTENTS_DIR/MacOS/IPInformer"
chmod +x "$CONTENTS_DIR/MacOS/IPInformerUpdater"

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
