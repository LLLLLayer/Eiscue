# AGENTS.md

Guidance for agents and contributors working in this repository. Public overviews: [English](README.md) · [简体中文](README.zh-CN.md). Keep both README versions consistent when changing features, setup steps, limitations or verification status. Firmware and vendor READMEs are tracked and in English.

Product docs under `docs/` are local-only, gitignored and mostly in Simplified Chinese; a fresh clone may not have them. `docs/roadmap.md` holds the architecture review and code / architecture / business roadmap. Keep public setup instructions self-contained and do not add public links to these untracked files.

## Project Overview

Eiscue is an on-device agent assistant for iPhone / iPad (app minimum **iOS / iPadOS 26.0**). Task orchestration and tool execution run on the phone; the model is called over a user-configured HTTPS service (OpenAI Chat Completions–compatible, OpenAI Responses, or Anthropic Messages). The agent can optionally observe and operate the device itself.

Main pieces:

- **Eiscue app** (`Apps/Eiscue`, SwiftUI): conversations, model settings (key in Keychain), attachments, on-device dictation, skills, run journal, background execution, device setup UI. `AppModel` (`@MainActor @Observable`) is the central state object; extensions such as `AppModel+Attachments.swift` split it by concern.
- **EiscueAgentKit** (`Sources/EiscueAgentKit`): Eiscue-owned agent/tool/event protocol (`AgentClient`, `AgentEngine`, `AgentTool`, `AgentEvent`), conversation models and `JSONConversationRepository`. `Internal/Runtime` adapts **PiDurableKit** (pinned commit, runs on JavaScriptCore, one SQLite per conversation).
- **EiscueDeviceKit** (`Sources/EiscueDeviceKit`): `DeviceController` protocol + `DeviceClient`, device models/capabilities, `BluetoothDeviceController` (BLE HID + ReplayKit frames), `ScreenBroadcastStore`, `KeychainPairingIdentityStore`, and the developer-services backend (`LocalDeviceController` → `PhoneAgentNCM` → C ABI → Rust).
- **App extensions**: `Apps/EiscueBroadcast` (ReplayKit broadcast upload; caches only the latest JPEG frame in the App Group) and `Apps/EiscueTunnel` (Packet Tunnel loopback reflector, used only by the local-VPN route). `Apps/Shared` holds config shared by the app and tunnel.
- **Vendor/DeviceBackend**: GPL-3.0 control backend copied from actell at a pinned commit (Swift `PhoneAgentNCM`, C `CNCMBackend`, ObjC `CEiscueAutomation`, Rust crate + vendored `idevice`), shipped as the prebuilt `NCMNativeBackend.xcframework` (arm64 iOS, arm64 simulator, arm64 macOS only; no x86_64).
- **Vendor/LocalTunnel**: LocalDevVPN / StosVPN–derived reflector source and license, bundled as app resources.
- **Firmware** (ESP-IDF v5.5.3): `Passport-BLE` (ESP32-C3 BLE HID), `NCM-Relay` (ESP32-S3 USB NCM relay, no real-board validation yet). `Passport-BLE` also builds explicitly for S3: BLE commands with selected BLE or USB HID output, independent ReplayKit observation, no VPN. Its 16 MB profile preserves the attached board's 24 KB NVS layout; do not reuse the C3 partition table. The Wi-Fi hotspot relay has been retired; its design is kept locally in `docs/wifi-hotspot-relay-retired.md`. Preserve the existing C3 partition layout and private configuration when updating BLE firmware.
- **C3 companion display**: the existing board profile drives ST7789 with packed Eiscue expressions, localized fixed phases and observed tool-step counts. Optional encrypted AB8/AB9 GATT channels carry only status and the physical OK-stop latch; they are separate from HID commands. A released-then-held OK key unlocks only after disconnect, requiring fresh calibration. S3 has no display channel. Asset sources and generation instructions are in `Firmware/Passport-BLE/Resources/README.md`.

### Repository layout

```text
Apps/Eiscue/            SwiftUI app
  AppModel*.swift       central @MainActor state, split by concern (+ extensions in Integrations/, Services/)
  Features/             views (AssistantView, DeviceView, BluetoothBoardSetupView, ModelSettingsView, sidebar, onboarding…)
  Integrations/         Kit bridges: DeviceTools (schemas → DeviceDecision), DeviceTaskRunner, DeviceConnection,
                        BoardCompanion, DeviceRunCleanup, BLE/owned-automation checks, Debug* fixtures (DEBUG only)
  Models/               app value types: ModelSettings/ModelProfile, RunRecord + RunJournal, ConversationFeed, presentations
  Services/             Keychain CredentialStore, BackgroundExecution, LocalTunnelManager, attachments, speech, skills, sharing
  Resources/            *.xcstrings (per area), Assets, built-in Skills/*.md, Stickers.json, OpenSourceLicenses
Apps/EiscueBroadcast/   ReplayKit upload extension (SampleHandler)
Apps/EiscueTunnel/      Packet Tunnel reflector (local-VPN route only)
Apps/Shared/            config shared by app and tunnel
Sources/EiscueAgentKit/ public API at top level, Models/, Tools/, Storage/; Pi adapter in Internal/Runtime/
Sources/EiscueDeviceKit/ public API at top level, Bluetooth/, ScreenBroadcast/; developer-services backend in Internal/
Tests/                  EiscueAgentKitTests, EiscueDeviceKitTests (Swift Testing); EiscueAppTests (XCTest)
UITests/EiscueUITests/  XCTest UI + real-runtime integration tests; BoardAcceptanceUITests is real-hardware opt-in
Vendor/                 DeviceBackend (GPL, actell-derived; prebuilt xcframework), LocalTunnel (StosVPN license)
Firmware/               Passport-BLE (C3/S3 HID), NCM-Relay (S3 USB NCM)
Scripts/                build/test/flash helpers, model fixture server, USB pairing bootstrap, asset generators
```

### Change recipes

- **New or changed device tool**: the tool name string is repeated across `Integrations/DeviceTools.swift` (schema, decision decoding, capability filter), `Integrations/DeviceTaskRunner.swift` (`DeviceAction.toolName`), `Models/ConversationFeed.swift` (activity titles), `Models/TaskStatusPresentation.swift`, `Models/BoardCompanionPresentation.swift`, `Services/ToolImagePreviewStore.swift` and `Features/MessageInteractionViews.swift`. Update the relevant mappings together. Add a `DeviceCapability` when needed, and advertise it in a controller's `status()` only when that backend actually supports it and its readiness requirements hold. Extend `DeviceToolSessionTests` / `DeviceTaskRunnerTests` to cover supported execution and verify that unsupported backends do not expose the tool.
- **New connection route**: add a `DeviceConnectionMethod` case, a controller `connect…` method and `DeviceClient.connect(method:)` mapping, then the app's route selection in `Integrations/DeviceConnection.swift` and `DeviceView`. Routes never fall back to each other, and switching releases the old session first (`selectDeviceConnectionMethod`).
- **Provider quirk**: keep it inside `Sources/EiscueAgentKit/Internal/Runtime/`, scoped to the exact host/path/protocol like `GoogleCompletionCompatibility`, and cover it with a `ProviderIntegrationTests` URLProtocol fixture.
- **User-visible copy**: edit the String Catalog or Kit `.strings` for both `en` and `zh-Hans`, then search `Tests/` and `UITests/` for the old literal. `DeviceErrorPresentationTests` and several UI tests assert exact text.
- **Target, Info.plist, entitlement or localization-list change**: edit `project.yml` and run `xcodegen generate`.

### Architecture rules

- The two Kits **must not depend on each other**. Only the app integration layer bridges them. `DeviceToolSession` (`Apps/Eiscue/Integrations/DeviceTools.swift`) adapts tool schemas/JSON to typed `DeviceDecision`s. `DeviceTaskRunner` depends on DeviceKit only and owns scope/capability/frame/timeout gates, serialized execution, redacted logs, progress phases and mandatory post-action observation.
- Public Kit APIs must not expose PiDurableKit or actell types. `public` access control defines the API; directories are just organization. There is no separate "Plugin" product.
- Engines are swappable via `AgentClient(engine:)`; device backends via `DeviceClient(controller:)`. New app preferences default to `localVPN` with the developer-services `DeviceClient()`; saved route choices are preserved. Selecting Bluetooth uses `BluetoothDeviceController` and retains the network client for switching back.
- S3 HID commands and replies use per-connection HMAC and monotonic sequence numbers; every command, including STOP/INFO, is authenticated. First enrollment is restricted to an unclaimed board's first 60 s of power, with the candidate key saved in Keychain before enrollment. Never replace an existing board key automatically. Enrollment uses encrypted Just Works and is a trusted-nearby development flow, without a MITM guarantee.
- Developer control backend (`DeviceControlBackend`) is separate from transport: `automatic` selects XCTest on iOS 26 and CoreDevice DisplayService/HID on iOS 27+; explicit `coreDevice` or `xcTest` is fixed for the session with no fallback. CoreDevice is unavailable below iOS 27. Backend changes release the current network session before persisting the new choice, retain pairing, and never start a connection automatically. Do not switch during a run or recovery. iOS 27 XCTest is integrated but lacks physical acceptance.
- Connection methods (`DeviceConnectionMethod`): `bluetoothBoard` (BLE HID + ReplayKit; no VPN, pairing file or DDI), `localVPN` (new-install default), `usbBoard` (RemotePairing / CoreDevice paths that need a pairing identity and developer environment). A route never silently falls back to another one. A retired `wirelessBoard` preference loads as disconnected `localVPN` without starting a connection.
- `EiscueBroadcast` compiles `Sources/EiscueDeviceKit/ScreenBroadcast/ScreenBroadcastStore.swift` directly so the extension doesn't link the device backend. Keep that file Foundation-only.
- Selecting Bluetooth at runtime does not remove the linked GPL backend from the binary; a pure-BLE distribution would need a target split.

### Agent / device behavior contracts (do not weaken)

- Task scope is `chat`, `observe`, or `control`, fixed when a run starts. Plain chat registers **no tools** and only a short system prompt. "Allow AI to operate device" defaults on in the device page; explicit off choices persist. New messages use chat scope while the device is unready, and control scope only when allowed and ready. Scope is captured before message persistence and never widened during a run or recovery. Device tools are filtered by the controller's actual `DeviceStatus` capabilities (HID has no Home, app list or bundle-ID launch; restricted keyboard navigation requires supporting firmware plus verified pointer/text calibration, and its visible effect must be checked).
- The runtime always opens with `resume:false`. Recovery is read-only; continuing an interrupted run requires an explicit `.resume`. Unaccepted messages are retried with the same `requestID`.
- Normal completion, settled pauses and unused model-request failures retain the selected connection by default after `DeviceClient.finishTask()` releases task-scoped input and invalidates old observations. The optional `disconnectAfterTask` setting defaults off. Scene backgrounding alone does not disconnect; plain chat still stops when backgrounded. This is not an execution lease or a guarantee of idle transport survival after OS suspension. Tool-budget and no-progress pauses settle the runtime before retention. Explicit continuation starts a new request and observes again; it never replays settled side effects. Read-only verification tools reserve the final call after an ordinary action. Device action tools use `executionCost=2, verifiesSideEffects=true`: they reserve input plus automatic observation before dispatch, stay unsafe to replay, and return the new screenshot/frame in the same result. Failed post-action observation pauses without repeating the input; storage or delivery uncertainty stops and disconnects. The runner also bounds typed callers with the same per-run operation limit; it does not create another Agent or SQLite loop. Conversation progress is held only from each observation boundary to its action outcome, with callbacks bound to the run ID.
- Side-effect tools use unsafe replay at the runtime level, but the host gate stops after an unknown outcome. `DeviceControlError.deliveryUnknown` is never retried automatically.
- Each coordinate action must use the newest screenshot's `frameID` and consumes it; actions, reconnects, rotation or geometry changes invalidate frames. RemotePairing frames last 30 s. ReplayKit stream liveness requires a publication within 3 s, or the extension heartbeat (every 0.5 s) naming the current frame with no newer buffer pending. Per the product decision, new pixels/animation alone do not revoke the model's latest single-use observation: it remains actionable for 30 s from issuance while the stream is live and session/geometry/calibration match. Do not renew that decision age when reading the live stream; paused/stopped sessions never authorize input. Each BLE observation gets a new `frameID`. Coordinates are screenshot pixels.
- Device operations are serialized (concurrent calls return `busy`). Success only means the command was sent; callers re-observe to confirm.
- HID readiness needs three separate conditions: authenticated BLE command connection (S3), selected BLE/USB output ready, and active screen sharing plus four-point touch/text calibration passed. C3 uses the existing encrypted BLE command protocol. A BLE acknowledgement doesn't count as a verified action.
- Stop callbacks carry a `runID` so a stale stop can't cancel a newer run. On event-save failure the host cancels and waits for the engine to close before reopening the same SQLite.
- Background device tasks use `BGContinuedProcessingTask` (`BackgroundExecution.swift`, identifier `$(PRODUCT_BUNDLE_IDENTIFIER).agent.continued-processing`). VPN, ReplayKit and Bluetooth background modes are not execution leases. Agent activity progress uses a fixed large display scale from launch so the ring stays nearly empty, with actual completed-step increments and phase text; it is not a workload estimate. Fill the ring only after successful cleanup and journal persistence, then end the activity. iOS controls dismissal and may deprioritize very low progress under resource pressure; this display choice is not a background-lifetime guarantee. Send an enabled local notification only if the activity did not receive the final result, avoiding duplicate alerts.
- Gemini's official OpenAI-compatible endpoint (`GoogleCompletionCompatibility.applies`: HTTPS `generativelanguage.googleapis.com/v1beta/openai`, Chat Completions only) gets `supportsStore=false`, a JS `afterResponse` hook that relabels a tool-bearing `stop` as `toolUse`, and per-call `thought_signature` preservation. Never widen this to other hosts or protocols. A final answer that still carries unexecuted tool calls is an error, never a success.

For more detail, see `docs/architecture.md`, `docs/agent-kit.md`, `docs/device-setup.md`, `docs/background.md`, `docs/local-tunnel.md`, `docs/design-v0.4.md`, `docs/validation.md` (dated evidence log) and `docs/roadmap.md` (architecture review and plan).

## Build & Commands

Requires an Apple Silicon Mac and Xcode 26+ (validation records use Xcode 26.3 / Swift 6.2.4). The Xcode project is generated by **XcodeGen** (`project.yml`, minimum XcodeGen 2.45.0). Regenerate it after any target, settings, Info.plist property or localization-list change; don't hand-edit `Eiscue.xcodeproj`.

Before running SwiftPM, preserve the current contents and staged/unstaged state of `Package.resolved`. `swift test` can drop the Xcode-only swift-markdown/cmark pins. Compare with that pre-run state and restore only changes produced by this run; never overwrite pre-existing or concurrent edits with an unconditional checkout/restore from Git.

For logged checks, use `bash Scripts/run-logged-check.sh .build/<unique-name>.log <command> [arguments...]`. It saves stdout/stderr and `exit=<code>`, returns the command's actual exit code, and refuses to overwrite an existing log. Do not end a test wrapper with only `echo`/`printf`: that masks failures as exit 0. A fixture server intentionally stopped after testing is a separate lifecycle result, not a test pass.

```sh
xcodegen generate

# Kit tests (EiscueAgentKitTests + EiscueDeviceKitTests)
swift test
swift test --filter ProviderIntegrationTests   # local URLProtocol fixture, no real model
swift test --filter DeviceKitTests

# App build
xcodebuild -project Eiscue.xcodeproj -scheme Eiscue \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 build

# App unit tests only (fast; no model fixture needed)
xcodebuild -project Eiscue.xcodeproj -scheme Eiscue \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' -only-testing:EiscueAppTests test

# UI tests that don't need the model fixture
xcodebuild -project Eiscue.xcodeproj -scheme Eiscue \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' \
  -only-testing:EiscueUITests/EiscueUITests test
```

For the full app suite (`EiscueAppTests` + `EiscueUITests`, non-parallel, about 20 minutes on one simulator), first keep the deterministic model fixture running in a separate terminal. It listens on `127.0.0.1:18765` and needs no API key:

```sh
python3 Scripts/test-model-server.py
```

Run the suite from another terminal:

```sh
xcodebuild -project Eiscue.xcodeproj -scheme Eiscue \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' test
```

Device backend (Rust, pinned toolchain 1.96.0; the default rustup toolchain isn't changed):

```sh
rustup toolchain install 1.96.0 --profile minimal --target aarch64-apple-ios,aarch64-apple-ios-sim
bash Scripts/build-device-backend.sh      # rebuilds Vendor/DeviceBackend/Frameworks/NCMNativeBackend.xcframework
CARGO_TARGET_DIR=.build/device-rust rustup run 1.96.0 cargo test --locked \
  --manifest-path Vendor/DeviceBackend/rust/Cargo.toml --lib
bash Scripts/test-owned-automation.sh     # ObjC automation bridge host fixture + iOS SDK syntax checks
```

- Set `CARGO_TARGET_DIR` as above (the build script uses the same directory). Without it Cargo writes an untracked, un-ignored `Vendor/DeviceBackend/rust/target/`.
- The prebuilt xcframework archives are committed in full on each rebuild, so rebuild only when backend source changes, and record the change in the vendor README.
- `build-device-backend.sh` moves the previous xcframework to `.build/previous-NCMNativeBackend-*.xcframework` and needs network access for Cargo.lock dependencies on the first build.
- A full `cargo test` including doctests has 6 known failing vendored `idevice` doctests. Use `--lib` (or `--workspace --features desktop-bootstrap --lib --bins`).
- `Scripts/pair-device-usb.sh --udid '<USB_UDID>' --output .build/pairing/EiscuePairingTransfer.json --enable-wifi` is the desktop USB pairing bootstrap for iOS 26 RemotePairing routes only (see `Scripts/pair-device-usb.md`, `docs/device-setup.md`).
- `python3 Scripts/setup-device.py` is the macOS interactive wrapper. The app's inline connection setup copies a complete command that clones the source into a fresh temporary folder and runs this wrapper, without depending on the user's current directory. It checks prerequisites, requires explicit USB device selection and confirmation, then generates and transfers an identity to the installed app without overwriting a pending transfer. It cleans up its private desktop temporary files; import remains a user action in the app. It does not prepare DDI, install toolchains, start VPN or run device control. Do not invoke the real pairing flow without user authorization; use `--help` or `Scripts/Tests/test_setup_device.py` for offline verification.

Firmware (ESP-IDF **v5.5.3**; `Scripts/board-idf-env.sh` rejects any other version. `IDF_TOOLS_PATH` is optional). The builds and `test-board-firmware.sh` (which compiles IDF's cJSON) need `IDF_PATH`. The auth host fixture needs clang and OpenSSL; the companion host fixture needs only clang. Neither requires ESP-IDF:

```sh
bash Scripts/build-passport-ble.sh esp32c3 # C3 BLE -> .build/passport-ble-firmware/
bash Scripts/build-passport-ble.sh esp32s3 # S3 BLE / USB HID -> .build/s3-hid-firmware/
bash Scripts/test-board-auth.sh           # real HMAC host fixture (OpenSSL), no hardware
bash Scripts/test-board-companion.sh      # C3 status/stop/button/bitmap UBSan fixture, no hardware
bash Scripts/build-board-firmware.sh      # S3 USB NCM relay (builds + packages)
bash Scripts/test-board-firmware.sh       # NCM-Relay host tests (UBSan, localhost) + Python tool tests
python3 Scripts/board-firmware.py --help
python3 Scripts/board-firmware.py flash --help
```

Build scripts never open serial ports or flash hardware. The packaging/flashing CLI supports these profiles only:

| CLI profile | Firmware | Board |
| --- | --- | --- |
| `s3-hid` | `Passport-BLE`, BLE commands with selected BLE / USB HID output | ESP32-S3, 16 MB profile |
| `ncm` | `NCM-Relay`, USB NCM relay | ESP32-S3, 4 MB profile |

There is **no C3 BLE CLI profile**; the retired `passport` profile is rejected. C3 BLE build output is an app image. When updating a C3 with the already verified matching partition layout, retain a verified full-flash backup, write only the app partition at `0x20000`, preserve private configuration at `0xF000`, and verify readback. Do not apply this app-only procedure to an unknown layout or write the C3 partition table to S3. See [HID firmware setup](Firmware/Passport-BLE/README.md) for the layout requirements.

For a supported S3 HID or relay package, `board-firmware.py flash` requires both `--port` and `--package`. It checks the package and ROM, backs up and verifies the **entire** flash, then writes and verifies the package images. It never uses `erase_flash` or writes eFuses. This is a package installation path, not the app-only C3 BLE update procedure. Only flash a board, use a serial port, or run on a real device when the user explicitly asks for it.

## Code Style

There are no SwiftLint / SwiftFormat / clang-format configs. Match the surrounding code.

- **Swift 6** language mode with strict concurrency for app and Kits. `PhoneAgentNCM` (vendored) stays in Swift 5 mode. UI state types are `@MainActor`. System/ObjC callbacks that fire on background queues (speech, audio, background tasks) must be non-isolated `@Sendable` closures that hop to `MainActor` explicitly; inheriting MainActor isolation has crashed the app on device before.
- Kit types crossing boundaries are `Sendable`; public enums are `Codable, Sendable` where persisted. Tool parameters use `AgentJSONValue` JSON-schema literals with `"additionalProperties": false`. `mayHaveSideEffects` defaults to `true`; set `false` only for pure observation tools.
- Code is dense: short helpers, several statements per line in places, and few comments. Comments explain *why* a constraint exists (security, race, platform quirk) rather than restating code.
- Every `--…` launch argument must be read only inside `#if DEBUG`. This includes device checks (`--owned-device-check`, `--owned-device-smoke`, `--ble-device-check`, `--bluetooth-setup-check`, `--system-pairing-check`, `--loopback-reflector-check`, `--legacy-device-probe`, `--device-connection-check`), tunnel/import helpers (`--import-pairing-transfer`, `--resume-existing-local-tunnel`, `--restart-existing-local-tunnel`), diagnostics (`--pairing-diagnostics`, `--speech-diagnostics`), `--pairing-local-interface` (publishes pairing on `en0` instead of the VPN peer) and the `--ui-testing` fixtures. Retired `--wireless-board-probe` / `--owned-device-check-wireless` flags make the setup check return without action. Release builds must not contain automation or auto-import paths. `--owned-device-smoke` requires `--owned-device-check` and limits verification to one connection, screenshot, owned counter-button tap, post-action screenshot and local disconnect; it does not establish cross-app or background acceptance.
- Speech handoff: switching to voice mode or back to keyboard without recording must retain the device connection. For an active iOS 27+ `localVPN` / `usbBoard` connection using CoreDevice DisplayService, an actual tap/hold recording request temporarily releases control after speech/microphone authorization, preserving pairing and VPN. Start capture only after confirmed release; canceled permission/preparation work must never start recording later. After capture finishes, fails or is canceled, or the user switches to keyboard or navigates away, restore the captured route and resolved backend once capture has fully stopped, only in the foreground. Manual connection/backend changes or backgrounding cancel pending restoration; never fall back or retry automatically. Failed release prevents recording and must not trigger automatic reconnection; failed reconnection preserves the draft and shows a localized notice. Other routes are unaffected: owned XCTest on any OS, disconnected/merely selected routes, and BLE / USB HID (both use `bluetoothBoard` with ReplayKit, not the `usbBoard` network relay).
- Speech evidence and diagnostics: a three-phase iPhone 12 mini / iOS 27 local-VPN check on 2026-10-15 confirmed nonzero microphone input before CoreDevice connection, all-zero PCM plus system remote-control mute while connected, and restored input after confirmed media release. Pairing and VPN remained unchanged; public `isInputMuted` remained false. This historical check validates capture on that device, not the subsequent automatic voice handoff, transcription or all OS builds. USB network relay uses the same DisplayService backend, but has no microphone acceptance evidence. Unaffected routes still need physical microphone-coexistence acceptance. A stream of all-zero PCM buffers is not evidence of recording. `--speech-diagnostics` and `--speech-capture-check` are DEBUG-only; the latter also requires the former and runs a bounded capture without saving audio or text. Diagnostics store only permissions, audio format, buffer counts, levels and error codes in the app sandbox.
- UI elements that tests interact with get stable `accessibilityIdentifier`s (e.g. `sendMessageButton`, `modelSettingsButton`, `deviceNavigationLink`). When you add containers, keep child identifiers reachable; container identifiers have hidden children before.
- UI follows native iOS 26 Liquid Glass (`.glass` / `.glassProminent` for standalone buttons, semantic backgrounds for content) with a monochrome adaptive accent. See `docs/chat-experience.md`.
- Device screen previews and repeat input diagnostics belong to the Debug section for all routes, controlled by the persisted `showsDebugTools` preference (default on in Debug builds). Compile both the setting and diagnostic entries out of Release. Required HID calibration remains visible until valid, independently of the debug preference.
- Message history uses lazy rows and a cached feed projection. Keep initial bottom positioning, respect manual reading while streaming, and freeze asynchronous Markdown publication during device observation/input boundaries. The sidebar opens with a rightward drag and closes leftward; remove its modal surface when fully hidden.
- **Localization**: English is the development language and Simplified Chinese (`zh-Hans`) is the translation. App and extensions use String Catalogs (`Apps/*/Resources/*.xcstrings`, split by area: `Runtime`, `Connections`, `TaskStatus`, `Composer`, `Speech`, `Navigation`, `Bluetooth`, etc.) with `String(localized: "key", table: "Table")`. Kits use `Resources/{en,zh-Hans}.lproj/*.strings` with `String(localized:defaultValue:bundle: .module)`. Use semantic keys, plural variations and Foundation formatting. Never branch on language in Swift. To add a language, update every catalog, add Kit `.lproj` files, add it to `CFBundleLocalizations` in `project.yml`, and regenerate. Model protocols, tool names, bundle IDs and system prompts are not translated. See `docs/localization.md`.
- Pass UI keys through `LocalizedStringKey` / `String.LocalizationValue`, or resolve them before passing a `String` to a view; a variable `String` is displayed verbatim. Built-in skill Markdown is canonical English instruction text, with localized names and summaries; its source preview must match the instructions and digest. Imported content remains unchanged.
- Commit messages are short, imperative and sentence case (e.g. "Fix Gemini Chat Completions store compatibility").

## Testing

- **Kits** (`Tests/EiscueAgentKitTests`, `Tests/EiscueDeviceKitTests`) use **Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`) and run with `swift test` on macOS. AgentKit tests drive the real PiDurableKit runtime through faux/URLProtocol fixtures. Real model calls are never made.
- **App unit tests** (`Tests/EiscueAppTests`) use **XCTest** with `@testable import Eiscue`. The target also compiles `Apps/EiscueTunnel/PacketReflector.swift` and `Apps/Shared` directly. Inject storage directories, `UserDefaults`, repositories, and `DeviceController`/identity stores instead of touching real state.
- **UI tests** (`UITests/EiscueUITests`) use XCTest and launch with `--ui-testing --skip-onboarding [--reset-state]` plus `-AppleLanguages (zh-Hans) -AppleLocale zh_CN` (or English). `--ui-testing` isolates state in `Caches/EiscueUITests`, the `org.eiscue.app.uitests` defaults suite, and the `org.eiscue.app.uitests.credentials` Keychain service. `AgentIntegrationUITests` sets `EISCUE_TEST_MODEL_URL=http://127.0.0.1:18765/v1` and needs `Scripts/test-model-server.py` running. The fixture's special prompts trigger 401/503 and streaming-release behavior. Shared navigation helpers are in `TestNavigation.swift`.
- Normal installs, launches and real-state device diagnostics must respect the phone's system / per-app language. Do not pass `-AppleLanguages` or `-AppleLocale` to these runs unless the user explicitly requests a language override. Keep explicit language selection in isolated UI / localization fixtures only.
- The scheme runs app and UI tests non-parallel. iPad-only (wide sidebar) scenarios are skipped on iPhone, so cover them on an iPad simulator.
- Physical-device UI cases skip unless explicitly enabled: `TEST_RUNNER_EISCUE_REAL_BOARD_TEST=1` (board acceptance), `TEST_RUNNER_EISCUE_REAL_DEVICE_TEST=1` (system pairing preparation), `TEST_RUNNER_EISCUE_REAL_SPEECH_TEST=1` (microphone capture) and `TEST_RUNNER_EISCUE_DEVICE_SCREENSHOT=1`. Set them only when the user asks for that hardware run.
- Unsigned simulator builds can't access the Keychain. Keep the default local signing for app tests.
- Firmware host tests are protocol/localhost tests only (UBSan by default via `BOARD_SANITIZERS`; ASan has deadlocked locally). The ObjC automation fixture uses fake runtime classes and never contacts a device.
- **Verification culture** (see `docs/validation.md`): keep "code integrated", "software tests passed" and "real-device acceptance" separate. Simulators can't validate BLE HID input, ReplayKit, background limits, or developer-service control. Report exact test counts and failures, keep aborted or failed runs visible instead of counting them as passes, and don't treat a build, ACK, or local socket close as proof of device behavior. Unverified items currently include Bluetooth swipe, full cross-app agent tasks, long background runs, S3 USB HID phone input, S3 USB NCM hardware, and company-VPN coexistence.

### Recorded baseline

Evidence from **2026-10-15**, commit `14d154f`, Xcode 26.3 (`DEVELOPER_DIR`), iPhone 16e / iOS 26.3.1 simulator, full UI suite with `Scripts/test-model-server.py` running. These are recorded results, not a guarantee for later changes. Logs are local under `.build/agents-init/`.

| Check | Recorded result |
| --- | --- |
| Kit tests (`swift test`) | 155 tests / 19 suites; 4 failing tests, 10 issues. Xcode 27 failed to compile `ProviderFixtureProtocol.startLoading()` due to a sending-closure isolation error; no tests ran |
| App unit tests | 242 passed |
| UI tests | 56 run: 42 passed, 9 skipped, 5 failed |
| Firmware auth host fixture | 6 groups passed |
| Firmware companion host fixture | 5 groups passed |
| NCM host / Python firmware tests (`test-board-firmware.sh`) | Not run: `IDF_PATH` unset |
| Owned-automation host checks | 332 passed |
| Rust library tests | 68 passed |

Failures and skipped coverage at that baseline:

- `DeviceErrorPresentationTests`: 4 tests asserted copy changed in `a465682`.
- `AgentIntegrationUITests`: the same 2 failures as `efb7703`. The timeline test read an empty `toolActivityRow` container label after `08cf84b` moved the title into its own accessibility element. The pause test expected `toolError.noProgress`, while the card showed `RunPauseReason.detail` (since `a957ab1`).
- `EiscueUITests.testBuiltInSkillCanBePreviewedAndSelected` asserted the Chinese preview text `先观察当前屏幕`; built-in skill Markdown became canonical English in `14d154f`.
- `EiscueUITests.testModelConfigurationValidatesHTTPSAndDoesNotPrefillSavedKey`: `reveal` could not make `modelAPIKey` hittable after six swipes. Follow-up inspection found the scroll targeted the underlying settings/keyboard accessory instead of the presented form.
- `MessageSharingUITests`: the two share-sheet tests that failed at `efb7703` passed. `testAttachmentOnlyFileSavesToLocalFilesAndReadsBackExactBytes` failed inside the system Files picker ("renamed folder did not become a selectable native directory"); that run did not verify save/readback.
- The 9 skips are 3 real-board cases, 4 physical-device/opt-in cases (control probe, screenshot, speech capture, system pairing), 1 iOS 27-only voice notice and 1 iPad-only sidebar case; they are not passes.

Follow-up fixes on **2026-10-15** (`.build/review-fixes-20261015/`):

- Kit tests: **155 passed / 19 suites** with both Xcode 26.3 and Xcode 27 (the latter ran the two test products separately). The provider fixture explicitly captures Sendable values; localized error assertions match current copy.
- Model profile app tests: **7 passed** after removing the name field from model setup. New profiles display their model ID; existing saved aliases and credential accounts are preserved.
- Targeted UI reruns: **16 distinct cases passed, 1 physical-device case skipped**, across the core UI, model profiles, two agent timeline/pause cases and three native-sharing cases. The Files test uses the system's actual folder/file elements and verified exact bytes through a fresh public picker. The core form scroll stays above the keyboard accessory and targets the presented form.
- Intermediate runs remain recorded: `ui-tests-01` had 14 passed / 2 failed / 1 skipped; `ui-tests-02` had 7 app tests passed and UI 11 passed / 1 failed / 1 skipped; final `sharing-tests-03` passed all 3 sharing cases. Failed runs return exit 65; the final sharing run returns 0.

Backend-selector follow-up on **2026-10-15**: 108 DeviceKit tests passed; 37 connection app tests passed on each iOS 26.3.1 / 27.0 simulator, with 2 / 3 targeted UI cases passed respectively. No failures or skips. The extra iOS 27 case verified the former CoreDevice voice notice; these records do not validate the subsequent automatic voice handoff. Explicit iOS 27 XCTest physical control remains unverified.

These targeted reruns fix the listed failures; they do not constitute a new full 56-case UI run or physical-device control acceptance. Preserve the original baseline and intermediate failures alongside the rerun evidence.

## Security

- **Secrets**: Model API keys (Keychain service `org.eiscue.app.credentials`, per-profile accounts `model-profile-<UUID>`; the migrated legacy profile retains `model-key`) and RemotePairing private keys (`KeychainPairingIdentityStore`) use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` Keychain items. They must never go to UserDefaults, logs, chat, run reports, or files. `ModelSettings` deliberately excludes credentials.
- **Model endpoints**: The app accepts only HTTPS base URLs without userinfo, query or fragment. Loopback HTTP is allowed only in DEBUG with `--ui-testing` and an `EISCUE_TEST_MODEL_URL` on `127.0.0.1`. The model fixture must never echo request credentials.
- **Screen data**: Device tools send screenshots to the configured model both for explicit observation and for automatic post-action observation. Starting screen sharing or opening a manual preview does not by itself send frames to the model. The broadcast extension stores only the latest JPEG (longest side ≤ 1600 px) in the file-protected App Group container, with no video history and no audio. Tool results pass through the durable runtime, whose per-conversation SQLite history may contain image data; do not claim screenshots are never written to disk. Treat runtime databases as sensitive screen history, separate from the redacted run reports below.
- **Text input** overwrites the system clipboard and pastes it, without reading the previous clipboard contents.
- **Reports/logs**: Exported run reports include only allowed metadata and tool status. They never include keys, pairing data, raw screenshots, or full input arguments. Device OSLog (`org.eiscue.device`/`connection`) records only operation names and numeric codes. Rust `tracing` is compiled with `max_level_off` so protocol traces can't leak credentials or frames.
- **Pairing transfer**: `EiscuePairingTransfer.json` (gitignored, mode `0600`) contains a private key. The app deletes it after import, and the desktop copy should be removed. Never commit it or put it in chat or cloud storage. The iOS UI-automation passcode is entered by the user on the device only.
- **Never commit**: `.build/` contents such as board flash backups (`.build/board-backups/`, which can contain device identity), `wifi-setup.txt` SSID/password, raw device logs, crash reports, passcode-page screenshots, or pairing files. PEM files under `Vendor/DeviceBackend/rust/tests/fixtures/lockdown/` are test fixtures only.
- **Skills**: Imported skills are UTF-8 Markdown instructions only. Scripts inside them are never executed, and skills can't widen tool permissions or grant a shell.
- **Attachments** are copied to app-private storage, re-encoded to strip EXIF, and bounded (max 4 per message, 20 MiB source, 2048 px / 2 MiB images, 100-page PDFs, 60,000 bytes of extracted text). They're sent to the model only on send.
- **Licensing**: The linked device backend is GPL-3.0-only (vendored `idevice` is MIT), the tunnel uses the custom StosVPN license, and PiDurableKit is CC0 plus embedded JS notices. Original HID application source in `Firmware/Passport-BLE` is Apache-2.0; the relay firmware retains its GPL license and provenance. Neither statement grants rights to the app / companion artwork or replaces third-party component licenses. Artwork provenance is recorded in [the companion resources README](Firmware/Passport-BLE/Resources/README.md), which makes no licensing claim for it. Keep provenance files (`SOURCE_MANIFEST.json`, `UPSTREAM_THIRD_PARTY.md`, `LICENSE`, `DEVICE_HUB_LICENSE`) in place and record upstream-file changes in the manifest. Don't make or imply a license decision for all of Eiscue. The developer-services route relies on private DDI interfaces and has no App Store commitment.

## Configuration

- **Project settings** live in `project.yml`: iOS deployment target 26.0, `SWIFT_VERSION` 6.0, `SWIFT_EMIT_LOC_STRINGS`, automatic signing with `DEVELOPMENT_TEAM` Q2T8TN4ZW6. Bundle IDs are `org.eiscue.app` (app), `.tunnel`, `.broadcast`, `.tests` and `.uitests`. The Swift package (`Package.swift`) targets iOS 17 / macOS 14 with default localization `en`.
- **Signing / entitlements**: The app and `EiscueBroadcast` share App Group `group.org.eiscue.app` (`ScreenBroadcastStore.defaultAppGroupIdentifier`). The app and `EiscueTunnel` need the Network Extension `packet-tunnel-provider` capability. If you change the app's bundle ID, keep the `.tunnel` / `.broadcast` suffixes and update the App Group to match.
- **Info.plist keys** are set in `project.yml`: camera, Bluetooth, microphone, speech and local-network usage strings (localized in `InfoPlist.xcstrings`); `UIBackgroundModes: bluetooth-central`; `BGTaskSchedulerPermittedIdentifiers`; `NSAllowsLocalNetworking`; and Bonjour `_remotepairing._tcp` / `_remotepairing-pairable-host._tcp`.
- **Dependencies** are pinned. PiDurableKit uses revision `6e7f2671…` (SwiftPM) and swift-markdown is exactly 0.9.0 (Xcode project only). `Package.resolved`, `Cargo.lock` and firmware `dependencies.lock` are committed. See `docs/dependencies.md`.
- **Environment variables**: `EISCUE_TEST_MODEL_URL` (UI-test model fixture), `EISCUE_RUST_TOOLCHAIN` (default `1.96.0`), `IDF_PATH` / `IDF_TOOLS_PATH` (ESP-IDF 5.5.3), `BOARD_SANITIZERS` and `CC` (firmware host tests).
- **Runtime data**: Everything lives in the app sandbox under `Application Support/Eiscue/`: `conversations.json`, `Runtime/` (per-conversation Pi SQLite), `Runs/` (task journal), `Skills/` (imported), and `Attachments/`. Built-in skills are `Apps/Eiscue/Resources/Skills/*.md`. Deleting a conversation removes its runtime files and journal; deleting the API key keeps conversations. Preferences such as `deviceConnectionMethod`, `deviceControlBackend`, `bluetoothInputRoute`, `allowsDeviceControl`, `disconnectAfterTask`, `appearance`, `modelProfiles` (profile list and selection; no keys), the legacy `modelSettings` projection and `onboardingVersion` are stored in UserDefaults. Only `Runs/` and the ReplayKit frame cache set `isExcludedFromBackup`; conversations, attachments and the screenshot-bearing Pi SQLite are included in device backups.
- **Local tunnel** addresses are fixed: local `10.7.1.1/24`, peer `10.7.0.1/32`, host route only, no default route or DNS. The USB NCM board is `192.168.7.1/24` and the phone uses a manual `.2`.
- **Build artifacts**: `.build/` is gitignored and holds research checkouts, backend/firmware builds, test results, and private board backups.
