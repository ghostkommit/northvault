#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
bash scripts/build-qr-local.sh
xcrun swiftc "${SWIFT_TEST_FLAGS[@]}" -parse-as-library -target "$SWIFT_TARGET" \
  -module-cache-path macos/build/ModuleCache -I core/target/headers \
  -I shared/.local-build -L shared/.local-build -lEFQRCode \
  macos/Generated/northvault_core.swift macos/Northvault/Support/QRCodeRenderer.swift \
  macos/Northvault/Support/QRImageDecoder.swift \
  scripts/check-qr.swift core/target/universal/libnorthvault_core.a \
  -framework IOKit -framework CoreFoundation -framework Security \
  -framework SystemConfiguration -liconv -o macos/build/check-qr
macos/build/check-qr
