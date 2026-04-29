#!/usr/bin/env bash
set -euo pipefail
swift build -c release
APP=".build/release/MacVidCatch.app"
BIN="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
rm -rf "$APP"
mkdir -p "$BIN" "$RES"
cp .build/release/VidcatchMac "$BIN/MacVidCatch"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacVidCatch</string>
<key>CFBundleIdentifier</key><string>com.example.vidcatchmac</string>
<key>CFBundleName</key><string>MacVidCatch</string>
<key>CFBundleDisplayName</key><string>MacVidCatch</string>
<key>CFBundleVersion</key><string>0.1.0</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>MacVidCatch</string><key>CFBundleURLSchemes</key><array><string>vidcatchmac</string></array></dict></array>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "$APP"
