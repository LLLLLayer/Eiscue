// SPDX-License-Identifier: Apache-2.0
#include "hid_peripheral.h"
#include "esp_log.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "store/config/ble_store_config.h"
#include <assert.h>
#include <string.h>

static const char *TAG="eiscue_ble";
void ble_store_config_init(void);
static uint8_t address_type;
static int gap_event(struct ble_gap_event *event,void *context);
static int store_status(struct ble_store_status_event *event,void *arg) {
    (void)arg;
    // The SDK demo's round-robin handler evicts an existing peer on overflow.
    // Preserve the authorized bond; an extra peer must fail instead.
    if(event->event_code==BLE_STORE_EVENT_FULL)return 0;
    ESP_LOGW(TAG,"bond store rejected event=%u",event->event_code);
    return BLE_HS_ESTORE_CAP;
}
static void advertise(void) {
    const ble_uuid16_t hid_uuid=BLE_UUID16_INIT(0x1812);
    const ble_uuid128_t command_service=BLE_UUID128_INIT(
        0xB3,0x3A,0x64,0x23,0xE6,0x70,0x1D,0x95,0x84,0x4E,0xE8,0x41,0x9A,0x4E,0x07,0x74);
    struct ble_hs_adv_fields fields={0};
    fields.flags=BLE_HS_ADV_F_DISC_GEN|BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids16=&hid_uuid;fields.num_uuids16=1;fields.uuids16_is_complete=0;
    fields.uuids128=&command_service;fields.num_uuids128=1;fields.uuids128_is_complete=1;
    fields.appearance=0x03C2;fields.appearance_is_present=1;
    int rc=ble_gap_adv_set_fields(&fields);
    if(rc){ESP_LOGE(TAG,"adv fields rc=%d",rc);return;}
    struct ble_hs_adv_fields scan={0};
    const char *name=ble_svc_gap_device_name();scan.name=(const uint8_t *)name;
    scan.name_len=strlen(name);scan.name_is_complete=1;
    rc=ble_gap_adv_rsp_set_fields(&scan);
    if(rc){ESP_LOGE(TAG,"scan response rc=%d",rc);return;}
    const struct ble_gap_adv_params params={.conn_mode=BLE_GAP_CONN_MODE_UND,.disc_mode=BLE_GAP_DISC_MODE_GEN};
    rc=ble_gap_adv_start(address_type,NULL,BLE_HS_FOREVER,&params,gap_event,NULL);
    ESP_LOGI(TAG,"advertising Eiscue BLE rc=%d",rc);
}
static int gap_event(struct ble_gap_event *event,void *context) {
    (void)context;
    switch(event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if(event->connect.status){advertise();return 0;}
        eiscue_ble_on_connect(event->connect.conn_handle);
        ESP_LOGI(TAG,"connected; requesting encrypted bond");
        (void)ble_gap_security_initiate(event->connect.conn_handle);return 0;
    case BLE_GAP_EVENT_DISCONNECT:
        eiscue_ble_on_disconnect();ESP_LOGI(TAG,"disconnected reason=%d",event->disconnect.reason);advertise();return 0;
    case BLE_GAP_EVENT_ENC_CHANGE:eiscue_ble_on_security_change();return 0;
    case BLE_GAP_EVENT_SUBSCRIBE:eiscue_ble_on_subscribe(event->subscribe.conn_handle,event->subscribe.attr_handle,event->subscribe.cur_notify);return 0;
    case BLE_GAP_EVENT_ADV_COMPLETE:advertise();return 0;
    case BLE_GAP_EVENT_REPEAT_PAIRING:
        // Do not silently replace an existing bond. Test re-pairing requires
        // an explicit reset coordinated outside this minimal experiment.
        return BLE_GAP_REPEAT_PAIRING_IGNORE;
    default:return 0;
    }
}
static void host_reset(int reason) {eiscue_ble_on_disconnect();ESP_LOGW(TAG,"host reset=%d",reason);}
static void host_sync(void) {
    int rc=ble_hs_util_ensure_addr(0);if(rc){ESP_LOGE(TAG,"address init rc=%d",rc);return;}
    rc=ble_hs_id_infer_auto(0,&address_type);if(rc){ESP_LOGE(TAG,"address type rc=%d",rc);return;}
    // The firmware may have updated its HID map and GATT handles while an
    // iPhone retained the old bonded cache. The standard GATT indication marks
    // the database changed for subscribed peers, including disconnected bonds.
    ble_svc_gatt_changed(0x0001,0xFFFF);
    advertise();
}
static void host_task(void *arg) {(void)arg;nimble_port_run();nimble_port_freertos_deinit();}
void app_main(void) {
    // Existing Wi-Fi configuration and original NVS are preserved. Never erase
    // NVS automatically if it is full or has an incompatible prior version.
    ESP_ERROR_CHECK(nvs_flash_init());
    ESP_ERROR_CHECK(nimble_port_init());
    ble_hs_cfg.reset_cb=host_reset;ble_hs_cfg.sync_cb=host_sync;
    ble_hs_cfg.store_status_cb=store_status;
    ble_hs_cfg.sm_io_cap=BLE_HS_IO_NO_INPUT_OUTPUT;
    ble_hs_cfg.sm_bonding=1;ble_hs_cfg.sm_sc=1;ble_hs_cfg.sm_mitm=0;
    ble_hs_cfg.sm_our_key_dist=BLE_SM_PAIR_KEY_DIST_ENC|BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist=BLE_SM_PAIR_KEY_DIST_ENC|BLE_SM_PAIR_KEY_DIST_ID;
    ble_svc_gap_init();ble_svc_gatt_init();
    assert(ble_svc_gap_device_name_set("Eiscue BLE")==0);
    assert(ble_svc_gap_device_appearance_set(0x03C2)==0);
    assert(eiscue_ble_services_init()==0);
    ble_store_config_init();
    ESP_LOGI(TAG,"Eiscue BLE board v0.2.0; no Wi-Fi startup; free heap=%lu",(unsigned long)esp_get_free_heap_size());
    nimble_port_freertos_init(host_task);
}
