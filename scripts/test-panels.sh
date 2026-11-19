#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
bash scripts/build-qr-local.sh
bash scripts/build-storage-local.sh
swiftc_app macos/build/check-panels "${SWIFT_TEST_FLAGS[@]}" -parse-as-library \
  -Xlinker -rpath -Xlinker "$ROOT/shared/.local-build" scripts/check-panels.swift
macos/build/check-panels
