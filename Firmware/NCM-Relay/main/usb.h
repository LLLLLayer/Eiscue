/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
void nd_usb_install(void);
bool nd_usb_online(void);
uint32_t nd_usb_epoch(void);
esp_err_t nd_network_start(void);
uint32_t nd_network_index(void);
