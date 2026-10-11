/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_MEDIA_OFFER_H
#define BRIDGE_MEDIA_OFFER_H
#include "bridge_core.h"

#define BRIDGE_MEDIA_VIDEO_PROTO_MAX 384u
#define BRIDGE_MEDIA_COMPRESSED_MAX 512u
#define BRIDGE_MEDIA_VIDEO_OFFER_MAX 1024u

/* Bounded default-video serializer derived from pymobiledevice3 at
 * cd895d17ce8a97d883c10f87b26c7356d5e0ccb1, remote/core_device/media_stream_offer.py.
 * Serializer makes no heap allocations; compressor memory is caller-managed.
 * Caller supplies fresh session_id and 16-byte call UUID.
 * UUID is formatted uppercase, as upstream new_call_id(). No randomness is
 * generated here. Inputs/output/compressor buffers must not overlap.
 *
 * Deliberate upstream compatibility identity (not actual ESP32 identity):
 * model Mac15,9; OS 2205.3.1; build 25F80; decoder Viceroy 1.7.0.
 * Defaults only: video mode 5; LTRP/RTCP feedback off; FEC on; one tile;
 * AVC/HEVC feature strings FLS;SW:1;. No audio or live-session support.
 *
 * Upstream requires zlib level 9 and reports level 6 rejected by the device.
 * Production callers must supply a compatible compressor. NULL is rejected;
 * there is deliberately no fallback compressor. The firmware integration of
 * bounded level-9 zlib is provided separately by bridge_zlib_compress, using a
 * per-call allocation ceiling and PSRAM-only allocation on ESP-IDF.
 * This module neither starts a stream nor establishes HID authorization.
 */
typedef bridge_status (*bridge_media_compress_fn)(void *context,
    const uint8_t *source, size_t source_size, uint8_t *destination,
    size_t destination_capacity, size_t *destination_size);

/* Exact uncompressed default video protobuf, useful for conformance tests. */
bridge_status bridge_media_video_protobuf(uint32_t session_id,
    uint8_t *out, size_t capacity, size_t *out_size);

/* Out_size is zero on every failure; partial output must be discarded.
 * A compressor error is propagated; oversize/empty output is rejected.
 * A successful result means serialized, never accepted by an iPhone.
 */
bridge_status bridge_media_video_offer(uint32_t session_id,
    const uint8_t call_uuid[16], bridge_media_compress_fn compressor,
    void *compressor_context, uint8_t *out, size_t capacity, size_t *out_size);

#endif
