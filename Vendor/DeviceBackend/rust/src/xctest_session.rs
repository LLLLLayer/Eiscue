// SPDX-License-Identifier: GPL-3.0-only
//! Owned XCTest IDE channels over this session's already authenticated adapter.
//! This authorizes only the embedding process. It neither launches/installs a
//! runner nor enables automation, injects input, or claims that touch is ready.
use crate::{
    Cause, Error, Session, Stage, bounded_for, error,
    transport::{Gated, Owner},
};
use idevice::{
    ReadWrite,
    dvt::{
        message::{AuxValue, Message},
        remote_server::RemoteServerClient,
        xctest_protocol::{
            archive_nsuuid_to_bytes, archive_xct_capabilities_to_bytes, ide_capabilities,
        },
    },
};
use plist::{Dictionary, Value};
use std::time::Duration;
use uuid::Uuid;

const TESTMANAGER: &str = "com.apple.dt.testmanagerd.remote";
const PROXY: &str = "dtxproxy:XCTestManager_IDEInterface:XCTestManager_DaemonConnectionInterface";
const CONTROL_INIT: &str = "_IDE_initiateControlSessionWithCapabilities:";
const MAIN_INIT: &str = "_IDE_initiateSessionWithIdentifier:capabilities:";
const AUTHORIZE: &str = "_IDE_authorizeTestSessionWithProcessID:";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const STEP_TIMEOUT: Duration = Duration::from_secs(15);

type DtxClient = RemoteServerClient<Box<dyn ReadWrite>>;

pub(crate) struct OwnedXCTestSession {
    // The local gate revokes only these two child streams, never the RP tunnel.
    owner: Owner,
    control: DtxClient,
    main: DtxClient,
    identifier: Uuid,
    process_id: u32,
}

impl Drop for OwnedXCTestSession {
    fn drop(&mut self) {
        self.owner.0.close();
    }
}

fn uuid_from_bytes(bytes: &[u8]) -> Result<Uuid, Error> {
    let raw: [u8; 16] = bytes
        .try_into()
        .map_err(|_| error(Stage::XCTestControlInit, Cause::InvalidParameters))?;
    let uuid = Uuid::from_bytes(raw);
    if uuid.is_nil() {
        return Err(error(Stage::XCTestControlInit, Cause::InvalidParameters));
    }
    Ok(uuid)
}

pub(crate) fn valid_uuid_bytes(bytes: &[u8]) -> bool {
    uuid_from_bytes(bytes).is_ok()
}

fn normal_reply(reply: &Message, stage: Stage) -> Result<(), Error> {
    // Empty DTX error payloads must not be interpreted as successful ACKs.
    let valid = match reply.payload_header.message_type() {
        0 => reply.data.is_none() && reply.raw_data.is_none(),
        3 => reply.raw_data.is_some(),
        _ => false,
    };
    if valid {
        Ok(())
    } else {
        Err(error(stage, Cause::Protocol))
    }
}

fn initialized(reply: &Message, stage: Stage) -> Result<(), Error> {
    normal_reply(reply, stage)?;
    match &reply.data {
        None => Ok(()), // documented wire ACK convention, not authorization evidence
        Some(Value::Dictionary(d))
            if d.len() == 1
                && d.get("capabilities-dictionary")
                    .is_some_and(|v| v.as_dictionary().is_some()) =>
        {
            Ok(())
        }
        _ if reply
            .raw_data
            .as_deref()
            .is_some_and(is_capabilities_archive) =>
        {
            Ok(())
        }
        _ => Err(error(stage, Cause::Protocol)),
    }
}

fn is_capabilities_archive(bytes: &[u8]) -> bool {
    // The generic MIT decoder leaves unknown Objective-C classes as UID-backed
    // dictionaries. Resolve just this known type, with no recursive UID walk.
    if bytes.len() > 1024 * 1024 {
        return false;
    }
    let Ok(Value::Dictionary(archive)) = Value::from_reader(std::io::Cursor::new(bytes)) else {
        return false;
    };
    if archive.get("$archiver").and_then(Value::as_string) != Some("NSKeyedArchiver") {
        return false;
    }
    let Some(objects) = archive.get("$objects").and_then(Value::as_array) else {
        return false;
    };
    let resolve = |value: &Value| {
        value
            .as_uid()
            .and_then(|uid| usize::try_from(uid.get()).ok())
            .and_then(|i| objects.get(i))
    };
    let Some(root) = archive
        .get("$top")
        .and_then(Value::as_dictionary)
        .and_then(|top| top.get("root"))
        .and_then(resolve)
    else {
        return false;
    };
    if root.as_string() == Some("$null") {
        return true;
    } // explicit init nil only
    let Some(root) = root.as_dictionary() else {
        return false;
    };
    if root.len() != 2 {
        return false;
    }
    let class_name = |dict: &Dictionary| {
        dict.get("$class")
            .and_then(resolve)
            .and_then(Value::as_dictionary)
            .and_then(|class| class.get("$classname"))
            .and_then(Value::as_string)
    };
    if class_name(root) != Some("XCTCapabilities") {
        return false;
    }
    let Some(caps) = root
        .get("capabilities-dictionary")
        .and_then(resolve)
        .and_then(Value::as_dictionary)
    else {
        return false;
    };
    if !class_name(caps).is_some_and(|name| name.contains("Dictionary")) {
        return false;
    }
    let Some(keys) = caps.get("NS.keys").and_then(Value::as_array) else {
        return false;
    };
    let Some(values) = caps.get("NS.objects").and_then(Value::as_array) else {
        return false;
    };
    keys.len() == values.len()
        && keys
            .iter()
            .all(|key| resolve(key).and_then(Value::as_string).is_some())
        && values.iter().all(|value| resolve(value).is_some())
}

fn authorized(reply: &Message) -> Result<(), Error> {
    normal_reply(reply, Stage::XCTestAuthorize)?;
    if reply.payload_header.message_type() == 3 && reply.data == Some(Value::Boolean(true)) {
        Ok(())
    } else {
        Err(error(Stage::XCTestAuthorize, Cause::Unprepared))
    }
}

async fn handshake(client: &mut DtxClient, stage: Stage, deadline: Duration) -> Result<(), Error> {
    let mut capabilities = Dictionary::new();
    capabilities.insert("com.apple.private.DTXBlockCompression".into(), 0_i64.into());
    capabilities.insert("com.apple.private.DTXConnection".into(), 1_i64.into());
    let remote = bounded_for(
        stage,
        deadline,
        client.perform_handshake(Some(capabilities), deadline + Duration::from_secs(1)),
    )
    .await?;
    if remote.is_none() {
        return Err(error(stage, Cause::Protocol));
    }
    Ok(())
}

impl OwnedXCTestSession {
    fn from_streams(
        control: impl ReadWrite + 'static,
        main: impl ReadWrite + 'static,
        owner: Owner,
        identifier: Uuid,
    ) -> Result<Self, Error> {
        // No PID is accepted from the C ABI, JSON, a provider or remote peer.
        let pid = unsafe { libc::getpid() };
        if pid <= 0 {
            return Err(error(Stage::XCTestAuthorize, Cause::InvalidParameters));
        }
        Ok(Self {
            control: RemoteServerClient::with_label(
                Gated::new(Box::new(control), owner.0.clone()),
                "xctest-owned-control",
            ),
            main: RemoteServerClient::with_label(
                Gated::new(Box::new(main), owner.0.clone()),
                "xctest-owned-main",
            ),
            owner,
            identifier,
            process_id: pid as u32,
        })
    }

    async fn initialize(&mut self, deadline: Duration) -> Result<(), Error> {
        handshake(&mut self.control, Stage::XCTestControlHandshake, deadline).await?;
        handshake(&mut self.main, Stage::XCTestMainHandshake, deadline).await?;
        let mut control = bounded_for(
            Stage::XCTestControlChannel,
            deadline,
            self.control.make_channel(PROXY),
        )
        .await?;
        let caps = archive_xct_capabilities_to_bytes(&Dictionary::new())
            .map_err(|_| error(Stage::XCTestControlInit, Cause::Protocol))?;
        let reply = bounded_for(
            Stage::XCTestControlInit,
            deadline,
            control.call_method_with_reply(Some(CONTROL_INIT), Some(vec![AuxValue::Array(caps)])),
        )
        .await?;
        initialized(&reply, Stage::XCTestControlInit)?;

        let mut main = bounded_for(
            Stage::XCTestMainChannel,
            deadline,
            self.main.make_channel(PROXY),
        )
        .await?;
        let uuid = archive_nsuuid_to_bytes(self.identifier.as_bytes())
            .map_err(|_| error(Stage::XCTestMainInit, Cause::Protocol))?;
        let caps = archive_xct_capabilities_to_bytes(&ide_capabilities())
            .map_err(|_| error(Stage::XCTestMainInit, Cause::Protocol))?;
        let reply = bounded_for(
            Stage::XCTestMainInit,
            deadline,
            main.call_method_with_reply(
                Some(MAIN_INIT),
                Some(vec![AuxValue::Array(uuid), AuxValue::Array(caps)]),
            ),
        )
        .await?;
        initialized(&reply, Stage::XCTestMainInit)?;

        let pid = AuxValue::archived_value(Value::Integer(u64::from(self.process_id).into()));
        let reply = bounded_for(
            Stage::XCTestAuthorize,
            deadline,
            control.call_method_with_reply(Some(AUTHORIZE), Some(vec![pid])),
        )
        .await?;
        authorized(&reply)
    }

    fn receipt(&self) -> Result<Vec<u8>, Error> {
        serde_json::to_vec(&serde_json::json!({
            "sessionIdentifier": self.identifier.to_string(),
            "processID": self.process_id,
            "authorized": true,
        }))
        .map_err(|_| error(Stage::XCTestAuthorize, Cause::Protocol))
    }
}

impl Session {
    pub async fn start_xctest_session(&mut self, session_uuid: &[u8]) -> Result<Vec<u8>, Error> {
        self.check()?;
        if !self.prepared {
            return Err(error(Stage::XCTestControlInit, Cause::Unprepared));
        }
        // Repeated starts never repeat authorization or replace live ownership.
        if self.xctest.is_some() {
            return Err(error(Stage::XCTestControlInit, Cause::InvalidParameters));
        }
        let identifier = uuid_from_bytes(session_uuid)?;
        let service = self
            .handshake
            .services
            .get(TESTMANAGER)
            .filter(|s| s.port != 0)
            .ok_or(error(Stage::XCTestControlConnection, Cause::MissingService))?;
        if service.uses_remote_xpc {
            return Err(error(Stage::XCTestControlConnection, Cause::Protocol));
        }
        let port = service.port;
        let owned = tokio::time::timeout(Duration::from_secs(105), async {
            let control = bounded_for(
                Stage::XCTestControlConnection,
                CONNECT_TIMEOUT,
                self.adapter.connect(port),
            )
            .await?;
            let main = bounded_for(
                Stage::XCTestMainConnection,
                CONNECT_TIMEOUT,
                self.adapter.connect(port),
            )
            .await?;
            let mut owned =
                OwnedXCTestSession::from_streams(control, main, Owner::default(), identifier)?;
            owned.initialize(STEP_TIMEOUT).await?;
            Ok::<_, Error>(owned)
        })
        .await
        .map_err(|_| error(Stage::XCTestControlInit, Cause::Timeout))??;
        let receipt = owned.receipt()?;
        // Commit ownership only after the strict affirmative authorization reply.
        self.xctest = Some(owned);
        Ok(receipt)
    }

    /// Revokes only the owned DTX channels. Does not call a global stop selector
    /// or claim that remote automation mode has been disabled.
    pub async fn stop_xctest_session(&mut self) -> Result<(), Error> {
        self.xctest.take();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use idevice::dvt::message::{MessageHeader, PayloadHeader};
    use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};

    #[derive(Clone, Copy)]
    enum AuthReply {
        True,
        False,
        Nil,
        Error,
        WrongChannel,
        WrongConversation,
        WantsReply,
        Silent,
    }

    fn identifier(message: &Message) -> u32 {
        let h = message.message_header.serialize();
        u32::from_le_bytes(h[16..20].try_into().unwrap())
    }

    fn reply_bytes(request: &Message, data: Option<Value>, kind: u8, channel: i32) -> Vec<u8> {
        let mut bytes = Message::new(
            MessageHeader::new(0, 1, identifier(request), 1, channel, false),
            PayloadHeader::new(),
            None,
            data,
        )
        .serialize();
        bytes[32] = kind;
        bytes
    }

    // Independent fixed DTX object-reply wire header, not the client encoder.
    fn raw_reply_bytes(id: u32, channel: i32, archive: &[u8]) -> Vec<u8> {
        let mut bytes = vec![0x79, 0x5b, 0x3d, 0x1f, 0x20, 0, 0, 0, 0, 0, 1, 0];
        bytes.extend_from_slice(&(16u32 + archive.len() as u32).to_le_bytes());
        bytes.extend_from_slice(&id.to_le_bytes());
        bytes.extend_from_slice(&1u32.to_le_bytes());
        bytes.extend_from_slice(&channel.to_le_bytes());
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(&[3, 0, 0, 0]);
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(&(archive.len() as u32).to_le_bytes());
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(archive);
        bytes
    }

    async fn ack(peer: &mut DuplexStream, request: &Message) {
        peer.write_all(&reply_bytes(
            request,
            None,
            0,
            -request.message_header.channel,
        ))
        .await
        .unwrap();
    }

    async fn hello(peer: &mut DuplexStream) {
        let request = Message::from_reader(peer).await.unwrap();
        assert_eq!(request.data, Some("_notifyOfPublishedCapabilities:".into()));
        let mut capabilities = Dictionary::new();
        capabilities.insert("com.apple.private.DTXBlockCompression".into(), 0_i64.into());
        capabilities.insert("com.apple.private.DTXConnection".into(), 1_i64.into());
        assert_eq!(
            request.aux.as_ref().unwrap().values,
            vec![AuxValue::archived_value(Value::Dictionary(capabilities))]
        );
        peer.write_all(
            &Message::new(
                MessageHeader::new(0, 1, 91, 0, 0, false),
                PayloadHeader::method_invocation(),
                request.aux,
                Some("_notifyOfPublishedCapabilities:".into()),
            )
            .serialize(),
        )
        .await
        .unwrap();
    }

    async fn channel(peer: &mut DuplexStream) {
        let request = Message::from_reader(peer).await.unwrap();
        assert_eq!(
            request.data,
            Some("_requestChannelWithCode:identifier:".into())
        );
        assert_eq!(
            request.aux.as_ref().unwrap().values,
            vec![
                AuxValue::U32(1),
                AuxValue::archived_value(Value::String(PROXY.into()))
            ]
        );
        ack(peer, &request).await;
    }

    async fn wait_closed(peer: &mut DuplexStream) {
        // No daemon-global stop, runner launch, input action or extra RPC is sent.
        let count = tokio::time::timeout(Duration::from_secs(1), peer.read(&mut [0u8; 1]))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(count, 0, "owned stream must reach EOF after scoped drop");
    }

    async fn control_peer(
        mut peer: DuplexStream,
        answer: AuthReply,
        auth_seen: Option<tokio::sync::oneshot::Sender<()>>,
    ) {
        hello(&mut peer).await;
        channel(&mut peer).await;
        let init = Message::from_reader(&mut peer).await.unwrap();
        assert_eq!(init.data, Some(CONTROL_INIT.into()));
        assert_eq!(
            init.aux.as_ref().unwrap().values,
            vec![AuxValue::Array(
                archive_xct_capabilities_to_bytes(&Dictionary::new()).unwrap()
            )]
        );
        ack(&mut peer, &init).await;
        let request = Message::from_reader(&mut peer).await.unwrap();
        assert_eq!(request.data, Some(AUTHORIZE.into()));
        assert_eq!(
            request.aux.as_ref().unwrap().values,
            vec![AuxValue::archived_value(Value::Integer(
                (unsafe { libc::getpid() } as u64).into()
            ))]
        );
        if let Some(sender) = auth_seen {
            let _ = sender.send(());
        }
        match answer {
            AuthReply::True => {
                // A same-ID incoming callback cannot satisfy authorization.
                let callback = Message::new(
                    MessageHeader::new(0, 1, identifier(&request), 0, -1, false),
                    PayloadHeader::method_invocation(),
                    None,
                    Some("_XCT_logMessage:".into()),
                );
                peer.write_all(&callback.serialize()).await.unwrap();
                peer.write_all(&reply_bytes(&request, Some(Value::Boolean(true)), 3, 1))
                    .await
                    .unwrap();
            }
            AuthReply::False => peer
                .write_all(&reply_bytes(&request, Some(Value::Boolean(false)), 3, 1))
                .await
                .unwrap(),
            AuthReply::Nil => ack(&mut peer, &request).await,
            AuthReply::Error => peer
                .write_all(&reply_bytes(&request, None, 4, 1))
                .await
                .unwrap(),
            AuthReply::WrongChannel => peer
                .write_all(&reply_bytes(&request, Some(Value::Boolean(true)), 3, 2))
                .await
                .unwrap(),
            AuthReply::WrongConversation => {
                let mut bytes = reply_bytes(&request, Some(Value::Boolean(true)), 3, 1);
                bytes[20..24].copy_from_slice(&3u32.to_le_bytes());
                peer.write_all(&bytes).await.unwrap();
            }
            AuthReply::WantsReply => {
                let mut bytes = reply_bytes(&request, Some(Value::Boolean(true)), 3, 1);
                bytes[28..32].copy_from_slice(&1u32.to_le_bytes());
                peer.write_all(&bytes).await.unwrap();
            }
            AuthReply::Silent => {}
        }
        wait_closed(&mut peer).await;
    }

    async fn main_peer(mut peer: DuplexStream, uuid: Uuid) {
        hello(&mut peer).await;
        channel(&mut peer).await;
        let init = Message::from_reader(&mut peer).await.unwrap();
        assert_eq!(init.data, Some(MAIN_INIT.into()));
        assert_eq!(
            init.aux.as_ref().unwrap().values,
            vec![
                AuxValue::Array(archive_nsuuid_to_bytes(uuid.as_bytes()).unwrap()),
                AuxValue::Array(archive_xct_capabilities_to_bytes(&ide_capabilities()).unwrap()),
            ]
        );
        // Inspect the real NSUUID archive bytes, rather than a textual UUID echo.
        let AuxValue::Array(bytes) = &init.aux.as_ref().unwrap().values[0] else {
            panic!()
        };
        let archive = plist::Value::from_reader(std::io::Cursor::new(bytes)).unwrap();
        assert_eq!(
            archive.as_dictionary().unwrap()["$objects"]
                .as_array()
                .unwrap()[1]
                .as_dictionary()
                .unwrap()["NS.uuidbytes"]
                .as_data(),
            Some(uuid.as_bytes().as_slice())
        );
        let caps = archive_xct_capabilities_to_bytes(&ide_capabilities()).unwrap();
        let reply = raw_reply_bytes(identifier(&init), 1, &caps);
        assert_eq!(i32::from_le_bytes(reply[24..28].try_into().unwrap()), 1);
        assert_eq!(reply[32], 3);
        peer.write_all(&reply).await.unwrap();
        wait_closed(&mut peer).await;
    }

    fn fixture(
        answer: AuthReply,
        auth_seen: Option<tokio::sync::oneshot::Sender<()>>,
    ) -> (
        OwnedXCTestSession,
        tokio::task::JoinHandle<()>,
        tokio::task::JoinHandle<()>,
    ) {
        let uuid = Uuid::from_bytes([0x31; 16]);
        let (control, ctrl_peer) = tokio::io::duplex(32768);
        let (main, main_stream) = tokio::io::duplex(32768);
        let owned =
            OwnedXCTestSession::from_streams(control, main, Owner::default(), uuid).unwrap();
        (
            owned,
            tokio::spawn(control_peer(ctrl_peer, answer, auth_seen)),
            tokio::spawn(main_peer(main_stream, uuid)),
        )
    }

    #[tokio::test]
    async fn two_wire_channels_use_the_same_uuid_and_authorize_only_self_pid() {
        let (mut owned, control, main) = fixture(AuthReply::True, None);
        owned.initialize(Duration::from_secs(1)).await.unwrap();
        let receipt: serde_json::Value = serde_json::from_slice(&owned.receipt().unwrap()).unwrap();
        assert_eq!(
            receipt,
            serde_json::json!({"sessionIdentifier": Uuid::from_bytes([0x31; 16]).to_string(),
            "processID": unsafe { libc::getpid() }, "authorized": true})
        );
        drop(owned);
        control.await.unwrap();
        main.await.unwrap();
    }

    #[tokio::test]
    async fn nil_false_remote_error_wrong_channel_and_timeout_revoke_both_owned_streams() {
        for answer in [
            AuthReply::False,
            AuthReply::Nil,
            AuthReply::Error,
            AuthReply::WrongChannel,
            AuthReply::WrongConversation,
            AuthReply::WantsReply,
            AuthReply::Silent,
        ] {
            let (mut owned, control, main) = fixture(answer, None);
            let result = owned.initialize(Duration::from_millis(100)).await;
            assert!(result.is_err());
            let failure = result.unwrap_err();
            assert_eq!(failure.stage, Stage::XCTestAuthorize);
            drop(owned);
            control.await.unwrap();
            main.await.unwrap();
        }
    }

    #[tokio::test]
    async fn cancellation_while_authorizing_drops_both_channels_without_a_retry() {
        let (tx, rx) = tokio::sync::oneshot::channel();
        let (mut owned, control, main) = fixture(AuthReply::Silent, Some(tx));
        let start = tokio::spawn(async move { owned.initialize(Duration::from_secs(10)).await });
        rx.await.unwrap();
        start.abort();
        assert!(start.await.unwrap_err().is_cancelled());
        control.await.unwrap();
        main.await.unwrap();
    }

    #[tokio::test]
    async fn duplicate_start_never_reauthorizes_and_stop_is_idempotent_retaining_parent() {
        let (mut owned, control, main) = fixture(AuthReply::True, None);
        owned.initialize(Duration::from_secs(1)).await.unwrap();
        let (adapter_stream, mut parent_peer) = tokio::io::duplex(1024);
        let adapter = idevice::tcp::adapter::Adapter::new(
            Box::new(adapter_stream),
            "fdab::1".parse().unwrap(),
            "fdab::2".parse().unwrap(),
        )
        .to_async_handle();
        let mut session = Session {
            owner: Owner::default(),
            _control: None,
            adapter,
            handshake: idevice::rsd::RsdHandshake {
                services: Default::default(),
                protocol_version: 1,
                properties: Default::default(),
                uuid: String::new(),
            },
            _rsd_control: None,
            prepared: true,
            media: None,
            media_release: crate::media::ReleaseState::default(),
            xctest: Some(owned),
            indigo: None,
            video: std::sync::Arc::new(crate::video::VideoMailbox::default()),
            valid: true,
        };
        assert_eq!(
            session.start_xctest_session(&[0x32; 16]).await,
            Err(error(Stage::XCTestControlInit, Cause::InvalidParameters))
        );
        session.stop_xctest_session().await.unwrap();
        session.stop_xctest_session().await.unwrap();
        assert!(session.xctest.is_none());
        assert!(session.check().is_ok());
        assert!(session.prepared);
        assert!(
            tokio::time::timeout(Duration::from_millis(20), parent_peer.read_u8())
                .await
                .is_err()
        );
        control.await.unwrap();
        main.await.unwrap();
    }

    #[tokio::test]
    async fn typed_reply_rejects_error_frames_even_when_payload_is_true_or_nil() {
        let request = Message::new(
            MessageHeader::new(0, 1, 42, 0, 1, true),
            PayloadHeader::method_invocation(),
            None,
            Some(AUTHORIZE.into()),
        );
        for data in [None, Some(Value::Boolean(true))] {
            let bytes = reply_bytes(&request, data, 4, -1);
            let reply = Message::from_reader(&mut bytes.as_slice()).await.unwrap();
            assert_eq!(
                authorized(&reply),
                Err(error(Stage::XCTestAuthorize, Cause::Protocol))
            );
            assert_eq!(
                initialized(&reply, Stage::XCTestMainInit),
                Err(error(Stage::XCTestMainInit, Cause::Protocol))
            );
        }
        for data in [
            None,
            Some(Value::Boolean(false)),
            Some(Value::String("unknown".into())),
            Some(Value::Dictionary(Dictionary::from_iter([(
                "NSDomain",
                Value::String("NSError".into()),
            )]))),
        ] {
            let bytes = reply_bytes(&request, data, 3, -1);
            let reply = Message::from_reader(&mut bytes.as_slice()).await.unwrap();
            assert!(authorized(&reply).is_err());
        }
    }

    #[test]
    fn protocol_archives_encode_without_runner_features() {
        archive_xct_capabilities_to_bytes(&Dictionary::new()).unwrap();
        archive_xct_capabilities_to_bytes(&ide_capabilities()).unwrap();
        archive_nsuuid_to_bytes(&[0x31; 16]).unwrap();
    }

    #[tokio::test]
    async fn capability_object_reply_resolves_custom_class_uids_and_rejects_nserror() {
        let request = Message::new(
            MessageHeader::new(0, 1, 42, 0, -1, true),
            PayloadHeader::method_invocation(),
            None,
            Some(MAIN_INIT.into()),
        );
        let caps = archive_xct_capabilities_to_bytes(&ide_capabilities()).unwrap();
        let bytes = raw_reply_bytes(identifier(&request), 1, &caps);
        let reply = Message::from_reader(&mut bytes.as_slice()).await.unwrap();
        initialized(&reply, Stage::XCTestMainInit).unwrap();
        let mut archive = Value::from_reader(std::io::Cursor::new(&caps)).unwrap();
        archive
            .as_dictionary_mut()
            .unwrap()
            .get_mut("$objects")
            .unwrap()
            .as_array_mut()
            .unwrap()[2]
            .as_dictionary_mut()
            .unwrap()
            .insert("$classname".into(), Value::String("NSError".into()));
        let mut error = Vec::new();
        archive.to_writer_binary(&mut error).unwrap();
        assert!(!is_capabilities_archive(&error));
        let bytes = raw_reply_bytes(42, 1, &error);
        let reply = Message::from_reader(&mut bytes.as_slice()).await.unwrap();
        assert!(initialized(&reply, Stage::XCTestMainInit).is_err());
    }

    #[tokio::test]
    async fn main_handshake_timeout_releases_both_connections_before_any_authorization() {
        let (control, mut ctrl_peer) = tokio::io::duplex(8192);
        let (main, mut main_peer) = tokio::io::duplex(8192);
        let mut owned = OwnedXCTestSession::from_streams(
            control,
            main,
            Owner::default(),
            Uuid::from_bytes([0x31; 16]),
        )
        .unwrap();
        let server = tokio::spawn(async move {
            hello(&mut ctrl_peer).await;
            let hello = Message::from_reader(&mut main_peer).await.unwrap();
            assert_eq!(hello.data, Some("_notifyOfPublishedCapabilities:".into()));
            tokio::join!(wait_closed(&mut ctrl_peer), wait_closed(&mut main_peer));
        });
        assert_eq!(
            owned.initialize(Duration::from_millis(30)).await,
            Err(error(Stage::XCTestMainHandshake, Cause::Timeout))
        );
        drop(owned);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn empty_control_init_error_releases_both_connections_without_authorizing() {
        let (control, mut ctrl_peer) = tokio::io::duplex(8192);
        let (main, mut main_peer) = tokio::io::duplex(8192);
        let mut owned = OwnedXCTestSession::from_streams(
            control,
            main,
            Owner::default(),
            Uuid::from_bytes([0x31; 16]),
        )
        .unwrap();
        let server = tokio::spawn(async move {
            hello(&mut ctrl_peer).await;
            hello(&mut main_peer).await;
            channel(&mut ctrl_peer).await;
            let request = Message::from_reader(&mut ctrl_peer).await.unwrap();
            assert_eq!(request.data, Some(CONTROL_INIT.into()));
            ctrl_peer
                .write_all(&reply_bytes(&request, None, 4, 1))
                .await
                .unwrap();
            tokio::join!(wait_closed(&mut ctrl_peer), wait_closed(&mut main_peer));
        });
        assert_eq!(
            owned.initialize(Duration::from_secs(1)).await,
            Err(error(Stage::XCTestControlInit, Cause::Protocol))
        );
        drop(owned);
        server.await.unwrap();
    }

    #[test]
    fn uuid_payload_accepts_exact_non_nil_bytes_and_no_pid_or_json_fields() {
        assert!(valid_uuid_bytes(&[0x33; 16]));
        for bytes in [
            vec![],
            vec![0; 16],
            vec![0x33; 15],
            vec![0x33; 17],
            b"{\"pid\":1}".to_vec(),
            b"11111111-1111-1111-1111-111111111111".to_vec(),
        ] {
            assert!(!valid_uuid_bytes(&bytes));
        }
    }
}
