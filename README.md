# Eiscue

**English** | [简体中文](README.zh-CN.md)

An on-device agent assistant for **iPhone / iPad**, requiring **iOS / iPadOS 26.0** or later.

Conversations, task orchestration and tool execution run on the phone; models are reached through a user-configured HTTPS service. When the user allows it, the agent can also look at the screen and operate the device, including other apps.

> Development preview (`0.1.0`), installed through Xcode with development signing. There is no App Store or TestFlight release. Internal design documents and full acceptance records are not published with the repository; public build, firmware and provenance instructions are linked below.

## How it works

A device task is a loop that runs on the phone:

1. The model receives the task and the current screenshot, then calls a device tool (tap, swipe, type text, press Home, launch an app…) with screenshot-pixel coordinates and that screenshot's `frameID`.
2. Eiscue checks that the frame is the newest one, still fresh, and matches the current orientation, size and session. It then converts the coordinates and sends the input. Each screenshot authorizes one action only.
3. Eiscue captures a new screenshot and returns it in the same tool result. The model checks the result on screen and decides the next step.

If delivery of an action is uncertain, the task stops instead of retrying. A command acknowledgement is never treated as success.

iOS gives apps no public API to operate other apps, so control goes through one of the routes below. A route never falls back to another one.

| Route | Screen / input | Initial setup | Extra hardware |
| --- | --- | --- | --- |
| **In app** (default, local VPN) | Developer services over Eiscue's loopback VPN; choose **DisplayService** (iOS 27+) or **XCTest** | Developer Mode, pairing (Mac + USB on iOS 26, system pairing on iOS 27+), developer disk image (DDI) | None; occupies the VPN slot |
| **S3 USB network** | The same developer services through an ESP32-S3 USB network relay | As above, plus relay firmware and a manual IPv4 address on the phone | ESP32-S3 board; no VPN |
| **ESP32 input**, Bluetooth (C3 / S3) | ReplayKit screen sharing / Bluetooth mouse and keyboard (HID) | Bluetooth pairing, AssistiveTouch, screen sharing and an on-screen calibration | ESP32-C3 or S3 board; no VPN, pairing file or DDI |
| **ESP32 input**, USB (S3) | ReplayKit / USB mouse and keyboard; commands still go over Bluetooth | As above, plus a USB host connection from the phone to the board | ESP32-S3 board |

Developer-services routes rely on private interfaces and the developer disk image, with no App Store distribution commitment. HID routes use only public features on the phone, but cannot press Home, list apps or launch apps by bundle ID; they navigate through visible controls such as the AssistiveTouch menu.

## Features

- **Chat and models**: OpenAI Chat Completions, OpenAI Responses and Anthropic Messages. Save several service/model configurations, each with its own API key in Keychain, and switch from the conversation header. Plain chat needs neither a board nor screen sharing.
- **Device control**: tools are registered only for capabilities the connected route actually supports. **Allow AI to operate device** is on by default on the device page; while the device is not ready, new messages are plain chat. A task's permission scope is fixed when it starts.
- **Tasks**: stop, explicit continuation after a pause, and redacted reports. Task details show one timeline of steps and logs, screenshots with tap/swipe positions, and provider-reported input/output/cache token usage. Missing counts stay unknown, interrupted totals are marked partial, and no cost is estimated. The connection stays open after a normal task unless **Settings → Disconnect after tasks** is enabled.
- **Background execution**: device tasks request iOS 26 `BGContinuedProcessingTask`. Its system Live Activity shows the current phase; the ring advances only on completed steps over a fixed scale, so it stays nearly empty until the task ends. iOS may end background work early and controls dismissal ([API](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask), [WWDC25](https://developer.apple.com/videos/play/wwdc2025/227/)). Optional **Task notifications** (off by default) are sent only when the system activity did not receive the result.
- **Attachments and dictation**: photos, camera capture, text/code files and PDFs with extractable text. On-device Apple Speech dictation needs no speech API key; tap to start/finish or hold to talk, and recognized text returns to the draft. On iOS 27+, an active DisplayService connection mutes the microphone ([Apple](https://developer.apple.com/documentation/xcode/interacting-with-your-app-in-device-hub#Handle-camera-and-microphone-access-conflicts-on-physical-devices)), so starting a recording temporarily releases control after permission is granted and restores it afterward, keeping pairing and VPN. Restoration has its own cancellable status; a failure keeps the draft.
- **Conversations**: streaming Markdown, tool progress and sharing. Long-press text to select it; pin, reorder, rename and multi-select conversations in the sidebar (swipe right to open, left to close); wide iPad windows keep the sidebar visible. Full-screen screenshots support pinch and double-tap zoom.
- **Interface**: native Liquid Glass, light/dark appearance, and English or Simplified Chinese (follows the system; **Settings → App language** opens the per-app setting). Imported UTF-8 Markdown skills. Animated [vector head designs](Artwork/EiscueHeads/README.md) show connection status and respect Reduce Motion. A supported C3 board with an ST7789 display shows expressions, task phases and step counts. Debug builds add screen previews and repeat-input checks under the device page's **Debug** section; Release builds omit them.

## Status

As of 2026-10-21. Code integration, software tests and real-device acceptance are recorded separately. Real-device results come from one or two test phones (mostly iPhone 12 mini / iOS 27) and are mostly single bounded runs; they do not establish compatibility with other models, OS versions or repeated use. Simulators cannot validate Bluetooth HID, screen sharing, background duration or developer-service control.

| Capability | Status |
| --- | --- |
| Chat, models, attachments, dictation, UI | Implemented; full Kit and App unit suites pass on iOS 26 and 27 simulators |
| In app + XCTest | Owned-page checks passed on iPhone 14 Pro / iOS 26.5.2 and iPhone 12 mini / iOS 27: taps, swipe, Unicode text, stale-frame rejection after rotation, short background. On the 12 mini, also a ten-minute background script, a stop during a swipe and one real-model Calculator task |
| In app + DisplayService (iOS 27) | The same 12 mini scope, but **fresh landscape taps fail intermittently**; the root cause is open |
| Recovery after VPN loss, explicit continuation | One same-process pass per control method: no automatic recovery, an explicit reconnect reaches Ready, and continuing after a stopped action takes a fresh screenshot without replaying the action. Input in the reconnected process is not yet verified |
| Dictation handoff | Finish, cancel, switch-to-keyboard, navigation and background lifecycle checks passed once per control method with nonzero audio; one user-reported transcription on DisplayService |
| S3 Bluetooth / USB input | One portrait owned-page pass each for taps, Chinese text and swipe, plus a stop during a swipe. USB passed a one-minute background screenshot run; **Bluetooth background expired after about one second** |
| S3 USB network | One foreground swipe per control method; DisplayService stop and a one-minute background observation |
| C3 Bluetooth input | Taps, Chinese text and screen sharing; **swipe not accepted** |
| Broader cross-app tasks, long real-model background runs, lock screen, system cancellation | Not yet accepted |
| Releasing a screen session left by a terminated app process | **Not implemented** |
| Other backends (iCTRL, element trees, on-device OCR) | Research only |

### Known limitations

- **Sessions left by a terminated app**: if Eiscue exits while DisplayService control is active, a relaunched app cannot release the old screen session, and microphone input stays muted until the phone restarts. Pairing and VPN remain usable. Within one app process, Eiscue keeps ownership across VPN loss, and **Settings → Connection repair → Reset connection & check** can release it. That check releases control, keeps pairing, VPN and conversations, and briefly samples the microphone without recognition or saving audio. If release stays unconfirmed, keep Eiscue in the foreground and check again; restart the phone only if control is disconnected and the microphone still fails.
- **No automatic retry or fallback**: an action with unknown delivery stops the task and releases the connection. The conversation shows an unconfirmed action; check the screen, reconnect and continue explicitly. Stopping cannot recall a touch that was already sent.
- **Background time** comes only from iOS. VPN, Bluetooth, ReplayKit and the Live Activity do not extend it.
- **Text input** through DisplayService and HID overwrites the clipboard and pastes, without reading its previous contents. XCTest types without the clipboard.
- **Board trust boundary**: C3 accepts commands from any encrypted, bonded Bluetooth connection; unlike S3, it has no per-connection application authentication. S3 first-time key enrollment is limited to the board's first 60 seconds of power and uses Just Works pairing without MITM protection. Use the boards only with phones and surroundings you trust.
- **Unverified environments**: iPad, other iPhone models and OS builds, USB cable and adapter combinations, and coexistence with company VPNs.

## Quick start

### Run and configure

1. Use an Apple Silicon Mac, Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45+. Run `xcodegen generate` at the repository root, open `Eiscue.xcodeproj` and select the `Eiscue` scheme.
2. Keep the default local signing when running on an iOS 26+ simulator; Keychain is unavailable in unsigned builds. For a real device, set your development team and bundle IDs in `project.yml`, then regenerate the project. The app and broadcast extension share an App Group; the app and local-VPN extension require the Network Extension `packet-tunnel-provider` capability. The defaults are `org.eiscue.app` and `group.org.eiscue.app`. When changing them, update the suffixes, extensions and shared-group configuration together; see [AGENTS.md](AGENTS.md).
3. Enter a service URL, model ID and API key during onboarding or under **Settings → Model**. Existing keys appear as saved; choose **Replace** to change one. Saving a configuration does not call the model.

Model service URLs must use HTTPS. OpenAI-compatible services usually include `/v1`; Anthropic uses `https://api.anthropic.com`. Device tasks also require image and tool-call support from the model.

### HID-only build

Select the `EiscueHID` scheme for a separate app containing only ESP32 BLE / USB HID with ReplayKit. It defaults to ESP32 input, uses `org.eiscue.hid` and `group.org.eiscue.hid`, and embeds only its own broadcast extension. Its package graph and compiled artifacts exclude the developer-services backend, XCTest bridge and VPN extension; choosing Bluetooth in the full `Eiscue` app does not remove those components. Model settings, conversations and sharing permissions are separate between the two apps. An S3 authentication key enrolled by one app is not automatically available to the other; existing enrollment is never silently replaced. This build separation is not an App Store approval or a new artwork/license grant.

For another host app, depend on the `EiscueHIDKit` product, `import EiscueDeviceCore`, and construct `let board = BluetoothDeviceController(); let client = DeviceClient(actuator: board, hidSetup: board)`. The full `EiscueDeviceKit` product keeps `DeviceClient()` and `DeviceClient(identityStore:)` compatible. Check the build boundary with `python3 Scripts/check-hid-boundary.py --app <path-to-EiscueHID.app>`.

### Set up device control

Open the device page at the top right of Eiscue and choose a **Connection method**. Choosing a route does not connect it. Onboarding and the device page show the setup steps inline. A saved pairing identity is checked when connecting; it does not by itself mean device control is ready.

#### In app (local VPN)

Tapping **Connect** starts Eiscue's built-in VPN; iOS asks to add the VPN configuration the first time, and other VPNs cannot run at the same time.

- **iOS 27+**: tap **Start pairing**, open **Settings → Privacy & Security → Developer Mode**, select Eiscue and confirm **Pair**, then enter the code Eiscue shows. Importing an existing compatible pairing file is still available.
- **iOS 26**: setup has five steps: prepare a Mac, connect the phone by USB, run the copied command, import the pairing, and connect.

System pairing creates Eiscue's identity but does not prepare the developer disk image. Developer Mode and a compatible DDI remain separate requirements, so first-time setup is not fully computer-free.

On iOS 26, **Copy command** copies a command that downloads the source before running the pairing helper. Paste the entire command into Mac Terminal from **any folder**; it creates a new temporary checkout without touching existing folders:

```sh
eiscue_setup_dir="$(mktemp -d -t eiscue-setup)" &&
git clone --depth 1 https://github.com/LLLLLayer/Eiscue.git "$eiscue_setup_dir" &&
python3 "$eiscue_setup_dir/Scripts/setup-device.py" --app-pairing-schema 1
```

The Mac needs Xcode 26+, Python 3.9+, Rust 1.96.0 and internet access. Device trust, Developer Mode and Xcode device preparation are still required; the command does not install these tools or prepare DDI. It asks you to select and confirm a USB-connected device, then generates and transfers its pairing identity to the installed Eiscue app. It does not replace a pending transfer, import the identity or start a VPN. The helper negotiates the supported pairing schema and validates before sending; the v1 JSON/plist format remains compatible, and unknown versions are rejected at import. The app detects the received file on the same page; choose **Import from computer**, then **Connect** (**Connect device** during onboarding). The helper deletes its private pairing file after sending; initial compilation may download pinned Cargo dependencies. With an existing checkout, run `python3 Scripts/setup-device.py --app-pairing-schema 1` from the project folder. See the [USB pairing tool](Scripts/pair-device-usb.md) for the lower-level steps.

Uninstalling may leave the identity in Keychain and the system VPN configuration in place. **Settings → Connection repair → Reset pairing** removes only Eiscue's pairing identity, retaining model settings and keys; disconnect first, then confirm. Removing Eiscue's VPN configuration is a separate action in iOS Settings.

#### ESP32 input (Bluetooth / USB)

1. Prepare the firmware using the [C3 / S3 firmware instructions](Firmware/Passport-BLE/README.md#build-and-flash-layout), then power the board.
2. On iPhone, enable **Settings → Accessibility → Touch → AssistiveTouch**.
3. On the device page, select **ESP32 input**; on an S3, also choose **Bluetooth input** or **USB input**. Connect, start screen sharing in the system panel, then start the check. Keep the check page visible without touching or rotating the phone: the app verifies four actual touches and one text entry. Firmware with relative-drag support also runs six short movement checks; swipe is offered only after they pass, and older firmware or a failed movement check keeps verified taps and typing.
4. Return to the conversation and give it a task.

Connection, screen sharing and calibration must all remain valid. Disconnection, rotation, a new sharing session or a change in screen size invalidates calibration and requires another check.

**USB input** uses the board's native USB / OTG port. USB-C phones use a C-to-C data cable; Lightning phones need a powered USB host (camera) adapter, not a regular Lightning cable. The COM / UART port is for flashing and logs.

The C3 companion display shows only fixed phases, expressions and step counts, not model-generated text. A short press of OK latches a stop. To unlock, release OK, hold it for about 1.5 seconds, then disconnect; reconnection and calibration are required afterward.

#### S3 USB network

This is a separate route from USB input. Flash the [NCM relay firmware](Firmware/NCM-Relay/README.md), connect the board's native USB port to the phone, and in iOS Settings give the board's Ethernet interface a manual IPv4 address `192.168.7.2`, subnet `255.255.255.0`, with no router or DNS (the board is `192.168.7.1`). Pairing and the developer disk image are still required, as for **In app**. The connection is bound to the USB interface and never falls back to Wi-Fi or VPN.

#### Control method

**In app** and **S3 USB network** offer **DisplayService** (CoreDevice) and **XCTest** under **Control method**, independent of route and pairing. The initial selection is XCTest on iOS 26 and DisplayService on iOS 27+; an existing Automatic preference displays its resolved method. DisplayService stays visible but disabled on iOS 26 with “Requires iOS 27 or later”; updating Eiscue alone cannot enable it. Selecting the current method keeps the session. Switching releases the current connection, keeps the pairing identity and requires reconnecting; there is no automatic fallback.

The former C3 Wi-Fi hotspot relay has been removed. An old saved selection resets to **In app** without connecting.

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
Firmware: Passport-BLE (C3 / S3 HID), NCM-Relay (S3 USB network relay)
```

The Agent and Device libraries have no dependency on one another. The two Device products share the Core module. The app integration layer connects them; there is no separate Plugin product.

| Kit | Responsibilities | Replacement interface |
| --- | --- | --- |
| [EiscueAgentKit](Sources/EiscueAgentKit/AgentClient.swift) | Agents, tools, events and conversation storage; internally runs PiDurableKit through JavaScriptCore, with one SQLite database per conversation | `AgentClient(engine:)`; custom Swift tools can also be registered |
| [EiscueDeviceKit](Sources/EiscueDeviceCore/DeviceClient.swift) | Connection, observation, actions and capability status | `DeviceClient(actuator:networkSetup:hidSetup:)` |

Apps integrating DeviceKit's XCTest backend must include `/System/Developer/usr/lib` and `/Developer/usr/lib` in the device target's `LD_RUNPATH_SEARCH_PATHS`, retaining inherited paths. Xcode 27's developer image uses these paths for Testing interop dependencies. Eiscue configures this in `project.yml`; Apple's test libraries are loaded from the mounted DDI and are not bundled.

Public APIs do not expose PiDurableKit or actell types. Contribution and maintenance rules are in [AGENTS.md](AGENTS.md).

## Build and test

Use the isolated wrapper below for Kit tests. It preserves the actual `Package.resolved` and staged state; a direct `swift test` can remove Xcode-only pins. Give each toolchain its own scratch directory.

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

To keep a check's output without masking its exit status, run `bash Scripts/run-logged-check.sh .build/<unique-name>.log <command> [arguments...]`. Existing logs are preserved; a failed check still returns a nonzero exit code.

### Recorded test baseline

| Check | Latest full result |
| --- | --- |
| Swift Kits (2026-10-20) | 242 tests / 24 suites passed on each Xcode 26.3 / Swift 6.2.4 and Xcode 27 / Swift 6.4 toolchain |
| App unit tests (2026-10-20) | iOS 26: 501 passed; iOS 27: 500 passed, 1 platform-specific skip |
| Offline Python helpers (2026-10-20) | 23 passed |
| Release builds (2026-10-20) | HID-only Release build and boundary audit (Xcode 26); full Release build (Xcode 27) |
| Full iPhone UI suite (2026-10-17) | iOS 26.3.1: 59 passed / 13 skipped; iOS 27: 63 passed / 9 skipped; 0 failed |

Later changes ran focused suites only, such as connection, dictation and cleanup tests on both toolchains. Skips are not passes; logs and result bundles stay local under `.build/`.

The hosted Ubuntu workflow runs offline Python helpers on pushes to main, pull requests and manual dispatch. The Apple checks described in the [CI setup](Scripts/ci.md) require registered self-hosted Apple Silicon runners and `EISCUE_APPLE_RUNNERS_ENABLED=true`. No runners or branch protection are configured yet, so hosted helpers do not validate Swift or Apple builds.

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

- **C3 BLE**: follow the [partition layout instructions](Firmware/Passport-BLE/README.md#build-and-flash-layout) to back up the full flash and verify the existing layout first. When updating a board with the verified matching layout, write only the app partition at `0x20000` and preserve private configuration at `0xF000`. The general flashing tool has no C3 BLE profile.
- **S3 HID / relay firmware**: `board-firmware.py` supports `s3-hid` and `ncm`. Generate and verify the corresponding package first. `flash` requires `--port` and `--package`; it backs up the entire flash before writing and verifying, without erasing the whole chip or writing eFuses. The default `ncm` package uses a 4 MB layout: do not write it over a board flashed with the 16 MB S3 HID layout, and do not reuse the C3 partition table on S3. See `python3 Scripts/board-firmware.py --help` and each firmware README.

## Permissions, data and privacy

- A task's permission scope is fixed when it starts; plain chat registers no tools. Device tools are exposed only for capabilities the active backend supports. Device continuations recheck permission and readiness, and route switching stays unavailable until device-task cleanup ends.
- Lack of progress or reaching the step limit pauses the task; **Continue** starts a new request that observes again. Recovery after interruption is read-only and never resumes automatically. Imported skills are Markdown instructions only; they cannot expand permissions or execute scripts.
- **Both observation tools and automatic post-action observation send screenshots to the model**; starting screen sharing or opening a manual preview does not. Model requests keep only the two newest device screenshots, but full tool history, including screenshots, stays in the conversation's SQLite database until the conversation is deleted.
- The ReplayKit extension keeps only the latest JPEG frame (longest side ≤ 1600 px) in a file-protected App Group, with no recording history or audio capture.
- Conversations, runtime SQLite databases, run journals, skills and attachments live in the app sandbox under `Application Support/Eiscue/`. `Runtime/` and run journals are excluded from device backups. API keys and pairing private keys stay in device-only Keychain items, never in UserDefaults, logs or exported reports. Deleting an API key does not delete conversations.
- Conversation storage uses a small manifest, one record per conversation and shared SHA-256 attachment blobs. Loading isolates corrupt conversations; incomplete validation defers collection and preserves the original data. Run journals append numbered, checksummed events with a terminal summary. Version 1 data migrates on the first write with an exact backup, retired by the first explicit deletion.
- Attachments are copied to private storage; images are re-encoded to remove EXIF and sent to the model only when the message is sent. Speech is recognized on-device, and audio is not written to disk.
- Exported reports contain only allowed metadata and tool status, excluding keys, pairing data, raw screenshots and full input arguments.

AX accessibility trees, PiP and Mac / Android / HarmonyOS backends remain future directions.

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
