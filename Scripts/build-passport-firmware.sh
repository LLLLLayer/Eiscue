#!/usr/bin/env bash
# Build/package only. Does not open serial ports or modify devices.
set -euo pipefail
source "$(dirname "$0")/board-idf-env.sh"
board_project="$board_repo_root/Firmware/Passport-Relay"
board_build="$board_repo_root/.build/passport-relay-firmware"
mkdir -p "$board_build"
idf.py -C "$board_project" -B "$board_build" \
    -D "SDKCONFIG=$board_build/sdkconfig" -D IDF_TARGET=esp32c3 build
python3 "$board_repo_root/Scripts/board-firmware.py" package --target passport --build-dir "$board_build"
