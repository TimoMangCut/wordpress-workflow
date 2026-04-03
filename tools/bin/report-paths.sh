#!/bin/bash
# Shared report directory layout helpers.

resolve_report_dirs() {
    local reports_root="$1"
    REPORTS_DIR="$reports_root"
    PHASE1_DIR="${REPORTS_DIR}/phase1"
    PHASE2_DIR="${REPORTS_DIR}/phase2"
    PHASE3_DIR="${REPORTS_DIR}/phase3"
    LOGS_DIR="${REPORTS_DIR}/logs"
    QUOTA_LEDGER="${LOGS_DIR}/quota-ledger.jsonl"
}

ensure_report_dirs() {
    mkdir -p "$REPORTS_DIR" "$PHASE1_DIR" "$PHASE2_DIR" "$PHASE3_DIR" "$LOGS_DIR"
}
