# Eiscue device backend

Eiscue's developer-services implementation connects the app to the device's own
developer services. The control runtime is maintained here; it does not build,
fetch or call an actell package. The MIT **idevice** protocol library is retained
at a pinned revision with Device Hub's MIT extensions and documented Eiscue
adaptations.

The directory remains under `Vendor/` to keep existing source and setup links
stable. This is not a clean-room or relicensing claim: the compatibility ABI,
some small adapters and regression fixtures retain their earlier provenance.
See [source origins](UPSTREAM_THIRD_PARTY.md) and the
[manifest](rust/SOURCE_MANIFEST.json). The backend remains **GPL-3.0-only**;
idevice and Device Hub files keep their MIT notices.

## Composition

```text
EiscueDeviceKit / LocalDeviceController
  └─ EiscueDeviceBackend (Swift)
       ├─ discovery, pairing callbacks, request ownership, HEVC → JPEG
       ├─ CEiscueAutomation (Objective-C, owned XCTest session)
       └─ CEiscueDeviceBackend (versioned C ABI)
            └─ EiscueNativeBackend.xcframework (Rust)
                 ├─ bounded session workers, cancellation and receipt queues
                 ├─ local-VPN / USB-network transport
                 ├─ DisplayService media, HID input and scoped media release
                 └─ idevice (MIT protocol clients)
```

These are internal build targets, not additional public Kit products. Use
`EiscueDeviceKit` or inject an actuator through `DeviceClient`. The AgentKit has
no dependency on this backend. `EiscueHIDKit` and the `EiscueHID` app omit it;
Bluetooth/USB HID input and ReplayKit remain in DeviceCore.

| Layer | Key implementation |
| --- | --- |
| Swift bridge | [NativeDeveloperServices](Sources/EiscueDeviceBackend/NativeDeveloperServices.swift), [NativeABI](Sources/EiscueDeviceBackend/NativeABI.swift) |
| Screen decoding | [NativeVideoPipeline](Sources/EiscueDeviceBackend/NativeVideoPipeline.swift) |
| Discovery and pairing | [LocalVPNDiscovery](Sources/EiscueDeviceBackend/LocalVPNDiscovery.swift), [RemotePairingSession](Sources/EiscueDeviceBackend/RemotePairingSession.swift) |
| Runtime and transport | [ffi.rs](rust/src/ffi.rs), [transport.rs](rust/src/transport.rs), [lib.rs](rust/src/lib.rs) |
| DisplayService | [media.rs](rust/src/media.rs), [video.rs](rust/src/video.rs) |
| Owned cleanup | [media_cleanup.rs](rust/src/media_cleanup.rs), [media_cleanup_ffi.rs](rust/src/media_cleanup_ffi.rs) |
| XCTest bridge | [EiscueAutomation.m](Sources/CEiscueAutomation/EiscueAutomation.m), [xctest_session.rs](rust/src/xctest_session.rs) |

## Routes and control methods

Transport and control method are separate choices:

- **Local VPN** discovers the device through Eiscue's Packet Tunnel reflector.
  The reflector lives in the app extension; this library authenticates and opens
  the developer-service tunnel. It does not create VPN configurations.
- **USB NCM** uses an ESP32-S3 network relay on `192.168.7.0/24`. Interface binding
  prevents the connection from silently moving to another route. This is distinct
  from an ESP32 acting as a USB keyboard/mouse.
- **XCTest** uses Eiscue's owned automation session for screenshots and input.
  It supports the app's iOS 26+ path through private developer/DDI interfaces.
- **DisplayService + HID** uses a streamed HEVC picture and developer-service
  HID commands on iOS 27+. It is unavailable below iOS 27.

The app selects one explicit control method for a connection. Legacy automatic
selection resolves to XCTest on iOS 26 and DisplayService on iOS 27+; there is no
runtime fallback. Both developer-service routes require Developer Mode, a pairing
identity and a compatible developer environment/DDI. For iOS 26 initialization,
see the self-contained [USB pairing instructions](../../Scripts/pair-device-usb.md).
No Apple frameworks or developer disk image are bundled here.

## Ownership and failure behavior

Each native handle owns a bounded worker and serialized request queue. Accepted
requests retain their receipts until read; a short output buffer cannot silently
consume one. Cancellation revokes the connection and drains the entire worker
runtime before cleanup can reuse its pairing binding. Input with uncertain
delivery is never replayed.

The video receiver maintains a bounded HEVC reference chain. Geometry changes,
missing reference pictures or decoder errors invalidate screenshot coordinates;
new pixels alone do not invalidate a current observation. Swift decodes and crops
frames outside MainActor. DeviceCore remains responsible for single-use model
frame grants and post-action observation.

A screen start reserves an owned cleanup receipt. Later same-process cleanup can
use a freshly authenticated transport only for that original pairing, client
session UUID and both SSRCs, and stops only the owned stream. Cleanup handles
cannot start media or send input. An unconfirmed release retains the receipt and
blocks replacing/deleting its pairing identity. There is no `stopAll` recovery,
cross-process orphan recovery, or proof of release from a local socket close.

Pairing persistence belongs to the caller. Provisional and committed records are
acknowledged only after durable storage succeeds; diagnostics never contain keys,
PINs, identities or screenshots. The optional desktop bootstrap is excluded from
shipped iOS archives. Rust tracing is compiled out.

## Build and verify

Run from the repository root on an Apple Silicon Mac. The public package supports
iOS 17 / macOS 14; the Eiscue app minimum remains iOS 26.

```sh
# Keep the global Rust toolchain unchanged.
rustup toolchain install 1.96.0 --profile minimal \
  --target aarch64-apple-ios,aarch64-apple-ios-sim

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash Scripts/build-device-backend.sh
python3 Scripts/device-backend-artifacts.py check

CARGO_TARGET_DIR=.build/device-rust rustup run 1.96.0 cargo test --locked \
  --manifest-path Vendor/DeviceBackend/rust/Cargo.toml \
  --workspace --features desktop-bootstrap --lib --bins

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  python3 Scripts/test-swift-package.py --scratch-path .build/kit-xcode26
bash Scripts/test-owned-automation.sh
```

The build produces arm64 slices for iOS, iOS Simulator and macOS. There is no
x86_64 slice. It strips debug symbols, records source/header/archive hashes in
`BUILD_MANIFEST.json`, and replaces the framework only after all slices and the
manifest are ready. Commit the rebuilt framework with its source. The legacy
`ncm_*` symbol names and ABI layouts remain stable; they are compatibility names,
not an actell runtime dependency.

Tests use synthetic fixtures and local sockets, with no phone or model API.
Host tests and simulator builds verify software contracts; actual pairing,
streaming, input, background behavior and microphone handoff still require
physical-device checks after backend changes. No App Store compatibility is
claimed for these private developer-service interfaces.
