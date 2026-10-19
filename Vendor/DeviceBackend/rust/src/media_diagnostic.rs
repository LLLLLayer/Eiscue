// SPDX-License-Identifier: GPL-3.0-only
//! Private, read-only evidence. None of these facts confer stream-release authority.
use crate::{Cause, Error, Stage, error};
use serde::Serialize;
use std::{future::Future, sync::atomic::{AtomicBool, Ordering}, time::Duration};

const MAX_DEPTH: usize = 8;
const MAX_NODES: u32 = 4096;
const MAX_BYTES: u32 = 1024 * 1024;

// Never serialized, logged or persisted; retained only by the live Media object.
pub(crate) struct Identity {
    session: uuid::Uuid,
    call: uuid::Uuid,
    sender: u32,
    receiver: u32,
}
impl Identity {
    pub(crate) fn new(session: uuid::Uuid, call: uuid::Uuid, sender: u32, receiver: u32) -> Self {
        Self { session, call, sender, receiver }
    }
}

#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct Summary {
    version: u32,
    query_succeeded: bool,
    query_timed_out: bool,
    failure_stage: Option<u32>,
    failure_cause: Option<u32>,
    media_healthy: bool,
    root_is_dictionary: Option<bool>,
    server_info_present: Option<bool>,
    server_info_is_dictionary: Option<bool>,
    sessions_present: Option<bool>,
    sessions_is_array: Option<bool>,
    session_count: Option<u32>,
    scan_complete: bool,
    truncated: bool,
    visited_node_count: u32,
    visited_byte_count: u32,
    opaque_data_present: Option<bool>,
    #[serde(rename = "sessionUUIDMatchCount")]
    session_uuid_match_count: Option<u32>,
    #[serde(rename = "callUUIDMatchCount")]
    call_uuid_match_count: Option<u32>,
    stream_config_count: Option<u32>,
    #[serde(rename = "localSSRCFieldCount")]
    local_ssrc_field_count: Option<u32>,
    #[serde(rename = "remoteSSRCFieldCount")]
    remote_ssrc_field_count: Option<u32>,
    stream_pair_match_count: Option<u32>,
    correlated_session_match_count: Option<u32>,
    client_session_pair_match_count: Option<u32>,
}
impl Summary {
    fn from_result(identity: &Identity, healthy: bool, result: Result<plist::Value, Error>) -> Self {
        let mut summary = Self { version: 1, media_healthy: healthy, ..Default::default() };
        let value = match result {
            Ok(value) => value,
            Err(failure) => {
                summary.query_timed_out = failure.cause == Cause::Timeout;
                summary.failure_stage = Some(failure.stage as u32 + 1);
                summary.failure_cause = Some(failure.cause as u32 + 1);
                return summary;
            }
        };
        summary.query_succeeded = true;
        let root = value.as_dictionary();
        let server = root.and_then(|d| d.get("serverInfo"));
        // getMediaStreamServerStatus returns DeviceServerInfo itself. The
        // serverInfo wrapper belongs to StopResponse, not this query's schema.
        let sessions = root.and_then(|d| d.get("sessions"));
        summary.root_is_dictionary = Some(root.is_some());
        summary.server_info_present = Some(server.is_some());
        summary.server_info_is_dictionary = Some(server.is_some_and(|v| v.as_dictionary().is_some()));
        summary.sessions_present = Some(sessions.is_some());
        summary.sessions_is_array = Some(sessions.is_some_and(|v| v.as_array().is_some()));
        let mut scan = Scan::default();
        scan.visit(&value, 0, Place::Root, identity);
        summary.truncated = scan.truncated;
        summary.scan_complete = !scan.truncated;
        summary.visited_node_count = scan.nodes;
        summary.visited_byte_count = scan.bytes;
        // An incomplete tree cannot establish an absent match or complete count.
        if !scan.truncated {
            summary.session_count = sessions.and_then(plist::Value::as_array).map(|v| v.len() as u32);
            summary.opaque_data_present = Some(scan.opaque_data);
            summary.session_uuid_match_count = Some(scan.session_matches);
            summary.call_uuid_match_count = Some(scan.call_matches);
            summary.stream_config_count = Some(scan.configs);
            summary.local_ssrc_field_count = Some(scan.local_fields);
            summary.remote_ssrc_field_count = Some(scan.remote_fields);
            summary.stream_pair_match_count = Some(scan.pair_matches);
            summary.correlated_session_match_count = Some(scan.correlated_sessions);
            summary.client_session_pair_match_count = Some(scan.client_session_pairs);
        }
        summary
    }
}

pub(crate) async fn query(
    identity: &Identity, healthy: &AtomicBool,
    request: impl Future<Output = Result<plist::Value, Error>>,
) -> Result<Vec<u8>, Error> {
    query_for(identity, healthy, request, Duration::from_secs(2)).await
}
async fn query_for(
    identity: &Identity, healthy: &AtomicBool,
    request: impl Future<Output = Result<plist::Value, Error>>, deadline: Duration,
) -> Result<Vec<u8>, Error> {
    if !healthy.load(Ordering::SeqCst) { return Err(error(Stage::Media, Cause::MediaInactive)); }
    let result = tokio::time::timeout(deadline, request).await
        .unwrap_or_else(|_| Err(error(Stage::Media, Cause::Timeout)));
    serde_json::to_vec(&Summary::from_result(identity, healthy.load(Ordering::SeqCst), result))
        .map_err(|_| error(Stage::Media, Cause::Protocol))
}

#[derive(Clone, Copy)]
enum Place { Root, Sessions, Session, Connection, Config, Options, ClientSession, ClientSessionUUID, Other }
impl Place {
    fn child(self, key: &str) -> Self {
        match (self, key) {
            (Self::Root, "sessions") => Self::Sessions,
            (Self::Session, "connection") => Self::Connection,
            (Self::Connection, "streamConfig") => Self::Config,
            (Self::Connection, "options") => Self::Options,
            (Self::Options, "avcMediaStreamOptionClientSessionID") => Self::ClientSession,
            (Self::ClientSession, "uuid") => Self::ClientSessionUUID,
            _ => Self::Other,
        }
    }
}
#[derive(Default)]
struct Scan {
    nodes: u32,
    bytes: u32,
    truncated: bool,
    opaque_data: bool,
    session_matches: u32,
    call_matches: u32,
    configs: u32,
    local_fields: u32,
    remote_fields: u32,
    pair_matches: u32,
    correlated_sessions: u32,
    client_session_pairs: u32,
}
impl Scan {
    fn add_bytes(&mut self, count: usize) -> bool {
        if count > (MAX_BYTES - self.bytes) as usize { self.truncated = true; return false; }
        self.bytes += count as u32;
        true
    }
    fn visit(&mut self, value: &plist::Value, depth: usize, place: Place, identity: &Identity) -> u8 {
        if self.truncated { return 0; }
        if depth > MAX_DEPTH || self.nodes == MAX_NODES { self.truncated = true; return 0; }
        self.nodes += 1;
        // Bits report only observations in this subtree: the two UUID string
        // matches, a stream pair and the candidate client-session UUID path.
        let mut evidence = 0;
        match value {
            plist::Value::Dictionary(values) => {
                if matches!(place, Place::Config) {
                    self.configs += 1;
                    let local = values.get("LocalSSRC");
                    let remote = values.get("RemoteSSRC");
                    self.local_fields += u32::from(local.is_some());
                    self.remote_fields += u32::from(remote.is_some());
                    let pair_matches =
                        local.and_then(plist::Value::as_unsigned_integer) == Some(u64::from(identity.sender))
                        && remote.and_then(plist::Value::as_unsigned_integer) == Some(u64::from(identity.receiver));
                    self.pair_matches += u32::from(pair_matches);
                    if pair_matches { evidence |= 4; }
                }
                for (key, child) in values {
                    if !self.add_bytes(key.len()) { return 0; }
                    evidence |= self.visit(child, depth + 1, place.child(key), identity);
                    if self.truncated { return 0; }
                }
                if matches!(place, Place::Session) {
                    if evidence & 7 == 7 { self.correlated_sessions += 1; }
                    if evidence & 12 == 12 { self.client_session_pairs += 1; }
                }
            }
            plist::Value::Array(values) => {
                let child_place = if matches!(place, Place::Sessions) { Place::Session } else { Place::Other };
                for child in values {
                    evidence |= self.visit(child, depth + 1, child_place, identity);
                    if self.truncated { return 0; }
                }
            }
            plist::Value::String(value) => {
                if !self.add_bytes(value.len()) { return 0; }
                // Canonical hyphenated UUID strings only. No substring, key or
                // opaque Data decoding; data may conceal unsupported identity fields.
                if value.len() == 36 {
                    if let Ok(value) = uuid::Uuid::try_parse(value) {
                        self.session_matches += u32::from(value == identity.session);
                        self.call_matches += u32::from(value == identity.call);
                        if value == identity.session { evidence |= 1; }
                        if value == identity.call { evidence |= 2; }
                        // Fixed sending-path candidate only; its presence in
                        // phone status remains diagnostic, never release authority.
                        if matches!(place, Place::ClientSessionUUID) && value == identity.session { evidence |= 8; }
                    }
                }
            }
            plist::Value::Data(value) => {
                if self.add_bytes(value.len()) { self.opaque_data = true; }
            }
            _ => {}
        }
        evidence
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use plist::Value as V;
    fn identity() -> Identity {
        Identity::new(uuid::Uuid::from_u128(1), uuid::Uuid::from_u128(2), 22, 11)
    }
    fn dict(values: impl IntoIterator<Item = (&'static str, V)>) -> V {
        plist::Dictionary::from_iter(values).into()
    }
    fn report(value: V) -> serde_json::Value {
        serde_json::to_value(Summary::from_result(&identity(), true, Ok(value))).unwrap()
    }
    fn status(config: V) -> V {
        dict([("sessions", V::Array(vec![
            dict([("connection", dict([("streamConfig", config)]))]),
        ]))])
    }
    #[test]
    fn summary_is_fixed_private_and_matches_only_canonical_string_values() {
        let id = identity();
        let session = id.session.to_string();
        let config = dict([("LocalSSRC", 22u32.into()), ("RemoteSSRC", 11u32.into())]);
        let mut value = status(config).into_dictionary().unwrap();
        value.insert("unknown-secret-key".into(), V::Array(vec![
            session.to_uppercase().into(), id.call.to_string().into(),
            format!("prefix-{session}").into(), id.session.simple().to_string().into(),
            V::Data(id.session.as_bytes().to_vec()), "private-address-device-offer".into(),
        ]));
        value.insert(session.clone(), false.into()); // keys never match UUIDs
        let report = report(value.into());
        assert_eq!(report["sessionUUIDMatchCount"], 1);
        assert_eq!(report["callUUIDMatchCount"], 1);
        assert_eq!(report["opaqueDataPresent"], true);
        assert_eq!(report["streamPairMatchCount"], 1);
        assert_eq!(report["sessionCount"], 1);
        assert_eq!(report["serverInfoPresent"], false);
        assert_eq!(report["sessionsPresent"], true);
        assert_eq!(report["sessionsIsArray"], true);
        assert_eq!(report["correlatedSessionMatchCount"], 0, "Top-level UUIDs cannot correlate a known session");
        assert_eq!(report["clientSessionPairMatchCount"], 0);
        assert_eq!(report.as_object().unwrap().len(), 25);
        assert!(report.as_object().unwrap().values().all(|v| v.is_boolean() || v.is_u64() || v.is_null()));
        let encoded = report.to_string();
        for secret in [session.as_str(), "unknown-secret-key", "private-address-device-offer", "RemoteSSRC", "LocalSSRC"] {
            assert!(!encoded.contains(secret));
        }
    }
    #[test]
    fn missing_shape_differs_from_empty_sessions_and_nonmatching_streams() {
        let missing = report(dict([]));
        assert_eq!(missing["serverInfoPresent"], false);
        assert_eq!(missing["sessionsPresent"], false);
        assert!(missing["sessionCount"].is_null());
        assert_eq!(missing["streamConfigCount"], 0);
        let empty = report(dict([("sessions", V::Array(vec![]))]));
        assert_eq!(empty["serverInfoPresent"], false);
        assert_eq!(empty["sessionsIsArray"], true);
        assert_eq!(empty["sessionCount"], 0);
        let wrong = report(status(dict([("LocalSSRC", 22u32.into()), ("RemoteSSRC", 99u32.into())])));
        assert_eq!(wrong["streamConfigCount"], 1);
        assert_eq!(wrong["localSSRCFieldCount"], 1);
        assert_eq!(wrong["remoteSSRCFieldCount"], 1);
        assert_eq!(wrong["streamPairMatchCount"], 0);
        let unknown = report(dict([("streamConfig", dict([("LocalSSRC", 22u32.into()), ("RemoteSSRC", 11u32.into())]))]));
        assert_eq!(unknown["streamConfigCount"], 0, "Only the known sessions/connection shape is classified");
    }
    #[test]
    fn correlation_requires_both_uuid_strings_and_direct_stream_pair_in_one_session() {
        let id = identity();
        let entry = |session: bool, call: bool, direct: bool| {
            let config = dict([("LocalSSRC", 22u32.into()), ("RemoteSSRC", 11u32.into())]);
            let mut fields = vec![("options", V::Array([
                session.then(|| V::String(id.session.to_string())),
                call.then(|| V::String(id.call.to_string())),
            ].into_iter().flatten().collect()))];
            fields.push((if direct { "connection" } else { "unknownConnection" }, dict([("streamConfig", config)])));
            dict(fields)
        };
        for (entries, expected) in [
            (vec![entry(true, true, true)], 1),
            (vec![entry(true, false, true), entry(false, true, true)], 0),
            (vec![entry(true, true, false)], 0),
        ] {
            let report = report(dict([("sessions", V::Array(entries))]));
            assert_eq!(report["sessionUUIDMatchCount"], 1);
            assert_eq!(report["callUUIDMatchCount"], 1);
            assert_eq!(report["correlatedSessionMatchCount"], expected);
            assert_eq!(report["scanComplete"], true);
        }
        let wrapped = report(dict([("serverInfo", dict([("sessions", V::Array(vec![entry(true, true, true)]))]))]));
        assert_eq!(wrapped["serverInfoPresent"], true);
        assert_eq!(wrapped["serverInfoIsDictionary"], true);
        assert_eq!(wrapped["sessionsPresent"], false);
        assert_eq!(wrapped["sessionsIsArray"], false);
        assert!(wrapped["sessionCount"].is_null());
        assert_eq!(wrapped["sessionUUIDMatchCount"], 1);
        assert_eq!(wrapped["callUUIDMatchCount"], 1);
        assert_eq!(wrapped["streamConfigCount"], 0);
        assert_eq!(wrapped["streamPairMatchCount"], 0);
        assert_eq!(wrapped["correlatedSessionMatchCount"], 0,
            "StopResponse's wrapper is not a known server-status query shape");
    }
    #[test]
    fn client_session_pair_requires_exact_candidate_path_and_same_entry_stream_pair() {
        let id = identity();
        let entry = |value: V, receiver: u32, options_key: &'static str, call: bool| {
            let mut fields = vec![("connection", dict([
                ("streamConfig", dict([("LocalSSRC", 22u32.into()), ("RemoteSSRC", receiver.into())])),
                (options_key, dict([("avcMediaStreamOptionClientSessionID", dict([("uuid", value)]))])),
            ]))];
            if call { fields.push(("otherValue", id.call.to_string().into())); }
            dict(fields)
        };
        for (entries, client_pairs, both_uuid_pairs) in [
            (vec![entry(id.session.to_string().to_uppercase().into(), 11, "options", false)], 1, 0),
            (vec![entry(id.session.to_string().into(), 11, "options", true)], 1, 1),
            (vec![entry(id.session.to_string().into(), 11, "unknownOptions", true)], 0, 1),
            (vec![entry(id.session.to_string().into(), 99, "options", false),
                entry(id.call.to_string().into(), 11, "options", false)], 0, 0),
            (vec![entry(V::Data(id.session.as_bytes().to_vec()), 11, "options", false)], 0, 0),
        ] {
            let report = report(dict([("sessions", V::Array(entries))]));
            assert_eq!(report["clientSessionPairMatchCount"], client_pairs);
            assert_eq!(report["correlatedSessionMatchCount"], both_uuid_pairs,
                "The independent candidate-path count must preserve the existing correlation meaning");
            assert_eq!(report["scanComplete"], true);
        }
        let wrapped = report(dict([("serverInfo", dict([("sessions", V::Array(vec![
            entry(id.session.to_string().into(), 11, "options", false),
        ]))]))]));
        assert_eq!(wrapped["sessionUUIDMatchCount"], 1);
        assert_eq!(wrapped["clientSessionPairMatchCount"], 0, "Unknown wrappers never match the candidate path");
    }
    #[test]
    fn every_scan_budget_leaves_matches_unknown_and_counts_bounded() {
        let mut deep: V = identity().session.to_string().into();
        for _ in 0..=MAX_DEPTH { deep = V::Array(vec![deep]); }
        for value in [deep, V::Array(vec![false.into(); MAX_NODES as usize]),
            V::String("x".repeat(MAX_BYTES as usize + 1)),
            dict([("key", V::Data(vec![0; MAX_BYTES as usize]))])] {
            let report = report(value);
            assert_eq!(report["truncated"], true);
            assert_eq!(report["scanComplete"], false);
            assert!(report["visitedNodeCount"].as_u64().unwrap() <= u64::from(MAX_NODES));
            assert!(report["visitedByteCount"].as_u64().unwrap() <= u64::from(MAX_BYTES));
            for field in ["sessionCount", "opaqueDataPresent", "sessionUUIDMatchCount", "callUUIDMatchCount",
                "streamConfigCount", "localSSRCFieldCount", "remoteSSRCFieldCount", "streamPairMatchCount",
                "correlatedSessionMatchCount", "clientSessionPairMatchCount"] {
                assert!(report[field].is_null(), "{field}");
            }
        }
    }
    #[tokio::test]
    async fn query_errors_are_one_read_only_summary_and_unhealthy_rejects_before_polling() {
        let healthy = AtomicBool::new(true);
        let calls = std::cell::Cell::new(0);
        let bytes = query(&identity(), &healthy, async { calls.set(calls.get() + 1); Ok(dict([])) }).await.unwrap();
        let success: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(calls.get(), 1);
        assert_eq!(success["querySucceeded"], true);
        assert_eq!(success["queryTimedOut"], false);
        assert!(success["failureStage"].is_null() && success["failureCause"].is_null());
        for failure in [error(Stage::VideoService, Cause::Protocol), error(Stage::Media, Cause::Timeout)] {
            let calls = std::cell::Cell::new(0);
            let bytes = query(&identity(), &healthy, async { calls.set(calls.get() + 1); Err(failure) }).await.unwrap();
            assert_eq!(calls.get(), 1);
            let report: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(report["querySucceeded"], false);
            assert_eq!(report["failureStage"], failure.stage as u32 + 1);
            assert_eq!(report["failureCause"], failure.cause as u32 + 1);
            assert_eq!(report["queryTimedOut"], failure.cause == Cause::Timeout);
            assert!(report["rootIsDictionary"].is_null());
            assert!(report["sessionUUIDMatchCount"].is_null());
            assert!(report["clientSessionPairMatchCount"].is_null());
            assert!(healthy.load(Ordering::SeqCst));
        }
        healthy.store(false, Ordering::SeqCst);
        assert_eq!(query(&identity(), &healthy, async { panic!("Unhealthy media must not query") }).await,
            Err(error(Stage::Media, Cause::MediaInactive)));
    }
    #[tokio::test]
    async fn query_deadline_drops_only_scoped_request_and_cancellation_is_not_a_report() {
        struct Dropped<'a>(&'a AtomicBool);
        impl Drop for Dropped<'_> { fn drop(&mut self) { self.0.store(true, Ordering::SeqCst); } }
        let healthy = AtomicBool::new(true);
        let dropped = AtomicBool::new(false);
        let request = async { let _drop = Dropped(&dropped); std::future::pending().await };
        let bytes = query_for(&identity(), &healthy, request, Duration::from_millis(1)).await.unwrap();
        let report: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(report["queryTimedOut"], true);
        assert!(dropped.load(Ordering::SeqCst));
        assert!(healthy.load(Ordering::SeqCst));
        dropped.store(false, Ordering::SeqCst);
        let id = identity();
        let request = async { let _drop = Dropped(&dropped); std::future::pending().await };
        assert!(tokio::time::timeout(Duration::from_millis(1), query(&id, &healthy, request)).await.is_err());
        assert!(dropped.load(Ordering::SeqCst));
        assert!(healthy.load(Ordering::SeqCst));
    }
}
