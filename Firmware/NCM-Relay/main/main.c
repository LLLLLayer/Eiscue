/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "usb.h"
#include "developer_service.h"
void app_main(void) {
    ESP_ERROR_CHECK(nd_network_start());
    ESP_ERROR_CHECK(developer_service_start(nd_usb_online, nd_usb_epoch, nd_network_index()));
}
