#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/FluxDownload.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
IDENTITY="${CODESIGN_IDENTITY:-}"

cd "$ROOT"
# APFS is case-insensitive: product names FluxDownload and fluxdownload collide.
# Build the GUI last and never copy a CLI binary named fluxdownload into MacOS/.
swift build -c release --product FluxDownloadNativeHost
swift build -c release --product fluxdownload-cli
swift build -c release --product FluxDownload

BIN_DIR="$(swift build -c release --show-bin-path)"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN_DIR/FluxDownload" "$MACOS/FluxDownload"
cp "$BIN_DIR/FluxDownloadNativeHost" "$MACOS/FluxDownloadNativeHost"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
echo -n "APPL????" > "$CONTENTS/PkgInfo"
cp "$ROOT/LICENSE" "$RES/LICENSE"
cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
chmod +x "$MACOS/FluxDownload" "$MACOS/FluxDownloadNativeHost"

ENTITLEMENTS="$ROOT/Resources/FluxDownload.entitlements"
SIGN_OPTS=(--force --deep --sign)
if [[ -n "$IDENTITY" ]] && security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  codesign "${SIGN_OPTS[@]}" "$IDENTITY" --timestamp --options runtime --entitlements "$ENTITLEMENTS" "$APP"
  echo "SIGNED with $IDENTITY"
elif security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  ID="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  codesign "${SIGN_OPTS[@]}" "$ID" --timestamp --options runtime --entitlements "$ENTITLEMENTS" "$APP"
  echo "SIGNED with $ID"
else
  codesign "${SIGN_OPTS[@]}" - --entitlements "$ENTITLEMENTS" "$APP"
  echo "SIGNED ad-hoc (no Developer ID). Not release-ready / not notarized."
fi

echo "Built $APP"
file "$MACOS/FluxDownload"

HOST_JSON="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.fluxdownload.native.json"
mkdir -p "$(dirname "$HOST_JSON")"
cat > "$HOST_JSON" <<EOF
{
  "name": "com.fluxdownload.native",
  "description": "FluxDownload",
  "path": "$MACOS/FluxDownloadNativeHost",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://cdhmompibjahkccghpbepifodgcallpi/"]
}
EOF
echo "Native host registered at $HOST_JSON -> $MACOS/FluxDownloadNativeHost"
