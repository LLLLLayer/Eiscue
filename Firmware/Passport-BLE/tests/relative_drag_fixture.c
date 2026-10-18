// SPDX-License-Identifier: Apache-2.0
#include "command_protocol.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void command(uint8_t bytes[16],int16_t x,int16_t y,uint8_t steps,uint16_t duration) {
    memset(bytes,0,16);bytes[0]=1;bytes[1]=EISCUE_RELATIVE_STROKE;bytes[2]=0x34;bytes[3]=0x12;
    bytes[4]=(uint16_t)x&255;bytes[5]=(uint16_t)x>>8;bytes[6]=(uint16_t)y&255;bytes[7]=(uint16_t)y>>8;
    bytes[8]=steps;bytes[9]=duration&255;bytes[10]=duration>>8;
}
static int signed_byte(uint8_t value) {return value<128?value:(int)value-256;}
static void wire_and_bounds(void) {
    uint8_t bytes[16];eiscue_action action;
    command(bytes,-151,99,100,1000);
    assert(eiscue_parse_action(bytes,&action));
    assert(action.stroke.dx==-151 && action.stroke.dy==99 && action.stroke.steps==100 && action.stroke.duration_ms==1000);
    assert(action.count==2 && action.reports[0].kind==EISCUE_MOUSE_REPORT && action.reports[0].length==4);
    assert(memcmp(action.reports[0].bytes,(uint8_t[]){1,0,0,0},4)==0);
    assert(memcmp(action.reports[1].bytes,(uint8_t[]){0,0,0,0},4)==0);
    for(unsigned i=11;i<16;i++){bytes[i]=1;assert(!eiscue_parse_action(bytes,&action));bytes[i]=0;}
    bytes[0]=2;assert(!eiscue_parse_action(bytes,&action));
    const struct {uint8_t steps;uint16_t duration;} invalid[]={{0,100},{251,2000},{1,100},{2,99},{250,2001},{20,159},{2,101}};
    for(unsigned i=0;i<sizeof invalid/sizeof invalid[0];i++) {
        command(bytes,0,0,invalid[i].steps,invalid[i].duration);assert(!eiscue_parse_action(bytes,&action));
    }
    command(bytes,16,0,2,100);assert(eiscue_parse_action(bytes,&action));
    command(bytes,16,2,2,100);assert(!eiscue_parse_action(bytes,&action));
    command(bytes,15,1,2,100);assert(!eiscue_parse_action(bytes,&action)); // Average is safe, rounded final (8,1) is not.
    command(bytes,32767,-32768,250,2000);assert(!eiscue_parse_action(bytes,&action));
    command(bytes,-7,5,3,100);assert(eiscue_parse_action(bytes,&action));
    const uint8_t expected[][4]={{1,0xFE,1,0},{1,0xFE,2,0},{1,0xFD,2,0}};
    for(unsigned i=1;i<=3;i++) {
        eiscue_report report;assert(eiscue_stroke_report(&action.stroke,i,&report));
        assert(memcmp(report.bytes,expected[i-1],4)==0);
        assert(eiscue_stroke_interval(&action.stroke,i)==(i==3?34:33));
    }
    puts("PASS relative stroke wire: LE fields, version/tail, timing/count bounds, rounded radial limit");
}
static void exact_trajectories(void) {
    unsigned accepted=0,rejected=0;
    for(unsigned steps=2;steps<=250;steps++)for(int axis=-1;axis<=1;axis++) {
        int16_t x=(int16_t)((int)steps*5+axis),y=(int16_t)((int)steps*3-axis);
        for(int sign=-1;sign<=1;sign+=2) {
            uint8_t bytes[16];eiscue_action action;
            command(bytes,(int16_t)(sign*x),(int16_t)(-sign*y),(uint8_t)steps,(uint16_t)(steps<13?100:steps*8));
            if(!eiscue_parse_action(bytes,&action)){rejected++;continue;}
            int total_x=0,total_y=0;unsigned duration=0;
            for(unsigned i=1;i<=steps;i++) {
                eiscue_report report;assert(eiscue_stroke_report(&action.stroke,i,&report));
                int dx=signed_byte(report.bytes[1]),dy=signed_byte(report.bytes[2]);
                assert(dx*dx+dy*dy<=64 && report.bytes[0]==1 && report.bytes[3]==0);
                total_x+=dx;total_y+=dy;
                assert(total_x==(int32_t)action.stroke.dx*(int)i/(int)steps);
                assert(total_y==(int32_t)action.stroke.dy*(int)i/(int)steps);
                unsigned interval=eiscue_stroke_interval(&action.stroke,i);
                assert(interval>=8 && interval<=50);duration+=interval;
            }
            assert(total_x==action.stroke.dx && total_y==action.stroke.dy && duration==action.stroke.duration_ms);
            accepted++;
        }
    }
    assert(accepted>1400 && rejected==0);
    uint8_t bytes[16];eiscue_action action;
    command(bytes,-2000,0,250,2000);assert(eiscue_parse_action(bytes,&action));
    assert(action.stroke.steps+2==252);
    eiscue_report report;assert(eiscue_stroke_report(&action.stroke,0,&report) && report.bytes[0]==1);
    assert(eiscue_stroke_report(&action.stroke,251,&report) && report.bytes[0]==0);
    assert(!eiscue_stroke_report(&action.stroke,252,&report));
    assert(eiscue_stroke_interval(&action.stroke,0)==0);
    puts("PASS relative stroke planner: 1494 signed paths, exact totals/duration, held reports, max252 emitted");
}
static void delayed_endpoint_release(void) {
    uint8_t bytes[16];eiscue_action action;command(bytes,40,-20,10,100);
    assert(eiscue_parse_action(bytes,&action));
    unsigned now=0,endpoint_ready_at=0,emitted=0;bool held=false;
    for(unsigned i=0;i<=action.stroke.steps+1U;i++) {
        if(i)now+=eiscue_stroke_interval(&action.stroke,i);
        eiscue_report report;assert(eiscue_stroke_report(&action.stroke,i,&report));
        // Model an interrupt endpoint that is busy for its next 5 ms poll.
        assert(now>=endpoint_ready_at);endpoint_ready_at=now+5;
        held=report.bytes[0]!=0;emitted++;
        if(i<=action.stroke.steps)assert(held);
        else assert(!held && now==108 && emitted==12);
    }
    assert(eiscue_stroke_interval(&action.stroke,action.stroke.steps+1)==8);
    puts("PASS relative stroke release: production UP plan waits8ms for a delayed USB endpoint, reply count only after UP");
}
static void old_commands_and_reply(void) {
    const uint8_t opcodes[]={EISCUE_STOP,EISCUE_INFO,EISCUE_QUERY_OUTPUT};eiscue_action action;
    for(unsigned i=0;i<sizeof opcodes;i++) {
        uint8_t bytes[16]={1,opcodes[i]};assert(eiscue_parse_action(bytes,&action));assert(action.count==0 && action.stroke.steps==0);
    }
    uint8_t absolute[16]={1,EISCUE_ABS_POINT,1,0,0xFF,0x7F,0x34,0x12,1};
    assert(eiscue_parse_action(absolute,&action));assert(action.count==1 && action.stroke.steps==0);
    assert(action.reports[0].kind==EISCUE_ABSOLUTE_REPORT && action.reports[0].bytes[0]==1);
    uint8_t bytes[16],reply[8];command(bytes,0,0,250,2000);
    eiscue_make_response(bytes,EISCUE_SENT,252,true,reply);
    assert(memcmp(reply,(uint8_t[]){1,10,0x34,0x12,0,252,1,0},8)==0);
    assert(EISCUE_CAP_OUTPUT_SELECTION==0x80 && EISCUE_CAP_RELATIVE_STROKE==0x40 && EISCUE_CAP_RELATIVE_READY==0x20);
    puts("PASS relative stroke compatibility: old parser/report bytes, capability bits and bounded reply count");
}
int main(void) {wire_and_bounds();exact_trajectories();delayed_endpoint_release();old_commands_and_reply();return 0;}
