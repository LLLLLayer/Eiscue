#!/usr/bin/env bash
# Build only. Never opens serial, resets hardware or writes Flash.
set -euo pipefail
source "$(dirname "$0")/board-idf-env.sh"
board_project="$board_repo_root/Firmware/Passport-BLE"
board_target=${1:-esp32c3}
case "$board_target" in
    esp32c3) board_build="$board_repo_root/.build/passport-ble-firmware" ;;
    esp32s3) board_build="$board_repo_root/.build/s3-hid-firmware" ;;
    *) printf '%s\n' 'Usage: build-passport-ble.sh [esp32c3|esp32s3]' >&2; exit 2 ;;
esac
mkdir -p "$board_build"
idf.py -C "$board_project" -B "$board_build" \
    -D "IDF_TARGET=$board_target" \
    -D "SDKCONFIG=$board_build/sdkconfig" \
    -D "SDKCONFIG_DEFAULTS=$board_project/sdkconfig.defaults;$board_project/sdkconfig.defaults.$board_target" build
