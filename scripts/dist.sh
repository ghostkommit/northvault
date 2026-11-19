#!/usr/bin/env bash
# Package the locally built app for download: dist/Northvault-<version>-macos-<arch>.zip
# plus its SHA-256. The app is ad-hoc signed, not notarized.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
APP=macos/build/Northvault.app
[[ -x "$APP/Contents/MacOS/Northvault" ]] || { echo "Run 'make build' first." >&2; exit 1; }
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
codesign --verify --deep --strict "$APP"
NAME="Northvault-$VERSION-macos-$(uname -m).zip"
mkdir -p dist
rm -f "dist/$NAME" "dist/$NAME.sha256"
# ditto keeps the bundle's signature and extended attributes intact.
ditto -c -k --keepParent "$APP" "dist/$NAME"
(cd dist && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "✓ dist/$NAME"
