// SPDX-License-Identifier: Apache-2.0
// Original minimal HOGP + encrypted GATT peripheral. HID byte layouts follow
// USB HID Usage Tables; NimBLE registration/callout APIs are from ESP-IDF.
#include "hid_peripheral.h"
#include "command_protocol.h"
#include "host/ble_hs.h"
#include "host/ble_hs_mbuf.h"
#include "host/ble_uuid.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_npl.h"
#include "esp_log.h"
#include <stdbool.h>
#include <string.h>

static const char *TAG="eiscue_ble";
static const ble_uuid128_t service_uuid=BLE_UUID128_INIT(
    0xB3,0x3A,0x64,0x23,0xE6,0x70,0x1D,0x95,0x84,0x4E,0xE8,0x41,0x9A,0x4E,0x07,0x74);
static const ble_uuid128_t command_uuid=BLE_UUID128_INIT(
    0xB4,0x3A,0x64,0x23,0xE6,0x70,0x1D,0x95,0x84,0x4E,0xE8,0x41,0x9A,0x4E,0x07,0x74);
static const ble_uuid128_t response_uuid=BLE_UUID128_INIT(
    0xB5,0x3A,0x64,0x23,0xE6,0x70,0x1D,0x95,0x84,0x4E,0xE8,0x41,0x9A,0x4E,0x07,0x74);

// Report ID 1: buttons + relative X/Y/wheel (4 bytes).
// Report ID 2: boot-compatible 6-key keyboard (8 bytes).
// HOGP Report Reference descriptors identify each characteristic, therefore
// notifications contain report data only, without a prefixed report ID.
static const uint8_t report_map[]={
    0x05,0x01,0x09,0x02,0xA1,0x01,0x85,0x01,
    0x09,0x01,0xA1,0x00,0x05,0x09,0x19,0x01,0x29,0x03,
    0x15,0x00,0x25,0x01,0x95,0x03,0x75,0x01,0x81,0x02,
    0x95,0x01,0x75,0x05,0x81,0x03,
    0x05,0x01,0x09,0x30,0x09,0x31,0x09,0x38,
    0x15,0x81,0x25,0x7F,0x75,0x08,0x95,0x03,0x81,0x06,0xC0,0xC0,
    0x05,0x01,0x09,0x06,0xA1,0x01,0x85,0x02,
    0x05,0x07,0x19,0xE0,0x29,0xE7,0x15,0x00,0x25,0x01,
    0x75,0x01,0x95,0x08,0x81,0x02,
    0x75,0x08,0x95,0x01,0x81,0x03,
    0x19,0x00,0x29,0x65,0x15,0x00,0x25,0x65,
    0x75,0x08,0x95,0x06,0x81,0x00,0xC0
};
enum attribute_kind { HID_INFO=1,HID_MAP,HID_CONTROL,HID_PROTOCOL,
    HID_MOUSE,HID_KEYBOARD,HID_MOUSE_REF,HID_KEYBOARD_REF,CUSTOM_COMMAND,CUSTOM_RESPONSE,
    BOOT_MOUSE,BOOT_KEYBOARD,BOOT_KEYBOARD_OUTPUT,MANUFACTURER,PNP_ID,BATTERY_LEVEL };
static uint16_t connection=BLE_HS_CONN_HANDLE_NONE;
static uint16_t mouse_handle,keyboard_handle,response_handle,boot_mouse_handle,boot_keyboard_handle;
static bool mouse_subscribed,keyboard_subscribed,response_subscribed,boot_mouse_subscribed,boot_keyboard_subscribed;
static bool suspended;
static uint8_t protocol_mode=1;
static uint8_t mouse_state[4],keyboard_state[8];
static uint8_t last_response[EISCUE_RESPONSE_SIZE]={1,0,0,0,EISCUE_INSECURE,0,0,0};
static struct ble_npl_callout release_timer;
static bool active,seen_request;
static uint16_t last_request;
static struct {
    uint8_t command[EISCUE_COMMAND_SIZE],emitted;
    eiscue_action action;
} pending;

static bool secure_connection(void) {
    struct ble_gap_conn_desc desc;
    return connection!=BLE_HS_CONN_HANDLE_NONE && ble_gap_conn_find(connection,&desc)==0 &&
        desc.sec_state.encrypted && desc.sec_state.bonded;
}
static void respond(const uint8_t *command,uint8_t status,uint8_t emitted) {
    eiscue_make_response(command,status,emitted,secure_connection(),last_response);
    if (response_subscribed && secure_connection()) {
        struct os_mbuf *mbuf=ble_hs_mbuf_from_flat(last_response,sizeof last_response);
        if (mbuf) (void)ble_gatts_notify_custom(connection,response_handle,mbuf);
    }
    ESP_LOGI(TAG,"command op=%u id=%u status=%u reports=%u secure=%u",
        command[1],(unsigned)((uint16_t)command[2]|((uint16_t)command[3]<<8)),status,emitted,last_response[6]);
}
static uint16_t report_handle(uint8_t kind) {
    if (kind==EISCUE_MOUSE_REPORT) return protocol_mode==1?mouse_handle:boot_mouse_handle;
    return protocol_mode==1?keyboard_handle:boot_keyboard_handle;
}
static bool report_subscribed(uint8_t kind) {
    if (kind==EISCUE_MOUSE_REPORT) return protocol_mode==1?mouse_subscribed:boot_mouse_subscribed;
    return protocol_mode==1?keyboard_subscribed:boot_keyboard_subscribed;
}
static uint8_t emit(const eiscue_report *report) {
    if (!secure_connection()) return EISCUE_INSECURE;
    if (!report_subscribed(report->kind) || suspended) return EISCUE_NOT_SUBSCRIBED;
    uint8_t length=report->length;
    if (protocol_mode==0 && report->kind==EISCUE_MOUSE_REPORT) length=3;
    struct os_mbuf *mbuf=ble_hs_mbuf_from_flat(report->bytes,length);
    if (!mbuf) return EISCUE_SEND_FAILED;
    int rc=ble_gatts_notify_custom(connection,report_handle(report->kind),mbuf);
    if (rc) return EISCUE_SEND_FAILED;
    memcpy(report->kind==EISCUE_MOUSE_REPORT?mouse_state:keyboard_state,report->bytes,report->length);
    return EISCUE_SENT;
}
static bool release_all(void) {
    const eiscue_report mouse={.kind=EISCUE_MOUSE_REPORT,.length=4};
    const eiscue_report keyboard={.kind=EISCUE_KEYBOARD_REPORT,.length=8};
    // Only release subscribed channels; never manufacture a success for a
    // channel the OS did not discover. A disconnect clears host-held HID state.
    bool success=true;
    if (report_subscribed(EISCUE_MOUSE_REPORT) && emit(&mouse)!=EISCUE_SENT) success=false;
    if (report_subscribed(EISCUE_KEYBOARD_REPORT) && emit(&keyboard)!=EISCUE_SENT) success=false;
    memset(mouse_state,0,sizeof mouse_state);memset(keyboard_state,0,sizeof keyboard_state);
    return success;
}
static void interrupt_and_release(void) {
    ble_npl_callout_stop(&release_timer);
    if (active) {active=false;respond(pending.command,EISCUE_SEND_FAILED,pending.emitted);}
    if (!release_all() && connection!=BLE_HS_CONN_HANDLE_NONE)
        (void)ble_gap_terminate(connection,BLE_ERR_REM_USER_CONN_TERM);
}
static void finish_later(struct ble_npl_event *event) {
    (void)event;
    if (!active) return;
    uint8_t status=emit(&pending.action.reports[1]);
    if (status==EISCUE_SENT) pending.emitted++;
    active=false;
    respond(pending.command,status,pending.emitted);
    if (status!=EISCUE_SENT && !release_all() && connection!=BLE_HS_CONN_HANDLE_NONE)
        (void)ble_gap_terminate(connection,BLE_ERR_REM_USER_CONN_TERM);
}
static int control_write(uint16_t conn,const struct os_mbuf *om) {
    uint8_t command[EISCUE_COMMAND_SIZE];
    if (OS_MBUF_PKTLEN(om)!=sizeof command || os_mbuf_copydata(om,0,sizeof command,command))
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    if (conn!=connection || !secure_connection()) return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
    uint16_t request=(uint16_t)command[2]|((uint16_t)command[3]<<8);
    uint16_t delta=(uint16_t)(request-last_request);
    if (seen_request && (delta==0 || delta>32767)) {
        // At most once per connection. A lost acknowledgement never replays
        // input. The App must observe UI effects rather than retry clicks.
        respond(command,EISCUE_ARGUMENT,0);return 0;
    }
    seen_request=true;last_request=request;
    eiscue_action action;
    if (!eiscue_parse_action(command,&action)) {respond(command,EISCUE_ARGUMENT,0);return 0;}
    if (command[1]==EISCUE_STOP) {
        ble_npl_callout_stop(&release_timer);
        if (active) {active=false;respond(pending.command,EISCUE_SEND_FAILED,pending.emitted);}
        uint8_t emitted=0,status=EISCUE_SENT;
        for (unsigned i=0;i<action.count;i++) {
            if (!report_subscribed(action.reports[i].kind)) continue;
            uint8_t result=emit(&action.reports[i]);
            if (result==EISCUE_SENT) emitted++;else status=result;
        }
        memset(mouse_state,0,sizeof mouse_state);memset(keyboard_state,0,sizeof keyboard_state);
        // STOP doubles as the encrypted GATT handshake. No subscribed HID
        // channel means zero reports, not a claim of input readiness.
        respond(command,status,emitted);
        if (status!=EISCUE_SENT && connection!=BLE_HS_CONN_HANDLE_NONE)
            (void)ble_gap_terminate(connection,BLE_ERR_REM_USER_CONN_TERM);
        return 0;
    }
    if (active) {respond(command,EISCUE_BUSY,0);return 0;}
    if (!response_subscribed) {respond(command,EISCUE_NOT_SUBSCRIBED,0);return 0;}
    uint8_t status=emit(&action.reports[0]);
    if (status!=EISCUE_SENT) {respond(command,status,0);return 0;}
    if (action.count==1) {respond(command,EISCUE_SENT,1);return 0;}
    memcpy(pending.command,command,sizeof command);pending.action=action;pending.emitted=1;active=true;
    int rc=ble_npl_callout_reset(&release_timer,ble_npl_time_ms_to_ticks32(25));
    if (rc) {
        active=false;bool released=release_all();respond(command,EISCUE_SEND_FAILED,1);
        if (!released) (void)ble_gap_terminate(connection,BLE_ERR_REM_USER_CONN_TERM);
    }
    return 0;
}
static int access(uint16_t conn,uint16_t attribute,struct ble_gatt_access_ctxt *ctx,void *arg) {
    (void)attribute;
    enum attribute_kind kind=(enum attribute_kind)(uintptr_t)arg;
    const uint8_t hid_info[]={0x11,0x01,0x00,0x02}; // HID 1.11, normally connectable.
    const uint8_t mouse_ref[]={1,1},keyboard_ref[]={2,1};
    const uint8_t pnp[]={1,0xFF,0xFF,1,0,1,0}; // Experimental identity, no claimed vendor registration.
    const void *bytes=NULL;unsigned length=0;
    if (ctx->op==BLE_GATT_ACCESS_OP_WRITE_CHR) {
        if (kind==CUSTOM_COMMAND) return control_write(conn,ctx->om);
        uint8_t value;
        if (OS_MBUF_PKTLEN(ctx->om)!=1 || os_mbuf_copydata(ctx->om,0,1,&value)) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        if (kind==BOOT_KEYBOARD_OUTPUT) return 0; // LED output is not device input.
        if (value>1) return BLE_ATT_ERR_UNLIKELY;
        if (kind==HID_CONTROL) {
            if (value==0) interrupt_and_release();
            suspended=value==0;return 0;
        }
        // Release on the OLD report/protocol channel before changing mode.
        if (kind==HID_PROTOCOL) {interrupt_and_release();protocol_mode=value;return 0;}
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }
    switch(kind) {
    case HID_INFO:bytes=hid_info;length=sizeof hid_info;break;
    case HID_MAP:bytes=report_map;length=sizeof report_map;break;
    case HID_PROTOCOL:bytes=&protocol_mode;length=1;break;
    case HID_MOUSE:bytes=mouse_state;length=sizeof mouse_state;break;
    case HID_KEYBOARD:bytes=keyboard_state;length=sizeof keyboard_state;break;
    case BOOT_MOUSE:bytes=mouse_state;length=3;break;
    case BOOT_KEYBOARD:bytes=keyboard_state;length=8;break;
    case BOOT_KEYBOARD_OUTPUT: {static const uint8_t zero=0;bytes=&zero;length=1;break;}
    case HID_MOUSE_REF:bytes=mouse_ref;length=2;break;
    case HID_KEYBOARD_REF:bytes=keyboard_ref;length=2;break;
    case CUSTOM_RESPONSE:bytes=last_response;length=sizeof last_response;break;
    case MANUFACTURER:bytes="Eiscue development";length=strlen(bytes);break;
    case PNP_ID:bytes=pnp;length=sizeof pnp;break;
    case BATTERY_LEVEL: {
        // HOGP requires BAS. This USB-powered laboratory prototype reports a
        // FIXED TEST VALUE, not a measured battery percentage. Do not expose
        // it as product SOC; the Passport fuel gauge is not initialized here.
        static const uint8_t usb_test_level=100;bytes=&usb_test_level;length=1;break;
    }
    default:return BLE_ATT_ERR_READ_NOT_PERMITTED;
    }
    return os_mbuf_append(ctx->om,bytes,length)==0?0:BLE_ATT_ERR_INSUFFICIENT_RES;
}
#define SECURE_READ (BLE_GATT_CHR_F_READ|BLE_GATT_CHR_F_READ_ENC)
#define INPUT_FLAGS (SECURE_READ|BLE_GATT_CHR_F_NOTIFY|BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC)
static const struct ble_gatt_svc_def services[]={
    {.type=BLE_GATT_SVC_TYPE_PRIMARY,.uuid=BLE_UUID16_DECLARE(0x1812),.characteristics=(struct ble_gatt_chr_def[]){
        {.uuid=BLE_UUID16_DECLARE(0x2A4A),.access_cb=access,.arg=(void *)HID_INFO,.flags=SECURE_READ},
        {.uuid=BLE_UUID16_DECLARE(0x2A4B),.access_cb=access,.arg=(void *)HID_MAP,.flags=SECURE_READ},
        {.uuid=BLE_UUID16_DECLARE(0x2A4C),.access_cb=access,.arg=(void *)HID_CONTROL,.flags=BLE_GATT_CHR_F_WRITE_NO_RSP|BLE_GATT_CHR_F_WRITE_ENC},
        {.uuid=BLE_UUID16_DECLARE(0x2A4E),.access_cb=access,.arg=(void *)HID_PROTOCOL,.flags=SECURE_READ|BLE_GATT_CHR_F_WRITE_NO_RSP|BLE_GATT_CHR_F_WRITE_ENC},
        {.uuid=BLE_UUID16_DECLARE(0x2A4D),.access_cb=access,.arg=(void *)HID_MOUSE,.flags=INPUT_FLAGS,.val_handle=&mouse_handle,
            .descriptors=(struct ble_gatt_dsc_def[]){{.uuid=BLE_UUID16_DECLARE(0x2908),.att_flags=BLE_ATT_F_READ,.access_cb=access,.arg=(void *)HID_MOUSE_REF},{0}}},
        {.uuid=BLE_UUID16_DECLARE(0x2A4D),.access_cb=access,.arg=(void *)HID_KEYBOARD,.flags=INPUT_FLAGS,.val_handle=&keyboard_handle,
            .descriptors=(struct ble_gatt_dsc_def[]){{.uuid=BLE_UUID16_DECLARE(0x2908),.att_flags=BLE_ATT_F_READ,.access_cb=access,.arg=(void *)HID_KEYBOARD_REF},{0}}},
        {.uuid=BLE_UUID16_DECLARE(0x2A33),.access_cb=access,.arg=(void *)BOOT_MOUSE,.flags=INPUT_FLAGS,.val_handle=&boot_mouse_handle},
        {.uuid=BLE_UUID16_DECLARE(0x2A22),.access_cb=access,.arg=(void *)BOOT_KEYBOARD,.flags=INPUT_FLAGS,.val_handle=&boot_keyboard_handle},
        {.uuid=BLE_UUID16_DECLARE(0x2A32),.access_cb=access,.arg=(void *)BOOT_KEYBOARD_OUTPUT,.flags=SECURE_READ|BLE_GATT_CHR_F_WRITE|BLE_GATT_CHR_F_WRITE_NO_RSP|BLE_GATT_CHR_F_WRITE_ENC},
        {0}}},
    {.type=BLE_GATT_SVC_TYPE_PRIMARY,.uuid=&service_uuid.u,.characteristics=(struct ble_gatt_chr_def[]){
        {.uuid=&command_uuid.u,.access_cb=access,.arg=(void *)CUSTOM_COMMAND,.flags=BLE_GATT_CHR_F_WRITE|BLE_GATT_CHR_F_WRITE_ENC},
        {.uuid=&response_uuid.u,.access_cb=access,.arg=(void *)CUSTOM_RESPONSE,.flags=INPUT_FLAGS,.val_handle=&response_handle},
        {0}}},
    {.type=BLE_GATT_SVC_TYPE_PRIMARY,.uuid=BLE_UUID16_DECLARE(0x180A),.characteristics=(struct ble_gatt_chr_def[]){
        {.uuid=BLE_UUID16_DECLARE(0x2A29),.access_cb=access,.arg=(void *)MANUFACTURER,.flags=BLE_GATT_CHR_F_READ},
        {.uuid=BLE_UUID16_DECLARE(0x2A50),.access_cb=access,.arg=(void *)PNP_ID,.flags=BLE_GATT_CHR_F_READ},{0}}},
    {.type=BLE_GATT_SVC_TYPE_PRIMARY,.uuid=BLE_UUID16_DECLARE(0x180F),.characteristics=(struct ble_gatt_chr_def[]){
        {.uuid=BLE_UUID16_DECLARE(0x2A19),.access_cb=access,.arg=(void *)BATTERY_LEVEL,.flags=BLE_GATT_CHR_F_READ},{0}}},
    {0}
};
int eiscue_ble_services_init(void) {
    ble_npl_callout_init(&release_timer,nimble_port_get_dflt_eventq(),finish_later,NULL);
    int rc=ble_gatts_count_cfg(services);return rc?rc:ble_gatts_add_svcs(services);
}
void eiscue_ble_on_connect(uint16_t conn) {
    connection=conn;protocol_mode=1;suspended=false;active=false;seen_request=false;
    mouse_subscribed=keyboard_subscribed=response_subscribed=boot_mouse_subscribed=boot_keyboard_subscribed=false;
    memset(mouse_state,0,sizeof mouse_state);memset(keyboard_state,0,sizeof keyboard_state);
    const uint8_t stop[EISCUE_COMMAND_SIZE]={1,EISCUE_STOP};respond(stop,EISCUE_INSECURE,0);
}
void eiscue_ble_on_disconnect(void) {
    ble_npl_callout_stop(&release_timer);active=false;
    memset(mouse_state,0,sizeof mouse_state);memset(keyboard_state,0,sizeof keyboard_state);
    connection=BLE_HS_CONN_HANDLE_NONE;seen_request=false;
    mouse_subscribed=keyboard_subscribed=response_subscribed=boot_mouse_subscribed=boot_keyboard_subscribed=false;
    // No report can be sent after disconnection; terminating HID transport
    // releases its host state. All local pending/pressed state is discarded.
}
void eiscue_ble_on_subscribe(uint16_t attribute,int enabled) {
    bool affected=active && attribute==report_handle(pending.action.reports[0].kind);
    if(attribute==report_handle(EISCUE_MOUSE_REPORT) && mouse_state[0]) affected=true;
    if(attribute==report_handle(EISCUE_KEYBOARD_REPORT))
        for(unsigned i=0;i<sizeof keyboard_state;i++)if(keyboard_state[i])affected=true;
    if(attribute==mouse_handle)mouse_subscribed=enabled;
    else if(attribute==keyboard_handle)keyboard_subscribed=enabled;
    else if(attribute==response_handle)response_subscribed=enabled;
    else if(attribute==boot_mouse_handle)boot_mouse_subscribed=enabled;
    else if(attribute==boot_keyboard_handle)boot_keyboard_subscribed=enabled;
    ESP_LOGI(TAG,"subscription kind=%s enabled=%d",attribute==mouse_handle?"mouse":attribute==keyboard_handle?"keyboard":attribute==response_handle?"response":"boot",enabled);
    if(!enabled && affected && connection!=BLE_HS_CONN_HANDLE_NONE) {
        // Once CCCD is disabled a release cannot be delivered on that channel.
        // Disconnect this HID transport instead of leaving an input held.
        ble_npl_callout_stop(&release_timer);
        if(active){active=false;respond(pending.command,EISCUE_SEND_FAILED,pending.emitted);}
        (void)ble_gap_terminate(connection,BLE_ERR_REM_USER_CONN_TERM);
    } else if(!enabled && attribute==response_handle && active) interrupt_and_release();
}
void eiscue_ble_on_security_change(void) {
    ESP_LOGI(TAG,"encryption+bond=%d",secure_connection());
    if(!secure_connection()){
        bool held=active || mouse_state[0]!=0;
        for(unsigned i=0;i<sizeof keyboard_state;i++) if(keyboard_state[i])held=true;
        ble_npl_callout_stop(&release_timer);active=false;
        memset(mouse_state,0,sizeof mouse_state);memset(keyboard_state,0,sizeof keyboard_state);
        // An unencrypted link cannot transmit a release. Revoke the HID
        // transport itself if a report could still hold an input down.
        if(held && connection!=BLE_HS_CONN_HANDLE_NONE)
            (void)ble_gap_terminate(connection,BLE_ERR_REM_USER_CONN_TERM);
    }
}
