// SPDX-License-Identifier: Apache-2.0
#include "ble_report_plan.h"
#include "hid_descriptors.h"
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

static const uint8_t mouse_map[]={EISCUE_MOUSE_DESCRIPTOR};
static const uint8_t keyboard_map[]={EISCUE_KEYBOARD_DESCRIPTOR};
static const uint8_t absolute_map[]={EISCUE_ABSOLUTE_DESCRIPTOR};
static const uint8_t original_map[]={EISCUE_MOUSE_DESCRIPTOR,EISCUE_KEYBOARD_DESCRIPTOR,EISCUE_ABSOLUTE_DESCRIPTOR};
static const uint8_t s3_ble_map[]={EISCUE_MOUSE_DESCRIPTOR,EISCUE_KEYBOARD_DESCRIPTOR,EISCUE_S3_BLE_ABSOLUTE_DESCRIPTOR};

static uint32_t fingerprint(const uint8_t *bytes,unsigned length) {
    uint32_t hash=2166136261u;
    for(unsigned i=0;i<length;i++)hash=(hash^bytes[i])*16777619u;
    return hash;
}
typedef struct {unsigned bits[4],button1[4];} map_summary;
// Parse HID short items rather than searching raw bytes: constant inputs must
// not count as a button source, and globals persist across collections.
static map_summary parse_map(const uint8_t *bytes,unsigned length) {
    map_summary summary={0};
    unsigned page=0,id=0,size=0,count=0,usage=0,minimum=0,maximum=0;
    bool has_usage=false,has_range=false;
    for(unsigned offset=0;offset<length;) {
        unsigned prefix=bytes[offset++],width=prefix&3;
        assert(prefix!=0xFE);if(width==3)width=4;
        assert(offset+width<=length);
        uint32_t value=0;
        for(unsigned i=0;i<width;i++)value|=(uint32_t)bytes[offset++]<<(8*i);
        unsigned type=(prefix>>2)&3,tag=prefix>>4;
        if(type==1) {
            if(tag==0)page=value;
            else if(tag==7)size=value;
            else if(tag==8){id=value;assert(id>=1 && id<=3);}
            else if(tag==9)count=value;
            else assert(tag!=10 && tag!=11); // These descriptors need no PUSH/POP.
        } else if(type==2) {
            if(tag==0){usage=value;has_usage=true;}
            else if(tag==1){minimum=value;has_range=true;}
            else if(tag==2)maximum=value;
        } else if(type==0) {
            if(tag==8) {
                assert(id>=1 && id<=3);summary.bits[id]+=size*count;
                if(!(value&1) && page==9 &&
                   ((has_usage && usage==1) || (has_range && minimum<=1 && maximum>=1)))
                    summary.button1[id]++;
            }
            has_usage=has_range=false;usage=minimum=maximum=0;
        }
    }
    return summary;
}
static void descriptor_contract(void) {
    // Frozen original macros are shared by C3 BLE and USB; adding the S3 BLE
    // variant must not silently change either original transport's bytes.
    assert(sizeof mouse_map==54 && fingerprint(mouse_map,sizeof mouse_map)==0x2c01638du);
    assert(sizeof keyboard_map==45 && fingerprint(keyboard_map,sizeof keyboard_map)==0xbfa6d471u);
    assert(sizeof absolute_map==53 && fingerprint(absolute_map,sizeof absolute_map)==0x3843babeu);
    map_summary original=parse_map(original_map,sizeof original_map),s3=parse_map(s3_ble_map,sizeof s3_ble_map);
    const unsigned widths[]={0,32,64,40};
    for(unsigned id=1;id<=3;id++)assert(original.bits[id]==widths[id] && s3.bits[id]==widths[id]);
    assert(original.button1[1]==1 && original.button1[3]==1);
    assert(s3.button1[1]==1 && s3.button1[2]==0 && s3.button1[3]==0);
    printf("PASS descriptor: original C3/USB bytes, IDs1/2/3 widths4/8/5, S3 BLE sole Button1; map length=%zu fingerprint=%08x\n",
        sizeof s3_ble_map,(unsigned)fingerprint(s3_ble_map,sizeof s3_ble_map));
}

typedef struct {
    unsigned attempts,delivered,fail_at;
    eiscue_report reports[256];
    uint8_t mouse[4],absolute[5];
} sink;
static uint8_t send_report(const eiscue_report *report,void *context) {
    sink *output=context;
    if(output->attempts++==output->fail_at)return EISCUE_SEND_FAILED;
    assert(output->delivered<256);output->reports[output->delivered++]=*report;
    if(report->kind==EISCUE_ABSOLUTE_REPORT)memcpy(output->absolute,report->bytes,5);
    if(report->kind==EISCUE_MOUSE_REPORT)memcpy(output->mouse,report->bytes,4);
    return EISCUE_SENT;
}
static void absolute_order_and_partial_counts(void) {
    for(unsigned held=0;held<=1;held++) {
        const eiscue_report report={.kind=EISCUE_ABSOLUTE_REPORT,.length=5,.bytes={held,0x34,0x12,0x78,0x56}};
        eiscue_ble_plan raw=eiscue_ble_plan_report(&report,false);
        assert(raw.count==1 && memcmp(&raw.reports[0],&report,sizeof report)==0);
        for(unsigned fail=0;fail<=2;fail++) {
            sink output={.fail_at=fail};bool logical_held=!held;uint8_t emitted=7;
            uint8_t status=eiscue_ble_send_report(&report,true,send_report,&output,&emitted,&logical_held);
            assert(emitted==7+fail && output.delivered==fail);
            assert(status==(fail==2?EISCUE_SENT:EISCUE_SEND_FAILED));
            // Until the complete plan succeeds, ABS watchdog ownership remains
            // unchanged even if one physical channel has already changed.
            assert(logical_held==(fail==2?(bool)held:!(bool)held));
            if(fail) {
                assert(output.reports[0].kind==(held?EISCUE_ABSOLUTE_REPORT:EISCUE_MOUSE_REPORT));
                assert(output.reports[0].bytes[0]==0);
            }
            if(fail==2) {
                assert(output.reports[1].kind==(held?EISCUE_MOUSE_REPORT:EISCUE_ABSOLUTE_REPORT));
                assert(output.absolute[0]==0 && memcmp(output.absolute+1,report.bytes+1,4)==0);
                assert(output.mouse[0]==held && output.mouse[1]==0 && output.mouse[2]==0 && output.mouse[3]==0);
            }
        }
    }
    puts("PASS ABS: position-before-DOWN / UP-before-position, raw physical caches, separate logical hold, partial0/1/full2 counts");
}
static void other_commands_and_counts(void) {
    const uint8_t commands[][16]={
        {1,EISCUE_MOVE,0,0,7,0,8,0},
        {1,EISCUE_CLICK,0,0,1,1},
        {1,EISCUE_KEY,0,0,1},
        {1,EISCUE_ABS_POINT,0,0,0x34,0x12,0x78,0x56,1},
        {1,EISCUE_RELATIVE_STROKE,0,0,0x30,0xF8,0,0,250,0xD0,0x07}
    };
    const unsigned expected[]={1,2,2,1,252};
    for(unsigned s3=0;s3<=1;s3++)for(unsigned i=0;i<sizeof commands/sizeof commands[0];i++) {
        eiscue_action action;assert(eiscue_parse_action(commands[i],&action));
        sink output={.fail_at=UINT_MAX};bool held=false;uint8_t emitted=0;
        unsigned count=action.stroke.steps?action.stroke.steps+2U:action.count;
        for(unsigned step=0;step<count;step++) {
            eiscue_report report;
            if(action.stroke.steps)assert(eiscue_stroke_report(&action.stroke,step,&report));
            else report=action.reports[step];
            assert(eiscue_ble_send_report(&report,s3,send_report,&output,&emitted,&held)==EISCUE_SENT);
        }
        unsigned total=expected[i]+(s3 && commands[i][1]==EISCUE_ABS_POINT?1:0);
        assert(emitted==total && output.delivered==total);
        if(action.stroke.steps)assert(output.mouse[0]==0 && !held);
    }
    puts("PASS compatibility: MOVE1 / click2 / key2 / op10 max252; only S3 BLE ABS changes1to2");
}
static void readiness(void) {
    for(unsigned mode=0;mode<=1;mode++)for(unsigned absolute=0;absolute<=1;absolute++)for(unsigned mouse=0;mouse<=1;mouse++) {
        assert(eiscue_ble_absolute_ready(false,mode,absolute,mouse)==(mode && absolute));
        assert(eiscue_ble_absolute_ready(true,mode,absolute,mouse)==(mode && absolute && mouse));
    }
    puts("PASS readiness: S3 BLE ABS requires report mode plus ABS+mouse subscriptions; C3 unchanged");
}
int main(void) {
    descriptor_contract();absolute_order_and_partial_counts();other_commands_and_counts();readiness();return 0;
}
