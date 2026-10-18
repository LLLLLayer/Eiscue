#!/usr/bin/env bash
# Host-only BLE report/descriptor fixture. Never opens serial or contacts a phone.
set -euo pipefail
button_root=$(cd "$(dirname "$0")/.." && pwd)
button_project="$button_root/Firmware/Passport-BLE"
button_build="$button_root/.build/board-ble-button-source-fixture"
mkdir -p "$button_build"
"${CC:-clang}" -std=c11 -O1 -g -Wall -Wextra -Werror \
    "-fsanitize=${BOARD_SANITIZERS:-undefined}" -I "$button_project/main" \
    "$button_project/main/command_protocol.c" "$button_project/tests/ble_button_source_fixture.c" \
    -o "$button_build/ble-button-source"
"$button_build/ble-button-source"
