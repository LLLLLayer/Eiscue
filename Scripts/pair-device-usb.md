# USB pairing bootstrap

This desktop helper creates Eiscue's own RemotePairing identity for iOS 26. It
uses the selected device's existing system USB trust. The device must be
unlocked, have Developer Mode enabled, and already trust the computer in
Finder or Xcode. Rust 1.96.0 is required by the build script.

```sh
Scripts/pair-device-usb.sh --udid '<USB device UDID>' --output '<new file.json>'
```

Both arguments are required. The helper selects only the exact USB device,
uses the local system usbmuxd daemon, and times out after 120 seconds. It
prints fixed error summaries and the verified peer identifiers on success.
It never prints private keys or the complete record. The desktop host target
is explicit even when the environment defaults Cargo to an iOS build target.

The output is a complete version 1 Eiscue RemotePairRecord. Its temporary and
final files have permissions `0600`. Publishing uses an exclusive hard link,
so an existing destination or symlink is never replaced. File and directory
contents are synced. Import the output through Eiscue's pairing import flow;
treat it as a credential and keep it out of source control and logs.

`--enable-wifi` explicitly enables and reads back `EnableWifiConnections` in
the device's `com.apple.mobile.wireless_lockdown` domain. This option is
optional; the helper does not change wireless settings by default.

The `desktop-bootstrap` Cargo feature enables USB transport and pinned TLS.
Every Lockdown session and TLS-enabled RemotePairing service checks the
system trust record's DeviceCertificate and TLS handshake signature. The
selected USB UniqueDeviceID is checked on both service opens. The helper
then uses explicit first-pairing negotiation, validates the Pair Setup M6
signature, and requires Pair Verify on a new connection before export.
RemotePairing peer identifiers are preserved exactly and may differ from the
USB UDID. The iOS backend does not enable this desktop feature.

Offline verification:

```sh
CARGO_TARGET_DIR="$PWD/.build/device-rust-bootstrap" MACOSX_DEPLOYMENT_TARGET=14.0 \
  rustup run 1.96.0 cargo test --manifest-path Vendor/DeviceBackend/rust/Cargo.toml \
  --locked --workspace --features desktop-bootstrap --lib --bins
Scripts/pair-device-usb.sh --help
```

The tests use public synthetic certificates and in-memory transports. They
cover USB selection, schema, file permissions, no-overwrite behavior, TLS
certificate/signature rejection, and first-pairing message order. Physical
USB pairing and subsequent on-device networking still require device testing.
