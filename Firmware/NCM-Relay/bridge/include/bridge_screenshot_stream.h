/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_SCREENSHOT_STREAM_H
#define BRIDGE_SCREENSHOT_STREAM_H
#include "bridge_core.h"
typedef struct { uint32_t image_bytes, width, height; uint64_t message_id; } bridge_png_info;
/* Extract CoreDevice.output.image from ONE complete RemoteXPC wrapper stream.
 * Input must ALREADY be demultiplexed from HTTP/2 and the authenticated tunnel.
 * Does not open services, strip HTTP/2 frames, or perform pairing.
 * Fixed caller scratch (>=32 bytes); image is streamed, not retained.
 * Validates wrapper/container lengths and PNG signature/IHDR dimensions only,
 * NOT PNG chunk CRCs or decompression. Sink output is provisional: discard it on
 * any non-OK return, including failures AFTER image bytes were emitted.
 * imageFormat is optional; if present it must equal png. Caller must correlate
 * info.message_id before committing output. On failure close/reset transport;
 * this extractor cannot resynchronize.
 * Deadline applies throughout. Callback must itself be bounded/nonblocking.
 */
bridge_status bridge_xpc_extract_png(bridge_io *, uint32_t max_wrapper_bytes,
    uint8_t *scratch, size_t scratch_size, bridge_sink_fn, void *sink_context,
    uint64_t deadline_ms, bridge_png_info *info);
#endif
