/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "network.h"
#include "developer_service.h"
#include "esp_log.h"
#include "esp_wifi.h"

void app_main(void) {
    esp_err_t result = passport_network_start();
    if (result == ESP_OK) {
        result = developer_service_start(passport_online, passport_epoch,
                                         passport_network_index());
    }
    if (result != ESP_OK) {
        // Configuration is provisioned privately by the flash tool. Never erase
        // factory credentials or fall back to a public password after an error.
        (void)esp_wifi_stop();
        ESP_LOGE("passport", "Relay unavailable (%s); AP disabled. Check provisioning.",
                 esp_err_to_name(result));
    }
}
