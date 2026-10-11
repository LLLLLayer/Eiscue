# Passport BLE experiment — 2026-10-12

## Scope

Use the existing ESP32-C3 TRAE Passport as a BLE HID peripheral and encrypted
GATT command receiver. The iPhone keeps its normal Wi-Fi Internet connection.
This experiment does not run the Agent, capture the screen with ReplayKit, or
prove background operation. The normal App's device backend is unchanged.

The dedicated `--ble-device-check` entry exists only in Debug builds and skips
normal AppModel loading/device connection. It observes UIKit input directly;
neither XCTest nor the existing network device backend supplies test input.

## Hardware and recovery

- Designated iPhone 14 Pro, iOS 26.5.2, App minimum iOS 26.0.
- ESP32-C3 with 8 MiB Flash, connected to the Mac for power, programming and
  diagnostics. Phone-to-board control uses BLE, not this USB connection.
- A new complete 8 MiB backup was read and checked against the board's Flash
  MD5 before switching. The original factory backup is also retained privately.
- The BLE partition table matches the current board byte for byte. Only the
  application at `0x20000` was written and verified; the existing bootloader,
  partition table, NVS and private Wi-Fi configuration were not erased.
- Final BLE image: 533024 bytes, SHA-256
  `0d33be29fa998dd5dc7b83b8008663ecac72362de0c094844a06a1d863b33192`.
- Existing Wi-Fi image remains available for application-only restoration:
  SHA-256 `f9b5d78afdc66ff09bc938c8d1f74a23c9c250d302f229dd1d4f98db5545244b`.
- Firmware startup reports no Wi-Fi initialization. Observed initial free heap:
  224080 bytes. This is a startup observation, not a runtime stress measurement.

## Observed results

1. The App discovered the custom GATT service, connected, and completed a
   system-approved encrypted bond. The system separately subscribed to the
   keyboard and mouse HID reports on the same physical connection.
2. Three separate App launches each generated a fresh 12-digit ASCII nonce and
   sent individual keyboard reports. Actual `UITextField.editingChanged`
   observations matched the complete nonce every time.
3. All three launches accessed Apple's HTTPS connectivity page with HTTP 200 using
   an ephemeral URLSession with cellular access disabled. The network monitor
   reported Wi-Fi before and after the request. No user model credentials were
   used. This proves Internet reachability for that endpoint, not every model
   provider or VPN combination.
4. The physical HID connection survived an App restart. The second launch
   continued request IDs from 16 instead of resetting to 1; it completed
   without repeat pairing. Counters are persisted per peripheral before writes.
5. The initial pointer check emitted a relative movement report but UIKit did
   not deliver a hover position. No click was sent in these two runs; their
   result is `partial_pass`, with keyboard/Internet independently verified.
   The user confirmed AssistiveTouch was enabled with a visible floating button,
   while `UIAccessibility.isAssistiveTouchRunning` reported false. That mismatch
   is not treated as proof that the user has disabled the feature.

6. An explicitly opted-in `--ble-pointer-coverage-check` run then covered the
   fixture's safe area with one harmless button. After verifying stable layout
   and foreground state, it sent exactly one mouse click, without extra movement,
   edge calibration or click retries. UIKit observed one real `touchUpInside`
   event at `(196.67, 580)` in fixture-view points, inside the target. The event's
   touch type was `direct` (`0`), consistent with the system's AssistiveTouch
   path; this is not a claim that iPhone supplies iPad-style pointer hover.
   The user had been asked not to touch the screen during this check.
7. The final run reported `state=passed`, `textVerified=true`,
   `clickVerified=true`, `observedClickCount=1`, and `internetHTTPStatus=200`.
   STOP acknowledged release reports, and the App disconnected its GATT client.
   System HID may retain its connection. `absoluteCoordinatesVerified=false`:
   a click received by a full-area target does not establish calibrated targeting.

The three-run result establishes BLE keyboard and mouse-click delivery alongside
Wi-Fi Internet on this phone. A GATT response alone only reports that firmware
queued HID reports, never that the phone performed an action. The independent
UIKit callback and matching nonce are the action evidence.

## Verification and boundaries

- ESP-IDF 5.5.3 ESP32-C3 build passed.
- Signed iPhone Debug and Release builds passed; Debug installed successfully.
- String catalogs and property lists validated; new permission and fixture
  strings use English and Simplified Chinese string catalogs.
- Cross-review addressed interrupted key release, required Battery Service,
  request ID persistence across App restarts, and bond overflow without silently
  deleting the previous paired device.
- Firmware fixed battery level 100 is an explicitly documented USB-powered
  experiment placeholder, not measured battery charge.
- HID keyboard tests cover ASCII digits only. Chinese/Unicode, calibrated
  coordinate clicks, scrolling, Home, other Apps, background execution and
  ReplayKit/Agent integration are not established by these observations.

The final fixture run remains on the test phone for inspection. Its entry is
available only through explicit Debug launch arguments; an ordinary launch still
opens the normal App. The board remains on the BLE experiment firmware, so its
former Wi-Fi relay is unavailable until that saved application image is restored.

Private reports and backups remain under `.build/ble-validation` and
`.build/board-backups`, excluded from Git. No pairing keys, Wi-Fi credentials,
user API keys, screen images or original Flash contents belong in this document.
