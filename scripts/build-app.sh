#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/ipFeat.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$ROOT_DIR"
swift build -c release --disable-sandbox --product ipFeat
swift build -c release --disable-sandbox --product ipFeatUpdater

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/.build/release/ipFeat" "$CONTENTS_DIR/MacOS/ipFeat"
cp "$ROOT_DIR/.build/release/ipFeatUpdater" "$CONTENTS_DIR/MacOS/ipFeatUpdater"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
cp "$ROOT_DIR/Resources/StatusIcon.png" "$CONTENTS_DIR/Resources/StatusIcon.png"
for language in ru en zh-Hans; do
    mkdir -p "$CONTENTS_DIR/Resources/$language.lproj"
    cp "$ROOT_DIR/Resources/$language.lproj/Localizable.strings" \
        "$CONTENTS_DIR/Resources/$language.lproj/Localizable.strings"
done
mkdir -p "$CONTENTS_DIR/Resources/scripts"
cp "$ROOT_DIR/scripts/install-network-service.sh" "$CONTENTS_DIR/Resources/scripts/"
cp "$ROOT_DIR/scripts/uninstall-network-service.sh" "$CONTENTS_DIR/Resources/scripts/"
cp "$ROOT_DIR/scripts/install-patched-engine.sh" "$CONTENTS_DIR/Resources/scripts/"
mkdir -p "$CONTENTS_DIR/Resources/scripts/service"
cp -R "$ROOT_DIR/scripts/service/." "$CONTENTS_DIR/Resources/scripts/service/"
chmod +x "$CONTENTS_DIR/Resources/scripts/install-patched-engine.sh"
chmod +x "$CONTENTS_DIR/Resources/scripts/install-network-service.sh" "$CONTENTS_DIR/Resources/scripts/uninstall-network-service.sh"
mkdir -p "$CONTENTS_DIR/Resources/engines"
/bin/rm -f "$CONTENTS_DIR/Resources/engines/sing-box-1.14.4-ipfeat-1" \
    "$CONTENTS_DIR/Resources/engines/sing-box-1.14.4-ipfeat-1.sha256" \
    "$CONTENTS_DIR/Resources/engines/sing-box-1.14.4-ipfeat-2" \
    "$CONTENTS_DIR/Resources/engines/sing-box-1.14.4-ipfeat-2.sha256"
/bin/rm -f "$CONTENTS_DIR/Resources/engines/sing-box-1.14.4-ipfeat-3" \
    "$CONTENTS_DIR/Resources/engines/sing-box-1.14.4-ipfeat-3.sha256" \
    "$CONTENTS_DIR/Resources/engines/sing-box-1.14.4-ipfeat-4" \
    "$CONTENTS_DIR/Resources/engines/sing-box-1.14.4-ipfeat-4.sha256" \
    "$CONTENTS_DIR/Resources/engines/sing-box-1.14.4-ipfeat-5" \
    "$CONTENTS_DIR/Resources/engines/sing-box-1.14.4-ipfeat-5.sha256"
PATCH_BINARY="$CONTENTS_DIR/Resources/engines/sing-box-1.14.4-ipfeat-6"
if [[ -n "${IPFEAT_PATCHED_BINARY:-}" ]]; then
    cp "$IPFEAT_PATCHED_BINARY" "$PATCH_BINARY"
else
    "$ROOT_DIR/scripts/build-patched-sing-box.sh" "$PATCH_BINARY"
fi
chmod +x "$PATCH_BINARY"
/usr/bin/shasum -a 256 "$PATCH_BINARY" | /usr/bin/awk '{print $1}' > "$PATCH_BINARY.sha256"
chmod +x "$CONTENTS_DIR/MacOS/ipFeat"
chmod +x "$CONTENTS_DIR/MacOS/ipFeatUpdater"

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
