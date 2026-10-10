# Device backend provenance

Source: https://github.com/ja1chen/actell

Pinned commit: `032864e2339da19ee13025c471f4cf1dfdf4c5cd`

Copied source directories:

- `ncm-dev/PhoneAgentNCM/Sources/CNCMBackend` → `Sources/CNCMBackend`
- `ncm-dev/PhoneAgentNCM/Sources/PhoneAgentNCM` → `Sources/PhoneAgentNCM`
- `ncm-dev/rust` → `rust` (including Cargo.lock, source, tests and vendored idevice)

No upstream App, model agent, ESP32 firmware, credentials or captured device data is included.

## Local changes

- `rust/src/pairing.rs`: the newly advertised controller / host display name is `Eiscue` instead of the upstream App name. Protocol behavior is unchanged.
- `rust/src/bin/pair_usb.rs` and the opt-in `desktop-bootstrap` feature provide an explicit USB initialization tool for iOS 26. The vendored idevice `pinned-usb` feature authenticates the selected device using the system USB trust certificate and validates TLS signatures; `remote_pairing/usb_bootstrap.rs` implements explicit first-pairing negotiation. These features are absent from shipped iOS archives. See [USB setup](../../Scripts/pair-device-usb.md).
- `Sources/PhoneAgentNCM/NativeDeveloperServices.swift`: adds a shutdown helper that stops local decode, waits for an in-flight operation to drain, and requests explicit owned-media release before the caller closes transport. The host supplies a bounded deadline; incomplete media startup is not reported as confirmed release. Geometry-tagged snapshots / current geometry checks are also exposed so the Kit can invalidate coordinates after display changes.
- Package composition is owned by Eiscue's root Package.swift. CNCMBackend depends on the internal NCMNativeBackend binary target, removing upstream's absolute host archive linker path. The upstream package manifest is not used.
- `Frameworks/NCMNativeBackend.xcframework` is generated from this source with Rust 1.96.0 for aarch64-apple-ios, aarch64-apple-ios-sim and aarch64-apple-darwin. The script strips debug symbols with `xcrun strip -S` and retains exported C symbols. No offline-fixture feature is enabled in shipped archives.

Rebuild: `Scripts/build-device-backend.sh` from the repository root. The complete corresponding Rust / Swift / C backend source is retained here. Registry dependency versions and integrity checksums are fixed in `rust/Cargo.lock` and fetched by Cargo; they are not all copied into this directory. The script does not modify the user's global default Rust toolchain.

## Licenses

The combined upstream backend declares **GPL-3.0-only**. Individual files retain their original SPDX headers, including GPL-3.0-or-later where applicable. `LICENSE` is the upstream GPL text. `UPSTREAM_THIRD_PARTY.md` is preserved verbatim as the upstream source's provenance record; it also discusses components outside this selected backend and does not imply they have been copied here.

`rust/vendor/idevice/LICENSE.txt` retains the vendored idevice MIT license. Cargo dependencies retain their own licenses; see their pinned Cargo manifests / registry source for distribution notices. Upstream includes adaptations/references to pymobiledevice3 under GPL; see the preserved source headers and notices.

These notices apply to the incorporated backend. They do not declare a license for all Eiscue source. Distribution of a linked product must account for the backend's GPL requirements.
