// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "command_protocol.h"

void eiscue_usb_hid_init(void);
bool eiscue_usb_hid_supported(void);
bool eiscue_usb_hid_online(void);
bool eiscue_usb_hid_relative_ready(void);
bool eiscue_usb_hid_mounted(void);
void eiscue_usb_hid_select(bool selected);
void eiscue_usb_hid_revoke(void);
uint8_t eiscue_usb_hid_send(const eiscue_report *report);
