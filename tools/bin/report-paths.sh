#!/bin/bash
# Shared report directory layout helpers.

resolve_report_dirs() {
    local reports_root="$1"
    REPORTS_DIR="$reports_root"
    PHASE1_DIR="${REPORTS_DIR}/phase1"
    PHASE2_DIR="${REPORTS_DIR}/phase2"
    PHASE3_DIR="${REPORTS_DIR}/phase3"
    CONTEXT_DIR="${REPORTS_DIR}/context"
    LOGS_DIR="${REPORTS_DIR}/logs"
    QUOTA_LEDGER="${LOGS_DIR}/quota-ledger.jsonl"
}

ensure_report_dirs() {
    mkdir -p "$REPORTS_DIR" "$PHASE1_DIR" "$PHASE2_DIR" "$PHASE3_DIR" "$CONTEXT_DIR" "$LOGS_DIR"
}

threat_context_path_for_slug() {
    printf '%s/%s-threat-context.json\n' "$CONTEXT_DIR" "$1"
}

threat_context_rel_for_slug() {
    printf 'reports/context/%s-threat-context.json\n' "$1"
}

logs_slug_dir() {
    printf '%s/%s\n' "$LOGS_DIR" "$1"
}

logs_phase_dir() {
    printf '%s/%s\n' "$(logs_slug_dir "$1")" "$2"
}

logs_phase1_dir() {
    logs_phase_dir "$1" phase1
}

logs_phase2_dir() {
    logs_phase_dir "$1" phase2
}

logs_phase2_worker_dir() {
    printf '%s/worker\n' "$(logs_phase2_dir "$1")"
}

logs_phase2_reviewer_dir() {
    printf '%s/reviewer\n' "$(logs_phase2_dir "$1")"
}

logs_phase2_chunked_dir() {
    printf '%s/chunked\n' "$(logs_phase2_dir "$1")"
}

logs_phase2_chunked_agents_dir() {
    printf '%s/agents\n' "$(logs_phase2_chunked_dir "$1")"
}

logs_phase2_chunked_agent_dir() {
    printf '%s/%s\n' "$(logs_phase2_chunked_agents_dir "$1")" "$2"
}

logs_phase2_cluster_dir() {
    printf '%s/cluster\n' "$(logs_phase2_dir "$1")"
}

logs_phase3_dir() {
    logs_phase_dir "$1" phase3
}

logs_phase3_providers_dir() {
    printf '%s/providers\n' "$(logs_phase3_dir "$1")"
}

logs_phase1_run_err_path() {
    printf '%s/run.err\n' "$(logs_phase1_dir "$1")"
}

logs_phase1_run_live_path() {
    printf '%s/run.live.log\n' "$(logs_phase1_dir "$1")"
}

logs_phase1_semgrep_err_path() {
    printf '%s/semgrep.err\n' "$(logs_phase1_dir "$1")"
}

logs_phase1_psalm_err_path() {
    printf '%s/psalm.err\n' "$(logs_phase1_dir "$1")"
}

logs_phase2_run_err_path() {
    if [ "${2:-deep}" = "quick" ]; then
        printf '%s/quick.err\n' "$(logs_phase2_dir "$1")"
    else
        printf '%s/run.err\n' "$(logs_phase2_dir "$1")"
    fi
}

logs_phase2_run_live_path() {
    if [ "${2:-deep}" = "quick" ]; then
        printf '%s/quick.live.log\n' "$(logs_phase2_dir "$1")"
    else
        printf '%s/run.live.log\n' "$(logs_phase2_dir "$1")"
    fi
}

logs_phase2_worker_err_path() {
    local slug="$1"
    local provider="$2"
    local round="$3"
    local label="${4:-}"
    local dir
    dir="$(logs_phase2_worker_dir "$slug")"
    if [ -n "$label" ]; then
        printf '%s/r%s.%s.%s.err\n' "$dir" "$round" "$provider" "$label"
    else
        printf '%s/r%s.%s.err\n' "$dir" "$round" "$provider"
    fi
}

logs_phase2_reviewer_err_path() {
    local slug="$1"
    local provider="$2"
    local round="$3"
    local label="${4:-}"
    local dir
    dir="$(logs_phase2_reviewer_dir "$slug")"
    if [ -n "$label" ]; then
        printf '%s/r%s.%s.%s.err\n' "$dir" "$round" "$provider" "$label"
    else
        printf '%s/r%s.%s.err\n' "$dir" "$round" "$provider"
    fi
}

logs_phase2_cluster_run_err_path() {
    printf '%s/run.err\n' "$(logs_phase2_cluster_dir "$1")"
}

logs_phase2_cluster_run_live_path() {
    printf '%s/run.live.log\n' "$(logs_phase2_cluster_dir "$1")"
}

logs_phase2_cluster_stage_log_path() {
    printf '%s/%s.%s.log\n' "$(logs_phase2_cluster_dir "$1")" "$2" "$3"
}

logs_phase2_cluster_stage_last_message_path() {
    printf '%s/%s.%s.last-message.txt\n' "$(logs_phase2_cluster_dir "$1")" "$2" "$3"
}

logs_phase2_chunked_failures_path() {
    printf '%s/failures.json\n' "$(logs_phase2_chunked_dir "$1")"
}

logs_phase2_chunked_agent_run_log_path() {
    printf '%s/run.log\n' "$(logs_phase2_chunked_agent_dir "$1" "$2")"
}

logs_phase2_chunked_agent_run_live_path() {
    printf '%s/run.live.log\n' "$(logs_phase2_chunked_agent_dir "$1" "$2")"
}

logs_phase2_chunked_agent_last_message_path() {
    printf '%s/last-message.txt\n' "$(logs_phase2_chunked_agent_dir "$1" "$2")"
}

logs_phase2_chunked_agent_review_log_path() {
    printf '%s/review.r%s.log\n' "$(logs_phase2_chunked_agent_dir "$1" "$2")" "${3:-1}"
}

logs_phase2_chunked_agent_review_last_message_path() {
    printf '%s/review.r%s.last-message.txt\n' "$(logs_phase2_chunked_agent_dir "$1" "$2")" "${3:-1}"
}

logs_phase2_chunked_agent_revision_log_path() {
    printf '%s/revision.r%s.log\n' "$(logs_phase2_chunked_agent_dir "$1" "$2")" "${3:-1}"
}

logs_phase2_chunked_agent_revision_last_message_path() {
    printf '%s/revision.r%s.last-message.txt\n' "$(logs_phase2_chunked_agent_dir "$1" "$2")" "${3:-1}"
}

logs_phase3_provider_err_path() {
    printf '%s/%s.err\n' "$(logs_phase3_providers_dir "$1")" "$2"
}

logs_phase3_provider_live_path() {
    printf '%s/%s.live.log\n' "$(logs_phase3_providers_dir "$1")" "$2"
}

logs_phase3_run_err_path() {
    printf '%s/run.err\n' "$(logs_phase3_dir "$1")"
}

logs_phase3_run_live_path() {
    printf '%s/run.live.log\n' "$(logs_phase3_dir "$1")"
}
