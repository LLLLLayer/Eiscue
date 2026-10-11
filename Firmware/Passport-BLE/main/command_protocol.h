// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdbool.h>
#include <stdint.h>

#define EISCUE_COMMAND_SIZE 16
#define EISCUE_RESPONSE_SIZE 8
#define EISCUE_PROTOCOL_VERSION 1

enum eiscue_opcode { EISCUE_STOP = 0, EISCUE_MOVE = 1, EISCUE_CLICK = 2,
                     EISCUE_ASCII = 3, EISCUE_KEY = 4, EISCUE_ABS_POINT = 5,
                     EISCUE_KEY_COMBO = 6, EISCUE_INFO = 7 };
enum eiscue_status { EISCUE_SENT = 0, EISCUE_ARGUMENT = 1, EISCUE_INSECURE = 2,
                     EISCUE_BUSY = 3, EISCUE_NOT_SUBSCRIBED = 4, EISCUE_SEND_FAILED = 5 };
enum eiscue_report_kind { EISCUE_MOUSE_REPORT = 1, EISCUE_KEYBOARD_REPORT = 2,
                          EISCUE_ABSOLUTE_REPORT = 3 };
typedef struct { uint8_t kind, length, bytes[8]; } eiscue_report;
typedef struct { eiscue_report reports[2]; uint8_t count; } eiscue_action;

// No BLE, timers, pointers, or unbounded text in the command parser.
bool eiscue_parse_action(const uint8_t command[EISCUE_COMMAND_SIZE], eiscue_action *action);
void eiscue_make_response(const uint8_t command[EISCUE_COMMAND_SIZE],
    uint8_t status, uint8_t emitted, bool secure, uint8_t response[EISCUE_RESPONSE_SIZE]);
