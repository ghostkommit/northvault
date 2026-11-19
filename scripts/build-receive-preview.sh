#!/usr/bin/env bash
# Run make build first, then build this isolated receive-panel UI fixture.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
bash scripts/build-qr-local.sh
APP="$ROOT/macos/build/NorthvaultReceivePreview.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp shared/Tests/WalletStorageTests/Fixtures/descriptors.json "$APP/Contents/Resources/"
swiftc_app "$APP/Contents/MacOS/NorthvaultReceivePreview" -parse-as-library scripts/preview-receive.swift
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NorthvaultReceivePreview</string>
<key>CFBundleIdentifier</key><string>com.example.northvault.receive-preview</string>
<key>CFBundleName</key><string>Northvault Receive Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
mkdir -p "$APP/Contents/Resources"
cp macos/Northvault/Resources/* "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"
