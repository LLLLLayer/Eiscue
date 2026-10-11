#!/usr/bin/env bash
# UBSan protocol and localhost transport tests, never hardware tests.
set -euo pipefail
board_repo_root=$(cd "$(dirname "$0")/.." && pwd)
if [[ ! -f "${IDF_PATH:-}/components/json/cJSON/cJSON.c" ]]; then
    printf '%s\n' 'Set IDF_PATH to an ESP-IDF v5.5.3 checkout for the cJSON source.' >&2
    exit 2
fi
board_project="$board_repo_root/Firmware/NCM-Relay"
board_build="$board_repo_root/.build/ncm-relay-host-tests"
mkdir -p "$board_build"
board_json="$IDF_PATH/components/json/cJSON"
board_core="$board_project/core"
board_bridge="$board_project/bridge"
board_flags=(-std=c11 -g -O1 -Wall -Wextra -Werror "-fsanitize=${BOARD_SANITIZERS:-undefined}")
board_includes=(-I "$board_core" -I "$board_bridge/include" -I "$board_json")
"${CC:-clang}" "${board_flags[@]}" -Wno-deprecated-declarations -I "$board_json" \
    -c "$board_json/cJSON.c" -o "$board_build/cJSON.o"
"${CC:-clang}" "${board_flags[@]}" "${board_includes[@]}" \
    "$board_project/tests/test_core.c" "$board_core"/*.c "$board_bridge"/*.c \
    "$board_build/cJSON.o" -o "$board_build/core"
"$board_build/core"
"${CC:-clang}" "${board_flags[@]}" "${board_includes[@]}" \
    "$board_project/tests/test_socket.c" \
    "$board_core"/{nd_discovery,nd_pairing,nd_socket,nd_server}.c \
    "$board_bridge"/{bridge_io,bridge_bplist,bridge_lockdown_probe}.c \
    "$board_build/cJSON.o" -pthread -o "$board_build/socket"
"$board_build/socket"
"${CC:-clang}" "${board_flags[@]}" "${board_includes[@]}" \
    "$board_project/tests/test_relay.c" "$board_core"/{nd_discovery,nd_socket,nd_relay}.c \
    "$board_bridge/bridge_io.c" -pthread -o "$board_build/relay"
"$board_build/relay"
python3 -m unittest discover -s "$board_project/tests" -p 'test_*.py'
