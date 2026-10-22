// SPDX-License-Identifier: GPL-3.0-only
//! Eiscue's DisplayService lifecycle, RTP consumer and serialized touch executor.
//! Uses idevice for wire protocols. Compatibility fixtures from the prior backend
//! are retained below; this is a reimplementation, not a clean-room claim.
use crate::{
    Cause, Error, Stage, Stream, bounded, bounded_for, error,
    video::{DisplayGeometry, VideoMailbox},
};
use idevice::{
    RsdService,
    core_device::{
        CoreDeviceError, CoreDeviceServiceClient, DisplayServiceClient, TouchEvent, TouchPoint,
        UniversalHidServiceClient,
        display_stream::{
            ReportBlock, RtpPacket, SenderReport, build_frame_ack, build_liveness, build_pli,
            build_rctl, build_start_video_parameters,
            hevc::{HevcAccessUnitAssembler, HevcDepacketizerEvent},
            is_rtcp,
            negotiation::{
                CallInfoBlob, ScreenVideoStream, build_screen_video_offer_with_bitrate,
                parse_screen_video_answer,
            },
        },
    },
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle,
};
use std::{
    collections::BTreeSet,
    future::Future,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::task::JoinHandle;

const DISPLAY_ID: i64 = 1;
const REQUESTED_VIDEO_PORT: u16 = 50001;
// Preserve the measured relay bandwidth ceiling and negotiated wire profile.
const RECEIVER_BANDWIDTH_KBPS: u16 = 2000;

struct DisplayInfoClient(CoreDeviceServiceClient<Stream>);
impl RsdService for DisplayInfoClient {
    fn rsd_service_name() -> std::borrow::Cow<'static, str> {
        "com.apple.coredevice.deviceinfo".into()
    }
    async fn from_stream(stream: Stream) -> Result<Self, idevice::IdeviceError> {
        CoreDeviceServiceClient::new(stream).await.map(Self)
    }
}
fn geometry_error() -> idevice::IdeviceError {
    CoreDeviceError::MalformedField("display geometry").into()
}
fn display_geometry(value: &plist::Value, id: i64) -> Option<DisplayGeometry> {
    let object = value.as_dictionary()?;
    if object.get("current")?.as_boolean()? != true {
        return None;
    }
    let mut selected = None;
    for display in object.get("displays")?.as_array()? {
        let Some(display) = display.as_dictionary() else {
            continue;
        };
        if display
            .get("displayId")
            .and_then(plist::Value::as_signed_integer)
            != Some(id)
        {
            continue;
        }
        if selected.replace(display).is_some() {
            return None;
        }
    }
    let selected = selected?;
    let frame = selected.get("frame")?.as_array()?;
    let [origin, extent] = frame.as_slice() else {
        return None;
    };
    let [x, y] = origin.as_array()?.as_slice() else {
        return None;
    };
    let [width, height] = extent.as_array()?.as_slice() else {
        return None;
    };
    let number = |value: &plist::Value| {
        value
            .as_real()
            .or_else(|| value.as_signed_integer().map(|n| n as f64))
    };
    if number(x)? != 0.0 || number(y)? != 0.0 {
        return None;
    }
    let dimension = |value: &plist::Value| -> Option<u32> {
        let value = number(value)?;
        (value.is_finite() && value.fract() == 0.0 && (1.0..=16384.0).contains(&value))
            .then_some(value as u32)
    };
    let orientation = |name| match selected.get(name)?.as_string()? {
        "rot0" => Some(0),
        "rot90" => Some(90),
        "rot180" => Some(180),
        "rot270" => Some(270),
        _ => None,
    };
    Some(DisplayGeometry {
        width: dimension(width)?,
        height: dimension(height)?,
        native_rotation: orientation("nativeOrientation")?,
        rotation: orientation("currentOrientation")?,
    })
}
async fn subscribe_display_geometry(
    client: &mut DisplayInfoClient,
    id: i64,
) -> Result<DisplayGeometry, idevice::IdeviceError> {
    client
        .0
        .begin_stream_with_plist(
            "com.apple.coredevice.feature.displayinfoupdates",
            Default::default(),
            Some("com.apple.coredevice.action.displayinfoupdates"),
        )
        .await?;
    loop {
        let rows = client
            .0
            .next_stream_batch()
            .await?
            .ok_or_else(geometry_error)?;
        let mut current = None;
        for row in rows {
            current = Some(display_geometry(&row, id).ok_or_else(geometry_error)?);
        }
        if let Some(current) = current {
            return Ok(current);
        }
    }
}
async fn verify_current_geometry(
    mailbox: &VideoMailbox,
    fresh: impl Future<Output = Result<DisplayGeometry, Error>>,
) -> Result<bool, Error> {
    let observed = mailbox.decode_cursor();
    if observed.serial == 0 {
        return Ok(false);
    }
    let result = fresh.await;
    match result {
        Ok(value) => Ok(mailbox.verify_display_geometry(observed.epoch, value)),
        Err(failure) => {
            mailbox.reset();
            Err(failure)
        }
    }
}

#[derive(Default)]
struct Drains(Vec<JoinHandle<()>>);
impl Drop for Drains {
    fn drop(&mut self) {
        for task in self.0.drain(..) {
            task.abort();
        }
    }
}
/// Every worker exit, including abort while a socket write is pending, revokes
/// video authority. The other worker cannot resurrect health afterward.
struct WorkerLifetime {
    health: Arc<AtomicBool>,
    mailbox: Arc<VideoMailbox>,
}
impl Drop for WorkerLifetime {
    fn drop(&mut self) {
        self.health.store(false, Ordering::SeqCst);
        self.mailbox.reset();
    }
}
pub(crate) struct Media {
    _video: DisplayServiceClient<Stream>,
    hid: UniversalHidServiceClient<Stream>,
    _drains: Drains,
    healthy: Arc<AtomicBool>,
    mailbox: Arc<VideoMailbox>,
    diagnostic_identity: crate::media_diagnostic::Identity,
}
impl Drop for Media {
    fn drop(&mut self) {
        self.healthy.store(false, Ordering::SeqCst);
        self.mailbox.reset();
    }
}
#[derive(Default, Debug, Eq, PartialEq)]
pub(crate) enum ReleaseState {
    #[default]
    Idle,
    Unknown,
    Owned(u32),
}
impl ReleaseState {
    pub fn is_idle(&self) -> bool {
        self == &Self::Idle
    }
    fn claim(&mut self, identifier: u32) -> Result<(), Error> {
        if identifier == 0 || !matches!(self, Self::Unknown | Self::Owned(_)) {
            return Err(error(Stage::VideoAnswer, Cause::Protocol));
        }
        if let Self::Owned(prior) = self {
            if *prior != identifier {
                return Err(error(Stage::VideoAnswer, Cause::Protocol));
            }
        }
        *self = Self::Owned(identifier);
        Ok(())
    }
    async fn stop_with<F, Fut>(&mut self, stop: F) -> Result<(), Error>
    where
        F: FnOnce(u32) -> Fut,
        Fut: Future<Output = Result<plist::Value, Error>>,
    {
        let identifier = match self {
            Self::Idle => return Ok(()),
            Self::Unknown => return Err(error(Stage::Media, Cause::DeliveryUncertain)),
            Self::Owned(identifier) => *identifier,
        };
        let response = stop(identifier).await?;
        if !stop_confirmed(&response, identifier) {
            return Err(error(Stage::Media, Cause::Protocol));
        }
        *self = Self::Idle;
        Ok(())
    }
    pub async fn stop(
        &mut self,
        adapter: &mut AdapterHandle,
        handshake: &mut RsdHandshake,
    ) -> Result<(), Error> {
        self.stop_with(|owned| async move {
            let mut client = bounded(
                Stage::Media,
                DisplayServiceClient::connect_rsd(adapter, handshake),
            )
            .await?;
            bounded(Stage::Media, client.stop_media_stream_identifiers(&[owned])).await
        })
        .await
    }
}
fn original_stream_config(answer: &plist::Value) -> Option<&plist::Dictionary> {
    answer
        .as_dictionary()?
        .get("connection")?
        .as_dictionary()?
        .get("streamConfig")?
        .as_dictionary()
}
fn nonzero_u32(value: Option<&plist::Value>) -> Option<u32> {
    u32::try_from(value?.as_unsigned_integer()?)
        .ok()
        .filter(|n| *n != 0)
}
fn owned_start_identifier(answer: &plist::Value) -> Option<u32> {
    nonzero_u32(original_stream_config(answer)?.get("RemoteSSRC"))
}
#[cfg(test)]
async fn start_reply(
    release: &mut ReleaseState,
    start: impl Future<Output = Result<plist::Value, Error>>,
) -> Result<(plist::Value, ScreenVideoStream), Error> {
    start_reply_retained(release, &Default::default(), uuid::Uuid::nil(), start).await
}
async fn start_reply_retained(
    release: &mut ReleaseState,
    cleanup: &crate::media_cleanup::Shared,
    session: uuid::Uuid,
    start: impl Future<Output = Result<plist::Value, Error>>,
) -> Result<(plist::Value, ScreenVideoStream), Error> {
    crate::media_cleanup::begin(cleanup)?;
    *release = ReleaseState::Unknown;
    let reply = start.await?;
    // Commit the original reply's stop identifier before any fallible parsing.
    // No status listing can replace it, even after negotiation fails.
    if let Some(identifier) = owned_start_identifier(&reply) {
        release.claim(identifier)?;
    }
    let stream = parse_screen_video_answer(extract_answer(&reply)?)
        .map_err(|_| error(Stage::VideoAnswer, Cause::Protocol))?;
    if let Some(receipt) = crate::media_cleanup::Receipt::from_start(&reply, session, stream.ssrc) {
        crate::media_cleanup::set(cleanup, crate::media_cleanup::State::Owned(receipt))?;
    }
    Ok((reply, stream))
}

impl Media {
    pub fn quiesce(&mut self) {
        self.healthy.store(false, Ordering::SeqCst);
        for task in self._drains.0.drain(..) {
            task.abort();
        }
        self.mailbox.reset();
    }
    pub async fn status_diagnostic(
        &self,
        adapter: &mut AdapterHandle,
        handshake: &mut RsdHandshake,
    ) -> Result<Vec<u8>, Error> {
        crate::media_diagnostic::query(&self.diagnostic_identity, &self.healthy, async {
            let mut query = DisplayServiceClient::connect_rsd(adapter, handshake)
                .await
                .map_err(|_| error(Stage::VideoService, Cause::Protocol))?;
            query
                .get_media_stream_server_status()
                .await
                .map_err(|_| error(Stage::Media, Cause::Protocol))
        })
        .await
    }
    pub async fn verify_geometry(
        &self,
        adapter: &mut AdapterHandle,
        handshake: &mut RsdHandshake,
        mailbox: &VideoMailbox,
    ) -> Result<bool, Error> {
        if !self.healthy.load(Ordering::SeqCst) {
            return Ok(false);
        }
        let fresh = bounded_for(Stage::VideoService, Duration::from_secs(2), async {
            let mut query = DisplayInfoClient::connect_rsd(adapter, handshake).await?;
            display_geometry(&query.0.current_display_info().await?, DISPLAY_ID)
                .ok_or_else(geometry_error)
        });
        let confirmed = verify_current_geometry(mailbox, fresh).await?;
        Ok(confirmed && self.healthy.load(Ordering::SeqCst))
    }
    pub async fn start(
        adapter: &mut AdapterHandle,
        handshake: &mut RsdHandshake,
        mailbox: Arc<VideoMailbox>,
        release: &mut ReleaseState,
        cleanup: &crate::media_cleanup::Shared,
    ) -> Result<Self, Error> {
        let video_udp = bounded(Stage::VideoReceiver, adapter.bind_udp(0)).await?;
        let session = uuid::Uuid::new_v4();
        let call = uuid::Uuid::new_v4();
        let call_id = call.to_string().to_uppercase();
        let offer_ssrc =
            u32::from_be_bytes(uuid::Uuid::new_v4().as_bytes()[..4].try_into().unwrap()).max(1);
        let profile = CallInfoBlob {
            call_id: 0,
            client_version: 1,
            device_type: "Mac17,7".into(),
            framework_version: "2205.3.1".into(),
            os_version: "25F71".into(),
            device_name: None,
            audio_device_uid: None,
        };
        let offer = build_screen_video_offer_with_bitrate(
            &call_id,
            &profile,
            offer_ssrc,
            u32::from(RECEIVER_BANDWIDTH_KBPS) * 1000,
        )
        .map_err(|_| error(Stage::VideoAnswer, Cause::Protocol))?;
        let mut video = bounded(
            Stage::VideoService,
            DisplayServiceClient::connect_rsd(adapter, handshake),
        )
        .await?;
        let mut metadata = bounded(
            Stage::VideoService,
            DisplayInfoClient::connect_rsd(adapter, handshake),
        )
        .await?;
        let initial = bounded(
            Stage::VideoService,
            subscribe_display_geometry(&mut metadata, DISPLAY_ID),
        )
        .await?;
        let request = build_start_video_parameters(
            &adapter.host_ip().to_string(),
            video_udp.local_port(),
            &adapter.peer_ip().to_string(),
            REQUESTED_VIDEO_PORT,
            offer,
            140,
            DISPLAY_ID,
            session,
        );
        let (reply, stream) = start_reply_retained(
            release,
            cleanup,
            session,
            Box::pin(bounded(
                Stage::VideoNegotiation,
                video.start_media_stream(request),
            )),
        )
        .await?;
        let endpoint = match feedback_endpoint(&reply, stream.ssrc) {
            Some(endpoint) => endpoint,
            None => {
                let status =
                    bounded(Stage::VideoAnswer, video.get_media_stream_server_status()).await?;
                feedback_endpoint(&status, stream.ssrc)
                    .ok_or(error(Stage::VideoAnswer, Cause::Protocol))?
            }
        };
        let (port, _, receiver_ssrc) = endpoint;
        release.claim(receiver_ssrc)?;
        let diagnostic_identity =
            crate::media_diagnostic::Identity::new(session, call, stream.ssrc, receiver_ssrc);
        mailbox.begin_stream();
        mailbox.set_display_geometry(Some(initial));
        let healthy = Arc::new(AtomicBool::new(true));
        let mut drains = Drains::default();
        let lifetime = WorkerLifetime {
            health: healthy.clone(),
            mailbox: mailbox.clone(),
        };
        drains.0.push(tokio::spawn(async move {
            let _lifetime = lifetime;
            loop {
                let Ok(Some(rows)) = metadata.0.next_stream_batch().await else {
                    break;
                };
                if !_lifetime.health.load(Ordering::SeqCst) {
                    return;
                }
                for row in rows {
                    let value = display_geometry(&row, DISPLAY_ID);
                    _lifetime.mailbox.set_display_geometry(value);
                    if value.is_none() {
                        return;
                    }
                }
            }
            _lifetime.mailbox.set_display_geometry(None);
        }));
        let lifetime = WorkerLifetime {
            health: healthy.clone(),
            mailbox: mailbox.clone(),
        };
        drains.0.push(tokio::spawn(async move {
            let _lifetime = lifetime;
            let mut receiver = VideoReceiver::new(stream, receiver_ssrc, call_id, _lifetime.mailbox.clone());
            let mut control = tokio::time::interval(Duration::from_millis(50));
            let mut recovery = tokio::time::interval(Duration::from_secs(1));
            control.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            recovery.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                if !_lifetime.health.load(Ordering::SeqCst) { return; }
                let feedback = tokio::select! {
                    datagram = video_udp.recv() => {
                        let Ok(datagram) = datagram else { return; };
                        if !_lifetime.health.load(Ordering::SeqCst) { return; }
                        receiver.mailbox.received_from(datagram.source_port);
                        receiver.accept(&datagram.data)
                    }
                    _ = control.tick() => receiver.feedback.control_report(),
                    _ = recovery.tick() => Some(receiver.feedback.recovery_report(&receiver.mailbox, false)),
                };
                if let Some(feedback) = feedback {
                    if video_udp.send_to(port, feedback).await.is_err() { return; }
                }
            }
        }));
        // Retain the accepted media service while allowing HID surfaces to settle.
        tokio::time::sleep(Duration::from_millis(350)).await;
        let hid = bounded(
            Stage::TouchService,
            UniversalHidServiceClient::connect_rsd(adapter, handshake),
        )
        .await?;
        if !healthy.load(Ordering::SeqCst) {
            return Err(error(Stage::Media, Cause::MediaInactive));
        }
        Ok(Self {
            _video: video,
            hid,
            _drains: drains,
            healthy,
            mailbox,
            diagnostic_identity,
        })
    }
    async fn perform_gesture(
        &mut self,
        schedule: Vec<(Duration, TouchEvent)>,
    ) -> Result<(), Error> {
        if !self.healthy.load(Ordering::SeqCst) {
            return Err(error(Stage::Input, Cause::MediaInactive));
        }
        // The mutable Media borrow serializes all reports in the gesture. From
        // the first write onward any cancellation/error is an uncertain effect.
        let mut started = None;
        for (at, event) in schedule {
            if let Some(started) = started {
                tokio::time::sleep_until(started + at).await;
            }
            if !self.healthy.load(Ordering::SeqCst) {
                return Err(error(Stage::Input, Cause::DeliveryUncertain));
            }
            bounded(Stage::Input, self.hid.send_touch(event, None))
                .await
                .map_err(|_| error(Stage::Input, Cause::DeliveryUncertain))?;
            // Duration measures the contact after Down is delivered, so a slow
            // initial write cannot compress every Move/Up into the same instant.
            started.get_or_insert_with(tokio::time::Instant::now);
        }
        Ok(())
    }
    pub async fn tap(&mut self, x: u16, y: u16) -> Result<(), Error> {
        let point = TouchPoint::new(x, y);
        self.perform_gesture(vec![
            (Duration::ZERO, TouchEvent::Down(point)),
            (Duration::from_millis(50), TouchEvent::Up(point)),
        ])
        .await
    }
    pub async fn drag(
        &mut self,
        x: u16,
        y: u16,
        end_x: u16,
        end_y: u16,
        duration: u16,
    ) -> Result<(), Error> {
        self.perform_gesture(drag_schedule(x, y, end_x, end_y, duration)?)
            .await
    }
}
fn drag_schedule(
    x: u16,
    y: u16,
    end_x: u16,
    end_y: u16,
    duration: u16,
) -> Result<Vec<(Duration, TouchEvent)>, Error> {
    if !(100..=2000).contains(&duration) {
        return Err(error(Stage::Input, Cause::InvalidParameters));
    }
    let count = u64::from(duration).div_ceil(20);
    let mut schedule = Vec::with_capacity(count as usize + 2);
    schedule.push((Duration::ZERO, TouchEvent::Down(TouchPoint::new(x, y))));
    for step in 1..=count {
        let coordinate = |a, b| {
            (i64::from(a) + (i64::from(b) - i64::from(a)) * step as i64 / count as i64) as u16
        };
        schedule.push((
            Duration::from_millis(u64::from(duration) * step / count),
            TouchEvent::Move(TouchPoint::new(coordinate(x, end_x), coordinate(y, end_y))),
        ));
    }
    schedule.push((
        Duration::from_millis(duration.into()),
        TouchEvent::Up(TouchPoint::new(end_x, end_y)),
    ));
    Ok(schedule)
}

struct VideoReceiver {
    expected: ScreenVideoStream,
    assembler: HevcAccessUnitAssembler,
    feedback: VideoFeedback,
    mailbox: Arc<VideoMailbox>,
}
impl VideoReceiver {
    fn new(
        expected: ScreenVideoStream,
        receiver_ssrc: u32,
        cname: String,
        mailbox: Arc<VideoMailbox>,
    ) -> Self {
        Self {
            assembler: HevcAccessUnitAssembler::new(expected.payload_type, expected.ssrc),
            feedback: VideoFeedback::new(receiver_ssrc, expected.ssrc, cname),
            expected,
            mailbox,
        }
    }
    fn accept(&mut self, bytes: &[u8]) -> Option<Vec<u8>> {
        if is_rtcp(bytes) {
            if let Some(report) =
                SenderReport::parse_first(bytes).filter(|report| report.ssrc == self.expected.ssrc)
            {
                self.feedback.sender_report =
                    Some((report.ntp_middle, tokio::time::Instant::now()));
                self.mailbox.sender_report(
                    report.packet_count == self.feedback.unique_packets
                        && self.assembler.is_complete(),
                );
            }
            return None;
        }
        let Some(packet) = parse_video_packet(bytes, self.expected) else {
            self.mailbox.count(2);
            return None;
        };
        self.mailbox.packet_pending();
        self.mailbox.count(1);
        let ack = self.feedback.observe_packet(&packet);
        for event in self.assembler.push_packet(&packet) {
            match event {
                HevcDepacketizerEvent::AccessUnit(unit) => {
                    self.mailbox.count(3);
                    let accepted = self
                        .assembler
                        .parameter_sets()
                        .is_some_and(|parameters| self.mailbox.push(unit, parameters));
                    if !accepted {
                        self.assembler.mark_stream_discontinuity();
                        self.mailbox.reset();
                    }
                }
                HevcDepacketizerEvent::Discontinuity(_) => {
                    self.mailbox.count(4);
                    self.mailbox.reset();
                }
                HevcDepacketizerEvent::PacketRejected(_) => self.mailbox.count(2),
            }
        }
        ack
    }
}
fn parse_video_packet(data: &[u8], expected: ScreenVideoStream) -> Option<RtpPacket<'_>> {
    if is_rtcp(data) {
        return None;
    }
    let packet = RtpPacket::parse_checked(data).ok()?;
    if packet.ssrc != expected.ssrc
        || packet.payload_type != expected.payload_type
        || packet.payload.is_empty()
    {
        return None;
    }
    Some(packet)
}
#[derive(Default)]
struct SequenceWindow {
    base: Option<u64>,
    highest: u64,
    seen: BTreeSet<u64>,
}
impl SequenceWindow {
    fn receive(&mut self, sequence: u16) -> bool {
        let extended = if self.base.is_none() {
            let initial = u64::from(sequence);
            self.base = Some(initial);
            self.highest = initial;
            initial
        } else {
            let distance = sequence.wrapping_sub(self.highest as u16) as i16;
            if distance == i16::MIN {
                return false;
            }
            let Some(extended) = self.highest.checked_add_signed(i64::from(distance)) else {
                return false;
            };
            extended
        };
        self.highest = self.highest.max(extended);
        let inserted = self.seen.insert(extended);
        // Keep exactly the reorder half-window; old packets can no longer be
        // distinguished from a future sequence cycle and must not count twice.
        self.seen = self.seen.split_off(&self.highest.saturating_sub(0x7fff));
        inserted
    }
    fn expected(&self) -> u32 {
        self.base
            .map(|base| {
                self.highest
                    .saturating_sub(base)
                    .saturating_add(1)
                    .min(u32::MAX as u64) as u32
            })
            .unwrap_or(0)
    }
}
struct VideoFeedback {
    receiver: u32,
    sender: u32,
    cname: String,
    sequence: SequenceWindow,
    timestamp: Option<u32>,
    packets: u32,
    unique_packets: u32,
    in_frame: u32,
    last_frame: u32,
    previous: (u32, u32),
    sender_report: Option<(u32, tokio::time::Instant)>,
}
impl VideoFeedback {
    fn new(receiver: u32, sender: u32, cname: String) -> Self {
        Self {
            receiver,
            sender,
            cname,
            sequence: Default::default(),
            timestamp: None,
            packets: 0,
            unique_packets: 0,
            in_frame: 0,
            last_frame: 0,
            previous: (0, 0),
            sender_report: None,
        }
    }
    fn observe_packet(&mut self, packet: &RtpPacket<'_>) -> Option<Vec<u8>> {
        if self.sequence.receive(packet.sequence_number) {
            self.unique_packets = self.unique_packets.wrapping_add(1);
        }
        if self
            .timestamp
            .is_none_or(|time| packet.timestamp.wrapping_sub(time) < 0x8000_0000)
        {
            self.timestamp = Some(packet.timestamp);
        }
        self.packets = self.packets.wrapping_add(1);
        self.in_frame = self.in_frame.saturating_add(1);
        if !packet.marker {
            return None;
        }
        self.last_frame = std::mem::take(&mut self.in_frame);
        Some(build_frame_ack(self.receiver, packet.timestamp))
    }
    fn control_report(&self) -> Option<Vec<u8>> {
        Some(build_rctl(
            self.receiver,
            self.timestamp?,
            self.last_frame,
            self.packets,
            RECEIVER_BANDWIDTH_KBPS,
        ))
    }
    fn liveness_report(&mut self) -> Vec<u8> {
        let expected = self.sequence.expected();
        let expected_interval = expected.saturating_sub(self.previous.0);
        let received_interval = self.unique_packets.saturating_sub(self.previous.1);
        let missing = expected_interval.saturating_sub(received_interval);
        let fraction_lost = if expected_interval == 0 {
            0
        } else {
            (u64::from(missing) * 256 / u64::from(expected_interval)).min(255) as u8
        };
        self.previous = (expected, self.unique_packets);
        let (lsr, dlsr) = self
            .sender_report
            .map(|(ntp, time)| {
                (
                    ntp,
                    (time.elapsed().as_secs_f64() * 65536.0).min(u32::MAX as f64) as u32,
                )
            })
            .unwrap_or_default();
        build_liveness(
            self.receiver,
            &self.cname,
            &[ReportBlock {
                source_ssrc: self.sender,
                fraction_lost,
                cumulative_lost: expected.saturating_sub(self.unique_packets).min(0x7fffff),
                highest_seq: self.sequence.highest as u32,
                jitter: 0,
                lsr,
                dlsr,
            }],
        )
    }
    fn keyframe_request(&mut self) -> Vec<u8> {
        build_pli(self.receiver, self.sender)
    }
    fn recovery_report(&mut self, mailbox: &VideoMailbox, needs_sync: bool) -> Vec<u8> {
        let requested = mailbox.take_refresh();
        let mut report = self.liveness_report();
        if requested || needs_sync || mailbox.needs_sync() {
            mailbox.count(6);
            report.extend(self.keyframe_request());
        }
        report
    }
}

fn stop_confirmed(reply: &plist::Value, identifier: u32) -> bool {
    let sessions = reply
        .as_dictionary()
        .and_then(|root| root.get("serverInfo"))
        .and_then(plist::Value::as_dictionary)
        .and_then(|server| server.get("sessions"))
        .and_then(plist::Value::as_array);
    sessions.is_some_and(|entries| {
        entries
            .iter()
            .all(|entry| owned_start_identifier(entry).is_some_and(|other| other != identifier))
    })
}
fn feedback_endpoint(value: &plist::Value, expected_sender: u32) -> Option<(u16, u32, u32)> {
    if expected_sender == 0 {
        return None;
    }
    let mut pending = vec![(value, 0)];
    let mut selected = None;
    let mut visited = 0;
    while let Some((value, depth)) = pending.pop() {
        visited += 1;
        if visited > 4096 {
            return None;
        }
        if depth > 5 {
            continue;
        }
        match value {
            plist::Value::Dictionary(fields) => {
                if nonzero_u32(fields.get("LocalSSRC")) == Some(expected_sender) {
                    let port =
                        u16::try_from(fields.get("SourcePort")?.as_unsigned_integer()?).ok()?;
                    let remote = nonzero_u32(fields.get("RemoteSSRC"))?;
                    if port == 0 || selected.replace((port, expected_sender, remote)).is_some() {
                        return None;
                    }
                }
                pending.extend(fields.values().map(|child| (child, depth + 1)));
            }
            plist::Value::Array(values) => {
                pending.extend(values.iter().map(|child| (child, depth + 1)))
            }
            _ => (),
        }
    }
    selected
}
fn extract_answer(value: &plist::Value) -> Result<&[u8], Error> {
    let failure = error(Stage::Media, Cause::Protocol);
    let mut pending = vec![(value, 0)];
    let mut selected = None;
    let mut visited = 0;
    while let Some((value, depth)) = pending.pop() {
        visited += 1;
        if visited > 4096 {
            return Err(failure);
        }
        if depth > 4 {
            continue;
        }
        match value {
            plist::Value::Dictionary(fields) => {
                for (name, child) in fields {
                    match name.as_str() {
                        "negotiatorAnswer" => {
                            let bytes = child.as_data().ok_or(failure)?;
                            if bytes.is_empty()
                                || bytes.len() > 1024 * 1024
                                || selected.replace(bytes).is_some()
                            {
                                return Err(failure);
                            }
                        }
                        "serverInfo" | "sessions" => (),
                        _ => pending.push((child, depth + 1)),
                    }
                }
            }
            plist::Value::Array(values) => {
                pending.extend(values.iter().map(|child| (child, depth + 1)))
            }
            _ => (),
        }
    }
    selected.ok_or(failure)
}

#[cfg(test)]
mod tests {
    fn stream_config(sender: u32, receiver: u32) -> plist::Value {
        plist::Dictionary::from_iter([
            ("SourcePort", plist::Value::from(53134u32)),
            ("LocalSSRC", plist::Value::from(sender)),
            ("RemoteSSRC", plist::Value::from(receiver)),
        ])
        .into()
    }
    fn start_response(config: plist::Value) -> plist::Value {
        let connection = plist::Dictionary::from_iter([("streamConfig", config)]);
        plist::Dictionary::from_iter([
            ("connection", connection.into()),
            ("negotiatorAnswer", plist::Value::Data(vec![1])),
        ])
        .into()
    }
    fn stop_response(ids: &[u32]) -> plist::Value {
        let sessions = ids
            .iter()
            .map(|id| start_response(stream_config(22, *id)))
            .collect();
        let server = plist::Dictionary::from_iter([("sessions", plist::Value::Array(sessions))]);
        plist::Dictionary::from_iter([("serverInfo", plist::Value::Dictionary(server))]).into()
    }

    #[tokio::test]
    async fn malformed_owned_start_retains_scoped_cleanup_across_failed_stops() {
        let mut release = ReleaseState::default();
        let result = start_reply(&mut release, async {
            Ok(start_response(stream_config(22, 11)))
        })
        .await;
        assert_eq!(
            result.unwrap_err(),
            error(Stage::VideoAnswer, Cause::Protocol)
        );
        assert_eq!(release, ReleaseState::Owned(11));
        for reply in [
            Err(error(Stage::Media, Cause::Timeout)),
            Ok(plist::Value::Dictionary(Default::default())),
            Ok(stop_response(&[11, 99])),
        ] {
            assert!(
                release
                    .stop_with(|id| async move {
                        assert_eq!(id, 11);
                        reply
                    })
                    .await
                    .is_err()
            );
            assert_eq!(
                release,
                ReleaseState::Owned(11),
                "No local Media object is needed to retain failed cleanup ownership"
            );
        }
        assert_eq!(
            release.claim(99),
            Err(error(Stage::VideoAnswer, Cause::Protocol))
        );
        assert_eq!(
            release,
            ReleaseState::Owned(11),
            "A conflicting configuration cannot replace our stop token"
        );
        release
            .stop_with(|id| async move {
                assert_eq!(id, 11);
                Ok(stop_response(&[99]))
            })
            .await
            .unwrap();
        assert!(release.is_idle());
        release
            .stop_with(|_| async { panic!("Confirmed release must be idempotent") })
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn lost_start_reply_and_foreign_status_never_become_noop_release_success() {
        let mut release = ReleaseState::default();
        let original = error(Stage::VideoNegotiation, Cause::Timeout);
        assert_eq!(
            start_reply(&mut release, async { Err(original) })
                .await
                .unwrap_err(),
            original
        );
        for _ in 0..2 {
            assert_eq!(
                release
                    .stop_with(|_| async { panic!("Unknown ownership must not send a stop") })
                    .await,
                Err(error(Stage::Media, Cause::DeliveryUncertain))
            );
        }
        for reply in [stop_response(&[99]), start_response(stream_config(22, 0))] {
            release = ReleaseState::Idle;
            assert!(
                start_reply(&mut release, async { Ok(reply) })
                    .await
                    .is_err()
            );
            assert_eq!(
                release,
                ReleaseState::Unknown,
                "Global status and zero tokens cannot establish owned media"
            );
        }
        release = ReleaseState::Idle;
        assert!(
            tokio::time::timeout(
                Duration::from_millis(1),
                start_reply(&mut release, std::future::pending())
            )
            .await
            .is_err()
        );
        assert_eq!(
            release,
            ReleaseState::Unknown,
            "Cancellation after dispatch must retain uncertainty"
        );
    }

    #[test]
    fn fallback_config_matches_only_the_owned_answer_and_rejects_ambiguity() {
        let status = plist::Value::Array(vec![stream_config(99, 77), stream_config(22, 11)]);
        assert_eq!(feedback_endpoint(&status, 22), Some((53134, 22, 11)));
        assert_eq!(feedback_endpoint(&stream_config(99, 77), 22), None);
        assert_eq!(
            feedback_endpoint(
                &plist::Value::Array(vec![stream_config(22, 11), stream_config(22, 12)]),
                22
            ),
            None
        );
        assert!(
            extract_answer(&stop_response(&[99])).is_err(),
            "A foreign session's negotiatorAnswer is not this start reply"
        );
        let mut reply = start_response(stream_config(22, 11))
            .into_dictionary()
            .unwrap();
        reply.extend(stop_response(&[99]).into_dictionary().unwrap());
        let reply = plist::Value::Dictionary(reply);
        assert_eq!(owned_start_identifier(&reply), Some(11));
        assert_eq!(extract_answer(&reply).unwrap(), &[1]);
    }

    #[test]
    fn stop_requires_peer_confirmation_and_does_not_confuse_other_streams() {
        fn response(ids: &[u32]) -> plist::Value {
            let sessions = ids
                .iter()
                .map(|id| {
                    let mut config = plist::Dictionary::new();
                    config.insert("RemoteSSRC".into(), (*id).into());
                    let mut connection = plist::Dictionary::new();
                    connection.insert("streamConfig".into(), config.into());
                    let mut session = plist::Dictionary::new();
                    session.insert("connection".into(), connection.into());
                    session.into()
                })
                .collect();
            let mut server = plist::Dictionary::new();
            server.insert("sessions".into(), plist::Value::Array(sessions));
            let mut reply = plist::Dictionary::new();
            reply.insert("serverInfo".into(), server.into());
            reply.into()
        }
        assert!(!super::stop_confirmed(&response(&[7, 9]), 7));
        assert!(super::stop_confirmed(&response(&[9]), 7));
        assert!(super::stop_confirmed(&response(&[]), 7));
        assert!(!super::stop_confirmed(
            &plist::Value::Dictionary(Default::default()),
            7
        ));
    }
    #[test]
    fn geometry_selects_exact_display_and_rejects_stale_or_ambiguous_data() {
        use plist::Value as V;
        fn display(id: i64, w: f64, h: f64) -> V {
            V::Dictionary(plist::Dictionary::from_iter([
                (String::from("displayId"), V::Integer(id.into())),
                (String::from("nativeOrientation"), V::String("rot0".into())),
                (String::from("currentOrientation"), V::String("rot0".into())),
                (
                    String::from("frame"),
                    V::Array(vec![
                        V::Array(vec![V::Real(0.0), V::Real(0.0)]),
                        V::Array(vec![V::Real(w), V::Real(h)]),
                    ]),
                ),
            ]))
        }
        fn root(current: bool, displays: Vec<V>) -> V {
            V::Dictionary(plist::Dictionary::from_iter([
                (String::from("current"), V::Boolean(current)),
                (String::from("displays"), V::Array(displays)),
            ]))
        }
        let phone = display(1, 1179.0, 2556.0);
        assert_eq!(
            super::display_geometry(
                &root(true, vec![display(3, 1184.0, 2560.0), phone.clone()]),
                1
            ),
            Some(DisplayGeometry {
                width: 1179,
                height: 2556,
                native_rotation: 0,
                rotation: 0
            })
        );
        assert_eq!(
            super::display_geometry(&root(true, vec![display(1, 2556.0, 1179.0)]), 1),
            Some(DisplayGeometry {
                width: 2556,
                height: 1179,
                native_rotation: 0,
                rotation: 0
            })
        );
        for value in [
            root(false, vec![phone.clone()]),
            root(true, vec![phone.clone(), phone]),
            root(true, vec![display(3, 1184.0, 2560.0)]),
            root(true, vec![display(1, 1179.5, 2556.0)]),
            root(true, vec![display(1, 0.0, 0.0)]),
        ] {
            assert_eq!(super::display_geometry(&value, 1), None);
        }
    }

    use super::*;
    #[test]
    fn media_admission_keeps_authenticated_identity_without_assuming_source_port() {
        let expected = idevice::core_device::display_stream::negotiation::ScreenVideoStream {
            payload_type: 100,
            ssrc: 7,
        };
        let mut p = vec![0x80, 100, 255, 255, 0, 0, 0, 0, 0, 0, 0, 7, 1];
        assert!(parse_video_packet(&p, expected).is_some());
        // Reorder/duplicates belong to the AU assembler, not a separate sequence filter.
        p[2] = 0;
        p[3] = 0;
        assert!(parse_video_packet(&p, expected).is_some());
        p[11] = 8;
        assert!(parse_video_packet(&p, expected).is_none());
        p[11] = 7;
        p[1] = 101;
        assert!(parse_video_packet(&p, expected).is_none());
        assert!(parse_video_packet(&[0; 11], expected).is_none());
        assert!(parse_video_packet(&build_liveness(7, "test", &[]), expected).is_none());
    }
    #[test]
    fn synthetic_rtp_reaches_complete_hevc_handoff_and_frame_ack() {
        // Same synthetic green 64x96 sample decoded by the Swift/VideoToolbox tests.
        let mut bytes = vec![0x80, 0x80 | 100, 0, 1, 0, 0, 0, 2, 0, 0, 0, 7];
        bytes.extend_from_slice(&[
            96, 1, 0, 24, 64, 1, 12, 1, 255, 255, 1, 96, 0, 0, 3, 0, 144, 0, 0, 3, 0, 0, 3, 0, 30,
            149, 152, 9, 0, 41, 66, 1, 1, 1, 96, 0, 0, 3, 0, 144, 0, 0, 3, 0, 0, 3, 0, 30, 160, 32,
            129, 133, 150, 86, 105, 36, 202, 240, 22, 128, 128, 0, 0, 3, 0, 128, 0, 0, 3, 0, 132,
            0, 7, 68, 1, 193, 114, 180, 34, 64, 0, 22, 40, 1, 175, 19, 128, 229, 50, 81, 255, 218,
            40, 255, 167, 213, 254, 128, 107, 64, 8, 35, 29, 135,
        ]);
        let stream = idevice::core_device::display_stream::negotiation::ScreenVideoStream {
            payload_type: 100,
            ssrc: 7,
        };
        let packet = parse_video_packet(&bytes, stream).unwrap();
        let mut assembler = HevcAccessUnitAssembler::new(100, 7);
        let mailbox = crate::video::VideoMailbox::default();
        mailbox.begin_stream();
        mailbox.received_from(49152); // Dynamic inbound source port must be admitted.
        let mut feedback = VideoFeedback::new(11, 7, "synthetic".into());
        assert_eq!(
            feedback.observe_packet(&packet),
            Some(build_frame_ack(11, 2))
        );
        for event in assembler.push_packet(&packet) {
            if let HevcDepacketizerEvent::AccessUnit(unit) = event {
                assert!(mailbox.push(unit, assembler.parameter_sets().unwrap()));
            }
        }
        assert!(assembler.is_complete());
        mailbox.sender_report(feedback.unique_packets == 1 && assembler.is_complete());
        assert_eq!(mailbox.snapshot().serial, 1);
        // A missing FU fragment invalidates an otherwise complete picture.
        let partial = RtpPacket {
            sequence_number: 3,
            timestamp: 3,
            marker: true,
            ..packet.clone()
        };
        assembler.push_packet(&partial);
        assert!(!assembler.is_complete());
        mailbox.sender_report(assembler.is_complete());
        assert_eq!(mailbox.snapshot().serial, 0);
        assert_eq!(mailbox.poll(0).0, 14);
        let (_, size, _) = mailbox.poll(0);
        let (_, _, data) = mailbox.poll(size);
        let data = data.expect("complete HEVC access unit reaches App handoff");
        assert_eq!(u32::from_le_bytes(data[40..44].try_into().unwrap()), 64);
        assert_eq!(u32::from_le_bytes(data[44..48].try_into().unwrap()), 96);
        assert_eq!(feedback.packets, 1);
    }
    #[test]
    fn receiver_feedback_tracks_real_frames_wraparound_and_compound_refresh() {
        let mut f = VideoFeedback::new(11, 22, "public-fixture".into());
        assert!(f.control_report().is_none());
        let raw = |seq: u16, ts: u32, marker: bool| {
            let mut b = vec![0x80, 100 | if marker { 0x80 } else { 0 }];
            b.extend_from_slice(&seq.to_be_bytes());
            b.extend_from_slice(&ts.to_be_bytes());
            b.extend_from_slice(&22u32.to_be_bytes());
            b.extend_from_slice(&[2, 1, 0x80]);
            b
        };
        let a = raw(65535, 1000, false);
        let b = raw(0, 1234, true);
        assert!(
            f.observe_packet(&RtpPacket::parse_checked(&a).unwrap())
                .is_none()
        );
        assert_eq!(
            f.observe_packet(&RtpPacket::parse_checked(&b).unwrap()),
            Some(build_frame_ack(11, 1234))
        );
        assert!(
            f.observe_packet(&RtpPacket::parse_checked(&a).unwrap())
                .is_none()
        );
        assert_eq!(f.sequence.highest - f.sequence.base.unwrap(), 1);
        assert_eq!(
            f.control_report().unwrap(),
            build_rctl(11, 1234, 2, 3, RECEIVER_BANDWIDTH_KBPS)
        );
        // Sequence loss must not stop sender receipt pacing while awaiting IDR.
        let c = raw(50, 2000, true);
        assert_eq!(
            f.observe_packet(&RtpPacket::parse_checked(&c).unwrap()),
            Some(build_frame_ack(11, 2000))
        );
        let rr = f.liveness_report();
        assert_eq!(
            rr[0] & 31,
            1,
            "One receiver-report block must be sent even during IDR recovery"
        );
        assert_eq!(&rr[8..12], &22u32.to_be_bytes());
        assert_eq!(
            &rr[16..20],
            &65586u32.to_be_bytes(),
            "Extended sequence includes the initial base and wrap"
        );
        assert!(
            rr[12] > 0,
            "Loss is reported to the sender rather than assumed zero"
        );
        let request = f.keyframe_request();
        assert_eq!(request, build_pli(11, 22));
        assert_eq!(
            f.unique_packets, 3,
            "Duplicates must not satisfy a sender progress barrier"
        );
    }
    #[test]
    fn lost_geometry_refresh_repeats_pli_until_a_sync_picture_is_accepted() {
        use idevice::core_device::display_stream::hevc::{HevcAccessUnit, HevcParameterSets};
        let mailbox = crate::video::VideoMailbox::default();
        mailbox.begin_stream();
        let geometry = DisplayGeometry {
            width: 10,
            height: 20,
            native_rotation: 0,
            rotation: 0,
        };
        mailbox.set_display_geometry(Some(geometry));
        mailbox.poll(0);
        let push = |sync| {
            mailbox.push(
                HevcAccessUnit {
                    ssrc: 22,
                    rtp_timestamp: 1,
                    first_sequence_number: 1,
                    last_sequence_number: 1,
                    parameter_set_revision: 1,
                    is_sync: sync,
                    bytes: vec![0, 0, 0, 2, 2, 1],
                },
                HevcParameterSets {
                    revision: 1,
                    pixel_width: 10,
                    pixel_height: 20,
                    video_parameter_set: vec![1],
                    sequence_parameter_set: vec![2],
                    picture_parameter_set: vec![3],
                },
            )
        };
        let mut reports = VideoFeedback::new(11, 22, "public-sync-recovery".into());
        let pli = build_pli(11, 22);
        assert!(push(true));
        // Consume the initial explicit refresh and ignore the generated packet.
        reports.recovery_report(&mailbox, false);
        assert!(!reports.recovery_report(&mailbox, false).ends_with(&pli));
        mailbox.set_display_geometry(Some(DisplayGeometry {
            rotation: 180,
            ..geometry
        }));
        let first = reports.recovery_report(&mailbox, false);
        assert_eq!(first[1], 201, "Recovery must retain Receiver Reports");
        assert!(first.ends_with(&pli)); // Simulate a lost PLI / absent IDR.
        assert!(
            !mailbox.take_refresh(),
            "The one-shot geometry request is consumed"
        );
        assert!(
            reports.recovery_report(&mailbox, false).ends_with(&pli),
            "An asynchronous geometry reset also needs recovery without another RTP frame"
        );
        for _ in 0..3 {
            // Production's local needs_sync becomes false for this push(true).
            assert!(push(false));
            let repeated = reports.recovery_report(&mailbox, false);
            assert_eq!(repeated[1], 201);
            assert!(repeated.ends_with(&pli));
            assert_eq!(mailbox.decode_cursor().serial, 0);
        }
        assert!(push(true));
        for _ in 0..3 {
            assert!(push(false));
            let recovered = reports.recovery_report(&mailbox, false);
            assert_eq!(recovered[1], 201);
            assert!(
                !recovered.ends_with(&pli),
                "A valid sync picture must end periodic PLI recovery"
            );
        }
        assert_eq!(mailbox.status().refreshes, 6);
    }
    fn geometry_probe_fixture() -> (crate::video::VideoMailbox, DisplayGeometry) {
        use idevice::core_device::display_stream::hevc::{HevcAccessUnit, HevcParameterSets};
        let mailbox = crate::video::VideoMailbox::default();
        mailbox.begin_stream();
        let geometry = DisplayGeometry {
            width: 10,
            height: 20,
            native_rotation: 0,
            rotation: 0,
        };
        mailbox.set_display_geometry(Some(geometry));
        assert!(mailbox.push(
            HevcAccessUnit {
                ssrc: 22,
                rtp_timestamp: 1,
                first_sequence_number: 1,
                last_sequence_number: 1,
                parameter_set_revision: 1,
                is_sync: true,
                bytes: vec![0, 0, 0, 2, 2, 1],
            },
            HevcParameterSets {
                revision: 1,
                pixel_width: 10,
                pixel_height: 20,
                video_parameter_set: vec![1],
                sequence_parameter_set: vec![2],
                picture_parameter_set: vec![3],
            }
        ));
        (mailbox, geometry)
    }
    #[tokio::test]
    async fn same_fresh_geometry_keeps_the_observed_epoch() {
        let (mailbox, geometry) = geometry_probe_fixture();
        let before = mailbox.decode_cursor();
        assert!(
            super::verify_current_geometry(&mailbox, async { Ok(geometry) })
                .await
                .unwrap()
        );
        assert_eq!(mailbox.decode_cursor(), before);
    }
    #[tokio::test]
    async fn fresh_rotation_refuses_cached_geometry_without_publishing_or_restoring_the_old_grant()
    {
        let (mailbox, geometry) = geometry_probe_fixture();
        let before = mailbox.decode_cursor();
        let rotated = DisplayGeometry {
            rotation: 180,
            ..geometry
        };
        assert!(
            !super::verify_current_geometry(&mailbox, async { Ok(rotated) })
                .await
                .unwrap()
        );
        let rejected = mailbox.decode_cursor();
        assert_ne!(rejected.epoch, before.epoch);
        assert_eq!(rejected.serial, 0);
        // A buffered notification of the old layout cannot recover this grant.
        mailbox.set_display_geometry(Some(geometry));
        assert_eq!(mailbox.decode_cursor(), rejected);
        assert!(!mailbox.verify_display_geometry(before.epoch, geometry));
        // A second fresh check cannot promote the RPC's newer layout either.
        assert!(!mailbox.verify_display_geometry(rejected.epoch, rotated));
        assert_eq!(mailbox.decode_cursor().serial, 0);
    }
    #[tokio::test]
    async fn notification_during_fresh_geometry_rpc_refuses_the_older_epoch_without_overwriting_it()
    {
        let (mailbox, geometry) = geometry_probe_fixture();
        let before = mailbox.decode_cursor();
        let rotated = DisplayGeometry {
            rotation: 180,
            ..geometry
        };
        assert!(
            !super::verify_current_geometry(&mailbox, async {
                mailbox.set_display_geometry(Some(rotated));
                Ok(geometry) // The earlier RPC reply arrives after the newer push.
            })
            .await
            .unwrap()
        );
        let current = mailbox.decode_cursor();
        assert_ne!(current.epoch, before.epoch);
        assert!(!mailbox.verify_display_geometry(before.epoch, geometry));
        assert_eq!(
            mailbox.decode_cursor(),
            current,
            "An old reply cannot overwrite or invalidate the newer push."
        );
    }
    #[tokio::test]
    async fn failed_fresh_geometry_rpc_revokes_previous_authority() {
        let (mailbox, _) = geometry_probe_fixture();
        let before = mailbox.decode_cursor();
        let failure = super::error(super::Stage::VideoService, super::Cause::Timeout);
        assert_eq!(
            super::verify_current_geometry(&mailbox, async { Err(failure) }).await,
            Err(failure)
        );
        assert_ne!(mailbox.decode_cursor().epoch, before.epoch);
        assert_eq!(mailbox.decode_cursor().serial, 0);
    }
    #[test]
    fn reordered_marker_is_received_and_acknowledged_without_false_loss() {
        let mut feedback = VideoFeedback::new(11, 22, "reorder".into());
        for (seq, marker) in [(10u16, false), (12, false), (11, true)] {
            let mut bytes = vec![0x80, 100 | if marker { 0x80 } else { 0 }];
            bytes.extend_from_slice(&seq.to_be_bytes());
            bytes.extend_from_slice(&1234u32.to_be_bytes());
            bytes.extend_from_slice(&22u32.to_be_bytes());
            bytes.extend_from_slice(&[2, 1, 0x80]);
            let ack = feedback.observe_packet(&RtpPacket::parse_checked(&bytes).unwrap());
            assert_eq!(ack, marker.then(|| build_frame_ack(11, 1234)));
        }
        let report = feedback.liveness_report();
        assert_eq!(
            &report[12..16],
            &[0, 0, 0, 0],
            "Reordering must not report packet loss"
        );
        assert_eq!(&report[16..20], &12u32.to_be_bytes());
        assert_eq!(
            feedback.control_report().unwrap(),
            build_rctl(11, 1234, 3, 3, RECEIVER_BANDWIDTH_KBPS)
        );
    }
    #[test]
    fn feedback_uses_authenticated_dynamic_port_and_both_ssrc_roles() {
        let mut cfg = plist::Dictionary::new();
        cfg.insert("SourcePort".into(), plist::Value::Integer(53134u64.into()));
        cfg.insert("LocalSSRC".into(), plist::Value::Integer(22u64.into()));
        cfg.insert("RemoteSSRC".into(), plist::Value::Integer(11u64.into()));
        let mut connection = plist::Dictionary::new();
        connection.insert("streamConfig".into(), plist::Value::Dictionary(cfg.clone()));
        let mut answer = plist::Dictionary::new();
        answer.insert("connection".into(), plist::Value::Dictionary(connection));
        assert_eq!(
            feedback_endpoint(&plist::Value::Dictionary(answer), 22),
            Some((53134, 22, 11))
        );
        cfg.insert("SourcePort".into(), plist::Value::Integer(65536u64.into()));
        assert_eq!(
            feedback_endpoint(&plist::Value::Dictionary(cfg.clone()), 22),
            None
        );
        cfg.insert("SourcePort".into(), plist::Value::Integer(0u64.into()));
        assert_eq!(feedback_endpoint(&plist::Value::Dictionary(cfg), 22), None);
    }
    #[test]
    fn answer_must_be_unique_bounded_data() {
        let mut d = plist::Dictionary::new();
        d.insert("negotiatorAnswer".into(), plist::Value::Data(vec![1]));
        let one = plist::Value::Dictionary(d);
        assert_eq!(extract_answer(&one).unwrap(), &[1]);
        assert!(extract_answer(&plist::Value::Array(vec![one.clone(), one])).is_err());
        assert!(extract_answer(&plist::Value::Data(vec![])).is_err());
    }
    #[tokio::test]
    async fn dropping_drains_aborts_consumers() {
        let task = tokio::spawn(std::future::pending::<()>());
        let handle = task.abort_handle();
        drop(Drains(vec![task]));
        tokio::task::yield_now().await;
        assert!(handle.is_finished());
    }
}

#[cfg(test)]
mod lifecycle_tests {
    use super::*;
    #[tokio::test]
    async fn worker_abort_revokes_media_health_and_decoder_generation() {
        let mailbox = Arc::new(VideoMailbox::default());
        let healthy = Arc::new(AtomicBool::new(true));
        let lifetime = WorkerLifetime {
            health: healthy.clone(),
            mailbox: mailbox.clone(),
        };
        let before = mailbox.decode_cursor().epoch;
        let task = tokio::spawn(async move {
            let _lifetime = lifetime;
            std::future::pending::<()>().await;
        });
        tokio::task::yield_now().await;
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        assert!(!healthy.load(Ordering::SeqCst));
        assert_ne!(mailbox.decode_cursor().epoch, before);
        assert_eq!(mailbox.poll(0).0, 14);
    }
    #[test]
    fn duplicate_packets_do_not_hide_loss_in_receiver_reports() {
        let mut feedback = VideoFeedback::new(11, 22, "fixture".into());
        for sequence_number in [10, 12, 12] {
            let mut bytes = vec![0x80, 100];
            bytes.extend((sequence_number as u16).to_be_bytes());
            bytes.extend(100u32.to_be_bytes());
            bytes.extend(22u32.to_be_bytes());
            bytes.extend([2, 1, 0x80]);
            feedback.observe_packet(&RtpPacket::parse_checked(&bytes).unwrap());
        }
        let report = feedback.liveness_report();
        assert_eq!(feedback.unique_packets, 2);
        assert_eq!(
            &report[13..16],
            &[0, 0, 1],
            "One missing packet remains visible despite a duplicate"
        );
        assert!(report[12] > 0);
    }
    #[test]
    fn drag_plan_has_one_contact_monotonic_deadlines_and_exact_endpoint() {
        for duration in [100, 101, 2000] {
            let steps = drag_schedule(65535, 0, 0, 65535, duration).unwrap();
            assert_eq!(
                steps.first(),
                Some(&(Duration::ZERO, TouchEvent::Down(TouchPoint::new(65535, 0))))
            );
            assert_eq!(
                steps.last(),
                Some(&(
                    Duration::from_millis(duration.into()),
                    TouchEvent::Up(TouchPoint::new(0, 65535))
                ))
            );
            assert_eq!(
                steps[steps.len() - 2].1,
                TouchEvent::Move(TouchPoint::new(0, 65535))
            );
            assert!(steps.windows(2).all(|pair| pair[0].0 <= pair[1].0));
            assert!(
                steps[1..steps.len() - 1]
                    .iter()
                    .all(|(_, event)| matches!(event, TouchEvent::Move(_)))
            );
        }
        for duration in [0, 99, 2001, u16::MAX] {
            assert!(drag_schedule(0, 0, 1, 1, duration).is_err());
        }
    }
    #[test]
    fn sequence_window_is_bounded_across_multiple_wraps() {
        let mut window = SequenceWindow::default();
        for n in 0..140_000u32 {
            assert!(window.receive(n as u16));
            assert!(!window.receive(n as u16));
        }
        assert_eq!(window.expected(), 140_000);
        assert_eq!(window.highest, 139_999);
        assert!(window.seen.len() <= 0x8000);
        assert!(
            !window.receive((window.highest as u16).wrapping_sub(0x8000)),
            "An ambiguous half-cycle is not a unique receipt"
        );
    }
}
