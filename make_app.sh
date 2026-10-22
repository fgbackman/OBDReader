#!/bin/bash
# Builds "OBD Reader.app" from this Swift package. Requires Xcode or the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="OBD Reader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OBDReader "$APP/Contents/MacOS/OBDReader"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>OBD Reader</string>
    <key>CFBundleDisplayName</key><string>OBD Reader</string>
    <key>CFBundleIdentifier</key><string>com.fred.obdreader</string>
    <key>CFBundleExecutable</key><string>OBDReader</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS will launch it locally.
codesign --force --deep -s - "$APP"
echo "Built: $(pwd)/$APP"
