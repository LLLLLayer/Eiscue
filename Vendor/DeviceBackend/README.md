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
- `rust/src/legacy_probe.rs` and `Sources/PhoneAgentNCM/LegacyDeveloperServicesProbe.swift`: an explicitly requested read-only probe of Instruments screenshots and testmanagerd DTX on the existing authenticated tunnel. The vendored MIT DTX implementation is enabled and its existing handshake method made public; upstream-file changes are recorded in `rust/SOURCE_MANIFEST.json`. The probe requires verified-identity and screen authorization, reports only dimensions/status, and does not initialize XCTest or send input. It is compatibility evidence, not a completed iOS 26 control backend.
- `rust/src/xctest_session.rs`: the iOS 26 control path owns two testmanagerd DTX channels over the existing authenticated transport, initializes a session UUID, and authorizes only the current process's `getpid()`. Authorization requires a correlated reply containing the Boolean `true`; no PID is accepted from a caller or remote peer. The Swift bridge validates the same UUID and PID before preparing local automation. Added C actions 14/15/16 start or stop these owned channels and obtain a validated Instruments PNG; existing action numbers and ABI version remain unchanged.
- `Sources/CEiscueAutomation`: new, independently implemented GPL-3.0-only Objective-C bridge with runtime-checked SDK signatures. It dynamically loads developer frameworks from the device's DDI, creates a new runner/XPC session using the same UUID, and asynchronously requests system UI automation consent. It does not create a shared XCTest session, start a test plan, install a UI Test Runner, or incorporate TouchSynthesis source. Touch submission binds a request receipt to the owned session's current display, orientation, scale and geometry revision; unknown delivery is not replayed. Cleanup revokes only owned connections. Home and text submission passed the designated phone's Wi-Fi board checks on 2026-10-11 and are now included in the iOS 26 Release capability set after the owned automation session is ready. Text copies the supplied value to the system clipboard and submits one owned Command-V event without reading prior clipboard content.
- `Sources/PhoneAgentNCM/NativeDeveloperServices.swift`: iOS 26 real devices select the owned XCTest route, while iOS 27+ retain the existing DisplayService/HID route. PNG capture checks geometry before and after acquisition and preserves its actual MIME type. Preparation does not report media ready until the owned automation session reports ready. Host/simulator automation is unsupported. The package does not embed Apple's test Runner frameworks; this path requires developer/DDI private interfaces and is not an App Store distribution commitment.
- Package composition is owned by Eiscue's root Package.swift. CNCMBackend depends on the internal NCMNativeBackend binary target, removing upstream's absolute host archive linker path. The upstream package manifest is not used.
- `Frameworks/NCMNativeBackend.xcframework` is generated from this source with Rust 1.96.0 for aarch64-apple-ios, aarch64-apple-ios-sim and aarch64-apple-darwin. The script strips debug symbols with `xcrun strip -S` and retains exported C symbols. No offline-fixture feature is enabled in shipped archives.

Rebuild: `Scripts/build-device-backend.sh` from the repository root. The complete corresponding Rust / Swift / C backend source is retained here. Registry dependency versions and integrity checksums are fixed in `rust/Cargo.lock` and fetched by Cargo; they are not all copied into this directory. The script does not modify the user's global default Rust toolchain.

## Validation boundary

On 2026-10-11, the designated iPhone 14 Pro / iOS 26.5.2 authorized the current App PID, created a new DDI runner/XPC session and completed the system UI automation authorization. The user entered the passcode directly on the device; it was not collected by this backend. Subsequent Wi-Fi board validation returned a valid 1179 × 2556 PNG and passed actual taps with follow-up screenshots, swiping, Unicode paste (`你好，Eiscue 🧊`), Home/App return, two connection cycles and 180-degree rotation checks that rejected an old frame before accepting a new-frame tap. The local VPN stayed disconnected. Local disconnect records do not prove remote daemon teardown acknowledgement; sustained background work, cellular model requests and company VPN coexistence remain unverified. See the [Wi-Fi device validation record](../../docs/board-validation-2026-10-11.md).

After those checks, the iOS 26 Home/text Release restriction was removed. The signed Release build, strict signature verification, installation and normal launch passed on that phone. These results do not validate the physical S3 USB NCM route, other phone/OS combinations or a complete model-driven task.

Historical host validation recorded on 2026-10-11 passed 64 backend Rust tests, 184 vendored idevice tests, 56 DeviceKit tests and 203 Objective-C fixture checks. `Scripts/test-owned-automation.sh` uses fake runtime classes and no device IPC, then syntax-checks the production source against device and simulator SDKs. It validates guards, receipts and cleanup, not physical input. The App's 21 connection-method tests included seven new authorization/background lifecycle cases. See [the validation record](../../docs/validation.md#ios-26-app-内-xctest-会话同日当前) for that software evidence and the linked Wi-Fi record above for subsequent hardware acceptance. Passcode-page images, identity files and full raw phone logs are not included here.

## Licenses

The combined upstream backend declares **GPL-3.0-only**. Individual files retain their original SPDX headers, including GPL-3.0-or-later where applicable. `LICENSE` is the upstream GPL text. `UPSTREAM_THIRD_PARTY.md` is preserved verbatim as the upstream source's provenance record; it also discusses components outside this selected backend and does not imply they have been copied here.

`rust/vendor/idevice/LICENSE.txt` retains the vendored idevice MIT license. Cargo dependencies retain their own licenses; see their pinned Cargo manifests / registry source for distribution notices. Upstream includes adaptations/references to pymobiledevice3 under GPL; see the preserved source headers and notices.

These notices apply to the incorporated backend. They do not declare a license for all Eiscue source. Distribution of a linked product must account for the backend's GPL requirements.
