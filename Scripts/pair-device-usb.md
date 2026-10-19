# USB pairing bootstrap

## Guided setup on a Mac

The app's connection page lists five steps: prepare the Mac, connect by USB, run the command, import pairing, and connect the device. The command is shown in a code block with a **Copy command** button. It copies the full source-download and setup command below, which works from **any folder** in Mac Terminal:

```sh
eiscue_setup_dir="$(mktemp -d -t eiscue-setup)" &&
git clone --depth 1 https://github.com/LLLLLayer/Eiscue.git "$eiscue_setup_dir" &&
python3 "$eiscue_setup_dir/Scripts/setup-device.py" --app-pairing-schema 1
```

This uses a new temporary checkout, leaving existing folders untouched. Source and build caches remain there; the helper cleans up its separate private identity file. If you already have a complete source checkout, you can instead run `python3 Scripts/setup-device.py` from its project root.

Use the command copied from the installed app: it declares the pairing format
that app accepts. Before accessing devices, the wrapper checks the exporter's
public format capabilities and selects a compatible version. It also checks the
generated file's version before sending it. An older command without this
option continues to request the original raw version 1 record. Incompatible
versions stop with an update instruction; they are never sent automatically.

The Mac needs Xcode 26 or newer selected as its active developer directory,
Python 3.9 or newer, and the Rust 1.96.0 toolchain already installed through
rustup. The command does not install these tools or change the default Rust
toolchain. The first build can download the project's locked Cargo dependencies
and may take several minutes. This guided command is macOS-only.

Before running it:

1. Install and open Eiscue on the iPhone or iPad.
2. Connect the device to the Mac with a USB data cable and keep it unlocked.
   Trust this computer in Finder or Xcode if the device asks.
3. Enable Developer Mode in the device's Settings > Privacy & Security.
4. Select the device in Xcode > Window > Devices and Simulators and finish its
   developer preparation. The helper checks that Developer Disk Image (DDI)
   services are available; **it does not download, personalize or mount DDI**.

The command lists only physical iPhones/iPads with a current wired connection.
Enter the intended device's number, even when only one is listed, then confirm
its name and USB identifier. It verifies the developer environment and access
to that device's installed Eiscue container before creating an identity. It
explicitly enables Wi-Fi developer connections, generates a new identity using
the USB helper below, and sends it to the **same selected device** at
`org.eiscue.app`'s `tmp/EiscuePairingTransfer.json`.

Eiscue detects the received file while the connection page is open. Choose **Import from computer** on that page. The command does not launch the app, automatically
import an identity, start XCTest or connect a VPN. After importing, choose
**Connect** (**Connect device** during onboarding) in the app and handle any system authorization there.

An existing pending transfer is not replaced. Import it on the device first,
or resolve it in the app, before retrying. The command never reads or modifies
other apps' pairing identities or the Mac's Keychain. Its temporary directory
is private (`0700`), and the generated identity must be an owned regular file
with `0600` permissions. The Mac's temporary file is removed after success,
failure or Ctrl-C. If transfer was interrupted, check the app for a pending
import before retrying; it may have received the file even when the Mac did
not confirm success. The app removes the transferred file when importing it.
Neither the identity's contents nor subprocess diagnostics are printed.

Offline helper checks (fake commands only; no device, Keychain or network):

```sh
python3 Scripts/setup-device.py --help
python3 -m unittest discover -s Scripts/Tests -p test_setup_device.py -v
```

## Direct export for manual use

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

`--identity-schema-version 1` explicitly requests this format; omitting it keeps
the same legacy default. Unknown requested versions are rejected before Cargo
or device access. `Scripts/pair-device-usb.sh --describe-format` prints only
public JSON format metadata, without building or accessing a device. The app
continues to import version 1 JSON and plist records. An unknown format is
rejected before replacing the saved identity; the consumed temporary transfer
is still removed.

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
