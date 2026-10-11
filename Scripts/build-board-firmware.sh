#!/usr/bin/env bash
# Build only. No serial port is opened and no board or phone is modified.
set -euo pipefail
source "$(dirname "$0")/board-idf-env.sh"
board_project="$board_repo_root/Firmware/NCM-Relay"
board_build="$board_repo_root/.build/ncm-relay-firmware"
mkdir -p "$board_build"
idf.py -C "$board_project" -B "$board_build" \
    -D "SDKCONFIG=$board_build/sdkconfig" build
python3 "$board_repo_root/Scripts/board-firmware.py" package --build-dir "$board_build"
