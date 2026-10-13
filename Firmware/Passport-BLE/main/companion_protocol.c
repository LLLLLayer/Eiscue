// SPDX-License-Identifier: Apache-2.0
#include "companion_protocol.h"
#include "command_protocol.h"

bool companion_parse_status(const uint8_t *bytes,size_t length,companion_status *status) {
    if(!bytes || !status || length!=COMPANION_STATUS_SIZE || bytes[0]!=1 ||
        bytes[1]>COMPANION_STOPPED || bytes[2]>1 || bytes[3])return false;
    for(unsigned i=6;i<COMPANION_STATUS_SIZE;i++)if(bytes[i])return false;
    *status=(companion_status){.phase=bytes[1],.language=bytes[2],
        .completed_actions=(uint16_t)bytes[4]|((uint16_t)bytes[5]<<8)};
    return true;
}
bool companion_stop_latch(companion_stop *stop) {
    unsigned old=atomic_load(&stop->state);
    do {
        if(old&1)return false;
    } while(!atomic_compare_exchange_weak(&stop->state,&old,((((old>>16)+1)&0xFFFF)<<16)|1));
    return true;
}
bool companion_stop_is_latched(const companion_stop *stop) {return (atomic_load(&stop->state)&1)!=0;}
bool companion_command_allowed(const companion_stop *stop,uint8_t opcode) {
    return !companion_stop_is_latched(stop) || opcode==EISCUE_STOP || opcode==EISCUE_INFO || opcode==EISCUE_QUERY_OUTPUT;
}
void companion_stop_unlock(companion_stop *stop) {atomic_fetch_and(&stop->state,~1U);}
void companion_stop_bytes(const companion_stop *stop,uint8_t bytes[COMPANION_STOP_SIZE]) {
    unsigned value=atomic_load(&stop->state);
    bytes[0]=1;bytes[1]=value&1;bytes[2]=(value>>16)&0xFF;bytes[3]=(value>>24)&0xFF;
}
uint8_t companion_visible_phase(bool connected,bool secure,bool stopped,uint64_t now,
        uint64_t updated_at,const companion_status *status) {
    if(stopped)return COMPANION_STOPPED;
    if(!connected)return COMPANION_IDLE;
    if(!secure)return COMPANION_CONNECTING;
    if(!updated_at || now<updated_at || now-updated_at>COMPANION_STALE_MS)return COMPANION_STALE;
    return status->phase;
}
enum companion_button_event companion_button_sample(companion_button *button,bool ok,
        bool stopped,uint64_t now) {
    if(ok!=button->candidate){button->candidate=ok;button->changed_at=now;}
    if(ok!=button->pressed && now-button->changed_at>=40) {
        button->pressed=ok;
        if(ok) {
            button->pressed_at=now;button->unlock_eligible=stopped;button->unlocked=false;
            if(!stopped)return COMPANION_BUTTON_STOP;
        }
    }
    // The press which stops input can never also unlock it, however long held.
    if(button->pressed && button->unlock_eligible && !button->unlocked &&
        now-button->pressed_at>=1500) {
        button->unlocked=true;return COMPANION_BUTTON_UNLOCK;
    }
    return COMPANION_BUTTON_NONE;
}
