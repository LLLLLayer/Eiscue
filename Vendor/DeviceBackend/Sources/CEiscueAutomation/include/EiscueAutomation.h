// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif
enum {
    EISCUE_AUTOMATION_PREPARING = 1,
    EISCUE_AUTOMATION_READY = 2,
    EISCUE_AUTOMATION_QUERYING = 3,
    EISCUE_AUTOMATION_DELIVERING = 4,
    EISCUE_AUTOMATION_FAILED = 5,
    EISCUE_AUTOMATION_STOPPED = 6,
    EISCUE_AUTOMATION_AUTHORIZING = 7,
    EISCUE_AUTOMATION_CAPTURING = 8,
};
enum {
    EISCUE_AUTOMATION_UNSUPPORTED = 1,
    EISCUE_AUTOMATION_WRONG_THREAD = 2,
    EISCUE_AUTOMATION_EXISTING_TEST = 3,
    EISCUE_AUTOMATION_FRAMEWORK = 4,
    EISCUE_AUTOMATION_SIGNATURE = 5,
    EISCUE_AUTOMATION_CONFIGURATION = 6,
    EISCUE_AUTOMATION_RUNNER = 7,
    EISCUE_AUTOMATION_CONSENT = 8,
    EISCUE_AUTOMATION_GEOMETRY = 9,
    EISCUE_AUTOMATION_EXCEPTION = 10,
    EISCUE_AUTOMATION_DELIVERY_UNKNOWN = 11,
    EISCUE_AUTOMATION_BUSY = 12,
    EISCUE_AUTOMATION_CLOSED = 13,
};
typedef struct {
    uint32_t phase;
    uint32_t error;
    uint64_t revision;
    uint64_t display_id;
    int64_t orientation;
    double scale;
    // Point dimensions, normalized from the screen service's physical pixels.
    double bounds_width;
    double bounds_height;
    uint64_t request_id;
} eiscue_automation_state;

// All entry points require the main thread. Abort on another thread is a no-op;
// callers must schedule main-thread cleanup even when their object deinitializes.
// Owns one local runner/XPC connection. UUID must match the authenticated DTX
// session. Does not create a shared session, launch a Runner app or run a test plan.
int32_t eiscue_automation_begin(const uint8_t uuid[16], uint64_t *lease);
int32_t eiscue_automation_poll(uint64_t lease, eiscue_automation_state *state);
int32_t eiscue_automation_refresh_geometry(uint64_t lease);
// Read through the owned runner, without a second Instruments connection.
// Copy with NULL bytes to obtain the length; a successful non-NULL copy consumes
// the image. BUSY means pending. Cancel only discards this read's local result;
// late callbacks cannot publish into another request or authorize input.
int32_t eiscue_automation_screenshot(uint64_t lease, uint64_t request_id, uint64_t revision);
int32_t eiscue_automation_copy_screenshot(uint64_t lease, uint64_t request_id,
    uint8_t *bytes, size_t capacity, size_t *length);
void eiscue_automation_cancel_screenshot(uint64_t lease, uint64_t request_id);
// Points are normalized screenshot coordinates; pixel size/scale and orientation
// are checked before constructing an event. No replay or cancellation claim.
int32_t eiscue_automation_touch(uint64_t lease, uint64_t request_id,
    uint64_t revision, uint32_t pixel_width, uint32_t pixel_height,
    uint16_t x, uint16_t y, uint16_t end_x, uint16_t end_y, uint16_t duration_ms);
// Both use the same monotonic request receipt and current geometry revision as
// touch. Home is submitted through this lease's runner, never a shared device.
int32_t eiscue_automation_home(uint64_t lease, uint64_t request_id, uint64_t revision);
// Sends 1..8192 strict UTF-8 bytes to the currently focused field in one owned,
// redacted Unicode text event, without accessing the clipboard. NUL is rejected.
// Text is not included in receipts; an event receipt does not prove visible input.
int32_t eiscue_automation_type_text(uint64_t lease, uint64_t request_id,
    uint64_t revision, const uint8_t *utf8, size_t length);
// Busy while an event receipt is outstanding. Timeout requires abort, which
// releases only this connection and does not claim to cancel an already sent event.
int32_t eiscue_automation_stop(uint64_t lease);
void eiscue_automation_abort(uint64_t lease);
#ifdef __cplusplus
}
#endif
