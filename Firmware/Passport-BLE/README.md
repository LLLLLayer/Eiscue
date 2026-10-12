# ESP32-C3 Bluetooth Board Firmware

Original ESP32-C3 firmware, version **0.2.0**, built with ESP-IDF **5.5.3**.
No Pilot or other undeclared-license implementation was copied. The peripheral
uses the official ESP-IDF NimBLE APIs and standard HID Usage Tables. Its purpose
is to test encrypted App commands and actual iPhone keyboard/mouse effects while
the phone keeps its normal Wi-Fi connection. It does not capture the screen,
implement an Agent, or prove that iOS recognizes the HID service merely by
returning a command acknowledgement.

Version 0.2 adds absolute pointer reports and restricted keyboard shortcuts for
the App's Bluetooth board route. The earlier version's Debug input checks are
recorded below; they do **not** validate the new coordinate path. Firmware build
success, a subscribed HID report, and an input acknowledgement do not establish
accurate screen coordinates. The App must observe calibration touches before
enabling coordinate actions. Other board layouts and phone / OS combinations
require separate validation.

## Build and Flash layout

```sh
export IDF_PATH=/path/to/esp-idf-v5.5.3
export IDF_TOOLS_PATH=/path/to/espressif-tools
bash Scripts/build-passport-ble.sh
```

Output is `.build/passport-ble-firmware/eiscue_passport_ble.bin`. Build never
opens serial or flashes. The partition table matches the existing
`Firmware/Passport-Relay/partitions.csv`: NVS at `0x9000`, PHY at `0xE000`, private
configuration at `0xF000`, and the 2 MB application at **`0x20000`**. Switching
these two experiment images should write **only the application** after reading
and checking the actual board/partition layout. Do not write an unverified
bootloader/table or erase private configuration.

The original full-Flash backup and the existing Wi-Fi firmware must be retained.
BLE bonds are stored in NimBLE's NVS namespace; startup does not erase NVS on an
error. No Wi-Fi, display, microphone or other product BSP feature is started.
No physical-device validation is implied by the build.

## BLE services

Advertising name: **Eiscue BLE**. Advertising includes HID `1812` and the custom
128-bit service; the full name is in the scan response. There is one peripheral
connection, shared by HID and the command service.

| Attribute | UUID |
| --- | --- |
| Service | `74074E9A-41E8-4E84-951D-70E623643AB3` |
| Command (write with response) | `74074E9A-41E8-4E84-951D-70E623643AB4` |
| Response (read/notify) | `74074E9A-41E8-4E84-951D-70E623643AB5` |

HID service `1812` contains HID Information, Report Map, Control Point, Protocol
Mode, three Input Report characteristics and their Report Reference descriptors,
plus boot mouse/keyboard input characteristics and boot keyboard LED output.
Report ID **1** is the 4-byte relative mouse report; report ID **2** is the 8-byte
US keyboard report. Report ID **3** is a 5-byte absolute mouse report: one left
button byte followed by X and Y, both UInt16 LE in `0...32767`. Its HID usages are
Generic Desktop Mouse / Pointer with absolute X/Y; it is unavailable in boot
protocol mode. HOGP notifications do not prefix the report ID: the Report
Reference descriptor identifies each characteristic. Device Information `180A`
has an experimental PnP identity rather than claiming a registered product.
Battery Service `180F` / Battery Level `2A19` is present for mandatory HOGP
structure. It reports **fixed 100 as a USB-powered laboratory test value**;
the board's fuel gauge is not initialized, and this is **not measured battery
SOC**. The App must not display it as the product's battery percentage.

The board requests encrypted Just Works bonding when connected. Command writes
require ATT encryption **and** the current connection's encrypted/bonded state.
HID reports use the same connection and the same checks. Pairing keys persist;
repeat pairing does not automatically remove an existing bond. Bond-store
overflow fails closed instead of evicting the authorized peer. This prototype
does not provide passkey/MITM authentication or an end-user bond-reset UI.

## Fixed command protocol

Each command is exactly **16 bytes**:

| Bytes | Value |
| --- | --- |
| 0 | Version `1` |
| 1 | Opcode |
| 2–3 | Request ID, little-endian UInt16 |
| 4–15 | Opcode payload, all unused bytes zero |

| Opcode | Payload |
| --- | --- |
| `00` STOP | All zeros. Cancel pending timers and release all subscribed report and boot input channels. Absolute release preserves the last X/Y. Also serves as encrypted GATT handshake. |
| `01` MOVE | Bytes 4–5: relative dx Int16 LE; 6–7: relative dy Int16 LE; byte 8: signed wheel Int8. Each component must be in `−127...127`. |
| `02` CLICK | Byte 4: `1` left / `2` right / `4` middle; byte 5: `1` click. Automatic release after 25 ms. |
| `03` ASCII | Byte 4: one US ASCII character. Letters, digits, US punctuation, space, CR/LF and Tab supported. Press/release after 25 ms. No Unicode or text injection. |
| `04` KEY | Byte 4: `1` Enter / `2` **keyboard Home** / `3` Backspace / `4` Tab / `5` Escape / `6` Space. Press/release after 25 ms. |
| `05` ABS_POINT | Bytes 4–5: X UInt16 LE; 6–7: Y UInt16 LE, both `0...32767`. Byte 8: `0` released or `1` left button held. Each held point refreshes the 250 ms automatic release deadline. |
| `06` KEY_COMBO | Byte 4: modifier `0x08` (left GUI/Command). Byte 5: only `0x0B` (H) or `0x19` (V). Automatic release after 25 ms. All other combinations are rejected. |
| `07` INFO | All zeros. No input report. Response byte 5 is the current capability bitmask: bit 0 (`1`) absolute report subscribed in report protocol; bit 1 (`2`) keyboard report subscribed in the current protocol. Suspended input returns zero. |

Keyboard Home is usage `0x4A`; **it is not an iPhone return-to-Home-screen
command**. The new Command-H and Command-V reports request host shortcuts; their
actual effects depend on iOS focus and state. The firmware does not read or write
the clipboard. Absolute HID coordinates are not automatically screen pixels:
the App must calibrate and validate the coordinate mapping for the current
orientation. The earlier full-safe-area Debug click only verified transport
delivery and cannot substitute for that calibration.

The response is exactly **8 bytes**:

| Bytes | Value |
| --- | --- |
| 0 | Version `1` |
| 1 | Request opcode |
| 2–3 | Request ID LE |
| 4 | Status |
| 5 | HID reports queued to BLE, except INFO: current capability bitmask |
| 6 | Current connection encrypted **and** bonded (`1` / `0`) |
| 7 | Reserved `0` |

Status: `0` reports queued / `1` invalid or duplicate request / `2` insecure /
`3` busy / `4` corresponding HID notification not subscribed or suspended /
`5` send/interruption failure. INFO status `0` means the query succeeded, even
when its capability mask is zero. **Status 0 proves neither radio delivery nor a
visible UI effect.** STOP succeeds with zero reports when HID is not subscribed,
which proves only the encrypted GATT handshake. Keyboard and mouse subscriptions
are checked independently; subscribing to the custom Response does not count as
an HID subscription.

## State and stopping

GATT callbacks, GAP callbacks and release callouts run on the single NimBLE host
event queue. No blocking sleeps occur in callbacks. At most one press/release
command is active. Request IDs must increase within the UInt16 half-range;
duplicates and old IDs never resend input. The App sends commands sequentially
and uses UIKit changes as the success evidence. The physical HID connection can
survive an App relaunch; the App must persist its request counter per peripheral
before sending, rather than starting from zero on each launch.
On a bonded reconnect, ESP-IDF may restore CCCDs before the application receives
CONNECT. Subscriptions are tagged with the live connection handle, preserved
when that same CONNECT arrives, and cleared on disconnect or a different link.

STOP cancels an active command and sends released reports only for subscribed HID
channels. For absolute input only the button changes to zero; X/Y stay at their
last values. Both report and boot subscriptions are released. If a scheduled
release fails, the firmware attempts all-channel
release; if that fails, it terminates its own HID connection. Disconnection
cancels all pending work and clears local pressed state; no notification can be
sent after a disconnected transport. It never reconnects or replays input
automatically.
An absolute held point arms a separate **250 ms** watchdog on the NimBLE event
queue. Every successfully queued held point restarts that deadline; invalid,
duplicate, failed, or INFO commands do not extend it. Expiry sends an absolute
button release at the last coordinates. A failed watchdog release terminates the
HID connection. This matters because iOS may keep system HID connected after the
App closes its custom GATT access. A long gesture therefore needs fresh held
points comfortably within 250 ms, and must stop if the App cannot continue.

Suspend/protocol changes interrupt pending commands with a failure response and
release the old report channel before changing mode. Failed release, loss of
encryption while input is held, or disabling a held-input notification channel
terminates the owned connection instead of abandoning its release timer.
Disabling the custom Response subscription cancels pending input and releases
all still-subscribed input channels, including an absolute hold.

## Updating from version 0.1

Version 0.2 changes the HID Report Map and adds a characteristic. iOS can retain
the previous GATT/HID descriptor cache for a bonded device. At host startup the
firmware sends the standard GATT Service Changed indication for the full handle
range to subscribed bonded peers, including on their next connection. This
requests rediscovery without deleting pairing keys. Check INFO first:
capability `1` must actually be present before calibration. If only the older
reports appear after an update, the phone may need to forget **Eiscue BLE** and
pair again. This firmware intentionally refuses silent replacement of an
existing bond, so a developer must coordinate removal of that peer's NimBLE
bond record on the board as well. The SDK's targeted API is
`ble_store_util_delete_peer`; its storage namespace is `nimble_bond`. There is no
remote reset opcode in this firmware. Preserve the original backup, unrelated NVS
namespaces and private configuration; do not erase the entire board to repair a
descriptor cache. Firmware update alone does not prove the new report is active.

On the selected iPhone 14 Pro / iOS 26.5.2, BLE HID and simultaneous custom GATT
access passed the input checks described below. Other combinations remain
unverified. Mouse behavior can depend on AssistiveTouch and system pointer
settings. A keyboard text effect, mouse movement or button action is considered
verified only when the App's actual UIKit callbacks observe it, not when this
firmware logs a packet or returns an acknowledgement.

## License and API references

This directory's original application source is Apache-2.0 (`LICENSE`). It links
the Apache-2.0 ESP-IDF and Apache NimBLE components provided by ESP-IDF. Their
upstream notices remain in the toolchain; `NIMBLE_NOTICE` is retained here for
distribution attribution. Reference APIs:

- [ESP-IDF v5.5.3 NimBLE peripheral example](https://github.com/espressif/esp-idf/tree/v5.5.3/examples/bluetooth/nimble/bleprph)
- ESP-IDF's vendored Apache NimBLE `host/ble_gatt.h`, `host/ble_gap.h`,
  `nimble_port.h` and `ble_npl_callout` APIs.

No credentials, original board data, serial captures or binaries are included.

## Version 0.2 build evidence (2026-10-12)

- ESP-IDF 5.5.3 / ESP32-C3 cross build: **PASS**. Image **534848 bytes**
  (`0x82940`), SHA-256
  `5da0051673ed5dd4e3be43b0243674f59f6610e838a571d51c4e2ad1dd509996`.
  The 2 MB application partition has 74% free space. Build log has no compiler
  warning or error. Only the application image is needed for the existing layout.
- A local UBSan smoke compiled the actual parser and peripheral source against
  host mocks. It checked coordinate bounds, all 65,536 modifier/key combinations
  against the whitelist, 250 ms watchdog release preserving X/Y, STOP on all five
  input channels, response / input unsubscription, protocol / suspend changes,
  encryption loss, release failures and duplicate request rejection. A focused
  callback-order check also verified CCCD restoration before CONNECT and clearing
  subscription state across different connections. **PASS**.
  Mock timers and notifications do not validate radio timing, iOS descriptor
  rediscovery, absolute coordinates, Home or clipboard behavior on a phone.
- Physical results for these new operations must be recorded separately; the
  older keyboard / relative-click checks below do not establish them.

## Earlier version 0.1 evidence (2026-10-12)

- ESP32-C3 cross build: **PASS**, `.bin` **533024 bytes** (`0x82220`), 75% of the
  2 MB application partition remains free. SHA-256:
  `0d33be29fa998dd5dc7b83b8008663ecac72362de0c094844a06a1d863b33192`.
- Linker static D/IRAM: **93982 bytes used**, **227314 remaining**; `.data` 10132,
  `.bss` 5160, IRAM text 78690 bytes. This is linker accounting, not a measurement
  of runtime BLE heap after connection.
- Small local UBSan parser smoke: all 95 printable US ASCII mappings, Enter /
  keyboard Home, relative bounds, reserved-byte rejection, STOP and fixed response
  shape passed. This does not exercise BLE or a phone.
- Existing Wi-Fi image remains intact (SHA-256
  `f9b5d78afdc66ff09bc938c8d1f74a23c9c250d302f229dd1d4f98db5545244b`).
- Physical app-only Flash switching was verified. On iPhone 14 Pro / iOS 26.5.2,
  actual UIKit callbacks confirmed three 12-digit keyboard inputs and one
  mouse click on an explicitly opted-in full-area test target. Wi-Fi HTTPS with
  cellular access disabled for that request returned 200 on each run. This does
  not establish calibrated coordinates, screen capture, Agent integration, or
  background execution. See
  the device validation record (local `../../docs/ble-board-validation-2026-10-12.md`).

Setup and validation notes under `docs/` are local-only and are not included in this repository.
