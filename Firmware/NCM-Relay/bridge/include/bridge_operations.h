/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_OPERATIONS_H
#define BRIDGE_OPERATIONS_H
#include "bridge_rsd.h"
#include "bridge_requests.h"
#include "bridge_screenshot_stream.h"

#define BRIDGE_OPERATIONS_SCRATCH_MIN 2048u
#define BRIDGE_OPERATIONS_MAX_IMAGE_WRAPPER (16u * 1024u * 1024u)
/* Stream to a caller-controlled sink; all emitted bytes are provisional until
 * BRIDGE_OK and a completed correlated wrapper. No image-sized allocation.
 * invocation UUID strings are fresh per-operation, supplied by caller; the
 * wrapper message_id field is ignored and assigned by the live session.
 * Requires a READY RSD. Opens/closes only the screenshot service. */
bridge_status bridge_capture_screenshot(bridge_rsd *, const bridge_invocation *,
    const char *display_unique_id, uint8_t *scratch, size_t scratch_capacity,
    uint32_t max_wrapper_size, bridge_sink_fn sink, void *sink_context,
    uint64_t deadline_ms, bridge_png_info *out);

typedef bridge_status (*bridge_operation_wait_fn)(void *, uint32_t milliseconds,
    uint64_t deadline_ms);
typedef struct {
    bool down_written, down_peer_acked, up_written, bytes_peer_acked;
    /* Transport evidence only. No UIKit/device-effect acknowledgment exists. */
} bridge_home_result;
/* Sends/ACK-drains Indigo Home DOWN, waits at least 50 ms while caller pumps its
 * scheduler, then UP. Requires dialer.drain before any input is sent. Drain must
 * wait for peer TCP acknowledgments, not merely an empty local write queue.
 * Each send/request uses the same absolute deadline. Failed release or drain is
 * explicitly reported by flags; no success/recovery is inferred from EOF.
 * The only button exposed here is Home. No keyboard/text or auto-started touch
 * session: safe per-session media teardown still needs verified stream tokens.
 */
bridge_status bridge_press_home(bridge_rsd *, bridge_operation_wait_fn,
    void *wait_context, uint8_t *scratch, size_t scratch_capacity,
    uint64_t deadline_ms, bridge_home_result *out);
#endif
