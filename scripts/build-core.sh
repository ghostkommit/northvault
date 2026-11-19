#!/usr/bin/env bash
# Builds the Rust core as a universal static library, generates the Swift
# bindings and packages everything as NorthvaultCore.xcframework.
set -euo pipefail

case "${1:-}" in
  "" )
    if ! xcodebuild -version >/dev/null 2>&1; then
      echo "XCFramework packaging requires full Xcode. Use 'make build' with Command Line Tools only." >&2
      exit 1
    fi
    ;;
  --bindings-only ) ;;
  * ) echo "Usage: $0 [--bindings-only]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
GEN="$ROOT/macos/Generated"
OUT="$CORE/target/NorthvaultCore.xcframework"
LIB="libnorthvault_core"

cd "$CORE"
# Toolchain and targets come from core/rust-toolchain.toml.
rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null
# Match the app's deployment target so the linker doesn't warn.
export MACOSX_DEPLOYMENT_TARGET=14.0

cargo build --locked --release --target aarch64-apple-darwin
cargo build --locked --release --target x86_64-apple-darwin

mkdir -p target/universal target/headers
lipo -create \
  "target/aarch64-apple-darwin/release/$LIB.a" \
  "target/x86_64-apple-darwin/release/$LIB.a" \
  -output "target/universal/$LIB.a"

# Swift bindings (library mode reads the interface from the compiled dylib)
rm -rf "$GEN" && mkdir -p "$GEN"
cargo run --locked --release --bin uniffi-bindgen -- generate \
  --library "target/aarch64-apple-darwin/release/$LIB.dylib" \
  --language swift --out-dir "$GEN"

mv "$GEN/northvault_coreFFI.h" target/headers/
mv "$GEN/northvault_coreFFI.modulemap" target/headers/module.modulemap

if [[ "${1:-}" == "--bindings-only" ]]; then
  echo "✓ Universal static library and Swift bindings built"
  exit 0
fi

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "target/universal/$LIB.a" \
  -headers target/headers \
  -output "$OUT"

echo "✓ $OUT"
echo "✓ Swift bindings in $GEN"
