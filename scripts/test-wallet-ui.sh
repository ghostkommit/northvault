#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
require_tesseract
(cd core && cargo build --locked --offline --example regtest_ui_fixture)
bash scripts/build-qr-local.sh
bash scripts/build-storage-local.sh
swiftc_app macos/build/check-wallet-ui "${SWIFT_TEST_FLAGS[@]}" -parse-as-library \
  shared/Tests/WalletStorageTests/NativeSnapshot.swift scripts/check-wallet-ui.swift
python3 - "$ROOT" <<'PY'
from pathlib import Path
import subprocess
import sys
import tempfile
root = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="northvault-wallet-ui-") as temporary:
    fixture = Path(temporary) / "wallet"
    subprocess.run([root / "core/target/debug/examples/regtest_ui_fixture", fixture], check=True)
    result = subprocess.run([root / "macos/build/check-wallet-ui", fixture], check=True,
                            stdout=subprocess.PIPE, text=True, timeout=600)
    # AppKit can terminate a CLI host without a nonzero exit. Require evidence
    # that every assertion completed, including after native input actions.
    marker = "Native Regtest wallet UI checks passed"
    if marker not in result.stdout.splitlines():
        raise SystemExit("Native wallet UI runner exited before completing its checks")
    print(marker)
PY
