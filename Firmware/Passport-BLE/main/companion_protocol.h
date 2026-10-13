// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>

#define COMPANION_STATUS_SIZE 12
#define COMPANION_STOP_SIZE 4
#define COMPANION_STALE_MS 15000
typedef struct { uint8_t phase,language; uint16_t completed_actions; } companion_status;
enum companion_phase { COMPANION_IDLE,COMPANION_NEEDS_SCREEN,COMPANION_NEEDS_CALIBRATION,
    COMPANION_READY,COMPANION_THINKING,COMPANION_OBSERVING,COMPANION_ACTING,COMPANION_WAITING,
    COMPANION_COMPLETED,COMPANION_FAILED,COMPANION_STOPPED,COMPANION_CONNECTING,COMPANION_STALE };
typedef struct { atomic_uint state; } companion_stop;
typedef struct { bool candidate,pressed,unlock_eligible,unlocked; uint64_t changed_at,pressed_at; } companion_button;
enum companion_button_event { COMPANION_BUTTON_NONE,COMPANION_BUTTON_STOP,COMPANION_BUTTON_UNLOCK };
bool companion_parse_status(const uint8_t *bytes,size_t length,companion_status *status);
bool companion_stop_latch(companion_stop *stop);
bool companion_stop_is_latched(const companion_stop *stop);
bool companion_command_allowed(const companion_stop *stop,uint8_t opcode);
void companion_stop_unlock(companion_stop *stop);
void companion_stop_bytes(const companion_stop *stop,uint8_t bytes[COMPANION_STOP_SIZE]);
uint8_t companion_visible_phase(bool connected,bool secure,bool stopped,uint64_t now,
    uint64_t updated_at,const companion_status *status);
enum companion_button_event companion_button_sample(companion_button *button,bool ok,
    bool stopped,uint64_t now);
