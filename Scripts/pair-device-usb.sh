#!/usr/bin/env bash
# Explicit desktop USB bootstrap; no iOS device is selected automatically.
set -euo pipefail
# Public format metadata and version rejection must not build or access devices.
if [[ $# -eq 1 && "$1" == "--describe-format" ]]; then
    printf '%s\n' '{"protocolVersion":1,"identitySchemaVersions":[1]}'
    exit 0
fi
arguments=()
schema_seen=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity-schema-version)
            if [[ $schema_seen -ne 0 || $# -lt 2 || "$2" != "1" ]]; then
                echo "Unsupported pairing identity format. Use the setup command shown in your installed Eiscue app." >&2
                exit 2
            fi
            schema_seen=1
            shift 2
            ;;
        --describe-format)
            echo "Use --describe-format by itself; it does not pair a device." >&2
            exit 2
            ;;
        *) arguments+=("$1"); shift ;;
    esac
done
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
exec "$CARGO_TARGET_DIR/$host_target/debug/eiscue-pair-usb" "${arguments[@]}"
