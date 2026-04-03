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
