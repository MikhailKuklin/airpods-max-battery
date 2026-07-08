#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="AirPodsMaxBattery.app"
BIN="AirPodsMaxBattery"

echo "→ compiling…"
mkdir -p "$APP/Contents/MacOS"
swiftc -O src/main.swift -o "$APP/Contents/MacOS/$BIN" \
    -framework AppKit -framework CoreBluetooth

echo "→ writing Info.plist…"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>AirPods Max Battery</string>
    <key>CFBundleDisplayName</key>     <string>AirPods Max Battery</string>
    <key>CFBundleExecutable</key>      <string>$BIN</string>
    <key>CFBundleIdentifier</key>      <string>com.airpodsmaxbattery</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Reads the AirPods Max battery level from its Bluetooth advertisement.</string>
</dict>
</plist>
PLIST

echo "→ ad-hoc signing (needed for Bluetooth TCC prompt)…"
codesign --force --deep --sign - \
    --options runtime \
    "$APP"

echo "✓ built $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true
