// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "sdkconfig.h"
#include "esp_err.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(CONFIG_IDF_TARGET_ESP32S3) && CONFIG_IDF_TARGET_ESP32S3
#define BOARD_AUTH_REQUIRED 1
#else
#define BOARD_AUTH_REQUIRED 0
#endif

#define BOARD_AUTH_VERSION 2
#define BOARD_AUTH_CHALLENGE_SIZE 34
#define BOARD_AUTH_REQUEST_SIZE 50
#define BOARD_AUTH_RESPONSE_SIZE 35
#define BOARD_AUTH_COMMAND_SIZE 52
#define BOARD_AUTH_REPLY_SIZE 44
#define BOARD_AUTH_ENROLL 1
#define BOARD_AUTH_PROVE 2

// Call after nvs_flash_init; never erases NVS or replaces an existing key.
esp_err_t board_auth_init(void);
// All calls after init are serialized on the BLE host task. Nonces last for
// exactly one connection, with one AUTH attempt to prevent sequence resets.
void board_auth_begin_connection(void);
void board_auth_end_connection(void);
void board_auth_get_challenge(uint8_t out[BOARD_AUTH_CHALLENGE_SIZE]);
// A false result requires disconnecting; no authenticated failure reply exists.
bool board_auth_handle_request(const uint8_t *data,size_t length,
    uint8_t out[BOARD_AUTH_RESPONSE_SIZE]);
bool board_auth_unwrap_command(const uint8_t *data,size_t length,
    uint8_t inner[16],uint32_t *sequence);
// Keep the accepted sequence with each pending action, including asynchronous
// release/STOP replies. A reply must not borrow a newer command's sequence.
bool board_auth_wrap_reply(const uint8_t inner[8],uint32_t sequence,
    uint8_t out[BOARD_AUTH_REPLY_SIZE]);
bool board_auth_is_authenticated(void);
bool board_auth_has_key(void);
