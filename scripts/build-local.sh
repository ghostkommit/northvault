#!/usr/bin/env bash
# Build a locally signed macOS app without Xcode or XcodeGen.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
bash scripts/build-qr-local.sh
bash scripts/build-core.sh --bindings-only
bash scripts/build-storage-local.sh
APP="$ROOT/macos/build/Northvault.app"
mkdir -p "$APP/Contents/MacOS"
swiftc_app "$APP/Contents/MacOS/Northvault" macos/Northvault/*.swift
rm -f "$APP/Contents/Frameworks/"libWallet*.dylib
cp macos/LocalInfo.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp macos/Northvault/Resources/* "$APP/Contents/Resources/"
codesign --force --sign - --options runtime \
  --entitlements macos/Northvault/Northvault.entitlements "$APP"
echo "✓ Built $APP (host architecture, ad-hoc signed)"
echo "Launch with: open macos/build/Northvault.app"
