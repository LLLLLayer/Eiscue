# Eiscue

**English** | [简体中文](README.zh-CN.md)

An on-device agent assistant for **iPhone / iPad**, requiring **iOS / iPadOS 26.0** or later.

Conversations, task orchestration and tool execution run on the phone. Models are accessed through a user-configured HTTPS service. Alongside chat, Eiscue can observe and operate the device when the user allows it.

> Development preview (`0.1.0`), installed through Xcode with development signing. No App Store or TestFlight release is available yet. Internal design documents and full acceptance records are not published with the repository; public build, firmware and provenance instructions are linked below.

## Features

- **Chat and multiple models**: OpenAI Chat Completions, OpenAI Responses and Anthropic Messages. Save multiple service/model configurations and switch from the conversation header. New configurations use their model IDs as display names, without a separate name field. Each configuration keeps its own API key in Keychain.
- **Device control**: the model uses screenshots to decide where to tap, swipe or type; each action automatically returns a new screenshot for verification. New installations of the full app default to **In-app connection (local VPN)**, which needs initial pairing: computer USB pairing on iOS 26, or system pairing on iOS 27+. The optional **Bluetooth board + system screen sharing** route only needs board power and does not occupy the phone's Wi-Fi or VPN connection. Saved supported route choices are retained.
- **Language**: follows the system by default. Open Settings → App language to select English or Simplified Chinese in iOS settings.
- **Attachments and speech**: photos, camera capture, text/code files, PDFs with extractable text and on-device dictation through Apple Speech, with no speech API key required. Tap to start/finish, or hold to talk; recognized text returns to the draft for editing. A gray backdrop extends behind the navigation bar and glass composer during recording; the waveform shows the measured microphone level without moving the composer. Switching to voice mode keeps the device connection. On iOS 27+, starting a recording temporarily releases an active CoreDevice connection after permission is granted; capture starts only after confirmed release. Control is restored afterward, keeping pairing and VPN. The voice button returns immediately when transcription finishes; device reconnection has a separate status that can be cancelled. Sending waits until reconnection or cancellation cleanup finishes. Other backends are unaffected. Connection failures show a notice and preserve the draft.
- **Conversation management**: streaming responses, Markdown, tool progress and sharing. Long-press a text message to select its full text and open the system editing menu directly; drag the selection handles to adjust the range. Images and files retain their long-press sharing menu. Sidebar rows show their last update time and support pinning, reordering and renaming. Long-press a conversation to enter multi-selection for bulk actions; wide iPad windows can keep the sidebar visible. Deleting a conversation also deletes its task records. The conversation menu opens task records for the current chat. Swipe right to open and left to close the sidebar. Task details combine steps and logs in one timeline. Full-screen screenshots support pinch/double-tap zoom and swipe in any direction to close when not zoomed in; short drags spring back.
- **Tasks and background execution**: stop, explicit continuation after a pause and redacted reports. Task details show saved input/output, screenshots and tap/swipe positions when the matching image is available. Connections stay open after normal task completion by default; disconnect manually on the device page or enable **Disconnect after tasks** in Settings. Changing apps alone does not disconnect, but this does not guarantee that iOS or the network will keep an idle session alive. An iOS 26 system Live Activity shows the current phase and final result; its ring stays nearly empty during execution, and iOS controls dismissal after the task ends. If the system activity receives the result, no duplicate notification is sent. Otherwise, optional completion/interruption notifications can be used; they are off by default.
- **Interface and extensions**: native Liquid Glass, light/dark appearance, English and Simplified Chinese, and imported UTF-8 Markdown skills. Settings use labeled sections. Three [vector head designs](Artwork/EiscueHeads/README.md) include blinking, looking and cube turns with changing face geometry; disconnected heads slowly turn with closed eyes. The chat welcome keeps its static illustration; the device button and device page use animated expressions for connection status. Animations respect Reduce Motion. Screen preview and repeat input checks for every connection route appear only in the device page's Debug section. The Debug toggle in Settings defaults on in Debug builds and remembers an off choice; Release builds contain neither the toggle nor these diagnostic entries. Required HID calibration remains available until completed in every build. The supported C3 board with an ST7789 display can also show expressions, task phases and completed step counts.

## Validation status

| Capability | Status |
| --- | --- |
| Chat, multiple models, streaming, Markdown, attachments, on-device dictation and English/Chinese UI | Implemented with simulator test coverage; dated results and remaining hardware checks are listed below |
| C3 / S3 Bluetooth connection, ReplayKit, four-point touch and Chinese text checks | Passed on the designated iPhone 14 Pro / iOS 26.5.2; C3 also passed repeated manual-start checks on iPhone 12 mini / iOS 27 (2026-10-18) |
| In-app connection, iOS 26 + XCTest | Deterministic checks in Eiscue's own test page passed on iPhone 14 Pro / iOS 26.5.2 (2026-10-13): two connection cycles, taps, swipe, Unicode text, stale-frame rejection after rotation, and short background screenshots |
| In-app connection, iOS 27 | On iPhone 12 mini (2026-10-18), XCTest's owned-page full check passed. CoreDevice has individual full passes but recurring rotation/input failures; one real-model Calculator task passed, while broader stability and task coverage remain open |
| Bluetooth swipe, broader cross-app agent coverage and model-driven long background runs | Integrated in code; **not yet accepted on real hardware** |
| S3 USB input: commands over Bluetooth, keyboard/mouse output over USB | App and firmware integrated; phone-side USB input **has not passed acceptance** |
| S3 USB network adapter | Firmware builds and host tests pass; **no hardware acceptance** |
| Other backends, including iCTRL | Source research only; not integrated |

**Code integration, software tests and real-device acceptance are recorded separately.** Simulators cannot validate Bluetooth HID, system screen sharing or background duration. Results from one test device do not establish compatibility with other models or OS versions.

## Quick start

### Run and configure

1. Use an Apple Silicon Mac, Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45+. Run `xcodegen generate` at the repository root, open `Eiscue.xcodeproj` and select the `Eiscue` scheme.
2. Keep the default local signing when running on an iOS 26+ simulator; Keychain is unavailable in unsigned builds. For a real device, set your development team and bundle IDs in `project.yml`, then regenerate the project. The app and broadcast extension share an App Group; the app and local-VPN extension require the Network Extension `packet-tunnel-provider` capability. The defaults are `org.eiscue.app` and `group.org.eiscue.app`. When changing them, update the suffixes, extensions and shared-group configuration together; see [AGENTS.md](AGENTS.md).
3. Enter a service URL, model ID and API key during onboarding or under **Settings → Model**. You can save multiple configurations. Existing keys appear as saved; choose **Replace** to change one. Saving a configuration does not call the model.

Model service URLs must use HTTPS. OpenAI-compatible services usually include `/v1`; Anthropic uses `https://api.anthropic.com`. Device tasks also require image and tool-call support from the model. Plain chat requires neither a board nor screen sharing.

### HID-only build

Select the `EiscueHID` scheme for a separate app containing only ESP32 BLE / USB HID with ReplayKit. It defaults to ESP32 input, uses `org.eiscue.hid` and `group.org.eiscue.hid`, and embeds only its own broadcast extension. Its package graph and compiled artifacts exclude the developer-services backend, XCTest bridge and VPN extension; choosing Bluetooth in the full `Eiscue` app does not remove those components. Model settings, conversations and sharing permissions are separate between the two apps. An S3 authentication key enrolled by one app is not automatically available to the other; existing enrollment is never silently replaced. This build separation is not an App Store approval or a new artwork/license grant.

For another host app, depend on the `EiscueHIDKit` product, `import EiscueDeviceCore`, and construct `let board = BluetoothDeviceController(); let client = DeviceClient(actuator: board, hidSetup: board)`. The full `EiscueDeviceKit` product keeps `DeviceClient()` and `DeviceClient(identityStore:)` compatible. Check the build boundary with `python3 Scripts/check-hid-boundary.py --app <path-to-EiscueHID.app>`.

### Let the AI operate the device

The default **In-app connection** route offers system pairing on iOS 27+, while retaining import of an existing compatible pairing file. Tap **Start pairing**, open **Settings → Privacy & Security → Developer Mode**, select Eiscue and confirm **Pair**, return to Eiscue for the code, then enter it in Settings. On iOS 26, setup uses five steps: prepare a Mac, connect the phone by USB, run the copyable command, import pairing, and connect the device. The command and requirements appear below. Choosing a route does not start it automatically.

System pairing completed on an iOS 27 device using a diagnostic build on 2026-10-14. That result does not establish the default publication configuration or screenshot/input acceptance. Developer Mode and a compatible prepared DDI remain separate requirements; this does not establish a fully computer-free setup.

To use the optional Bluetooth route:

1. Prepare the Bluetooth firmware using the [C3 / S3 firmware instructions](Firmware/Passport-BLE/README.md#build-and-flash-layout), then power the board.
2. On iPhone, enable **Settings → Accessibility → Touch → AssistiveTouch**.
3. Open the device page at the top right of Eiscue and select **ESP32 input**. On an S3, also choose **Bluetooth input** or **USB input**. Connect, start screen sharing in the system panel, then start the check. Keep the check page visible without touching or rotating the phone; the app verifies four actual touches and one text entry. Firmware with relative-drag support also runs six short movement checks. Swipe is offered only after those checks pass; older firmware or a failed movement check retains verified taps and typing.
4. Once ready, return to the conversation and give it a task. **Allow AI to operate device** is on by default and can be turned off on the device page. When the device is not ready, new messages use plain chat.

The connection, screen sharing and calibration must all remain valid. Disconnection, rotation, a change of sharing session or screen dimensions invalidates calibration and requires another check. Routes never fall back to one another automatically.

### Connection routes

| Route | Screen / input | Initial setup | Uses Eiscue's VPN connection |
| --- | --- | --- | --- |
| Bluetooth board (C3 / S3) | ReplayKit / BLE HID | Bluetooth pairing, AssistiveTouch, screen sharing and calibration; no computer-generated pairing file or DDI | No |
| S3 USB input | ReplayKit / USB HID; control commands still use Bluetooth | As above, plus a USB connection with the phone acting as host | No |
| In-app connection (default, local VPN) | Choose DisplayService or XCTest | USB identity setup on iOS 26 or system pairing on iOS 27+, plus developer environment / DDI | Yes |
| S3 USB network adapter | As above, through a USB NCM relay | As above, plus a USB host connection and network adapter configuration | No |

**Control method** is separate from the connection route and pairing. In-app and USB network connections offer **DisplayService (CoreDevice)** and **XCTest**. The initial selection is XCTest on iOS 26 and DisplayService on iOS 27+; existing Automatic preferences display their resolved method. DisplayService remains visible but disabled on iOS 26 with “Requires iOS 27 or later”; updating Eiscue alone cannot enable it. Selecting the current method retains the session. Switching to a different method releases the current connection, keeps the pairing identity, and requires reconnecting; there is no automatic fallback. Dated checks and remaining limits are listed under [Physical-device notes](#physical-device-notes).

The former C3 Wi-Fi hotspot relay has been removed. An old saved selection resets to the default In-app connection without starting it; choose and connect a supported route explicitly.

**USB input and the USB network adapter are separate routes.** S3 USB input uses the board's native USB / OTG port. USB-C phones use a C-to-C data cable; Lightning phones require a powered USB host (camera) adapter, not a regular Lightning data cable. The COM / UART port is for computer flashing and logs. Phone, cable and adapter combinations still need real-device validation.

For developer-services setup, see the [USB pairing tool](Scripts/pair-device-usb.md). Routine tasks run on the phone, but these routes depend on DDI developer frameworks and private interfaces, with no App Store distribution commitment. Bluetooth and S3 USB input do not require this pairing workflow.

Onboarding and the device page show setup steps inline, with no separate help page. A saved pairing identity is checked when connecting; it does not by itself mean device control is ready. Uninstalling may leave the identity in Keychain and the system VPN configuration in place. **Settings → Connection repair → Reset pairing** removes only Eiscue's pairing identity, retaining model settings and keys. Disconnect first, then confirm the reset; removing Eiscue's VPN configuration is a separate action in iOS Settings.

The **Copy command** button includes downloading the source before running the pairing helper. Paste the entire command into Mac Terminal from **any folder**; it creates a new temporary checkout without touching existing folders:

```sh
eiscue_setup_dir="$(mktemp -d -t eiscue-setup)" &&
git clone --depth 1 https://github.com/LLLLLayer/Eiscue.git "$eiscue_setup_dir" &&
python3 "$eiscue_setup_dir/Scripts/setup-device.py"
```

The Mac needs Xcode 26+, Python 3.9+, Rust 1.96.0 and internet access. Device trust, Developer Mode and Xcode device preparation are still required; the command does not install these tools or prepare DDI. It asks you to select and confirm a USB-connected device, then generates and transfers its pairing identity to the installed Eiscue app. It does not replace a pending transfer, import the identity or start a VPN. The app detects the received file on the same page; choose **Import from computer**, then **Connect** (**Connect device** during onboarding). The source and build cache remain in the Mac's temporary folder; the helper deletes its separate private pairing file after sending. Initial compilation may download pinned Cargo dependencies.

With an existing checkout, contributors can instead run `python3 Scripts/setup-device.py` from its project folder. The convenience helper is macOS-only; the lower-level pairing tool remains separate.

The C3 companion display shows only fixed phases, expressions and step counts, not model-generated text. A short press of OK latches a stop. To unlock, release OK, hold it for about 1.5 seconds, then disconnect; reconnection and calibration are required afterward.

## Architecture

```text
Eiscue App (SwiftUI, iOS 26+)
├── Conversations, model settings, attachments, speech, skills, run journal, background execution
├── RunCoordinator / RunSession: per-run engine, device ownership, cleanup and awaited completion
├── DeviceSession / DictationSession: connection state, ownership and recording handoff
├── DeviceToolSpec / DeviceToolSession: shared tool catalog → DeviceDecision
├── DeviceTaskRunner: permissions, budgets, serialized execution, post-action observation
├── EiscueAgentKit: agent / tool / event protocols, with an internal PiDurableKit adapter
└── EiscueDeviceCore: DeviceActuator, GuardedDevice, injected DeviceClient, BLE / USB HID + ReplayKit
    ├── EiscueHIDKit product: Core only
    └── EiscueDeviceKit facade: Core + developer services / default client

Extensions: EiscueBroadcast (screen sharing), EiscueTunnel (local-VPN route only)
Firmware: Passport-BLE (C3 / S3 HID), NCM-Relay (S3 USB network adapter)
```

The Agent and Device libraries have no dependency on one another. The two Device products share the Core module. The app integration layer connects them; there is no separate Plugin product.

| Kit | Responsibilities | Replacement interface |
| --- | --- | --- |
| [EiscueAgentKit](Sources/EiscueAgentKit/AgentClient.swift) | Agents, tools, events and conversation storage; internally runs PiDurableKit through JavaScriptCore, with one SQLite database per conversation | `AgentClient(engine:)`; custom Swift tools can also be registered |
| [EiscueDeviceKit](Sources/EiscueDeviceCore/DeviceClient.swift) | Connection, observation, actions and capability status | `DeviceClient(actuator:networkSetup:hidSetup:)` |

Apps integrating DeviceKit’s XCTest backend must include `/System/Developer/usr/lib` and `/Developer/usr/lib` in the device target’s `LD_RUNPATH_SEARCH_PATHS`, retaining inherited paths. Xcode 27’s developer image uses these paths for Testing interop dependencies. Eiscue configures this in `project.yml`; Apple’s test libraries are loaded from the mounted DDI and are not bundled.

Public APIs do not expose PiDurableKit or actell types. Contribution and maintenance rules are in [AGENTS.md](AGENTS.md).

## Build and test

Use the isolated wrapper below for Kit tests. It preserves the actual `Package.resolved` and staged state; a direct `swift test` can remove Xcode-only pins. Give each toolchain its own scratch directory. The [CI setup](Scripts/ci.md) explains the two self-hosted Xcode/iOS gates, required runners and local equivalent; committing the workflow does not provision runners or enforce branch protection.

Run from the repository root:

```sh
xcodegen generate

# Kit tests: explicit Xcode, isolated lockfile and build products
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 Scripts/test-swift-package.py --scratch-path .build/kit-xcode26

# App build
xcodebuild -project Eiscue.xcodeproj -scheme Eiscue \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 build

# App unit tests
xcodebuild -project Eiscue.xcodeproj -scheme Eiscue \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' \
  -only-testing:EiscueAppTests test
```

For the full app + UI suite, first start the local model server in another terminal. No API key is needed:

```sh
python3 Scripts/test-model-server.py
```

```sh
xcodebuild -project Eiscue.xcodeproj -scheme Eiscue \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' test
```

### Recorded test baseline

To retain a check's output without masking its exit status, run `bash Scripts/run-logged-check.sh .build/<unique-name>.log <command> [arguments...]`. Existing logs are preserved; a failed check still returns a nonzero exit code.

Architecture iteration on **2026-10-17**, using separate Xcode 26.3 / Swift 6.2.4 and Xcode 27 / Swift 6.4 builds. No physical device, board or real model was used in this round:

| Check | Result |
| --- | --- |
| Swift Kits | 209 passed on each toolchain |
| App unit tests, iOS 26.3.1 | 426 passed, 0 failed |
| App unit tests, iOS 27.0 | 425 passed, 1 platform-specific skip, 0 failed |
| Connection / onboarding / dictation / unknown-outcome UI, iOS 26.3.1 | 10 passed, 5 iOS 27-only skips, 0 failed |
| Same focused UI, iOS 27.0 | 15 passed; both systems repeated the 2 unknown-outcome cases after the final coordinator error-classification fix |
| Release app builds | Full and HID-only apps built with both Xcode versions; HID dependency graph and artifact boundary audits passed |
| HID app unit tests | 3 passed in this round; Release checks repeated after the final coordinator fix |
| Generated project | Regenerated without drift |

Successful commands return exit 0; skips are not passes. Logs and result bundles remain local under `.build/`. Current checks are focused UI coverage, not another full UI-suite run. At the preceding `c4fc538` baseline, full iPhone UI passed on both systems (iOS 26: 59 passed / 13 skipped; iOS 27: 63 passed / 9 skipped), and iPad sidebar/conversation/sharing checks had 10 passes / 1 layout skip. Those historical results do not certify later changes.

Broader hardware acceptance remains open for C3/S3 gestures and rotation, external connection loss, model-driven long background runs and broader agent tasks. The limited 2026-10-18 phone checks below cover bounded scripted scenarios and one real-model Calculator task. CI workflow and local gate scripts are committed; remote runners and branch protection require separate configuration. Earlier failures and intermediate runs remain in the local validation record.

### Physical-device notes

- **2026-10-18, iPhone 12 mini / iOS 27.0 (24A437), local VPN**: On the same app version and upright phone, XCTest's full check passed rotation rejection, fresh-frame input, swipe, Unicode, short background/return and two confirmed-release cycles, while CoreDevice's fresh landscape tap failed. This narrows the unresolved tap issue to the CoreDevice input path; its root cause and landscape acceptance remain open. The restored backend passed 79 Rust tests; Geometry tests passed eight cases on each Xcode 26.3/27. Clean full/HID Release builds and the HID boundary audit passed.
- **One real-model Calculator task, same phone and date**: CoreDevice completed 17×23=391, visually verified in Calculator, and returned automatically to Eiscue in about 106.5 seconds with no cleanup failure. It launched Eiscue directly, without Home; the earlier Home/verification failure remains recorded. This one A1 pass does not establish landscape stability, XCTest real-model acceptance or broader task coverage.
- **Bounded background and stop checks, same phone and date**: each backend completed one approximately ten-minute zero-model script through the normal host, with confirmed cleanup. Each also passed one stop during an actual swipe, retained an unknown work outcome and completed confirmed cleanup; the submitted touch still finished its original motion. Latest route-aware cleanup changes passed 80 focused App tests on each iOS 26.3.1 and iOS 27, preserving HID confirmation metadata and independent cleanup errors while keeping network release strict. These results do not cover real-model long background tasks, system cancellation, external connection loss or every stop/continuation path.

- **C3 BLE, same phone and date**: encrypted command/status channels, ReplayKit, and manually started four-point/Chinese-input checks passed. A calibration-page teardown bug that cleared a retained mapping was fixed and rechecked on the phone. The scripted moving swipe still failed its visible-scroll check; One normal tool-sequence completion retained BLE, sharing and calibration, while the swipe goal still failed. Relative-drag firmware and calibration changes are not yet hardware-accepted. Focused calibration and diagnostic regressions passed on both Xcode toolchains. No firmware was changed and no model API was called.
- **S3 HID, same phone and date**: separately authorized system-pairing repair and App control-key reset/enrollment for the 12 mini passed backup and production-image restoration checks, preserving other settings and C3. Authenticated BLE connection passed, including reconnection with the saved key after an App restart. Screen sharing and calibration are still incomplete, so the device is not ready for control; ReplayKit, actual gestures and USB input remain unaccepted. Zero model calls; earlier failures remain recorded.
- **iOS 27 microphone while controlled**: on iPhone 12 mini / iOS 27 (2026-10-15), microphone input was nonzero before a CoreDevice connection, all-zero with a system remote-control mute while connected, and nonzero again after confirmed screen-session release. Pairing and VPN stayed unchanged. Apple documents this conflict for [Device Hub](https://developer.apple.com/documentation/xcode/interacting-with-your-app-in-device-hub#Handle-camera-and-microphone-access-conflicts-on-physical-devices). On 2026-10-18, one hold/cancel check per backend recorded nonzero PCM, preserved the draft and restored the selected ready route. Both backends also passed one mode-switch/hold-to-finish lifecycle check each, with nonzero PCM and the selected connection restored or retained. An external XCTest runner was present; transcription and repeated-cycle stability remain unaccepted.
- **Sessions left by a terminated app**: after an app relaunch on the same phone, input stayed all-zero while iOS still reported remote-control muting. Pairing and VPN can be reused, but pairing alone cannot recover or release the previous process's screen session; a phone restart restored input. Automatic cleanup across app-process restarts is not implemented.
- **Settings → Connection repair → Reset connection & check** releases Eiscue's current control connection while keeping pairing, VPN and conversations, then briefly samples the microphone without speech recognition or saving audio. Connection release and microphone input are reported separately; neither proves that no earlier session remains.

### Backend and firmware

The device backend ships an XCFramework for arm64 iOS, simulator and macOS, without x86_64 slices. Rebuild only when backend source changes, using the pinned Rust 1.96.0 toolchain:

```sh
bash Scripts/build-device-backend.sh
CARGO_TARGET_DIR=.build/device-rust rustup run 1.96.0 cargo test --locked \
  --manifest-path Vendor/DeviceBackend/rust/Cargo.toml --lib
```

Firmware builds require ESP-IDF **v5.5.3** with `IDF_PATH` set:

```sh
bash Scripts/build-passport-ble.sh esp32c3  # or esp32s3
bash Scripts/test-board-auth.sh           # Host tests; no hardware needed
bash Scripts/test-board-companion.sh
```

Builds do not open serial ports or flash hardware. Flashing depends on the firmware:

- **C3 BLE**: follow the [partition layout instructions](Firmware/Passport-BLE/README.md#build-and-flash-layout) to back up the full flash and verify the existing layout first. When updating a board with the verified matching layout, write only the app partition at `0x20000` and preserve private configuration at `0xF000`. The general flashing tool currently has no C3 BLE profile.
- **S3 HID / relay firmware**: `board-firmware.py` supports `s3-hid` and `ncm`. Generate and verify the corresponding firmware package first. `flash` requires `--port` and `--package`; it backs up the entire flash before writing and verifying, without erasing the whole chip or writing eFuses. See `python3 Scripts/board-firmware.py --help` for arguments and each firmware README for its layout. Do not reuse the C3 partition table on S3.

## Permissions, data and privacy

Conversation storage uses a small manifest, one record per conversation and shared SHA-256 attachment blobs. Loading isolates corrupt conversations and reports their IDs; incomplete validation defers collection and preserves the original data. Run journals append numbered, checksummed events and generate terminal summaries; legacy records remain readable. SQLite admission rebuilds submission caches, while host journals retain explicit abandonment of unsubmitted requests. Version 1 data migrates on the first write with an exact backup; the first explicit deletion retires that backup and reclaims unreferenced blobs. Interrupted deletion cleanup resumes on load or subsequent writes. Original documents remain available for byte-exact sharing. New runtime metadata references attachment content instead of copying it again; old SQLite entries are kept readable.

Model requests include only the two newest device screenshots; text/tool-call IDs and provider signatures remain intact, and user photos are unaffected. Full historical screenshots remain in the conversation SQLite for inspection until conversation deletion. `Runtime/` is excluded from device backups; conversations and original attachments retain their existing backup behavior. Run records include the system-instruction version.

- A task's permission scope is fixed when it starts; plain chat registers no tools. Device tools are exposed only for capabilities supported by the active backend. Actions are bound to the latest valid screenshot and consume it once. Unknown delivery stops execution and releases the connection. The conversation shows an unconfirmed action; continuing requires checking the screen, reconnecting and explicitly continuing, with no action retry button. Device continuations recheck permission and readiness; route switching stays unavailable until device-task cleanup ends.
- Lack of progress or reaching the step limit pauses the task. Choosing **Continue** starts a new request and observes again. Recovery after interruption is read-only and never resumes automatically. Imported skills are Markdown instructions only; they cannot expand permissions or execute scripts.
- Conversations, runtime SQLite databases, run journals, skills and attachments live in the app sandbox under `Application Support/Eiscue/`. API keys and pairing private keys stay in device-only Keychain items, never in UserDefaults, logs or exported reports.
- The ReplayKit extension keeps only the latest JPEG frame (longest side ≤ 1600 px) in a file-protected App Group, with no recording history or audio capture. **Both observation tools and automatic post-action observation return screenshots to the model**; starting screen sharing or opening a manual preview does not upload frames. Tool history may persist screenshots in the conversation's SQLite database, which is removed when that conversation is deleted.
- Owned XCTest types through a redacted native Unicode event without accessing the clipboard. CoreDevice and ESP32 HID text input overwrite the clipboard and paste, without reading its previous contents. Attachments are copied to private storage; images are re-encoded to remove EXIF and sent to the model only when the message is sent. Speech is recognized on-device, and audio is not written to disk.
- Exported reports contain only allowed metadata and tool status, excluding keys, pairing data, raw screenshots and full input arguments. Deleting an API key does not delete conversations.

Background device tasks request continued execution through `BGContinuedProcessingTask`; the system may cancel or end them. Bluetooth, ReplayKit, VPN and a visible Live Activity do not themselves guarantee background execution time. AX accessibility trees, PiP and Mac / Android / HarmonyOS backends remain future directions.

## Licenses and provenance

Eiscue as a whole does not yet have a unified distribution license. The table below records the licenses and provenance of individual components:

| Component | Source / license |
| --- | --- |
| [DeviceBackend](Vendor/DeviceBackend/README.md) | Pinned actell commit, GPL-3.0-only; includes MIT-licensed idevice. The full `Eiscue` app links this backend; choosing Bluetooth does not remove it. The separate `EiscueHID` build does not link it |
| [LocalTunnel](Vendor/LocalTunnel/README.md) | Derived from LocalDevVPN / StosVPN, under the custom StosVPN License; see attribution in the directory |
| [Passport-BLE](Firmware/Passport-BLE/README.md#license-and-api-references) | Original firmware source is Apache-2.0; dependency notices are in the firmware directory. The firmware source license does not grant the same license to the [expression artwork](Firmware/Passport-BLE/Resources/README.md) |
| [NCM-Relay](Firmware/NCM-Relay/README.md) | The upstream combined project declares GPL-3.0-only; local files have GPL-3.0-or-later headers. See its `SOURCE_MANIFEST.json` |
| PiDurableKit | Pinned commit, CC0-1.0; embedded JS dependencies have separate notices |
| swift-markdown / swift-cmark | Pinned to 0.9.0; full license texts are included in the [app resources](Apps/Eiscue/Resources/OpenSourceLicenses) |

See [Package.swift](Package.swift) and [project.yml](project.yml) for dependency versions.
