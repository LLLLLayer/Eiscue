#!/usr/bin/env bash
# Host-only protocol/planner fixture. Never opens serial or contacts a phone.
set -euo pipefail
relative_root=$(cd "$(dirname "$0")/.." && pwd)
relative_project="$relative_root/Firmware/Passport-BLE"
relative_build="$relative_root/.build/board-relative-drag-fixture"
mkdir -p "$relative_build"
"${CC:-clang}" -std=c11 -O1 -g -Wall -Wextra -Werror \
    "-fsanitize=${BOARD_SANITIZERS:-undefined}" -I "$relative_project/main" \
    "$relative_project/main/command_protocol.c" "$relative_project/tests/relative_drag_fixture.c" \
    -o "$relative_build/relative-drag"
"$relative_build/relative-drag"
