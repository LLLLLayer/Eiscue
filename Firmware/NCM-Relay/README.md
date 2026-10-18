# Eiscue NCM Relay firmware

Version **1.0.0**, target **ESP32-S3**, minimum **4 MB Flash**, ESP-IDF **5.5.3**.

This standalone firmware exposes a USB CDC-NCM Ethernet device and the bounded
ND1/NR1/NL1 relay used by Eiscue's `PhoneAgentNCM` backend. The App owns pairing,
authentication and developer-service protocols; the board supplies an external
network origin. It does not implement an Agent or store pairing keys.

**ESP32-C3 cannot run this USB NCM firmware.** Its fixed-function USB Serial/JTAG
block cannot become a network device.
An ESP32-S3 build is not evidence of physical USB compatibility.

The separate [HID firmware](../Passport-BLE/README.md) supports C3 BLE and S3
BLE / USB HID, with ReplayKit observation. Its recorded phone input results do
not validate USB NCM on an S3. Separate bounded USB/CoreDevice and XCTest
phone checks passed on 2026-10-19; broader hardware behavior and company VPN
coexistence remain unverified.

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

This default package uses a **4 MB layout**. The 2026-10-19 phone check instead
used a verified **app-only image preserving an existing 16 MB HID layout**.
These are different flash layouts; do not write the default package over that
HID layout without a separately verified migration.

The CLI supports only `ncm` and `s3-hid` packages. The removed `passport` Wi-Fi
relay profile and its old packages are rejected before opening a serial port;
the tool no longer generates Wi-Fi credentials. Existing private backups and
configuration files must be retained. `flash` requires explicit `--port` and
`--package` arguments, verifies a full-Flash backup, then writes and verifies the
selected package. `check-link --target ncm --interface <interface>` accepts only
an active USB interface with `192.168.7.2/24`; it never uses Wi-Fi or VPN.

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

## Validation status (updated 2026-10-19)

| Check | Evidence |
| --- | --- |
| ESP32-S3 cross build | PASS: ESP-IDF 5.5.3, app `0x5f600` bytes within 1 MB partition |
| Protocol/localhost tests | PASS: DNS truncation/TTL, greeting/schema/EOF, auth boundaries, browser gates, source binding, deadlines, two-way 1 MiB relay/backpressure/cancel |
| Python flash-tool guards | Historical PASS for the USB S3 profile: C3/encryption refusal, verified private backup, mismatch and package tamper rejection, filtered USB inventory. |
| Flash/readback on physical S3 | PASS: verified full backup and app-only readback on a 16 MB S3; existing layout and bytes outside written sectors preserved, no key/bond reset |
| iPhone USB NCM | One foreground swipe per CoreDevice/XCTest backend; CoreDevice stop gate/confirmed cleanup and short background observation passed; scope below |
| Standalone Mac enumeration/ND1 checks | NOT RUN |
| Company VPN coexistence | NOT RUN |

The local Xcode 26.3 ASan runtime deadlocked during initialization on the current
macOS; a process sample located the deadlock before test `main`. UBSan tests
passed; ASan is not counted as a pass.

On **2026-10-14**, `python3 -m unittest discover -s Firmware/NCM-Relay/tests -p
'test_*.py' -v` passed **14 tests, 0 failures** after removing the Wi-Fi profile.
These offline tests cover rejected legacy CLI targets/packages before serial
access, retained NCM/S3 HID packaging, USB-only link selection, private backup
verification and protected S3 partitions. No firmware build or hardware checks
were run for this removal; the historical results above remain separate.

On **2026-10-17** the same Python suite passed again (**14 tests, 0 failures**).
`Scripts/test-board-firmware.sh` was not run because `IDF_PATH` was unset, so
the C protocol/localhost tests have no new result. No hardware was used.

On **2026-10-19**, iPhone 12 mini / iOS 27.0 (24A437) passed one zero-model
USB NCM/CoreDevice owned-page swipe (153 pt visible scrolling and a fresh
post-action image), retaining readiness through completion with confirmed
cleanup and engine/owner release. A separate in-flight stop gate settled an
unknown work outcome with confirmed cleanup; the submitted two-second drag
still finished about 1.471 seconds after stop. One 61.429-second actual
background-observation window passed four background samples with no model
requests. USB interface binding excludes Wi-Fi/VPN fallback; this does not
verify company VPN coexistence. XCTest also passed one foreground swipe
(151 pt scrolling, fresh image, retained readiness and confirmed cleanup) on
this same iOS 27 phone. XCTest background/stop, iOS 26 hardware, background
input, real-model tasks, rotation and repeated-cycle stability remain open.
The HID image/readback was restored and saved authorization reconnected;
sharing/calibration were not rechecked.
