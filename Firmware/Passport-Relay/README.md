# Eiscue Wi-Fi Board Relay

Version **1.0.0**, target **ESP32-C3**, **8 MB Flash**, ESP-IDF **5.5.3**.

This target supplies a private Wi-Fi access point for the tested ESP32-C3 / 8 MB
development-board sample. An ESP32-C3 cannot expose USB NCM; its USB Serial/JTAG
connection is used for provisioning and power. The phone joins the board's Wi-Fi
network and the App uses the same bounded ND1/NR1/NL1 relay as the USB target.
Pairing credentials and developer-service authentication stay in the App.

Physical control passed on that sample with iPhone 14 Pro / iOS 26.5.2 on
2026-10-11, as detailed below. This does not establish compatibility with every
C3 board or phone. Identify the attached board from its ROM before flashing.
Wi-Fi association alone does not prove that iOS has authorized screen or touch
services. Joining this AP occupies the phone's Wi-Fi connection; it is not an
Internet hotspot. Cellular model requests and company VPN coexistence still
require device validation.

## Network behavior

- WPA2-PSK / CCMP, protected management frames, at most one associated phone.
- Board `192.168.7.1/30`, the only DHCP lease `192.168.7.2`, TCP port **28767**.
  IDF 5.5.3 rejects a single-address explicit lease range, so the `/30` network
  limits its native pool to `.2`. Firmware reads back that pool and stops the AP
  if the result is different.
- No DHCP router or DNS options, no advertised default route, gateway zero,
  no NAT or IP forwarding. IPv6 uses link-local addressing; no SLAAC forwarding
  or upstream network is configured.
- The shared relay accepts only the `.2` peer. It is offline with no associated
  client. AP stop, client disconnect and reconnect change the link epoch, so
  active relay work is revoked. A disconnect also releases the single DHCP lease
  for a different phone or a changed private Wi-Fi MAC address.
- Discovery retries service PTR questions on each existing 900 ms follow-up,
  including when no record has arrived yet, within the same 3-second window.
  Firmware diagnostics log only numeric packet/record counts and result codes.
- No stored phone pairing key, no microphone use, no Bluetooth startup, and no
  relay opened until the App requests it.

## Private provisioning

Firmware contains **no default SSID or password**. The flash tool must generate
unique credentials for each board and write an ESP-IDF NVS image to:

| Field | Value |
| --- | --- |
| Partition label / type | `eiscue_cfg` / `data,nvs` |
| Offset / size | `0xF000` / `0x6000` (24 KiB) |
| NVS namespace | `relay` |
| NVS key `ssid` | String, 1–32 printable ASCII bytes |
| NVS key `password` | String, 16–63 printable ASCII bytes |

Both NVS strings must be NUL-terminated. The firmware opens the namespace with
`NVS_READONLY`, keeps the active Wi-Fi config in RAM and never logs either
credential. Missing, corrupt or invalid provisioning leaves the AP disabled;
firmware never erases the configuration or falls back to an open network. Normal
runtime NVS space is reserved separately at `0x9000` (20 KiB); this target does
not open it. Wi-Fi NVS and stored PHY calibration are disabled, so a previous
firmware's runtime NVS does not have to be erased. The application image occupies
a 2 MiB partition starting at `0x20000`.

Credentials in the provisioning image are secrets, even though the image is not
encrypted. Keep the NVS image, its source CSV, and the original board's complete
flash backup in private local storage. Do not commit them or include a real
board's provisioning image in a distributable firmware package.

## Build

From the repository root, using the matching Espressif RISC-V toolchain:

```sh
export IDF_PATH=/path/to/esp-idf-v5.5.3
export IDF_TOOLS_PATH=/path/to/espressif-tools
source "$IDF_PATH/export.sh"
idf.py -C Firmware/Passport-Relay -B "$PWD/.build/passport-relay-firmware" \
  -D "SDKCONFIG=$PWD/.build/passport-relay-firmware/sdkconfig" build
```

`sdkconfig.defaults` selects ESP32-C3 and 8 MB Flash. This command does not open a
serial port, generate credentials or flash hardware. Keep this build directory
separate from the ESP32-S3 USB firmware.

## Shared code and license

The build directly reuses `../NCM-Relay/core`, `../NCM-Relay/bridge`, and
`../NCM-Relay/main/developer_service.c`; no protocol implementation is forked.
See the [source manifest](../NCM-Relay/SOURCE_MANIFEST.json),
[license](../NCM-Relay/LICENSE), and
[upstream notices](../NCM-Relay/UPSTREAM_THIRD_PARTY.md) for the selected upstream
source and provenance. Local C and build files carry GPL-3.0-or-later headers.

## Validation boundary

ESP32-C3 cross build passed with ESP-IDF 5.5.3 and the matching RISC-V GCC 14.2.0
toolchain on 2026-10-11. The application is `0xC9900` bytes (825,600 bytes), with
61% of its 2 MiB partition free. The generated partition table and 8 MB image
header were checked by the IDF build.

Physical ESP32-C3 and iPhone 14 Pro / iOS 26.5.2 validation also passed AP/DHCP
association, wireless discovery and authorization, screenshots, portrait and
landscape touch, stale-frame rejection, swiping, Unicode input, Home/App return,
and a second connection cycle. The App's local VPN stayed disconnected. A
600-second board capture had one association, one lease and no disconnect/error.
See the [device validation record](../../docs/board-validation-2026-10-11.md).

Local disconnection is not a remote daemon teardown acknowledgement. Sustained
background work, cellular model requests and company VPN coexistence remain
unverified. Board identification, backup and flashing belong to the
[board setup workflow](../../docs/board-setup.md).

The sample now runs the separate [BLE firmware](../Passport-BLE/README.md),
integrated with ordinary App connection selection, ReplayKit sharing and Agent
tools. On 2026-10-12, version 0.2 passed ordinary connection, screen sharing,
four actual calibration touches and Chinese text checks on the same iPhone.
BLE swiping, complete cross-App Agent tasks and sustained background sharing
remain unverified. See the [current BLE validation record](../../docs/ble-production-validation-2026-10-12.md).

The earlier version 0.1 Debug baseline on 2026-10-12 passed three 12-digit inputs,
one test-button click and Wi-Fi HTTPS 200 with cellular access disabled for each
request. The version 0.2 run did not repeat that Internet check; these separate
BLE results do not validate Internet access through this Wi-Fi AP. See the
[BLE baseline record](../../docs/ble-board-validation-2026-10-12.md).

Restore the retained Wi-Fi application image before using this Wi-Fi route;
the two firmware images do not run simultaneously.
