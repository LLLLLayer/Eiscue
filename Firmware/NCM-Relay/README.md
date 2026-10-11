# Eiscue NCM Relay firmware

Version **1.0.0**, target **ESP32-S3**, minimum **4 MB Flash**, ESP-IDF **5.5.3**.

This standalone firmware exposes a USB CDC-NCM Ethernet device and the bounded
ND1/NR1/NL1 relay used by Eiscue's `PhoneAgentNCM` backend. The App owns pairing,
authentication and developer-service protocols; the board supplies an external
network origin. It does not implement an Agent or store pairing keys.

**TRAE Passport / FoloToy AI Passport is an ESP32-C3 product and cannot run this
USB NCM firmware.** Its fixed-function USB Serial/JTAG block cannot become a
network device. See [hardware compatibility and setup](../../docs/board-setup.md).
An ESP32-S3 build is not evidence that the TRAE Passport works.

The attached user's board has now been identified by ROM as ESP32-C3 with 8 MB
Flash. Its separate [Passport Wi-Fi firmware](../Passport-Relay/README.md) uses
WPA2, one client and `.1/.2` on a `/30` subnet; this S3 USB firmware keeps `/24`.
The C3's full original Flash backup passed ROM MD5 verification, and an initial
wireless image passed `write_flash` and `verify_flash`. Runtime review then found
a missing explicit DHCP start. The patched application partition has been
written and verified while preserving the original backup and private Wi-Fi
configuration. An actual boot log reports the private WPA2 AP and relay ready
at 352 ms, waiting for a phone; phone association and relay/control behavior
remain unverified. The wireless App's unsigned Release build passed, but its
signed build still fails and has not been installed. See the [Passport build,
private provisioning and phone
setup](../../docs/board-setup.md#给-passport-烧录无线固件). Neither route has yet
demonstrated company VPN coexistence or complete iOS 26 device control.

## Source and license

Source: [ja1chen/actell](https://github.com/ja1chen/actell), pinned commit
`032864e2339da19ee13025c471f4cf1dfdf4c5cd`.

`SOURCE_MANIFEST.json` records every selected upstream file, original SHA-256,
current SHA-256 and local modifications. Original SPDX headers are retained.
The upstream combined project declares GPL-3.0-only; individual files retain
GPL-3.0-or-later headers. `LICENSE` is the original GPL text, and
`UPSTREAM_THIRD_PARTY.md` is the unmodified provenance notice (some entries refer
to upstream components outside this selected firmware).

Local changes relocate build paths, pin ESP-IDF 5.5.3, regenerate its component
lock, use a 4 MB image layout, and identify the USB product as Eiscue NCM Relay.
All source required for this selected firmware is retained. Managed ESP-IDF
components are downloaded using the pinned versions/integrity checks in
`dependencies.lock`; no compiled firmware or captured device data is committed.

## Layout

| Directory | Purpose |
| --- | --- |
| `main` | USB descriptors/lifecycle, lwIP Ethernet interface, bounded TCP dispatcher |
| `core` | mDNS discovery, diagnostic JSON, TCP binding and two-stream relay |
| `bridge` | Selected upstream framing/protocol helpers required by the core |
| `tests` | Synthetic protocol/localhost transport tests and flash-tool guards |

## Build and package

Install ESP-IDF v5.5.3 and its `esp32s3` tools using Espressif's installer. Set
`IDF_PATH` and optionally `IDF_TOOLS_PATH`; no personal-machine path is hardcoded
in the scripts.

```sh
export IDF_PATH=/path/to/esp-idf-v5.5.3
export IDF_TOOLS_PATH=/path/to/espressif-tools
bash Scripts/build-board-firmware.sh
bash Scripts/test-board-firmware.sh
```

The build script only builds/packages; it never opens serial or flashes. Output:
`.build/ncm-relay-firmware/release/eiscue-ncm-relay-1.0.0/`, containing the three
flash images and a versioned SHA-256 manifest. `board-firmware.py verify-package`
checks sizes, hashes, chip, version and non-overlapping flash regions.

Host tests use UBSan by default. `BOARD_SANITIZERS=address,undefined` enables both
sanitizers where the host ASan runtime supports its macOS version. The bundled
localhost tests currently target macOS (`lo0` / `SO_NOSIGPIPE`). Neither test mode
opens any physical device.

## Wire compatibility

The USB device contains only CDC-NCM interfaces (no USB HID, serial CDC or mass
storage). IPv4 board address is `192.168.7.1/24`; the host is `192.168.7.2/24`.
IPv6 is link-local. There is no DHCP, default route, DNS, NAT, IP forwarding or
radio startup. The static host configuration is an initial setup requirement.

TCP port **28767** accepts only the attached `.2` peer. One bounded ASCII line
starts each connection:

- `STATUS`, `DISCOVER4`, `DISCOVER6`, `LOCKDOWN`, `PROBE generation index` return
  diagnostic-only ND1 JSON. They never grant screen/input authorization.
- `NR1 OPEN generation index nonce` opens a current discovered RemotePairing
  endpoint. `NR1 TUNNEL nonce port` opens its negotiated tunnel. One owned session
  has at most two byte streams, bounded buffers, deadlines and cancellation.
- `NL1 OPEN nonce` is the separate fixed peer Lockdown route; it cannot open a
  RemotePairing tunnel.

The nonce is exactly 32 lowercase hexadecimal characters. Stale generations,
wrong nonces, duplicate streams and arbitrary target addresses are rejected.
Unplug/suspend epochs revoke active relays. Authentication remains end to end in
the App/backend; an `NR1 OK` is a transport acknowledgement, not proof that a tap
or screenshot succeeded.

## Validation status (2026-10-11)

| Check | Evidence |
| --- | --- |
| ESP32-S3 cross build | PASS: ESP-IDF 5.5.3, app `0x5f600` bytes within 1 MB partition |
| Protocol/localhost tests | PASS: DNS truncation/TTL, greeting/schema/EOF, auth boundaries, browser gates, source binding, deadlines, two-way 1 MiB relay/backpressure/cancel |
| Python flash-tool guards | Historical PASS for the USB S3 profile: C3/encryption refusal, verified private backup, mismatch and package tamper rejection, filtered USB inventory. Passport now has a separate C3 profile; no new unit-test result is claimed. |
| Physical board identification | PASS for the subsequently attached Passport: ROM reports ESP32-C3 / 8 MB. The earlier no-board USB inventory remains a historical observation, not current status. |
| Passport original Flash backup | PASS: full Flash saved privately and checked against ROM MD5 |
| Passport wireless write/readback | PASS: initial image and DHCP-fixed application partition both passed `write_flash` and `verify_flash`; original backup and private provisioning preserved |
| Passport actual boot | PASS: at 352 ms, `Private WPA2 AP ready; waiting for one phone` and ND1/NR1 relay idle; no phone association or actual diagnostic request demonstrated |
| Wireless App build/install | Unsigned Release full build PASS; signed build still fails, so the wireless version has not been installed on the phone |
| Flash/readback on physical S3 | NOT RUN: the connected Passport is C3, not an S3 board |
| USB NCM enumeration and ND1 on Mac/phone | NOT RUN |
| Company VPN coexistence and iOS control | NOT RUN |

The local Xcode 26.3 ASan runtime deadlocked during initialization on the current
macOS; a process sample located the deadlock before test `main`. UBSan tests
passed; ASan is not counted as a pass.
