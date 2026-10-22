// SPDX-License-Identifier: GPL-3.0-only
//! Eiscue C ABI runtime. One bounded worker owns each explicitly opened connection.
//! ABI layouts, Eiscue extensions and upstream regression fixtures are preserved.
use crate::{
    Cause, Error, ExistingIdentity, NcmConnector, RelayConnector, RpPairingFile, Session, Stage,
    VerifiedPeerIdentity,
};
use std::{
    collections::HashMap,
    slice,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, mpsc, watch};
use zeroize::{Zeroize, Zeroizing};
#[path = "media_cleanup_ffi.rs"]
mod media_cleanup;
#[path = "pairing.rs"]
mod pairing;
const INVALID: i32 = 1;
const BUSY: i32 = 2;
const CLOSED: i32 = 3;
const EMPTY: i32 = 4;
const SMALL: i32 = 5;
const NOT_READY: i32 = 6;
const SCREEN: u32 = 1;
const MEDIA: u32 = 2;
const INPUT: u32 = 4;
const VERIFY: u32 = 8;
#[repr(C)]
pub struct Bytes {
    data: *const u8,
    size: usize,
}
#[repr(C)]
pub struct Identity {
    seed: Bytes,
    controller_id: Bytes,
    peer_id: Bytes,
    peer_public_key: Bytes,
    alt_irk: Bytes,
    peer_udid: Bytes,
    peer_model: Bytes,
}
#[repr(C)]
pub struct Config {
    abi: u32,
    interface_index: u32,
    generation: u32,
    endpoint_index: u32,
    permissions: u32,
}
#[repr(C)]
#[derive(Default, Clone, Copy)]
pub struct EventHeader {
    request_id: u64,
    kind: u32,
    stage: u32,
    cause: u32,
    reserved: u32,
    size: usize,
}
struct Event {
    header: EventHeader,
    data: Vec<u8>,
    credit: Option<OwnedSemaphorePermit>,
}
impl Drop for Event {
    fn drop(&mut self) {
        self.data.zeroize();
    }
}
impl Event {
    fn ok(id: u64, kind: u32, data: Vec<u8>) -> Self {
        Self {
            header: EventHeader {
                request_id: id,
                kind,
                size: data.len(),
                ..Default::default()
            },
            data,
            credit: None,
        }
    }
    fn failed(id: u64, e: Error) -> Self {
        Self {
            header: EventHeader {
                request_id: id,
                kind: 3,
                stage: e.stage as u32 + 1,
                cause: e.cause as u32 + 1,
                ..Default::default()
            },
            data: Vec::new(),
            credit: None,
        }
    }
}
#[derive(Clone)]
struct Request {
    id: u64,
    action: u32,
    x: u16,
    y: u16,
    end_x: u16,
    end_y: u16,
    duration: u16,
    payload: Zeroizing<Vec<u8>>,
}
impl Request {
    fn empty(id: u64, action: u32) -> Self {
        Self {
            id,
            action,
            x: 0,
            y: 0,
            end_x: 0,
            end_y: 0,
            duration: 0,
            payload: Zeroizing::new(Vec::new()),
        }
    }
}
struct Receiver {
    pending: Option<Event>,
    queue: mpsc::Receiver<Event>,
}
struct Entry {
    pairing: bool,
    pairing_state: AtomicUsize,
    submit: Mutex<(u64, mpsc::Sender<Request>)>,
    receive: Mutex<Receiver>,
    cancel: watch::Sender<bool>,
    ready: AtomicBool,
    done: Arc<AtomicBool>,
    video: Arc<crate::video::VideoMailbox>,
    screen_allowed: bool,
    cleanup: Option<Arc<media_cleanup::Ownership>>,
}
static ENTRIES: OnceLock<Mutex<HashMap<u64, Arc<Entry>>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);
static WORKERS: AtomicUsize = AtomicUsize::new(0);
fn registry() -> &'static Mutex<HashMap<u64, Arc<Entry>>> {
    ENTRIES.get_or_init(Mutex::default)
}
fn get(handle: u64) -> Option<Arc<Entry>> {
    registry()
        .lock()
        .ok()
        .and_then(|entries| entries.get(&handle).cloned())
}
fn protect(operation: impl FnOnce() -> i32) -> i32 {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(operation)) {
        Ok(code) => code,
        Err(_) => INVALID,
    }
}
unsafe fn bytes<'a>(input: &Bytes, maximum: usize) -> Result<&'a [u8], i32> {
    match (input.data.is_null(), input.size) {
        (false, size) if size > 0 && size <= maximum => {
            Ok(unsafe { slice::from_raw_parts(input.data, size) })
        }
        _ => Err(INVALID),
    }
}
unsafe fn text(input: &Bytes) -> Result<String, i32> {
    let value = std::str::from_utf8(unsafe { bytes(input, 256) }?).map_err(|_| INVALID)?;
    if value.as_bytes().contains(&0) {
        return Err(INVALID);
    }
    Ok(value.into())
}
unsafe fn fixed<const N: usize>(input: &Bytes) -> Result<[u8; N], i32> {
    unsafe { bytes(input, N) }?.try_into().map_err(|_| INVALID)
}
unsafe fn identity(input: &Identity) -> Result<ExistingIdentity, i32> {
    let secret = Zeroizing::new(unsafe { fixed::<32>(&input.seed) }?);
    let signing = ed25519_dalek::SigningKey::from_bytes(&secret);
    let alternate = unsafe { fixed::<16>(&input.alt_irk) }?.to_vec();
    let identifier = unsafe { text(&input.peer_id) }?;
    let remote = idevice::remote_pairing::PeerDevice {
        account_id: identifier.clone(),
        alt_irk: alternate.clone(),
        name: String::new(),
        remotepairing_udid: unsafe { text(&input.peer_udid) }?,
        model: unsafe { text(&input.peer_model) }?,
    };
    let parsed = ExistingIdentity {
        controller: RpPairingFile {
            identifier: unsafe { text(&input.controller_id) }?,
            e_public_key: signing.verifying_key(),
            e_private_key: signing,
            alt_irk: Some(alternate),
        },
        peer: VerifiedPeerIdentity {
            pairing_identifier: identifier,
            long_term_public_key: unsafe { fixed::<32>(&input.peer_public_key) }?,
            peer: remote,
        },
    };
    parsed.validate().map_err(|_| INVALID)?;
    Ok(parsed)
}

struct WorkerSlot;
impl WorkerSlot {
    fn reserve() -> Result<Self, i32> {
        WORKERS
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |used| {
                if used >= 2 { None } else { Some(used + 1) }
            })
            .map(|_| WorkerSlot)
            .map_err(|_| BUSY)
    }
}
impl Drop for WorkerSlot {
    fn drop(&mut self) {
        WORKERS.fetch_sub(1, Ordering::SeqCst);
    }
}
struct WorkerEnd {
    entry: Arc<Entry>,
    _slot: WorkerSlot,
}
impl Drop for WorkerEnd {
    fn drop(&mut self) {
        self.entry.ready.store(false, Ordering::SeqCst);
        self.entry.done.store(true, Ordering::SeqCst);
    }
}
#[derive(Clone)]
struct Replies {
    sender: mpsc::Sender<Event>,
    credits: Arc<Semaphore>,
}
impl Replies {
    async fn reserve(&self) -> Option<OwnedSemaphorePermit> {
        self.credits.clone().acquire_owned().await.ok()
    }
    async fn send_reserved(&self, mut event: Event, credit: OwnedSemaphorePermit) -> bool {
        event.credit = Some(credit);
        self.sender.send(event).await.is_ok()
    }
    async fn send(&self, event: Event) -> bool {
        match self.reserve().await {
            Some(credit) => self.send_reserved(event, credit).await,
            None => false,
        }
    }
}
/// One worker owns one Tokio runtime. Its guard is constructed before the runtime,
/// so unwinding and explicit cancellation both destroy spawned tasks before done.
fn start_worker<F, Fut>(
    name: &str,
    pairing: bool,
    screen_allowed: bool,
    cleanup: Option<Arc<media_cleanup::Ownership>>,
    run: F,
) -> Result<u64, i32>
where
    F: FnOnce(Arc<Entry>, mpsc::Receiver<Request>, Replies) -> Fut + Send + 'static,
    Fut: std::future::Future<Output = ()> + 'static,
{
    let slot = WorkerSlot::reserve()?;
    let (sender, commands) = mpsc::channel(1);
    let (events, queue) = mpsc::channel(1);
    let (cancel, mut cancellation) = watch::channel(false);
    let entry = Arc::new(Entry {
        pairing,
        pairing_state: AtomicUsize::new(0),
        submit: Mutex::new((0, sender)),
        receive: Mutex::new(Receiver {
            pending: None,
            queue,
        }),
        cancel,
        ready: AtomicBool::new(false),
        done: Arc::new(AtomicBool::new(false)),
        video: Arc::default(),
        screen_allowed,
        cleanup,
    });
    let handle = NEXT.fetch_add(1, Ordering::SeqCst);
    {
        let mut entries = registry().lock().map_err(|_| INVALID)?;
        if handle == 0 || entries.len() >= 2 {
            return Err(BUSY);
        }
        entries.insert(handle, entry.clone());
    }
    let completed = WorkerEnd {
        entry: entry.clone(),
        _slot: slot,
    };
    let spawned = std::thread::Builder::new()
        .name(name.into())
        .spawn(move || {
            let end = completed;
            let replies = Replies {
                sender: events,
                credits: Arc::new(Semaphore::new(1)),
            };
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(_) => {
                    let _ = replies.sender.try_send(Event::failed(
                        0,
                        Error {
                            stage: Stage::Closed,
                            cause: Cause::Protocol,
                        },
                    ));
                    return;
                }
            };
            runtime.block_on(async {
                if *cancellation.borrow() {
                    return;
                }
                tokio::select! { biased;
                    _ = cancellation.changed() => {},
                    _ = run(entry, commands, replies) => {},
                }
            });
            drop(runtime);
            drop(end);
        });
    if spawned.is_err() {
        if let Ok(mut entries) = registry().lock() {
            entries.remove(&handle);
        }
        return Err(INVALID);
    }
    Ok(handle)
}
fn launch(
    connector: impl NcmConnector + 'static,
    mut identity: ExistingIdentity,
    permissions: u32,
) -> Result<u64, i32> {
    // The receipt slot must exist before an authenticated source session can start.
    let ownership = Arc::new(media_cleanup::Ownership::new(&identity)?);
    start_worker(
        "eiscue-control",
        false,
        permissions & SCREEN != 0,
        Some(ownership.clone()),
        move |entry, mut requests, replies| async move {
            let connected = Session::connect(&connector, &mut identity).await;
            drop(identity);
            let mut session = match connected {
                Ok(session) => session,
                Err(error) => {
                    replies.send(Event::failed(0, error)).await;
                    return;
                }
            };
            session.video = entry.video.clone();
            session.media_cleanup = ownership.state.clone();
            let services: Vec<_> = session
                .services()
                .unwrap_or_default()
                .into_iter()
                .map(|service| service.name)
                .collect();
            let ready = Event::ok(0, 1, serde_json::to_vec(&services).unwrap_or_default());
            entry.ready.store(true, Ordering::SeqCst);
            if !replies.send(ready).await {
                return;
            }
            while let Some(request) = requests.recv().await {
                let Some(credit) = replies.reserve().await else {
                    break;
                };
                let reply = execute(&mut session, request, permissions).await;
                let terminal = reply.header.cause == Cause::DeliveryUncertain as u32 + 1;
                if terminal {
                    entry.ready.store(false, Ordering::SeqCst);
                }
                if !replies.send_reserved(reply, credit).await || terminal {
                    break;
                }
            }
        },
    )
}
fn lockdown_failure(id: u64, failure: crate::lockdown::Failure) -> Event {
    let mut event = Event::ok(id, 3, Vec::new());
    event.header.stage = failure as u32 + 101;
    event.header.cause = 1;
    event
}
fn launch_lockdown(
    connector: impl NcmConnector + 'static,
    identity: crate::lockdown::ExistingIdentity,
) -> Result<u64, i32> {
    start_worker(
        "eiscue-lockdown",
        false,
        false,
        None,
        move |entry, mut commands, replies| async move {
            let connected = crate::lockdown::Session::connect(&connector, &identity).await;
            drop(identity);
            let mut session = match connected {
                Ok(session) => session,
                Err(error) => {
                    replies.send(lockdown_failure(0, error)).await;
                    return;
                }
            };
            entry.ready.store(true, Ordering::SeqCst);
            if !replies.send(Event::ok(0, 2, Vec::new())).await {
                return;
            }
            while let Some(command) = commands.recv().await {
                let Some(credit) = replies.reserve().await else {
                    break;
                };
                let stopping = command.action == 5;
                let result = if stopping {
                    session.stop().await
                } else {
                    Err(crate::lockdown::Failure::Closed)
                };
                let response = match result {
                    Ok(()) => Event::ok(command.id, 2, Vec::new()),
                    Err(error) => lockdown_failure(command.id, error),
                };
                if stopping {
                    entry.ready.store(false, Ordering::SeqCst);
                }
                if !replies.send_reserved(response, credit).await || stopping {
                    break;
                }
            }
        },
    )
}
/// # Safety
/// All byte fields are borrowed for this call; handle must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_lockdown_start(
    interface_index: u32,
    permissions: u32,
    record: Bytes,
    udid: Bytes,
    handle: *mut u64,
) -> i32 {
    protect(|| unsafe {
        publish(handle, || {
            if permissions != VERIFY {
                return Err(INVALID);
            }
            let identity = crate::lockdown::ExistingIdentity::from_plist(
                bytes(&record, 1024 * 1024)?,
                &text(&udid)?,
            )
            .map_err(|_| INVALID)?;
            let connector = RelayConnector::new_lockdown(interface_index).map_err(|_| INVALID)?;
            launch_lockdown(connector, identity)
        })
    })
}
unsafe fn publish(handle: *mut u64, operation: impl FnOnce() -> Result<u64, i32>) -> i32 {
    if handle.is_null() {
        return INVALID;
    }
    unsafe {
        handle.write(0);
    }
    match operation() {
        Ok(value) => {
            unsafe {
                handle.write(value);
            }
            0
        }
        Err(code) => code,
    }
}
async fn dispatch(session: &mut Session, request: &Request) -> Result<(u32, Vec<u8>), Error> {
    let invalid = || Error {
        stage: Stage::Input,
        cause: Cause::InvalidParameters,
    };
    match request.action {
        1 => session.check_developer_readiness().await?,
        2 => return session.screenshot().await.map(|image| (4, image.png)),
        3 => session.start_touch_media().await?,
        4 => {
            session.tap(request.x, request.y).await?;
        }
        6 => {
            session
                .drag(
                    request.x,
                    request.y,
                    request.end_x,
                    request.end_y,
                    request.duration,
                )
                .await?;
        }
        7 => {
            session.home().await?;
        }
        8 => return session.list_apps().await.map(|apps| (11, apps)),
        9 | 10 => {
            let value: serde_json::Value =
                serde_json::from_slice(&request.payload).map_err(|_| invalid())?;
            if request.action == 10 {
                session
                    .type_text(
                        value
                            .get("text")
                            .and_then(serde_json::Value::as_str)
                            .ok_or_else(invalid)?,
                    )
                    .await?;
            } else {
                let bundle = value
                    .get("bundle_id")
                    .and_then(serde_json::Value::as_str)
                    .ok_or_else(invalid)?;
                let arguments: Option<Vec<String>> = value
                    .get("arguments")
                    .and_then(serde_json::Value::as_array)
                    .map(|values| {
                        values
                            .iter()
                            .map(|value| value.as_str().map(String::from))
                            .collect()
                    })
                    .flatten();
                session
                    .launch_app(bundle, &arguments.ok_or_else(invalid)?)
                    .await?;
            }
        }
        11 => session.stop_touch_media().await?,
        13 => {
            return session
                .probe_legacy_developer_services()
                .await
                .map(|data| (2, data));
        }
        14 => {
            return session
                .start_xctest_session(&request.payload)
                .await
                .map(|data| (2, data));
        }
        15 => session.stop_xctest_session().await?,
        16 => {
            return session
                .screenshot_legacy()
                .await
                .map(|image| (4, image.png));
        }
        17 => {
            return session
                .verify_video_geometry()
                .await
                .map(|confirmed| (2, vec![u8::from(confirmed)]));
        }
        18 => {
            return session
                .media_status_diagnostic()
                .await
                .map(|report| (2, report));
        }
        _ => {
            return Err(Error {
                stage: Stage::Closed,
                cause: Cause::InvalidParameters,
            });
        }
    }
    Ok((2, Vec::new()))
}
async fn execute(session: &mut Session, request: Request, permissions: u32) -> Event {
    let required = required_permissions(request.action);
    if required & permissions != required {
        let stage = match request.action {
            2 => Stage::Screenshot,
            3 | 18 => Stage::Media,
            13 | 16 => Stage::LegacyInstrumentsConnection,
            14 => Stage::XCTestControlInit,
            _ => Stage::Input,
        };
        return Event::failed(
            request.id,
            Error {
                stage,
                cause: Cause::Unprepared,
            },
        );
    }
    match Box::pin(dispatch(session, &request)).await {
        Ok((kind, data)) => Event::ok(request.id, kind, data),
        Err(error) => {
            let mut failure = Event::failed(request.id, error);
            match request.action {
                3 => failure.header.kind = 10,
                8 => failure.header.kind = 12,
                _ => {}
            }
            failure
        }
    }
}
fn required_permissions(action: u32) -> u32 {
    match action {
        1 | 11 | 15 => 0,
        2 => SCREEN,
        3 => MEDIA,
        4 | 6 | 7 | 9 | 10 => INPUT,
        8 => VERIFY,
        13 => SCREEN | VERIFY,
        14 => INPUT | VERIFY,
        16 => SCREEN | VERIFY,
        17 => SCREEN | VERIFY,
        18 => SCREEN | MEDIA | VERIFY,
        _ => u32::MAX,
    }
}
fn video_entry(handle: u64) -> Result<Arc<Entry>, i32> {
    let entry = get(handle).ok_or(CLOSED)?;
    if !entry.screen_allowed {
        return Err(NOT_READY);
    }
    if entry.done.load(Ordering::SeqCst) {
        return Err(CLOSED);
    }
    Ok(entry)
}
unsafe fn video_value<T>(
    handle: u64,
    output: *mut T,
    read: impl FnOnce(&crate::video::VideoMailbox) -> T,
) -> i32 {
    if output.is_null() {
        return INVALID;
    }
    match video_entry(handle) {
        Ok(entry) => {
            unsafe {
                output.write(read(&entry.video));
            }
            0
        }
        Err(code) => code,
    }
}
/// # Safety
/// status points to writable C storage; only bounded metadata is returned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_video_get_status(
    handle: u64,
    status: *mut crate::video::VideoStatus,
) -> i32 {
    protect(|| unsafe { video_value(handle, status, |video| video.status()) })
}
/// # Safety
/// status points to writable C storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_video_get_snapshot(
    handle: u64,
    status: *mut crate::video::VideoSnapshot,
) -> i32 {
    protect(|| unsafe { video_value(handle, status, |video| video.snapshot()) })
}
/// # Safety
/// cursor points to writable C storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_video_get_decode_cursor(
    handle: u64,
    cursor: *mut crate::video::VideoDecodeCursor,
) -> i32 {
    protect(|| unsafe { video_value(handle, cursor, |video| video.decode_cursor()) })
}
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_video_refresh(handle: u64) -> i32 {
    protect(|| match video_entry(handle) {
        Ok(entry) => {
            entry.video.request_refresh();
            0
        }
        Err(code) => code,
    })
}
/// # Safety
/// event is writable; a non-null buffer is writable for capacity bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_video_poll(
    handle: u64,
    event: *mut EventHeader,
    buffer: *mut u8,
    capacity: usize,
) -> i32 {
    protect(|| {
        if event.is_null() {
            return INVALID;
        }
        let entry = match video_entry(handle) {
            Ok(entry) => entry,
            Err(code) => return code,
        };
        let available = if buffer.is_null() { 0 } else { capacity };
        let (kind, size, payload) = entry.video.poll(available);
        unsafe {
            event.write(EventHeader {
                kind,
                size,
                ..EventHeader::default()
            });
        }
        if kind == 0 {
            return EMPTY;
        }
        match payload {
            None => SMALL,
            Some(payload) => {
                if !payload.is_empty() {
                    unsafe {
                        std::ptr::copy_nonoverlapping(payload.as_ptr(), buffer, payload.len());
                    }
                }
                0
            }
        }
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_abi() -> u32 {
    1
}
fn valid_permissions(permissions: u32) -> bool {
    permissions & VERIFY != 0 && permissions & !15 == 0
}
/// # Safety
/// config and raw are readable; handle is writable. Borrowed inputs are copied.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_start(
    config: *const Config,
    raw: *const Identity,
    handle: *mut u64,
) -> i32 {
    protect(|| unsafe {
        publish(handle, || {
            let configuration = config.as_ref().ok_or(INVALID)?;
            let raw = raw.as_ref().ok_or(INVALID)?;
            if configuration.abi != 1
                || configuration.endpoint_index > 15
                || !valid_permissions(configuration.permissions)
            {
                return Err(INVALID);
            }
            let selected = RelayConnector::new(
                configuration.interface_index,
                configuration.generation,
                configuration.endpoint_index as u8,
            )
            .map_err(|_| INVALID)?;
            launch(selected, identity(raw)?, configuration.permissions)
        })
    })
}
/// # Safety
/// raw is readable and handle is writable for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_local_vpn_start(
    interface_index: u32,
    pairing_port: u16,
    permissions: u32,
    raw: *const Identity,
    handle: *mut u64,
) -> i32 {
    unsafe {
        ncm_local_vpn_start_configured(
            interface_index,
            pairing_port,
            permissions,
            0x0a070101,
            0x0a070001,
            raw,
            handle,
        )
    }
}
/// # Safety
/// Same ownership as ncm_local_vpn_start; IPv4 integers use address byte order.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_local_vpn_start_configured(
    interface_index: u32,
    pairing_port: u16,
    permissions: u32,
    local_ipv4: u32,
    peer_ipv4: u32,
    raw: *const Identity,
    handle: *mut u64,
) -> i32 {
    protect(|| unsafe {
        publish(handle, || {
            if !valid_permissions(permissions) {
                return Err(INVALID);
            }
            let parsed = identity(raw.as_ref().ok_or(INVALID)?)?;
            let connector = crate::local_vpn::LocalVPNConnector::configured(
                interface_index,
                pairing_port,
                std::net::Ipv4Addr::from(local_ipv4),
                std::net::Ipv4Addr::from(peer_ipv4),
            )
            .map_err(|_| INVALID)?;
            launch(connector, parsed, permissions)
        })
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_submit(handle: u64, id: u64, action: u32, x: u16, y: u16) -> i32 {
    match action {
        1..=5 | 7 | 8 | 11 | 13 | 15..=18 => {
            let mut request = Request::empty(id, action);
            request.x = x;
            request.y = y;
            submit_request(handle, request)
        }
        _ => INVALID,
    }
}
/// # Safety
/// session_uuid borrows the exact 16 NSUUID bytes for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_xctest_start(
    handle: u64,
    id: u64,
    session_uuid: Bytes,
) -> i32 {
    protect(|| {
        let value = match unsafe { bytes(&session_uuid, 16) } {
            Ok(value) if crate::xctest_session::valid_uuid_bytes(value) => value,
            _ => return INVALID,
        };
        let mut request = Request::empty(id, 14);
        request.payload.extend_from_slice(value);
        submit_request(handle, request)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_xctest_stop(handle: u64, id: u64) -> i32 {
    submit_request(handle, Request::empty(id, 15))
}
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_drag(
    handle: u64,
    id: u64,
    x: u16,
    y: u16,
    end_x: u16,
    end_y: u16,
    duration: u16,
) -> i32 {
    if duration < 100 || duration > 2000 {
        return INVALID;
    }
    let mut request = Request::empty(id, 6);
    request.x = x;
    request.y = y;
    request.end_x = end_x;
    request.end_y = end_y;
    request.duration = duration;
    submit_request(handle, request)
}
fn valid_command(action: u32, encoded: &[u8]) -> bool {
    if encoded.is_empty() || encoded.len() > 16 * 1024 {
        return false;
    }
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(encoded) else {
        return false;
    };
    match action {
        10 => value
            .get("text")
            .and_then(serde_json::Value::as_str)
            .is_some_and(crate::valid_input_text),
        9 => {
            let Some(bundle) = value.get("bundle_id").and_then(serde_json::Value::as_str) else {
                return false;
            };
            let Some(arguments) = value.get("arguments").and_then(serde_json::Value::as_array)
            else {
                return false;
            };
            (1..=256).contains(&bundle.len())
                && bundle
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
                && arguments.len() <= 32
                && arguments.iter().all(|arg| {
                    arg.as_str()
                        .is_some_and(|arg| arg.len() <= 1024 && !arg.contains('\0'))
                })
        }
        _ => false,
    }
}
/// # Safety
/// payload is borrowed only while this call copies and validates its bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_command(
    handle: u64,
    id: u64,
    action: u32,
    payload: Bytes,
) -> i32 {
    protect(|| {
        let encoded = match unsafe { bytes(&payload, 16 * 1024) } {
            Ok(encoded) => encoded,
            Err(code) => return code,
        };
        if !valid_command(action, encoded) {
            return INVALID;
        }
        let mut request = Request::empty(id, action);
        request.payload.extend_from_slice(encoded);
        submit_request(handle, request)
    })
}
fn submit_request(handle: u64, request: Request) -> i32 {
    protect(|| {
        if request.id == 0 {
            return INVALID;
        }
        let Some(entry) = get(handle) else {
            return CLOSED;
        };
        if entry.pairing {
            return INVALID;
        }
        let Ok(mut submission) = entry.submit.lock() else {
            return INVALID;
        };
        if entry.done.load(Ordering::SeqCst) {
            return CLOSED;
        }
        if !entry.ready.load(Ordering::SeqCst) {
            return NOT_READY;
        }
        let sequence = request.id;
        if sequence <= submission.0 {
            return INVALID;
        }
        match submission.1.try_send(request) {
            Ok(()) => {
                submission.0 = sequence;
                0
            }
            Err(mpsc::error::TrySendError::Closed(_)) => CLOSED,
            Err(mpsc::error::TrySendError::Full(_)) => BUSY,
        }
    })
}
/// # Safety
/// header is writable; a non-null buffer is writable for capacity bytes.
/// A short buffer retains the same event and therefore its execution credit.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_poll(
    handle: u64,
    header: *mut EventHeader,
    buffer: *mut u8,
    capacity: usize,
) -> i32 {
    protect(|| {
        if header.is_null() || capacity > 64 * 1024 * 1024 {
            return INVALID;
        }
        unsafe {
            header.write(EventHeader::default());
        }
        let Some(entry) = get(handle) else {
            return CLOSED;
        };
        let Ok(mut inbox) = entry.receive.lock() else {
            return INVALID;
        };
        if inbox.pending.is_none() {
            inbox.pending = match inbox.queue.try_recv() {
                Ok(event) => Some(event),
                Err(mpsc::error::TryRecvError::Empty) if !entry.done.load(Ordering::SeqCst) => {
                    return EMPTY;
                }
                Err(_) => return CLOSED,
            };
        }
        let pending = inbox.pending.as_ref().unwrap();
        unsafe {
            header.write(pending.header);
        }
        let writable = if buffer.is_null() { 0 } else { capacity };
        if pending.data.len() > writable {
            return SMALL;
        }
        if !pending.data.is_empty() {
            unsafe {
                std::ptr::copy_nonoverlapping(pending.data.as_ptr(), buffer, pending.data.len());
            }
        }
        drop(inbox.pending.take());
        0
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_close(handle: u64) {
    protect(|| {
        let removed = registry()
            .lock()
            .ok()
            .and_then(|mut entries| entries.remove(&handle));
        if let Some(entry) = removed {
            entry.ready.store(false, Ordering::SeqCst);
            let _ = entry.cancel.send(true);
        }
        0
    });
}
// Retained upstream offline fixtures and regression tests (GPL-3.0-only).
// These are not part of the production runtime implementation above.
#[cfg(any(test, feature = "offline-fixtures"))]
pub(crate) fn fixture_identity() -> ExistingIdentity {
    let key = ed25519_dalek::SigningKey::from_bytes(&[0x42; 32]);
    ExistingIdentity {
        controller: RpPairingFile {
            identifier: "SYNTHETIC-CONTROLLER".into(),
            e_public_key: key.verifying_key(),
            e_private_key: key,
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
                name: String::new(),
                remotepairing_udid: "SYNTHETIC-UDID".into(),
            },
        },
    }
}
// Public synthetic sample only; this export never exists in device archives.
#[cfg(feature = "offline-fixtures")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_test_start_video_burst(
    sample: Bytes,
    continuous: u32,
    handle: *mut u64,
) -> i32 {
    protect(|| {
        let Ok(data) = (unsafe { bytes(&sample, 4096) }) else {
            return INVALID;
        };
        if data.len() < 64 {
            return INVALID;
        }
        let n = |offset: usize| u32::from_le_bytes(data[offset..offset + 4].try_into().unwrap());
        let (width, height) = (n(40), n(44));
        let lengths = [
            n(48) as usize,
            n(52) as usize,
            n(56) as usize,
            n(60) as usize,
        ];
        if n(36) != 1
            || width == 0
            || height == 0
            || width > 256
            || height > 256
            || lengths.iter().any(|n| *n == 0)
            || lengths.iter().sum::<usize>() + 64 != data.len()
        {
            return INVALID;
        }
        let mut offset = 64;
        let mut fields = Vec::new();
        for len in lengths {
            fields.push(data[offset..offset + len].to_vec());
            offset += len;
        }
        let params = idevice::core_device::display_stream::HevcParameterSets {
            revision: 1,
            pixel_width: width,
            pixel_height: height,
            video_parameter_set: fields[0].clone(),
            sequence_parameter_set: fields[1].clone(),
            picture_parameter_set: fields[2].clone(),
        };
        let unit = idevice::core_device::display_stream::HevcAccessUnit {
            ssrc: 7,
            rtp_timestamp: n(32),
            first_sequence_number: 1,
            last_sequence_number: 1,
            parameter_set_revision: 1,
            is_sync: true,
            bytes: fields[3].clone(),
        };
        unsafe { start_media_fixture(handle, Some((unit, params)), continuous != 0) }
    })
}

// Synthetic ABI ownership fixture, compiled out of every device archive.
#[cfg(feature = "offline-fixtures")]
/// # Safety
/// handle must be writable; no network or credentials are accessed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_test_start_media_failure(handle: *mut u64) -> i32 {
    unsafe { start_media_fixture(handle, None, false) }
}
#[cfg(feature = "offline-fixtures")]
unsafe fn start_media_fixture(
    handle: *mut u64,
    burst: Option<(
        idevice::core_device::display_stream::HevcAccessUnit,
        idevice::core_device::display_stream::HevcParameterSets,
    )>,
    continuous: bool,
) -> i32 {
    protect(|| {
        if handle.is_null() {
            return INVALID;
        }
        unsafe {
            *handle = 0;
        }
        let (tx, mut rx) = mpsc::channel::<Request>(1);
        let (events, queue) = mpsc::channel(1);
        let (cancel, mut cancelled) = watch::channel(false);
        let entry = Arc::new(Entry {
            pairing: false,
            pairing_state: AtomicUsize::new(0),
            submit: Mutex::new((0, tx)),
            receive: Mutex::new(Receiver {
                pending: None,
                queue,
            }),
            cancel,
            ready: AtomicBool::new(true),
            done: Arc::new(AtomicBool::new(false)),
            video: Arc::new(crate::video::VideoMailbox::default()),
            screen_allowed: burst.is_some(),
            cleanup: None,
        });
        let id = NEXT.fetch_add(1, Ordering::SeqCst);
        registry().lock().unwrap().insert(id, entry.clone());
        let spawn = std::thread::Builder::new().spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            runtime.block_on(async {
                let work = async {
                    if events.send(Event::ok(0, 1, b"[]".to_vec())).await.is_err() {
                        return;
                    }
                    let mut fixture_media: Option<tokio::task::JoinHandle<()>> = None;
                    while let Some(request) = rx.recv().await {
                        let event = match request.action {
                            2 => Event::failed(
                                request.id,
                                Error {
                                    stage: Stage::ScreenshotConnection,
                                    cause: Cause::Protocol,
                                },
                            ),
                            3 if burst.is_some() => {
                                if let Some(task) = fixture_media.take() {
                                    task.abort();
                                }
                                let (unit, params) = burst.as_ref().unwrap();
                                entry.video.begin_stream();
                                for _ in 0..1000 {
                                    entry.video.push(unit.clone(), params.clone());
                                    let mut inter = unit.clone();
                                    inter.is_sync = false;
                                    entry.video.push(inter, params.clone());
                                }
                                let (mut inter, params) = (unit.clone(), params.clone());
                                inter.is_sync = false;
                                let media_entry = entry.clone();
                                fixture_media = Some(tokio::spawn(async move {
                                    let began = tokio::time::Instant::now();
                                    loop {
                                        tokio::time::sleep(std::time::Duration::from_millis(40))
                                            .await;
                                        if continuous {
                                            media_entry.video.push(inter.clone(), params.clone());
                                        } else if began.elapsed()
                                            < std::time::Duration::from_secs(3)
                                        {
                                            // Healthy idle peer: progress reports, no new pictures.
                                            media_entry.video.sender_report(true);
                                        }
                                    }
                                }));
                                Event::ok(request.id, 2, Vec::new())
                            }
                            11 => {
                                if let Some(task) = fixture_media.take() {
                                    task.abort();
                                }
                                entry.video.reset();
                                Event::ok(request.id, 2, Vec::new())
                            }
                            3 => {
                                let mut e = Event::failed(
                                    request.id,
                                    Error {
                                        stage: Stage::VideoNegotiation,
                                        cause: Cause::Timeout,
                                    },
                                );
                                e.header.kind = 10;
                                e
                            }
                            4 | 6 => Event::failed(
                                request.id,
                                Error {
                                    stage: Stage::Input,
                                    cause: Cause::DeliveryUncertain,
                                },
                            ),
                            _ => Event::ok(request.id, 2, Vec::new()),
                        };
                        if events.send(event).await.is_err() {
                            return;
                        }
                    }
                };
                tokio::select! { biased; _=cancelled.changed()=>{}, _=work=>{} }
            });
            drop(runtime);
            entry.done.store(true, Ordering::SeqCst);
        });
        if spawn.is_err() {
            registry().lock().unwrap().remove(&id);
            return INVALID;
        }
        unsafe {
            *handle = id;
        }
        0
    })
}

#[cfg(feature = "offline-fixtures")]
/// # Safety
/// handle must be writable. Target is restricted to IPv4 loopback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_test_start_loopback(port: u16, handle: *mut u64) -> i32 {
    protect(|| {
        if handle.is_null() || port == 0 {
            return INVALID;
        }
        unsafe { *handle = 0 };
        match launch(RelayConnector::loopback(port), fixture_identity(), VERIFY) {
            Ok(id) => {
                unsafe { *handle = id };
                0
            }
            Err(e) => e,
        }
    })
}
#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn eiscue_done_requires_runtime_children_to_be_dropped() {
        let _test = TEST_LOCK.lock().await;
        let child_started = Arc::new(AtomicBool::new(false));
        let child_dropped = Arc::new(AtomicBool::new(false));
        struct Child(Arc<AtomicBool>);
        impl Drop for Child {
            fn drop(&mut self) {
                self.0.store(true, Ordering::SeqCst);
            }
        }
        let started = child_started.clone();
        let dropped = child_dropped.clone();
        let handle = start_worker(
            "eiscue-drain-test",
            false,
            false,
            None,
            move |_, _, _| async move {
                tokio::spawn(async move {
                    let _child = Child(dropped);
                    started.store(true, Ordering::SeqCst);
                    std::future::pending::<()>().await;
                });
                std::future::pending::<()>().await;
            },
        )
        .unwrap();
        let entry = get(handle).unwrap();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(2);
        while !child_started.load(Ordering::SeqCst) {
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
        }
        assert!(!entry.done.load(Ordering::SeqCst));
        ncm_backend_close(handle);
        while !entry.done.load(Ordering::SeqCst) {
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
        }
        assert!(
            child_dropped.load(Ordering::SeqCst),
            "drain evidence must follow runtime destruction"
        );
        while WORKERS.load(Ordering::SeqCst) != 0 {
            tokio::task::yield_now().await;
        }
    }

    #[tokio::test]
    async fn eiscue_short_poll_holds_execution_credit_until_receipt_consumed() {
        let _test = TEST_LOCK.lock().await;
        let executions = Arc::new(AtomicUsize::new(0));
        let counter = executions.clone();
        let handle = start_worker(
            "eiscue-credit-test",
            false,
            false,
            None,
            move |entry, mut requests, replies| async move {
                entry.ready.store(true, Ordering::SeqCst);
                replies.send(Event::ok(0, 1, vec![1, 2, 3])).await;
                while let Some(request) = requests.recv().await {
                    let credit = replies.reserve().await.unwrap();
                    counter.fetch_add(1, Ordering::SeqCst);
                    replies
                        .send_reserved(Event::ok(request.id, 2, vec![4, 5]), credit)
                        .await;
                }
            },
        )
        .unwrap();
        let entry = get(handle).unwrap();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(2);
        let mut header = EventHeader::default();
        while unsafe { ncm_backend_poll(handle, &mut header, std::ptr::null_mut(), 0) } == EMPTY {
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
        }
        assert_eq!(header.kind, 1);
        assert_eq!(ncm_backend_submit(handle, 1, 1, 0, 0), 0);
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        assert_eq!(executions.load(Ordering::SeqCst), 0);
        let mut output = [0; 3];
        assert_eq!(
            unsafe { ncm_backend_poll(handle, &mut header, output.as_mut_ptr(), 2) },
            SMALL
        );
        assert_eq!(executions.load(Ordering::SeqCst), 0);
        assert_eq!(
            unsafe { ncm_backend_poll(handle, &mut header, output.as_mut_ptr(), 3) },
            0
        );
        while executions.load(Ordering::SeqCst) != 1 {
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
        }
        assert_eq!(ncm_backend_submit(handle, 2, 1, 0, 0), 0);
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        assert_eq!(executions.load(Ordering::SeqCst), 1);
        ncm_backend_close(handle);
        while !entry.done.load(Ordering::SeqCst) {
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
        }
        while WORKERS.load(Ordering::SeqCst) != 0 {
            tokio::task::yield_now().await;
        }
    }

    #[test]
    fn xctest_and_legacy_capture_permissions_and_uuid_abi_are_explicit() {
        use super::*;
        assert_eq!(required_permissions(14), INPUT | VERIFY);
        assert_eq!(required_permissions(15), 0);
        assert_eq!(required_permissions(16), SCREEN | VERIFY);
        assert_eq!(required_permissions(17), SCREEN | VERIFY);
        assert_eq!(Stage::LegacyTestmanagerHandshake as u32 + 1, 27);
        assert_eq!(Stage::XCTestControlConnection as u32 + 1, 28);
        assert_eq!(Stage::XCTestAuthorize as u32 + 1, 36);
        // Generic submit cannot accept a start with missing UUID or an arbitrary PID.
        assert_eq!(ncm_backend_submit(u64::MAX, 1, 14, 1, 0), INVALID);
        for input in [
            vec![0; 16],
            vec![1; 15],
            vec![1; 17],
            b"{\"pid\":1}".to_vec(),
        ] {
            assert_eq!(
                unsafe {
                    ncm_backend_xctest_start(
                        u64::MAX,
                        1,
                        Bytes {
                            data: input.as_ptr(),
                            size: input.len(),
                        },
                    )
                },
                INVALID
            );
        }
        let uuid = [0x33; 16];
        assert_eq!(
            unsafe {
                ncm_backend_xctest_start(
                    u64::MAX,
                    1,
                    Bytes {
                        data: uuid.as_ptr(),
                        size: uuid.len(),
                    },
                )
            },
            CLOSED
        );
        assert_eq!(ncm_backend_xctest_stop(u64::MAX, 1), CLOSED);
    }

    #[tokio::test]
    async fn media_status_diagnostic_requires_screen_media_and_verification_only() {
        let required = super::required_permissions(18);
        assert_eq!(required, super::SCREEN | super::MEDIA | super::VERIFY);
        let mut session = crate::tests::broken_media_session();
        for permissions in 0..16 {
            let allowed = permissions & required == required;
            assert_eq!(
                allowed,
                permissions & super::SCREEN != 0
                    && permissions & super::MEDIA != 0
                    && permissions & super::VERIFY != 0
            );
            let request = super::Request {
                id: 1,
                action: 18,
                x: 0,
                y: 0,
                end_x: 0,
                end_y: 0,
                duration: 0,
                payload: zeroize::Zeroizing::new(Vec::new()),
            };
            let event = super::execute(&mut session, request, permissions).await;
            assert_eq!(event.header.kind, 3);
            assert_eq!(event.header.stage, super::Stage::Media as u32 + 1);
            assert_eq!(
                event.header.cause,
                if allowed {
                    super::Cause::MediaInactive
                } else {
                    super::Cause::Unprepared
                } as u32
                    + 1
            );
            assert!(
                session.services().is_ok(),
                "Read-only refusal must retain the authenticated generation"
            );
        }
        assert_eq!(
            super::ncm_backend_submit(u64::MAX, 1, 18, 0, 0),
            super::CLOSED
        );
    }
    #[test]
    fn legacy_probe_requires_screen_and_existing_verification_but_no_input() {
        let required = super::required_permissions(13);
        assert_eq!(required, super::SCREEN | super::VERIFY);
        for permissions in 0..16 {
            assert_eq!(
                permissions & required == required,
                permissions & super::SCREEN != 0 && permissions & super::VERIFY != 0
            );
        }
    }

    #[test]
    fn command_payload_is_bounded_typed_and_accepts_unicode() {
        // ASCII, whitespace, and mixed Unicode all use the same paste command.
        for text in ["ASCII 123!", "你好 ESP32 🌟", "\n\t ", "a"]
            .iter()
            .copied()
        {
            let payload = serde_json::to_vec(&serde_json::json!({"text": text})).unwrap();
            assert!(super::valid_command(10, &payload));
        }
        for count in [8192, 8193] {
            let payload =
                serde_json::to_vec(&serde_json::json!({"text": "x".repeat(count)})).unwrap();
            assert_eq!(super::valid_command(10, &payload), count == 8192);
        }
        assert!(super::valid_command(10, br#"{"text":"hello"}"#));
        assert!(super::valid_command(
            10,
            "{\"text\":\"你好 🌟\"}".as_bytes()
        ));
        assert!(super::valid_command(
            9,
            br#"{"bundle_id":"example.fixture","arguments":["--resume","token"]}"#
        ));
        for invalid in [
            br#"{"bundle_id":"example.fixture","arguments":"wrong"}"#.as_slice(),
            br#"{"bundle_id":"bad/path","arguments":[]}"#,
            br#"{"bundle_id":"example.fixture","arguments":[4]}"#,
        ] {
            assert!(!super::valid_command(9, invalid));
        }
        assert!(!super::valid_command(10, br#"{"text":"a\u0000b"}"#));
        assert!(!super::valid_command(10, br#"{"text":""}"#));
        assert!(!super::valid_command(10, &vec![b'x'; 16 * 1024 + 1]));
        assert!(!super::valid_command(7, br#"{"text":"hello"}"#));
    }

    pub(super) static TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    #[tokio::test]
    async fn pairing_persistence_ack_requires_exact_pending_state_and_rejects_replay() {
        let _test = TEST_LOCK.lock().await;
        let (tx, mut rx) = mpsc::channel(1);
        let (_, queue) = mpsc::channel(1);
        let (cancel, _) = watch::channel(false);
        let entry = Arc::new(Entry {
            pairing: true,
            pairing_state: AtomicUsize::new(1),
            submit: Mutex::new((0, tx)),
            receive: Mutex::new(Receiver {
                pending: None,
                queue,
            }),
            cancel,
            ready: AtomicBool::new(true),
            done: Arc::new(AtomicBool::new(false)),
            video: Arc::new(crate::video::VideoMailbox::default()),
            screen_allowed: false,
            cleanup: None,
        });
        let id = NEXT.fetch_add(1, Ordering::SeqCst);
        registry().lock().unwrap().insert(id, entry.clone());
        let mut header = EventHeader::default();
        assert_eq!(
            unsafe { ncm_backend_video_poll(id, &mut header, std::ptr::null_mut(), 0) },
            NOT_READY
        );
        assert_eq!(ncm_backend_video_refresh(id), NOT_READY);
        let mut snapshot = crate::video::VideoSnapshot::default();
        assert_eq!(
            unsafe { ncm_backend_video_get_snapshot(id, &mut snapshot) },
            NOT_READY
        );
        let mut cursor = crate::video::VideoDecodeCursor::default();
        assert_eq!(
            unsafe { ncm_backend_video_get_decode_cursor(id, &mut cursor) },
            NOT_READY
        );
        let mut status = crate::video::VideoStatus::default();
        assert_eq!(
            unsafe { ncm_backend_video_get_status(id, &mut status) },
            NOT_READY
        );
        assert_eq!(pairing::ncm_pairing_ack(id, 2), NOT_READY);
        assert_eq!(pairing::ncm_pairing_ack(id, 1), 0);
        assert_eq!(pairing::ncm_pairing_ack(id, 1), NOT_READY);
        assert_eq!(pairing::ncm_pairing_ack(id, 2), NOT_READY);
        let request = rx.try_recv().unwrap();
        assert_eq!(request.id, 1);
        assert_eq!(request.action, 6);
        entry.pairing_state.store(2, Ordering::SeqCst);
        assert_eq!(pairing::ncm_pairing_ack(id, 1), NOT_READY);
        assert_eq!(pairing::ncm_pairing_ack(id, 2), 0);
        assert_eq!(rx.try_recv().unwrap().id, 2);
        ncm_backend_close(id);
        assert_eq!(pairing::ncm_pairing_ack(id, 2), CLOSED);
    }

    #[tokio::test]
    async fn explicit_pairing_attempts_advertise_distinct_v4_identifiers() {
        let _test = TEST_LOCK.lock().await;
        struct PairingHandle(u64);
        impl Drop for PairingHandle {
            fn drop(&mut self) {
                ncm_backend_close(self.0);
            }
        }
        let mut identifiers = Vec::new();
        for _ in 0..2 {
            let mut id = 0;
            assert_eq!(unsafe { pairing::ncm_pairing_start(1, &mut id) }, 0);
            let handle = PairingHandle(id);
            let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(3);
            let mut header = EventHeader::default();
            loop {
                let code = unsafe { ncm_backend_poll(id, &mut header, std::ptr::null_mut(), 0) };
                if code == SMALL {
                    break;
                }
                assert_eq!(code, EMPTY);
                assert!(tokio::time::Instant::now() < deadline);
                tokio::time::sleep(std::time::Duration::from_millis(5)).await;
            }
            assert_eq!(header.kind, 5);
            let mut payload = vec![0; header.size];
            assert_eq!(
                unsafe { ncm_backend_poll(id, &mut header, payload.as_mut_ptr(), payload.len()) },
                0
            );
            let advertisement: serde_json::Value = serde_json::from_slice(&payload).unwrap();
            let identifier = advertisement["identifier"].as_str().unwrap();
            let parsed = uuid::Uuid::parse_str(identifier).unwrap();
            assert_eq!(parsed.get_version_num(), 4);
            assert_eq!(advertisement["txt"]["identifier"], identifier);
            identifiers.push(parsed);
            drop(handle);
            while WORKERS.load(Ordering::SeqCst) != 0 {
                assert!(tokio::time::Instant::now() < deadline);
                tokio::time::sleep(std::time::Duration::from_millis(5)).await;
            }
        }
        assert_ne!(identifiers[0], identifiers[1]);
    }

    #[tokio::test]
    async fn explicit_pairing_listener_requires_consent_and_close_releases_port() {
        let _test = TEST_LOCK.lock().await;
        let mut id = 99;
        assert_eq!(unsafe { pairing::ncm_pairing_start(0, &mut id) }, INVALID);
        assert_eq!(id, 0);
        assert_eq!(unsafe { pairing::ncm_pairing_start(1, &mut id) }, 0);
        let mut header = EventHeader::default();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(3);
        loop {
            let code = unsafe { ncm_backend_poll(id, &mut header, std::ptr::null_mut(), 0) };
            if code == SMALL {
                break;
            }
            assert_eq!(code, EMPTY);
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
        assert_eq!(header.kind, 5);
        let mut payload = vec![0; header.size];
        assert_eq!(
            unsafe { ncm_backend_poll(id, &mut header, payload.as_mut_ptr(), payload.len()) },
            0
        );
        let value: serde_json::Value = serde_json::from_slice(&payload).unwrap();
        assert!(value.get("seed").is_none());
        assert_eq!(value["txt"]["identifier"], value["identifier"]);
        assert_eq!(pairing::ncm_pairing_ack(id, 1), NOT_READY);
        assert_eq!(ncm_backend_submit(id, 1, 1, 0, 0), INVALID);
        let port = value["port"].as_u64().unwrap() as u16;
        let mut peer = tokio::net::TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, port))
            .await
            .expect("connect pairing fixture");
        loop {
            let code = unsafe { ncm_backend_poll(id, &mut header, std::ptr::null_mut(), 0) };
            if code == 0 {
                break;
            }
            assert_eq!(code, EMPTY);
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
        assert_eq!(
            (
                header.request_id,
                header.kind,
                header.stage,
                header.cause,
                header.reserved,
                header.size
            ),
            (0, 10, 1, 0, 0, 0)
        );
        // A nil/zero poll consumes the empty diagnostic; it is not retained as
        // a buffer-size query or mistaken for a command failure.
        assert_eq!(
            unsafe { ncm_backend_poll(id, &mut header, std::ptr::null_mut(), 0) },
            EMPTY
        );
        ncm_backend_close(id);
        ncm_backend_close(id);
        assert_eq!(
            unsafe { ncm_backend_poll(id, &mut header, std::ptr::null_mut(), 0) },
            CLOSED
        );
        let mut remaining = Vec::new();
        match tokio::time::timeout_at(deadline, peer.read_to_end(&mut remaining))
            .await
            .expect("close did not release accepted TCP connection")
        {
            Ok(_) => {}
            Err(error) => assert!(matches!(
                error.kind(),
                std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::ConnectionAborted
            )),
        }
        loop {
            if tokio::net::TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, port))
                .await
                .is_err()
            {
                break;
            }
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
        while WORKERS.load(Ordering::SeqCst) != 0 {
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
    }

    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    #[tokio::test]
    async fn polling_keeps_payload_until_sufficient_buffer_and_close_revokes_handle() {
        let _test = TEST_LOCK.lock().await;
        let (send, queue) = mpsc::channel(1);
        let (tx, _) = mpsc::channel(1);
        let (cancel, _) = watch::channel(false);
        let entry = Arc::new(Entry {
            pairing: false,
            pairing_state: AtomicUsize::new(0),
            submit: Mutex::new((0, tx)),
            receive: Mutex::new(Receiver {
                pending: None,
                queue,
            }),
            cancel,
            ready: AtomicBool::new(true),
            done: Arc::new(AtomicBool::new(false)),
            video: Arc::new(crate::video::VideoMailbox::default()),
            screen_allowed: true,
            cleanup: None,
        });
        let id = NEXT.fetch_add(1, Ordering::SeqCst);
        registry().lock().unwrap().insert(id, entry);
        send.try_send(Event::ok(9, 4, vec![1, 2, 3]))
            .unwrap_or_else(|_| panic!("queue"));
        let mut h = EventHeader::default();
        assert_eq!(
            unsafe { ncm_backend_video_poll(id, &mut h, std::ptr::null_mut(), 0) },
            EMPTY
        );
        assert_eq!(ncm_backend_video_refresh(id), 0);
        let mut status = crate::video::VideoStatus::default();
        assert_eq!(unsafe { ncm_backend_video_get_status(id, &mut status) }, 0);
        assert_eq!(status.datagrams, 0);
        let mut snapshot = crate::video::VideoSnapshot::default();
        assert_eq!(
            unsafe { ncm_backend_video_get_snapshot(id, &mut snapshot) },
            0
        );
        assert_eq!(snapshot.serial, 0);
        assert_eq!(
            unsafe { ncm_backend_video_get_snapshot(id, std::ptr::null_mut()) },
            INVALID
        );
        assert_eq!(
            unsafe { ncm_backend_video_get_snapshot(u64::MAX, &mut snapshot) },
            CLOSED
        );
        let mut cursor = crate::video::VideoDecodeCursor::default();
        assert_eq!(
            unsafe { ncm_backend_video_get_decode_cursor(id, &mut cursor) },
            0
        );
        assert_eq!(cursor.serial, 0);
        assert_eq!(
            unsafe { ncm_backend_video_get_decode_cursor(id, std::ptr::null_mut()) },
            INVALID
        );
        assert_eq!(
            unsafe { ncm_backend_video_get_decode_cursor(u64::MAX, &mut cursor) },
            CLOSED
        );
        assert_eq!(
            unsafe { ncm_backend_video_get_status(id, std::ptr::null_mut()) },
            INVALID
        );

        assert_eq!(
            unsafe { ncm_backend_poll(id, &mut h, std::ptr::null_mut(), 0) },
            SMALL
        );
        assert_eq!((h.request_id, h.size), (9, 3));
        let mut output = [0; 3];
        assert_eq!(
            unsafe { ncm_backend_poll(id, &mut h, output.as_mut_ptr(), 3) },
            0
        );
        assert_eq!(output, [1, 2, 3]);
        ncm_backend_close(id);
        assert_eq!(
            unsafe { ncm_backend_video_get_decode_cursor(id, &mut cursor) },
            CLOSED
        );
        assert_eq!(
            unsafe { ncm_backend_poll(id, &mut h, std::ptr::null_mut(), 0) },
            CLOSED
        );
        ncm_backend_close(id);
    }
    #[tokio::test]
    async fn command_queue_is_bounded_and_duplicate_ids_are_rejected() {
        let _test = TEST_LOCK.lock().await;
        let (tx, mut rx) = mpsc::channel(1);
        let (_send, queue) = mpsc::channel(1);
        let (cancel, _) = watch::channel(false);
        let entry = Arc::new(Entry {
            pairing: false,
            pairing_state: AtomicUsize::new(0),
            submit: Mutex::new((0, tx)),
            receive: Mutex::new(Receiver {
                pending: None,
                queue,
            }),
            cancel,
            ready: AtomicBool::new(true),
            done: Arc::new(AtomicBool::new(false)),
            video: Arc::new(crate::video::VideoMailbox::default()),
            screen_allowed: false,
            cleanup: None,
        });
        let id = NEXT.fetch_add(1, Ordering::SeqCst);
        registry().lock().unwrap().insert(id, entry);
        // Invalid drag must not consume the monotonic request ID or queue slot.
        assert_eq!(ncm_backend_drag(id, 1, 0, 0, 65535, 65535, 99), INVALID);
        assert_eq!(ncm_backend_drag(id, 1, 0, 0, 65535, 65535, 2001), INVALID);
        assert_eq!(ncm_backend_drag(id, 1, 0, 0, 65535, 65535, 100), 0);
        let drag = rx.try_recv().unwrap();
        assert_eq!(
            (drag.action, drag.end_x, drag.end_y, drag.duration),
            (6, 65535, 65535, 100)
        );
        assert_eq!(ncm_backend_submit(id, 2, 2, 0, 0), 0);
        assert_eq!(ncm_backend_drag(id, 2, 0, 0, 1, 1, 100), INVALID);
        assert_eq!(ncm_backend_submit(id, 2, 2, 0, 0), INVALID);
        assert_eq!(ncm_backend_submit(id, 3, 2, 0, 0), BUSY);
        assert_eq!(rx.try_recv().unwrap().id, 2);
        assert_eq!(ncm_backend_submit(id, 3, 2, 0, 0), 0);
        ncm_backend_close(id);
    }
    #[tokio::test]
    async fn closing_one_handle_preserves_another_sessions_reply() {
        let _test = TEST_LOCK.lock().await;
        let mut ids = Vec::new();
        for value in [11, 22] {
            let (tx, _) = mpsc::channel(1);
            let (events, queue) = mpsc::channel(1);
            let (cancel, _) = watch::channel(false);
            let entry = Arc::new(Entry {
                pairing: false,
                pairing_state: AtomicUsize::new(0),
                submit: Mutex::new((0, tx)),
                receive: Mutex::new(Receiver {
                    pending: None,
                    queue,
                }),
                cancel,
                ready: AtomicBool::new(true),
                done: Arc::new(AtomicBool::new(false)),
                video: Arc::new(crate::video::VideoMailbox::default()),
                screen_allowed: false,
                cleanup: None,
            });
            let id = NEXT.fetch_add(1, Ordering::SeqCst);
            registry().lock().unwrap().insert(id, entry);
            events
                .try_send(Event::ok(1, 4, vec![value]))
                .unwrap_or_else(|_| panic!("fixture queue"));
            ids.push(id);
        }
        ncm_backend_close(ids[0]);
        let mut h = EventHeader::default();
        let mut byte = [0];
        assert_eq!(
            unsafe { ncm_backend_poll(ids[0], &mut h, byte.as_mut_ptr(), 1) },
            CLOSED
        );
        assert_eq!(
            unsafe { ncm_backend_poll(ids[1], &mut h, byte.as_mut_ptr(), 1) },
            0
        );
        assert_eq!(byte, [22]);
        ncm_backend_close(ids[1]);
    }
    #[tokio::test]
    async fn ffi_worker_reports_real_handshake_failure_and_cancels_pending_read() {
        let _test = TEST_LOCK.lock().await;
        struct Connector(Mutex<Option<tokio::io::DuplexStream>>);
        impl NcmConnector for Connector {
            fn connect(&self, _: crate::Purpose) -> crate::DialFuture<'_> {
                Box::pin(async move {
                    Ok(Box::new(self.0.lock().unwrap().take().unwrap()) as crate::Stream)
                })
            }
        }
        let (stream, mut peer) = tokio::io::duplex(4096);
        let id = launch(
            Connector(Mutex::new(Some(stream))),
            fixture_identity(),
            VERIFY,
        )
        .unwrap();
        let mut magic = [0; 9];
        peer.read_exact(&mut magic).await.unwrap();
        assert_eq!(&magic, b"RPPairing");
        peer.write_all(b"bad").await.unwrap();
        peer.shutdown().await.unwrap();
        let mut h = EventHeader::default();
        for _ in 0..100 {
            let r = unsafe { ncm_backend_poll(id, &mut h, std::ptr::null_mut(), 0) };
            if r == 0 {
                break;
            }
            assert_eq!(r, EMPTY);
            tokio::time::sleep(std::time::Duration::from_millis(2)).await;
        }
        assert_eq!(h.kind, 3);
        assert_eq!(h.stage, Stage::PairVerify as u32 + 1);
        ncm_backend_close(id);
        let (stream, mut peer) = tokio::io::duplex(4096);
        let id = launch(
            Connector(Mutex::new(Some(stream))),
            fixture_identity(),
            VERIFY,
        )
        .unwrap();
        peer.read_exact(&mut magic).await.unwrap();
        ncm_backend_close(id);
        let mut drain = Vec::new();
        tokio::time::timeout(
            std::time::Duration::from_secs(1),
            peer.read_to_end(&mut drain),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(ncm_backend_submit(id, 1, 2, 0, 0), CLOSED);
    }
    #[tokio::test]
    async fn ordinary_lockdown_worker_ready_only_after_tls_and_stops_cleanly() {
        let _test = TEST_LOCK.lock().await;
        use crate::lockdown::tests as peer;
        struct Connector(Mutex<Option<tokio::io::DuplexStream>>);
        impl NcmConnector for Connector {
            fn connect(&self, purpose: crate::Purpose) -> crate::DialFuture<'_> {
                assert_eq!(purpose, crate::Purpose::LockdownSession);
                Box::pin(async move {
                    Ok(Box::new(self.0.lock().unwrap().take().unwrap()) as crate::Stream)
                })
            }
        }
        let (stream, mut device) = tokio::io::duplex(4096);
        let id = launch_lockdown(Connector(Mutex::new(Some(stream))), peer::identity()).unwrap();
        let request = peer::read(&mut device).await;
        assert_eq!(
            request.get("Request").and_then(plist::Value::as_string),
            Some("StartSession")
        );
        let mut event = EventHeader::default();
        assert_eq!(
            unsafe { ncm_backend_poll(id, &mut event, std::ptr::null_mut(), 0) },
            EMPTY
        );
        peer::write(&mut device, peer::start_reply()).await;
        let mut tls = peer::acceptor(false).accept(device).await.unwrap();
        async fn poll(id: u64) -> EventHeader {
            tokio::time::timeout(std::time::Duration::from_secs(2), async {
                loop {
                    let mut e = EventHeader::default();
                    let status = unsafe { ncm_backend_poll(id, &mut e, std::ptr::null_mut(), 0) };
                    if status == 0 {
                        return e;
                    }
                    assert_eq!(status, EMPTY);
                    tokio::time::sleep(std::time::Duration::from_millis(2)).await;
                }
            })
            .await
            .unwrap()
        }
        let ready = poll(id).await;
        assert_eq!(ready.kind, 2);
        assert_eq!(ready.request_id, 0);
        assert_eq!(ncm_backend_submit(id, 1, 5, 0, 0), 0);
        let stop = peer::read(&mut tls).await;
        assert_eq!(
            stop.get("Request").and_then(plist::Value::as_string),
            Some("StopSession")
        );
        let mut response = plist::Dictionary::new();
        response.insert("Request".into(), "StopSession".into());
        peer::write(&mut tls, response).await;
        let stopped = poll(id).await;
        assert_eq!(stopped.kind, 2);
        assert_eq!(stopped.request_id, 1);
        ncm_backend_close(id);
    }
}
