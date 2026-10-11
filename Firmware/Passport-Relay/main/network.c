/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "network.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "dhcpserver/dhcpserver.h"
#include <stdatomic.h>
#include <string.h>

#if defined(CONFIG_LWIP_IP_FORWARD) || defined(CONFIG_LWIP_IPV6_FORWARD) || \
    defined(CONFIG_LWIP_IPV4_NAPT) || defined(CONFIG_LWIP_DHCPS_ADD_DNS)
#error "Passport Relay must not provide forwarding, NAT or fallback DNS"
#endif

#define READY_BIT BIT0
#define FAILED_BIT BIT1

static esp_netif_t *ap_netif;
static EventGroupHandle_t start_events;
static atomic_bool ready;
static atomic_bool connected;
static atomic_uint_least32_t link_epoch = 1;

static void clear_secret(void *buffer, size_t length) {
    volatile unsigned char *bytes = buffer;
    while (length--) *bytes++ = 0;
}

static bool printable(const char *value, size_t length) {
    for (size_t i = 0; i < length; ++i) {
        if ((unsigned char)value[i] < 32 || (unsigned char)value[i] > 126) return false;
    }
    return true;
}

static esp_err_t read_config(wifi_config_t *config) {
    esp_err_t result = nvs_flash_init_partition("eiscue_cfg");
    if (result != ESP_OK) return result;
    nvs_handle_t handle;
    result = nvs_open_from_partition("eiscue_cfg", "relay", NVS_READONLY, &handle);
    if (result != ESP_OK) return result;
    char ssid[33] = {0};
    char password[64] = {0};
    size_t ssid_length = sizeof ssid, password_length = sizeof password;
    result = nvs_get_str(handle, "ssid", ssid, &ssid_length);
    if (result == ESP_OK) result = nvs_get_str(handle, "password", password, &password_length);
    nvs_close(handle);
    if (result == ESP_OK &&
        (ssid_length < 2 || ssid_length > sizeof ssid ||
         password_length < 17 || password_length > sizeof password ||
         strlen(ssid) + 1 != ssid_length || strlen(password) + 1 != password_length ||
         !printable(ssid, ssid_length - 1) || !printable(password, password_length - 1))) {
        result = ESP_ERR_INVALID_ARG;
    }
    if (result == ESP_OK) {
        memcpy(config->ap.ssid, ssid, ssid_length - 1);
        config->ap.ssid_len = ssid_length - 1;
        memcpy(config->ap.password, password, password_length);
        config->ap.channel = 1;
        config->ap.authmode = WIFI_AUTH_WPA2_PSK;
        config->ap.pairwise_cipher = WIFI_CIPHER_TYPE_CCMP;
        config->ap.max_connection = 1;
        config->ap.pmf_cfg.capable = true;
        config->ap.pmf_cfg.required = true;
    }
    clear_secret(password, sizeof password);
    clear_secret(ssid, sizeof ssid);
    return result;
}

static void revoke_link(void) {
    atomic_store(&connected, false);
    atomic_fetch_add(&link_epoch, 1);
}

static void fail_closed(esp_err_t result) {
    atomic_store(&ready, false);
    revoke_link();
    xEventGroupClearBits(start_events, READY_BIT);
    xEventGroupSetBits(start_events, FAILED_BIT);
    (void)esp_wifi_stop();
    ESP_LOGE("passport", "Local network setup failed (%s); AP disabled", esp_err_to_name(result));
}

static esp_err_t check_pool(void) {
    // ESP-IDF 5.5.3 rejects start == end in its explicit lease setter. A /30
    // has exactly one peer address, so use the native pool and verify it.
    dhcps_lease_t lease = {0};
    esp_err_t result = esp_netif_dhcps_option(ap_netif, ESP_NETIF_OP_GET,
        ESP_NETIF_REQUESTED_IP_ADDRESS, &lease, sizeof lease);
    ip4_addr_t peer;
    IP4_ADDR(&peer, 192, 168, 7, 2);
    if (result == ESP_OK && (!lease.enable || lease.start_ip.addr != peer.addr ||
                            lease.end_ip.addr != peer.addr)) return ESP_ERR_INVALID_STATE;
    uint8_t enabled = 1;
    if (result == ESP_OK) result = esp_netif_dhcps_option(ap_netif, ESP_NETIF_OP_GET,
        ESP_NETIF_ROUTER_SOLICITATION_ADDRESS, &enabled, sizeof enabled);
    if (result == ESP_OK && enabled) return ESP_ERR_INVALID_STATE;
    if (result == ESP_OK) result = esp_netif_dhcps_option(ap_netif, ESP_NETIF_OP_GET,
        ESP_NETIF_DOMAIN_NAME_SERVER, &enabled, sizeof enabled);
    if (result == ESP_OK && enabled) return ESP_ERR_INVALID_STATE;
    return result;
}

static void wifi_event(void *argument, esp_event_base_t base, int32_t event_id, void *data) {
    (void)argument; (void)base; (void)data;
    if (event_id == WIFI_EVENT_AP_START) {
        atomic_store(&ready, false);
        revoke_link();
        xEventGroupClearBits(start_events, READY_BIT | FAILED_BIT);
        // The default handler has brought the interface up. Configuration
        // stopped DHCP, so explicitly restart it before reading its pool.
        esp_err_t result = esp_netif_dhcps_start(ap_netif);
        if (result == ESP_ERR_ESP_NETIF_DHCP_ALREADY_STARTED) result = ESP_OK;
        if (result == ESP_OK) result = check_pool();
        if (result == ESP_OK) result = esp_netif_create_ip6_linklocal(ap_netif);
        if (result != ESP_OK) { fail_closed(result); return; }
        atomic_store(&ready, true);
        xEventGroupSetBits(start_events, READY_BIT);
        ESP_LOGI("passport", "Private WPA2 AP ready; waiting for one phone");
    } else if (event_id == WIFI_EVENT_AP_STACONNECTED) {
        revoke_link();
        if (atomic_load(&ready)) atomic_store(&connected, true);
    } else if (event_id == WIFI_EVENT_AP_STADISCONNECTED) {
        revoke_link();
        // Release the only address for a new/private-MAC client. Existing relay
        // streams observe the changed epoch and cannot survive a reconnect.
        if (atomic_load(&ready)) {
            esp_err_t result = esp_netif_dhcps_stop(ap_netif);
            if (result == ESP_OK) result = esp_netif_dhcps_start(ap_netif);
            if (result == ESP_OK) result = check_pool();
            if (result != ESP_OK) fail_closed(result);
        }
    } else if (event_id == WIFI_EVENT_AP_STOP) {
        atomic_store(&ready, false);
        revoke_link();
        xEventGroupClearBits(start_events, READY_BIT);
    }
}

static esp_err_t configure_network(void) {
    esp_err_t result = esp_netif_init();
    if (result != ESP_OK) return result;
    result = esp_event_loop_create_default();
    if (result != ESP_OK) return result;
    ap_netif = esp_netif_create_default_wifi_ap();
    if (!ap_netif) return ESP_ERR_NO_MEM;
    result = esp_netif_dhcps_stop(ap_netif);
    if (result != ESP_OK && result != ESP_ERR_ESP_NETIF_DHCP_ALREADY_STOPPED) return result;
    esp_netif_ip_info_t address = {0};
    IP4_ADDR(&address.ip, 192, 168, 7, 1);
    IP4_ADDR(&address.netmask, 255, 255, 255, 252);
    result = esp_netif_set_ip_info(ap_netif, &address); // gateway remains zero
    if (result != ESP_OK) return result;
    uint8_t disabled = 0;
    result = esp_netif_dhcps_option(ap_netif, ESP_NETIF_OP_SET,
        ESP_NETIF_ROUTER_SOLICITATION_ADDRESS, &disabled, sizeof disabled);
    if (result != ESP_OK) return result;
    return esp_netif_dhcps_option(ap_netif, ESP_NETIF_OP_SET,
        ESP_NETIF_DOMAIN_NAME_SERVER, &disabled, sizeof disabled);
}

esp_err_t passport_network_start(void) {
    wifi_config_t config = {0};
    esp_err_t result = read_config(&config);
    if (result != ESP_OK) return result;
    // Wi-Fi NVS and PHY calibration storage are disabled. The previous
    // firmware's runtime NVS need not be erased or interpreted to start here.
    result = configure_network();
    if (result == ESP_OK) {
        start_events = xEventGroupCreate();
        if (!start_events) result = ESP_ERR_NO_MEM;
    }
    if (result == ESP_OK) {
        wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
        result = esp_wifi_init(&init);
    }
    if (result == ESP_OK) result = esp_wifi_set_storage(WIFI_STORAGE_RAM);
    if (result == ESP_OK) result = esp_wifi_set_mode(WIFI_MODE_AP);
    if (result == ESP_OK) result = esp_wifi_set_config(WIFI_IF_AP, &config);
    clear_secret(&config, sizeof config);
    if (result == ESP_OK) result = esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event, NULL);
    if (result == ESP_OK) result = esp_wifi_start();
    if (result != ESP_OK) return result;
    EventBits_t events = xEventGroupWaitBits(start_events, READY_BIT | FAILED_BIT,
                                            pdFALSE, pdFALSE, pdMS_TO_TICKS(5000));
    if (events & FAILED_BIT) return ESP_FAIL;
    if (!(events & READY_BIT)) return ESP_ERR_TIMEOUT;
    return ESP_OK;
}

bool passport_online(void) { return atomic_load(&ready) && atomic_load(&connected); }
uint32_t passport_epoch(void) { return atomic_load(&link_epoch); }
uint32_t passport_network_index(void) { return (uint32_t)esp_netif_get_netif_impl_index(ap_netif); }
