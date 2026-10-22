// SPDX-License-Identifier: GPL-3.0-only
//! Eiscue's in-memory decoder handoff. The wire structs and retained regression
//! fixtures preserve compatibility with the previous backend; the queue and
//! reference-chain implementation below is maintained by Eiscue.
use idevice::core_device::display_stream::hevc::{HevcAccessUnit, HevcParameterSets};
use std::{
    collections::VecDeque,
    sync::{
        Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Instant,
};

const MAX_BYTES: usize = 8 * 1024 * 1024;
const MAX_FRAMES: usize = 64;
const HEADER_BYTES: usize = 64;
const SAMPLE_EVENT: u32 = 13;
const RESET_EVENT: u32 = 14;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct DisplayGeometry {
    pub width: u32,
    pub height: u32,
    pub native_rotation: u16,
    pub rotation: u16,
}
#[repr(C)]
#[derive(Default, Copy, Clone, Debug)]
pub struct VideoStatus {
    pub datagrams: u64,
    pub rtp: u64,
    pub rejected: u64,
    pub frames: u64,
    pub discontinuities: u64,
    pub overflows: u64,
    pub refreshes: u64,
    pub source_port: u64,
}
#[repr(C)]
#[derive(Default, Copy, Clone, Debug)]
pub struct VideoSnapshot {
    pub report: u64,
    pub epoch: u64,
    pub serial: u64,
}
#[repr(C)]
#[derive(Default, Copy, Clone, Debug, PartialEq, Eq)]
pub struct VideoDecodeCursor {
    pub epoch: u64,
    pub serial: u64,
}

struct QueuedPicture {
    wire: Vec<u8>,
    arrived: Instant,
}
#[derive(Default)]
struct DecoderQueue {
    pictures: VecDeque<QueuedPicture>,
    occupied: usize,
    generation: u64,
    sequence: u64,
    configuration: Option<u64>,
    reference_ready: bool,
    reset_pending: bool,
    display: Option<DisplayGeometry>,
    confirmation: VideoSnapshot,
}
impl DecoderQueue {
    fn discard_pictures(&mut self) {
        self.pictures.clear();
        self.occupied = 0;
    }
    fn revoke(&mut self) {
        self.discard_pictures();
        self.generation = self.generation.wrapping_add(1);
        self.reference_ready = false;
        self.configuration = None;
        self.reset_pending = true;
        self.confirmation.serial = 0;
        self.confirmation.epoch = self.generation;
    }
    fn cursor(&self) -> VideoDecodeCursor {
        VideoDecodeCursor {
            epoch: self.generation,
            // DisplayInfo tracks layout transitions independently of the
            // encoded canvas. A missing optional crop may be supplied by the
            // picture's validated HEVC trailer in the Swift decoder.
            serial: if self.reference_ready && self.display.is_some() {
                self.sequence
            } else {
                0
            },
        }
    }
}
#[derive(Default)]
pub(crate) struct VideoMailbox {
    queue: Mutex<DecoderQueue>,
    refresh: AtomicBool,
    counters: [AtomicU64; 8],
}

/// Visible dimensions belong to this picture only. Encoder padding is bounded
/// independently on each axis; mismatched metadata cannot authorize coordinates.
fn visible_dimensions(
    display: Option<DisplayGeometry>,
    p: &HevcParameterSets,
) -> Option<(u32, u32)> {
    let display = display?;
    let padding_x = p.pixel_width.checked_sub(display.width)?;
    let padding_y = p.pixel_height.checked_sub(display.height)?;
    (display.width > 0 && display.height > 0 && padding_x < 64 && padding_y < 64)
        .then_some((display.width, display.height))
}
fn picture_size(unit: &HevcAccessUnit, params: &HevcParameterSets, visible: bool) -> Option<usize> {
    [
        unit.bytes.len(),
        params.video_parameter_set.len(),
        params.sequence_parameter_set.len(),
        params.picture_parameter_set.len(),
        if visible { 8 } else { 0 },
    ]
    .into_iter()
    .try_fold(HEADER_BYTES, usize::checked_add)
}
fn encode_picture(
    unit: HevcAccessUnit,
    params: HevcParameterSets,
    visible: Option<(u32, u32)>,
    sequence: u64,
    generation: u64,
    size: usize,
) -> QueuedPicture {
    let mut wire = Vec::with_capacity(size);
    // ABI: serial / generation / age-ms / SPS revision, then eight u32 fields.
    for n in [sequence, generation, 0, params.revision] {
        wire.extend(n.to_le_bytes());
    }
    for n in [
        unit.rtp_timestamp,
        u32::from(unit.is_sync) | (u32::from(visible.is_some()) << 1),
        params.pixel_width,
        params.pixel_height,
        params.video_parameter_set.len() as u32,
        params.sequence_parameter_set.len() as u32,
        params.picture_parameter_set.len() as u32,
        unit.bytes.len() as u32,
    ] {
        wire.extend(n.to_le_bytes());
    }
    if let Some((width, height)) = visible {
        wire.extend(width.to_le_bytes());
        wire.extend(height.to_le_bytes());
    }
    wire.extend(params.video_parameter_set);
    wire.extend(params.sequence_parameter_set);
    wire.extend(params.picture_parameter_set);
    wire.extend(unit.bytes);
    QueuedPicture {
        wire,
        arrived: Instant::now(),
    }
}

impl VideoMailbox {
    pub fn snapshot(&self) -> VideoSnapshot {
        self.queue
            .lock()
            .map(|state| state.confirmation)
            .unwrap_or_default()
    }
    pub fn decode_cursor(&self) -> VideoDecodeCursor {
        self.queue
            .lock()
            .map(|state| state.cursor())
            .unwrap_or_default()
    }
    pub fn packet_pending(&self) {
        if let Ok(mut state) = self.queue.lock() {
            state.confirmation.serial = 0;
        }
    }
    pub fn sender_report(&self, complete: bool) {
        if let Ok(mut state) = self.queue.lock() {
            state.confirmation = VideoSnapshot {
                report: state.confirmation.report.wrapping_add(1),
                epoch: state.generation,
                serial: if complete && state.reference_ready {
                    state.sequence
                } else {
                    0
                },
            };
        }
    }
    pub fn begin_stream(&self) {
        for counter in &self.counters {
            counter.store(0, Ordering::Relaxed);
        }
        self.refresh.store(false, Ordering::SeqCst);
        if let Ok(mut state) = self.queue.lock() {
            state.display = None;
            state.revoke();
        }
    }
    pub fn reset(&self) {
        if let Ok(mut state) = self.queue.lock() {
            state.revoke();
        }
    }
    pub fn set_display_geometry(&self, geometry: Option<DisplayGeometry>) {
        if let Ok(mut state) = self.queue.lock() {
            if state.display == geometry {
                return;
            }
            state.display = geometry;
            state.revoke();
            self.request_refresh();
        }
    }
    #[cfg(test)]
    fn set_visible_size(&self, size: Option<(u32, u32)>) {
        self.set_display_geometry(size.map(|(width, height)| DisplayGeometry {
            width,
            height,
            native_rotation: 0,
            rotation: 0,
        }));
    }
    /// A solicited read may invalidate a generation, but only the ordered
    /// subscription may replace its geometry. Late replies have no authority.
    pub fn verify_display_geometry(&self, epoch: u64, fresh: DisplayGeometry) -> bool {
        let Ok(mut state) = self.queue.lock() else {
            return false;
        };
        if epoch != state.generation {
            return false;
        }
        if state.display == Some(fresh) {
            return state.cursor().serial != 0;
        }
        state.revoke();
        self.request_refresh();
        false
    }
    pub fn needs_sync(&self) -> bool {
        self.queue
            .lock()
            .map(|state| !state.reference_ready)
            .unwrap_or(true)
    }
    pub fn request_refresh(&self) {
        self.refresh.store(true, Ordering::SeqCst);
    }
    pub fn take_refresh(&self) -> bool {
        self.refresh.swap(false, Ordering::SeqCst)
    }
    pub fn count(&self, index: usize) {
        self.counters[index].fetch_add(1, Ordering::Relaxed);
    }
    pub fn received_from(&self, port: u16) {
        self.count(0);
        self.counters[7].store(port.into(), Ordering::Relaxed);
    }
    pub fn status(&self) -> VideoStatus {
        let [
            datagrams,
            rtp,
            rejected,
            frames,
            discontinuities,
            overflows,
            refreshes,
            source_port,
        ] = self
            .counters
            .each_ref()
            .map(|counter| counter.load(Ordering::Relaxed));
        VideoStatus {
            datagrams,
            rtp,
            rejected,
            frames,
            discontinuities,
            overflows,
            refreshes,
            source_port,
        }
    }
    pub fn push(&self, unit: HevcAccessUnit, params: HevcParameterSets) -> bool {
        let Ok(mut state) = self.queue.lock() else {
            return false;
        };
        if state
            .configuration
            .is_some_and(|revision| revision != params.revision)
        {
            state.revoke();
        }
        state.configuration = Some(params.revision);
        if !unit.is_sync && !state.reference_ready {
            return true;
        }
        // A new independent picture supersedes all queued dependencies. This is
        // the only lossless way to catch up without decoding every older frame.
        if unit.is_sync {
            state.discard_pictures();
        }
        let visible = visible_dimensions(state.display, &params);
        let size = picture_size(&unit, &params, visible.is_some());
        let fits = size.is_some_and(|size| size <= MAX_BYTES && state.occupied <= MAX_BYTES - size)
            && state.pictures.len() < MAX_FRAMES;
        if !fits {
            state.revoke();
            self.count(5);
            self.request_refresh();
            return false;
        }
        state.sequence = state.sequence.wrapping_add(1).max(1);
        let picture = encode_picture(
            unit,
            params,
            visible,
            state.sequence,
            state.generation,
            size.unwrap(),
        );
        state.reference_ready = true;
        state.confirmation.serial = 0;
        state.occupied += picture.wire.len();
        state.pictures.push_back(picture);
        true
    }
    /// A too-small output buffer leaves the entire picture available for retry.
    /// A generation reset is always published before any picture in that epoch.
    pub fn poll(&self, capacity: usize) -> (u32, usize, Option<Vec<u8>>) {
        let Ok(mut state) = self.queue.lock() else {
            return (0, 0, None);
        };
        if std::mem::take(&mut state.reset_pending) {
            return (RESET_EVENT, 0, Some(Vec::new()));
        }
        let Some(front) = state.pictures.front() else {
            return (0, 0, None);
        };
        let size = front.wire.len();
        if capacity < size {
            return (SAMPLE_EVENT, size, None);
        }
        let mut picture = state
            .pictures
            .pop_front()
            .expect("front checked under lock");
        state.occupied -= size;
        let age = picture.arrived.elapsed().as_millis().min(u64::MAX as u128) as u64;
        picture.wire[16..24].copy_from_slice(&age.to_le_bytes());
        (SAMPLE_EVENT, size, Some(picture.wire))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn sample(sync: bool) -> (HevcAccessUnit, HevcParameterSets) {
        (
            HevcAccessUnit {
                ssrc: 1,
                rtp_timestamp: 2,
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
    }
    #[test]
    fn snapshot_requires_sender_progress_and_valid_complete_epoch() {
        let q = VideoMailbox::default();
        q.begin_stream();
        q.poll(0);
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        assert_eq!(q.snapshot().serial, 0, "No sender confirmation yet");
        q.sender_report(false);
        assert_eq!(
            q.snapshot().serial,
            0,
            "Unreceived/partial packets cannot confirm a picture"
        );
        q.sender_report(true);
        let confirmed = q.snapshot();
        assert_eq!(confirmed.serial, 1);
        assert_eq!(confirmed.report, 2);
        q.sender_report(true);
        assert_eq!(
            q.snapshot().serial,
            1,
            "Idle screen keeps the same valid picture"
        );
        assert!(
            q.snapshot().report > confirmed.report,
            "Fresh peer progress without a new frame"
        );
        q.packet_pending();
        assert_eq!(
            q.snapshot().serial,
            0,
            "New unassembled data invalidates the old confirmation"
        );
        q.reset();
        q.sender_report(true);
        assert_eq!(q.snapshot().serial, 0);
        assert_ne!(q.snapshot().epoch, confirmed.epoch);
    }
    #[test]
    fn input_geometry_cursor_does_not_require_an_idle_sender_report() {
        let q = VideoMailbox::default();
        q.begin_stream();
        q.poll(0);
        q.set_visible_size(Some((10, 20)));
        assert_eq!(q.decode_cursor().serial, 0);
        for _ in 0..100 {
            q.packet_pending();
            let (u, p) = sample(true);
            assert!(q.push(u, p));
            let cursor = q.decode_cursor();
            assert!(
                cursor.serial > 0,
                "Complete animation pictures remain available to the decoder"
            );
            q.packet_pending();
            assert_eq!(
                q.snapshot().serial,
                0,
                "An incomplete next picture cannot confirm fresh screenshot pixels"
            );
            assert_eq!(
                q.decode_cursor(),
                cursor,
                "Receiving new pixels alone must not invalidate input geometry"
            );
            q.sender_report(false);
            assert_eq!(q.decode_cursor(), cursor);
        }
        let old = q.decode_cursor();
        q.reset();
        assert_eq!(q.decode_cursor().serial, 0);
        assert_ne!(q.decode_cursor().epoch, old.epoch);
    }
    #[test]
    fn input_geometry_cursor_advances_before_queued_layout_is_decoded() {
        let q = VideoMailbox::default();
        q.begin_stream();
        q.poll(0);
        q.set_visible_size(Some((10, 20)));
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        let old = q.decode_cursor();
        let (u, p) = sample(false);
        assert!(q.push(u, p));
        assert_eq!(q.decode_cursor().epoch, old.epoch);
        assert!(
            q.decode_cursor().serial > old.serial,
            "Do not validate a decoder behind queued pictures"
        );
        let (u, mut p) = sample(true);
        p.revision = 2;
        assert!(q.push(u, p));
        assert_ne!(
            q.decode_cursor().epoch,
            old.epoch,
            "A configuration change revokes old geometry before polling"
        );
    }
    #[test]
    fn display_metadata_revokes_geometry_before_new_pixels_and_when_rotating_back() {
        let q = VideoMailbox::default();
        q.begin_stream();
        q.poll(0);
        q.set_visible_size(Some((9, 18)));
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        let old = q.decode_cursor();
        q.set_visible_size(Some((9, 18)));
        assert_eq!(q.decode_cursor(), old);
        q.set_visible_size(Some((18, 9)));
        assert_eq!(q.decode_cursor().serial, 0);
        assert_ne!(q.decode_cursor().epoch, old.epoch);
        assert_eq!(q.poll(0).0, 14);
        assert!(q.take_refresh());
        q.set_visible_size(Some((9, 18)));
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        assert_ne!(
            q.decode_cursor().epoch,
            old.epoch,
            "Returning to old dimensions must not revive an observation"
        );
    }
    #[test]
    fn same_size_rotation_and_return_revoke_old_input_without_pixel_changes() {
        let q = VideoMailbox::default();
        q.begin_stream();
        let geometry = DisplayGeometry {
            width: 10,
            height: 20,
            native_rotation: 0,
            rotation: 0,
        };
        q.set_display_geometry(Some(geometry));
        q.poll(0);
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        let original = q.decode_cursor();
        q.set_display_geometry(Some(DisplayGeometry {
            rotation: 180,
            ..geometry
        }));
        assert_eq!(q.decode_cursor().serial, 0);
        assert_ne!(q.decode_cursor().epoch, original.epoch);
        let rotated_epoch = q.decode_cursor().epoch;
        q.set_display_geometry(Some(geometry));
        assert_ne!(
            q.decode_cursor().epoch,
            rotated_epoch,
            "Even A→B→A before new pixels cannot revive A"
        );
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        assert_ne!(q.decode_cursor().epoch, original.epoch);
        q.set_display_geometry(None);
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        assert_eq!(
            q.decode_cursor().serial,
            0,
            "Lost direction metadata must not authorize coordinates"
        );
    }
    #[test]
    fn geometry_reset_keeps_sync_demand_while_inter_frames_are_discarded() {
        let q = VideoMailbox::default();
        q.begin_stream();
        let geometry = DisplayGeometry {
            width: 10,
            height: 20,
            native_rotation: 0,
            rotation: 0,
        };
        q.set_display_geometry(Some(geometry));
        q.poll(0);
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        assert!(!q.needs_sync());
        let previous = q.decode_cursor();
        q.poll(1024);
        q.set_display_geometry(Some(DisplayGeometry {
            rotation: 180,
            ..geometry
        }));
        assert!(q.take_refresh());
        assert!(
            !q.take_refresh(),
            "A one-shot refresh is not the reference-chain state"
        );
        assert_eq!(q.poll(0).0, 14);
        for _ in 0..100 {
            let (u, p) = sample(false);
            assert!(q.push(u, p));
            assert!(
                q.needs_sync(),
                "An accepted but discarded P-frame cannot end keyframe recovery"
            );
            assert_eq!(q.decode_cursor().serial, 0);
            assert_eq!(q.poll(1024).0, 0);
        }
        assert_eq!(q.status().overflows, 0);
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        assert!(!q.needs_sync());
        assert_ne!(q.decode_cursor().epoch, previous.epoch);
        assert!(q.decode_cursor().serial > previous.serial);
        assert_eq!(q.poll(1024).0, 13);
    }
    #[test]
    fn display_geometry_is_snapshotted_and_checked_against_each_picture() {
        let q = VideoMailbox::default();
        q.begin_stream();
        q.poll(0);
        q.set_visible_size(Some((9, 18)));
        assert_eq!(q.poll(0).0, 14);
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        let (_, size, data) = q.poll(1024);
        let data = data.unwrap();
        assert_eq!(size, 81);
        assert_eq!(data[36], 3);
        assert_eq!(u32::from_le_bytes(data[64..68].try_into().unwrap()), 9);
        assert_eq!(u32::from_le_bytes(data[68..72].try_into().unwrap()), 18);
        q.set_visible_size(Some((18, 9))); // orientation changed before the next picture
        assert_eq!(
            q.poll(0).0,
            14,
            "Revoke the previously decoded coordinate space immediately"
        );
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        let (_, size, data) = q.poll(1024);
        assert_eq!(size, 73);
        assert_eq!(
            data.unwrap()[36],
            1,
            "Wrong orientation must never crop the picture"
        );
        q.begin_stream();
        q.set_visible_size(None);
        q.poll(0);
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        assert_eq!(q.poll(1024).2.unwrap()[36], 1);
    }
    #[test]
    fn slow_consumer_keeps_latest_independent_picture_without_overflow_or_reset() {
        let q = VideoMailbox::default();
        q.begin_stream();
        assert_eq!(q.poll(0).0, 14);
        for timestamp in 0..1000 {
            let (mut u, p) = sample(true);
            u.rtp_timestamp = timestamp;
            assert!(q.push(u, p));
            for _ in 0..10 {
                let (u, p) = sample(false);
                assert!(q.push(u, p));
            }
        }
        assert_eq!(q.status().overflows, 0);
        assert_eq!(q.poll(0).0, 13);
        assert_eq!(q.poll(0).1, 73);
        let (_, size, data) = q.poll(73);
        assert_eq!(size, 73);
        let data = data.unwrap();
        assert_eq!(u32::from_le_bytes(data[32..36].try_into().unwrap()), 999);
        assert_eq!(u64::from_le_bytes(data[0..8].try_into().unwrap()), 10990);
        for _ in 0..10 {
            assert_eq!(q.poll(100).0, 13);
        }
        assert_eq!(q.poll(100).0, 0);
    }
    #[test]
    fn inter_frames_preserve_order_and_overflow_discards_the_reference_chain() {
        let q = VideoMailbox::default();
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        for _ in 1..MAX_FRAMES {
            let (u, p) = sample(false);
            assert!(q.push(u, p));
        }
        let (u, p) = sample(false);
        assert!(!q.push(u, p));
        assert_eq!(q.status().overflows, 1);
        assert_eq!(q.poll(100).0, 14);
        let (u, p) = sample(false);
        assert!(q.push(u, p));
        assert_eq!(q.poll(100).0, 0);
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        let (u, p) = sample(false);
        assert!(q.push(u, p));
        let a = q.poll(100).2.unwrap();
        let b = q.poll(100).2.unwrap();
        assert_eq!(u32::from_le_bytes(a[36..40].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(b[36..40].try_into().unwrap()), 0);
        assert!(
            u64::from_le_bytes(b[0..8].try_into().unwrap())
                > u64::from_le_bytes(a[0..8].try_into().unwrap())
        );
    }
    #[test]
    fn oversized_picture_is_bounded_and_requires_a_new_independent_picture() {
        let q = VideoMailbox::default();
        let (mut u, p) = sample(true);
        u.bytes.resize(MAX_BYTES + 1, 0);
        assert!(!q.push(u, p));
        assert_eq!(q.status().overflows, 1);
        assert_eq!(q.poll(0).0, 14);
        let (u, p) = sample(false);
        assert!(q.push(u, p));
        assert_eq!(q.poll(0).0, 0);
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        assert_eq!(q.poll(0).0, 13);
    }
    #[test]
    fn configuration_change_without_a_sync_picture_invalidates_previous_pixels() {
        let q = VideoMailbox::default();
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        let (_, size, _) = q.poll(0);
        assert!(q.poll(size).2.is_some());
        let (u, mut p) = sample(false);
        p.revision = 2;
        assert!(q.push(u, p));
        assert_eq!(
            q.poll(0).0,
            14,
            "Invalidate decoded pixels even if Rust slot was consumed"
        );
        assert_eq!(
            q.poll(0).0,
            0,
            "Never hand an inter picture to an independent decoder"
        );
        let (u, mut p) = sample(true);
        p.revision = 2;
        assert!(q.push(u, p));
        assert_eq!(q.poll(0).0, 13);
    }
    #[test]
    fn receiver_status_survives_frame_resets_but_not_a_new_stream() {
        let q = VideoMailbox::default();
        q.begin_stream();
        q.received_from(49152);
        q.count(1);
        q.count(6);
        let s = q.status();
        assert_eq!(s.datagrams, 1);
        assert_eq!(s.rtp, 1);
        assert_eq!(s.source_port, 49152);
        q.reset();
        assert_eq!(q.status().refreshes, 1);
        q.begin_stream();
        assert_eq!(q.status().datagrams, 0);
        assert_eq!(q.status().refreshes, 0);
    }
    #[test]
    fn reset_drops_old_images_before_new_generation() {
        let q = VideoMailbox::default();
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        q.reset();
        assert_eq!(q.poll(100).0, 14);
        assert_eq!(q.poll(100).0, 0);
        let (u, p) = sample(false);
        assert!(q.push(u, p));
        assert_eq!(q.poll(100).0, 0);
    }
}

#[cfg(test)]
mod handoff_tests {
    use super::*;
    fn picture() -> (HevcAccessUnit, HevcParameterSets) {
        (
            HevcAccessUnit {
                ssrc: 1,
                rtp_timestamp: 1,
                first_sequence_number: 1,
                last_sequence_number: 1,
                parameter_set_revision: 1,
                is_sync: true,
                bytes: vec![0, 0, 0, 2, 2, 1],
            },
            HevcParameterSets {
                revision: 1,
                pixel_width: 100,
                pixel_height: 200,
                video_parameter_set: vec![1],
                sequence_parameter_set: vec![2],
                picture_parameter_set: vec![3],
            },
        )
    }
    #[test]
    fn optional_crop_mismatch_keeps_synchronized_geometry_cursor() {
        let mailbox = VideoMailbox::default();
        let display = DisplayGeometry {
            width: 200,
            height: 100,
            native_rotation: 0,
            rotation: 90,
        };
        mailbox.set_display_geometry(Some(display));
        assert_eq!(mailbox.poll(0).0, RESET_EVENT);
        let (unit, params) = picture();
        assert_eq!(visible_dimensions(Some(display), &params), None);
        assert!(mailbox.push(unit, params));
        let synchronized = mailbox.decode_cursor();
        assert!(synchronized.serial > 0);
        assert!(mailbox.verify_display_geometry(synchronized.epoch, display));
        let (_, size, _) = mailbox.poll(0);
        let wire = mailbox.poll(size).2.unwrap();
        let flags = u32::from_le_bytes(wire[36..40].try_into().unwrap());
        assert_eq!(flags & 2, 0, "Do not publish an invalid optional crop");

        mailbox.set_display_geometry(None);
        assert_ne!(mailbox.decode_cursor().epoch, synchronized.epoch);
        let (unit, params) = picture();
        assert!(mailbox.push(unit, params));
        assert_eq!(
            mailbox.decode_cursor().serial,
            0,
            "Display metadata is still required"
        );

        mailbox.set_display_geometry(Some(display));
        assert_eq!(
            mailbox.decode_cursor().serial,
            0,
            "A changed epoch requires fresh sync"
        );
        let (mut unit, params) = picture();
        unit.is_sync = false;
        assert!(mailbox.push(unit, params));
        assert_eq!(mailbox.decode_cursor().serial, 0);
        let (unit, params) = picture();
        assert!(mailbox.push(unit, params));
        let current = mailbox.decode_cursor();
        assert!(current.serial > 0);
        assert!(!mailbox.verify_display_geometry(synchronized.epoch, display));
        assert!(mailbox.verify_display_geometry(current.epoch, display));
    }
    #[test]
    fn assembled_picture_requires_new_sender_confirmation_and_capacity_retry_is_lossless() {
        let mailbox = VideoMailbox::default();
        let (unit, params) = picture();
        mailbox.push(unit, params);
        mailbox.sender_report(true);
        assert!(mailbox.snapshot().serial > 0);
        let (unit, params) = picture();
        mailbox.push(unit, params);
        assert_eq!(
            mailbox.snapshot().serial,
            0,
            "An older report cannot confirm a newer picture"
        );
        let (_, size, _) = mailbox.poll(0);
        assert!(mailbox.poll(size - 1).2.is_none());
        let data = mailbox.poll(size).2.unwrap();
        assert_eq!(u64::from_le_bytes(data[..8].try_into().unwrap()), 2);
        assert_eq!(mailbox.poll(size).0, 0);
    }
}
