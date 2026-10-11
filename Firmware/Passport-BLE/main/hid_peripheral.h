// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdint.h>
int eiscue_ble_services_init(void);
void eiscue_ble_on_connect(uint16_t connection);
void eiscue_ble_on_disconnect(void);
void eiscue_ble_on_subscribe(uint16_t attribute, int enabled);
void eiscue_ble_on_security_change(void);
