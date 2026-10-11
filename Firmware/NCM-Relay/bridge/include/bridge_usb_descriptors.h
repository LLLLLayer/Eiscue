/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_USB_DESCRIPTORS_H
#define BRIDGE_USB_DESCRIPTORS_H
#include "bridge_core.h"
#define BRIDGE_USB_CONFIG_MAX 4096u
#define BRIDGE_USB_APPLE_VID 0x05acu
/* Values describe the observed active USB configuration, never assumed pins. */
typedef struct {
    uint8_t configuration, interface_number, alternate_setting;
    uint8_t endpoint_in, endpoint_out;
    uint16_t max_packet_in, max_packet_out;
} bridge_usb_interface;
/* ESP32-S3 Full Speed profile: exact vendor class FF/FE/02; exactly one
 * bulk IN and OUT endpoint, alternate setting 0 only; legal full-speed bulk MPS (8/16/32/64).
 * Strict lengths and ambiguities fail closed. Other configurations are not
 * selected automatically; caller chooses an observed configuration value. */
bridge_status bridge_usb_find_mux_interface(const uint8_t *descriptor, size_t size,
    bridge_usb_interface *out);
#endif
