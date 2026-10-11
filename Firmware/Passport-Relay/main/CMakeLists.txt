# SPDX-License-Identifier: GPL-3.0-or-later
set(SHARED "${CMAKE_CURRENT_LIST_DIR}/../../NCM-Relay")
set(CORE "${SHARED}/core")
set(BRIDGE "${SHARED}/bridge")
idf_component_register(SRCS "main.c" "network.c" "${SHARED}/main/developer_service.c"
    "${CORE}/nd_discovery.c" "${CORE}/nd_pairing.c" "${CORE}/nd_socket.c"
    "${CORE}/nd_server.c" "${CORE}/nd_services.c" "${CORE}/nd_http.c" "${CORE}/nd_relay.c"
    "${BRIDGE}/bridge_xpc.c" "${BRIDGE}/bridge_hid.c" "${BRIDGE}/bridge_requests.c"
    "${BRIDGE}/bridge_screenshot_stream.c" "${BRIDGE}/bridge_remotexpc.c"
    "${BRIDGE}/bridge_rsd.c" "${BRIDGE}/bridge_operations.c"
    "${BRIDGE}/bridge_io.c" "${BRIDGE}/bridge_bplist.c" "${BRIDGE}/bridge_lockdown_probe.c"
    INCLUDE_DIRS "." "${SHARED}/main" "${CORE}" "${BRIDGE}/include"
    PRIV_REQUIRES esp_wifi esp_netif esp_event esp_timer nvs_flash json)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Werror)
