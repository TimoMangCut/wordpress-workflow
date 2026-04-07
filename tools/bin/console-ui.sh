#!/bin/bash
# Shared plain-text console formatting helpers for workflow scripts.

log_section() {
    printf '=== %s ===\n' "$*"
}

log_stage() {
    printf -- '--- %s ---\n' "$*"
}

log_info() {
    printf '[INFO] %s\n' "$*"
}

log_ok() {
    printf '[OK] %s\n' "$*"
}

log_warn() {
    printf '[WARN] %s\n' "$*"
}

log_error() {
    printf '[ERROR] %s\n' "$*"
}

log_kv() {
    printf '  - %s: %s\n' "$1" "$2"
}

log_warn_block() {
    local title="$1"
    shift
    log_warn "$title"
    while [ "$#" -ge 2 ]; do
        log_kv "$1" "$2"
        shift 2
    done
}

log_error_block() {
    local title="$1"
    shift
    log_error "$title"
    while [ "$#" -ge 2 ]; do
        log_kv "$1" "$2"
        shift 2
    done
}

timestamp_utc() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

append_log_marker() {
    local path="$1"
    shift
    [ -n "$path" ] || return 0
    mkdir -p "$(dirname "$path")"
    printf '[%s] %s\n' "$(timestamp_utc)" "$*" >> "$path"
}

reset_log_file() {
    local path="$1"
    [ -n "$path" ] || return 0
    mkdir -p "$(dirname "$path")"
    : > "$path"
}

live_log_path_from_errlog() {
    local errlog="$1"
    printf '%s\n' "${errlog%.err}.live.log"
}

run_command_with_live_logs() {
    local live_log="$1"
    local err_log="$2"
    shift 2

    mkdir -p "$(dirname "$live_log")" "$(dirname "$err_log")"

    set +e
    "$@" \
        > >(tee -a "$live_log") \
        2> >(tee -a "$err_log" "$live_log" >&2)
    local rc=$?
    set -e
    return "$rc"
}
