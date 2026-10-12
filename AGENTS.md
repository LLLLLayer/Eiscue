# AGENTS.md

Guidance for agents and contributors working in this repository. Product docs under `docs/` are local-only (gitignored, not in the remote) and mostly in Simplified Chinese; firmware and vendor READMEs are tracked and in English.

## Project Overview

Eiscue is an on-device agent assistant for iPhone / iPad (app minimum **iOS / iPadOS 26.0**). Task orchestration and tool execution run on the phone; the model is called over a user-configured HTTPS service (OpenAI Chat Completions–compatible, OpenAI Responses, or Anthropic Messages). The agent can optionally observe and operate the device itself.

Main pieces:

- **Eiscue app** (`Apps/Eiscue`, SwiftUI): conversations, model settings (key in Keychain), attachments, on-device dictation, skills, run journal, background execution, device setup UI. `AppModel` (`@MainActor @Observable`) is the central state object; extensions such as `AppModel+Attachments.swift` split it by concern.
- **EiscueAgentKit** (`Sources/EiscueAgentKit`): Eiscue-owned agent/tool/event protocol (`AgentClient`, `AgentEngine`, `AgentTool`, `AgentEvent`), conversation models and `JSONConversationRepository`. `Internal/Runtime` adapts **PiDurableKit** (pinned commit, runs on JavaScriptCore, one SQLite per conversation).
- **EiscueDeviceKit** (`Sources/EiscueDeviceKit`): `DeviceController` protocol + `DeviceClient`, device models/capabilities, `BluetoothDeviceController` (BLE HID + ReplayKit frames), `ScreenBroadcastStore`, `KeychainPairingIdentityStore`, and the developer-services backend (`LocalDeviceController` → `PhoneAgentNCM` → C ABI → Rust).
- **App extensions**: `Apps/EiscueBroadcast` (ReplayKit broadcast upload; caches only the latest JPEG frame in the App Group) and `Apps/EiscueTunnel` (Packet Tunnel loopback reflector, used only by the local-VPN route). `Apps/Shared` holds config shared by the app and tunnel.
- **Vendor/DeviceBackend**: GPL-3.0 control backend copied from actell at a pinned commit (Swift `PhoneAgentNCM`, C `CNCMBackend`, ObjC `CEiscueAutomation`, Rust crate + vendored `idevice`), shipped as the prebuilt `NCMNativeBackend.xcframework` (arm64 iOS, arm64 simulator, arm64 macOS only; no x86_64).
- **Vendor/LocalTunnel**: LocalDevVPN / StosVPN–derived reflector source and license, bundled as app resources.
- **Firmware** (ESP-IDF v5.5.3): `Passport-BLE` (ESP32-C3 BLE HID, default route), `Passport-Relay` (ESP32-C3 Wi-Fi AP relay), `NCM-Relay` (ESP32-S3 USB NCM relay, no real-board validation yet). `Passport-BLE` also builds explicitly for S3: BLE commands with selected BLE or USB HID output, independent ReplayKit observation, no VPN. Its 16 MB profile preserves the attached board's 24 KB NVS layout; do not reuse the C3 partition table. The C3 BLE and Wi-Fi images share a partition layout and cannot run at the same time.

### Architecture rules

- The two Kits **must not depend on each other**. Only the app's `DeviceToolSession` (`Apps/Eiscue/Integrations/DeviceTools.swift`) depends on both; it builds tool schemas, enforces scope/frame/timeout gates, logs actions, and stops on unknown results.
- Public Kit APIs must not expose PiDurableKit or actell types. `public` access control defines the API; directories are just organization. There is no separate "Plugin" product.
- Engines are swappable via `AgentClient(engine:)`; device backends via `DeviceClient(controller:)`. The app defaults to `BluetoothDeviceController` and keeps the developer-services `DeviceClient()` for the other routes.
- S3 HID commands and replies use per-connection HMAC and monotonic sequence numbers; every command, including STOP/INFO, is authenticated. First enrollment is restricted to an unclaimed board's first 60 s of power, with the candidate key saved in Keychain before enrollment. Never replace an existing board key automatically. Enrollment uses encrypted Just Works and is a trusted-nearby development flow, without a MITM guarantee.
- Connection methods (`DeviceConnectionMethod`): `bluetoothBoard` (default; BLE HID + ReplayKit; no VPN, pairing file or DDI), `localVPN`, `usbBoard`, `wirelessBoard` (RemotePairing / CoreDevice paths that need a pairing identity and developer environment). A route never silently falls back to another one.
- `EiscueBroadcast` compiles `Sources/EiscueDeviceKit/ScreenBroadcast/ScreenBroadcastStore.swift` directly so the extension doesn't link the device backend. Keep that file Foundation-only.
- Selecting Bluetooth at runtime does not remove the linked GPL backend from the binary; a pure-BLE distribution would need a target split.

### Agent / device behavior contracts (do not weaken)

- Task scope is `chat`, `observe`, or `control`, fixed when a run starts. Plain chat registers **no tools** and only a short system prompt. Device tools appear only when the user enables "Allow AI to operate device" and are filtered by the controller's actual `DeviceStatus` capabilities (HID has no app list or bundle-ID launch; Home and restricted keyboard navigation require a supporting firmware plus verified pointer/text calibration).
- The runtime always opens with `resume:false`. Recovery is read-only; continuing an interrupted run requires an explicit `.resume`. Unaccepted messages are retried with the same `requestID`.
- Side-effect tools use unsafe replay at the runtime level, but the host gate stops after an unknown outcome. `DeviceControlError.deliveryUnknown` is never retried automatically.
- Each coordinate action must use the newest screenshot's `frameID` and consumes it; actions, reconnects, rotation or geometry changes invalidate frames. RemotePairing frames last 30 s. A ReplayKit frame counts as current only if it was published within 3 s, or the broadcast extension's heartbeat (every 0.5 s) names it with no newer buffer pending; paused/stopped sessions never authorize input. Each BLE observation gets a new `frameID`. Coordinates are screenshot pixels.
- Device operations are serialized (concurrent calls return `busy`). Success only means the command was sent; callers re-observe to confirm.
- HID readiness needs three separate conditions: authenticated BLE command connection (S3), selected BLE/USB output ready, and active screen sharing plus four-point touch/text calibration passed. C3 uses the existing encrypted BLE command protocol. A BLE acknowledgement doesn't count as a verified action.
- Stop callbacks carry a `runID` so a stale stop can't cancel a newer run. On event-save failure the host cancels and waits for the engine to close before reopening the same SQLite.
- Background device tasks use `BGContinuedProcessingTask` (`BackgroundExecution.swift`, identifier `$(PRODUCT_BUNDLE_IDENTIFIER).agent.continued-processing`). VPN, ReplayKit and Bluetooth background modes are not execution leases.
- Gemini's official OpenAI-compatible endpoint gets `supportsStore=false` (`DefaultEngine.swift`). This rule is scoped to that exact HTTPS host/path and to Chat Completions only.

For more detail, see `docs/architecture.md`, `docs/agent-kit.md`, `docs/device-setup.md`, `docs/background.md`, `docs/local-tunnel.md`, and `docs/design-v0.4.md`.

## Build & Commands

Requires an Apple Silicon Mac and Xcode 26+ (validation records use Xcode 26.3 / Swift 6.2.4). The Xcode project is generated by **XcodeGen** (`project.yml`, minimum XcodeGen 2.45.0). Regenerate it after any target, settings, Info.plist property or localization-list change; don't hand-edit `Eiscue.xcodeproj`.

```sh
xcodegen generate

# Kit tests (EiscueAgentKitTests + EiscueDeviceKitTests)
swift test
swift test --filter ProviderIntegrationTests   # local URLProtocol fixture, no real model
swift test --filter DeviceKitTests

# App build
xcodebuild -project Eiscue.xcodeproj -scheme Eiscue \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 build

# Full app tests (EiscueAppTests + EiscueUITests, non-parallel).
# Start the deterministic model fixture first (127.0.0.1:18765, no API key):
python3 Scripts/test-model-server.py
xcodebuild -project Eiscue.xcodeproj -scheme Eiscue \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' test

# UI tests that don't need the model fixture
xcodebuild -project Eiscue.xcodeproj -scheme Eiscue \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' \
  -only-testing:EiscueUITests/EiscueUITests test
```

Device backend (Rust, pinned toolchain 1.96.0; the default rustup toolchain isn't changed):

```sh
rustup toolchain install 1.96.0 --profile minimal --target aarch64-apple-ios,aarch64-apple-ios-sim
bash Scripts/build-device-backend.sh      # rebuilds Vendor/DeviceBackend/Frameworks/NCMNativeBackend.xcframework
rustup run 1.96.0 cargo test --locked --manifest-path Vendor/DeviceBackend/rust/Cargo.toml --lib
bash Scripts/test-owned-automation.sh     # ObjC automation bridge host fixture + iOS SDK syntax checks
```

- `build-device-backend.sh` moves the previous xcframework to `.build/previous-NCMNativeBackend-*.xcframework` and needs network access for Cargo.lock dependencies on the first build.
- A full `cargo test` including doctests has 6 known failing vendored `idevice` doctests. Use `--lib` (or `--workspace --features desktop-bootstrap --lib --bins`).
- `Scripts/pair-device-usb.sh --udid '<USB_UDID>' --output .build/pairing/EiscuePairingTransfer.json --enable-wifi` is the desktop USB pairing bootstrap for iOS 26 RemotePairing routes only (see `Scripts/pair-device-usb.md`, `docs/device-setup.md`).

Firmware (requires `IDF_PATH` pointing to an ESP-IDF **v5.5.3** checkout. `Scripts/board-idf-env.sh` rejects any other version. `IDF_TOOLS_PATH` is optional):

```sh
bash Scripts/build-passport-ble.sh esp32c3 # C3 BLE -> .build/passport-ble-firmware/
bash Scripts/build-passport-ble.sh esp32s3 # S3 BLE / USB HID -> .build/s3-hid-firmware/
bash Scripts/test-board-auth.sh           # real HMAC host fixture (OpenSSL), no hardware
bash Scripts/build-passport-firmware.sh   # C3 Wi-Fi relay (builds + packages)
bash Scripts/build-board-firmware.sh      # S3 USB NCM relay (builds + packages)
bash Scripts/test-board-firmware.sh       # NCM-Relay host tests (UBSan, localhost) + Python tool tests
python Scripts/board-firmware.py inspect | probe | check-link | package | verify-package | flash
```

Build scripts never open serial ports or flash hardware. `board-firmware.py flash` checks the package and ROM, backs up the **entire** flash, then writes and verifies. It never uses `erase_flash` and never writes eFuses. When switching between C3 BLE and Wi-Fi images, write only the app partition at `0x20000` and keep the `0xF000` private configuration. Only flash a board, use a serial port, or run on a real device when the user explicitly asks for it.

## Code Style

There are no SwiftLint / SwiftFormat / clang-format configs. Match the surrounding code.

- **Swift 6** language mode with strict concurrency for app and Kits. `PhoneAgentNCM` (vendored) stays in Swift 5 mode. UI state types are `@MainActor`. System/ObjC callbacks that fire on background queues (speech, audio, background tasks) must be non-isolated `@Sendable` closures that hop to `MainActor` explicitly; inheriting MainActor isolation has crashed the app on device before.
- Kit types crossing boundaries are `Sendable`; public enums are `Codable, Sendable` where persisted. Tool parameters use `AgentJSONValue` JSON-schema literals with `"additionalProperties": false`. `mayHaveSideEffects` defaults to `true`; set `false` only for pure observation tools.
- Code is dense: short helpers, several statements per line in places, and few comments. Comments explain *why* a constraint exists (security, race, platform quirk) rather than restating code.
- Debug-only entry points (`--owned-device-check`, `--ble-device-check`, `--bluetooth-setup-check`, `--wireless-board-probe`, `--legacy-device-probe`, `--import-pairing-transfer`, `--device-connection-check`, `--resume-existing-local-tunnel`, UI fixtures) must stay inside `#if DEBUG`. Release builds must not contain automation or auto-import paths.
- UI elements that tests interact with get stable `accessibilityIdentifier`s (e.g. `sendMessageButton`, `modelSettingsButton`, `deviceNavigationLink`). When you add containers, keep child identifiers reachable; container identifiers have hidden children before.
- UI follows native iOS 26 Liquid Glass (`.glass` / `.glassProminent` for standalone buttons, semantic backgrounds for content) with a monochrome adaptive accent. See `docs/chat-experience.md`.
- **Localization**: English is the development language and Simplified Chinese (`zh-Hans`) is the translation. App and extensions use String Catalogs (`Apps/*/Resources/*.xcstrings`, split by area: `Runtime`, `Connections`, `TaskStatus`, `Composer`, `Speech`, `Navigation`, `Bluetooth`, etc.) with `String(localized: "key", table: "Table")`. Kits use `Resources/{en,zh-Hans}.lproj/*.strings` with `String(localized:defaultValue:bundle: .module)`. Use semantic keys, plural variations and Foundation formatting. Never branch on language in Swift. To add a language, update every catalog, add Kit `.lproj` files, add it to `CFBundleLocalizations` in `project.yml`, and regenerate. Model protocols, tool names, bundle IDs and system prompts are not translated. See `docs/localization.md`.
- Commit messages are short, imperative and sentence case (e.g. "Fix Gemini Chat Completions store compatibility").

## Testing

- **Kits** (`Tests/EiscueAgentKitTests`, `Tests/EiscueDeviceKitTests`) use **Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`) and run with `swift test` on macOS. AgentKit tests drive the real PiDurableKit runtime through faux/URLProtocol fixtures. Real model calls are never made.
- **App unit tests** (`Tests/EiscueAppTests`) use **XCTest** with `@testable import Eiscue`. The target also compiles `Apps/EiscueTunnel/PacketReflector.swift` and `Apps/Shared` directly. Inject storage directories, `UserDefaults`, repositories, and `DeviceController`/identity stores instead of touching real state.
- **UI tests** (`UITests/EiscueUITests`) use XCTest and launch with `--ui-testing --skip-onboarding [--reset-state]` plus `-AppleLanguages (zh-Hans) -AppleLocale zh_CN` (or English). `--ui-testing` isolates state in `Caches/EiscueUITests`, the `org.eiscue.app.uitests` defaults suite, and the `org.eiscue.app.uitests.credentials` Keychain service. `AgentIntegrationUITests` sets `EISCUE_TEST_MODEL_URL=http://127.0.0.1:18765/v1` and needs `Scripts/test-model-server.py` running. The fixture's special prompts trigger 401/503 and streaming-release behavior. Shared navigation helpers are in `TestNavigation.swift`.
- The scheme runs app and UI tests non-parallel. iPad-only (wide sidebar) scenarios are skipped on iPhone, so cover them on an iPad simulator.
- Unsigned simulator builds can't access the Keychain. Keep the default local signing for app tests.
- Firmware host tests are protocol/localhost tests only (UBSan by default via `BOARD_SANITIZERS`; ASan has deadlocked locally). The ObjC automation fixture uses fake runtime classes and never contacts a device.
- **Verification culture** (see `docs/validation.md`): keep "code integrated", "software tests passed" and "real-device acceptance" separate. Simulators can't validate BLE HID input, ReplayKit, background limits, or developer-service control. Report exact test counts and failures, keep aborted or failed runs visible instead of counting them as passes, and don't treat a build, ACK, or local socket close as proof of device behavior. Unverified items currently include Bluetooth swipe, full cross-app agent tasks, long background runs, S3 USB NCM hardware, and company-VPN coexistence.

## Security

- **Secrets**: The model API key (Keychain service `org.eiscue.app.credentials`, account `model-key`) and RemotePairing private keys (`KeychainPairingIdentityStore`) use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` Keychain items. They must never go to UserDefaults, logs, chat, run reports, or files. `ModelSettings` deliberately excludes credentials.
- **Model endpoints**: The app accepts only HTTPS base URLs without userinfo, query or fragment. Loopback HTTP is allowed only in DEBUG with `--ui-testing` and an `EISCUE_TEST_MODEL_URL` on `127.0.0.1`. The model fixture must never echo request credentials.
- **Screen data**: Screenshots go to the model only when a device task calls the observe tool. Sharing or a manual preview never uploads. The broadcast extension stores only the latest JPEG (longest side ≤ 1600 px) in the file-protected App Group container, with no video history and no audio. Normal screenshots are returned in memory, not written to disk.
- **Text input** overwrites the system clipboard and pastes it, without reading the previous clipboard contents.
- **Reports/logs**: Exported run reports include only allowed metadata and tool status. They never include keys, pairing data, raw screenshots, or full input arguments. Device OSLog (`org.eiscue.device`/`connection`) records only operation names and numeric codes. Rust `tracing` is compiled with `max_level_off` so protocol traces can't leak credentials or frames.
- **Pairing transfer**: `EiscuePairingTransfer.json` (gitignored, mode `0600`) contains a private key. The app deletes it after import, and the desktop copy should be removed. Never commit it or put it in chat or cloud storage. The iOS UI-automation passcode is entered by the user on the device only.
- **Never commit**: `.build/` contents such as board flash backups (`.build/board-backups/`, which can contain device identity), `wifi-setup.txt` SSID/password, raw device logs, crash reports, passcode-page screenshots, or pairing files. PEM files under `Vendor/DeviceBackend/rust/tests/fixtures/lockdown/` are test fixtures only.
- **Skills**: Imported skills are UTF-8 Markdown instructions only. Scripts inside them are never executed, and skills can't widen tool permissions or grant a shell.
- **Attachments** are copied to app-private storage, re-encoded to strip EXIF, and bounded (max 4 per message, 20 MiB source, 2048 px / 2 MiB images, 100-page PDFs, 60,000 bytes of extracted text). They're sent to the model only on send.
- **Licensing**: The linked device backend is GPL-3.0-only (vendored `idevice` is MIT), the tunnel uses the custom StosVPN license, and PiDurableKit is CC0 plus embedded JS notices. Keep provenance files (`SOURCE_MANIFEST.json`, `UPSTREAM_THIRD_PARTY.md`, `LICENSE`, `DEVICE_HUB_LICENSE`) in place and record upstream-file changes in the manifest. Don't make or imply a license decision for all of Eiscue. The developer-services route relies on private DDI interfaces and has no App Store commitment.

## Configuration

- **Project settings** live in `project.yml`: iOS deployment target 26.0, `SWIFT_VERSION` 6.0, `SWIFT_EMIT_LOC_STRINGS`, automatic signing with `DEVELOPMENT_TEAM` Q2T8TN4ZW6. Bundle IDs are `org.eiscue.app` (app), `.tunnel`, `.broadcast`, `.tests` and `.uitests`. The Swift package (`Package.swift`) targets iOS 17 / macOS 14 with default localization `en`.
- **Signing / entitlements**: The app and `EiscueBroadcast` share App Group `group.org.eiscue.app` (`ScreenBroadcastStore.defaultAppGroupIdentifier`). The app and `EiscueTunnel` need the Network Extension `packet-tunnel-provider` capability. If you change the app's bundle ID, keep the `.tunnel` / `.broadcast` suffixes and update the App Group to match.
- **Info.plist keys** are set in `project.yml`: camera, Bluetooth, microphone, speech and local-network usage strings (localized in `InfoPlist.xcstrings`); `UIBackgroundModes: bluetooth-central`; `BGTaskSchedulerPermittedIdentifiers`; `NSAllowsLocalNetworking`; and Bonjour `_remotepairing._tcp` / `_remotepairing-pairable-host._tcp`.
- **Dependencies** are pinned. PiDurableKit uses revision `6e7f2671…` (SwiftPM) and swift-markdown is exactly 0.9.0 (Xcode project only). `Package.resolved`, `Cargo.lock` and firmware `dependencies.lock` are committed. See `docs/dependencies.md`.
- **Environment variables**: `EISCUE_TEST_MODEL_URL` (UI-test model fixture), `EISCUE_RUST_TOOLCHAIN` (default `1.96.0`), `IDF_PATH` / `IDF_TOOLS_PATH` (ESP-IDF 5.5.3), `BOARD_SANITIZERS` and `CC` (firmware host tests).
- **Runtime data**: Everything lives in the app sandbox under `Application Support/Eiscue/`: `conversations.json`, `Runtime/` (per-conversation Pi SQLite), `Runs/` (task journal), `Skills/` (imported), and `Attachments/`. Built-in skills are `Apps/Eiscue/Resources/Skills/*.md`. Deleting a conversation removes its runtime files and journal; deleting the API key keeps conversations. Preferences such as `deviceConnectionMethod`, `appearance`, `modelSettings` and `onboardingVersion` are stored in UserDefaults.
- **Local tunnel** addresses are fixed: local `10.7.1.1/24`, peer `10.7.0.1/32`, host route only, no default route or DNS. The Wi-Fi board is `192.168.7.1/30` and the phone gets `.2`. The USB NCM board is `192.168.7.1/24` and the phone uses a manual `.2`.
- **Build artifacts**: `.build/` is gitignored and holds research checkouts, backend/firmware builds, test results, and private board backups.
