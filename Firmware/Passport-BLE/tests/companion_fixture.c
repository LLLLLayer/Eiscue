// SPDX-License-Identifier: Apache-2.0
#include "companion_protocol.h"
#include "command_protocol.h"
#include "companion_assets.h"
#include "companion_text.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void packets(void) {
    uint8_t packet[COMPANION_STATUS_SIZE]={1,COMPANION_ACTING,1,0,0x34,0x12};
    companion_status status={0};
    assert(companion_parse_status(packet,sizeof packet,&status));
    assert(status.phase==COMPANION_ACTING && status.language==1 && status.completed_actions==0x1234);
    assert(!companion_parse_status(packet,sizeof packet-1,&status));
    assert(!companion_parse_status(packet,sizeof packet+1,&status));
    for(unsigned i=6;i<sizeof packet;i++) {
        packet[i]=1;assert(!companion_parse_status(packet,sizeof packet,&status));packet[i]=0;
    }
    packet[3]=1;assert(!companion_parse_status(packet,sizeof packet,&status));packet[3]=0;
    packet[0]=2;assert(!companion_parse_status(packet,sizeof packet,&status));packet[0]=1;
    packet[1]=COMPANION_STOPPED+1;assert(!companion_parse_status(packet,sizeof packet,&status));packet[1]=0;
    packet[2]=2;assert(!companion_parse_status(packet,sizeof packet,&status));
    puts("PASS companion packets: bounds, version, phases, language, reserved bytes, LE counter");
}
static void stopping(void) {
    companion_stop stop={0};uint8_t bytes[COMPANION_STOP_SIZE];
    companion_stop_bytes(&stop,bytes);assert(memcmp(bytes,(uint8_t[]){1,0,0,0},4)==0);
    assert(companion_stop_latch(&stop));assert(!companion_stop_latch(&stop));
    companion_stop_bytes(&stop,bytes);assert(memcmp(bytes,(uint8_t[]){1,1,1,0},4)==0);
    for(unsigned opcode=0;opcode<256;opcode++) {
        bool safe=opcode==EISCUE_STOP || opcode==EISCUE_INFO || opcode==EISCUE_QUERY_OUTPUT;
        assert(companion_command_allowed(&stop,opcode)==safe);
    }
    companion_stop_unlock(&stop);assert(!companion_stop_is_latched(&stop));
    assert(companion_stop_latch(&stop));companion_stop_bytes(&stop,bytes);
    assert(memcmp(bytes,(uint8_t[]){1,1,2,0},4)==0);
    atomic_store(&stop.state,0xFFFF0000);assert(companion_stop_latch(&stop));
    companion_stop_bytes(&stop,bytes);assert(memcmp(bytes,(uint8_t[]){1,1,0,0},4)==0);
    puts("PASS companion stop: latch idempotence, all side-effect opcodes blocked, explicit unlock, generation wrap");
}
static void freshness(void) {
    companion_status status={.phase=COMPANION_THINKING};
    assert(companion_visible_phase(true,true,false,15001,1,&status)==COMPANION_THINKING);
    assert(companion_visible_phase(true,true,false,15002,1,&status)==COMPANION_STALE);
    assert(companion_visible_phase(true,true,false,10,0,&status)==COMPANION_STALE);
    assert(companion_visible_phase(true,true,false,10,11,&status)==COMPANION_STALE);
    assert(companion_visible_phase(false,false,false,10,1,&status)==COMPANION_IDLE);
    assert(companion_visible_phase(true,false,false,10,1,&status)==COMPANION_CONNECTING);
    assert(companion_visible_phase(false,false,true,50000,1,&status)==COMPANION_STOPPED);
    puts("PASS companion freshness: local stop/link priority, startup, expired heartbeat and clock regression");
}
static void buttons(void) {
    companion_button button={0};
    assert(companion_button_sample(&button,true,false,100)==COMPANION_BUTTON_NONE);
    assert(companion_button_sample(&button,false,false,120)==COMPANION_BUTTON_NONE);
    assert(companion_button_sample(&button,true,false,125)==COMPANION_BUTTON_NONE);
    assert(companion_button_sample(&button,true,false,164)==COMPANION_BUTTON_NONE);
    assert(companion_button_sample(&button,true,false,165)==COMPANION_BUTTON_STOP);
    assert(companion_button_sample(&button,true,true,3000)==COMPANION_BUTTON_NONE);
    assert(companion_button_sample(&button,false,true,3010)==COMPANION_BUTTON_NONE);
    assert(companion_button_sample(&button,false,true,3050)==COMPANION_BUTTON_NONE);
    assert(companion_button_sample(&button,true,true,3060)==COMPANION_BUTTON_NONE);
    assert(companion_button_sample(&button,true,true,3100)==COMPANION_BUTTON_NONE);
    assert(companion_button_sample(&button,true,true,4599)==COMPANION_BUTTON_NONE);
    assert(companion_button_sample(&button,true,true,4600)==COMPANION_BUTTON_UNLOCK);
    assert(companion_button_sample(&button,true,false,8000)==COMPANION_BUTTON_NONE);
    puts("PASS companion keys: bounce rejection, stop on press, same hold cannot unlock, release/repress and 1.5s unlock");
}
static void bitmap_rows(const companion_bitmap *bitmap) {
    assert(bitmap && bitmap->width<=216);
    uint16_t pixels[218];
    for(unsigned y=0;y<bitmap->height;y++) {
        pixels[0]=pixels[bitmap->width+1]=0xCAFE;
        assert(companion_bitmap_decode_row(bitmap,y,pixels+1,bitmap->width));
        assert(pixels[0]==0xCAFE && pixels[bitmap->width+1]==0xCAFE);
    }
    assert(!companion_bitmap_decode_row(bitmap,bitmap->height,pixels,216));
    assert(!companion_bitmap_decode_row(bitmap,0,pixels,bitmap->width-1));
    companion_bitmap truncated=*bitmap;truncated.data_length=0;
    assert(!companion_bitmap_decode_row(&truncated,0,pixels,216));
}
static void assets(void) {
    for(unsigned i=0;i<COMPANION_ASSET_COUNT;i++)bitmap_rows(companion_asset_get(i));
    for(unsigned language=0;language<2;language++)
        for(unsigned text=0;text<16;text++)bitmap_rows(companion_text_get(text,language));
    for(unsigned text=16;text<26;text++)bitmap_rows(companion_text_get(text,0));
    uint16_t row[160];assert(companion_bitmap_decode_row(companion_asset_get(0),0,row,160));
    const uint8_t *bytes=(const uint8_t *)row;
    assert(bytes[0]==0x10 && bytes[1]==0xC3);
    assert(!companion_asset_get(COMPANION_ASSET_COUNT));
    puts("PASS companion assets: 47 bitmaps, every row, DMA byte order, output guards, invalid rows/buffers/truncation");
}
int main(void) {packets();stopping();freshness();buttons();assets();return 0;}
