/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_HID_H
#define BRIDGE_HID_H
#include "bridge_core.h"
#define BRIDGE_TOUCH_REPORT_SIZE 58u
#define BRIDGE_KEYBOARD_REPORT_SIZE 39u
#define BRIDGE_TOUCH_CONTACT 0xc2u
#define BRIDGE_TOUCH_RELEASE 0x02u
#define BRIDGE_TOUCH_SERVICE_ID UINT64_C(257)
#define BRIDGE_HID_TIMESTAMP_MASK UINT64_C(0xffffffffffff)
#define BRIDGE_HOME_USAGE_PAGE 0x0cu
#define BRIDGE_HOME_USAGE_CODE 0x40u
/* Pure report builders, NOT transport calls. Touch requires an authenticated
 * active media session; keyboard also requires registered virtual service.
 * timestamp is the explicitly supplied low 48 bits of monotonic nanoseconds.
 * Invalid values fail instead of silently wrapping. */
bridge_status bridge_hid_touch(uint8_t *out, size_t capacity, uint8_t state,
    uint32_t x, uint32_t y, uint64_t timestamp);
/* Raw usages only; intentionally no text/ASCII API because the baseline's
 * Shift/case handling is not correct on the tested iPhone. Empty set releases. */
bridge_status bridge_hid_keyboard(uint8_t *out, size_t capacity,
    const uint16_t *usages, size_t count, uint64_t timestamp);
/* Maps an inclusive screenshot pixel coordinate 0..extent-1 to 0..65535.
 * Caller must account for screen rotation/crop before invoking. */
bridge_status bridge_hid_normalize(uint32_t pixel, uint32_t extent, uint16_t *out);
#endif
