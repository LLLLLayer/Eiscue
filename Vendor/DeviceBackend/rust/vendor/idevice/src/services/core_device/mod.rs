// Jackson Coxson
// Ported from pymobiledevice3

use tracing::warn;

use crate::{
    IdeviceError, ReadWrite, RemoteXpcClient,
    xpc::{self, XPCObject},
};

mod app_service;
mod diagnosticsservice;
#[cfg(feature = "display_stream")]
pub mod display_stream;
mod errors;
#[cfg(feature = "display_stream")]
pub mod hid;
mod location_service;
mod openstdiosocket;
mod orientation_service;
mod pasteboard_service;
mod screencaptureservices;
pub use app_service::*;
pub use diagnosticsservice::*;
#[cfg(feature = "display_stream")]
pub use display_stream::*;
pub use errors::CoreDeviceError;
#[cfg(feature = "display_stream")]
pub use hid::*;
pub use location_service::*;
pub use openstdiosocket::*;
pub use orientation_service::*;
pub use pasteboard_service::*;
pub use screencaptureservices::*;

const CORE_SERVICE_VERSION: &str = "443.18";
const MAX_STREAM_BATCH_ELEMENTS: usize = 4096;
const SIDE_CHANNEL_IDENTIFIER: &str = "XPCSideChannel.uniqueIdentifier";
const SIDE_CHANNEL_STATUS: &str = "CoreDevice.XPCMessageKey.sideChannelStatus";

#[derive(Clone, Copy, Debug)]
struct StreamIdentity {
    side_channel: uuid::Uuid,
    invocation: uuid::Uuid,
}

#[derive(Debug)]
pub struct CoreDeviceServiceClient<R: ReadWrite> {
    inner: RemoteXpcClient<R>,
    active_stream: Option<StreamIdentity>,
    stream_failed: bool,
}

impl<R: ReadWrite> CoreDeviceServiceClient<R> {
    pub async fn new(inner: R) -> Result<Self, IdeviceError> {
        let mut client = RemoteXpcClient::new(inner).await?;
        client.do_handshake().await?;
        Ok(Self { inner: client, active_stream: None, stream_failed: false })
    }

    /// Begin one long-lived protocol-v2 stream on this dedicated service client.
    /// The returned UUID identifies its side channel. Drop the client to cancel;
    /// a cancelled send or failed stream must never be retried on this connection.
    pub async fn begin_stream_with_plist(
        &mut self, feature: &str, input: plist::Dictionary, action_identifier: Option<&str>,
    ) -> Result<uuid::Uuid, IdeviceError> {
        if self.active_stream.is_some() || self.stream_failed {
            return Err(CoreDeviceError::MalformedField("stream already active or failed").into());
        }
        let (request, identity) = stream_request(feature, input, action_identifier);
        // Reserve before sending, including when the send future is cancelled.
        self.active_stream = Some(identity);
        if let Err(error) = self.inner.send_object(request, true).await {
            self.stream_failed = true;
            return Err(error);
        }
        Ok(identity.side_channel)
    }

    /// Read one bounded batch without accumulating earlier updates. None is an
    /// explicit finishStreaming, never an empty batch or an ignored stream error.
    /// Read cancellation preserves RemoteXPC's partial-message buffer and identity.
    pub async fn next_stream_batch(&mut self) -> Result<Option<Vec<plist::Value>>, IdeviceError> {
        if self.stream_failed {
            return Err(CoreDeviceError::MalformedField("stream failed").into());
        }
        let identity = self.active_stream.ok_or(CoreDeviceError::MissingField("active stream"))?;
        let result = self.inner.recv_root().await.and_then(|reply| parse_stream_batch(reply, identity));
        match &result {
            Ok(None) => self.active_stream = None,
            Err(_) => self.stream_failed = true,
            Ok(Some(_)) => {}
        }
        result
    }

    /// Bounded collection of CoreDevice protocol-v2 side-channel batches.
    /// Caller supplies an overall deadline; malformed/error streams fail closed.
    pub async fn stream_with_plist(&mut self, feature: &str, input: plist::Dictionary) -> Result<plist::Value, IdeviceError> {
        let (request, _) = stream_request(feature, input, None);
        self.inner.send_object(request, true).await?;
        let mut collection = Vec::new();
        let mut remaining_batches = MAX_STREAM_BATCH_ELEMENTS;
        loop {
            remaining_batches = remaining_batches.checked_sub(1)
                .ok_or(CoreDeviceError::MalformedField("too many application batches"))?;
            let message = self.inner.recv_root().await?;
            let status = message.as_dictionary().and_then(|root| root.get(SIDE_CHANNEL_STATUS))
                .and_then(plist::Value::as_dictionary)
                .ok_or(CoreDeviceError::MalformedField("application stream status"))?;
            if status.get("receivedError").is_some() {
                return Err(CoreDeviceError::MalformedField("application stream failed").into());
            }
            if status.get("finishStreaming").is_some() { break; }
            let batch = status.get("pushing").and_then(plist::Value::as_dictionary)
                .and_then(|pushing| pushing.get("elements")).and_then(plist::Value::as_array)
                .ok_or(CoreDeviceError::MalformedField("application stream batch"))?;
            if batch.len() > MAX_STREAM_BATCH_ELEMENTS - collection.len() {
                return Err(CoreDeviceError::MalformedField("too many applications").into());
            }
            collection.extend_from_slice(batch);
        }
        Ok(collection.into())
    }
    pub async fn invoke_with_plist(
        &mut self,
        feature: impl Into<String>,
        input: plist::Dictionary,
    ) -> Result<plist::Value, IdeviceError> {
        let input: XPCObject = plist::Value::Dictionary(input).into();
        let input = input.to_dictionary().unwrap();
        self.invoke(feature, Some(input)).await
    }

    pub async fn invoke_with_plist_action(
        &mut self,
        feature: impl Into<String>,
        input: plist::Dictionary,
        action_identifier: impl Into<String>,
    ) -> Result<plist::Value, IdeviceError> {
        let input: XPCObject = plist::Value::Dictionary(input).into();
        let input = input.to_dictionary().unwrap();
        self.invoke_inner(feature, Some(input), Some(action_identifier.into()))
            .await
    }

    /// Eiscue's read-only input-geometry barrier. Older peers omit the response
    /// invocation ID; when present it must identify this exact request.
    pub async fn current_display_info(&mut self) -> Result<plist::Value, IdeviceError> {
        self.invoke_inner_checking("com.apple.coredevice.feature.getdisplayinfo", None, None, true).await
    }

    pub async fn invoke(
        &mut self,
        feature: impl Into<String>,
        input: Option<crate::xpc::Dictionary>,
    ) -> Result<plist::Value, IdeviceError> {
        self.invoke_inner(feature, input, None).await
    }

    async fn invoke_inner(
        &mut self,
        feature: impl Into<String>,
        input: Option<crate::xpc::Dictionary>,
        action_identifier: Option<String>,
    ) -> Result<plist::Value, IdeviceError> {
        self.invoke_inner_checking(feature, input, action_identifier, false).await
    }

    async fn invoke_inner_checking(
        &mut self,
        feature: impl Into<String>,
        input: Option<crate::xpc::Dictionary>,
        action_identifier: Option<String>,
        check_invocation: bool,
    ) -> Result<plist::Value, IdeviceError> {
        let feature = feature.into();
        let input: crate::xpc::XPCObject = match input {
            Some(i) => i.into(),
            None => crate::xpc::Dictionary::new().into(),
        };

        let mut req = xpc::Dictionary::new();
        let protocol_version = if action_identifier.is_some() { 2 } else { 0 };
        req.insert(
            "CoreDevice.CoreDeviceDDIProtocolVersion".into(),
            XPCObject::Int64(protocol_version),
        );
        req.insert("CoreDevice.action".into(), xpc::Dictionary::new().into());
        req.insert(
            "CoreDevice.coreDeviceVersion".into(),
            create_xpc_version_from_string(CORE_SERVICE_VERSION).into(),
        );
        req.insert(
            "CoreDevice.deviceIdentifier".into(),
            XPCObject::String(uuid::Uuid::new_v4().to_string()),
        );
        req.insert(
            "CoreDevice.featureIdentifier".into(),
            XPCObject::String(feature),
        );
        req.insert("CoreDevice.input".into(), input);
        let invocation = uuid::Uuid::new_v4();
        req.insert(
            "CoreDevice.invocationIdentifier".into(),
            XPCObject::String(invocation.to_string()),
        );
        if let Some(action_identifier) = action_identifier {
            req.insert(
                "CoreDevice.actionIdentifier".into(),
                XPCObject::String(action_identifier),
            );
        }

        self.inner.send_object(req, true).await?;
        let res = self.inner.recv().await?;
        let mut res = match res {
            plist::Value::Dictionary(d) => d,
            _ => {
                warn!("XPC response was not a dictionary");
                return Err(CoreDeviceError::MalformedField("(root)").into());
            }
        };
        if check_invocation {
            if let Some(reply) = res.get("CoreDevice.invocationIdentifier") {
                if reply.as_string().and_then(|value| uuid::Uuid::parse_str(value).ok()) != Some(invocation) {
                    return Err(CoreDeviceError::MalformedField("display info invocation identity").into());
                }
            }
        }

        let res = match res.remove("CoreDevice.output") {
            Some(r) => r,
            None => {
                // The device replied with an error rather than an output. Surface
                // its contents (commonly under "CoreDevice.error") so callers can
                // see why a feature invocation was rejected.
                warn!("XPC response did not have an output: {res:?}");
                return match res.get("CoreDevice.error") {
                    Some(e) => Err(CoreDeviceError::DeviceError(format!("{e:?}")).into()),
                    None => Err(CoreDeviceError::MissingField("CoreDevice.output").into()),
                };
            }
        };

        Ok(res)
    }
}

fn stream_request(feature: &str, input: plist::Dictionary, action_identifier: Option<&str>) -> (xpc::Dictionary, StreamIdentity) {
    let identity = StreamIdentity { side_channel: uuid::Uuid::new_v4(), invocation: uuid::Uuid::new_v4() };
    let mut proxy = xpc::Dictionary::new();
    proxy.insert("sideChannel".into(), XPCObject::Uuid(identity.side_channel));
    let mut wrapped = xpc::Dictionary::new();
    wrapped.insert("actualInput".into(), plist::Value::Dictionary(input).into());
    wrapped.insert("streamProxy".into(), proxy.into());
    let mut request = xpc::Dictionary::new();
    request.insert("CoreDevice.CoreDeviceDDIProtocolVersion".into(), XPCObject::Int64(2));
    request.insert("CoreDevice.coreDeviceVersion".into(), create_xpc_version_from_string(CORE_SERVICE_VERSION).into());
    request.insert("CoreDevice.deviceIdentifier".into(), XPCObject::String(uuid::Uuid::new_v4().to_string()));
    request.insert("CoreDevice.invocationIdentifier".into(), XPCObject::String(identity.invocation.to_string()));
    request.insert("CoreDevice.featureIdentifier".into(), XPCObject::String(feature.into()));
    request.insert("CoreDevice.action".into(), xpc::Dictionary::new().into());
    request.insert("CoreDevice.input".into(), wrapped.into());
    if let Some(action) = action_identifier {
        request.insert("CoreDevice.actionIdentifier".into(), XPCObject::String(action.into()));
    }
    (request, identity)
}

fn parse_stream_batch(mut reply: plist::Value, identity: StreamIdentity) -> Result<Option<Vec<plist::Value>>, IdeviceError> {
    let root = reply.as_dictionary_mut().ok_or(CoreDeviceError::MalformedField("stream root"))?;
    let id = root.get(SIDE_CHANNEL_IDENTIFIER).and_then(plist::Value::as_string)
        .and_then(|value| uuid::Uuid::parse_str(value).ok());
    if id != Some(identity.side_channel) {
        return Err(CoreDeviceError::MalformedField("side channel identity").into());
    }
    if let Some(invocation) = root.get("CoreDevice.invocationIdentifier") {
        if invocation.as_string().and_then(|value| uuid::Uuid::parse_str(value).ok()) != Some(identity.invocation) {
            return Err(CoreDeviceError::MalformedField("stream invocation identity").into());
        }
    }
    let status = root.remove(SIDE_CHANNEL_STATUS).ok_or(CoreDeviceError::MissingField("sideChannelStatus"))?;
    let mut status = status.into_dictionary().ok_or(CoreDeviceError::MalformedField("sideChannelStatus"))?;
    if status.len() != 1 { return Err(CoreDeviceError::MalformedField("stream status variant").into()); }
    if status.contains_key("receivedError") {
        // Error content is peer data: propagate a fixed category without logging it.
        return Err(CoreDeviceError::MalformedField("receivedError").into());
    }
    if let Some(finish) = status.remove("finishStreaming") {
        if !finish.as_dictionary().is_some_and(|value| value.is_empty()) {
            return Err(CoreDeviceError::MalformedField("finishStreaming").into());
        }
        return Ok(None);
    }
    let pushing = status.remove("pushing").ok_or(CoreDeviceError::MissingField("pushing"))?;
    let mut pushing = pushing.into_dictionary().ok_or(CoreDeviceError::MalformedField("pushing"))?;
    let elements = pushing.remove("elements").ok_or(CoreDeviceError::MissingField("elements"))?;
    let elements = elements.into_array().ok_or(CoreDeviceError::MalformedField("elements"))?;
    if elements.len() > MAX_STREAM_BATCH_ELEMENTS { return Err(CoreDeviceError::MalformedField("stream batch count").into()); }
    Ok(Some(elements))
}

fn create_xpc_version_from_string(version: impl Into<String>) -> xpc::Dictionary {
    let version: String = version.into();
    let mut collected_version = Vec::new();
    version.split('.').for_each(|x| {
        if let Ok(x) = x.parse() {
            collected_version.push(XPCObject::UInt64(x));
        }
    });

    let mut res = xpc::Dictionary::new();
    res.insert(
        "originalComponentsCount".into(),
        XPCObject::Int64(collected_version.len() as i64),
    );
    res.insert("components".into(), XPCObject::Array(collected_version));
    res.insert("stringValue".into(), XPCObject::String(version));
    res
}

#[cfg(test)]
mod stream_tests {
    use super::*;

    #[derive(Clone, Copy)]
    enum DisplayReplyId { Matching, MatchingUuid, Missing, Foreign, Malformed, WrongType }

    // Exercise the actual HTTP/2 + RemoteXPC receive path and request UUID,
    // rather than passing an already-parsed geometry value to the validator.
    async fn display_info_wire_reply(id: DisplayReplyId, checked: bool) -> Result<plist::Value, IdeviceError> {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let (host, mut peer) = tokio::io::duplex(16384);
        let server = tokio::spawn(async move {
            let mut preface = [0; 24]; peer.read_exact(&mut preface).await.unwrap();
            assert_eq!(&preface, b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
            loop {
                let mut header = [0; 9]; peer.read_exact(&mut header).await.unwrap();
                let length = u32::from_be_bytes([0, header[0], header[1], header[2]]) as usize;
                assert!(length <= 16384);
                let mut payload = vec![0; length]; peer.read_exact(&mut payload).await.unwrap();
                if header[3] != 0 || u32::from_be_bytes(header[5..9].try_into().unwrap()) != 1 { continue; }
                let message = xpc::XPCMessage::decode(&payload).unwrap();
                let Some(root) = message.message.and_then(|value| value.to_dictionary()) else { continue; };
                let Some(feature) = root.get("CoreDevice.featureIdentifier") else { continue; };
                assert_eq!(feature.as_string(), Some("com.apple.coredevice.feature.getdisplayinfo"));
                let request_id = root.get("CoreDevice.invocationIdentifier").and_then(XPCObject::as_string)
                    .and_then(|value| uuid::Uuid::parse_str(value).ok()).expect("The real request must contain a UUID");
                let mut reply = xpc::Dictionary::new();
                reply.insert("CoreDevice.output".into(), XPCObject::String("public-display-output".into()));
                let identity = match id {
                    DisplayReplyId::Matching => Some(XPCObject::String(request_id.to_string())),
                    DisplayReplyId::MatchingUuid => Some(XPCObject::Uuid(request_id)),
                    DisplayReplyId::Missing => None,
                    DisplayReplyId::Foreign => Some(XPCObject::String(uuid::Uuid::nil().to_string())),
                    DisplayReplyId::Malformed => Some(XPCObject::String("not-a-uuid".into())),
                    DisplayReplyId::WrongType => Some(XPCObject::Int64(7)),
                };
                if let Some(identity) = identity { reply.insert("CoreDevice.invocationIdentifier".into(), identity); }
                let body = xpc::XPCMessage::new(None, Some(reply.into()), Some(1)).encode(1).unwrap();
                let mut frame = (body.len() as u32).to_be_bytes()[1..].to_vec();
                frame.extend_from_slice(&[0, 0]); frame.extend_from_slice(&3u32.to_be_bytes()); frame.extend(body);
                peer.write_all(&frame).await.unwrap();
                // Keep the peer alive while the client's HTTP/2 receive path
                // returns its window-update writes, including rejection paths.
                return peer;
            }
        });
        let mut client = CoreDeviceServiceClient::new(host).await.unwrap();
        let result = if checked { client.current_display_info().await }
        else { client.invoke_with_plist("com.apple.coredevice.feature.getdisplayinfo", plist::Dictionary::new()).await };
        let _peer = server.await.unwrap();
        result
    }

    #[tokio::test]
    async fn core_service_display_info_wire_accepts_matching_and_omitted_reply_ids() {
        for id in [DisplayReplyId::Matching, DisplayReplyId::MatchingUuid, DisplayReplyId::Missing] {
            let result = tokio::time::timeout(std::time::Duration::from_secs(2), display_info_wire_reply(id, true)).await.unwrap().unwrap();
            assert_eq!(result.as_string(), Some("public-display-output"));
        }
    }

    #[tokio::test]
    async fn core_service_display_info_wire_refuses_foreign_malformed_or_mistyped_reply_ids() {
        for id in [DisplayReplyId::Foreign, DisplayReplyId::Malformed, DisplayReplyId::WrongType] {
            let result = tokio::time::timeout(std::time::Duration::from_secs(2), display_info_wire_reply(id, true)).await.unwrap();
            assert!(result.is_err(), "A present invalid invocation must not expose the otherwise valid output");
        }
    }

    #[tokio::test]
    async fn core_service_display_info_wire_keeps_legacy_invoke_compatibility() {
        let result = tokio::time::timeout(std::time::Duration::from_secs(2), display_info_wire_reply(DisplayReplyId::Foreign, false)).await.unwrap().unwrap();
        assert_eq!(result.as_string(), Some("public-display-output"));
    }

    fn identity() -> StreamIdentity {
        StreamIdentity { side_channel: uuid::Uuid::from_bytes([0x11; 16]), invocation: uuid::Uuid::from_bytes([0x22; 16]) }
    }

    fn reply(variant: &str, value: plist::Value) -> plist::Value {
        plist::Value::Dictionary(plist::Dictionary::from_iter([
            (SIDE_CHANNEL_IDENTIFIER, plist::Value::String(identity().side_channel.to_string())),
            (SIDE_CHANNEL_STATUS, plist::Value::Dictionary(plist::Dictionary::from_iter([(variant, value)]))),
        ]))
    }

    fn batch(elements: Vec<plist::Value>) -> plist::Value {
        reply("pushing", plist::Value::Dictionary(plist::Dictionary::from_iter([
            ("elements", plist::Value::Array(elements)),
        ])))
    }

    #[test]
    fn core_service_stream_request_correlates_the_proxy_and_optional_action() {
        for action in [None, Some("com.apple.coredevice.action.displayinfoupdates")] {
            let (request, identity) = stream_request("com.apple.coredevice.feature.displayinfoupdates", plist::Dictionary::new(), action);
            assert_eq!(request.get("CoreDevice.CoreDeviceDDIProtocolVersion"), Some(&XPCObject::Int64(2)));
            assert_eq!(request.get("CoreDevice.invocationIdentifier"), Some(&XPCObject::String(identity.invocation.to_string())));
            let input = request.get("CoreDevice.input").and_then(XPCObject::as_dictionary).unwrap();
            assert_eq!(input.get("actualInput").and_then(XPCObject::as_dictionary), Some(&xpc::Dictionary::new()));
            let proxy = input.get("streamProxy").and_then(XPCObject::as_dictionary).unwrap();
            assert_eq!(proxy.get("sideChannel"), Some(&XPCObject::Uuid(identity.side_channel)));
            assert_eq!(request.get("CoreDevice.actionIdentifier"), action.map(|value| XPCObject::String(value.into())).as_ref());
        }
    }

    #[test]
    fn core_service_stream_batches_preserve_order_without_accumulating_or_coalescing() {
        for orientation in ["rot0", "rot180", "rot0"] {
            let elements = vec![plist::Value::String(orientation.into())];
            assert_eq!(parse_stream_batch(batch(elements.clone()), identity()).unwrap(), Some(elements));
        }
        assert_eq!(parse_stream_batch(batch(Vec::new()), identity()).unwrap(), Some(Vec::new()));
    }

    #[test]
    fn core_service_stream_rejects_missing_wrong_or_malformed_ids() {
        for replacement in [None, Some(plist::Value::String(uuid::Uuid::nil().to_string())), Some(plist::Value::String("invalid".into()))] {
            let mut value = batch(Vec::new());
            let root = value.as_dictionary_mut().unwrap();
            root.remove(SIDE_CHANNEL_IDENTIFIER);
            if let Some(replacement) = replacement { root.insert(SIDE_CHANNEL_IDENTIFIER.into(), replacement); }
            assert!(parse_stream_batch(value, identity()).is_err());
        }
        let mut value = batch(Vec::new());
        value.as_dictionary_mut().unwrap().insert("CoreDevice.invocationIdentifier".into(), plist::Value::String(uuid::Uuid::nil().to_string()));
        assert!(parse_stream_batch(value, identity()).is_err());
    }

    #[test]
    fn core_service_stream_finish_and_errors_are_not_empty_batches() {
        assert_eq!(parse_stream_batch(reply("finishStreaming", plist::Value::Dictionary(plist::Dictionary::new())), identity()).unwrap(), None);
        assert!(parse_stream_batch(reply("receivedError", plist::Value::Dictionary(plist::Dictionary::new())), identity()).is_err());
        assert!(parse_stream_batch(reply("finishStreaming", plist::Value::Boolean(true)), identity()).is_err());
        assert!(parse_stream_batch(reply("unknown", plist::Value::Dictionary(plist::Dictionary::new())), identity()).is_err());
        let mut value = batch(Vec::new());
        value.as_dictionary_mut().unwrap().get_mut(SIDE_CHANNEL_STATUS).unwrap().as_dictionary_mut().unwrap()
            .insert("finishStreaming".into(), plist::Value::Dictionary(plist::Dictionary::new()));
        assert!(parse_stream_batch(value, identity()).is_err());
    }

    #[test]
    fn core_service_stream_caps_each_batch_and_requires_the_elements_array() {
        assert!(parse_stream_batch(batch(vec![plist::Value::Boolean(false); MAX_STREAM_BATCH_ELEMENTS]), identity()).is_ok());
        assert!(parse_stream_batch(batch(vec![plist::Value::Boolean(false); MAX_STREAM_BATCH_ELEMENTS + 1]), identity()).is_err());
        assert!(parse_stream_batch(reply("pushing", plist::Value::Dictionary(plist::Dictionary::new())), identity()).is_err());
    }
}
