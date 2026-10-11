#!/usr/bin/env bash
# Build only. Never opens serial, resets hardware or writes Flash.
set -euo pipefail
source "$(dirname "$0")/board-idf-env.sh"
board_project="$board_repo_root/Firmware/Passport-BLE"
board_build="$board_repo_root/.build/passport-ble-firmware"
mkdir -p "$board_build"
idf.py -C "$board_project" -B "$board_build" \
    -D "SDKCONFIG=$board_build/sdkconfig" build
