#!/usr/bin/env bash
# Host fixture only: no serial ports, phones, flashing, or real credentials.
set -euo pipefail
board_repo_root=$(cd "$(dirname "$0")/.." && pwd)
board_auth_build="$board_repo_root/.build/board-auth-fixture"
board_auth_project="$board_repo_root/Firmware/Passport-BLE"
board_auth_flags=(-std=c11 -g -O1 -Wall -Wextra -Werror "-fsanitize=${BOARD_SANITIZERS:-undefined}")
board_auth_includes=(-I "$board_auth_project/tests/board_auth_stubs" -I "$board_auth_project/main")
board_auth_link=(-lcrypto)
board_auth_openssl_prefix=${BOARD_AUTH_OPENSSL_PREFIX:-}
if [[ -z "$board_auth_openssl_prefix" && -f /opt/homebrew/opt/openssl@3/include/openssl/hmac.h ]]; then
    board_auth_openssl_prefix=/opt/homebrew/opt/openssl@3
fi
if [[ -n "$board_auth_openssl_prefix" ]]; then
    if [[ ! -f "$board_auth_openssl_prefix/include/openssl/hmac.h" ]]; then
        printf '%s\n' 'BOARD_AUTH_OPENSSL_PREFIX must point to an installed OpenSSL development prefix.' >&2
        exit 2
    fi
    board_auth_includes+=(-I "$board_auth_openssl_prefix/include")
    board_auth_link=(-L "$board_auth_openssl_prefix/lib" -lcrypto)
fi
mkdir -p "$board_auth_build"
"${CC:-clang}" "${board_auth_flags[@]}" "${board_auth_includes[@]}" \
    "$board_auth_project/main/board_auth.c" "$board_auth_project/tests/board_auth_fixture.c" \
    "${board_auth_link[@]}" -o "$board_auth_build/auth"
"$board_auth_build/auth"
