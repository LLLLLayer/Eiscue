# ESP32-C3 Bluetooth Board Experiment

Original ESP32-C3 firmware, version **0.1.0**, built with ESP-IDF **5.5.3**.
No Pilot or other undeclared-license implementation was copied. The peripheral
uses the official ESP-IDF NimBLE APIs and standard HID Usage Tables. Its purpose
is to test encrypted App commands and actual iPhone keyboard/mouse effects while
the phone keeps its normal Wi-Fi connection. It does not capture the screen,
implement an Agent, or prove that iOS recognizes the HID service merely by
returning a command acknowledgement.

This route is an explicit **Debug-only experiment** on the current ESP32-C3 /
8 MB sample. It is not integrated into the normal App's device-connection
selection or Agent. Other board layouts and phone / OS combinations require
separate validation.

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
Mode, two Input Report characteristics and their Report Reference descriptors,
plus boot mouse/keyboard input characteristics and boot keyboard LED output.
Report ID **1** is the 4-byte relative mouse report; report ID **2** is the 8-byte
US keyboard report. HOGP notifications do not prefix the report ID: the Report
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
| `00` STOP | All zeros. Cancel pending release timer and release all subscribed input channels. Also serves as encrypted GATT handshake. |
| `01` MOVE | Bytes 4–5: relative dx Int16 LE; 6–7: relative dy Int16 LE; byte 8: signed wheel Int8. Each component must be in `−127...127`. |
| `02` CLICK | Byte 4: `1` left / `2` right / `4` middle; byte 5: `1` click. Automatic release after 25 ms. |
| `03` ASCII | Byte 4: one US ASCII character. Letters, digits, US punctuation, space, CR/LF and Tab supported. Press/release after 25 ms. No Unicode or text injection. |
| `04` KEY | Byte 4: `1` Enter / `2` **keyboard Home** / `3` Backspace / `4` Tab / `5` Escape / `6` Space. Press/release after 25 ms. |

Keyboard Home is usage `0x4A`; **it is not an iPhone return-to-Home-screen
command**. Absolute pointer coordinates are not implemented. Coordinate-targeted
actions must observe or calibrate actual pointer position; HID offsets cannot be
treated as screen coordinates. A separately opted-in Debug experiment may use a
full-safe-area harmless button and one click to verify transport delivery only.

The response is exactly **8 bytes**:

| Bytes | Value |
| --- | --- |
| 0 | Version `1` |
| 1 | Request opcode |
| 2–3 | Request ID LE |
| 4 | Status |
| 5 | HID reports queued to BLE |
| 6 | Current connection encrypted **and** bonded (`1` / `0`) |
| 7 | Reserved `0` |

Status: `0` reports queued / `1` invalid or duplicate request / `2` insecure /
`3` busy / `4` corresponding HID notification not subscribed or suspended /
`5` send/interruption failure. **Status 0 proves neither radio delivery nor a
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

STOP cancels an active command and sends zero reports only for subscribed HID
channels. If a scheduled release fails, the firmware attempts all-channel
release; if that fails, it terminates its own HID connection. Disconnection
cancels all pending work and clears local pressed state; no notification can be
sent after a disconnected transport. It never reconnects or replays input
automatically.
Suspend/protocol changes interrupt pending commands with a failure response and
release the old report channel before changing mode. Failed release, loss of
encryption while input is held, or disabling a held-input notification channel
terminates the owned connection instead of abandoning its release timer.

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

## Build evidence (2026-10-12)

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
  [the device validation record](../../docs/ble-board-validation-2026-10-12.md).
