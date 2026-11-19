#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
xcodebuild -version >/dev/null || { echo "Full Xcode is required for iOS and XCFramework builds." >&2; exit 1; }
cd "$ROOT/descriptor-core"
for target in aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
  rustup target add "$target"
  MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --locked --release --target "$target"
done
mkdir -p target/apple/{macosx,iphoneos,iphonesimulator,headers}
lipo -create target/{aarch64,x86_64}-apple-darwin/release/libnorthvault_descriptor.a -output target/apple/macosx/libnorthvault_descriptor.a
cp target/aarch64-apple-ios/release/libnorthvault_descriptor.a target/apple/iphoneos/
lipo -create target/aarch64-apple-ios-sim/release/libnorthvault_descriptor.a target/x86_64-apple-ios/release/libnorthvault_descriptor.a -output target/apple/iphonesimulator/libnorthvault_descriptor.a
cat > target/apple/headers/northvault_descriptor.h <<'HEADER'
char *nv_descriptor_validate(const char *input);
void nv_descriptor_free(char *output);
HEADER
rm -rf target/apple/NorthvaultDescriptor.xcframework
xcodebuild -create-xcframework \
  -library target/apple/macosx/libnorthvault_descriptor.a -headers target/apple/headers \
  -library target/apple/iphoneos/libnorthvault_descriptor.a -headers target/apple/headers \
  -library target/apple/iphonesimulator/libnorthvault_descriptor.a -headers target/apple/headers \
  -output target/apple/NorthvaultDescriptor.xcframework
cd "$ROOT/apple"
xcodegen generate
