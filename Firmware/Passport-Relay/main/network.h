// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

esp_err_t passport_network_start(void);
bool passport_online(void);
uint32_t passport_epoch(void);
uint32_t passport_network_index(void);
