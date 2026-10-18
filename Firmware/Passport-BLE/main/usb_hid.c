// SPDX-License-Identifier: Apache-2.0
#include "usb_hid.h"
#include "sdkconfig.h"

#if CONFIG_IDF_TARGET_ESP32S3
#include "hid_descriptors.h"
#include "tinyusb.h"
#include "tinyusb_default_config.h"
#include "device/dcd.h"
#include "esp_mac.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include <stdatomic.h>
#include <stdio.h>

#if CFG_TUD_HID != 3 || CFG_TUD_CDC || CFG_TUD_MSC || CFG_TUD_NCM || CFG_TUD_ECM_RNDIS
#error "S3 control firmware exposes only the three HID input interfaces"
#endif
static const uint8_t mouse_descriptor[]={EISCUE_MOUSE_DESCRIPTOR};
static const uint8_t keyboard_descriptor[]={EISCUE_KEYBOARD_DESCRIPTOR};
static const uint8_t absolute_descriptor[]={EISCUE_ABSOLUTE_DESCRIPTOR};
static const tusb_desc_device_t device={
    .bLength=sizeof(tusb_desc_device_t),.bDescriptorType=TUSB_DESC_DEVICE,.bcdUSB=0x0200,
    .bMaxPacketSize0=64,.idVendor=0x303A,.idProduct=0x4004,.bcdDevice=0x0300,
    .iManufacturer=1,.iProduct=2,.iSerialNumber=3,.bNumConfigurations=1
};
static const uint8_t configuration[]={
    TUD_CONFIG_DESCRIPTOR(1,3,0,TUD_CONFIG_DESC_LEN+3*TUD_HID_DESC_LEN,0,100),
    TUD_HID_DESCRIPTOR(0,4,HID_ITF_PROTOCOL_NONE,sizeof mouse_descriptor,0x81,16,5),
    TUD_HID_DESCRIPTOR(1,5,HID_ITF_PROTOCOL_NONE,sizeof keyboard_descriptor,0x82,16,5),
    TUD_HID_DESCRIPTOR(2,6,HID_ITF_PROTOCOL_NONE,sizeof absolute_descriptor,0x83,16,5)
};
static char serial[13];
static const char *strings[]={(const char[]){0x09,0x04},"Eiscue development","Eiscue S3 HID",
    serial,"Relative pointer","Keyboard","Absolute pointer"};
static atomic_bool selected,online,ever_mounted;
static atomic_uint reset_count,unplug_count,setup_count;
static atomic_uint logged_reset,logged_unplug,logged_setup;
static esp_timer_handle_t reconnect_timer;
static portMUX_TYPE transition_lock=portMUX_INITIALIZER_UNLOCKED;
static int64_t connect_after;
static const char *TAG="eiscue_usb";
static void quarantine_locked(void) {
    atomic_store(&selected,false);atomic_store(&online,false);connect_after=0;
    // On pinned S3 TinyUSB this is a register-only PHY disconnect. Revocation
    // must also stop enumeration: a report whose guard raced with host reset
    // may still queue an old buffer, but cannot reach a newly connected host.
    (void)tud_disconnect();
}
static void diagnostics(void) {
    unsigned resets=atomic_load(&reset_count),unplugs=atomic_load(&unplug_count),setups=atomic_load(&setup_count);
    bool changed=atomic_exchange(&logged_reset,resets)!=resets;
    changed|=atomic_exchange(&logged_unplug,unplugs)!=unplugs;
    changed|=atomic_exchange(&logged_setup,setups)!=setups;
    if(changed)ESP_LOGI(TAG,"bus reset=%u unplug=%u setup=%u selected=%u mounted=%u first=%u",
        resets,unplugs,setups,(unsigned)atomic_load(&selected),(unsigned)tud_mounted(),(unsigned)!atomic_load(&ever_mounted));
}
static void reconnect(void *unused) {
    (void)unused;
    int64_t now=esp_timer_get_time();bool did_connect=false;
    portENTER_CRITICAL(&transition_lock);
    if(atomic_load(&selected) && connect_after>0 && now>=connect_after) {
        connect_after=0;(void)tud_connect();did_connect=true;
    }
    portEXIT_CRITICAL(&transition_lock);
    if(did_connect)ESP_LOGI(TAG,"connect selected=%u first=%u",(unsigned)atomic_load(&selected),(unsigned)!atomic_load(&ever_mounted));
}
void tud_event_hook_cb(uint8_t rhport,uint32_t event_id,bool in_isr) {
    (void)rhport;
    if(event_id==DCD_EVENT_BUS_RESET)atomic_fetch_add(&reset_count,1);
    else if(event_id==DCD_EVENT_UNPLUGGED)atomic_fetch_add(&unplug_count,1);
    else if(event_id==DCD_EVENT_SETUP_RECEIVED)atomic_fetch_add(&setup_count,1);
    // A bus reset is not followed by the wrapper's DETACHED callback. Do not
    // let a new USB host reuse the previous phone's calibrated authorization.
    if(event_id==DCD_EVENT_UNPLUGGED || event_id==DCD_EVENT_BUS_RESET) {
        if(in_isr)portENTER_CRITICAL_ISR(&transition_lock);else portENTER_CRITICAL(&transition_lock);
        if(event_id==DCD_EVENT_UNPLUGGED || atomic_load(&ever_mounted)) {
            quarantine_locked();
        }
        if(in_isr)portEXIT_CRITICAL_ISR(&transition_lock);else portEXIT_CRITICAL(&transition_lock);
    }
}
static void event(tinyusb_event_t *e,void *unused) {
    (void)unused;
    portENTER_CRITICAL(&transition_lock);
    if(e->id==TINYUSB_EVENT_ATTACHED)atomic_store(&ever_mounted,true);
    if(e->id==TINYUSB_EVENT_DETACHED || (e->id==TINYUSB_EVENT_SUSPENDED && atomic_load(&ever_mounted))) {
        quarantine_locked();
    }
    atomic_store(&online,atomic_load(&selected) && (e->id==TINYUSB_EVENT_ATTACHED || e->id==TINYUSB_EVENT_RESUMED));
    portEXIT_CRITICAL(&transition_lock);
    ESP_LOGI(TAG,"event=%u selected=%u mounted=%u first=%u",(unsigned)e->id,
        (unsigned)atomic_load(&selected),(unsigned)tud_mounted(),(unsigned)!atomic_load(&ever_mounted));
    diagnostics();
}
void eiscue_usb_hid_init(void) {
    uint8_t mac[6];ESP_ERROR_CHECK(esp_read_mac(mac,ESP_MAC_BASE));
    snprintf(serial,sizeof serial,"%02X%02X%02X%02X%02X%02X",mac[0],mac[1],mac[2],mac[3],mac[4],mac[5]);
    tinyusb_config_t config=TINYUSB_DEFAULT_CONFIG();
    config.descriptor.device=&device;config.descriptor.full_speed_config=configuration;
    config.descriptor.string=strings;config.descriptor.string_count=sizeof strings/sizeof strings[0];
    config.phy.self_powered=false;config.event_cb=event;
    const esp_timer_create_args_t timer={.callback=reconnect,.name="eiscue_usb_connect"};
    ESP_ERROR_CHECK(esp_timer_create(&timer,&reconnect_timer));
    ESP_ERROR_CHECK(tinyusb_driver_install(&config));
    eiscue_usb_hid_revoke();
}
bool eiscue_usb_hid_supported(void) {return true;}
bool eiscue_usb_hid_mounted(void) {diagnostics();return atomic_load(&ever_mounted) && atomic_load(&online) && tud_mounted() && !tud_suspended();}
bool eiscue_usb_hid_online(void) {return atomic_load(&selected) && eiscue_usb_hid_mounted();}
bool eiscue_usb_hid_relative_ready(void) {
    return eiscue_usb_hid_online() && tud_hid_n_get_protocol(0)==HID_PROTOCOL_REPORT && tud_hid_n_ready(0);
}
void eiscue_usb_hid_select(bool value) {
    if(value) {
        (void)esp_timer_stop(reconnect_timer);
        int64_t deadline=esp_timer_get_time()+20000;
        portENTER_CRITICAL(&transition_lock);
        atomic_store(&ever_mounted,false);atomic_store(&online,false);atomic_store(&selected,true);
        connect_after=deadline;
        // Soft disconnect does not clear TinyUSB's previous cfg_num. Start a
        // fresh host enumeration without trusting that stale mounted flag or
        // blocking the BLE task while the host observes the disconnect.
        (void)tud_disconnect();
        portEXIT_CRITICAL(&transition_lock);
        if(esp_timer_start_once(reconnect_timer,20000)!=ESP_OK)eiscue_usb_hid_revoke();
        ESP_LOGI(TAG,"select=%u mounted=%u first=1",(unsigned)atomic_load(&selected),(unsigned)tud_mounted());
        diagnostics();
    }
    else eiscue_usb_hid_revoke();
}
void eiscue_usb_hid_revoke(void) {
    // Terminate the USB HID transport if a release cannot be delivered, or
    // the authenticated BLE command owner disappears. Never route to BLE.
    portENTER_CRITICAL(&transition_lock);
    quarantine_locked();
    portEXIT_CRITICAL(&transition_lock);
    (void)esp_timer_stop(reconnect_timer);
}
uint8_t eiscue_usb_hid_send(const eiscue_report *report) {
    if(!eiscue_usb_hid_online())return EISCUE_NOT_SUBSCRIBED;
    if(report->kind<EISCUE_MOUSE_REPORT || report->kind>EISCUE_ABSOLUTE_REPORT)return EISCUE_ARGUMENT;
    uint8_t instance=report->kind-1;
    if(tud_hid_n_get_protocol(instance)!=HID_PROTOCOL_REPORT || !tud_hid_n_ready(instance))return EISCUE_SEND_FAILED;
    bool sent=tud_hid_n_report(instance,report->kind,report->bytes,report->length);
    // SELECT runs on the same serialized BLE task as this submission. If a
    // USB callback revoked ownership meanwhile, no fresh SELECT can mask it.
    return sent && atomic_load(&selected)?EISCUE_SENT:EISCUE_SEND_FAILED;
}
const uint8_t *tud_hid_descriptor_report_cb(uint8_t instance) {
    const uint8_t *descriptors[]={mouse_descriptor,keyboard_descriptor,absolute_descriptor};
    ESP_LOGI(TAG,"descriptor instance=%u",(unsigned)instance);
    return instance<3?descriptors[instance]:NULL;
}
uint16_t tud_hid_get_report_cb(uint8_t instance,uint8_t report_id,hid_report_type_t type,uint8_t *buffer,uint16_t length) {
    (void)instance;(void)report_id;(void)type;(void)buffer;(void)length;
    ESP_LOGI(TAG,"get_report instance=%u id=%u type=%u length=%u",(unsigned)instance,(unsigned)report_id,(unsigned)type,(unsigned)length);
    return 0;
}
void tud_hid_set_report_cb(uint8_t instance,uint8_t report_id,hid_report_type_t type,const uint8_t *buffer,uint16_t length) {
    (void)instance;(void)report_id;(void)type;(void)buffer;(void)length;
}
#else
void eiscue_usb_hid_init(void) {}
bool eiscue_usb_hid_supported(void) {return false;}
bool eiscue_usb_hid_online(void) {return false;}
bool eiscue_usb_hid_relative_ready(void) {return false;}
bool eiscue_usb_hid_mounted(void) {return false;}
void eiscue_usb_hid_select(bool selected) {(void)selected;}
void eiscue_usb_hid_revoke(void) {}
uint8_t eiscue_usb_hid_send(const eiscue_report *report) {(void)report;return EISCUE_NOT_SUBSCRIBED;}
#endif
