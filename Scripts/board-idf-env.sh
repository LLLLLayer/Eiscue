#!/usr/bin/env bash
# Source this helper from board build/test scripts. It does not install tools.
set -euo pipefail
board_repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -z "${IDF_PATH:-}" ]]; then
    printf '%s\n' 'Set IDF_PATH to an ESP-IDF v5.5.3 checkout.' >&2
    exit 2
fi
board_idf_version=$(git -C "$IDF_PATH" describe --tags --exact-match 2>/dev/null || true)
if [[ "$board_idf_version" != v5.5.3 ]]; then
    printf 'Expected ESP-IDF v5.5.3, found %s\n' "${board_idf_version:-unversioned checkout}" >&2
    exit 2
fi
# export.sh chooses its matching Python environment and compiler; an explicit
# IDF_TOOLS_PATH can keep the entire toolchain outside global ESP-IDF state.
source "$IDF_PATH/export.sh" >/dev/null
