// SPDX-License-Identifier: GPL-3.0-only
//! Explicit read-only compatibility probe over the existing authenticated tunnel.
//! No new identity, daemon test session, process authorization or input actions.

use crate::{Cause, Error, Session, Stage, bounded_for, error, png};
use idevice::{
    ReadWrite,
    dvt::{remote_server::RemoteServerClient, screenshot::ScreenshotClient},
    rsd::RsdHandshake,
};
use serde::Serialize;
use std::time::Duration;
use zeroize::Zeroizing;

const INSTRUMENTS: &str = "com.apple.instruments.dtservicehub";
const TESTMANAGER: &str = "com.apple.dt.testmanagerd.remote";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ServiceReport {
    service_available: bool,
    handshake_succeeded: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    screenshot: Option<Dimensions>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<ProbeError>,
}

#[derive(Serialize)]
struct Dimensions {
    width: u32,
    height: u32,
}

/// Only stable numeric ABI categories cross the boundary, never peer strings.
#[derive(Serialize)]
struct ProbeError {
    stage: u32,
    cause: u32,
}

impl From<Error> for ProbeError {
    fn from(value: Error) -> Self {
        Self {
            stage: value.stage as u32 + 1,
            cause: value.cause as u32 + 1,
        }
    }
}

#[derive(Serialize)]
struct ProbeReport {
    version: u32,
    instruments: ServiceReport,
    testmanager: ServiceReport,
}

impl ServiceReport {
    fn new(service_available: bool) -> Self {
        Self {
            service_available,
            handshake_succeeded: false,
            screenshot: None,
            error: None,
        }
    }

    fn record(&mut self, result: Result<(), Error>) {
        if let Err(failure) = result {
            self.error = Some(failure.into());
        }
    }
}

// DTX is not RemoteXPC. A service with UsesRemoteXPC=false is the expected path.
fn service_port(handshake: &RsdHandshake, name: &str) -> Result<u16, Cause> {
    let service = handshake
        .services
        .get(name)
        .filter(|service| service.port != 0)
        .ok_or(Cause::MissingService)?;
    if service.uses_remote_xpc {
        return Err(Cause::Protocol);
    }
    Ok(service.port)
}

async fn handshake(
    client: &mut RemoteServerClient<Box<dyn ReadWrite>>,
    stage: Stage,
    timeout: Duration,
) -> Result<(), Error> {
    // Match the licensed vendored DTX handshake, advertising only the transport
    // capabilities. No process-control callback or XCTest capabilities are sent.
    let mut capabilities = plist::Dictionary::new();
    capabilities.insert("com.apple.private.DTXBlockCompression".into(), 0_i64.into());
    capabilities.insert("com.apple.private.DTXConnection".into(), 1_i64.into());
    let peer = bounded_for(
        stage,
        timeout,
        client.perform_handshake(Some(capabilities), timeout + Duration::from_secs(1)),
    )
    .await?;
    if peer.is_none() {
        return Err(error(stage, Cause::Protocol));
    }
    Ok(())
}

async fn screenshot_bytes(
    client: &mut RemoteServerClient<Box<dyn ReadWrite>>,
) -> Result<Zeroizing<Vec<u8>>, Error> {
    let mut screenshot = bounded_for(
        Stage::LegacyScreenshotChannel, Duration::from_secs(10), ScreenshotClient::new(client),
    ).await?;
    let bytes = Zeroizing::new(bounded_for(
        Stage::LegacyScreenshotResponse, Duration::from_secs(45), screenshot.take_screenshot(),
    ).await?);
    png::validate_png(&bytes).map_err(|_| error(Stage::LegacyScreenshotResponse, Cause::Protocol))?;
    Ok(bytes)
}

async fn screenshot_dimensions(
    client: &mut RemoteServerClient<Box<dyn ReadWrite>>,
) -> Result<Dimensions, Error> {
    let bytes = screenshot_bytes(client).await?;
    let dimensions = png::validate_png(&bytes)
        .map_err(|_| error(Stage::LegacyScreenshotResponse, Cause::Protocol))?;
    Ok(Dimensions { width: dimensions.width, height: dimensions.height })
}

impl Session {
    /// Actual PNG capture for the iOS 26 Instruments path. Uses only the current
    /// prepared adapter; one request, no alternate transport or automatic replay.
    pub async fn screenshot_legacy(&mut self) -> Result<crate::Screenshot, Error> {
        self.check()?;
        if !self.prepared { return Err(error(Stage::LegacyInstrumentsConnection, Cause::Unprepared)); }
        let port = service_port(&self.handshake, INSTRUMENTS)
            .map_err(|cause| error(Stage::LegacyInstrumentsConnection, cause))?;
        let stream = bounded_for(Stage::LegacyInstrumentsConnection, CONNECT_TIMEOUT,
            self.adapter.connect(port)).await?;
        let mut client = RemoteServerClient::with_label(stream, "legacy-screenshot");
        handshake(&mut client, Stage::LegacyInstrumentsHandshake, HANDSHAKE_TIMEOUT).await?;
        let bytes = screenshot_bytes(&mut client).await?;
        let dimensions = png::validate_png(&bytes)
            .map_err(|_| error(Stage::LegacyScreenshotResponse, Cause::Protocol))?;
        Ok(crate::Screenshot { png: bytes.to_vec(), width: dimensions.width, height: dimensions.height })
    }

    /// Both services are probed independently, once, on this session's adapter.
    /// Result contains status, dimensions and sanitized errors only. Per-step
    /// deadlines sum to 105s, below the caller's 120s operation deadline.
    pub async fn probe_legacy_developer_services(&mut self) -> Result<Vec<u8>, Error> {
        self.check()?;
        if !self.prepared {
            return Err(error(Stage::LegacyInstrumentsConnection, Cause::Unprepared));
        }
        let instruments_port = service_port(&self.handshake, INSTRUMENTS);
        let testmanager_port = service_port(&self.handshake, TESTMANAGER);
        let mut instruments = ServiceReport::new(instruments_port != Err(Cause::MissingService));
        let mut testmanager = ServiceReport::new(testmanager_port != Err(Cause::MissingService));

        let instruments_result = async {
            let port = instruments_port
                .map_err(|cause| error(Stage::LegacyInstrumentsConnection, cause))?;
            let stream = bounded_for(
                Stage::LegacyInstrumentsConnection,
                CONNECT_TIMEOUT,
                self.adapter.connect(port),
            )
            .await?;
            let mut client = RemoteServerClient::with_label(stream, "legacy-instruments-probe");
            handshake(
                &mut client,
                Stage::LegacyInstrumentsHandshake,
                HANDSHAKE_TIMEOUT,
            )
            .await?;
            instruments.handshake_succeeded = true;
            instruments.screenshot = Some(screenshot_dimensions(&mut client).await?);
            Ok(())
        }
        .await;
        instruments.record(instruments_result);

        let testmanager_result = async {
            let port = testmanager_port
                .map_err(|cause| error(Stage::LegacyTestmanagerConnection, cause))?;
            let stream = bounded_for(
                Stage::LegacyTestmanagerConnection,
                CONNECT_TIMEOUT,
                self.adapter.connect(port),
            )
            .await?;
            let mut client = RemoteServerClient::with_label(stream, "legacy-testmanager-probe");
            handshake(
                &mut client,
                Stage::LegacyTestmanagerHandshake,
                HANDSHAKE_TIMEOUT,
            )
            .await?;
            testmanager.handshake_succeeded = true;
            // Drop the DTX connection after capabilities. Do not open a test
            // channel, enable UI automation, authorize a PID or launch a runner.
            Ok(())
        }
        .await;
        testmanager.record(testmanager_result);

        serde_json::to_vec(&ProbeReport {
            version: 1,
            instruments,
            testmanager,
        })
        .map_err(|_| error(Stage::LegacyInstrumentsConnection, Cause::Protocol))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{transport::Owner, video::VideoMailbox};
    use idevice::dvt::message::{AuxValue, Message, MessageHeader, PayloadHeader};
    use idevice::tcp::adapter::Adapter;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn readiness_is_required_and_missing_services_are_reported_independently_without_io() {
        let (stream, mut peer) = tokio::io::duplex(1024);
        let adapter = Adapter::new(
            Box::new(stream),
            "fdab::1".parse().unwrap(),
            "fdab::2".parse().unwrap(),
        )
        .to_async_handle();
        let mut session = Session {
            owner: Owner::default(),
            _control: None,
            adapter,
            handshake: RsdHandshake {
                services: Default::default(),
                protocol_version: 1,
                properties: Default::default(),
                uuid: String::new(),
            },
            _rsd_control: None,
            prepared: false,
            media: None,
            xctest: None,
            indigo: None,
            video: std::sync::Arc::new(VideoMailbox::default()),
            valid: true,
        };
        assert_eq!(
            session.probe_legacy_developer_services().await,
            Err(error(Stage::LegacyInstrumentsConnection, Cause::Unprepared))
        );
        session.prepared = true;
        let report: serde_json::Value =
            serde_json::from_slice(&session.probe_legacy_developer_services().await.unwrap())
                .unwrap();
        assert_eq!(
            report,
            serde_json::json!({
                "version": 1,
                "instruments": {"serviceAvailable": false, "handshakeSucceeded": false,
                    "error": {"stage": 22, "cause": 4}},
                "testmanager": {"serviceAvailable": false, "handshakeSucceeded": false,
                    "error": {"stage": 26, "cause": 4}}
            })
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(20), peer.read_u8())
                .await
                .is_err()
        );
        assert!(
            session.check().is_ok(),
            "read-only failures retain the authenticated generation"
        );
    }

    #[test]
    fn dtx_service_does_not_require_remote_xpc() {
        let mut handshake = RsdHandshake {
            services: Default::default(),
            protocol_version: 1,
            properties: Default::default(),
            uuid: String::new(),
        };
        handshake.services.insert(
            INSTRUMENTS.into(),
            idevice::rsd::RsdService {
                entitlement: String::new(),
                port: 1234,
                uses_remote_xpc: false,
                features: None,
                service_version: None,
            },
        );
        assert_eq!(service_port(&handshake, INSTRUMENTS), Ok(1234));
        assert_eq!(
            service_port(&handshake, TESTMANAGER),
            Err(Cause::MissingService)
        );
        handshake
            .services
            .get_mut(INSTRUMENTS)
            .unwrap()
            .uses_remote_xpc = true;
        assert_eq!(service_port(&handshake, INSTRUMENTS), Err(Cause::Protocol));
        handshake.services.get_mut(INSTRUMENTS).unwrap().port = 0;
        assert_eq!(
            service_port(&handshake, INSTRUMENTS),
            Err(Cause::MissingService)
        );
    }

    #[test]
    fn report_preserves_handshake_success_after_screenshot_error_without_raw_payload() {
        let mut instruments = ServiceReport::new(true);
        instruments.handshake_succeeded = true;
        instruments.record(Err(error(Stage::LegacyScreenshotResponse, Cause::Timeout)));
        let mut testmanager = ServiceReport::new(false);
        testmanager.record(Err(error(
            Stage::LegacyTestmanagerConnection,
            Cause::MissingService,
        )));
        let report = serde_json::to_value(ProbeReport {
            version: 1,
            instruments,
            testmanager,
        })
        .unwrap();
        assert_eq!(
            report,
            serde_json::json!({
                "version": 1,
                "instruments": {"serviceAvailable": true, "handshakeSucceeded": true,
                    "error": {"stage": 25, "cause": 2}},
                "testmanager": {"serviceAvailable": false, "handshakeSucceeded": false,
                    "error": {"stage": 26, "cause": 4}}
            })
        );
    }

    #[tokio::test]
    async fn instruments_capture_returns_actual_png_and_rejects_non_images_and_errors() {
        // Generated public 2x2 RGB fixture; contains no captured device pixels.
        let png = vec![137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0, 0, 0, 16, 73, 68, 65, 84, 120, 156, 99, 48, 94, 117, 6, 136, 24, 32, 20, 0, 44, 38, 6, 165, 74, 91, 171, 240, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];
        assert_eq!(png::validate_png(&png).unwrap(), png::PngDimensions { width: 2, height: 2 });
        for (payload, kind, succeeds) in [(png.clone(), 3u8, true), (b"not an image".to_vec(), 3, false),
                                         (png.clone(), 4, false)] {
            let (stream, mut peer) = tokio::io::duplex(8192);
            let mut client = RemoteServerClient::new(stream);
            let expected = payload.clone();
            let server = tokio::spawn(async move {
                let request = Message::from_reader(&mut peer).await.unwrap();
                assert_eq!(request.data, Some("_requestChannelWithCode:identifier:".into()));
                assert_eq!(request.aux.as_ref().unwrap().values, vec![AuxValue::U32(1),
                    AuxValue::archived_value(plist::Value::String("com.apple.instruments.server.services.screenshot".into()))]);
                let id = u32::from_le_bytes(request.message_header.serialize()[16..20].try_into().unwrap());
                let ack = Message::new(MessageHeader::new(0, 1, id, 1, 0, false),
                    PayloadHeader::new(), None, None);
                peer.write_all(&ack.serialize()).await.unwrap();
                let request = Message::from_reader(&mut peer).await.unwrap();
                assert_eq!(request.data, Some("takeScreenshot".into()));
                assert!(request.aux.is_none());
                let id = u32::from_le_bytes(request.message_header.serialize()[16..20].try_into().unwrap());
                let mut reply = Message::new(MessageHeader::new(0, 1, id, 1, 1, false),
                    PayloadHeader::new(), None, Some(plist::Value::Data(payload))).serialize();
                reply[32] = kind;
                peer.write_all(&reply).await.unwrap();
                assert_eq!(tokio::time::timeout(Duration::from_secs(1), peer.read_u8()).await.unwrap()
                    .unwrap_err().kind(), std::io::ErrorKind::UnexpectedEof);
            });
            let result = screenshot_bytes(&mut client).await;
            if succeeds { assert_eq!(result.unwrap().as_slice(), expected.as_slice()); }
            else { assert_eq!(result.unwrap_err(), error(Stage::LegacyScreenshotResponse, Cause::Protocol)); }
            drop(client);
            server.await.unwrap();
        }
    }

    #[tokio::test]
    async fn capability_handshake_exchanges_only_transport_capabilities() {
        let (client_stream, mut peer) = tokio::io::duplex(8192);
        let mut client = RemoteServerClient::new(client_stream);
        let exchange = async {
            let message = Message::from_reader(&mut peer).await.unwrap();
            assert_eq!(message.data, Some("_notifyOfPublishedCapabilities:".into()));
            let mut expected = plist::Dictionary::new();
            expected.insert("com.apple.private.DTXBlockCompression".into(), 0_i64.into());
            expected.insert("com.apple.private.DTXConnection".into(), 1_i64.into());
            assert_eq!(
                message.aux.as_ref().unwrap().values,
                vec![AuxValue::archived_value(plist::Value::Dictionary(expected))]
            );
            // The peer echoes exactly the capabilities received. No automation,
            // process authorization, or test-channel message is involved.
            let response = Message::new(
                MessageHeader::new(0, 1, 1, 0, 0, false),
                PayloadHeader::method_invocation(),
                message.aux,
                Some("_notifyOfPublishedCapabilities:".into()),
            );
            peer.write_all(&response.serialize()).await.unwrap();
            assert!(
                tokio::time::timeout(Duration::from_millis(20), peer.read_u8())
                    .await
                    .is_err()
            );
        };
        let (result, ()) = tokio::join!(
            handshake(
                &mut client,
                Stage::LegacyTestmanagerHandshake,
                Duration::from_secs(1)
            ),
            exchange
        );
        assert_eq!(result, Ok(()));
    }

    #[tokio::test]
    async fn silent_dtx_peer_times_out_with_the_correct_stage() {
        let (client_stream, _peer) = tokio::io::duplex(8192);
        let mut client = RemoteServerClient::new(client_stream);
        assert_eq!(
            handshake(
                &mut client,
                Stage::LegacyTestmanagerHandshake,
                Duration::from_millis(5)
            )
            .await,
            Err(error(Stage::LegacyTestmanagerHandshake, Cause::Timeout))
        );
    }

    #[tokio::test]
    async fn closed_peer_is_a_protocol_error_not_a_successful_handshake() {
        let (client_stream, peer) = tokio::io::duplex(8192);
        let mut client = RemoteServerClient::new(client_stream);
        drop(peer);
        assert_eq!(
            handshake(
                &mut client,
                Stage::LegacyInstrumentsHandshake,
                Duration::from_secs(1)
            )
            .await,
            Err(error(Stage::LegacyInstrumentsHandshake, Cause::Protocol))
        );
    }
}
