// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "command_protocol.h"

typedef struct { eiscue_report reports[2]; uint8_t count; } eiscue_ble_plan;
typedef uint8_t (*eiscue_ble_sender)(const eiscue_report *report,void *context);

// Only S3 BLE splits ABS. Position precedes DOWN; UP precedes position so a
// release at a new coordinate cannot move while held. C3 and non-ABS are raw.
static inline eiscue_ble_plan eiscue_ble_plan_report(const eiscue_report *report,bool single_button_source) {
    eiscue_ble_plan plan={.reports={*report},.count=1};
    if(single_button_source && report->kind==EISCUE_ABSOLUTE_REPORT) {
        eiscue_report position=*report;position.bytes[0]=0;
        const eiscue_report button={.kind=EISCUE_MOUSE_REPORT,.length=4,.bytes={report->bytes[0],0,0,0}};
        plan.reports[0]=report->bytes[0]?position:button;
        plan.reports[1]=report->bytes[0]?button:position;
        plan.count=2;
    }
    return plan;
}
static inline uint8_t eiscue_ble_send_plan(const eiscue_ble_plan *plan,eiscue_ble_sender send,
                                         void *context,uint8_t *emitted) {
    for(unsigned i=0;i<plan->count;i++) {
        uint8_t status=send(&plan->reports[i],context);
        if(status!=EISCUE_SENT)return status;
        if(emitted)(*emitted)++;
    }
    return EISCUE_SENT;
}
// Physical report caches remain identical to successful wire notifications.
// Keep ABS watchdog ownership separately, and commit it only on full success;
// a partial plan is released by the caller before any further command.
static inline uint8_t eiscue_ble_send_report(const eiscue_report *report,bool single_button_source,
    eiscue_ble_sender send,void *context,uint8_t *emitted,bool *absolute_held) {
    const eiscue_ble_plan plan=eiscue_ble_plan_report(report,single_button_source);
    uint8_t status=eiscue_ble_send_plan(&plan,send,context,emitted);
    if(status==EISCUE_SENT && single_button_source && report->kind==EISCUE_ABSOLUTE_REPORT)
        *absolute_held=report->bytes[0]!=0;
    return status;
}
static inline bool eiscue_ble_absolute_ready(bool single_button_source,uint8_t mode,
                                             bool absolute_subscribed,bool mouse_subscribed) {
    return mode==1 && absolute_subscribed && (!single_button_source || mouse_subscribed);
}
