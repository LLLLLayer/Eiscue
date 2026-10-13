// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "sdkconfig.h"
#include <stdint.h>
int eiscue_ble_services_init(void);
void eiscue_ble_on_connect(uint16_t connection);
void eiscue_ble_on_disconnect(void);
void eiscue_ble_on_subscribe(uint16_t connection, uint16_t attribute, int enabled);
void eiscue_ble_on_security_change(void);
#if CONFIG_IDF_TARGET_ESP32C3
// Callable from the button task; effects run on the NimBLE host queue.
void eiscue_ble_companion_stop(int unlock);
#endif
