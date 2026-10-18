// SPDX-License-Identifier: Apache-2.0
#include "command_protocol.h"
#include <string.h>

static bool zero_tail(const uint8_t *bytes, unsigned first) {
    for (unsigned i = first; i < EISCUE_COMMAND_SIZE; ++i) if (bytes[i]) return false;
    return true;
}
static int16_t signed_le(const uint8_t *bytes) {
    uint16_t raw = (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
    return raw <= INT16_MAX ? (int16_t)raw : (int16_t)((int32_t)raw - 65536);
}
static bool valid_stroke(const eiscue_stroke *stroke) {
    return stroke && stroke->steps>=1 && stroke->steps<=250 &&
        stroke->duration_ms>=100 && stroke->duration_ms<=2000 &&
        stroke->duration_ms>=stroke->steps*8 && stroke->duration_ms<=stroke->steps*50;
}
bool eiscue_stroke_report(const eiscue_stroke *stroke,unsigned step,eiscue_report *report) {
    if(!valid_stroke(stroke) || !report || step>(unsigned)stroke->steps+1)return false;
    if(step==0 || step==(unsigned)stroke->steps+1) {
        *report=(eiscue_report){.kind=EISCUE_MOUSE_REPORT,.length=4,.bytes={step==0?1:0,0,0,0}};
        return true;
    }
    int32_t x=(int32_t)stroke->dx*(int32_t)step/stroke->steps-(int32_t)stroke->dx*(int32_t)(step-1)/stroke->steps;
    int32_t y=(int32_t)stroke->dy*(int32_t)step/stroke->steps-(int32_t)stroke->dy*(int32_t)(step-1)/stroke->steps;
    if(x*x+y*y>64)return false;
    *report=(eiscue_report){.kind=EISCUE_MOUSE_REPORT,.length=4,.bytes={1,(uint8_t)x,(uint8_t)y,0}};
    return true;
}
uint16_t eiscue_stroke_interval(const eiscue_stroke *stroke,unsigned step) {
    if(!valid_stroke(stroke) || step<1 || step>(unsigned)stroke->steps+1)return 0;
    if(step==(unsigned)stroke->steps+1)return 8;
    return (uint16_t)((uint32_t)stroke->duration_ms*step/stroke->steps-
        (uint32_t)stroke->duration_ms*(step-1)/stroke->steps);
}
static bool ascii_key(uint8_t c, uint8_t *usage, uint8_t *modifier) {
    *modifier = 0;
    if (c >= 'a' && c <= 'z') { *usage = 4 + c - 'a'; return true; }
    if (c >= 'A' && c <= 'Z') { *usage = 4 + c - 'A'; *modifier = 2; return true; }
    if (c >= '1' && c <= '9') { *usage = 0x1E + c - '1'; return true; }
    if (c == '0') { *usage = 0x27; return true; }
    const char plain[] = " -=[]\\;'`,./";
    const char shifted[] = " _+{}|:\"~<>?";
    const uint8_t usages[] = {0x2C,0x2D,0x2E,0x2F,0x30,0x31,0x33,0x34,0x35,0x36,0x37,0x38};
    for (unsigned i = 0; i < sizeof usages; ++i) {
        if (c == (uint8_t)plain[i]) { *usage = usages[i]; return true; }
        if (c == (uint8_t)shifted[i]) { *usage = usages[i]; *modifier = 2; return true; }
    }
    const char number_shift[] = "!@#$%^&*()";
    for (unsigned i = 0; i < 10; ++i) if (c == (uint8_t)number_shift[i]) {
        *usage = i < 9 ? 0x1E + i : 0x27; *modifier = 2; return true;
    }
    if (c == '\n' || c == '\r') { *usage = 0x28; return true; }
    if (c == '\t') { *usage = 0x2B; return true; }
    return false;
}
bool eiscue_parse_action(const uint8_t command[EISCUE_COMMAND_SIZE], eiscue_action *action) {
    memset(action, 0, sizeof *action);
    if (command[0] != EISCUE_PROTOCOL_VERSION) return false;
    switch (command[1]) {
    case EISCUE_STOP:
    case EISCUE_INFO:
    case EISCUE_QUERY_OUTPUT:
        if (!zero_tail(command, 4)) return false;
        // The peripheral supplies releases from current state, so releasing
        // an absolute button preserves its last coordinates.
        return true;
    case EISCUE_SELECT_OUTPUT:
        return command[4]<=EISCUE_OUTPUT_USB && zero_tail(command,5);
    case EISCUE_MOVE: {
        int16_t x=signed_le(command+4), y=signed_le(command+6);
        if (x < -127 || x > 127 || y < -127 || y > 127 || !zero_tail(command, 9) || command[8] == 128) return false;
        action->reports[0]=(eiscue_report){.kind=EISCUE_MOUSE_REPORT, .length=4,
            .bytes={0, (uint8_t)x, (uint8_t)y, command[8]}};
        action->count=1; return true;
    }
    case EISCUE_CLICK:
        if ((command[4]!=1 && command[4]!=2 && command[4]!=4) || command[5]!=1 || !zero_tail(command,6)) return false;
        action->reports[0]=(eiscue_report){.kind=EISCUE_MOUSE_REPORT, .length=4, .bytes={command[4],0,0,0}};
        action->reports[1]=(eiscue_report){.kind=EISCUE_MOUSE_REPORT, .length=4};
        action->count=2; return true;
    case EISCUE_ASCII:
    case EISCUE_KEY:
    case EISCUE_KEY_COMBO: {
        uint8_t usage=0,modifier=0;
        if (command[1]==EISCUE_KEY_COMBO) {
            if (command[4]!=0x08 || (command[5]!=0x0B && command[5]!=0x19 && command[5]!=0x2C) || !zero_tail(command,6)) return false;
            modifier=command[4];usage=command[5];
        } else if (!zero_tail(command,5)) {
            return false;
        } else if (command[1]==EISCUE_ASCII) {
            if (!ascii_key(command[4], &usage, &modifier)) return false;
        } else {
            const uint8_t keys[]={0,0x28,0x4A,0x2A,0x2B,0x29,0x2C};
            if (command[4]<1 || command[4]>=sizeof keys) return false;
            usage=keys[command[4]];
        }
        action->reports[0]=(eiscue_report){.kind=EISCUE_KEYBOARD_REPORT, .length=8, .bytes={modifier,0,usage,0,0,0,0,0}};
        action->reports[1]=(eiscue_report){.kind=EISCUE_KEYBOARD_REPORT, .length=8};
        action->count=2; return true;
    }
    case EISCUE_ABS_POINT:
        if (command[5]>0x7F || command[7]>0x7F || command[8]>1 || !zero_tail(command,9)) return false;
        action->reports[0]=(eiscue_report){.kind=EISCUE_ABSOLUTE_REPORT, .length=5,
            .bytes={command[8],command[4],command[5],command[6],command[7]}};
        action->count=1;return true;
    case EISCUE_RELATIVE_STROKE: {
        action->stroke=(eiscue_stroke){.dx=signed_le(command+4),.dy=signed_le(command+6),
            .steps=command[8],.duration_ms=(uint16_t)command[9]|((uint16_t)command[10]<<8)};
        if(!zero_tail(command,11) || !valid_stroke(&action->stroke))return false;
        eiscue_report step;
        for(unsigned i=1;i<=action->stroke.steps;i++)if(!eiscue_stroke_report(&action->stroke,i,&step))return false;
        if(!eiscue_stroke_report(&action->stroke,0,&action->reports[0]) ||
           !eiscue_stroke_report(&action->stroke,action->stroke.steps+1,&action->reports[1]))return false;
        action->count=2;return true;
    }
    default: return false;
    }
}
void eiscue_make_response(const uint8_t command[EISCUE_COMMAND_SIZE], uint8_t status,
        uint8_t emitted, bool secure, uint8_t response[EISCUE_RESPONSE_SIZE]) {
    const uint8_t value[EISCUE_RESPONSE_SIZE]={EISCUE_PROTOCOL_VERSION,command[1],command[2],command[3],status,emitted,secure?1:0,0};
    memcpy(response,value,sizeof value);
}
