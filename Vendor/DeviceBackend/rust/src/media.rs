// SPDX-License-Identifier: GPL-3.0-only
//! Authenticated DisplayService video negotiation and discard-only consumer.
//! Complete HEVC units are handed to the owning App decoder; no media is persisted.
use crate::{Cause, Error, Stage, Stream, bounded, bounded_for, error, video::DisplayGeometry};
use idevice::{
    RsdService,
    core_device::{
        DisplayServiceClient, TouchEvent, TouchPoint, UniversalHidServiceClient,
        display_stream::{
            RtpPacket, ReportBlock, SenderReport, build_frame_ack, build_pli, build_liveness, build_rctl,
            build_start_video_parameters,
            hevc::{HevcAccessUnitAssembler, HevcDepacketizerEvent},
            is_rtcp,
            negotiation::{CallInfoBlob, build_screen_video_offer_with_bitrate, parse_screen_video_answer},
        },
    },
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle,
};
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::task::JoinHandle;
// Requested sender port is an offer only; feedback uses the returned SourcePort.
const REQUESTED_VIDEO_PORT: u16 = 50001;
// S3 relay budget, not an iOS limit. Live 6 Mbps produced sender ENOBUFS;
// 2 Mbps RCTL feedback made the peer target ~1.7 Mbps without steady-state loss.
const RECEIVER_BANDWIDTH_KBPS: u16 = 2000;
// Display identity and geometry are queried from the authenticated peer.
struct DisplayInfoClient(idevice::core_device::CoreDeviceServiceClient<Stream>);
impl RsdService for DisplayInfoClient {
    fn rsd_service_name() -> std::borrow::Cow<'static, str> {
        "com.apple.coredevice.deviceinfo".into()
    }
    async fn from_stream(stream: Stream) -> Result<Self, idevice::IdeviceError> {
        Ok(Self(
            idevice::core_device::CoreDeviceServiceClient::new(stream).await?,
        ))
    }
}
async fn subscribe_display_geometry(info: &mut DisplayInfoClient, id: i64) -> Result<DisplayGeometry, idevice::IdeviceError> {
    info.0.begin_stream_with_plist(
        "com.apple.coredevice.feature.displayinfoupdates", plist::Dictionary::new(),
        Some("com.apple.coredevice.action.displayinfoupdates"),
    ).await?;
    loop {
        let rows = info.0.next_stream_batch().await?
            .ok_or(idevice::core_device::CoreDeviceError::MalformedField("display stream finished"))?;
        if rows.is_empty() { continue; }
        let mut current = None;
        for row in rows {
            current = Some(display_geometry(&row, id)
                .ok_or(idevice::core_device::CoreDeviceError::MalformedField("display geometry"))?);
        }
        return current.ok_or(idevice::core_device::CoreDeviceError::MalformedField("display geometry").into());
    }
}
async fn verify_current_geometry(
    mailbox: &crate::video::VideoMailbox,
    fresh: impl std::future::Future<Output = Result<DisplayGeometry, Error>>,
) -> Result<bool, Error> {
    let before = mailbox.decode_cursor();
    if before.serial == 0 { return Ok(false); }
    match fresh.await {
        Ok(geometry) => Ok(mailbox.verify_display_geometry(before.epoch, geometry)),
        Err(error) => { mailbox.reset(); Err(error) }
    }
}
fn display_geometry(value: &plist::Value, id: i64) -> Option<DisplayGeometry> {
    let root = value.as_dictionary()?;
    if !root.get("current")?.as_boolean()? {
        return None;
    }
    let displays = root.get("displays")?.as_array()?;
    let mut matches = displays
        .iter()
        .filter_map(|v| v.as_dictionary())
        .filter(|d| d.get("displayId").and_then(plist::Value::as_signed_integer) == Some(id));
    let display = matches.next()?;
    if matches.next().is_some() {
        return None;
    }
    let frame = display.get("frame")?.as_array()?;
    if frame.len() != 2 {
        return None;
    }
    let origin = frame[0].as_array()?;
    let size = frame[1].as_array()?;
    if origin.len() != 2 || size.len() != 2 {
        return None;
    }
    fn number(v: &plist::Value) -> Option<f64> {
        v.as_real()
            .or_else(|| v.as_signed_integer().map(|n| n as f64))
    }
    if number(&origin[0])? != 0.0 || number(&origin[1])? != 0.0 {
        return None;
    }
    let w = number(&size[0])?;
    let h = number(&size[1])?;
    if !w.is_finite()
        || !h.is_finite()
        || w.fract() != 0.0
        || h.fract() != 0.0
        || !(1.0..=16384.0).contains(&w)
        || !(1.0..=16384.0).contains(&h)
    {
        return None;
    }
    fn rotation(value: &plist::Value) -> Option<u16> {
        match value.as_string()? {
            "rot0" => Some(0), "rot90" => Some(90), "rot180" => Some(180), "rot270" => Some(270),
            _ => None,
        }
    }
    Some(DisplayGeometry {
        width: w as u32, height: h as u32,
        native_rotation: rotation(display.get("nativeOrientation")?)?,
        rotation: rotation(display.get("currentOrientation")?)?,
    })
}
#[derive(Default)]
struct Drains(Vec<JoinHandle<()>>);
impl Drop for Drains {
    fn drop(&mut self) {
        for task in &self.0 {
            task.abort();
        }
    }
}
pub(crate) struct Media {
    _video: DisplayServiceClient<Stream>,
    hid: UniversalHidServiceClient<Stream>,
    _drains: Drains,
    healthy: Arc<AtomicBool>,
    diagnostic_identity: crate::media_diagnostic::Identity,
}
#[derive(Default, Debug, Eq, PartialEq)]
pub(crate) enum ReleaseState {
    #[default]
    Idle,
    Unknown,
    Owned(u32),
}
impl ReleaseState {
    pub fn is_idle(&self) -> bool { matches!(self, Self::Idle) }

    fn claim(&mut self, identifier: u32) -> Result<(), Error> {
        match self {
            Self::Unknown if identifier != 0 => { *self = Self::Owned(identifier); Ok(()) }
            Self::Owned(owned) if *owned == identifier => Ok(()),
            _ => Err(error(Stage::VideoAnswer, Cause::Protocol)),
        }
    }

    async fn stop_with<F, Fut>(&mut self, stop: F) -> Result<(), Error>
    where F: FnOnce(u32) -> Fut, Fut: std::future::Future<Output = Result<plist::Value, Error>> {
        let identifier = match self {
            Self::Idle => return Ok(()),
            Self::Unknown => return Err(error(Stage::Media, Cause::DeliveryUncertain)),
            Self::Owned(identifier) => *identifier,
        };
        let reply = stop(identifier).await?;
        if !stop_confirmed(&reply, identifier) { return Err(error(Stage::Media, Cause::Protocol)); }
        *self = Self::Idle;
        Ok(())
    }

    pub async fn stop(&mut self, adapter: &mut AdapterHandle, handshake: &mut RsdHandshake) -> Result<(), Error> {
        self.stop_with(|identifier| async move {
            // Dropping local sockets does not release the peer's assertion.
            // The scoped stop must use a fresh reply-bearing connection.
            let mut stop = bounded(Stage::Media, DisplayServiceClient::connect_rsd(adapter, handshake)).await?;
            bounded(Stage::Media, stop.stop_media_stream_identifiers(&[identifier])).await
        }).await
    }
}

async fn start_reply(
    release: &mut ReleaseState,
    start: impl std::future::Future<Output = Result<plist::Value, Error>>,
) -> Result<(plist::Value, idevice::core_device::display_stream::negotiation::ScreenVideoStream), Error> {
    // Cancellation or a missing reply cannot prove that the peer never started.
    *release = ReleaseState::Unknown;
    let answer = start.await?;
    if let Some(identifier) = owned_start_identifier(&answer) { release.claim(identifier)?; }
    let negotiated = parse_screen_video_answer(extract_answer(&answer)?)
        .map_err(|_| error(Stage::VideoAnswer, Cause::Protocol))?;
    Ok((answer, negotiated))
}

fn owned_start_identifier(answer: &plist::Value) -> Option<u32> {
    // Only this start response's connection proves ownership before parsing the
    // answer. serverInfo may list unrelated controllers and is never evidence.
    answer.as_dictionary()?.get("connection")?.as_dictionary()?
        .get("streamConfig")?.as_dictionary()?.get("RemoteSSRC")?.as_unsigned_integer()
        .and_then(|id| u32::try_from(id).ok()).filter(|id| *id != 0)
}

impl Media {
    pub async fn status_diagnostic(
        &self, adapter: &mut AdapterHandle, handshake: &mut RsdHandshake,
    ) -> Result<Vec<u8>, Error> {
        crate::media_diagnostic::query(&self.diagnostic_identity, &self.healthy, async {
            // A timeout drops only this temporary client, preserving _video.
            let mut client = DisplayServiceClient::connect_rsd(adapter, handshake).await
                .map_err(|_| error(Stage::VideoService, Cause::Protocol))?;
            client.get_media_stream_server_status().await
                .map_err(|_| error(Stage::Media, Cause::Protocol))
        }).await
    }
    /// Correlated read-only roundtrip before reusing input geometry. This uses
    /// a separate short-lived client, never the notification stream's channel.
    pub async fn verify_geometry(
        &self, adapter: &mut AdapterHandle, handshake: &mut RsdHandshake,
        mailbox: &crate::video::VideoMailbox,
    ) -> Result<bool, Error> {
        if !self.healthy.load(Ordering::SeqCst) { return Ok(false); }
        let confirmed = verify_current_geometry(mailbox, bounded_for(Stage::VideoService, Duration::from_secs(2), async {
            let mut info = DisplayInfoClient::connect_rsd(adapter, handshake).await?;
            let value = info.0.current_display_info().await?;
            display_geometry(&value, 1)
                .ok_or_else(|| idevice::IdeviceError::from(idevice::core_device::CoreDeviceError::MalformedField("display geometry")))
        })).await?;
        Ok(confirmed && self.healthy.load(Ordering::SeqCst))
    }
    pub async fn start(
        adapter: &mut AdapterHandle,
        handshake: &mut RsdHandshake,
        mailbox: Arc<crate::video::VideoMailbox>,
        release: &mut ReleaseState,
    ) -> Result<Self, Error> {
        let fail = || error(Stage::VideoAnswer, Cause::Protocol);
        let mut drains = Drains::default();
        let healthy = Arc::new(AtomicBool::new(true));
        let video_udp = bounded(Stage::VideoReceiver, adapter.bind_udp(0)).await?;
        let receiver = adapter.host_ip().to_string();
        let sender = adapter.peer_ip().to_string();
        // Compatibility profile captured in Device Hub's protocol source, not
        // evidence of iOS27 compatibility or the actual controller model/OS.
        let info = CallInfoBlob {
            call_id: 0,
            client_version: 1,
            device_type: "Mac17,7".into(),
            framework_version: "2205.3.1".into(),
            os_version: "25F71".into(),
            device_name: None,
            audio_device_uid: None,
        };
        let session = uuid::Uuid::new_v4();
        let ssrc =
            u32::from_be_bytes(uuid::Uuid::new_v4().as_bytes()[..4].try_into().unwrap()).max(1);
        let call = uuid::Uuid::new_v4();
        let call_id = call.to_string().to_uppercase();
        let offer = build_screen_video_offer_with_bitrate(&call_id, &info, ssrc, u32::from(RECEIVER_BANDWIDTH_KBPS) * 1000).map_err(|_| fail())?;
        // Retain the video session until close; audio is not needed for touch.
        let mut video = bounded(
            Stage::VideoService,
            DisplayServiceClient::connect_rsd(adapter, handshake),
        )
        .await?;
        const DISPLAY_ID: i64 = 1;
        let mut display_info = bounded(
            Stage::VideoService, DisplayInfoClient::connect_rsd(adapter, handshake),
        ).await?;
        let initial_geometry = bounded(Stage::VideoService,
            subscribe_display_geometry(&mut display_info, DISPLAY_ID)).await?;
        let (answer, negotiated) = start_reply(release, Box::pin(bounded(
            Stage::VideoNegotiation,
            video.start_media_stream(build_start_video_parameters(
                &receiver,
                video_udp.local_port(),
                &sender,
                REQUESTED_VIDEO_PORT,
                offer,
                140,
                DISPLAY_ID,
                session,
            )),
        ))).await?;
        let config = match feedback_endpoint(&answer, negotiated.ssrc) {
            Some(config) => config,
            None => {
                let status = bounded(Stage::VideoAnswer, video.get_media_stream_server_status()).await?;
                feedback_endpoint(&status, negotiated.ssrc).ok_or_else(fail)?
            }
        };
        let (feedback_port, _, receiver_ssrc) = config;
        release.claim(receiver_ssrc)?;
        let diagnostic_identity = crate::media_diagnostic::Identity::new(
            session, call, negotiated.ssrc, receiver_ssrc,
        );
        // Refresh outside the receiver: service latency must not block RTP/ACKs.
        // Each frame carries a snapshot, validated against that frame's SPS.
        mailbox.begin_stream();
        mailbox.set_display_geometry(Some(initial_geometry));
        let geometry_mailbox = mailbox.clone();
        let geometry_health = healthy.clone();
        drains.0.push(tokio::spawn(async move {
            // Consume every peer update, including A→B→A between video frames.
            // Physical pose and image dimensions are not interface direction.
            while let Ok(Some(rows)) = display_info.0.next_stream_batch().await {
                for row in rows {
                    let geometry = display_geometry(&row, DISPLAY_ID);
                    geometry_mailbox.set_display_geometry(geometry);
                    if geometry.is_none() { geometry_health.store(false, Ordering::SeqCst); return; }
                }
            }
            geometry_mailbox.set_display_geometry(None);
            geometry_health.store(false, Ordering::SeqCst);
        }));
        let video_health = healthy.clone();
        drains.0.push(tokio::spawn(async move {
            let mut assembler = HevcAccessUnitAssembler::new(negotiated.payload_type, negotiated.ssrc);
            let mut needs_sync = true;
            let mut reports = VideoFeedback::new(receiver_ssrc, negotiated.ssrc, call_id);
            let mut control_tick = tokio::time::interval(Duration::from_millis(50));
            control_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            let mut feedback = tokio::time::interval(Duration::from_secs(1));
            feedback.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                tokio::select! {
                    packet=video_udp.recv()=>match packet {
                        Ok(p)=> {
                            mailbox.received_from(p.source_port);
                            // The adapter already binds the authenticated peer IP and local port.
                            // senderPort is our feedback destination, not a constraint on inbound source ports.
                            if is_rtcp(&p.data) {
                                if let Some(sr) = SenderReport::parse_first(&p.data) {
                                    if sr.ssrc == negotiated.ssrc {
                                        reports.sender_report = Some((sr.ntp_middle, tokio::time::Instant::now()));
                                        mailbox.sender_report(sr.packet_count == reports.unique_packets && assembler.is_complete());
                                    }
                                }
                                continue;
                            }
                            let Some(packet) = parse_video_packet(&p.data, negotiated) else { mailbox.count(2); continue; };
                            mailbox.packet_pending();
                            mailbox.count(1);
                            if let Some(ack) = reports.observe_packet(&packet) {
                                if video_udp.send_to(feedback_port, ack).await.is_err() { video_health.store(false, Ordering::SeqCst); return; }
                            }
                            for event in assembler.push_packet(&packet) {
                                match event {
                                    HevcDepacketizerEvent::AccessUnit(unit) => {
                                        mailbox.count(3);
                                        if let Some(params) = assembler.parameter_sets() {
                                            if mailbox.push(unit, params) { needs_sync = false; }
                                            else { assembler.mark_stream_discontinuity(); needs_sync = true; }
                                        }
                                    },
                                    HevcDepacketizerEvent::Discontinuity(_) => {
                                        mailbox.count(4); mailbox.reset(); needs_sync = true;
                                    },
                                    HevcDepacketizerEvent::PacketRejected(_) => { mailbox.count(2); },
                                }
                            }
                        },
                        Err(_)=>break,
                    },
                    _=control_tick.tick()=> {
                        if let Some(report) = reports.control_report() {
                            if video_udp.send_to(feedback_port,report).await.is_err() { break; }
                        }
                    },
                    _=feedback.tick()=> {
                        let report = reports.recovery_report(&mailbox, needs_sync);
                        if video_udp.send_to(feedback_port,report).await.is_err() { break; }
                    }
                }
            }
            mailbox.reset();
            video_health.store(false, Ordering::SeqCst);
        }));
        // A successful reply-bearing video session, not arrival of RTP frames,
        // is the prerequisite used by the verified touch_session reference.
        // Idle/static screens and receiver filtering must not block HID reports.
        // Reference touch_session allows HID surfaces time to become authenticated.
        tokio::time::sleep(Duration::from_millis(350)).await;
        let hid = bounded(
            Stage::TouchService,
            UniversalHidServiceClient::connect_rsd(adapter, handshake),
        )
        .await?;
        Ok(Self {
            _video: video,
            hid,
            _drains: drains,
            healthy,
            diagnostic_identity,
        })
    }
    pub async fn drag(
        &mut self,
        x: u16,
        y: u16,
        end_x: u16,
        end_y: u16,
        duration: u16,
    ) -> Result<(), Error> {
        if !(100..=2000).contains(&duration) {
            return Err(error(Stage::Input, Cause::InvalidParameters));
        }
        if !self.healthy.load(Ordering::SeqCst) {
            return Err(error(Stage::Input, Cause::MediaInactive));
        }
        let uncertain = || error(Stage::Input, Cause::DeliveryUncertain);
        bounded(
            Stage::Input,
            self.hid
                .send_touch(TouchEvent::Down(TouchPoint::new(x, y)), None),
        )
        .await
        .map_err(|_| uncertain())?;
        let start = tokio::time::Instant::now();
        let steps = u32::from(duration).div_ceil(20);
        for i in 1..=steps {
            tokio::time::sleep_until(
                start
                    + Duration::from_millis(u64::from(duration) * u64::from(i) / u64::from(steps)),
            )
            .await;
            let interpolate = |a: u16, b: u16| {
                (i64::from(a) + (i64::from(b) - i64::from(a)) * i64::from(i) / i64::from(steps))
                    as u16
            };
            let point = TouchPoint::new(interpolate(x, end_x), interpolate(y, end_y));
            bounded(
                Stage::Input,
                self.hid.send_touch(TouchEvent::Move(point), None),
            )
            .await
            .map_err(|_| uncertain())?;
        }
        bounded(
            Stage::Input,
            self.hid
                .send_touch(TouchEvent::Up(TouchPoint::new(end_x, end_y)), None),
        )
        .await
        .map_err(|_| uncertain())
    }
    pub async fn tap(&mut self, x: u16, y: u16) -> Result<(), Error> {
        if !self.healthy.load(Ordering::SeqCst) {
            return Err(error(Stage::Input, Cause::MediaInactive));
        }
        let point = TouchPoint::new(x, y);
        if bounded(
            Stage::Input,
            self.hid.send_touch(TouchEvent::Down(point), None),
        )
        .await
        .is_err()
        {
            // An incomplete write may still have reached the device. Do not
            // replay Down or claim cancellation succeeded; close the generation.
            return Err(error(Stage::Input, Cause::DeliveryUncertain));
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
        bounded(
            Stage::Input,
            self.hid.send_touch(TouchEvent::Up(point), None),
        )
        .await
        .map_err(|_| error(Stage::Input, Cause::DeliveryUncertain))
    }
}

fn stop_confirmed(reply: &plist::Value, identifier: u32) -> bool {
    let Some(sessions) = reply.as_dictionary()
        .and_then(|d| d.get("serverInfo")).and_then(plist::Value::as_dictionary)
        .and_then(|d| d.get("sessions")).and_then(plist::Value::as_array) else { return false };
    sessions.iter().all(|session| {
        session.as_dictionary().and_then(|d| d.get("connection")).and_then(plist::Value::as_dictionary)
            .and_then(|d| d.get("streamConfig")).and_then(plist::Value::as_dictionary)
            .and_then(|d| d.get("RemoteSSRC")).and_then(plist::Value::as_unsigned_integer)
            .and_then(|id| u32::try_from(id).ok()).is_some_and(|id| id != identifier)
    })
}
/// Admission is bound to the authenticated answer, not an assumed UDP source port.
fn parse_video_packet(
    data: &[u8],
    expected: idevice::core_device::display_stream::negotiation::ScreenVideoStream,
) -> Option<RtpPacket<'_>> {
    if is_rtcp(data) {
        return None;
    }
    let p = RtpPacket::parse_checked(data).ok()?;
    (p.ssrc == expected.ssrc && p.payload_type == expected.payload_type && !p.payload.is_empty())
        .then_some(p)
}
struct VideoFeedback {
    our_ssrc: u32,
    media_ssrc: u32,
    cname: String,
    base: Option<u16>,
    highest: u32,
    timestamp: u32,
    packets: u32,
    unique_packets: u32,
    seen: std::collections::HashSet<u32>,
    current_frame_packets: u32,
    last_frame_packets: u32,
    previous_expected: u32,
    previous_received: u32,
    sender_report: Option<(u32,tokio::time::Instant)>,
}
impl VideoFeedback {
    fn new(our_ssrc: u32, media_ssrc: u32, cname: String) -> Self {
        Self {
            our_ssrc,
            media_ssrc,
            cname,
            base: None,
            highest: 0,
            unique_packets: 0, seen: std::collections::HashSet::new(),
            timestamp: 0, packets: 0, current_frame_packets: 0, last_frame_packets: 0,
            previous_expected: 0, previous_received: 0, sender_report: None,
        }
    }
    fn observe_sequence(&mut self, sequence: u16) {
        let Some(base) = self.base else {
            self.base = Some(sequence);
            return;
        };
        let current = base.wrapping_add(self.highest as u16);
        let delta = sequence.wrapping_sub(current);
        if delta != 0 && delta < 0x8000 {
            self.highest = self.highest.wrapping_add(u32::from(delta));
        }
    }
    fn observe_packet(&mut self, packet: &RtpPacket<'_>) -> Option<Vec<u8>> {
        // Receipt counts and the highest sequence serve different purposes.
        // A reordered packet is still received, even if it cannot advance highest.
        self.observe_sequence(packet.sequence_number);
        let highest = u32::from(self.base.unwrap()).wrapping_add(self.highest);
        let behind = (highest as u16).wrapping_sub(packet.sequence_number);
        if behind < 0x8000 && self.seen.insert(highest.wrapping_sub(u32::from(behind))) {
            self.unique_packets = self.unique_packets.wrapping_add(1);
            if self.seen.len() > 0x9000 { self.seen.retain(|seq| highest.wrapping_sub(*seq) < 0x8000); }
        }
        if self.packets == 0 || packet.timestamp.wrapping_sub(self.timestamp) < 0x80000000 {
            self.timestamp = packet.timestamp;
        }
        self.packets = self.packets.wrapping_add(1);
        self.current_frame_packets = self.current_frame_packets.saturating_add(1);
        if !packet.marker { return None; }
        self.last_frame_packets = std::mem::take(&mut self.current_frame_packets);
        // Receipt pacing must continue even if an AU was discarded after loss.
        Some(build_frame_ack(self.our_ssrc, packet.timestamp))
    }
    fn control_report(&self) -> Option<Vec<u8>> {
        self.base?;
        Some(build_rctl(self.our_ssrc, self.timestamp, self.last_frame_packets, self.packets, RECEIVER_BANDWIDTH_KBPS))
    }
    fn liveness_report(&mut self) -> Vec<u8> {
        let expected = self.base.map(|_| self.highest.saturating_add(1)).unwrap_or(0);
        let interval_expected = expected.saturating_sub(self.previous_expected);
        let interval_received = self.packets.saturating_sub(self.previous_received);
        let loss = interval_expected.saturating_sub(interval_received);
        let fraction = if interval_expected == 0 { 0 } else { ((u64::from(loss)*256/u64::from(interval_expected)).min(255)) as u8 };
        self.previous_expected = expected; self.previous_received = self.packets;
        let (lsr,dlsr) = self.sender_report.map(|(lsr,at)| (lsr,(at.elapsed().as_secs_f64()*65536.0).min(u32::MAX as f64) as u32)).unwrap_or((0,0));
        build_liveness(self.our_ssrc, &self.cname, &[ReportBlock {
            source_ssrc: self.media_ssrc, fraction_lost: fraction,
            cumulative_lost: expected.saturating_sub(self.packets).min(0x7fffff),
            highest_seq: self.base.map(|base| u32::from(base).wrapping_add(self.highest)).unwrap_or(0),
            jitter: 0, lsr, dlsr,
        }])
    }
    fn keyframe_request(&mut self) -> Vec<u8> {
        // PLI and FIR reached the same iOS encoder hook; sending both together
        // generated "Request key frame too soon, discard" for the duplicate.
        build_pli(self.our_ssrc, self.media_ssrc)
    }
    fn recovery_report(&mut self, mailbox: &crate::video::VideoMailbox, needs_sync: bool) -> Vec<u8> {
        let refresh = mailbox.take_refresh();
        // RR liveness continues during recovery. Geometry changes run outside
        // the RTP loop, and push(true) can mean a discarded inter frame, so the
        // mailbox's actual reference chain must also gate every 1 Hz PLI.
        let mut report = self.liveness_report();
        if needs_sync || mailbox.needs_sync() || refresh {
            mailbox.count(6);
            report.extend_from_slice(&self.keyframe_request());
        }
        report
    }

}
/// Authenticated stream configuration, never infer RTCP destination from the offer.
fn feedback_endpoint(value: &plist::Value, expected_sender: u32) -> Option<(u16,u32,u32)> {
    fn number(d: &plist::Dictionary, key: &str) -> Option<u64> { d.get(key)?.as_unsigned_integer() }
    fn visit(v: &plist::Value, depth: usize, expected_sender: u32, found: &mut Vec<Option<(u16,u32,u32)>>) {
        if depth > 5 { return; }
        if let Some(d) = v.as_dictionary() {
            if number(d,"LocalSSRC") == Some(u64::from(expected_sender)) {
                let endpoint = || {
                    let port = u16::try_from(number(d,"SourcePort")?).ok()?;
                    let receiver = u32::try_from(number(d,"RemoteSSRC")?).ok()?;
                    (port != 0 && expected_sender != 0 && receiver != 0).then_some((port,expected_sender,receiver))
                };
                found.push(endpoint());
            }
            for child in d.values() { visit(child,depth+1,expected_sender,found); }
        } else if let Some(values) = v.as_array() {
            for child in values { visit(child,depth+1,expected_sender,found); }
        }
    }
    let mut found=Vec::new(); visit(value,0,expected_sender,&mut found);
    if found.len()==1 { found[0] } else { None }
}
fn extract_answer(value: &plist::Value) -> Result<&[u8], Error> {
    fn visit<'a>(
        v: &'a plist::Value,
        depth: usize,
        count: &mut usize,
        answer: &mut Option<&'a [u8]>,
    ) {
        if depth > 4 {
            return;
        }
        match v {
            plist::Value::Dictionary(d) => {
                for (k, v) in d {
                    if k == "negotiatorAnswer" {
                        *count += 1;
                        *answer = v.as_data();
                    } else if k != "serverInfo" && k != "sessions" {
                        visit(v, depth + 1, count, answer);
                    }
                }
            }
            plist::Value::Array(a) => {
                for v in a {
                    visit(v, depth + 1, count, answer);
                }
            }
            _ => {}
        }
    }
    let mut count = 0;
    let mut answer = None;
    visit(value, 0, &mut count, &mut answer);
    answer
        .filter(|v| count == 1 && !v.is_empty() && v.len() <= 1024 * 1024)
        .ok_or(error(Stage::Media, Cause::Protocol))
}
#[cfg(test)]
mod tests {
    fn stream_config(sender: u32, receiver: u32) -> plist::Value {
        plist::Dictionary::from_iter([
            ("SourcePort", plist::Value::from(53134u32)),
            ("LocalSSRC", plist::Value::from(sender)),
            ("RemoteSSRC", plist::Value::from(receiver)),
        ]).into()
    }
    fn start_response(config: plist::Value) -> plist::Value {
        let connection = plist::Dictionary::from_iter([("streamConfig", config)]);
        plist::Dictionary::from_iter([
            ("connection", connection.into()),
            ("negotiatorAnswer", plist::Value::Data(vec![1])),
        ]).into()
    }
    fn stop_response(ids: &[u32]) -> plist::Value {
        let sessions = ids.iter().map(|id| start_response(stream_config(22, *id))).collect();
        let server = plist::Dictionary::from_iter([("sessions", plist::Value::Array(sessions))]);
        plist::Dictionary::from_iter([("serverInfo", plist::Value::Dictionary(server))]).into()
    }

    #[tokio::test]
    async fn malformed_owned_start_retains_scoped_cleanup_across_failed_stops() {
        let mut release = ReleaseState::default();
        let result = start_reply(&mut release, async { Ok(start_response(stream_config(22, 11))) }).await;
        assert_eq!(result.unwrap_err(), error(Stage::VideoAnswer, Cause::Protocol));
        assert_eq!(release, ReleaseState::Owned(11));
        for reply in [Err(error(Stage::Media, Cause::Timeout)), Ok(plist::Value::Dictionary(Default::default())), Ok(stop_response(&[11, 99]))] {
            assert!(release.stop_with(|id| async move { assert_eq!(id, 11); reply }).await.is_err());
            assert_eq!(release, ReleaseState::Owned(11), "No local Media object is needed to retain failed cleanup ownership");
        }
        assert_eq!(release.claim(99), Err(error(Stage::VideoAnswer, Cause::Protocol)));
        assert_eq!(release, ReleaseState::Owned(11), "A conflicting configuration cannot replace our stop token");
        release.stop_with(|id| async move { assert_eq!(id, 11); Ok(stop_response(&[99])) }).await.unwrap();
        assert!(release.is_idle());
        release.stop_with(|_| async { panic!("Confirmed release must be idempotent") }).await.unwrap();
    }

    #[tokio::test]
    async fn lost_start_reply_and_foreign_status_never_become_noop_release_success() {
        let mut release = ReleaseState::default();
        let original = error(Stage::VideoNegotiation, Cause::Timeout);
        assert_eq!(start_reply(&mut release, async { Err(original) }).await.unwrap_err(), original);
        for _ in 0..2 {
            assert_eq!(release.stop_with(|_| async { panic!("Unknown ownership must not send a stop") }).await,
                Err(error(Stage::Media, Cause::DeliveryUncertain)));
        }
        for reply in [stop_response(&[99]), start_response(stream_config(22, 0))] {
            release = ReleaseState::Idle;
            assert!(start_reply(&mut release, async { Ok(reply) }).await.is_err());
            assert_eq!(release, ReleaseState::Unknown, "Global status and zero tokens cannot establish owned media");
        }
        release = ReleaseState::Idle;
        assert!(tokio::time::timeout(Duration::from_millis(1), start_reply(&mut release, std::future::pending())).await.is_err());
        assert_eq!(release, ReleaseState::Unknown, "Cancellation after dispatch must retain uncertainty");
    }

    #[test]
    fn fallback_config_matches_only_the_owned_answer_and_rejects_ambiguity() {
        let status = plist::Value::Array(vec![stream_config(99, 77), stream_config(22, 11)]);
        assert_eq!(feedback_endpoint(&status, 22), Some((53134, 22, 11)));
        assert_eq!(feedback_endpoint(&stream_config(99, 77), 22), None);
        assert_eq!(feedback_endpoint(&plist::Value::Array(vec![stream_config(22, 11), stream_config(22, 12)]), 22), None);
        assert!(extract_answer(&stop_response(&[99])).is_err(), "A foreign session's negotiatorAnswer is not this start reply");
        let mut reply = start_response(stream_config(22, 11)).into_dictionary().unwrap();
        reply.extend(stop_response(&[99]).into_dictionary().unwrap());
        let reply = plist::Value::Dictionary(reply);
        assert_eq!(owned_start_identifier(&reply), Some(11));
        assert_eq!(extract_answer(&reply).unwrap(), &[1]);
    }

    #[test]
    fn stop_requires_peer_confirmation_and_does_not_confuse_other_streams() {
        fn response(ids: &[u32]) -> plist::Value {
            let sessions = ids.iter().map(|id| {
                let mut config = plist::Dictionary::new(); config.insert("RemoteSSRC".into(), (*id).into());
                let mut connection = plist::Dictionary::new(); connection.insert("streamConfig".into(), config.into());
                let mut session = plist::Dictionary::new(); session.insert("connection".into(), connection.into());
                session.into()
            }).collect();
            let mut server = plist::Dictionary::new(); server.insert("sessions".into(), plist::Value::Array(sessions));
            let mut reply = plist::Dictionary::new(); reply.insert("serverInfo".into(), server.into()); reply.into()
        }
        assert!(!super::stop_confirmed(&response(&[7,9]),7));
        assert!(super::stop_confirmed(&response(&[9]),7));
        assert!(super::stop_confirmed(&response(&[]),7));
        assert!(!super::stop_confirmed(&plist::Value::Dictionary(Default::default()),7));
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
            Some(DisplayGeometry { width: 1179, height: 2556, native_rotation: 0, rotation: 0 })
        );
        assert_eq!(
            super::display_geometry(&root(true, vec![display(1, 2556.0, 1179.0)]), 1),
            Some(DisplayGeometry { width: 2556, height: 1179, native_rotation: 0, rotation: 0 })
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
        assert_eq!(feedback.observe_packet(&packet), Some(build_frame_ack(11, 2)));
        for event in assembler.push_packet(&packet) {
            if let HevcDepacketizerEvent::AccessUnit(unit) = event {
                assert!(mailbox.push(unit, assembler.parameter_sets().unwrap()));
            }
        }
        assert!(assembler.is_complete());
        mailbox.sender_report(feedback.unique_packets == 1 && assembler.is_complete());
        assert_eq!(mailbox.snapshot().serial, 1);
        // A missing FU fragment invalidates an otherwise complete picture.
        let partial = RtpPacket { sequence_number: 3, timestamp: 3, marker: true, ..packet.clone() };
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
            b.extend_from_slice(&seq.to_be_bytes()); b.extend_from_slice(&ts.to_be_bytes());
            b.extend_from_slice(&22u32.to_be_bytes()); b.extend_from_slice(&[2,1,0x80]); b
        };
        let a = raw(65535, 1000, false); let b = raw(0, 1234, true);
        assert!(f.observe_packet(&RtpPacket::parse_checked(&a).unwrap()).is_none());
        assert_eq!(f.observe_packet(&RtpPacket::parse_checked(&b).unwrap()), Some(build_frame_ack(11,1234)));
        assert!(f.observe_packet(&RtpPacket::parse_checked(&a).unwrap()).is_none());
        assert_eq!(f.highest, 1);
        assert_eq!(f.control_report().unwrap(), build_rctl(11,1234,2,3, RECEIVER_BANDWIDTH_KBPS));
        // Sequence loss must not stop sender receipt pacing while awaiting IDR.
        let c = raw(50, 2000, true);
        assert_eq!(f.observe_packet(&RtpPacket::parse_checked(&c).unwrap()), Some(build_frame_ack(11,2000)));
        let rr = f.liveness_report();
        assert_eq!(rr[0] & 31,1,"One receiver-report block must be sent even during IDR recovery");
        assert_eq!(&rr[8..12],&22u32.to_be_bytes());
        assert_eq!(&rr[16..20],&65586u32.to_be_bytes(),"Extended sequence includes the initial base and wrap");
        assert!(rr[12] > 0,"Loss is reported to the sender rather than assumed zero");
        let request = f.keyframe_request();
        assert_eq!(request, build_pli(11,22));
        assert_eq!(f.unique_packets, 3, "Duplicates must not satisfy a sender progress barrier");
    }
    #[test]
    fn lost_geometry_refresh_repeats_pli_until_a_sync_picture_is_accepted() {
        use idevice::core_device::display_stream::hevc::{HevcAccessUnit, HevcParameterSets};
        let mailbox = crate::video::VideoMailbox::default(); mailbox.begin_stream();
        let geometry = DisplayGeometry { width: 10, height: 20, native_rotation: 0, rotation: 0 };
        mailbox.set_display_geometry(Some(geometry)); mailbox.poll(0);
        let push = |sync| {
            mailbox.push(HevcAccessUnit {
                ssrc: 22, rtp_timestamp: 1, first_sequence_number: 1, last_sequence_number: 1,
                parameter_set_revision: 1, is_sync: sync, bytes: vec![0, 0, 0, 2, 2, 1],
            }, HevcParameterSets {
                revision: 1, pixel_width: 10, pixel_height: 20,
                video_parameter_set: vec![1], sequence_parameter_set: vec![2], picture_parameter_set: vec![3],
            })
        };
        let mut reports = VideoFeedback::new(11, 22, "public-sync-recovery".into());
        let pli = build_pli(11, 22);
        assert!(push(true));
        // Consume the initial explicit refresh and ignore the generated packet.
        reports.recovery_report(&mailbox, false);
        assert!(!reports.recovery_report(&mailbox, false).ends_with(&pli));
        mailbox.set_display_geometry(Some(DisplayGeometry { rotation: 180, ..geometry }));
        let first = reports.recovery_report(&mailbox, false);
        assert_eq!(first[1], 201, "Recovery must retain Receiver Reports");
        assert!(first.ends_with(&pli)); // Simulate a lost PLI / absent IDR.
        assert!(!mailbox.take_refresh(), "The one-shot geometry request is consumed");
        assert!(reports.recovery_report(&mailbox, false).ends_with(&pli),
                "An asynchronous geometry reset also needs recovery without another RTP frame");
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
            assert!(!recovered.ends_with(&pli), "A valid sync picture must end periodic PLI recovery");
        }
        assert_eq!(mailbox.status().refreshes, 6);
    }
    fn geometry_probe_fixture() -> (crate::video::VideoMailbox, DisplayGeometry) {
        use idevice::core_device::display_stream::hevc::{HevcAccessUnit, HevcParameterSets};
        let mailbox = crate::video::VideoMailbox::default(); mailbox.begin_stream();
        let geometry = DisplayGeometry { width: 10, height: 20, native_rotation: 0, rotation: 0 };
        mailbox.set_display_geometry(Some(geometry));
        assert!(mailbox.push(HevcAccessUnit {
            ssrc: 22, rtp_timestamp: 1, first_sequence_number: 1, last_sequence_number: 1,
            parameter_set_revision: 1, is_sync: true, bytes: vec![0, 0, 0, 2, 2, 1],
        }, HevcParameterSets {
            revision: 1, pixel_width: 10, pixel_height: 20,
            video_parameter_set: vec![1], sequence_parameter_set: vec![2], picture_parameter_set: vec![3],
        }));
        (mailbox, geometry)
    }
    #[tokio::test]
    async fn same_fresh_geometry_keeps_the_observed_epoch() {
        let (mailbox, geometry) = geometry_probe_fixture();
        let before = mailbox.decode_cursor();
        assert!(super::verify_current_geometry(&mailbox, async { Ok(geometry) }).await.unwrap());
        assert_eq!(mailbox.decode_cursor(), before);
    }
    #[tokio::test]
    async fn fresh_rotation_refuses_cached_geometry_without_publishing_or_restoring_the_old_grant() {
        let (mailbox, geometry) = geometry_probe_fixture();
        let before = mailbox.decode_cursor();
        let rotated = DisplayGeometry { rotation: 180, ..geometry };
        assert!(!super::verify_current_geometry(&mailbox, async { Ok(rotated) }).await.unwrap());
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
    async fn notification_during_fresh_geometry_rpc_refuses_the_older_epoch_without_overwriting_it() {
        let (mailbox, geometry) = geometry_probe_fixture();
        let before = mailbox.decode_cursor();
        let rotated = DisplayGeometry { rotation: 180, ..geometry };
        assert!(!super::verify_current_geometry(&mailbox, async {
            mailbox.set_display_geometry(Some(rotated));
            Ok(geometry) // The earlier RPC reply arrives after the newer push.
        }).await.unwrap());
        let current = mailbox.decode_cursor();
        assert_ne!(current.epoch, before.epoch);
        assert!(!mailbox.verify_display_geometry(before.epoch, geometry));
        assert_eq!(mailbox.decode_cursor(), current, "An old reply cannot overwrite or invalidate the newer push.");
    }
    #[tokio::test]
    async fn failed_fresh_geometry_rpc_revokes_previous_authority() {
        let (mailbox, _) = geometry_probe_fixture();
        let before = mailbox.decode_cursor();
        let failure = super::error(super::Stage::VideoService, super::Cause::Timeout);
        assert_eq!(super::verify_current_geometry(&mailbox, async { Err(failure) }).await, Err(failure));
        assert_ne!(mailbox.decode_cursor().epoch, before.epoch);
        assert_eq!(mailbox.decode_cursor().serial, 0);
    }
    #[test]
    fn reordered_marker_is_received_and_acknowledged_without_false_loss() {
        let mut feedback = VideoFeedback::new(11,22,"reorder".into());
        for (seq,marker) in [(10u16,false),(12,false),(11,true)] {
            let mut bytes = vec![0x80,100 | if marker { 0x80 } else { 0 }];
            bytes.extend_from_slice(&seq.to_be_bytes());
            bytes.extend_from_slice(&1234u32.to_be_bytes());
            bytes.extend_from_slice(&22u32.to_be_bytes());
            bytes.extend_from_slice(&[2,1,0x80]);
            let ack = feedback.observe_packet(&RtpPacket::parse_checked(&bytes).unwrap());
            assert_eq!(ack, marker.then(|| build_frame_ack(11,1234)));
        }
        let report = feedback.liveness_report();
        assert_eq!(&report[12..16], &[0,0,0,0], "Reordering must not report packet loss");
        assert_eq!(&report[16..20], &12u32.to_be_bytes());
        assert_eq!(feedback.control_report().unwrap(), build_rctl(11,1234,3,3, RECEIVER_BANDWIDTH_KBPS));
    }
    #[test]
    fn feedback_uses_authenticated_dynamic_port_and_both_ssrc_roles() {
        let mut cfg=plist::Dictionary::new();
        cfg.insert("SourcePort".into(),plist::Value::Integer(53134u64.into()));
        cfg.insert("LocalSSRC".into(),plist::Value::Integer(22u64.into()));
        cfg.insert("RemoteSSRC".into(),plist::Value::Integer(11u64.into()));
        let mut connection=plist::Dictionary::new();
        connection.insert("streamConfig".into(),plist::Value::Dictionary(cfg.clone()));
        let mut answer=plist::Dictionary::new(); answer.insert("connection".into(),plist::Value::Dictionary(connection));
        assert_eq!(feedback_endpoint(&plist::Value::Dictionary(answer),22),Some((53134,22,11)));
        cfg.insert("SourcePort".into(),plist::Value::Integer(65536u64.into()));
        assert_eq!(feedback_endpoint(&plist::Value::Dictionary(cfg.clone()),22),None);
        cfg.insert("SourcePort".into(),plist::Value::Integer(0u64.into()));
        assert_eq!(feedback_endpoint(&plist::Value::Dictionary(cfg),22),None);
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
