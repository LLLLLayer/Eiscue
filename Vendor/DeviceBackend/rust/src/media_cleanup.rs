// SPDX-License-Identifier: GPL-3.0-only
//! Same-process release evidence. Never serialized, logged, or inferred from status.
use crate::{Cause, Error, ExistingIdentity, Stage, error};
use std::sync::{Arc, Mutex};

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct Binding {
    controller_id: String,
    controller_key: [u8; 32],
    peer_id: String,
    peer_key: [u8; 32],
    peer_udid: String,
    peer_model: String,
    alt_irk: Vec<u8>,
}
impl Binding {
    pub fn new(identity: &ExistingIdentity) -> Self {
        Self {
            controller_id: identity.controller.identifier.clone(),
            controller_key: identity.controller.e_public_key.to_bytes(),
            peer_id: identity.peer.pairing_identifier.clone(),
            peer_key: identity.peer.long_term_public_key,
            peer_udid: identity.peer.peer.remotepairing_udid.clone(),
            peer_model: identity.peer.peer.model.clone(),
            alt_irk: identity.peer.peer.alt_irk.clone(),
        }
    }
}
impl Drop for Binding {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.alt_irk.zeroize();
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
pub(crate) struct Receipt {
    session: uuid::Uuid,
    local: u32,
    remote: u32,
}
#[derive(Clone, Copy, Default, Eq, PartialEq)]
pub(crate) enum State {
    #[default]
    Idle,
    Unknown,
    Owned(Receipt),
}
#[derive(Default)]
pub(crate) struct Tracking {
    pub state: State,
    detached: bool,
}
pub(crate) type Shared = Arc<Mutex<Tracking>>;
pub(crate) fn set(state: &Shared, value: State) -> Result<(), Error> {
    state.lock().map_err(|_| unconfirmed())?.state = value;
    Ok(())
}
pub(crate) fn begin(state: &Shared) -> Result<(), Error> {
    let mut tracking = state.lock().map_err(|_| unconfirmed())?;
    if tracking.detached || tracking.state != State::Idle { return Err(unconfirmed()); }
    tracking.state = State::Unknown;
    Ok(())
}
pub(crate) fn detach(state: &Shared) -> Result<(), Error> {
    state.lock().map_err(|_| unconfirmed())?.detached = true;
    Ok(())
}
fn unconfirmed() -> Error { error(Stage::Media, Cause::DeliveryUncertain) }

impl Receipt {
    /// Only the original reply can establish ownership. The source SSRC must
    /// agree with the negotiated video answer; status is never an adoption path.
    pub fn from_start(answer: &plist::Value, session: uuid::Uuid, local: u32) -> Option<Self> {
        let connection = answer.as_dictionary()?.get("connection")?.as_dictionary()?;
        let (actual_local, remote) = stream_pair(connection)?;
        (actual_local == local && !session.is_nil()).then_some(Self { session, local, remote })
    }

    /// Every entry must have the known direct identity/configuration shape.
    /// A partial tree or conflicting use of either identifier rejects the stop.
    pub fn matches_status(&self, status: &plist::Value) -> bool {
        let Some(sessions) = sessions(status) else { return false };
        let mut matches = 0;
        for session in sessions {
            let Some(candidate) = entry(session) else { return false };
            if candidate.session == self.session || candidate.remote == self.remote {
                if candidate != *self { return false; }
                matches += 1;
            }
        }
        matches == 1
    }

    /// Confirmation is accepted only from the response to our scoped stop.
    /// A status query with zero matches is never confirmation.
    pub fn confirms_stop(&self, reply: &plist::Value) -> bool {
        if !bounded_tree(reply) { return false; }
        let Some(server) = reply.as_dictionary().and_then(|d| d.get("serverInfo")) else { return false };
        let Some(sessions) = sessions(server) else { return false };
        sessions.iter().all(|session| entry(session)
            .is_some_and(|other| other.session != self.session && other.remote != self.remote))
    }

    pub fn remote(&self) -> u32 { self.remote }
}

fn stream_pair(connection: &plist::Dictionary) -> Option<(u32, u32)> {
    let config = connection.get("streamConfig")?.as_dictionary()?;
    let number = |name| config.get(name)?.as_unsigned_integer()
        .and_then(|n| u32::try_from(n).ok()).filter(|n| *n != 0);
    Some((number("LocalSSRC")?, number("RemoteSSRC")?))
}
fn entry(value: &plist::Value) -> Option<Receipt> {
    let connection = value.as_dictionary()?.get("connection")?.as_dictionary()?;
    let (local, remote) = stream_pair(connection)?;
    let session = connection.get("options")?.as_dictionary()?
        .get("avcMediaStreamOptionClientSessionID")?.as_dictionary()?
        .get("uuid")?.as_string()?;
    if session.len() != 36 { return None; }
    let session = uuid::Uuid::try_parse(session).ok()?;
    (!session.is_nil()).then_some(Receipt { session, local, remote })
}
fn sessions(value: &plist::Value) -> Option<&[plist::Value]> {
    if !bounded_tree(value) { return None; }
    let root = value.as_dictionary()?;
    // DeviceServerInfo's required scalar fields guard against mistaking an
    // arbitrary nested sessions array or a StopResponse for the status schema.
    root.get("running")?.as_boolean()?;
    root.get("runDurationSeconds")?.as_unsigned_integer()?;
    Some(root.get("sessions")?.as_array()?.as_slice())
}

fn bounded_tree(value: &plist::Value) -> bool {
    fn visit(value: &plist::Value, depth: usize, nodes: &mut usize, bytes: &mut usize) -> Option<()> {
        if depth > 10 || *nodes >= 4096 { return None; }
        *nodes += 1;
        let mut add = |n: usize| {
            *bytes = bytes.checked_add(n)?;
            (*bytes <= 1024 * 1024).then_some(())
        };
        match value {
            plist::Value::Dictionary(values) => {
                for key in values.keys() { add(key.len())?; }
                for child in values.values() { visit(child, depth + 1, nodes, bytes)?; }
            }
            plist::Value::Array(values) => for child in values { visit(child, depth + 1, nodes, bytes)?; },
            plist::Value::String(value) => add(value.len())?,
            plist::Value::Data(value) => add(value.len())?,
            _ => {}
        }
        Some(())
    }
    visit(value, 0, &mut 0, &mut 0).is_some()
}

pub(crate) async fn release_with<Q, QF, S, SF>(
    shared: &Shared, query: Q, stop: S,
) -> Result<(), Error>
where
    Q: FnOnce() -> QF, QF: std::future::Future<Output = Result<plist::Value, Error>>,
    S: FnOnce(u32) -> SF, SF: std::future::Future<Output = Result<plist::Value, Error>>,
{
    let receipt = match shared.lock().map_err(|_| unconfirmed())?.state {
        State::Idle => return Ok(()),
        State::Unknown => return Err(unconfirmed()),
        State::Owned(receipt) => receipt,
    };
    if !receipt.matches_status(&query().await?) { return Err(unconfirmed()); }
    let reply = stop(receipt.remote()).await?;
    if !receipt.confirms_stop(&reply) { return Err(unconfirmed()); }
    let mut state = shared.lock().map_err(|_| unconfirmed())?;
    if state.state != State::Owned(receipt) { return Err(unconfirmed()); }
    state.state = State::Idle;
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use plist::Value as V;
    use std::{cell::Cell, time::Duration};

    fn dict<const N: usize>(rows: [(&str, V); N]) -> V {
        plist::Dictionary::from_iter(rows).into()
    }
    pub(crate) fn owned() -> Receipt {
        Receipt { session: uuid::Uuid::from_u128(123), local: 22, remote: 11 }
    }
    fn row(receipt: Receipt) -> V {
        dict([("connection", dict([
            ("streamConfig", dict([("LocalSSRC", receipt.local.into()), ("RemoteSSRC", receipt.remote.into())])),
            ("options", dict([("avcMediaStreamOptionClientSessionID", dict([("uuid", receipt.session.to_string().into())]))])),
        ]))])
    }
    fn status(rows: Vec<V>) -> V {
        dict([("running", true.into()), ("runDurationSeconds", 12u32.into()), ("sessions", V::Array(rows))])
    }
    fn stopped(rows: Vec<V>) -> V { dict([("serverInfo", status(rows))]) }
    fn shared() -> Shared {
        Arc::new(Mutex::new(Tracking { state: State::Owned(owned()), detached: true }))
    }
    fn is_owned(shared: &Shared) -> bool { shared.lock().unwrap().state == State::Owned(owned()) }

    #[test]
    fn original_start_only_and_both_ssrc_roles_are_required() {
        let receipt = owned();
        assert!(Receipt::from_start(&row(receipt), receipt.session, 22) == Some(receipt));
        for value in [status(vec![row(receipt)]), dict([]), row(Receipt { remote: 0, ..receipt }),
            row(Receipt { local: 0, ..receipt })]
        {
            assert!(Receipt::from_start(&value, receipt.session, 22).is_none());
        }
        assert!(Receipt::from_start(&row(receipt), receipt.session, 99).is_none());
        assert!(Receipt::from_start(&row(receipt), uuid::Uuid::nil(), 22).is_none());
    }

    #[test]
    fn complete_status_requires_unique_uuid_pair_and_no_remote_identifier_collision() {
        let receipt = owned();
        let other = Receipt { session: uuid::Uuid::from_u128(456), local: 88, remote: 99 };
        assert!(receipt.matches_status(&status(vec![row(receipt), row(other)])));
        for rows in [
            vec![], vec![row(other)], vec![row(receipt), row(receipt)],
            vec![row(receipt), row(Receipt { remote: 11, ..other })],
            vec![row(receipt), row(Receipt { local: 88, ..receipt })],
            vec![row(receipt), dict([])],
        ] {
            assert!(!receipt.matches_status(&status(rows)));
        }
        assert!(!receipt.matches_status(&stopped(vec![row(receipt)])));
        let mut incomplete = status(vec![row(receipt)]).into_dictionary().unwrap();
        incomplete.remove("running");
        assert!(!receipt.matches_status(&incomplete.into()));
        let mut malformed = row(receipt).into_dictionary().unwrap();
        malformed.get_mut("connection").unwrap().as_dictionary_mut().unwrap().remove("options");
        assert!(!receipt.matches_status(&status(vec![malformed.into()])));
    }

    #[test]
    fn oversized_or_partial_tree_and_invalid_required_scalars_fail_closed() {
        let receipt = owned();
        let mut root = status(vec![row(receipt)]).into_dictionary().unwrap();
        for invalid in [V::Real(f64::NAN), V::Real(-1.0), V::Real(1.0), (-1i64).into(), "unknown".into()] {
            root.insert("runDurationSeconds".into(), invalid);
            assert!(!receipt.matches_status(&root.clone().into()));
        }
        root.insert("runDurationSeconds".into(), 1u32.into());
        assert!(receipt.matches_status(&root.clone().into()));
        for oversized in [V::Data(vec![0; 1024 * 1024]), V::Array(vec![true.into(); 4096])] {
            root.insert("other".into(), oversized);
            assert!(!receipt.matches_status(&root.clone().into()));
        }
        let mut deep = true.into();
        for _ in 0..12 { deep = V::Array(vec![deep]); }
        root.insert("other".into(), deep);
        assert!(!receipt.matches_status(&root.into()));
    }

    #[tokio::test]
    async fn scoped_stop_follows_one_exact_query_and_clears_only_after_complete_reply() {
        let state = shared();
        let calls = Cell::new(0);
        let other = Receipt { session: uuid::Uuid::from_u128(456), local: 88, remote: 99 };
        release_with(&state, || async {
            assert_eq!(calls.replace(1), 0);
            Ok(status(vec![row(owned()), row(other)]))
        }, |identifier| {
            assert_eq!(identifier, 11);
            async {
                assert_eq!(calls.replace(2), 1);
                assert!(is_owned(&state));
                Ok(stopped(vec![row(other)]))
            }
        }).await.unwrap();
        assert_eq!(calls.get(), 2);
        assert!(state.lock().unwrap().state == State::Idle);
        release_with(&state, || async { panic!("Settled receipt must not query") },
            |_| async { panic!("Settled receipt must not stop again") }).await.unwrap();
    }

    #[tokio::test]
    async fn absence_unknown_and_malformed_status_never_dispatch_stop_or_confirm() {
        for value in [status(vec![]), dict([]), stopped(vec![row(owned())])] {
            let state = shared();
            assert!(release_with(&state, || async { Ok(value) },
                |_| async { panic!("No exact complete match") }).await.is_err());
            assert!(is_owned(&state));
        }
        let state = shared();
        set(&state, State::Unknown).unwrap();
        assert!(release_with(&state, || async { panic!("Unknown starts cannot query-adopt") },
            |_| async { panic!("Unknown starts cannot stop") }).await.is_err());
    }

    #[tokio::test]
    async fn failed_timeout_and_cancelled_stop_retain_receipt_for_explicit_retry() {
        let state = shared();
        for failure in [Err(error(Stage::Media, Cause::Timeout)), Ok(dict([])),
            Ok(stopped(vec![row(owned())])), Ok(status(vec![]))]
        {
            assert!(release_with(&state, || async { Ok(status(vec![row(owned())])) },
                |_| async { failure }).await.is_err());
            assert!(is_owned(&state));
        }
        let stop_entered = Cell::new(false);
        assert!(tokio::time::timeout(Duration::from_millis(1),
            release_with(&state, || async { Ok(status(vec![row(owned())])) }, |_| async {
                stop_entered.set(true);
                std::future::pending().await
            })).await.is_err());
        assert!(stop_entered.get() && is_owned(&state));
        // A lost stop acknowledgement followed by absence remains unresolved.
        assert!(release_with(&state, || async { Ok(status(vec![])) },
            |_| async { panic!("Absent owner must not be stopped") }).await.is_err());
        assert!(is_owned(&state));
        release_with(&state, || async { Ok(status(vec![row(owned())])) },
            |_| async { Ok(stopped(vec![])) }).await.unwrap();
        assert!(state.lock().unwrap().state == State::Idle);
    }

    #[test]
    fn detach_latches_start_admission_even_after_late_original_completion() {
        let state: Shared = Default::default();
        begin(&state).unwrap();
        detach(&state).unwrap();
        // The already-dispatched original start may record its reply.
        set(&state, State::Owned(owned())).unwrap();
        assert!(begin(&state).is_err());
        // A late stop confirmation cannot rearm the detached transport.
        set(&state, State::Idle).unwrap();
        assert!(begin(&state).is_err());
        let fresh: Shared = Default::default();
        begin(&fresh).unwrap();
        assert!(begin(&fresh).is_err(), "Unresolved original start cannot be overwritten");
    }

    #[test]
    fn pairing_binding_changes_in_any_credential_generation_component_reject() {
        let identity = crate::ffi::fixture_identity();
        let binding = Binding::new(&identity);
        assert!(binding == Binding::new(&identity));
        for change in 0..7 {
            let mut changed = crate::ffi::fixture_identity();
            match change {
                0 => changed.controller.identifier.push('x'),
                1 => changed.controller.e_public_key = ed25519_dalek::SigningKey::from_bytes(&[9; 32]).verifying_key(),
                2 => changed.peer.pairing_identifier.push('x'),
                3 => changed.peer.long_term_public_key[0] ^= 1,
                4 => changed.peer.peer.remotepairing_udid.push('x'),
                5 => changed.peer.peer.model.push('x'),
                _ => changed.peer.peer.alt_irk[0] ^= 1,
            }
            assert!(binding != Binding::new(&changed));
        }
    }
}
