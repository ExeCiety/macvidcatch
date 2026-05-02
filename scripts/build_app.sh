#!/usr/bin/env bash
set -euo pipefail

build_release() {
  swift build -c release
}

if ! build_release; then
  echo "Release build failed; clearing Swift module cache and retrying..." >&2
  find .build -type d -name ModuleCache -prune -exec rm -rf {} +
  build_release
fi

APP=".build/release/MacVidCatch.app"
BIN="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
rm -rf "$APP"
mkdir -p "$BIN" "$RES"
cp .build/release/MacVidCatch "$BIN/MacVidCatch"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacVidCatch</string>
<key>CFBundleIdentifier</key><string>app.macvidcatch.MacVidCatch</string>
<key>CFBundleName</key><string>MacVidCatch</string>
<key>CFBundleDisplayName</key><string>MacVidCatch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>0.1.0</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>NSUserNotificationAlertStyle</key><string>alert</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>MacVidCatch</string><key>CFBundleURLSchemes</key><array><string>macvidcatch</string></array></dict></array>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "$APP"
