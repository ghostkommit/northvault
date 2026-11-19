#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
bash scripts/build-storage-local.sh
OUT="$ROOT/shared/.local-build"
APP="$ROOT/macos/build/NorthvaultStorage.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -parse-as-library -target "$SWIFT_TARGET" \
  -module-cache-path "$OUT/ModuleCache" -I "$OUT" -L "$OUT" \
  -lWalletUI -lWalletStorage -lWalletCrypto -lWalletModels \
  -L "descriptor-core/target/$RUST_TARGET/debug" -lnorthvault_descriptor \
  ios/NorthvaultStorageApp.swift -o "$APP/Contents/MacOS/NorthvaultStorage"
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
p=plistlib.loads(Path('apple/StorageInfo.plist').read_bytes())
p.update(CFBundleExecutable='NorthvaultStorage', CFBundleIdentifier='com.example.northvault.storage.local', CFBundleName='Northvault Storage', LSMinimumSystemVersion='14.0')
p.pop('WalletUbiquityContainer', None)
p.pop('WalletKeychainAccessGroup', None)
Path(sys.argv[1]).write_bytes(plistlib.dumps(p))
PY
codesign --force --sign - --options runtime "$APP"
echo "Built $APP (local-only, ad-hoc signed)"
