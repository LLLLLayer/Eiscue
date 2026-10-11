/* SPDX-License-Identifier: GPL-3.0-or-later
 * Wire layout derived from pymobiledevice3 hid_service.py at
 * cd895d17ce8a97d883c10f87b26c7356d5e0ccb1 (GPL-3.0-or-later).
 */
#include "bridge_hid.h"
#include <string.h>
static void le16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void timestamp48(uint8_t *p, uint64_t t) {
    for (unsigned i = 0; i < 6; ++i) p[i] = (uint8_t)(t >> (i * 8));
}
bridge_status bridge_hid_touch(uint8_t *out, size_t cap, uint8_t state,
    uint32_t x, uint32_t y, uint64_t timestamp) {
    if (!out || x > UINT16_MAX || y > UINT16_MAX || timestamp > BRIDGE_HID_TIMESTAMP_MASK ||
        (state != BRIDGE_TOUCH_CONTACT && state != BRIDGE_TOUCH_RELEASE)) return BRIDGE_E_ARGUMENT;
    if (cap < BRIDGE_TOUCH_REPORT_SIZE) return BRIDGE_E_LIMIT;
    memset(out, 0, BRIDGE_TOUCH_REPORT_SIZE);
    out[0] = 9; out[1] = 1; out[2] = 5; out[3] = state;
    le16(out + 4, (uint16_t)x); le16(out + 6, (uint16_t)y);
    out[40] = 2; timestamp48(out + 44, timestamp); return BRIDGE_OK;
}
bridge_status bridge_hid_keyboard(uint8_t *out, size_t cap,
    const uint16_t *usages, size_t count, uint64_t timestamp) {
    if (!out || (!usages && count) || timestamp > BRIDGE_HID_TIMESTAMP_MASK || count > 240)
        return BRIDGE_E_ARGUMENT;
    if (cap < BRIDGE_KEYBOARD_REPORT_SIZE) return BRIDGE_E_LIMIT;
    for (size_t i = 0; i < count; ++i) if (usages[i] >= 240) return BRIDGE_E_ARGUMENT;
    memset(out, 0, BRIDGE_KEYBOARD_REPORT_SIZE); out[0] = 1;
    for (size_t i = 0; i < count; ++i)
        out[1 + usages[i] / 8] |= (uint8_t)(1u << (usages[i] % 8));
    timestamp48(out + 31, timestamp); return BRIDGE_OK;
}
bridge_status bridge_hid_normalize(uint32_t pixel, uint32_t extent, uint16_t *out) {
    if (!out || extent < 2 || pixel >= extent) return BRIDGE_E_ARGUMENT;
    uint64_t n = (uint64_t)pixel * UINT16_MAX + (extent - 1) / 2;
    *out = (uint16_t)(n / (extent - 1)); return BRIDGE_OK;
}
