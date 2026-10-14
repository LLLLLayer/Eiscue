# Eiscue

**English** | [简体中文](README.zh-CN.md)

An on-device agent assistant for **iPhone / iPad**, requiring **iOS / iPadOS 26.0** or later.

Conversations, task orchestration and tool execution run on the phone. Models are accessed through a user-configured HTTPS service. Alongside chat, Eiscue can observe and operate the device when the user allows it.

> Development preview (`0.1.0`), installed through Xcode with development signing. No App Store or TestFlight release is available yet. Internal design documents and full acceptance records are not published with the repository; public build, firmware and provenance instructions are linked below.

## Features

- **Chat and multiple models**: OpenAI Chat Completions, OpenAI Responses and Anthropic Messages. Save multiple service/model configurations and switch from the conversation header. Each configuration keeps its own API key in Keychain.
- **Device control**: the model uses screenshots to decide where to tap, swipe or type; each action automatically returns a new screenshot for verification. New installations default to **In-app connection (local VPN)**, which needs initial computer pairing. The optional **Bluetooth board + system screen sharing** route only needs board power and does not occupy the phone's Wi-Fi or VPN connection. Saved supported route choices are retained.
- **Attachments and speech**: photos, camera capture, text/code files, PDFs with extractable text and on-device dictation through Apple Speech, with no speech API key required.
- **Conversation management**: streaming responses, Markdown, tool progress, copy and share. The sidebar supports pinning, reordering, renaming and bulk deletion; wide iPad windows can keep it visible.
- **Tasks and background execution**: stop, explicit continuation after a pause and redacted reports. Task details show saved input/output, screenshots and tap/swipe positions when the matching image is available. An iOS 26 system Live Activity shows the current task phase. Completion/interruption notifications are optional and off by default.
- **Interface and extensions**: native Liquid Glass, light/dark appearance, English and Simplified Chinese, and imported UTF-8 Markdown skills. Manual input diagnostics appear in a Debug-only section; required HID calibration remains available in every build. The supported C3 board with an ST7789 display can also show expressions, task phases and completed step counts.

## Validation status

| Capability | Status |
| --- | --- |
| Chat, multiple models, streaming, Markdown, attachments, on-device dictation and English/Chinese UI | Implemented with simulator test coverage; known failures are listed in the test baseline below |
| C3 / S3 Bluetooth connection, ReplayKit, four-point touch and Chinese text checks | Passed on the designated iPhone 14 Pro / iOS 26.5.2 |
| Bluetooth swipe, complete cross-app agent tasks and long background runs | Integrated in code; **not yet accepted on real hardware** |
| S3 USB input: commands over Bluetooth, keyboard/mouse output over USB | App and firmware integrated; phone-side USB input **has not passed acceptance** |
| Local VPN / USB network adapter | Integrated in code; route-specific real-device acceptance is still required |
| Other backends, including iCTRL | Source research only; not integrated |

**Code integration, software tests and real-device acceptance are recorded separately.** Simulators cannot validate Bluetooth HID, system screen sharing or background duration. Results from one test device do not establish compatibility with other models or OS versions.

## Quick start

### Run and configure

1. Use an Apple Silicon Mac, Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45+. Run `xcodegen generate` at the repository root, open `Eiscue.xcodeproj` and select the `Eiscue` scheme.
2. Keep the default local signing when running on an iOS 26+ simulator; Keychain is unavailable in unsigned builds. For a real device, set your development team and bundle IDs in `project.yml`, then regenerate the project. The app and broadcast extension share an App Group; the app and local-VPN extension require the Network Extension `packet-tunnel-provider` capability. The defaults are `org.eiscue.app` and `group.org.eiscue.app`. When changing them, update the suffixes, extensions and shared-group configuration together; see [AGENTS.md](AGENTS.md).
3. Enter a service URL, model ID and API key during onboarding or under **Settings → Models**. You can save multiple configurations. Existing keys appear as saved; choose **Replace** to change one. Saving a configuration does not call the model.

Model service URLs must use HTTPS. OpenAI-compatible services usually include `/v1`; Anthropic uses `https://api.anthropic.com`. Device tasks also require image and tool-call support from the model. Plain chat requires neither a board nor screen sharing.

### Let the AI operate the device

The default **In-app connection** route guides you through five steps: prepare a Mac, connect the phone by USB, run the copyable command, import pairing, and connect the device. The command and requirements appear below. Choosing a route does not start it automatically.

To use the optional Bluetooth route:

1. Prepare the Bluetooth firmware using the [C3 / S3 firmware instructions](Firmware/Passport-BLE/README.md#build-and-flash-layout), then power the board.
2. On iPhone, enable **Settings → Accessibility → Touch → AssistiveTouch**.
3. Open the device page at the top right of Eiscue and select **ESP32-C3 / S3 input**. Connect, start screen sharing in the system panel, then start the check. Keep the check page visible without touching or rotating the phone; the app verifies four actual touches and one text entry.
4. Once ready, return to the conversation and give it a task. **Allow AI to operate device** is on by default and can be turned off on the device page. When the device is not ready, new messages use plain chat.

The connection, screen sharing and calibration must all remain valid. Disconnection, rotation, a change of sharing session or screen dimensions invalidates calibration and requires another check. Routes never fall back to one another automatically.

### Connection routes

| Route | Screen / input | Initial setup | Uses Eiscue's VPN connection |
| --- | --- | --- | --- |
| Bluetooth board (C3 / S3) | ReplayKit / BLE HID | Bluetooth pairing, AssistiveTouch, screen sharing and calibration; no computer-generated pairing file or DDI | No |
| S3 USB input | ReplayKit / USB HID; control commands still use Bluetooth | As above, plus a USB connection with the phone acting as host | No |
| In-app connection (default, local VPN) | In-app XCTest screenshots and input on iOS 26 | Initial USB identity setup on a computer, developer environment / DDI | Yes |
| S3 USB network adapter | As above, through a USB NCM relay | As above, plus a USB host connection and network adapter configuration | No |

The former C3 Wi-Fi hotspot relay has been removed. An old saved selection resets to the default In-app connection without starting it; choose and connect a supported route explicitly.

**USB input and the USB network adapter are separate routes.** S3 USB input uses the board's native USB / OTG port. USB-C phones use a C-to-C data cable; Lightning phones require a powered USB host (camera) adapter, not a regular Lightning data cable. The COM / UART port is for computer flashing and logs. Phone, cable and adapter combinations still need real-device validation.

For developer-services setup, see the [USB pairing tool](Scripts/pair-device-usb.md). Routine tasks run on the phone, but these routes depend on DDI developer frameworks and private interfaces, with no App Store distribution commitment. Bluetooth and S3 USB input do not require this pairing workflow.

Onboarding and the device page show setup steps inline, with no separate help page. A saved pairing identity is checked when connecting; it does not by itself mean device control is ready. Uninstalling may leave the identity in Keychain and the system VPN configuration in place. **Pair again** removes only Eiscue's pairing identity, retaining model settings and keys; removing Eiscue's VPN configuration is a separate action in iOS Settings.

The **Copy command** button includes downloading the source before running the pairing helper. Paste the entire command into Mac Terminal from **any folder**; it creates a new temporary checkout without touching existing folders:

```sh
eiscue_setup_dir="$(mktemp -d -t eiscue-setup)" &&
git clone --depth 1 https://github.com/LLLLLayer/Eiscue.git "$eiscue_setup_dir" &&
python3 "$eiscue_setup_dir/Scripts/setup-device.py"
```

The Mac needs Xcode 26+, Python 3.9+, Rust 1.96.0 and internet access. Device trust, Developer Mode and Xcode device preparation are still required; the command does not install these tools or prepare DDI. It asks you to select and confirm a USB-connected device, then generates and transfers its pairing identity to the installed Eiscue app. It does not replace a pending transfer, import the identity or start a VPN. The app detects the received file on the same page; choose **Import from computer**, then **Connect device**. The source and build cache remain in the Mac's temporary folder; the helper deletes its separate private pairing file after sending. Initial compilation may download pinned Cargo dependencies.

With an existing checkout, contributors can instead run `python3 Scripts/setup-device.py` from its project folder. The convenience helper is macOS-only; the lower-level pairing tool remains separate.

The C3 companion display shows only fixed phases, expressions and step counts, not model-generated text. A short press of OK latches a stop. To unlock, release OK, hold it for about 1.5 seconds, then disconnect; reconnection and calibration are required afterward.

## Architecture

```text
Eiscue App (SwiftUI, iOS 26+)
├── Conversations, model settings, attachments, speech, skills, run journal, background execution
├── DeviceToolSession: model tool calls → DeviceDecision
├── DeviceTaskRunner: permissions, budgets, serialized execution, post-action observation
├── EiscueAgentKit: agent / tool / event protocols, with an internal PiDurableKit adapter
└── EiscueDeviceKit: DeviceController protocol
    ├── BluetoothDeviceController: BLE / USB HID + ReplayKit
    └── Developer services: RemotePairing → in-app XCTest screenshots and input on iOS 26

Extensions: EiscueBroadcast (screen sharing), EiscueTunnel (local-VPN route only)
Firmware: Passport-BLE (C3 / S3 HID), NCM-Relay (S3 USB network adapter)
```

The two Kits are independent Swift package libraries with no dependency on one another. The app integration layer connects them; there is no separate Plugin product.

| Kit | Responsibilities | Replacement interface |
| --- | --- | --- |
| [EiscueAgentKit](Sources/EiscueAgentKit/AgentClient.swift) | Agents, tools, events and conversation storage; internally runs PiDurableKit through JavaScriptCore, with one SQLite database per conversation | `AgentClient(engine:)`; custom Swift tools can also be registered |
| [EiscueDeviceKit](Sources/EiscueDeviceKit/DeviceClient.swift) | Connection, observation, actions and capability status | `DeviceClient(controller:)` |

Public APIs do not expose PiDurableKit or actell types. Contribution and maintenance rules are in [AGENTS.md](AGENTS.md).

## Build and test

**Preserve the lockfile's current state first.** SwiftPM may remove the Xcode-only swift-markdown / swift-cmark pins from `Package.resolved`. Record and preserve existing changes before running it, inspect the diff afterward and restore only changes caused by that run. Do not unconditionally restore the entire file.

Run from the repository root:

```sh
xcodegen generate

# Kit tests: local model fixtures, no real model calls
swift test

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

2026-10-14, commit `efb7703`, Xcode 26.3, iPhone 16e / iOS 26.3 simulator:

| Suite | Result |
| --- | --- |
| Swift Kits | 149 tests / 19 suites; 4 failing tests (10 issues) |
| App unit tests | 226 passed |
| UI tests | 44 tests: 34 passed, 5 skipped, 5 failed |
| Firmware host tests | Board authentication: 6 groups passed; C3 companion display: 5 groups passed. NCM relay host tests were not run in this round |
| Device backend | 64 Rust library tests and 332 ObjC automation bridge checks passed |

The 4 Kit failures and 2 UI failures were traced to outdated copy or view-hierarchy assertions. Another 3 sharing tests could not find the system panel identifier. Screenshots show that the panel opened, but **saving, dismissal and readback still need revalidation after the tests are fixed**; the screenshots do not establish that the complete sharing flow works. Skipped cases require real hardware or an iPad. The failing suites are not currently green gates. These tests were not rerun for this documentation update.

Later targeted checks on 2026-10-14 passed 4 Kit tests, 12 app tests and 10 UI cases (8 on iPhone, 2 on iPad). Coverage includes read-only tool-image recovery, screenshot details and previews, context menus, keyboard navigation, model parameter persistence and opening/dismissing/reopening native file sharing. Saving, readback and photo sharing were not rerun. These checks do not replace the full baseline or establish real-device control acceptance; failed intermediate runs are retained in the local validation record.

Hotspot-relay removal on 2026-10-14 additionally passed 21 Kit tests, 34 app tests, 3 device-page UI tests, 14 offline firmware-tool tests and 64 Rust library tests. All three native backend slices were rebuilt. These targeted checks do not replace the full baseline or validate physical USB/Bluetooth behavior.

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

- A task's permission scope is fixed when it starts; plain chat registers no tools. Device tools are exposed only for capabilities supported by the active backend. Actions are bound to the latest valid screenshot and consume it once. Commands are not automatically resent when delivery is uncertain.
- Lack of progress or reaching the step limit pauses the task. Choosing **Continue** starts a new request and observes again. Recovery after interruption is read-only and never resumes automatically. Imported skills are Markdown instructions only; they cannot expand permissions or execute scripts.
- Conversations, runtime SQLite databases, run journals, skills and attachments live in the app sandbox under `Application Support/Eiscue/`. API keys and pairing private keys stay in device-only Keychain items, never in UserDefaults, logs or exported reports.
- The ReplayKit extension keeps only the latest JPEG frame (longest side ≤ 1600 px) in a file-protected App Group, with no recording history or audio capture. **Both observation tools and automatic post-action observation return screenshots to the model**; starting screen sharing or opening a manual preview does not upload frames. Tool history may persist screenshots in the conversation's SQLite database, which is removed when that conversation is deleted.
- Text input overwrites the clipboard and pastes, without reading its previous contents. Attachments are copied to private storage; images are re-encoded to remove EXIF and sent to the model only when the message is sent. Speech is recognized on-device, and audio is not written to disk.
- Exported reports contain only allowed metadata and tool status, excluding keys, pairing data, raw screenshots and full input arguments. Deleting an API key does not delete conversations.

Background device tasks request continued execution through `BGContinuedProcessingTask`; the system may cancel or end them. Bluetooth, ReplayKit, VPN and a visible Live Activity do not themselves guarantee background execution time. AX accessibility trees, PiP and Mac / Android / HarmonyOS backends remain future directions.

## Licenses and provenance

Eiscue as a whole does not yet have a unified distribution license. The table below records the licenses and provenance of individual components:

| Component | Source / license |
| --- | --- |
| [DeviceBackend](Vendor/DeviceBackend/README.md) | Pinned actell commit, GPL-3.0-only; includes MIT-licensed idevice. The app always links this backend; choosing Bluetooth does not remove it from the binary |
| [LocalTunnel](Vendor/LocalTunnel/README.md) | Derived from LocalDevVPN / StosVPN, under the custom StosVPN License; see attribution in the directory |
| [Passport-BLE](Firmware/Passport-BLE/README.md#license-and-api-references) | Original firmware source is Apache-2.0; dependency notices are in the firmware directory. The firmware source license does not grant the same license to the [expression artwork](Firmware/Passport-BLE/Resources/README.md) |
| [NCM-Relay](Firmware/NCM-Relay/README.md) | The upstream combined project declares GPL-3.0-only; local files have GPL-3.0-or-later headers. See its `SOURCE_MANIFEST.json` |
| PiDurableKit | Pinned commit, CC0-1.0; embedded JS dependencies have separate notices |
| swift-markdown / swift-cmark | Pinned to 0.9.0; full license texts are included in the [app resources](Apps/Eiscue/Resources/OpenSourceLicenses) |

See [Package.swift](Package.swift) and [project.yml](project.yml) for dependency versions.
