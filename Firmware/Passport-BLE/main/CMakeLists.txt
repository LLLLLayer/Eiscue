# SPDX-License-Identifier: Apache-2.0
idf_component_register(SRCS "main.c" "hid_peripheral.c" "command_protocol.c"
    INCLUDE_DIRS "." PRIV_REQUIRES bt nvs_flash)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Werror)
