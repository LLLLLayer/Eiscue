// SPDX-License-Identifier: GPL-3.0-only
//! Eiscue pairing host: protocol cryptography is provided by the MIT idevice library.
//! Durable provisional and committed acknowledgements are separate capability gates.
use super::*;
use idevice::{
    IdeviceError,
    remote_pairing::{PairRecordState, PairableHost, PairableHostInfo, RpPairingSocket},
};

fn persistence_error() -> IdeviceError {
    idevice::remote_pairing::errors::RemotePairingError::PairRecordPersistenceFailed.into()
}
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct PairingRecord<'a> {
    version: u8,
    seed: &'a [u8],
    #[serde(rename = "controllerID")]
    controller_id: &'a str,
    #[serde(rename = "peerID")]
    peer_id: &'a str,
    peer_public_key: &'a [u8],
    #[serde(rename = "alternateIRK")]
    alternate_irk: &'a [u8],
    #[serde(rename = "peerUDID")]
    peer_udid: &'a str,
    peer_model: &'a str,
    committed: bool,
}
struct Persistence {
    entry: Arc<Entry>,
    replies: Replies,
    acknowledgements: tokio::sync::Mutex<mpsc::Receiver<Request>>,
    secret: Zeroizing<[u8; 32]>,
    controller_id: String,
}
impl Persistence {
    async fn save(
        &self,
        state: PairRecordState,
        peer: VerifiedPeerIdentity,
    ) -> Result<(), IdeviceError> {
        let committed = state == PairRecordState::Committed;
        let sequence = if committed { 2 } else { 1 };
        let record = PairingRecord {
            version: 1,
            seed: self.secret.as_slice(),
            controller_id: &self.controller_id,
            peer_id: &peer.pairing_identifier,
            peer_public_key: &peer.long_term_public_key,
            alternate_irk: &peer.peer.alt_irk,
            peer_udid: &peer.peer.remotepairing_udid,
            peer_model: &peer.peer.model,
            committed,
        };
        let data = serde_json::to_vec(&record).map_err(|_| persistence_error())?;
        self.entry.pairing_state.store(sequence, Ordering::SeqCst);
        self.entry.ready.store(true, Ordering::SeqCst);
        let delivered = self
            .replies
            .send(Event::ok(0, if committed { 8 } else { 7 }, data))
            .await;
        let acknowledged = if delivered {
            tokio::time::timeout(std::time::Duration::from_secs(10), async {
                self.acknowledgements.lock().await.recv().await
            })
            .await
            .ok()
            .flatten()
        } else {
            None
        };
        self.entry.ready.store(false, Ordering::SeqCst);
        self.entry.pairing_state.store(0, Ordering::SeqCst);
        match acknowledged {
            Some(request) if request.action == 6 && request.id == sequence as u64 => Ok(()),
            _ => Err(persistence_error()),
        }
    }
}
async fn pair(
    entry: Arc<Entry>,
    commands: mpsc::Receiver<Request>,
    replies: Replies,
) -> Result<(), IdeviceError> {
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::UNSPECIFIED, 0)).await?;
    let mut identity = RpPairingFile::generate("Eiscue");
    // Eiscue identity invariant: a new key always gets a fresh controller UUID.
    identity.identifier = uuid::Uuid::new_v4().to_string();
    let mut host_info = PairableHostInfo::generate("Eiscue", "Mac17,7");
    host_info.identifier = identity.identifier.clone();
    host_info.udid = uuid::Uuid::new_v4().to_string();
    let advertisement = serde_json::json!({
        "identifier": identity.identifier,
        "port": listener.local_addr()?.port(),
        "txt": host_info.mdns_txt_records(&identity.identifier).into_iter().collect::<HashMap<_, _>>()
    });
    if !replies
        .send(Event::ok(
            0,
            5,
            serde_json::to_vec(&advertisement).map_err(|_| persistence_error())?,
        ))
        .await
    {
        return Err(persistence_error());
    }
    let (socket, _) = listener.accept().await?;
    drop(listener);
    let mut accepted = Event::ok(0, 10, Vec::new());
    accepted.header.stage = 1;
    if !replies.send(accepted).await {
        return Err(persistence_error());
    }
    let persistence = Arc::new(Persistence {
        entry,
        replies: replies.clone(),
        acknowledgements: tokio::sync::Mutex::new(commands),
        secret: Zeroizing::new(identity.e_private_key.to_bytes()),
        controller_id: identity.identifier.clone(),
    });
    let pin_replies = replies.clone();
    let mut responder = PairableHost::new(RpPairingSocket::new_device(socket), host_info);
    responder
        .accept_fallible(
            &mut identity,
            move |pin| async move {
                if pin_replies.send(Event::ok(0, 6, pin.into_bytes())).await {
                    Ok(())
                } else {
                    Err(persistence_error())
                }
            },
            move |state, peer| {
                let persistence = persistence.clone();
                async move { persistence.save(state, peer).await }
            },
        )
        .await?;
    if replies.send(Event::ok(0, 9, Vec::new())).await {
        Ok(())
    } else {
        Err(persistence_error())
    }
}
/// # Safety
/// handle must be writable. Consent 1 is the explicit new-pairing operation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_pairing_start(consent: u32, handle: *mut u64) -> i32 {
    protect(|| unsafe {
        publish(handle, || {
            if consent != 1 {
                return Err(INVALID);
            }
            start_worker(
                "eiscue-pairing",
                true,
                false,
                None,
                |entry, commands, replies| async move {
                    let outcome = tokio::time::timeout(
                        std::time::Duration::from_secs(180),
                        pair(entry.clone(), commands, replies.clone()),
                    )
                    .await;
                    entry.ready.store(false, Ordering::SeqCst);
                    if !matches!(outcome, Ok(Ok(()))) {
                        let mut failure = Event::ok(0, 3, Vec::new());
                        failure.header.stage = 201;
                        failure.header.cause = 1;
                        replies.send(failure).await;
                    }
                },
            )
        })
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn ncm_pairing_ack(handle: u64, state: u32) -> i32 {
    protect(|| {
        if state != 1 && state != 2 {
            return INVALID;
        }
        let Some(entry) = get(handle) else {
            return CLOSED;
        };
        if !entry.pairing {
            return INVALID;
        }
        let Ok(mut submission) = entry.submit.lock() else {
            return INVALID;
        };
        if entry.done.load(Ordering::SeqCst) {
            return CLOSED;
        }
        if !entry.ready.load(Ordering::SeqCst)
            || entry.pairing_state.load(Ordering::SeqCst) != state as usize
        {
            return NOT_READY;
        }
        if submission.0 + 1 != u64::from(state) {
            return INVALID;
        }
        // Revoke this phase before waking its consumer. Clearing it after send
        // could erase the next phase if the worker advances on another thread.
        if entry
            .pairing_state
            .compare_exchange(state as usize, 0, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return NOT_READY;
        }
        let request = Request::empty(u64::from(state), 6);
        match submission.1.try_send(request) {
            Ok(()) => {
                submission.0 = state.into();
                0
            }
            Err(mpsc::error::TrySendError::Full(_)) => {
                let _ = entry.pairing_state.compare_exchange(
                    0,
                    state as usize,
                    Ordering::SeqCst,
                    Ordering::SeqCst,
                );
                BUSY
            }
            Err(mpsc::error::TrySendError::Closed(_)) => CLOSED,
        }
    })
}
