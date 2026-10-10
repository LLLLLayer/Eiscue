#!/usr/bin/env bash
# Explicit desktop USB bootstrap; no iOS device is selected automatically.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
toolchain=${EISCUE_RUST_TOOLCHAIN:-1.96.0}
export CARGO_TARGET_DIR="$root/.build/device-rust-bootstrap"
export MACOSX_DEPLOYMENT_TARGET=14.0
manifest="$root/Vendor/DeviceBackend/rust/Cargo.toml"
host_target=$(rustup run "$toolchain" rustc -vV | sed -n 's/^host: //p')
if [[ -z "$host_target" ]]; then
    echo "Could not determine the desktop Rust target." >&2
    exit 1
fi
rustup run "$toolchain" cargo build --manifest-path "$manifest" --locked \
    --target "$host_target" --features desktop-bootstrap --bin eiscue-pair-usb
exec "$CARGO_TARGET_DIR/$host_target/debug/eiscue-pair-usb" "$@"
