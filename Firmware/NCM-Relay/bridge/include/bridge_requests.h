/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_REQUESTS_H
#define BRIDGE_REQUESTS_H
#include "bridge_xpc.h"
#include "bridge_hid.h"
#define BRIDGE_SCREENSHOT_SERVICE "com.apple.coredevice.screencaptureservice"
#define BRIDGE_DISPLAY_SERVICE "com.apple.coredevice.displayservice"
#define BRIDGE_UNIVERSAL_HID_SERVICE "com.apple.coredevice.hid.universalhidservice"
#define BRIDGE_INDIGO_SERVICE "com.apple.coredevice.hid.indigo"
typedef struct {
    /* Fresh canonical UUID strings supplied by caller; not physical-device UDID. */
    const char *device_identifier;
    const char *invocation_identifier;
    uint64_t message_id;
} bridge_invocation;
/* Serialize request only. OK means bytes encoded, never sent/accepted.
 * Caller must use RSD-discovered service ports and a properly initialized
 * authenticated RemoteXPC connection. These helpers perform no networking.
 */
bridge_status bridge_request_screenshot(const bridge_invocation *, const char *display_unique_id,
    uint8_t *out, size_t capacity, size_t *out_size);
bridge_status bridge_request_touch_report(uint64_t message_id, uint64_t service_id,
    const uint8_t report[BRIDGE_TOUCH_REPORT_SIZE], uint8_t *out, size_t capacity, size_t *out_size);
bridge_status bridge_request_home(uint64_t message_id, uint32_t state,
    uint8_t *out, size_t capacity, size_t *out_size); /* 1 down, 2 up, 3 canceled */
/* Requires a complete valid negotiator offer and an already-bound UDP endpoint
 * reachable inside the trusted tunnel. Local validation is only a bplist-signature
 * and address-character prefilter; it cannot establish those preconditions. */
bridge_status bridge_request_media_start(const bridge_invocation *, const uint8_t client_session_uuid[16],
    const char *receiver_ipv6, uint16_t receiver_port, const char *sender_ipv6,
    const uint8_t *negotiator_offer, size_t offer_size,
    uint8_t *out, size_t capacity, size_t *out_size);
/* Must be the first/only reply-bearing request on a FRESH display connection.
 * The caller must obtain its own stream token from the negotiated response.
 * No stop-all default and no assumption that EOF means successful cleanup. */
bridge_status bridge_request_media_stop(const bridge_invocation *, uint32_t own_stream_id,
    uint8_t *out, size_t capacity, size_t *out_size);
#endif
