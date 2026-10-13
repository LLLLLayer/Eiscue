# SPDX-License-Identifier: Apache-2.0
set(board_sources "main.c" "hid_peripheral.c" "command_protocol.c" "usb_hid.c")
set(board_dependencies bt nvs_flash)
if(IDF_TARGET STREQUAL "esp32c3")
    list(APPEND board_sources "companion.c" "companion_protocol.c" "companion_assets.c" "companion_text.c")
    list(APPEND board_dependencies esp_lcd esp_adc esp_driver_spi esp_driver_gpio esp_timer)
endif()
if(IDF_TARGET STREQUAL "esp32s3")
    list(APPEND board_sources "board_auth.c")
    list(APPEND board_dependencies mbedtls esp_timer)
endif()
idf_component_register(SRCS ${board_sources}
    INCLUDE_DIRS "." PRIV_REQUIRES ${board_dependencies})
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Werror)
