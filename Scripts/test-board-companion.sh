#!/usr/bin/env bash
# Host-only state fixture. Does not open a serial port or access a phone.
set -euo pipefail
companion_root=$(cd "$(dirname "$0")/.." && pwd)
companion_project="$companion_root/Firmware/Passport-BLE"
companion_build="$companion_root/.build/board-companion-fixture"
mkdir -p "$companion_build"
"${CC:-clang}" -std=c11 -O1 -g -Wall -Wextra -Werror \
    "-fsanitize=${BOARD_SANITIZERS:-undefined}" -I "$companion_project/main" \
    "$companion_project/main/companion_protocol.c" "$companion_project/main/companion_assets.c" \
    "$companion_project/main/companion_text.c" "$companion_project/tests/companion_fixture.c" \
    -o "$companion_build/companion"
"$companion_build/companion"
