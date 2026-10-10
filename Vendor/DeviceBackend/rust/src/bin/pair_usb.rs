// SPDX-License-Identifier: GPL-3.0-only
//! Explicit USB bootstrap for Eiscue's own RemotePairing identity.
//! Reuses only the selected device's system USB trust, never another app's
//! RemotePairing record. No tracing subscriber or raw protocol errors are used.

#[cfg(not(unix))]
compile_error!("eiscue-pair-usb currently requires macOS or Linux for 0600 output files");

use idevice::{
    IdeviceService, ReadWrite,
    pairing_file::PairingFile,
    provider::{IdeviceProvider, UsbmuxdProvider},
    remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket, VerifiedPeerIdentity},
    services::lockdown::LockdownClient,
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdDevice},
};
use serde::Serialize;
use std::{
    ffi::OsString,
    fs::{self, File, OpenOptions},
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::ExitCode,
    time::Duration,
};
use zeroize::Zeroizing;

const SERVICE: &str = "com.apple.dt.remotepairingdeviced.lockdown";
const WIRELESS_DOMAIN: &str = "com.apple.mobile.wireless_lockdown";
type RemoteClient = RemotePairingClient<RpPairingSocket<Box<dyn ReadWrite>>>;
type Result<T> = std::result::Result<T, Failure>;

#[derive(Debug, PartialEq, Eq)]
struct Options {
    udid: String,
    output: PathBuf,
    enable_wifi: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Failure(&'static str);

fn main() -> ExitCode {
    // Dependencies may panic with remote content. Never forward panic payloads.
    std::panic::set_hook(Box::new(|_| {
        eprintln!(
            "USB pairing stopped because of an internal error. Check the output file before retrying."
        )
    }));
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    if args == [OsString::from("--help")] || args == [OsString::from("-h")] {
        println!(
            "Usage: eiscue-pair-usb --udid <USB-UDID> --output <new-file.json> [--enable-wifi]\n\
                  Creates a NEW Eiscue RemotePairing identity through existing system USB trust.\n\
                  Output is verified, mode 0600, and never overwrites an existing file.\n\
                  --enable-wifi explicitly enables this device's Wi-Fi Lockdown connections.\n\
                  Keep the selected device unlocked; trust this computer in Finder/Xcode first."
        );
        return ExitCode::SUCCESS;
    }
    let result = std::panic::catch_unwind(|| {
        let options = parse_options(args)?;
        let output = PreparedOutput::create(&options.output)?;
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|_| Failure("Could not start the pairing runtime."))?;
        let verified = runtime.block_on(async {
            tokio::time::timeout(Duration::from_secs(120), bootstrap(&options)).await
                .map_err(|_| Failure("USB pairing timed out. Keep the device unlocked and check USB trust. No record was exported."))?
        })?;
        output.commit(&verified.record)?;
        println!("Eiscue pairing identity exported successfully (file permissions 0600).");
        println!(
            "Verified USB device: {}; RemotePairing peer: {}, model={}; Pair Setup signature and fresh Pair Verify passed.",
            options.udid, verified.peer_udid, verified.model
        );
        if options.enable_wifi {
            println!("Wi-Fi Lockdown connections are enabled on the selected device.");
        }
        Ok::<_, Failure>(())
    });
    match result {
        Ok(Ok(())) => ExitCode::SUCCESS,
        Ok(Err(error)) => {
            eprintln!("{}", error.0);
            ExitCode::FAILURE
        }
        Err(_) => ExitCode::FAILURE,
    }
}

fn parse_options(args: Vec<OsString>) -> Result<Options> {
    let mut udid = None;
    let mut output = None;
    let mut enable_wifi = false;
    let mut iter = args.into_iter();
    while let Some(argument) = iter.next() {
        match argument.to_str() {
            Some("--udid") if udid.is_none() => {
                let value = iter
                    .next()
                    .and_then(|x| x.into_string().ok())
                    .ok_or(Failure(
                        "--udid requires an explicit USB device identifier.",
                    ))?;
                if !(16..=64).contains(&value.len())
                    || !value.bytes().all(|c| c.is_ascii_hexdigit() || c == b'-')
                {
                    return Err(Failure(
                        "The USB device identifier must contain only hexadecimal digits and hyphens.",
                    ));
                }
                udid = Some(value);
            }
            Some("--output") if output.is_none() => {
                let value = iter
                    .next()
                    .ok_or(Failure("--output requires a new file path."))?;
                if value.is_empty() || value.to_string_lossy().starts_with("--") {
                    return Err(Failure("--output requires a new file path."));
                }
                output = Some(PathBuf::from(value));
            }
            Some("--enable-wifi") if !enable_wifi => enable_wifi = true,
            _ => {
                return Err(Failure(
                    "Unknown or repeated argument. Use --help for the required --udid and --output options.",
                ));
            }
        }
    }
    Ok(Options {
        udid: udid.ok_or(Failure(
            "An explicit --udid is required; automatic device selection is not allowed.",
        ))?,
        output: output.ok_or(Failure("An explicit --output path is required."))?,
        enable_wifi,
    })
}

fn select_device(devices: Vec<UsbmuxdDevice>, udid: &str) -> Result<UsbmuxdDevice> {
    let mut selected = devices.into_iter().filter(|device| {
        device.udid.eq_ignore_ascii_case(udid) && device.connection_type == Connection::Usb
    });
    let device = selected.next().ok_or(Failure(
        "The selected device is not connected over USB. No other device was selected.",
    ))?;
    if selected.next().is_some() {
        return Err(Failure(
            "More than one USB device matched the identifier. Pairing was not started.",
        ));
    }
    Ok(device)
}

struct VerifiedExport {
    record: Zeroizing<Vec<u8>>,
    model: String,
    peer_udid: String,
}

async fn bootstrap(options: &Options) -> Result<VerifiedExport> {
    // Intentionally ignore USBMUXD_SOCKET_ADDRESS: only the computer's local
    // system daemon may supply USB trust for this explicitly selected device.
    let address = UsbmuxdAddr::UnixSocket(UsbmuxdAddr::SOCKET_FILE.to_owned());
    let mut mux = address
        .connect(1)
        .await
        .map_err(|_| Failure("Could not connect to the local usbmuxd service."))?;
    let devices = mux
        .get_devices()
        .await
        .map_err(|_| Failure("Could not enumerate USB devices."))?;
    let device = select_device(devices, &options.udid)?;
    let provider = UsbmuxdProvider {
        addr: address,
        tag: 1,
        udid: device.udid,
        device_id: device.device_id,
        label: "Eiscue USB bootstrap".to_owned(),
    };
    // This is the operating system's existing USB trust for this UDID only.
    // No remote-pairing cache is read, imported, replaced or shared.
    let trust = provider.get_pairing_file().await.map_err(|_| Failure("System USB trust is unavailable. Unlock the selected device and trust this computer in Finder or Xcode first."))?;
    let (mut client, mut lockdown) = open_client(&provider, &trust, &options.udid).await?;
    if options.enable_wifi {
        lockdown
            .set_value(
                "EnableWifiConnections",
                plist::Value::Boolean(true),
                Some(WIRELESS_DOMAIN),
            )
            .await
            .map_err(|_| {
                Failure("Could not enable Wi-Fi Lockdown connections on the selected device.")
            })?;
        let enabled = lockdown
            .get_value(Some("EnableWifiConnections"), Some(WIRELESS_DOMAIN))
            .await
            .map_err(|_| Failure("Could not verify the Wi-Fi Lockdown connection setting."))?;
        if enabled.as_boolean() != Some(true) {
            return Err(Failure(
                "The device did not confirm Wi-Fi Lockdown connections were enabled.",
            ));
        }
    }
    let mut controller = RpPairingFile::generate(&format!("Eiscue-USB-{}", uuid::Uuid::new_v4()));
    client.begin_new_pairing_over_trusted_usb().await.map_err(|_| Failure("The USB RemotePairing first-pairing negotiation failed. Keep the device unlocked and check Developer Mode. No identity was exported."))?;
    // Trusted USB pair-setup uses the protocol's fixed consent code; it does
    // not use the iOS 27 device-initiated Settings/PIN flow.
    client
        .pair(&mut controller, || async { "000000".to_owned() })
        .await
        .map_err(|_| Failure("USB RemotePairing Pair Setup failed. No identity was exported."))?;
    let peer = client
        .paired_peer_device()
        .map_err(|_| Failure("The device did not provide a verified pairing identity."))?
        .clone();
    validate_peer(&peer)?;
    drop(client);
    let _ = tokio::time::timeout(Duration::from_secs(3), lockdown.stop_session()).await;
    drop(lockdown);

    // A successful setup alone is not enough: reconnect and verify the new
    // identity against the same signed peer before marking our record committed.
    let (mut verifier, mut lockdown) = open_client(&provider, &trust, &options.udid).await?;
    verifier
        .connect_paired(&mut controller, &peer)
        .await
        .map_err(|_| {
            Failure("Fresh Pair Verify failed. The generated identity was not exported.")
        })?;
    drop(verifier);
    let _ = tokio::time::timeout(Duration::from_secs(3), lockdown.stop_session()).await;
    let record = encode_record(&controller, &peer)?;
    Ok(VerifiedExport {
        record,
        model: peer.peer.model.clone(),
        peer_udid: peer.peer.remotepairing_udid.clone(),
    })
}

async fn open_client(
    provider: &UsbmuxdProvider,
    trust: &PairingFile,
    expected_udid: &str,
) -> Result<(RemoteClient, LockdownClient)> {
    let mut lockdown = LockdownClient::connect(provider)
        .await
        .map_err(|_| Failure("Could not open USB Lockdown for the selected device."))?;
    let legacy = lockdown.start_session(trust).await.map_err(|_| Failure("The selected device did not accept this computer's USB trust. Unlock it and check Finder/Xcode."))?;
    let actual = lockdown
        .get_value(Some("UniqueDeviceID"), None)
        .await
        .map_err(|_| Failure("Could not verify the connected USB device identifier."))?;
    if !actual
        .as_string()
        .is_some_and(|value| value.eq_ignore_ascii_case(expected_udid))
    {
        return Err(Failure(
            "The authenticated USB device does not match --udid. Pairing was stopped.",
        ));
    }
    let (port, ssl) = lockdown.start_service(SERVICE).await.map_err(|_| Failure("The USB RemotePairing service is unavailable. Keep the device unlocked and enable Developer Mode."))?;
    let mut connection = provider.connect(port).await.map_err(|_| {
        Failure("Could not connect to the selected device's USB RemotePairing service.")
    })?;
    if ssl {
        connection
            .start_session(trust, legacy)
            .await
            .map_err(|_| Failure("USB RemotePairing service TLS failed."))?;
    }
    let socket = connection
        .get_socket()
        .ok_or(Failure("USB RemotePairing did not provide a transport."))?;
    Ok((
        RemotePairingClient::new(RpPairingSocket::new(socket), "Eiscue"),
        lockdown,
    ))
}

fn validate_peer(peer: &VerifiedPeerIdentity) -> Result<()> {
    // RemotePairing identifiers and USB UniqueDeviceID are separate namespaces.
    // Preserve the actual peer value. The two authenticated USB service opens
    // above bind it to the selected physical device; Pair Verify binds its key.
    if peer.peer.alt_irk.len() != 16
        || peer.long_term_public_key == [0; 32]
        || peer.pairing_identifier.is_empty()
        || peer.pairing_identifier.len() > 256
        || peer.pairing_identifier.contains('\0')
        || peer.peer.model.is_empty()
        || peer.peer.model.len() > 64
        || !peer
            .peer
            .model
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b",._-".contains(&c))
        || peer.peer.remotepairing_udid.is_empty()
        || peer.peer.remotepairing_udid.len() > 256
        || !peer
            .peer
            .remotepairing_udid
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
    {
        return Err(Failure(
            "The signed peer identity is incomplete or invalid. No identity was exported.",
        ));
    }
    Ok(())
}

#[derive(Serialize)]
struct ExportRecord<'a> {
    version: u8,
    seed: &'a [u8],
    #[serde(rename = "controllerID")]
    controller_id: &'a str,
    #[serde(rename = "peerID")]
    peer_id: &'a str,
    #[serde(rename = "peerPublicKey")]
    peer_public_key: &'a [u8],
    #[serde(rename = "alternateIRK")]
    alternate_irk: &'a [u8],
    #[serde(rename = "peerUDID")]
    peer_udid: &'a str,
    #[serde(rename = "peerModel")]
    peer_model: &'a str,
    committed: bool,
}

fn encode_record(
    controller: &RpPairingFile,
    peer: &VerifiedPeerIdentity,
) -> Result<Zeroizing<Vec<u8>>> {
    validate_peer(peer)?;
    let seed = Zeroizing::new(controller.private_key_bytes());
    let record = ExportRecord {
        version: 1,
        seed: &seed,
        controller_id: &controller.identifier,
        peer_id: &peer.pairing_identifier,
        peer_public_key: &peer.long_term_public_key,
        alternate_irk: &peer.peer.alt_irk,
        peer_udid: &peer.peer.remotepairing_udid,
        peer_model: &peer.peer.model,
        committed: true,
    };
    serde_json::to_vec(&record)
        .map(Zeroizing::new)
        .map_err(|_| Failure("Could not encode the verified Eiscue pairing record."))
}

/// An owned private temporary file reserves write access before USB pairing.
/// The final path appears only after a full fsync; hard_link cannot overwrite an
/// existing file or symlink. No unfinished identity is published to --output.
struct PreparedOutput {
    destination: PathBuf,
    temporary: PathBuf,
    file: File,
    directory: File,
}

impl PreparedOutput {
    fn create(destination: &Path) -> Result<Self> {
        if destination.file_name().is_none() {
            return Err(Failure(
                "--output must name a new file in an existing directory.",
            ));
        }
        match fs::symlink_metadata(destination) {
            Ok(_) => {
                return Err(Failure(
                    "The output path already exists. Existing files and symlinks are never replaced.",
                ));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(Failure("The output path could not be checked.")),
        }
        let parent = destination
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        let directory =
            File::open(parent).map_err(|_| Failure("The output directory could not be opened."))?;
        let temporary = parent.join(format!(".eiscue-pairing-{}.tmp", uuid::Uuid::new_v4()));
        let file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)
            .map_err(|_| Failure("Could not create a private output file. Check the output directory and permissions."))?;
        let prepared = Self {
            destination: destination.to_owned(),
            temporary,
            file,
            directory,
        };
        prepared
            .file
            .set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(|_| Failure("Could not secure output permissions."))?;
        Ok(prepared)
    }

    fn commit(mut self, data: &[u8]) -> Result<()> {
        self.file
            .write_all(data)
            .and_then(|_| self.file.sync_all())
            .map_err(|_| Failure("Could not save the complete pairing record."))?;
        fs::hard_link(&self.temporary, &self.destination).map_err(|_| Failure("Could not publish the record without overwriting an existing path. No existing file was changed."))?;
        fs::remove_file(&self.temporary).map_err(|_| Failure("The private output was saved, but temporary file cleanup failed. Check the output before retrying."))?;
        self.directory.sync_all().map_err(|_| Failure("The private output was saved, but directory durability could not be confirmed. Check the output before retrying."))?;
        Ok(())
    }
}

impl Drop for PreparedOutput {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.temporary);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use idevice::remote_pairing::PeerDevice;
    const UDID: &str = "00000000-0000000000000000";
    fn args(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }
    fn device(connection_type: Connection, udid: &str) -> UsbmuxdDevice {
        UsbmuxdDevice {
            connection_type,
            udid: udid.to_owned(),
            device_id: 1,
        }
    }
    fn peer() -> VerifiedPeerIdentity {
        VerifiedPeerIdentity {
            pairing_identifier: "SYNTHETIC-PEER".to_owned(),
            long_term_public_key: [0x42; 32],
            peer: PeerDevice {
                account_id: "SYNTHETIC-PEER".to_owned(),
                alt_irk: vec![0x33; 16],
                model: "iPhone15,2".to_owned(),
                name: "SYNTHETIC".to_owned(),
                remotepairing_udid: UDID.to_owned(),
            },
        }
    }
    #[test]
    fn arguments_require_explicit_selection_and_destination() {
        assert!(parse_options(args(&[])).is_err());
        assert!(parse_options(args(&["--udid", UDID])).is_err());
        assert!(parse_options(args(&["--output", "file.json"])).is_err());
        assert!(
            parse_options(args(&[
                "--udid",
                UDID,
                "--output",
                "file.json",
                "--udid",
                UDID
            ]))
            .is_err()
        );
        assert!(
            parse_options(args(&["--udid", "private\ntext", "--output", "file.json"])).is_err()
        );
        let parsed = parse_options(args(&[
            "--udid",
            UDID,
            "--output",
            "file.json",
            "--enable-wifi",
        ]))
        .unwrap();
        assert_eq!(parsed.udid, UDID);
        assert!(parsed.enable_wifi);
    }
    #[test]
    fn never_falls_back_to_another_device_or_network_transport() {
        assert!(select_device(vec![device(Connection::Usb, "other")], UDID).is_err());
        assert!(
            select_device(
                vec![device(
                    Connection::Network("127.0.0.1".parse().unwrap()),
                    UDID
                )],
                UDID
            )
            .is_err()
        );
        assert!(
            select_device(
                vec![device(Connection::Usb, UDID), device(Connection::Usb, UDID)],
                UDID
            )
            .is_err()
        );
        assert_eq!(
            select_device(
                vec![
                    device(Connection::Usb, "other"),
                    device(Connection::Usb, UDID)
                ],
                UDID
            )
            .unwrap()
            .udid,
            UDID
        );
    }
    #[test]
    fn export_schema_binds_the_verified_peer_and_never_prints_secrets() {
        let controller = RpPairingFile::generate("SYNTHETIC-OFFLINE-TEST");
        let peer = peer();
        let data = encode_record(&controller, &peer).unwrap();
        let value: serde_json::Value = serde_json::from_slice(&data).unwrap();
        assert_eq!(value["version"], 1);
        assert_eq!(value["committed"], true);
        assert_eq!(value["peerUDID"], UDID);
        assert_eq!(value["peerID"], "SYNTHETIC-PEER");
        assert_eq!(value["seed"].as_array().unwrap().len(), 32);
        assert_eq!(value["peerPublicKey"].as_array().unwrap().len(), 32);
        assert_eq!(value["alternateIRK"].as_array().unwrap().len(), 16);
        let mut distinct_remote_id = peer.clone();
        distinct_remote_id.peer.remotepairing_udid =
            "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF".to_owned();
        let remote_data = encode_record(&controller, &distinct_remote_id).unwrap();
        let remote_value: serde_json::Value = serde_json::from_slice(&remote_data).unwrap();
        assert_eq!(
            remote_value["peerUDID"],
            distinct_remote_id.peer.remotepairing_udid
        );
        let mut malformed = peer.clone();
        malformed.peer.alt_irk.clear();
        assert!(encode_record(&controller, &malformed).is_err());
        let mut malformed = peer;
        malformed.peer.model = "model\nforged-success".to_owned();
        assert!(encode_record(&controller, &malformed).is_err());
    }
    #[test]
    fn output_is_private_complete_and_never_overwrites_or_follows_links() {
        let directory =
            std::env::temp_dir().join(format!("eiscue-bootstrap-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&directory).unwrap();
        let output = directory.join("identity.json");
        let prepared = PreparedOutput::create(&output).unwrap();
        assert!(!output.exists());
        assert_eq!(
            prepared.file.metadata().unwrap().permissions().mode() & 0o777,
            0o600
        );
        prepared.commit(b"synthetic complete test data").unwrap();
        assert_eq!(fs::read(&output).unwrap(), b"synthetic complete test data");
        assert_eq!(
            fs::metadata(&output).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert!(PreparedOutput::create(&output).is_err());
        let link = directory.join("link.json");
        std::os::unix::fs::symlink(&output, &link).unwrap();
        assert!(PreparedOutput::create(&link).is_err());
        let race = directory.join("race.json");
        let prepared = PreparedOutput::create(&race).unwrap();
        fs::write(&race, b"existing user data").unwrap();
        assert!(prepared.commit(b"replacement").is_err());
        assert_eq!(fs::read(&race).unwrap(), b"existing user data");
        let abandoned = directory.join("abandoned.json");
        drop(PreparedOutput::create(&abandoned).unwrap());
        assert!(!abandoned.exists());
        assert!(fs::read_dir(&directory).unwrap().all(|entry| {
            !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".eiscue-pairing-")
        }));
        fs::remove_dir_all(directory).unwrap();
    }
}
