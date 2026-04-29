#!/usr/bin/env bash
set -euo pipefail
APP_PATH="${1:-.build/release/MacVidCatch.app}"
OUT="${2:-.build/release/MacVidCatch.dmg}"
VOL="MacVidCatch"
STAGE=".build/dmg-stage"
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
echo "$OUT"
