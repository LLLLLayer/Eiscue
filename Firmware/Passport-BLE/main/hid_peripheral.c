// SPDX-License-Identifier: Apache-2.0
// Original minimal HOGP + encrypted GATT peripheral. HID byte layouts follow
// USB HID Usage Tables; NimBLE registration/callout APIs are from ESP-IDF.
#include "hid_peripheral.h"
#include "command_protocol.h"
#include "hid_descriptors.h"
#include "usb_hid.h"
#include "board_auth.h"
#if CONFIG_IDF_TARGET_ESP32C3
#include "companion.h"
#endif
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
#if BOARD_AUTH_REQUIRED
static const ble_uuid128_t challenge_uuid=BLE_UUID128_INIT(
    0xB6,0x3A,0x64,0x23,0xE6,0x70,0x1D,0x95,0x84,0x4E,0xE8,0x41,0x9A,0x4E,0x07,0x74);
static const ble_uuid128_t auth_uuid=BLE_UUID128_INIT(
    0xB7,0x3A,0x64,0x23,0xE6,0x70,0x1D,0x95,0x84,0x4E,0xE8,0x41,0x9A,0x4E,0x07,0x74);
static uint16_t auth_handle;
static bool auth_subscribed;
#endif
#if CONFIG_IDF_TARGET_ESP32C3
static const ble_uuid128_t companion_uuid=BLE_UUID128_INIT(
    0xB8,0x3A,0x64,0x23,0xE6,0x70,0x1D,0x95,0x84,0x4E,0xE8,0x41,0x9A,0x4E,0x07,0x74);
static const ble_uuid128_t companion_stop_uuid=BLE_UUID128_INIT(
    0xB9,0x3A,0x64,0x23,0xE6,0x70,0x1D,0x95,0x84,0x4E,0xE8,0x41,0x9A,0x4E,0x07,0x74);
static uint16_t companion_stop_handle;
static bool companion_stop_subscribed,unlock_after_disconnect;
static struct ble_npl_event companion_stop_event,companion_unlock_event;
#endif

// Report ID 1: buttons + relative X/Y/wheel (4 bytes).
// Report ID 2: boot-compatible 6-key keyboard (8 bytes).
// Report ID 3: left button + absolute X/Y, each 0...32767 (5 bytes).
// HOGP Report Reference descriptors identify each characteristic, therefore
// notifications contain report data only, without a prefixed report ID.
static const uint8_t report_map[]={
    EISCUE_MOUSE_DESCRIPTOR,
    EISCUE_KEYBOARD_DESCRIPTOR,
    EISCUE_ABSOLUTE_DESCRIPTOR
};
enum attribute_kind { HID_INFO=1,HID_MAP,HID_CONTROL,HID_PROTOCOL,
    HID_MOUSE,HID_KEYBOARD,HID_MOUSE_REF,HID_KEYBOARD_REF,CUSTOM_COMMAND,CUSTOM_RESPONSE,
    BOOT_MOUSE,BOOT_KEYBOARD,BOOT_KEYBOARD_OUTPUT,MANUFACTURER,PNP_ID,BATTERY_LEVEL,
    HID_ABSOLUTE,HID_ABSOLUTE_REF,AUTH_CHALLENGE,AUTH_PROOF,COMPANION_STATUS,COMPANION_STOP_STATE };
static uint16_t connection=BLE_HS_CONN_HANDLE_NONE;
static uint16_t subscription_connection=BLE_HS_CONN_HANDLE_NONE;
static uint16_t mouse_handle,keyboard_handle,absolute_handle,response_handle,boot_mouse_handle,boot_keyboard_handle;
static bool mouse_subscribed,keyboard_subscribed,absolute_subscribed,response_subscribed,boot_mouse_subscribed,boot_keyboard_subscribed;
static bool suspended;
static uint8_t protocol_mode=1;
static uint8_t output=EISCUE_OUTPUT_BLE;
static uint8_t mouse_state[4],keyboard_state[8],absolute_state[5];
static uint8_t last_response[BOARD_AUTH_REPLY_SIZE]={1,0,0,0,EISCUE_INSECURE,0,0,0};
static unsigned last_response_length=EISCUE_RESPONSE_SIZE;
static uint32_t command_sequence;
static struct ble_npl_callout release_timer,held_timer,relative_held_timer;
#define ABSOLUTE_HOLD_MS 250
static ble_npl_time_t relative_hold_until;
static bool active,seen_request;
static uint16_t last_request;
static struct {
    uint8_t command[EISCUE_COMMAND_SIZE],emitted,stroke_step;
    uint32_t sequence;
    ble_npl_time_t due,planned_due,last_report_at,stroke_deadline;
    eiscue_action action;
} pending;

static bool secure_connection(void) {
    struct ble_gap_conn_desc desc;
    return connection!=BLE_HS_CONN_HANDLE_NONE && ble_gap_conn_find(connection,&desc)==0 &&
        desc.sec_state.encrypted && desc.sec_state.bonded;
}
static void respond_at_sequence(const uint8_t *command,uint8_t status,uint8_t emitted,uint32_t sequence) {
    uint8_t inner[EISCUE_RESPONSE_SIZE];
    eiscue_make_response(command,status,emitted,secure_connection(),inner);
#if BOARD_AUTH_REQUIRED
    if(!board_auth_wrap_reply(inner,sequence,last_response))return;
    last_response_length=BOARD_AUTH_REPLY_SIZE;
#else
    (void)sequence;
    memcpy(last_response,inner,sizeof inner);last_response_length=sizeof inner;
#endif
    if (response_subscribed && secure_connection()) {
        struct os_mbuf *mbuf=ble_hs_mbuf_from_flat(last_response,last_response_length);
        if (mbuf) (void)ble_gatts_notify_custom(connection,response_handle,mbuf);
    }
    ESP_LOGI(TAG,"command op=%u id=%u status=%u value=%u secure=%u",
        command[1],(unsigned)((uint16_t)command[2]|((uint16_t)command[3]<<8)),status,emitted,inner[6]);
}
static void respond(const uint8_t *command,uint8_t status,uint8_t emitted) {respond_at_sequence(command,status,emitted,command_sequence);}
static uint16_t report_handle(uint8_t kind) {
    if (kind==EISCUE_ABSOLUTE_REPORT) return absolute_handle;
    if (kind==EISCUE_MOUSE_REPORT) return protocol_mode==1?mouse_handle:boot_mouse_handle;
    return protocol_mode==1?keyboard_handle:boot_keyboard_handle;
}
static bool report_subscribed(uint8_t kind) {
    if(output==EISCUE_OUTPUT_USB)return eiscue_usb_hid_online();
    if (kind==EISCUE_ABSOLUTE_REPORT) return protocol_mode==1 && absolute_subscribed;
    if (kind==EISCUE_MOUSE_REPORT) return protocol_mode==1?mouse_subscribed:boot_mouse_subscribed;
    return protocol_mode==1?keyboard_subscribed:boot_keyboard_subscribed;
}
static uint8_t *report_state(uint8_t kind) {
    if (kind==EISCUE_ABSOLUTE_REPORT) return absolute_state;
    return kind==EISCUE_MOUSE_REPORT?mouse_state:keyboard_state;
}
static uint8_t notify_report(const eiscue_report *report,uint16_t handle,uint8_t length) {
    if (!secure_connection()) return EISCUE_INSECURE;
    struct os_mbuf *mbuf=ble_hs_mbuf_from_flat(report->bytes,length);
    if (!mbuf) return EISCUE_SEND_FAILED;
    int rc=ble_gatts_notify_custom(connection,handle,mbuf);
    if (rc) return EISCUE_SEND_FAILED;
    memcpy(report_state(report->kind),report->bytes,report->length);
    return EISCUE_SENT;
}
static uint8_t emit(const eiscue_report *report) {
    if (!secure_connection()) return EISCUE_INSECURE;
#if CONFIG_IDF_TARGET_ESP32C3
    if(companion_input_stopped())return EISCUE_SEND_FAILED;
#endif
#if BOARD_AUTH_REQUIRED
    if(!board_auth_is_authenticated())return EISCUE_AUTH_REQUIRED;
#endif
    if(output==EISCUE_OUTPUT_USB) {
        uint8_t status=eiscue_usb_hid_send(report);
        if(status==EISCUE_SENT)memcpy(report_state(report->kind),report->bytes,report->length);
        return status;
    }
    if (!report_subscribed(report->kind) || suspended) return EISCUE_NOT_SUBSCRIBED;
    uint8_t length=report->length;
    if (protocol_mode==0 && report->kind==EISCUE_MOUSE_REPORT) length=3;
    return notify_report(report,report_handle(report->kind),length);
}
static eiscue_report absolute_release(void) {
    eiscue_report report={.kind=EISCUE_ABSOLUTE_REPORT,.length=sizeof absolute_state};
    memcpy(report.bytes,absolute_state,sizeof absolute_state);report.bytes[0]=0;
    return report;
}
static uint8_t release_all(uint8_t *emitted) {
    ble_npl_callout_stop(&held_timer);
    ble_npl_callout_stop(&relative_held_timer);
    const eiscue_report mouse={.kind=EISCUE_MOUSE_REPORT,.length=4};
    const eiscue_report keyboard={.kind=EISCUE_KEYBOARD_REPORT,.length=8};
    const eiscue_report absolute=absolute_release();
    if(output==EISCUE_OUTPUT_USB) {
        uint8_t status=EISCUE_SENT;
        if(emitted)*emitted=0;
        if(eiscue_usb_hid_online()) {
            const eiscue_report *reports[]={&mouse,&keyboard,&absolute};
            for(unsigned i=0;i<sizeof reports/sizeof reports[0];i++) {
                uint8_t result=eiscue_usb_hid_send(reports[i]);
                if(result!=EISCUE_SENT)status=result;
                else if(emitted)(*emitted)++;
            }
        } else eiscue_usb_hid_revoke();
        if(status!=EISCUE_SENT)eiscue_usb_hid_revoke();
        memset(mouse_state,0,sizeof mouse_state);memset(keyboard_state,0,sizeof keyboard_state);absolute_state[0]=0;
        return status;
    }
    // Only release subscribed channels; never manufacture a success for a
    // channel the OS did not discover. Include both report and boot channels
    // even if the host changed protocol mode while retaining subscriptions.
    const struct {bool subscribed;uint16_t handle;const eiscue_report *report;uint8_t length;} channels[]={
        {mouse_subscribed,mouse_handle,&mouse,4},
        {keyboard_subscribed,keyboard_handle,&keyboard,8},
        {absolute_subscribed,absolute_handle,&absolute,5},
        {boot_mouse_subscribed,boot_mouse_handle,&mouse,3},
        {boot_keyboard_subscribed,boot_keyboard_handle,&keyboard,8}
    };
    uint8_t status=EISCUE_SENT;
    if(emitted)*emitted=0;
    for(unsigned i=0;i<sizeof channels/sizeof channels[0];i++) {
        if(!channels[i].subscribed)continue;
        uint8_t result=notify_report(channels[i].report,channels[i].handle,channels[i].length);
        if(result!=EISCUE_SENT)status=result;
        else if(emitted)(*emitted)++;
    }
    memset(mouse_state,0,sizeof mouse_state);memset(keyboard_state,0,sizeof keyboard_state);
    absolute_state[0]=0;
    return status;
}
static void revoke_connection(void) {
    if(output==EISCUE_OUTPUT_USB)eiscue_usb_hid_revoke();
#if BOARD_AUTH_REQUIRED
    board_auth_end_connection();
#endif
    if(connection!=BLE_HS_CONN_HANDLE_NONE)(void)ble_gap_terminate(connection,BLE_ERR_REM_USER_CONN_TERM);
}
static void interrupt_and_release(void) {
    ble_npl_callout_stop(&release_timer);
    if (active) {active=false;respond_at_sequence(pending.command,EISCUE_SEND_FAILED,pending.emitted,pending.sequence);}
    if (release_all(NULL)!=EISCUE_SENT && connection!=BLE_HS_CONN_HANDLE_NONE)
        revoke_connection();
}
#if CONFIG_IDF_TARGET_ESP32C3
static void notify_companion_stop(void) {
    if(!companion_stop_subscribed || !secure_connection())return;
    uint8_t bytes[COMPANION_STOP_SIZE];companion_read_stop(bytes);
    struct os_mbuf *mbuf=ble_hs_mbuf_from_flat(bytes,sizeof bytes);
    if(mbuf)(void)ble_gatts_notify_custom(connection,companion_stop_handle,mbuf);
}
static void companion_key_event(struct ble_npl_event *event) {
    interrupt_and_release();
    if(event==&companion_unlock_event) {
        // Keep input blocked until the physical link ends. A failed terminate
        // cannot reopen input with the phone's previous calibration intact.
        if(connection==BLE_HS_CONN_HANDLE_NONE)companion_host_unlock();
        else {
            unlock_after_disconnect=true;
            if(ble_gap_terminate(connection,BLE_ERR_REM_USER_CONN_TERM)!=0)unlock_after_disconnect=false;
        }
    } else notify_companion_stop();
}
void eiscue_ble_companion_stop(int unlock) {
    ble_npl_eventq_put(nimble_port_get_dflt_eventq(),unlock?&companion_unlock_event:&companion_stop_event);
}
#endif
static void expire_hold(struct ble_npl_event *event) {
    (void)event;
    if(!absolute_state[0])return;
    const eiscue_report release=absolute_release();
    ESP_LOGW(TAG,"absolute button hold expired after %u ms",ABSOLUTE_HOLD_MS);
    if(emit(&release)!=EISCUE_SENT) {
        interrupt_and_release();
        if(connection!=BLE_HS_CONN_HANDLE_NONE)
            revoke_connection();
    }
}
static bool update_relative_hold(void) {
    ble_npl_callout_stop(&relative_held_timer);
    if(!mouse_state[0])return true;
    ble_npl_time_t delay=ble_npl_time_ms_to_ticks32(ABSOLUTE_HOLD_MS);
    relative_hold_until=ble_npl_time_get()+delay;
    return ble_npl_callout_reset(&relative_held_timer,delay)==0;
}
static void expire_relative_hold(struct ble_npl_event *event) {
    (void)event;
    if(!mouse_state[0])return;
    int32_t remaining=(int32_t)(relative_hold_until-ble_npl_time_get());
    if(remaining>0) {
        if(ble_npl_callout_reset(&relative_held_timer,(ble_npl_time_t)remaining)==0)return;
    }
    ESP_LOGW(TAG,"relative button hold expired after %u ms",ABSOLUTE_HOLD_MS);
    interrupt_and_release();
}
static int schedule_pending(uint16_t milliseconds) {
    ble_npl_time_t delay=ble_npl_time_ms_to_ticks32(milliseconds);
    pending.due=ble_npl_time_get()+delay;
    pending.planned_due=pending.due;
    return ble_npl_callout_reset(&release_timer,delay);
}
static int advance_stroke(uint16_t milliseconds) {
    pending.planned_due+=ble_npl_time_ms_to_ticks32(milliseconds);
    int32_t remaining=(int32_t)(pending.planned_due-ble_npl_time_get());
    ble_npl_time_t minimum=ble_npl_time_ms_to_ticks32(8);
    // Keep cumulative deadlines without a burst of catch-up input after a
    // delayed host-queue turn. A stalled trajectory is aborted, never replayed.
    if(remaining<(int32_t)minimum)remaining=(int32_t)minimum;
    pending.due=ble_npl_time_get()+(ble_npl_time_t)remaining;
    return ble_npl_callout_reset(&release_timer,(ble_npl_time_t)remaining);
}
static void finish_pending(uint8_t status) {
    active=false;
    respond_at_sequence(pending.command,status,pending.emitted,pending.sequence);
    if(status!=EISCUE_SENT && release_all(NULL)!=EISCUE_SENT && connection!=BLE_HS_CONN_HANDLE_NONE)
        revoke_connection();
}
static void finish_later(struct ble_npl_event *event) {
    (void)event;
    if (!active) return;
    // A stopped callout may already be queued. It cannot advance a newer
    // command before that command's own next report is due.
    int32_t remaining=(int32_t)(pending.due-ble_npl_time_get());
    if(remaining>0) {
        if(ble_npl_callout_reset(&release_timer,(ble_npl_time_t)remaining))finish_pending(EISCUE_SEND_FAILED);
        return;
    }
    if(pending.action.stroke.steps &&
       ((int32_t)(ble_npl_time_get()-pending.stroke_deadline)>0 ||
        ble_npl_time_get()-pending.last_report_at>ble_npl_time_ms_to_ticks32(50))) {
        finish_pending(EISCUE_SEND_FAILED);return;
    }
    if(pending.action.stroke.steps && pending.stroke_step<pending.action.stroke.steps) {
        eiscue_report report;
        if(!eiscue_stroke_report(&pending.action.stroke,pending.stroke_step+1,&report)) {
            finish_pending(EISCUE_SEND_FAILED);return;
        }
        uint8_t status=emit(&report);
        if(status==EISCUE_SENT){pending.emitted++;pending.stroke_step++;pending.last_report_at=ble_npl_time_get();}
        if(status!=EISCUE_SENT || !update_relative_hold()) {
            finish_pending(status==EISCUE_SENT?EISCUE_SEND_FAILED:status);return;
        }
        // Give the USB interrupt endpoint a poll turn before the final UP.
        uint16_t interval=eiscue_stroke_interval(&pending.action.stroke,pending.stroke_step+1);
        if(advance_stroke(interval))finish_pending(EISCUE_SEND_FAILED);
        return;
    }
    uint8_t status=emit(&pending.action.reports[1]);
    if (status==EISCUE_SENT) pending.emitted++;
    if(pending.action.reports[1].kind==EISCUE_MOUSE_REPORT && !update_relative_hold())status=EISCUE_SEND_FAILED;
    finish_pending(status);
}
static int control_write(uint16_t conn,const struct os_mbuf *om) {
    uint8_t command[EISCUE_COMMAND_SIZE];
#if BOARD_AUTH_REQUIRED
    uint8_t envelope[BOARD_AUTH_COMMAND_SIZE];
    if(conn!=connection || !secure_connection()) {
        interrupt_and_release();revoke_connection();return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
    }
    if(OS_MBUF_PKTLEN(om)!=sizeof envelope || os_mbuf_copydata(om,0,sizeof envelope,envelope) ||
        !board_auth_unwrap_command(envelope,sizeof envelope,command,&command_sequence)) {
        interrupt_and_release();board_auth_end_connection();
        revoke_connection();
        return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
    }
#else
    if (OS_MBUF_PKTLEN(om)!=sizeof command || os_mbuf_copydata(om,0,sizeof command,command)) {
        interrupt_and_release();return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    if (conn!=connection || !secure_connection()) {
        interrupt_and_release();revoke_connection();return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
    }
#endif
    uint16_t request=(uint16_t)command[2]|((uint16_t)command[3]<<8);
    uint16_t delta=(uint16_t)(request-last_request);
    if (seen_request && (delta==0 || delta>32767)) {
        // At most once per connection. A lost acknowledgement never replays
        // input. The App must observe UI effects rather than retry clicks.
        interrupt_and_release();respond(command,EISCUE_ARGUMENT,0);return 0;
    }
    seen_request=true;last_request=request;
    eiscue_action action;
    if (!eiscue_parse_action(command,&action)) {interrupt_and_release();respond(command,EISCUE_ARGUMENT,0);return 0;}
#if CONFIG_IDF_TARGET_ESP32C3
    if(!companion_accepts_command(command[1])){interrupt_and_release();respond(command,EISCUE_SEND_FAILED,0);return 0;}
#endif
    if (command[1]==EISCUE_STOP) {
        ble_npl_callout_stop(&release_timer);
        if (active) {active=false;respond_at_sequence(pending.command,EISCUE_SEND_FAILED,pending.emitted,pending.sequence);}
        uint8_t emitted=0,status=release_all(&emitted);
        // STOP doubles as the encrypted GATT handshake. No subscribed HID
        // channel means zero reports, not a claim of input readiness.
        respond(command,status,emitted);
        if (status!=EISCUE_SENT && connection!=BLE_HS_CONN_HANDLE_NONE)
            revoke_connection();
        return 0;
    }
    if(command[1]==EISCUE_INFO) {
        uint8_t capabilities=EISCUE_CAP_OUTPUT_SELECTION|EISCUE_CAP_RELATIVE_STROKE;
#if CONFIG_IDF_TARGET_ESP32C3
        if(companion_input_stopped()){respond(command,EISCUE_SENT,capabilities);return 0;}
#endif
        if((output==EISCUE_OUTPUT_USB || !suspended) && report_subscribed(EISCUE_ABSOLUTE_REPORT))capabilities|=1;
        if((output==EISCUE_OUTPUT_USB || !suspended) && report_subscribed(EISCUE_KEYBOARD_REPORT))capabilities|=2;
        if(output==EISCUE_OUTPUT_USB?eiscue_usb_hid_relative_ready():!suspended && report_subscribed(EISCUE_MOUSE_REPORT))
            capabilities|=EISCUE_CAP_RELATIVE_READY;
        respond(command,EISCUE_SENT,capabilities);return 0;
    }
    if(command[1]==EISCUE_QUERY_OUTPUT) {
        uint8_t value=output==EISCUE_OUTPUT_USB?1:0;
        if(eiscue_usb_hid_supported())value|=2;
        if(eiscue_usb_hid_mounted())value|=4;
#if CONFIG_IDF_TARGET_ESP32S3
        value|=8;
#endif
        value|=16;
        respond(command,EISCUE_SENT,value);return 0;
    }
    if(command[1]==EISCUE_SELECT_OUTPUT) {
        bool held=mouse_state[0] || absolute_state[0];
        for(unsigned i=0;i<sizeof keyboard_state;i++)if(keyboard_state[i])held=true;
        if(active || held){respond(command,EISCUE_BUSY,0);return 0;}
        if(command[4]==EISCUE_OUTPUT_USB && !eiscue_usb_hid_supported()) {
            respond(command,EISCUE_NOT_SUBSCRIBED,0);return 0;
        }
        // Selecting an output is explicit even if the cable is absent. INFO
        // reports readiness only after that host enumerates the USB device.
        if(release_all(NULL)!=EISCUE_SENT){respond(command,EISCUE_SEND_FAILED,0);return 0;}
        output=command[4];eiscue_usb_hid_select(output==EISCUE_OUTPUT_USB);
        respond(command,EISCUE_SENT,0);return 0;
    }
    if (active) {respond(command,EISCUE_BUSY,0);return 0;}
    if(command[1]==EISCUE_RELATIVE_STROKE && (mouse_state[0] || absolute_state[0])) {
        respond(command,EISCUE_BUSY,0);return 0;
    }
    if (!response_subscribed) {respond(command,EISCUE_NOT_SUBSCRIBED,0);return 0;}
    uint8_t status=emit(&action.reports[0]);
    if (status!=EISCUE_SENT) {
        // A failed absolute update must not extend an earlier drag. Try a
        // release immediately; the watchdog remains a second line of defense.
        if((command[1]==EISCUE_ABS_POINT && absolute_state[0]) || command[1]==EISCUE_RELATIVE_STROKE)interrupt_and_release();
        respond(command,status,0);return 0;
    }
    if(command[1]==EISCUE_ABS_POINT) {
        ble_npl_callout_stop(&held_timer);
        if(absolute_state[0] && ble_npl_callout_reset(&held_timer,ble_npl_time_ms_to_ticks32(ABSOLUTE_HOLD_MS))) {
            interrupt_and_release();respond(command,EISCUE_SEND_FAILED,1);return 0;
        }
    }
    if(action.reports[0].kind==EISCUE_MOUSE_REPORT && !update_relative_hold()) {
        interrupt_and_release();respond(command,EISCUE_SEND_FAILED,1);return 0;
    }
    if (action.count==1) {respond(command,EISCUE_SENT,1);return 0;}
    memcpy(pending.command,command,sizeof command);pending.action=action;pending.emitted=1;pending.stroke_step=0;
    pending.sequence=command_sequence;pending.last_report_at=ble_npl_time_get();active=true;
    pending.stroke_deadline=pending.last_report_at+ble_npl_time_ms_to_ticks32(action.stroke.duration_ms+8+50);
    int rc=schedule_pending(action.stroke.steps?eiscue_stroke_interval(&action.stroke,1):25);
    if (rc) {
        active=false;uint8_t released=release_all(NULL);respond(command,EISCUE_SEND_FAILED,1);
        if (released!=EISCUE_SENT) revoke_connection();
    }
    return 0;
}
static int access(uint16_t conn,uint16_t attribute,struct ble_gatt_access_ctxt *ctx,void *arg) {
    (void)attribute;
    enum attribute_kind kind=(enum attribute_kind)(uintptr_t)arg;
    const uint8_t hid_info[]={0x11,0x01,0x00,0x02}; // HID 1.11, normally connectable.
    const uint8_t mouse_ref[]={1,1},keyboard_ref[]={2,1},absolute_ref[]={3,1};
    const uint8_t pnp[]={1,0xFF,0xFF,1,0,1,0}; // Experimental identity, no claimed vendor registration.
    const void *bytes=NULL;unsigned length=0;
    if (ctx->op==BLE_GATT_ACCESS_OP_WRITE_CHR) {
        if (kind==CUSTOM_COMMAND) return control_write(conn,ctx->om);
#if CONFIG_IDF_TARGET_ESP32C3
        if(kind==COMPANION_STATUS) {
            if(conn!=connection || !secure_connection())return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
            uint8_t value[COMPANION_STATUS_SIZE];
            if(OS_MBUF_PKTLEN(ctx->om)!=sizeof value || os_mbuf_copydata(ctx->om,0,sizeof value,value))
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            return companion_update_status(value,sizeof value)?0:BLE_ATT_ERR_VALUE_NOT_ALLOWED;
        }
#endif
#if BOARD_AUTH_REQUIRED
        if(kind==AUTH_PROOF) {
            uint8_t request[BOARD_AUTH_REQUEST_SIZE],reply[BOARD_AUTH_RESPONSE_SIZE];
            bool held=mouse_state[0] || absolute_state[0];
            for(unsigned i=0;i<sizeof keyboard_state;i++)if(keyboard_state[i])held=true;
            if(conn!=connection || !secure_connection())return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
            if(active || held || !auth_subscribed || OS_MBUF_PKTLEN(ctx->om)!=sizeof request ||
                os_mbuf_copydata(ctx->om,0,sizeof request,request) ||
                !board_auth_handle_request(request,sizeof request,reply)) {
                interrupt_and_release();board_auth_end_connection();
                revoke_connection();
                return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
            }
            struct os_mbuf *ack=ble_hs_mbuf_from_flat(reply,sizeof reply);
            if(!ack || ble_gatts_notify_custom(connection,auth_handle,ack)) {
                board_auth_end_connection();revoke_connection();
                return BLE_ATT_ERR_UNLIKELY;
            }
            return 0;
        }
#endif
        uint8_t value;
        if (OS_MBUF_PKTLEN(ctx->om)!=1 || os_mbuf_copydata(ctx->om,0,1,&value)) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        if (kind==BOOT_KEYBOARD_OUTPUT) return 0; // LED output is not device input.
        if (value>1) return BLE_ATT_ERR_UNLIKELY;
        if (kind==HID_CONTROL) {
            if (value==0 && output==EISCUE_OUTPUT_BLE) interrupt_and_release();
            suspended=value==0;return 0;
        }
        // Release on the OLD report/protocol channel before changing mode.
        if (kind==HID_PROTOCOL) {if(output==EISCUE_OUTPUT_BLE)interrupt_and_release();protocol_mode=value;return 0;}
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }
    switch(kind) {
#if CONFIG_IDF_TARGET_ESP32C3
    case COMPANION_STOP_STATE: {
        if(conn!=connection || !secure_connection())return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
        uint8_t value[COMPANION_STOP_SIZE];companion_read_stop(value);
        return os_mbuf_append(ctx->om,value,sizeof value)==0?0:BLE_ATT_ERR_INSUFFICIENT_RES;
    }
#endif
    case HID_INFO:bytes=hid_info;length=sizeof hid_info;break;
    case HID_MAP:bytes=report_map;length=sizeof report_map;break;
    case HID_PROTOCOL:bytes=&protocol_mode;length=1;break;
    case HID_MOUSE:bytes=mouse_state;length=sizeof mouse_state;break;
    case HID_KEYBOARD:bytes=keyboard_state;length=sizeof keyboard_state;break;
    case HID_ABSOLUTE:bytes=absolute_state;length=sizeof absolute_state;break;
    case BOOT_MOUSE:bytes=mouse_state;length=3;break;
    case BOOT_KEYBOARD:bytes=keyboard_state;length=8;break;
    case BOOT_KEYBOARD_OUTPUT: {static const uint8_t zero=0;bytes=&zero;length=1;break;}
    case HID_MOUSE_REF:bytes=mouse_ref;length=2;break;
    case HID_KEYBOARD_REF:bytes=keyboard_ref;length=2;break;
    case HID_ABSOLUTE_REF:bytes=absolute_ref;length=2;break;
    case CUSTOM_RESPONSE:bytes=last_response;length=last_response_length;break;
#if BOARD_AUTH_REQUIRED
    case AUTH_CHALLENGE: {
        if(conn!=connection || !secure_connection())return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
        uint8_t challenge[BOARD_AUTH_CHALLENGE_SIZE];board_auth_get_challenge(challenge);
        return os_mbuf_append(ctx->om,challenge,sizeof challenge)==0?0:BLE_ATT_ERR_INSUFFICIENT_RES;
    }
#endif
    case MANUFACTURER:bytes="Eiscue development";length=strlen(bytes);break;
    case PNP_ID:bytes=pnp;length=sizeof pnp;break;
    case BATTERY_LEVEL: {
        // HOGP requires BAS. This USB-powered laboratory prototype reports a
        // FIXED TEST VALUE, not a measured battery percentage. Do not expose
        // it as product SOC; the board fuel gauge is not initialized here.
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
        {.uuid=BLE_UUID16_DECLARE(0x2A4D),.access_cb=access,.arg=(void *)HID_ABSOLUTE,.flags=INPUT_FLAGS,.val_handle=&absolute_handle,
            .descriptors=(struct ble_gatt_dsc_def[]){{.uuid=BLE_UUID16_DECLARE(0x2908),.att_flags=BLE_ATT_F_READ,.access_cb=access,.arg=(void *)HID_ABSOLUTE_REF},{0}}},
        {0}}},
    {.type=BLE_GATT_SVC_TYPE_PRIMARY,.uuid=&service_uuid.u,.characteristics=(struct ble_gatt_chr_def[]){
        {.uuid=&command_uuid.u,.access_cb=access,.arg=(void *)CUSTOM_COMMAND,.flags=BLE_GATT_CHR_F_WRITE|BLE_GATT_CHR_F_WRITE_ENC},
        {.uuid=&response_uuid.u,.access_cb=access,.arg=(void *)CUSTOM_RESPONSE,.flags=INPUT_FLAGS,.val_handle=&response_handle},
#if BOARD_AUTH_REQUIRED
        {.uuid=&challenge_uuid.u,.access_cb=access,.arg=(void *)AUTH_CHALLENGE,.flags=SECURE_READ},
        {.uuid=&auth_uuid.u,.access_cb=access,.arg=(void *)AUTH_PROOF,.flags=BLE_GATT_CHR_F_WRITE|BLE_GATT_CHR_F_WRITE_ENC|BLE_GATT_CHR_F_NOTIFY|BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC,.val_handle=&auth_handle},
#endif
#if CONFIG_IDF_TARGET_ESP32C3
        {.uuid=&companion_uuid.u,.access_cb=access,.arg=(void *)COMPANION_STATUS,.flags=BLE_GATT_CHR_F_WRITE|BLE_GATT_CHR_F_WRITE_ENC},
        {.uuid=&companion_stop_uuid.u,.access_cb=access,.arg=(void *)COMPANION_STOP_STATE,.flags=INPUT_FLAGS,.val_handle=&companion_stop_handle},
#endif
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
    ble_npl_callout_init(&held_timer,nimble_port_get_dflt_eventq(),expire_hold,NULL);
    ble_npl_callout_init(&relative_held_timer,nimble_port_get_dflt_eventq(),expire_relative_hold,NULL);
#if CONFIG_IDF_TARGET_ESP32C3
    ble_npl_event_init(&companion_stop_event,companion_key_event,NULL);
    ble_npl_event_init(&companion_unlock_event,companion_key_event,NULL);
#endif
    int rc=ble_gatts_count_cfg(services);return rc?rc:ble_gatts_add_svcs(services);
}
static void reset_subscriptions(uint16_t conn) {
    mouse_subscribed=keyboard_subscribed=absolute_subscribed=response_subscribed=boot_mouse_subscribed=boot_keyboard_subscribed=false;
    subscription_connection=conn;
#if BOARD_AUTH_REQUIRED
    auth_subscribed=false;
#endif
#if CONFIG_IDF_TARGET_ESP32C3
    companion_stop_subscribed=false;
#endif
}
void eiscue_ble_on_connect(uint16_t conn) {
    connection=conn;protocol_mode=1;suspended=false;active=false;seen_request=false;output=EISCUE_OUTPUT_BLE;
    // ESP-IDF can restore encrypted bond CCCDs before its CONNECT callback
    // (which waits for remote feature/version discovery). Keep only restored
    // subscriptions explicitly tagged with this connection's handle.
    if(subscription_connection!=conn)reset_subscriptions(conn);
    memset(mouse_state,0,sizeof mouse_state);memset(keyboard_state,0,sizeof keyboard_state);
    memset(absolute_state,0,sizeof absolute_state);
#if BOARD_AUTH_REQUIRED
    board_auth_begin_connection();
    memset(last_response,0,sizeof last_response);last_response[0]=BOARD_AUTH_VERSION;last_response[4]=EISCUE_AUTH_REQUIRED;
    last_response_length=EISCUE_RESPONSE_SIZE;
#else
    const uint8_t stop[EISCUE_COMMAND_SIZE]={1,EISCUE_STOP};respond(stop,EISCUE_INSECURE,0);
#endif
#if CONFIG_IDF_TARGET_ESP32C3
    companion_connection_changed(true,secure_connection());
#endif
}
void eiscue_ble_on_disconnect(void) {
    ble_npl_callout_stop(&release_timer);ble_npl_callout_stop(&held_timer);ble_npl_callout_stop(&relative_held_timer);active=false;
    if(output==EISCUE_OUTPUT_USB){(void)release_all(NULL);eiscue_usb_hid_revoke();}
    memset(mouse_state,0,sizeof mouse_state);memset(keyboard_state,0,sizeof keyboard_state);
    memset(absolute_state,0,sizeof absolute_state);
    connection=BLE_HS_CONN_HANDLE_NONE;seen_request=false;output=EISCUE_OUTPUT_BLE;
    reset_subscriptions(BLE_HS_CONN_HANDLE_NONE);
#if CONFIG_IDF_TARGET_ESP32C3
    companion_connection_changed(false,false);
    if(unlock_after_disconnect){unlock_after_disconnect=false;companion_host_unlock();}
#endif
#if BOARD_AUTH_REQUIRED
    board_auth_end_connection();
#endif
    // No report can be sent after disconnection; terminating HID transport
    // releases its host state. All local pending/pressed state is discarded.
}
void eiscue_ble_on_subscribe(uint16_t conn,uint16_t attribute,int enabled) {
    struct ble_gap_conn_desc desc;
    // Reject notifications for a retired or different connection. Before
    // CONNECT, the host already knows the live link restoring its CCCDs.
    if((connection!=BLE_HS_CONN_HANDLE_NONE && connection!=conn) || ble_gap_conn_find(conn,&desc)!=0)return;
    if(subscription_connection!=conn)reset_subscriptions(conn);
    bool response_lost=attribute==response_handle && response_subscribed && !enabled;
#if BOARD_AUTH_REQUIRED
    bool auth_lost=attribute==auth_handle && auth_subscribed && !enabled;
#endif
    bool affected=output==EISCUE_OUTPUT_BLE && active && attribute==report_handle(pending.action.reports[0].kind);
    if(output==EISCUE_OUTPUT_BLE && attribute==report_handle(EISCUE_MOUSE_REPORT) && mouse_state[0]) affected=true;
    if(output==EISCUE_OUTPUT_BLE && attribute==absolute_handle && absolute_state[0]) affected=true;
    if(output==EISCUE_OUTPUT_BLE && attribute==report_handle(EISCUE_KEYBOARD_REPORT))
        for(unsigned i=0;i<sizeof keyboard_state;i++)if(keyboard_state[i])affected=true;
    if(attribute==mouse_handle)mouse_subscribed=enabled;
    else if(attribute==keyboard_handle)keyboard_subscribed=enabled;
    else if(attribute==absolute_handle)absolute_subscribed=enabled;
    else if(attribute==response_handle)response_subscribed=enabled;
    else if(attribute==boot_mouse_handle)boot_mouse_subscribed=enabled;
    else if(attribute==boot_keyboard_handle)boot_keyboard_subscribed=enabled;
#if BOARD_AUTH_REQUIRED
    else if(attribute==auth_handle)auth_subscribed=enabled;
#endif
#if CONFIG_IDF_TARGET_ESP32C3
    else if(attribute==companion_stop_handle)companion_stop_subscribed=enabled;
#endif
    ESP_LOGI(TAG,"subscription kind=%s enabled=%d",attribute==mouse_handle?"mouse":attribute==keyboard_handle?"keyboard":attribute==absolute_handle?"absolute":attribute==response_handle?"response":"boot",enabled);
    if(!enabled && affected && connection!=BLE_HS_CONN_HANDLE_NONE) {
        // Once CCCD is disabled a release cannot be delivered on that channel.
        // Disconnect this HID transport instead of leaving an input held.
        interrupt_and_release();
        revoke_connection();
    } else if(response_lost
#if BOARD_AUTH_REQUIRED
              || auth_lost
#endif
    ) {
        interrupt_and_release();
#if BOARD_AUTH_REQUIRED
        // iOS may retain the system HID link after the App closes GATT. End
        // that physical session too, so a later App connect gets a new nonce.
        if(output==EISCUE_OUTPUT_USB)eiscue_usb_hid_revoke();
        board_auth_end_connection();
        if(connection!=BLE_HS_CONN_HANDLE_NONE)revoke_connection();
#endif
    }
}
void eiscue_ble_on_security_change(void) {
    ESP_LOGI(TAG,"encryption+bond=%d",secure_connection());
#if CONFIG_IDF_TARGET_ESP32C3
    companion_connection_changed(connection!=BLE_HS_CONN_HANDLE_NONE,secure_connection());
#endif
    if(!secure_connection()){
        bool held=active || mouse_state[0]!=0 || absolute_state[0]!=0;
        for(unsigned i=0;i<sizeof keyboard_state;i++) if(keyboard_state[i])held=true;
        ble_npl_callout_stop(&release_timer);ble_npl_callout_stop(&held_timer);ble_npl_callout_stop(&relative_held_timer);active=false;
        if(output==EISCUE_OUTPUT_USB){(void)release_all(NULL);eiscue_usb_hid_revoke();}
#if BOARD_AUTH_REQUIRED
        board_auth_end_connection();
#endif
        memset(mouse_state,0,sizeof mouse_state);memset(keyboard_state,0,sizeof keyboard_state);
        absolute_state[0]=0;
        // An unencrypted link cannot transmit a release. Revoke the HID
        // transport itself if a report could still hold an input down.
        if((held || BOARD_AUTH_REQUIRED) && connection!=BLE_HS_CONN_HANDLE_NONE)
            revoke_connection();
    }
}
