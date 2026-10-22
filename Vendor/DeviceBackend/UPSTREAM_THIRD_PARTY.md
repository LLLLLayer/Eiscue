# Source origins and retained notices

## Current implementation

Eiscue maintains the Swift bridge, Rust connection workers, transport adapters,
session orchestration, media receiver and decoder queue in this directory. The
2026 replacement does not depend on an actell package or binary. The owned XCTest
Objective-C bridge, USB bootstrap, media diagnostics and scoped cleanup were
already Eiscue additions and remain part of this implementation.

This is a replacement of the control implementation, not a claim of clean-room
provenance or a license change. Stable C ABI structures and constants, small
compatibility/data wrappers, the IPv4 interface-scope workaround, and regression
fixtures remain adapted from the previous backend. GPL notices are retained.
The combined backend continues under [GPL-3.0-only](LICENSE).

## Protocol library

- [idevice](https://github.com/jkcoxson/idevice), revision
  `a64b8867815b3da17b5c927531bdba877e8456ef`, MIT.
- [Device Hub](https://github.com/JaviSoto/device-hub-ios), revision
  `1fcdfb0a6799b62f05625d0cbb359bec57256b94`, supplies the MIT protocol patch and
  PNG validator. Its patch SHA-256 is
  `6654ef68a966f5a05e04470d08871e1f70f5b4747eb4d5865b6fcb2ea32d00bd`.
- License copies: [idevice](rust/vendor/idevice/LICENSE.txt) and
  [Device Hub](rust/DEVICE_HUB_LICENSE).
- Eiscue's feature closure, retained RSD lifetime, scoped stop request, app-list
  collection, HEVC footer handling, negotiation and RTCP adaptations are recorded
  against that independent MIT baseline in [SOURCE_MANIFEST.json](rust/SOURCE_MANIFEST.json).
  Eiscue's prior USB-trust, DTX and geometry adaptations remain recorded there.

## Historical compatibility source

The earlier backend was imported from
[actell](https://github.com/ja1chen/actell/tree/032864e2339da19ee13025c471f4cf1dfdf4c5cd)
at revision `032864e2339da19ee13025c471f4cf1dfdf4c5cd`, from
`ncm-dev/PhoneAgentNCM/Sources` and `ncm-dev/rust`. Its compatibility declarations,
small adapters and test fixtures retain this origin even though their production
control implementation has been replaced. The source manifest distinguishes
reimplemented bodies from retained compatibility material.

[Original actell third-party notices](UPSTREAM_ACTELL_NOTICES.md) are preserved
verbatim as historical attribution. References there to firmware, research files
or directories describe that upstream project, not additional files or build
dependencies of this backend. No real pairing records, captured device data,
Apple DDI or private framework binaries are distributed here. The TLS identities
under `rust/tests/fixtures/lockdown` are public synthetic test fixtures.
