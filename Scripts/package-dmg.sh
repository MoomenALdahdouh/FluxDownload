#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/Scripts/package-app.sh"
STAGE="$ROOT/build/dmg"
APP="$ROOT/build/FluxDownload.app"
DMG="$ROOT/build/FluxDownload.dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname FluxDownload -srcfolder "$STAGE" -ov -format UDZO "$DMG"
echo "Built $DMG"
