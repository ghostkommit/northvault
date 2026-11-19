# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
# Shared by the local build and test scripts. Source it; don't run it.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_TARGET="$(uname -m)-apple-macosx14.0"
RUST_TARGET="$(uname -m | sed s/arm64/aarch64/)-apple-darwin"

# Flags for test binaries; coverage runs add instrumentation.
SWIFT_TEST_FLAGS=(-Onone)
if [[ "${NORTHVAULT_SWIFT_COVERAGE:-0}" == 1 ]]; then
  SWIFT_TEST_FLAGS+=(-profile-generate -profile-coverage-mapping)
fi

require_tesseract() {
  if ! command -v "${TESSERACT:-tesseract}" >/dev/null; then
    echo "Native UI checks require Tesseract 5 with English data (or set TESSERACT to its executable path)." >&2
    exit 1
  fi
}

# swiftc_app OUTPUT [flags and extra sources...]
# Links the app's Support and Views sources against the Rust core, the vendored
# QR encoder and the shared modules. Run from $ROOT after the libraries are built.
swiftc_app() {
  local output="$1"
  shift
  mkdir -p macos/build/ModuleCache
  xcrun swiftc -target "$SWIFT_TARGET" \
    -module-cache-path macos/build/ModuleCache \
    -I core/target/headers -I shared/.local-build -L shared/.local-build \
    -lEFQRCode -lWalletUI -lWalletStorage -lWalletCrypto -lWalletModels \
    macos/Generated/northvault_core.swift \
    macos/Northvault/Support/*.swift macos/Northvault/Views/*.swift \
    "$@" \
    core/target/universal/libnorthvault_core.a \
    -framework IOKit -framework CoreFoundation -framework Security \
    -framework SystemConfiguration -liconv -o "$output"
}
