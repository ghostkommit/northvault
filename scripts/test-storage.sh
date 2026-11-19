#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_tesseract
NORTHVAULT_TESTABLE=1 bash "$ROOT/scripts/build-storage-local.sh"
OUT="$ROOT/shared/.local-build"
xcrun swiftc "${SWIFT_TEST_FLAGS[@]}" -parse-as-library -target "$SWIFT_TARGET" \
  -module-cache-path "$OUT/ModuleCache" -I "$OUT" -L "$OUT" \
  -lWalletModels -lWalletCrypto -lWalletStorage -lWalletUI \
  -L "$ROOT/descriptor-core/target/$RUST_TARGET/debug" -lnorthvault_descriptor \
  -Xlinker -rpath -Xlinker "$OUT" \
  "$ROOT/shared/Tests/WalletStorageTests/StorageChecks.swift" \
  "$ROOT/shared/Tests/WalletStorageTests/RecoveryChecks.swift" \
  "$ROOT/shared/Tests/WalletStorageTests/KeychainAdapterChecks.swift" \
  "$ROOT/shared/Tests/WalletStorageTests/NativeSnapshot.swift" \
  "$ROOT/shared/Tests/WalletStorageTests/VaultModelChecks.swift" "$ROOT/scripts/storage-check-main.swift" \
  -o "$OUT/storage-checks"
"$OUT/storage-checks" "$ROOT/shared/Tests/WalletStorageTests/Fixtures/descriptors-regtest.json"
