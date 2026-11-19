#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
if [[ "${NORTHVAULT_TESTABLE:-0}" == 1 ]]; then
  SWIFT_TEST_FLAGS+=(-enable-testing)
fi
cd "$ROOT/descriptor-core"
cargo build --locked --offline --target "$RUST_TARGET"
OUT="$ROOT/shared/.local-build"
mkdir -p "$OUT/ModuleCache"
rm -f "$OUT"/libWallet*.dylib
cd "$ROOT"
for module in WalletModels WalletCrypto WalletStorage WalletUI; do
  xcrun swiftc "${SWIFT_TEST_FLAGS[@]}" -parse-as-library -emit-module -emit-library -static -module-name "$module" \
    -target "$SWIFT_TARGET" -module-cache-path "$OUT/ModuleCache" \
    -I "$OUT" \
    "$ROOT/shared/Sources/$module/"*.swift \
    -emit-module-path "$OUT/$module.swiftmodule" -o "$OUT/lib$module.a"
done
