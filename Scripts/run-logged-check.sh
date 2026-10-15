#!/usr/bin/env bash
# Keep the tool/CI exit status consistent with the result saved in the log.
set -euo pipefail

if [[ $# -lt 2 ]]; then
    printf 'Usage: %s LOG_FILE COMMAND [ARG ...]\n' "$0" >&2
    exit 2
fi

check_log=$1
shift
mkdir -p "$(dirname "$check_log")"
if ! (set -o noclobber; : > "$check_log") 2>/dev/null; then
    printf 'Cannot create log (existing results are preserved): %s\n' "$check_log" >&2
    exit 2
fi

if "$@" > "$check_log" 2>&1; then
    check_exit=0
else
    check_exit=$?
fi
printf '\nexit=%s\n' "$check_exit" >> "$check_log"
printf 'exit=%s; log=%s\n' "$check_exit" "$check_log"
exit "$check_exit"
