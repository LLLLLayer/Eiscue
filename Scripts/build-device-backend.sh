#!/usr/bin/env bash
# Reproducible local Rust static libraries. Does not change rustup's default toolchain.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
toolchain=${EISCUE_RUST_TOOLCHAIN:-1.96.0}
export CARGO_TARGET_DIR="$root/.build/device-rust"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export MACOSX_DEPLOYMENT_TARGET=14.0
manifest="$root/Vendor/DeviceBackend/rust/Cargo.toml"
for target in aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim; do
    rustup run "$toolchain" cargo build --manifest-path "$manifest" --locked --release --target "$target"
    # Rust's prebuilt standard library carries debug data even in release archives.
    # Strip only debug symbols; exported C ABI and relocations remain intact.
    xcrun strip -S "$CARGO_TARGET_DIR/$target/release/libeiscue_device_backend.a"
done
headers="$root/.build/device-headers"
mkdir -p "$headers"
cp "$root/Vendor/DeviceBackend/Sources/CEiscueDeviceBackend/include/ncm_backend.h" "$headers/"
printf 'module EiscueNativeBackend { header "ncm_backend.h" export * }\n' > "$headers/module.modulemap"
output="$root/Vendor/DeviceBackend/Frameworks/EiscueNativeBackend.xcframework"
staging=$(mktemp -d "$root/.build/native-backend.XXXXXX")
trap 'rm -rf "$staging"' EXIT
xcodebuild -create-xcframework \
    -library "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libeiscue_device_backend.a" -headers "$headers" \
    -library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libeiscue_device_backend.a" -headers "$headers" \
    -library "$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/libeiscue_device_backend.a" -headers "$headers" \
    -output "$staging/EiscueNativeBackend.xcframework"
python3 "$root/Scripts/device-backend-artifacts.py" record \
    --framework "$staging/EiscueNativeBackend.xcframework" --toolchain "$toolchain"
if [[ -d "$output" ]]; then
    mv "$output" "$root/.build/previous-EiscueNativeBackend-$(date +%s)-$$.xcframework"
fi
mv "$staging/EiscueNativeBackend.xcframework" "$output"
