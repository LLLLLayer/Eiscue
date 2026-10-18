# ESP32-C3 / ESP32-S3 Device Control Firmware

Original ESP32-C3 / ESP32-S3 firmware, version **0.3.0**, built with ESP-IDF **5.5.3**.
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
bash Scripts/build-passport-ble.sh esp32c3   # Legacy BLE HID
bash Scripts/build-passport-ble.sh esp32s3   # BLE command + explicitly selected BLE / USB HID
```

Outputs are `.build/passport-ble-firmware/eiscue_passport_ble.bin` (C3) and
`.build/s3-hid-firmware/eiscue_passport_ble.bin` (S3). Each target has its own
build directory, defaults and dependency lock. TinyUSB is included only on S3.
Build never opens serial or flashes. The C3 `partitions.csv` preserves the
existing board layout: NVS at `0x9000`, PHY at `0xE000`, private configuration at
`0xF000`, and the 2 MB application at **`0x20000`**. Updating a C3 with this
verified layout should write **only the application**, after retaining a verified
full-Flash backup and checking the actual board/partition layout, then verify
readback. Do not write an unverified bootloader/table or erase private
configuration. There is no C3 CLI packaging/flashing profile.

S3 uses its own `partitions.esp32s3.csv`, matching the attached board's original
24 KB NVS at `0x9000` and PHY at `0xF000`, with reserved configuration at
`0x10000` and the application at `0x20000`. Its Flash header is **16 MB**, matching
the probed board. Installing it on a differently laid-out board requires its
own full backup and explicit layout checks; the existing C3 table must not be
written over S3's longer NVS range. Build success does not authorize Flash writes.

The original full-Flash backup and any retained recovery images must be kept.
BLE bonds are stored in NimBLE's NVS namespace; startup does not erase NVS on an
error. C3 initializes the board-specific display and OK key described below.
S3 has no display or key driver. Neither target starts Wi-Fi or the microphone.
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
| C3 companion status (encrypted write) | `74074E9A-41E8-4E84-951D-70E623643AB8` |
| C3 physical stop (encrypted read/notify) | `74074E9A-41E8-4E84-951D-70E623643AB9` |

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

## S3 USB and authenticated command route

S3 keeps the same encrypted BLE command service, ReplayKit capture and on-phone
Agent. It can send either BLE HID or USB HID, selected explicitly by opcode 8.
Every connection defaults to BLE; choosing USB never falls back to BLE if the
cable, host enumeration or input release fails. It starts no Wi-Fi or network
interface and occupies no VPN channel. C3 continues using the version 1 command
protocol and has no USB HID support.

USB uses the S3 native full-speed OTG peripheral on GPIO 19 / 20. Connect the
board's **native data USB port**, rather than a UART bridge port, to the phone
as a USB peripheral. The descriptor is a bus-powered 100 mA development device
with three input interfaces: relative pointer, keyboard and absolute pointer,
using the same report layouts as BLE. This firmware exposes no CDC, USB network,
storage, charging negotiation or accessory authentication function. Its
`303A:4004` identity is experimental, not a certified product identity.

USB-C phones need a data/host-capable connection. Lightning phones (including
iPhone 14 Pro) need a compatible USB host adapter; sufficient external power
may also be required. S3 support alone does not establish Lightning adapter
compatibility. The native USB PHY is shared with USB Serial/JTAG: once this
firmware runs, that port no longer provides the previous debug serial device.
Logs use UART; ROM download mode remains the recovery path. These assumptions
require board-specific and phone-specific acceptance.

USB input is not authorized until explicit SELECT_OUTPUT and host enumeration.
A detach, or a suspend / bus reset **after the first mount**, revokes that selection;
reconnecting a different host cannot reuse a phone screenshot/calibration. It
requires a fresh explicit selection and App calibration. Losing the BLE command
owner revokes USB input, releases available reports and electrically disconnects
the owned HID interface. A failed release disconnects USB instead of leaving a
button pressed. STOP, request deduplication and the 250 ms absolute-hold watchdog
apply to both outputs.

Each SELECT_OUTPUT starts a fresh mount epoch and performs a nonblocking 20 ms
soft disconnect / reconnect; TinyUSB's old `cfg_num` is never used as proof of a
new host. Before the first mount, a temporary suspend blocks input while resume
can continue enumeration. Only a fresh ATTACHED callback authorizes the mount;
resume alone cannot revive a stale configured flag. Once mounted, the existing
host-change revocation rules remain in force, so this initialization fix cannot
restore an old calibration or switch outputs automatically.
Timer PHY connect and session revocation share a short critical section. A
queued timer checks the current epoch's reconnect deadline; cancellation cannot
let a late callback reconnect a revoked session or borrow a newer selection.
Post-mount revocation also electrically disconnects the PHY in that critical
section. A report submission interrupted by host reset cannot reach a newly
connected host; only a fresh SELECT on the serialized BLE command queue can
reconnect, followed by new USB enumeration. Report submission remains outside
the critical section, and an acknowledgement is returned only after TinyUSB
actually accepts the report and the output is still authorized.

UART diagnostics contain numeric USB event IDs, reset / unplug / SETUP counts,
selection / mount flags and HID descriptor query metadata only. IRQ hooks update
atomic counters; task callbacks and readiness queries emit logs. No command
payload, pointer coordinate, key value, authentication material or raw USB data
is logged.

### S3 authentication v2

S3 rejects unsigned version 1 command writes, including STOP and INFO. The BLE
link still requires encryption and bonding; each command additionally carries
a session HMAC so a different App sharing the phone's system BLE connection
cannot borrow Eiscue's authenticated state. No key, proof, nonce or command
payload is written to logs.

| Attribute | UUID suffix | Value |
| --- | --- | --- |
| Challenge, encrypted read | `3AB6` | 34 bytes: version `2`, flags (bit 0 key present, bit 1 enrollment open), board ID 16, board nonce 16 |
| Authenticate, encrypted write / notify | `3AB7` | Request 50 bytes: version `2`, operation `1` enroll / `2` prove, client nonce 16, root key 32 (enroll) or proof 32 (prove). Reply 35 bytes: version `2`, operation, status `0`, server proof 32 |
| Command | `3AB4` | 52 bytes: semantic command 16 (byte 0 `2`), sequence UInt32 LE, HMAC-SHA256 32 |
| Response | `3AB5` | 44 bytes: semantic response 8 (byte 0 `2`), matching sequence UInt32 LE, HMAC-SHA256 32 |

All labels below are exact UTF-8, concatenated without a terminator. Let
`context = boardID16 || boardNonce16 || clientNonce16`. The client proof is
`HMAC(rootKey, "EiscueBLE/v2/client" || context)`; the session key is
`HMAC(rootKey, "EiscueBLE/v2/session" || context)`; server proof is
`HMAC(rootKey, "EiscueBLE/v2/server" || context || reply[0..<3])`. Command and
response MACs use the session key and respectively the labels
`EiscueBLE/v2/cmd` over the first 20 bytes and `EiscueBLE/v2/reply` over the
first 12 bytes. Sequences start above zero, strictly increase per connection,
and cannot wrap; timers retain the original command sequence for their reply.
Only one AUTH write is accepted per connection. Invalid MACs, repeated AUTH,
unsigned commands or replayed sequences release input and disconnect.

Board ID and root key are persisted in the default NVS namespace `eiscue_auth`,
separate from the reserved private configuration partition. Startup never erases or replaces
existing identity. An unclaimed board permits first enrollment only during its
first 60 seconds after boot; an existing key closes enrollment permanently.
This is **trusted-nearby development enrollment**, not passkey/MITM-protected
production onboarding. Power cycling an unclaimed board reopens that short
window; an already claimed board requires its saved key, and this firmware
provides no remote key-reset command. Negotiate ATT MTU at least 55 (preferred
128) before commands. A connection, AUTH ACK or USB enumeration alone does not
prove phone input.

For S3, the App stores its board key in a device-only Keychain item. Losing that
key, changing phones or a stale board/phone BLE bond has no automatic reset path:
uninstalling the App or flashing its application image does not unclaim the
board. Preserve the private board backup and coordinate an explicit, targeted
identity/bond reset outside this prototype. Never erase the full Flash or
unrelated NVS as an onboarding shortcut.

## C3 screen companion and physical stop

The C3 profile targets the existing development board's ST7789 240 × 320 display
and GPIO 0 resistor-ladder keys. Its original driver uses ESP-IDF `esp_lcd` with
SPI MOSI 9, SCLK 8, CS 1, DC 20, backlight 21, no reset pin, SPI mode 0 and color
inversion. SPI runs at 20 MHz. These board-specific electrical parameters are
documented by the [hardware maintainer](https://github.com/FoloToy/ai-passport/blob/main/components/bsp/include/bsp_pins.h);
the upstream BSP implementation is not copied. Do not use this profile for an
arbitrary C3 board without checking its wiring.

Five existing Eiscue expressions and fixed English / Simplified Chinese labels
are stored as per-row RGB565 PackBits assets in Flash. A low-priority display
task decodes into one 3,840-byte DMA strip; it has no framebuffer, LVGL heap or
Wi-Fi dependency. A failed or timed-out display transfer stops rendering without
reusing its possibly in-flight DMA buffer. Display failure cannot prevent the
independent key task from stopping input. Generated assets, source hashes and
regeneration instructions are recorded in [Resources](Resources/README.md).

AB8 accepts exactly 12 bytes from the currently encrypted and bonded connection:

| Bytes | Meaning |
| --- | --- |
| 0 | Version `1` |
| 1 | Phase: `0` idle, `1` needs screen sharing, `2` needs calibration, `3` ready, `4` thinking, `5` observing, `6` acting, `7` waiting, `8` turn finished, `9` needs attention, `10` stopped |
| 2 | Language: `0` English, `1` Simplified Chinese |
| 3 | Reserved zero |
| 4–5 | Completed device steps, UInt16 little endian |
| 6–11 | Reserved zero |

It is a separate optional status characteristic, never a HID command or tool.
There are no task titles, chat contents, coordinates, credentials or percentages
in this channel. Completed-step counts come from the App; neither HID ACKs nor
the board infer task success. Phase 8 is displayed as **Turn finished**. The App
sends a five-second heartbeat for every state. After 15 seconds without a valid
update the display says status is unavailable; it cannot keep claiming the
Agent is acting. A disconnected or unencrypted local link takes precedence over
App status, and the physical stop latch takes precedence over everything.

The **OK key** (ADC voltage 447–1900 mV) stops on a debounced press, without
waiting for release or a phone response. The other two keys are unused. An
independent task samples the calibrated ADC every 20 ms with 40 ms debounce.
It atomically latches input off, then posts onto the NimBLE host queue to cancel
pending reports, release all subscribed keyboard/mouse channels, and notify the
App. Failed releases terminate the BLE transport. An unreadable key ADC also
latches input off. LCD rendering never runs on this queue.

AB9 is four bytes: `[1, stopLatched, stopGenerationLo, stopGenerationHi]`.
The App reads it during connection, subscribes for immediate stop events, and
polls every second to recover missed notifications. Polls use an independent GATT
read, allow one outstanding read, and yield while a HID command is awaiting its
reply. A failed read or a five-second read timeout closes the connection. These
reads continue even if display writes have failed. Generation increments once
per newly latched stop, modulo 65,536. The latch survives BLE reconnects during
the same power session. While latched, only STOP, INFO and QUERY_OUTPUT are
accepted; INFO clears input-ready bits and all other commands fail before any
HID report. The report emission path independently checks the latch to cover a
press between parsing a command and queuing its report.

To unlock, first release OK, then hold it again for **1.5 seconds**. The press
which stops input can never also unlock it. Unlock releases inputs and forces a
BLE disconnect; the latch clears only when that disconnect completes (or when
already disconnected). A failed disconnect leaves input blocked. The App must
connect and calibrate again, and must never automatically continue the stopped
run. This is an input safety stop, not an undo for actions already delivered.
It does not persist across board power loss or replace the phone's stop button.

Software checks use `bash Scripts/test-board-companion.sh`: five UBSan scenario
groups cover packet validation, the stop gate, heartbeat expiry/local precedence,
debounce/unlock sequencing, and all 47 decoded bitmap assets. These checks and
the C3/S3 builds do not establish physical display orientation, button thresholds,
BLE notification timing or iPhone input behavior. The initial C3 build exposed
a compile-time RGB565 narrowing error; the corrected build passes with warnings
treated as errors. No serial or Flash access is performed by these checks.

## Fixed semantic command protocol

Each semantic command is exactly **16 bytes** (C3 sends it directly; S3 wraps it
in the authenticated v2 envelope above):

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
| `06` KEY_COMBO | Byte 4: modifier `0x08` (left GUI/Command). Byte 5: only `0x0B` (H), `0x19` (V) or `0x2C` (Space). Automatic release after 25 ms. All other combinations are rejected. |
| `07` INFO | All zeros. No input report. Response byte 5: bit 0 (`1`) absolute input ready for the selected output; bit 1 (`2`) keyboard input ready; bit 5 (`32`) relative mouse input ready; bit 6 (`64`) bounded RELATIVE_STROKE supported; bit 7 (`128`) SELECT_OUTPUT / QUERY_OUTPUT supported. A suspended or unauthorized output clears readiness bits 0, 1 and 5. Support bits remain static. |
| `08` SELECT_OUTPUT | Byte 4 `0` BLE / `1` USB, remaining bytes zero. Rejects switching while a command or held input is active, releases the old output first. USB on C3 is rejected; USB without a mounted host is selectable but not ready. |
| `09` QUERY_OUTPUT | All zeros. Response byte 5: bit 0 USB selected; bit 1 USB supported; bit 2 actual USB host mounted and awake; bit 3 S3; bit 4 restricted navigation shortcuts supported. Mounted does not imply calibrated input. |
| `0A` RELATIVE_STROKE | Bytes 4–5: total dx Int16 LE; 6–7: total dy Int16 LE; byte 8: movement step count `1...250`; 9–10: movement duration UInt16 LE `100...2000` ms; bytes 11–15 zero. Duration must be between `steps × 8` and `steps × 50` ms. Every planned movement delta must have squared length at most `64` (8 relative counts radially). Rejects an already held absolute or mouse button before dispatch. |

RELATIVE_STROKE uses the existing relative mouse report, without changing the
report map, GATT identity, bond records or flash partitions. It sends a zero-motion
left-button DOWN, the bounded held movement reports, then a zero-motion UP after
an additional **8 ms** release tail. The wire duration describes movement only;
the nominal held duration is movement duration plus 8 ms. Success is acknowledged
only after UP is queued, with exactly `steps + 2` reports (at most 252).
Cumulative signed division truncates toward zero: step `i` moves by
`trunc(total × i / steps) − trunc(total × (i−1) / steps)` on each axis, preserving
the exact total including negative directions. Each rounded delta is checked,
so a small average displacement cannot hide an oversized individual step.
Movement intervals use cumulative integer duration division and are 8–50 ms;
queued timer turns never cause a burst of catch-up reports. An observed step gap
over 50 ms, or completion later than nominal movement plus release plus 50 ms,
aborts and attempts all-channel release. These scheduling bounds are software
checks; actual BLE/USB and phone contact timing still require hardware validation.

Keyboard Home is usage `0x4A`; **it is not an iPhone return-to-Home-screen
command**. Command-H is not a verified system Home action, so the app does not
advertise a Home capability on this transport. iPhone Full Keyboard Access is a
separate system feature with its own Home command; enabling AssistiveTouch does
not enable it.
Command-Space and Command-V also request host shortcuts; a board acknowledgement
does not confirm their visible effects. The firmware does not read or write
the clipboard. Absolute HID coordinates are not automatically screen pixels:
the App must calibrate and validate the coordinate mapping for the current
orientation. The earlier full-safe-area Debug click only verified transport
delivery and cannot substitute for that calibration.

The semantic response is exactly **8 bytes** (C3 direct; S3 authenticated 44-byte
envelope):

| Bytes | Value |
| --- | --- |
| 0 | Version `1` |
| 1 | Request opcode |
| 2–3 | Request ID LE |
| 4 | Status |
| 5 | HID reports queued to selected output, except INFO / QUERY_OUTPUT: current capability / output metadata |
| 6 | Current connection encrypted **and** bonded (`1` / `0`) |
| 7 | Reserved `0` |

Status: `0` reports queued / `1` invalid or duplicate request / `2` insecure /
`3` busy / `4` corresponding HID notification not subscribed or suspended /
`5` send/interruption failure / `6` authentication required. S3 authentication failures
terminate the connection; no unsigned command acknowledgement is accepted. INFO status `0` means the query succeeded, even
when its capability mask is zero. **Status 0 proves neither radio delivery nor a
visible UI effect.** STOP succeeds with zero reports when HID is not subscribed,
which proves only the encrypted GATT handshake. BLE keyboard and mouse subscriptions
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
Relative held reports have an independent watchdog with the same **250 ms**
deadline. Every successfully queued relative held report refreshes it; mouse UP
stops it. STOP, malformed commands, authentication/subscription loss, suspended
output and the C3 physical stop cancel a trajectory and attempt release; an output
send failure also aborts it. No descriptor or bond reset is part of this change.

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
- [ESP-IDF v5.5.3 USB HID example](https://github.com/espressif/esp-idf/tree/v5.5.3/examples/peripherals/usb/device/tusb_hid)
- Pinned `espressif/esp_tinyusb` 2.2.0 (Apache-2.0) and `espressif/tinyusb` 0.21.0~2 (MIT); upstream license files remain in the managed component distribution.
- ESP-IDF's vendored Apache NimBLE `host/ble_gatt.h`, `host/ble_gap.h`,
  `nimble_port.h` and `ble_npl_callout` APIs.

No credentials, original board data, serial captures or binaries are included.

## Version 0.3 software evidence (2026-10-13)

- ESP-IDF 5.5.3 ESP32-S3 / 16 MB Flash build: **PASS**, application
  **552736 bytes** (`0x86F20`), SHA-256
  `931fcc33eabb15cd2108b44a95ecb93bb1a8b5fde871c80c9819bb69aca32c9a`.
  The separate S3 table preserves the probed NVS / PHY ranges. This build
  includes USB HID, authentication v2 and physical host-change quarantine;
  74% of its 2 MB app partition is free. It has **not been flashed**.
- ESP32-C3 compatibility build: **PASS**, **535696 bytes** (`0x82C90`), SHA-256
  `6bd4f4aaf283008592d3a9b23370883e90c8711c90b9aba34cb4d36018d3255d`.
  It keeps the original table and version 1 packet sizes; it does not link
  TinyUSB or require S3 authentication.
- Neither build reported a compiler warning or error. Build scripts passed
  Bash syntax validation; no build command opens serial or writes Flash.
- A focused UBSan host smoke compiled the actual USB and command parser source
  with fake host APIs: first-mount authorization, three report interfaces,
  bus-reset / unplug / suspend revocation, explicit reselection, busy / boot /
  unsupported reports, route bounds and Cmd-Space whitelist: **PASS**. The
  initialization fix additionally passed stale `cfg_num` selection, pre-mount
  suspend / resume recovery, canceled / old callbacks and a deterministic
  contended callback-versus-revocation PHY transition. Host reset immediately
  before or during report submission also prevented delivery to a new host.
- The actual authentication module passed its six host fixture scenario groups
  using independent Python HMAC vectors: persistent identity, enrollment
  expiration, first-key preservation, previous-session proofs, invalid MAC /
  old sequence rejection, pending reply sequences and uncertain NVS writes
  failing closed. Host APIs and test keys do not prove BLE or phone behavior.

## Version 0.3 physical evidence (2026-10-13)

The earlier S3 image with SHA-256
`e0f7aebfdf0404bf08dfde3fc4269c9344e9c67e45ee4da56599948171605470`
passed the App's four-point touch and Chinese text checks over BLE on iPhone
14 Pro. This does not establish full cross-App Agent tasks, Bluetooth swipe or
long background execution.

The subsequent enumeration/state-fix image, SHA-256
`26c7db94103d2fbe283653fe2ea0e5fbd737dd2c46fd86396fdbfb0adf96249d`,
was installed after a full-Flash backup and passed Flash readback verification.
No phone input acceptance was performed for that image. The latest physical
quarantine image (`931fcc33…` above) has software evidence only and has not been
installed; the board still has the `26c7db94…` image.

The USB attempt used an ordinary Lightning-to-USB-C cable, rather than a USB
host / Camera Adapter. The phone did not enumerate the board; no USB phone input
acceptance was completed. A compatible host adapter is still required. The new
software result does not validate USB HID on the phone, and the earlier BLE
result applies only to its recorded image.

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
- Historical recovery image was retained privately (SHA-256
  `f9b5d78afdc66ff09bc938c8d1f74a23c9c250d302f229dd1d4f98db5545244b`).
- Physical app-only Flash switching was verified. On iPhone 14 Pro / iOS 26.5.2,
  actual UIKit callbacks confirmed three 12-digit keyboard inputs and one
  mouse click on an explicitly opted-in full-area test target. Wi-Fi HTTPS with
  cellular access disabled for that request returned 200 on each run. This does
  not establish calibrated coordinates, screen capture, Agent integration, or
  background execution.
