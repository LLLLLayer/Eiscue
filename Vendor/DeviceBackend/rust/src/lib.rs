// SPDX-License-Identifier: GPL-3.0-only
//! Eiscue-owned session orchestration over the MIT idevice protocol clients.
//! Connectors supply all I/O. ABI types and regression fixtures are retained for
//! compatibility with the earlier backend; provenance is recorded separately.
mod ffi;
mod legacy_probe;
mod local_vpn;
mod media;
mod media_cleanup;
mod media_diagnostic;
mod relay;
mod video;
mod xctest_session;
pub use relay::RelayConnector;
pub mod lockdown;
mod png;
mod transport;
pub use idevice::remote_pairing::{RpPairingFile, VerifiedPeerIdentity};
use idevice::{
    RemoteXpcClient, RsdService,
    core_device::{
        AppServiceClient, ButtonState, HardwareButton, ImageFormat, IndigoHidClient,
        PasteboardServiceClient, ScreenCaptureServiceClient,
    },
    remote_pairing::{RemotePairingClient, RpPairingSocket, connect_tls_psk_tunnel_native},
    rsd::RsdHandshake,
    services::mobile_image_mounter::ImageMounter,
    tcp::{
        adapter::Adapter,
        handle::{AdapterHandle, StreamHandle},
    },
};
use std::{future::Future, net::Ipv6Addr, time::Duration};
pub use transport::{DialFuture, NcmConnector, Purpose, Stream};
use transport::{Gated, OperationGuard, Owner};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Stage {
    Identity,
    NcmConnect,
    PairVerify,
    TunnelListener,
    TlsTunnel,
    Rsd,
    DeveloperMode,
    DeveloperImage,
    Screenshot,
    Media,
    Input,
    Closed,
    VideoReceiver,
    VideoService,
    VideoNegotiation,
    VideoAnswer,
    VideoPackets,
    TouchService,
    ScreenshotConnection,
    ScreenshotResponse,
    Applications,
    LegacyInstrumentsConnection,
    LegacyInstrumentsHandshake,
    LegacyScreenshotChannel,
    LegacyScreenshotResponse,
    LegacyTestmanagerConnection,
    LegacyTestmanagerHandshake,
    XCTestControlConnection,
    XCTestMainConnection,
    XCTestControlHandshake,
    XCTestMainHandshake,
    XCTestControlChannel,
    XCTestMainChannel,
    XCTestControlInit,
    XCTestMainInit,
    XCTestAuthorize,
    XCTestStop,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Cause {
    Protocol,
    Timeout,
    InvalidParameters,
    MissingService,
    Unprepared,
    MediaInactive,
    DeliveryUncertain,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Error {
    pub stage: Stage,
    pub cause: Cause,
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}/{:?}", self.stage, self.cause)
    }
}
impl std::error::Error for Error {}
pub(crate) fn valid_input_text(text: &str) -> bool {
    // Bytes, not scalar or grapheme count, bound the transport payload.
    (1..=8192).contains(&text.len()) && !text.as_bytes().contains(&0)
}
fn error(stage: Stage, cause: Cause) -> Error {
    Error { stage, cause }
}
async fn bounded<T, E>(stage: Stage, work: impl Future<Output = Result<T, E>>) -> Result<T, Error> {
    bounded_for(stage, Duration::from_secs(15), work).await
}
async fn bounded_for<T, E>(
    stage: Stage,
    budget: Duration,
    work: impl Future<Output = Result<T, E>>,
) -> Result<T, Error> {
    // Timeout is a separate protocol outcome, never an invitation to retry.
    match tokio::time::timeout(budget, work).await {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(_)) => Err(error(stage, Cause::Protocol)),
        Err(_) => Err(error(stage, Cause::Timeout)),
    }
}
/// Only already-authorized, in-memory RemotePairing identities. Caller retains
/// original identifier/keys/peer binding. There is no Pair Setup or persistence.
pub struct ExistingIdentity {
    pub controller: RpPairingFile,
    pub peer: VerifiedPeerIdentity,
}
impl ExistingIdentity {
    fn validate(&self) -> Result<(), Error> {
        let invalid = error(Stage::Identity, Cause::InvalidParameters);
        // Audit each ownership boundary independently before opening any I/O.
        // The controller must own its signing key, and its remembered binding
        // must agree with the expected peer rather than a newly discovered peer.
        let controller = &self.controller;
        if !(1..=256).contains(&controller.identifier.len()) {
            return Err(invalid);
        }
        if controller.e_private_key.verifying_key().to_bytes() != controller.e_public_key.to_bytes()
        {
            return Err(invalid);
        }
        let peer = &self.peer;
        for required in [
            &peer.pairing_identifier,
            &peer.peer.remotepairing_udid,
            &peer.peer.model,
        ] {
            if required.is_empty() {
                return Err(invalid);
            }
        }
        let Some(binding) = controller.alt_irk.as_ref() else {
            return Err(invalid);
        };
        if peer.peer.alt_irk.len() == 16 && binding == &peer.peer.alt_irk {
            Ok(())
        } else {
            Err(invalid)
        }
    }
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Service {
    pub name: String,
    pub port: u16,
    pub remote_xpc: bool,
}
pub struct Screenshot {
    pub png: Vec<u8>,
    pub width: u32,
    pub height: u32,
}
/// Transport evidence, explicitly not evidence of visible UIKit effects.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TouchDelivery {
    ReportsWrittenVisualEffectUnverified,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloseReport {
    OwnedTransportRevokedRemoteMediaStopUnconfirmed,
}

pub struct Session {
    owner: Owner,
    _control: Option<RemotePairingClient<RpPairingSocket<Gated>>>,
    adapter: AdapterHandle,
    handshake: RsdHandshake,
    _rsd_control: Option<RemoteXpcClient<StreamHandle>>,
    prepared: bool,
    media: Option<media::Media>,
    media_release: media::ReleaseState,
    media_cleanup: media_cleanup::Shared,
    xctest: Option<xctest_session::OwnedXCTestSession>,
    indigo: Option<IndigoHidClient<Box<dyn idevice::ReadWrite>>>,
    video: std::sync::Arc<video::VideoMailbox>,
    valid: bool,
}
/// Guard only the effect-bearing portion of a request. Losing this future closes
/// the transport generation; no caller can reuse it to retry an uncertain input.
async fn input_transaction<T>(
    owner: &Owner,
    work: impl Future<Output = Result<T, Error>>,
) -> Result<T, Error> {
    let mut pending = OperationGuard(Some(owner.0.clone()));
    let result = work.await;
    if result.is_ok() {
        pending.0 = None;
    }
    result
}

impl Session {
    pub async fn connect(
        connector: &impl NcmConnector,
        identity: &mut ExistingIdentity,
    ) -> Result<Self, Error> {
        identity.validate()?;
        let owner = Owner::default();
        let mut control = authenticate_controller(connector, identity, &owner).await?;
        let port = bounded(Stage::TunnelListener, control.create_tcp_listener()).await?;
        if port == 0 {
            return Err(error(Stage::TunnelListener, Cause::InvalidParameters));
        }
        let stream = bounded(
            Stage::NcmConnect,
            connector.connect(Purpose::NegotiatedTunnel { port }),
        )
        .await?;
        let tunnel = bounded(
            Stage::TlsTunnel,
            connect_tls_psk_tunnel_native(
                Gated::new(stream, owner.0.clone()),
                control.encryption_key(),
            ),
        )
        .await?;
        let (host, peer, rsd_port, mss) = tunnel_parameters(&tunnel.info)?;
        let mut engine = Adapter::new(Box::new(tunnel.into_inner()), host.into(), peer.into());
        engine.set_mss(mss);
        let mut adapter = engine.to_async_handle();
        let socket = bounded(Stage::Rsd, adapter.connect(rsd_port)).await?;
        let (handshake, retained) = bounded(Stage::Rsd, RsdHandshake::new_retained(socket)).await?;
        verify_rsd_identity(&handshake, &identity.peer)?;
        Ok(Self {
            owner,
            _control: Some(control),
            adapter,
            handshake,
            _rsd_control: Some(retained),
            prepared: false,
            media: None,
            media_release: Default::default(),
            media_cleanup: Default::default(),
            xctest: None,
            indigo: None,
            video: Default::default(),
            valid: true,
        })
    }
    fn check(&self) -> Result<(), Error> {
        match (self.valid, self.owner.0.is_closed()) {
            (true, false) => Ok(()),
            _ => Err(error(Stage::Closed, Cause::Unprepared)),
        }
    }
    fn advertised(&self, name: &str) -> bool {
        self.handshake
            .services
            .get(name)
            .is_some_and(|service| service.port > 0 && service.uses_remote_xpc)
    }
    fn require(&self, name: &str, stage: Stage) -> Result<(), Error> {
        self.check()?;
        if !self.prepared {
            return Err(error(stage, Cause::Unprepared));
        }
        if !self.advertised(name) {
            return Err(error(stage, Cause::MissingService));
        }
        Ok(())
    }
    async fn open_service<S: RsdService>(&mut self, stage: Stage) -> Result<S, Error> {
        bounded(
            stage,
            S::connect_rsd(&mut self.adapter, &mut self.handshake),
        )
        .await
    }
    pub fn services(&self) -> Result<Vec<Service>, Error> {
        self.check()?;
        let mut result = Vec::with_capacity(self.handshake.services.len());
        for (name, entry) in &self.handshake.services {
            result.push(Service {
                name: name.clone(),
                port: entry.port,
                remote_xpc: entry.uses_remote_xpc,
            });
        }
        result.sort_unstable_by(|a, b| a.name.cmp(&b.name));
        Ok(result)
    }
    pub async fn check_developer_readiness(&mut self) -> Result<(), Error> {
        self.check()?;
        self.prepared = false;
        let mut mounter: ImageMounter = self.open_service(Stage::DeveloperImage).await?;
        let enabled = bounded(Stage::DeveloperMode, mounter.query_developer_mode_status()).await?;
        if !enabled {
            return Err(error(Stage::DeveloperMode, Cause::Unprepared));
        }
        let mounted = bounded(
            Stage::DeveloperImage,
            mounter.image_is_present("Personalized"),
        )
        .await?;
        if !mounted {
            return Err(error(Stage::DeveloperImage, Cause::Unprepared));
        }
        self.check()?;
        self.prepared = true;
        Ok(())
    }
    pub async fn screenshot(&mut self) -> Result<Screenshot, Error> {
        self.require(
            "com.apple.coredevice.screencaptureservice",
            Stage::Screenshot,
        )?;
        let mut capture: ScreenCaptureServiceClient<Stream> =
            self.open_service(Stage::ScreenshotConnection).await?;
        // Large PNG transfers have their own read-only budget. No input retry.
        let png = bounded_for(
            Stage::ScreenshotResponse,
            Duration::from_secs(90),
            capture.take_screenshot(None, ImageFormat::Png),
        )
        .await?;
        self.check()?;
        let dimensions =
            png::validate_png(&png).map_err(|_| error(Stage::Screenshot, Cause::Protocol))?;
        Ok(Screenshot {
            png,
            width: dimensions.width,
            height: dimensions.height,
        })
    }
    pub async fn start_touch_media(&mut self) -> Result<(), Error> {
        self.require("com.apple.coredevice.displayservice", Stage::Media)?;
        self.require("com.apple.coredevice.hid.universalhidservice", Stage::Input)?;
        if self.media.is_some() || !self.media_release.is_idle() {
            return Err(error(Stage::Media, Cause::InvalidParameters));
        }
        let media = Box::pin(media::Media::start(
            &mut self.adapter,
            &mut self.handshake,
            self.video.clone(),
            &mut self.media_release,
            &self.media_cleanup,
        ))
        .await?;
        self.check()?;
        self.media = Some(media);
        Ok(())
    }
    pub async fn stop_touch_media(&mut self) -> Result<(), Error> {
        self.check()?;
        // Stop frame publication immediately, but keep the original service
        // alive until its reply-bearing scoped stop completes (or is cancelled).
        let mut media = self.media.take();
        if let Some(media) = media.as_mut() {
            media.quiesce();
        }
        self.indigo.take();
        self.video.reset();
        let stopped = self
            .media_release
            .stop(&mut self.adapter, &mut self.handshake)
            .await;
        drop(media);
        stopped?;
        media_cleanup::set(&self.media_cleanup, media_cleanup::State::Idle)
    }
    async fn release_retained_media(
        &mut self,
        shared: &media_cleanup::Shared,
    ) -> Result<(), Error> {
        use idevice::core_device::DisplayServiceClient;
        self.check()?;
        if !self.advertised("com.apple.coredevice.displayservice") {
            return Err(error(Stage::Media, Cause::MissingService));
        }
        let status = bounded_for(Stage::Media, Duration::from_secs(3), async {
            let mut client =
                DisplayServiceClient::connect_rsd(&mut self.adapter, &mut self.handshake).await?;
            client.get_media_stream_server_status().await
        })
        .await?;
        self.check()?;
        media_cleanup::release_with(
            shared,
            || async { Ok(status) },
            |identifier| async move {
                let mut client: DisplayServiceClient<Stream> =
                    self.open_service(Stage::Media).await?;
                bounded(
                    Stage::Media,
                    client.stop_media_stream_identifiers(&[identifier]),
                )
                .await
            },
        )
        .await
    }
    pub async fn verify_video_geometry(&mut self) -> Result<bool, Error> {
        self.check()?;
        let Some(media) = self.media.as_ref() else {
            return Ok(false);
        };
        let valid = media
            .verify_geometry(&mut self.adapter, &mut self.handshake, &self.video)
            .await?;
        self.check()?;
        Ok(valid)
    }
    pub async fn media_status_diagnostic(&mut self) -> Result<Vec<u8>, Error> {
        self.check()?;
        let Some(media) = self.media.as_ref() else {
            return Err(error(Stage::Media, Cause::MediaInactive));
        };
        self.require("com.apple.coredevice.displayservice", Stage::Media)?;
        let report = media
            .status_diagnostic(&mut self.adapter, &mut self.handshake)
            .await?;
        self.check()?;
        Ok(report)
    }
    fn settle_input<T>(&mut self, result: Result<T, Error>) -> Result<T, Error> {
        if result.is_err() {
            self.invalidate();
        }
        result
    }
    pub async fn tap(&mut self, x: u16, y: u16) -> Result<TouchDelivery, Error> {
        self.check()?;
        let media = self
            .media
            .as_mut()
            .ok_or(error(Stage::Input, Cause::MediaInactive))?;
        let result = input_transaction(&self.owner, media.tap(x, y)).await;
        self.settle_input(result)
            .map(|()| TouchDelivery::ReportsWrittenVisualEffectUnverified)
    }
    pub async fn drag(
        &mut self,
        x: u16,
        y: u16,
        end_x: u16,
        end_y: u16,
        duration: u16,
    ) -> Result<TouchDelivery, Error> {
        self.check()?;
        if !(100..=2000).contains(&duration) {
            return Err(error(Stage::Input, Cause::InvalidParameters));
        }
        let media = self
            .media
            .as_mut()
            .ok_or(error(Stage::Input, Cause::MediaInactive))?;
        let result = input_transaction(&self.owner, media.drag(x, y, end_x, end_y, duration)).await;
        self.settle_input(result)
            .map(|()| TouchDelivery::ReportsWrittenVisualEffectUnverified)
    }
    pub async fn list_apps(&mut self) -> Result<Vec<u8>, Error> {
        self.require("com.apple.coredevice.appservice", Stage::Applications)?;
        let streaming = self
            .handshake
            .services
            .get("com.apple.coredevice.appservice")
            .and_then(|entry| entry.features.as_ref())
            .is_some_and(|features| {
                features
                    .iter()
                    .any(|name| name == "com.apple.coredevice.feature.streamapplist")
            });
        let mut client: AppServiceClient<Stream> = self.open_service(Stage::Applications).await?;
        let applications = bounded(
            Stage::Applications,
            client.list_apps_mode(false, true, false, false, true, streaming),
        )
        .await?;
        self.check()?;
        let rows: Vec<_> = applications
            .into_iter()
            .map(|app| {
                serde_json::json!({
                    "name": app.name, "bundle_id": app.bundle_identifier, "version": app.version,
                })
            })
            .collect();
        serde_json::to_vec(&rows).map_err(|_| error(Stage::Applications, Cause::Protocol))
    }
    pub async fn launch_app(&mut self, bundle: &str, arguments: &[String]) -> Result<(), Error> {
        self.require("com.apple.coredevice.appservice", Stage::Applications)?;
        let mut client: AppServiceClient<Stream> = self.open_service(Stage::Applications).await?;
        let arguments: Vec<_> = arguments.iter().map(String::as_str).collect();
        let result = input_transaction(&self.owner, async {
            bounded(
                Stage::Applications,
                client.launch_application(bundle, &arguments, false, false, None, None, None),
            )
            .await
            .map(|_| ())
            .map_err(|_| error(Stage::Applications, Cause::DeliveryUncertain))
        })
        .await;
        self.settle_input(result)
    }
    async fn prepare_indigo(&mut self) -> Result<(), Error> {
        self.require("com.apple.coredevice.hid.indigo", Stage::Input)?;
        if self.media.is_none() {
            return Err(error(Stage::Input, Cause::MediaInactive));
        }
        if self.indigo.is_none() {
            self.indigo = Some(self.open_service(Stage::Input).await?);
        }
        Ok(())
    }
    pub async fn home(&mut self) -> Result<(), Error> {
        self.prepare_indigo().await?;
        let keyboard = self.indigo.as_mut().expect("prepared indigo client");
        let result = input_transaction(&self.owner, async {
            bounded(Stage::Input, async {
                keyboard
                    .send_hardware_button(HardwareButton::Home, ButtonState::Down)
                    .await?;
                tokio::time::sleep(Duration::from_millis(100)).await;
                keyboard
                    .send_hardware_button(HardwareButton::Home, ButtonState::Up)
                    .await
            })
            .await
            .map_err(|_| error(Stage::Input, Cause::DeliveryUncertain))
        })
        .await;
        self.settle_input(result)
    }
    pub async fn type_text(&mut self, text: &str) -> Result<(), Error> {
        if !valid_input_text(text) {
            return Err(error(Stage::Input, Cause::InvalidParameters));
        }
        self.require("com.apple.coredevice.pasteboardservice", Stage::Input)?;
        self.prepare_indigo().await?;
        let mut pasteboard: PasteboardServiceClient<Stream> =
            self.open_service(Stage::Input).await?;
        let keyboard = self.indigo.as_mut().expect("prepared indigo client");
        let result = input_transaction(&self.owner, async {
            bounded(Stage::Input, async {
                // One complete overwrite/paste, without reading prior clipboard
                // contents or retrying after a pending consent/transport failure.
                pasteboard.set_text(text, "general").await.map_err(|_| ())?;
                for key in [0xe3, 0x19] {
                    keyboard
                        .send_keyboard(key, ButtonState::Down)
                        .await
                        .map_err(|_| ())?;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
                for key in [0x19, 0xe3] {
                    keyboard
                        .send_keyboard(key, ButtonState::Up)
                        .await
                        .map_err(|_| ())?;
                }
                Ok::<_, ()>(())
            })
            .await
            .map_err(|_| error(Stage::Input, Cause::DeliveryUncertain))
        })
        .await;
        self.settle_input(result)
    }
    fn invalidate(&mut self) {
        self.valid = false;
        self.prepared = false;
        self.owner.0.close();
        self.video.reset();
        self.media.take();
        self.indigo.take();
        self.xctest.take();
        self._control.take();
        self._rsd_control.take();
    }
    pub async fn close(mut self) -> CloseReport {
        self.invalidate();
        let _ = self.adapter.close().await;
        CloseReport::OwnedTransportRevokedRemoteMediaStopUnconfirmed
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.invalidate();
    }
}
async fn authenticate_controller(
    connector: &impl NcmConnector,
    identity: &mut ExistingIdentity,
    owner: &Owner,
) -> Result<RemotePairingClient<RpPairingSocket<Gated>>, Error> {
    let channel = bounded(Stage::NcmConnect, connector.connect(Purpose::PairVerify)).await?;
    let socket = RpPairingSocket::new(Gated::new(channel, owner.0.clone()));
    let mut controller = RemotePairingClient::new(socket, &identity.controller.identifier);
    bounded(Stage::PairVerify, controller.attempt_pair_verify()).await?;
    bounded(
        Stage::PairVerify,
        controller.validate_pairing(&mut identity.controller, &identity.peer),
    )
    .await?;
    Ok(controller)
}
fn tunnel_parameters(
    info: &idevice::tunnel::TunnelInfo,
) -> Result<(Ipv6Addr, Ipv6Addr, u16, usize), Error> {
    let invalid = error(Stage::TlsTunnel, Cause::InvalidParameters);
    let usable_address = |text: &str| -> Result<Ipv6Addr, Error> {
        let address: Ipv6Addr = text.parse().map_err(|_| invalid)?;
        if address.is_unspecified()
            || address.is_loopback()
            || address.is_multicast()
            || address.to_ipv4_mapped().is_some()
        {
            return Err(invalid);
        }
        Ok(address)
    };
    let host = usable_address(&info.client_address)?;
    let peer = usable_address(&info.server_address)?;
    if host == peer || info.mtu < 1280 || info.server_rsd_port == 0 {
        return Err(invalid);
    }
    Ok((host, peer, info.server_rsd_port, usize::from(info.mtu) - 60))
}
fn verify_rsd_identity(handshake: &RsdHandshake, peer: &VerifiedPeerIdentity) -> Result<(), Error> {
    let matches = [
        ("UniqueDeviceID", &peer.peer.remotepairing_udid),
        ("ProductType", &peer.peer.model),
    ]
    .into_iter()
    .all(|(key, expected)| {
        handshake
            .properties
            .get(key)
            .and_then(plist::Value::as_string)
            == Some(expected.as_str())
    });
    if matches && handshake.protocol_version != 0 {
        Ok(())
    } else {
        Err(error(Stage::Rsd, Cause::InvalidParameters))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    };
    use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};
    fn fixture_identity() -> ExistingIdentity {
        // Public deterministic test-only seeds. Never persisted or used with a device.
        let key = ed25519_dalek::SigningKey::from_bytes(&[0x42; 32]);
        ExistingIdentity {
            controller: RpPairingFile {
                e_public_key: key.verifying_key(),
                e_private_key: key,
                identifier: "SYNTHETIC-CONTROLLER".into(),
                alt_irk: Some(vec![0x33; 16]),
            },
            peer: VerifiedPeerIdentity {
                pairing_identifier: "SYNTHETIC-PEER".into(),
                long_term_public_key: ed25519_dalek::SigningKey::from_bytes(&[0x44; 32])
                    .verifying_key()
                    .to_bytes(),
                peer: idevice::remote_pairing::PeerDevice {
                    account_id: "SYNTHETIC-PEER".into(),
                    alt_irk: vec![0x33; 16],
                    model: "iPhone-SYNTHETIC".into(),
                    name: "test".into(),
                    remotepairing_udid: "SYNTHETIC-UDID".into(),
                },
            },
        }
    }
    struct Connector {
        stream: Mutex<Option<DuplexStream>>,
        calls: AtomicUsize,
    }
    impl NcmConnector for Connector {
        fn connect(&self, purpose: Purpose) -> DialFuture<'_> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            assert_eq!(
                purpose,
                Purpose::PairVerify,
                "failure must not dial a tunnel/fallback"
            );
            Box::pin(async move {
                Ok(Box::new(self.stream.lock().unwrap().take().expect("no retry")) as Stream)
            })
        }
    }
    async fn read_frame(peer: &mut DuplexStream) -> String {
        let mut magic = [0; 9];
        peer.read_exact(&mut magic).await.unwrap();
        assert_eq!(&magic, b"RPPairing");
        let size = peer.read_u16().await.unwrap();
        let mut b = vec![0; size as usize];
        peer.read_exact(&mut b).await.unwrap();
        String::from_utf8(b).unwrap()
    }
    #[tokio::test]
    async fn real_verify_m1_rejection_closes_without_pair_setup_or_tunnel() {
        let (stream, mut peer) = tokio::io::duplex(8192);
        let connector = Connector {
            stream: Mutex::new(Some(stream)),
            calls: AtomicUsize::new(0),
        };
        let mock = tokio::spawn(async move {
            let greeting = read_frame(&mut peer).await;
            assert!(greeting.contains("attemptPairVerify"));
            assert!(!greeting.contains("pairingData"));
            let body=br#"{"originatedBy":"device","sequenceNumber":0,"message":{"plain":{"_0":{"response":{"_1":{"handshake":{"_0":{"wireProtocolVersion":19}}}}}}}}"#;
            peer.write_all(b"RPPairing").await.unwrap();
            peer.write_u16(body.len() as u16).await.unwrap();
            peer.write_all(body).await.unwrap();
            let m1 = read_frame(&mut peer).await;
            assert!(m1.contains("verifyManualPairing"));
            assert!(m1.contains("startNewSession"));
            assert!(!m1.contains("setupManualPairing"));
            // Adversarial peer sends a truncated second envelope, not fake success.
            peer.write_all(b"BAD").await.unwrap();
            peer.shutdown().await.unwrap();
            let mut rest = Vec::new();
            peer.read_to_end(&mut rest).await.unwrap();
            assert!(rest.is_empty());
        });
        let result = Session::connect(&connector, &mut fixture_identity()).await;
        assert!(matches!(
            result,
            Err(Error {
                stage: Stage::PairVerify,
                ..
            })
        ));
        mock.await.unwrap();
        assert_eq!(connector.calls.load(Ordering::SeqCst), 1);
    }
    #[tokio::test]
    async fn invalid_identity_never_dials() {
        let connector = Connector {
            stream: Mutex::new(None),
            calls: AtomicUsize::new(0),
        };
        let mut id = fixture_identity();
        id.controller.alt_irk = None;
        assert!(matches!(
            Session::connect(&connector, &mut id).await,
            Err(Error {
                stage: Stage::Identity,
                ..
            })
        ));
        assert_eq!(connector.calls.load(Ordering::SeqCst), 0);
    }
    pub(super) fn broken_media_session() -> Session {
        let (stream, peer) = tokio::io::duplex(1024);
        drop(peer); // synthetic broken video transport, no device connection
        let adapter = Adapter::new(
            Box::new(stream),
            "fdab::1".parse().unwrap(),
            "fdab::2".parse().unwrap(),
        )
        .to_async_handle();
        let services = [
            "com.apple.coredevice.displayservice",
            "com.apple.coredevice.hid.universalhidservice",
            "com.apple.coredevice.screencaptureservice",
        ]
        .into_iter()
        .map(|name| {
            (
                name.to_owned(),
                idevice::rsd::RsdService {
                    entitlement: String::new(),
                    port: 1234,
                    uses_remote_xpc: true,
                    features: None,
                    service_version: None,
                },
            )
        })
        .collect();
        Session {
            owner: Owner::default(),
            _control: None,
            adapter,
            handshake: RsdHandshake {
                services,
                protocol_version: 1,
                properties: Default::default(),
                uuid: String::new(),
            },
            _rsd_control: None,
            prepared: true,
            media: None,
            media_release: media::ReleaseState::default(),
            media_cleanup: Default::default(),
            xctest: None,
            indigo: None,
            video: std::sync::Arc::new(video::VideoMailbox::default()),
            valid: true,
        }
    }
    #[tokio::test]
    async fn idle_media_status_diagnostic_rejects_without_query_or_release_changes() {
        let mut session = broken_media_session();
        for release in [
            media::ReleaseState::Idle,
            media::ReleaseState::Unknown,
            media::ReleaseState::Owned(11),
        ] {
            session.media_release = release;
            assert_eq!(
                session.media_status_diagnostic().await,
                Err(error(Stage::Media, Cause::MediaInactive))
            );
            assert!(session.valid && !session.owner.0.is_closed());
            assert!(session.media.is_none());
        }
        assert_eq!(session.media_release, media::ReleaseState::Owned(11));
    }
    #[tokio::test]
    async fn failed_video_preparation_does_not_revoke_screenshot_generation() {
        let mut session = broken_media_session();
        let result =
            tokio::time::timeout(Duration::from_secs(2), session.start_touch_media()).await;
        assert!(!matches!(result, Ok(Ok(()))));
        assert!(session.stop_touch_media().await.is_ok());
        assert!(
            session.stop_touch_media().await.is_ok(),
            "owned media release is idempotent"
        );
        assert!(session.media.is_none());
        assert!(session.prepared);
        assert!(
            session.check().is_ok(),
            "preparation must not close the owned generation"
        );
        assert!(
            session
                .require(
                    "com.apple.coredevice.screencaptureservice",
                    Stage::Screenshot
                )
                .is_ok()
        );
    }

    #[tokio::test]
    async fn partial_media_start_and_failed_stop_retain_session_cleanup_state() {
        let mut session = broken_media_session();
        session.media_release = media::ReleaseState::Unknown;
        for _ in 0..2 {
            assert_eq!(
                session.stop_touch_media().await,
                Err(error(Stage::Media, Cause::DeliveryUncertain))
            );
            assert!(session.media.is_none());
            assert_eq!(session.media_release, media::ReleaseState::Unknown);
        }
        session.media_release = media::ReleaseState::Owned(11);
        for _ in 0..2 {
            let stopped =
                tokio::time::timeout(Duration::from_millis(20), session.stop_touch_media()).await;
            assert!(
                !matches!(stopped, Ok(Ok(()))),
                "Broken scoped-stop transport cannot confirm release"
            );
            assert_eq!(session.media_release, media::ReleaseState::Owned(11));
        }
        assert_eq!(
            session.start_touch_media().await,
            Err(error(Stage::Media, Cause::InvalidParameters)),
            "A new start must not replace unresolved owned media"
        );
        assert!(session.check().is_ok());
    }

    #[test]
    fn tunnel_uses_negotiated_ipv6_and_port_only() {
        let mut info = idevice::tunnel::TunnelInfo {
            client_address: "fdab::9".into(),
            server_address: "fdab::8".into(),
            netmask: String::new(),
            mtu: 1280,
            server_rsd_port: 43210,
        };
        let (_, _, port, mss) = tunnel_parameters(&info).unwrap();
        assert_eq!((port, mss), (43210, 1220));
        info.server_rsd_port = 0;
        assert!(tunnel_parameters(&info).is_err());
        info.server_rsd_port = 43210;
        for ip in [
            "192.168.7.2",
            "::ffff:192.168.7.2",
            "::1",
            "::",
            "ff02::fb",
            "fdab::9",
        ] {
            info.server_address = ip.into();
            assert!(tunnel_parameters(&info).is_err());
        }
    }
    #[test]
    fn rsd_metadata_must_match_verified_peer() {
        let id = fixture_identity();
        let mut h = RsdHandshake {
            services: Default::default(),
            properties: Default::default(),
            protocol_version: 1,
            uuid: String::new(),
        };
        assert!(verify_rsd_identity(&h, &id.peer).is_err());
        h.properties.insert(
            "UniqueDeviceID".into(),
            plist::Value::String(id.peer.peer.remotepairing_udid.clone()),
        );
        h.properties.insert(
            "ProductType".into(),
            plist::Value::String(id.peer.peer.model.clone()),
        );
        assert!(verify_rsd_identity(&h, &id.peer).is_ok());
        h.protocol_version = 0;
        assert!(verify_rsd_identity(&h, &id.peer).is_err());
    }
    #[test]
    fn canceled_operation_invalidates_transport_generation() {
        let owner = Owner::default();
        drop(OperationGuard(Some(owner.0.clone())));
        assert!(owner.0.is_closed());
    }
}

#[cfg(test)]
mod orchestration_tests {
    use super::*;
    #[tokio::test]
    async fn successful_effect_keeps_generation_but_failed_effect_revokes_it_once() {
        let owner = Owner::default();
        let calls = std::cell::Cell::new(0);
        assert_eq!(
            input_transaction(&owner, async {
                calls.set(calls.get() + 1);
                Ok(7)
            })
            .await,
            Ok(7)
        );
        assert!(!owner.0.is_closed());
        let failure = error(Stage::Input, Cause::DeliveryUncertain);
        assert_eq!(
            input_transaction(&owner, async {
                calls.set(calls.get() + 1);
                Err::<(), _>(failure)
            })
            .await,
            Err(failure)
        );
        assert!(owner.0.is_closed());
        assert_eq!(calls.get(), 2, "Each requested effect is invoked only once");
    }
    #[tokio::test]
    async fn cancellation_during_effect_revokes_generation() {
        let owner = Owner::default();
        let started = std::cell::Cell::new(false);
        let operation = input_transaction(&owner, async {
            started.set(true);
            std::future::pending::<Result<(), Error>>().await
        });
        assert!(
            tokio::time::timeout(Duration::from_millis(1), operation)
                .await
                .is_err()
        );
        assert!(started.get());
        assert!(owner.0.is_closed());
    }
    #[tokio::test]
    async fn explicit_invalidation_revokes_previously_queued_decoder_bytes() {
        let mut session = super::tests::broken_media_session();
        session.video.begin_stream();
        session.video.poll(0);
        let before = session.video.decode_cursor().epoch;
        session.invalidate();
        assert_ne!(session.video.decode_cursor().epoch, before);
        assert_eq!(session.video.poll(0).0, 14);
        assert!(session.check().is_err());
    }
}
