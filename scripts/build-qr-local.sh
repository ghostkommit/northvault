#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
mkdir -p shared/.local-build macos/build/ModuleCache
xcrun swiftc -parse-as-library -emit-library -static -emit-module -module-name EFQRCode \
  -target "$SWIFT_TARGET" -module-cache-path macos/build/ModuleCache \
  -emit-module-path shared/.local-build/EFQRCode.swiftmodule \
  vendor/EFQRCode/Sources/EFQRCode/*.swift -o shared/.local-build/libEFQRCode.a
