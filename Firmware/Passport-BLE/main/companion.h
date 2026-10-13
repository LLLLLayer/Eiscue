// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "companion_protocol.h"

// C3-only implementation. All BLE effects are dispatched onto the host queue.
void companion_init(void);
void companion_connection_changed(bool connected,bool secure);
bool companion_update_status(const uint8_t *bytes,size_t length);
bool companion_input_stopped(void);
bool companion_accepts_command(uint8_t opcode);
void companion_read_stop(uint8_t bytes[COMPANION_STOP_SIZE]);
void companion_host_unlock(void);
