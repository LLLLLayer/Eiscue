// SPDX-License-Identifier: GPL-3.0-only
//! Opaque, memory-only receipts survive transport close; poll handles never control.
use super::*;
use crate::media_cleanup::{Binding, Shared, State};

pub(super) struct Ownership {
    binding: Binding,
    pub state: Shared,
    _reservation: Reservation,
}
static OWNERSHIPS: AtomicUsize = AtomicUsize::new(0);
struct Reservation;
impl Drop for Reservation {
    fn drop(&mut self) { OWNERSHIPS.fetch_sub(1, Ordering::SeqCst); }
}
impl Ownership {
    pub(super) fn new(identity: &ExistingIdentity) -> Result<Self, i32> {
        // Reserve before accepting a control session, rather than discovering
        // during close that its only media receipt cannot be retained.
        OWNERSHIPS.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| (n < 2).then_some(n + 1))
            .map_err(|_| BUSY)?;
        let reservation = Reservation;
        Ok(Self { binding: Binding::new(identity), state: Default::default(), _reservation: reservation })
    }
}
struct Retained {
    ownership: Arc<Ownership>,
    drained: Arc<AtomicBool>,
    active: AtomicBool,
    disposed: AtomicBool,
    cancel: Mutex<Option<watch::Sender<bool>>>,
}
static RECEIPTS: OnceLock<Mutex<HashMap<u64, Arc<Retained>>>> = OnceLock::new();
fn receipts() -> &'static Mutex<HashMap<u64, Arc<Retained>>> {
    RECEIPTS.get_or_init(|| Mutex::new(HashMap::new()))
}
struct Attempt(Arc<Retained>);
impl Drop for Attempt {
    fn drop(&mut self) {
        if let Ok(mut cancel) = self.0.cancel.lock() { cancel.take(); }
        self.0.active.store(false, Ordering::SeqCst);
    }
}
fn claim(receipt: u64, identity: &ExistingIdentity) -> Result<Attempt, i32> {
    let retained = receipts().lock().map_err(|_| INVALID)?
        .get(&receipt).cloned().ok_or(CLOSED)?;
    if retained.ownership.binding != Binding::new(identity) { return Err(INVALID); }
    if !retained.drained.load(Ordering::SeqCst) { return Err(BUSY); }
    if retained.active.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_err() {
        return Err(BUSY);
    }
    let attempt = Attempt(retained);
    if attempt.0.disposed.load(Ordering::SeqCst) { return Err(CLOSED); }
    if matches!(attempt.0.ownership.state.lock().map_err(|_| INVALID)?.state, State::Unknown) {
        return Err(NOT_READY);
    }
    Ok(attempt)
}

/// # Safety
/// receipt must be writable. Detach never waits for old network work.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_detach_media_cleanup(handle: u64, receipt: *mut u64) -> i32 {
    protect(|| {
        if receipt.is_null() { return INVALID; }
        unsafe { *receipt = 0; }
        let Ok(mut retained) = receipts().lock() else { return INVALID };
        let Ok(mut entries) = registry().lock() else { return INVALID };
        let Some(entry) = entries.get(&handle) else { return CLOSED };
        let Some(ownership) = entry.cleanup.clone() else { return INVALID };
        let id = NEXT.fetch_add(1, Ordering::SeqCst);
        if id == 0 { return BUSY; }
        if crate::media_cleanup::detach(&ownership.state).is_err() { return INVALID; }
        let entry = entries.remove(&handle).unwrap();
        entry.ready.store(false, Ordering::SeqCst);
        let _ = entry.cancel.send(true);
        retained.insert(id, Arc::new(Retained {
            ownership, drained: entry.done.clone(), active: AtomicBool::new(false),
            disposed: AtomicBool::new(false), cancel: Mutex::new(None),
        }));
        unsafe { *receipt = id; }
        0
    })
}

/// Final local disposal is not evidence that remote media stopped.
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_dispose_media_cleanup(receipt: u64) {
    let _ = protect(|| {
        if let Some(retained) = receipts().lock().ok().and_then(|mut r| r.remove(&receipt)) {
            retained.disposed.store(true, Ordering::SeqCst);
            if let Ok(cancel) = retained.cancel.lock() {
                if let Some(cancel) = cancel.as_ref() { let _ = cancel.send(true); }
            }
        }
        0
    });
}

/// Read-only local evidence; never discovers, authenticates, or resets ownership.
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_confirm_media_cleanup(receipt: u64) -> i32 {
    protect(|| {
        let Ok(retained) = receipts().lock() else { return INVALID };
        let Some(retained) = retained.get(&receipt) else { return CLOSED };
        if retained.disposed.load(Ordering::SeqCst) { return CLOSED; }
        if !retained.drained.load(Ordering::SeqCst)
            || retained.active.load(Ordering::SeqCst)
        {
            return BUSY;
        }
        let Ok(tracking) = retained.ownership.state.lock() else { return INVALID };
        if tracking.state != State::Idle { return NOT_READY; }
        // An attempt may have claimed the receipt since the first snapshot.
        if retained.active.load(Ordering::SeqCst) { return BUSY; }
        0
    })
}

/// # Safety
/// Identity is borrowed only for this call; handle must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_local_vpn_cleanup_start_configured(
    receipt: u64, interface_index: u32, pairing_port: u16,
    local_ipv4: u32, peer_ipv4: u32, raw: *const Identity, handle: *mut u64,
) -> i32 {
    protect(|| {
        if raw.is_null() || handle.is_null() { return INVALID; }
        unsafe { *handle = 0; }
        let identity = match unsafe { identity(&*raw) } { Ok(id) => id, Err(e) => return e };
        let connector = match crate::local_vpn::LocalVPNConnector::configured(
            interface_index, pairing_port,
            std::net::Ipv4Addr::from(local_ipv4), std::net::Ipv4Addr::from(peer_ipv4),
        ) { Ok(c) => c, Err(_) => return INVALID };
        start(receipt, connector, identity, handle)
    })
}

/// # Safety
/// Config/identity are borrowed only for this call; handle must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_cleanup_start(
    receipt: u64, config: *const Config, raw: *const Identity, handle: *mut u64,
) -> i32 {
    protect(|| {
        if config.is_null() || raw.is_null() || handle.is_null() { return INVALID; }
        unsafe { *handle = 0; }
        let config = unsafe { &*config };
        if config.abi != 1 || config.endpoint_index >= 16 || config.permissions != VERIFY { return INVALID; }
        let identity = match unsafe { identity(&*raw) } { Ok(id) => id, Err(e) => return e };
        let connector = match RelayConnector::new(
            config.interface_index, config.generation, config.endpoint_index as u8,
        ) { Ok(c) => c, Err(_) => return INVALID };
        start(receipt, connector, identity, handle)
    })
}

fn start(receipt: u64, connector: impl NcmConnector + 'static,
    identity: ExistingIdentity, handle: *mut u64) -> i32
{
    let attempt = match claim(receipt, &identity) { Ok(a) => a, Err(e) => return e };
    match launch_cleanup(connector, identity, attempt) {
        Ok(id) => { unsafe { *handle = id; } 0 }
        Err(e) => e,
    }
}

fn launch_cleanup(connector: impl NcmConnector + 'static,
    mut identity: ExistingIdentity, attempt: Attempt) -> Result<u64, i32>
{
    WORKERS.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| (n < 2).then_some(n + 1))
        .map_err(|_| BUSY)?;
    let (tx, _rx) = mpsc::channel::<Request>(1);
    let (events, queue) = mpsc::channel(1);
    let (cancel, mut cancelled) = watch::channel(false);
    {
        let mut active_cancel = attempt.0.cancel.lock().map_err(|_| {
            WORKERS.fetch_sub(1, Ordering::SeqCst); INVALID
        })?;
        *active_cancel = Some(cancel.clone());
        if attempt.0.disposed.load(Ordering::SeqCst) { let _ = cancel.send(true); }
    }
    let entry = Arc::new(Entry {
        pairing: false, pairing_state: AtomicUsize::new(0),
        submit: Mutex::new((0, tx)), receive: Mutex::new(Receiver { pending: None, queue }),
        cancel, ready: AtomicBool::new(false), done: Arc::new(AtomicBool::new(false)),
        video: Arc::new(crate::video::VideoMailbox::default()), screen_allowed: false, cleanup: None,
    });
    let id = NEXT.fetch_add(1, Ordering::SeqCst);
    {
        let mut entries = registry().lock().map_err(|_| {
            WORKERS.fetch_sub(1, Ordering::SeqCst); INVALID
        })?;
        if id == 0 || entries.len() >= 2 {
            WORKERS.fetch_sub(1, Ordering::SeqCst);
            return Err(BUSY);
        }
        entries.insert(id, entry.clone());
    }
    let spawned = std::thread::Builder::new().name("ncm-media-cleanup".into()).spawn(move || {
        // These guards outlive runtime destruction: a new attempt cannot overlap
        // an old adapter task, pending stop, canceled query, or late response.
        let _attempt = attempt;
        struct Finished(Arc<Entry>);
        impl Drop for Finished {
            fn drop(&mut self) {
                self.0.done.store(true, Ordering::SeqCst);
                WORKERS.fetch_sub(1, Ordering::SeqCst);
            }
        }
        let _finished = Finished(entry);
        let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_all().build() else { return };
        let result = runtime.block_on(async {
            let work = async {
                let state = _attempt.0.ownership.state.lock()
                    .map_err(|_| crate::error(Stage::Media, Cause::DeliveryUncertain))?.state;
                match state {
                    State::Idle => Ok(()),
                    State::Unknown => Err(crate::error(Stage::Media, Cause::DeliveryUncertain)),
                    State::Owned(_) => {
                        let connection = Session::connect(&connector, &mut identity).await;
                        drop(identity); // no signing seed retained during status/stop
                        let mut session = connection?;
                        session.release_retained_media(&_attempt.0.ownership.state).await
                    }
                }
            };
            tokio::select! { biased;
                _ = cancelled.changed() => None,
                result = work => Some(result),
            }
        });
        drop(runtime); // all authenticated child transports are gone before receipt publication
        if let Some(result) = result {
            let event = match result {
                Ok(()) => Event::ok(0, 2, Vec::new()),
                Err(e) => Event::failed(0, e),
            };
            let _ = events.try_send(event);
        }
    });
    if spawned.is_err() {
        registry().lock().map_err(|_| INVALID)?.remove(&id);
        WORKERS.fetch_sub(1, Ordering::SeqCst);
        return Err(INVALID);
    }
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn original() -> (u64, Arc<Entry>, watch::Receiver<bool>) {
        let (tx, _) = mpsc::channel(1);
        let (_, queue) = mpsc::channel(1);
        let (cancel, cancelled) = watch::channel(false);
        let ownership = Arc::new(Ownership::new(&fixture_identity()).unwrap());
        crate::media_cleanup::set(&ownership.state,
            State::Owned(crate::media_cleanup::tests::owned())).unwrap();
        let entry = Arc::new(Entry {
            pairing: false, pairing_state: AtomicUsize::new(0),
            submit: Mutex::new((0, tx)), receive: Mutex::new(Receiver { pending: None, queue }),
            cancel, ready: AtomicBool::new(true), done: Arc::new(AtomicBool::new(false)),
            video: Arc::new(crate::video::VideoMailbox::default()),
            screen_allowed: true, cleanup: Some(ownership),
        });
        let id = NEXT.fetch_add(1, Ordering::SeqCst);
        registry().lock().unwrap().insert(id, entry.clone());
        (id, entry, cancelled)
    }
    async fn until(mut condition: impl FnMut() -> bool) {
        tokio::time::timeout(Duration::from_secs(2), async {
            while !condition() { tokio::time::sleep(Duration::from_millis(1)).await; }
        }).await.unwrap();
    }
    async fn event(handle: u64) -> EventHeader {
        let mut header = EventHeader::default();
        until(|| {
            let code = unsafe { ncm_backend_poll(handle, &mut header, std::ptr::null_mut(), 0) };
            assert!(code == 0 || code == EMPTY, "unexpected poll: {code}");
            code == 0
        }).await;
        header
    }
    struct NoNetwork;
    impl NcmConnector for NoNetwork {
        fn connect(&self, _: crate::Purpose) -> crate::DialFuture<'_> {
            panic!("Already settled receipts must not open any transport")
        }
    }
    struct FailingConnector(Arc<AtomicUsize>);
    impl NcmConnector for FailingConnector {
        fn connect(&self, purpose: crate::Purpose) -> crate::DialFuture<'_> {
            assert_eq!(purpose, crate::Purpose::PairVerify);
            self.0.fetch_add(1, Ordering::SeqCst);
            Box::pin(async { Err(std::io::ErrorKind::ConnectionAborted.into()) })
        }
    }
    struct PendingConnector(Arc<AtomicUsize>);
    impl NcmConnector for PendingConnector {
        fn connect(&self, _: crate::Purpose) -> crate::DialFuture<'_> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Box::pin(std::future::pending())
        }
    }

    #[tokio::test]
    async fn detach_revokes_old_apis_waits_for_drain_and_observes_late_stop_confirmation() {
        let _test = super::super::tests::TEST_LOCK.lock().await;
        let (old, entry, cancelled) = original();
        let mut receipt = 0;
        assert_eq!(unsafe { ncm_backend_detach_media_cleanup(old, &mut receipt) }, 0);
        assert!(receipt != old && receipt != 0);
        assert!(*cancelled.borrow());
        assert_eq!(ncm_backend_submit(old, 1, 3, 0, 0), CLOSED);
        assert_eq!(ncm_backend_video_refresh(old), CLOSED);
        assert!(matches!(claim(receipt, &fixture_identity()), Err(BUSY)));
        // A pending old stop settles before runtime destruction is reported.
        let state = &entry.cleanup.as_ref().unwrap().state;
        crate::media_cleanup::set(state, State::Idle).unwrap();
        assert!(crate::media_cleanup::begin(state).is_err());
        assert!(matches!(claim(receipt, &fixture_identity()), Err(BUSY)));
        entry.done.store(true, Ordering::SeqCst);
        let attempt = claim(receipt, &fixture_identity()).unwrap();
        let retained = attempt.0.clone();
        let handle = launch_cleanup(NoNetwork, fixture_identity(), attempt).unwrap();
        let outcome = event(handle).await;
        assert_eq!((outcome.kind, outcome.request_id, outcome.size), (2, 0, 0));
        assert_ne!(ncm_backend_submit(handle, 1, 3, 0, 0), 0);
        assert_eq!(ncm_backend_video_refresh(handle), NOT_READY);
        until(|| !retained.active.load(Ordering::SeqCst)).await;
        ncm_backend_close(handle);
        ncm_backend_dispose_media_cleanup(receipt);
        assert!(matches!(claim(receipt, &fixture_identity()), Err(CLOSED)));
    }

    #[tokio::test]
    async fn rejected_identity_unknown_start_and_failed_auth_keep_receipt_and_prevent_overlap() {
        let _test = super::super::tests::TEST_LOCK.lock().await;
        let (old, entry, _) = original();
        let mut receipt = 0;
        assert_eq!(unsafe { ncm_backend_detach_media_cleanup(old, &mut receipt) }, 0);
        entry.done.store(true, Ordering::SeqCst);
        let mut foreign = fixture_identity();
        foreign.peer.pairing_identifier.push('x');
        assert!(matches!(claim(receipt, &foreign), Err(INVALID)));
        let state = &entry.cleanup.as_ref().unwrap().state;
        crate::media_cleanup::set(state, State::Unknown).unwrap();
        assert!(matches!(claim(receipt, &fixture_identity()), Err(NOT_READY)));
        crate::media_cleanup::set(state, State::Owned(crate::media_cleanup::tests::owned())).unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        for _ in 0..2 {
            let attempt = claim(receipt, &fixture_identity()).unwrap();
            let retained = attempt.0.clone();
            assert!(matches!(claim(receipt, &fixture_identity()), Err(BUSY)));
            let handle = launch_cleanup(FailingConnector(calls.clone()), fixture_identity(), attempt).unwrap();
            let outcome = event(handle).await;
            assert_eq!((outcome.kind, outcome.stage), (3, Stage::NcmConnect as u32 + 1));
            until(|| !retained.active.load(Ordering::SeqCst)).await;
            assert!(matches!(state.lock().unwrap().state, State::Owned(_)));
            ncm_backend_close(handle);
        }
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        ncm_backend_dispose_media_cleanup(receipt);
    }

    #[tokio::test]
    async fn cancellation_waits_for_runtime_drop_before_retry_and_dispose_cancels_attempt() {
        let _test = super::super::tests::TEST_LOCK.lock().await;
        let (old, entry, _) = original();
        let mut receipt = 0;
        assert_eq!(unsafe { ncm_backend_detach_media_cleanup(old, &mut receipt) }, 0);
        entry.done.store(true, Ordering::SeqCst);
        let attempt = claim(receipt, &fixture_identity()).unwrap();
        let retained = attempt.0.clone();
        let calls = Arc::new(AtomicUsize::new(0));
        let handle = launch_cleanup(PendingConnector(calls.clone()), fixture_identity(), attempt).unwrap();
        until(|| calls.load(Ordering::SeqCst) == 1).await;
        assert!(matches!(claim(receipt, &fixture_identity()), Err(BUSY)));
        ncm_backend_close(handle);
        until(|| !retained.active.load(Ordering::SeqCst)).await;
        assert!(matches!(retained.ownership.state.lock().unwrap().state, State::Owned(_)));
        let retry = claim(receipt, &fixture_identity()).unwrap();
        let handle = launch_cleanup(PendingConnector(calls.clone()), fixture_identity(), retry).unwrap();
        until(|| calls.load(Ordering::SeqCst) == 2).await;
        ncm_backend_dispose_media_cleanup(receipt);
        until(|| !retained.active.load(Ordering::SeqCst)).await;
        assert!(matches!(claim(receipt, &fixture_identity()), Err(CLOSED)));
        ncm_backend_close(handle);
        assert_eq!(WORKERS.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn capacity_is_reserved_before_control_admission_and_never_lost_at_detach() {
        let _test = super::super::tests::TEST_LOCK.lock().await;
        until(|| OWNERSHIPS.load(Ordering::SeqCst) == 0).await;
        let (first, first_entry, _) = original();
        let (second, second_entry, _) = original();
        let mut receipts = [0; 2];
        assert_eq!(unsafe { ncm_backend_detach_media_cleanup(first, &mut receipts[0]) }, 0);
        assert_eq!(unsafe { ncm_backend_detach_media_cleanup(second, &mut receipts[1]) }, 0);
        assert!(matches!(super::super::launch(NoNetwork, fixture_identity(), VERIFY), Err(BUSY)),
            "A third source must be refused before network or media dispatch");
        first_entry.done.store(true, Ordering::SeqCst);
        second_entry.done.store(true, Ordering::SeqCst);
        ncm_backend_dispose_media_cleanup(receipts[0]);
        assert_eq!(OWNERSHIPS.load(Ordering::SeqCst), 2,
            "An old live worker/reference still owns its reservation");
        drop(first_entry);
        assert_eq!(OWNERSHIPS.load(Ordering::SeqCst), 1);
        let third = Ownership::new(&fixture_identity()).unwrap();
        assert_eq!(OWNERSHIPS.load(Ordering::SeqCst), 2);
        ncm_backend_dispose_media_cleanup(receipts[1]);
        drop(second_entry);
        drop(third);
        assert_eq!(OWNERSHIPS.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn local_confirmation_requires_settled_state_and_every_worker_drained() {
        let _test = super::super::tests::TEST_LOCK.lock().await;
        let (old, entry, _) = original();
        let mut receipt = 0;
        assert_eq!(unsafe { ncm_backend_detach_media_cleanup(old, &mut receipt) }, 0);
        let state = &entry.cleanup.as_ref().unwrap().state;
        crate::media_cleanup::set(state, State::Idle).unwrap();
        assert_eq!(ncm_backend_confirm_media_cleanup(receipt), BUSY,
            "Idle alone cannot bypass the original runtime drain");
        entry.done.store(true, Ordering::SeqCst);
        assert_eq!(ncm_backend_confirm_media_cleanup(receipt), 0);
        let attempt = claim(receipt, &fixture_identity()).unwrap();
        assert_eq!(ncm_backend_confirm_media_cleanup(receipt), BUSY);
        drop(attempt);
        assert_eq!(ncm_backend_confirm_media_cleanup(receipt), 0);
        for value in [State::Unknown, State::Owned(crate::media_cleanup::tests::owned())] {
            crate::media_cleanup::set(state, value).unwrap();
            assert_eq!(ncm_backend_confirm_media_cleanup(receipt), NOT_READY);
            assert!(state.lock().unwrap().state == value, "Read-only check must preserve authority");
        }
        let attempt = claim(receipt, &fixture_identity()).unwrap();
        let retained = attempt.0.clone();
        let calls = Arc::new(AtomicUsize::new(0));
        let handle = launch_cleanup(PendingConnector(calls.clone()), fixture_identity(), attempt).unwrap();
        until(|| calls.load(Ordering::SeqCst) == 1).await;
        assert_eq!(ncm_backend_confirm_media_cleanup(receipt), BUSY);
        ncm_backend_close(handle);
        // A cancellation request does not itself settle or confirm the receipt.
        let code = ncm_backend_confirm_media_cleanup(receipt);
        assert!(code == BUSY || code == NOT_READY);
        until(|| !retained.active.load(Ordering::SeqCst)).await;
        assert_eq!(ncm_backend_confirm_media_cleanup(receipt), NOT_READY);
        crate::media_cleanup::set(state, State::Idle).unwrap();
        assert_eq!(ncm_backend_confirm_media_cleanup(receipt), 0);
        assert!(crate::media_cleanup::begin(state).is_err(),
            "Confirmation cannot rearm the detached source");
        ncm_backend_dispose_media_cleanup(receipt);
        assert_eq!(ncm_backend_confirm_media_cleanup(receipt), CLOSED);
    }
}
