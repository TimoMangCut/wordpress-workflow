#!/bin/bash
# Shared report directory layout helpers.

resolve_report_dirs() {
    local reports_root="$1"
    REPORTS_DIR="$reports_root"
    PHASE1_DIR="${REPORTS_DIR}/phase1"
    PHASE2_DIR="${REPORTS_DIR}/phase2"
    PHASE3_DIR="${REPORTS_DIR}/phase3"
    CONTEXT_DIR="${REPORTS_DIR}/context"
    COST_DIR="${REPORTS_DIR}/cost"
    LOGS_DIR="${REPORTS_DIR}/logs"
    QUOTA_LEDGER="${LOGS_DIR}/quota-ledger.jsonl"
}

ensure_report_dirs() {
    mkdir -p "$REPORTS_DIR" "$PHASE1_DIR" "$PHASE2_DIR" "$PHASE3_DIR" "$CONTEXT_DIR" "$COST_DIR" "$LOGS_DIR"
}

threat_context_path_for_slug() {
    printf '%s/%s-threat-context.json\n' "$CONTEXT_DIR" "$1"
}

threat_context_rel_for_slug() {
    printf 'reports/context/%s-threat-context.json\n' "$1"
}

cost_slug_dir_path_for_slug() {
    printf '%s/%s\n' "$COST_DIR" "$1"
}

cost_run_summary_path_for_slug() {
    printf '%s/%s.cost.json\n' "$(cost_slug_dir_path_for_slug "$1")" "$2"
}

cost_tracking_snapshot_path_for_slug() {
    printf '%s/%s.tracking.%s.json\n' "$(cost_slug_dir_path_for_slug "$1")" "$2" "$3"
}

phase2_prep_dir_path_for_slug() {
    printf '%s/prep/%s\n' "$PHASE2_DIR" "$1"
}

phase2_prep_candidate_bundles_dir_path_for_slug() {
    printf '%s/candidate-bundles\n' "$(phase2_prep_dir_path_for_slug "$1")"
}

phase2_prep_legacy_slices_dir_path_for_slug() {
    printf '%s/legacy-slices\n' "$(phase2_prep_dir_path_for_slug "$1")"
}

phase2_dispatch_path_for_slug() {
    printf '%s/dispatch.json\n' "$(phase2_prep_dir_path_for_slug "$1")"
}

phase2_dispatch_manifest_path_for_slug() {
    printf '%s/dispatch.manifest.json\n' "$(phase2_prep_dir_path_for_slug "$1")"
}

phase2_candidate_inventory_path_for_slug() {
    printf '%s/candidate-inventory.json\n' "$(phase2_prep_dir_path_for_slug "$1")"
}

phase2_candidate_bundle_path_for_slug() {
    printf '%s/%s.input.json\n' "$(phase2_prep_candidate_bundles_dir_path_for_slug "$1")" "$2"
}

phase2_legacy_ir_slice_path_for_slug() {
    printf '%s/%s-ir-slice-%s.json\n' "$(phase2_prep_legacy_slices_dir_path_for_slug "$1")" "$1" "$2"
}

phase2_legacy_semgrep_slice_path_for_slug() {
    printf '%s/%s-semgrep-filtered-%s.json\n' "$(phase2_prep_legacy_slices_dir_path_for_slug "$1")" "$1" "$2"
}

phase2_agents_dir_path_for_slug() {
    printf '%s/agents/%s\n' "$PHASE2_DIR" "$1"
}

phase2_agent_attempts_dir_path_for_slug() {
    printf '%s/attempts\n' "$(phase2_agents_dir_path_for_slug "$1")"
}

phase2_agent_output_path_for_slug() {
    printf '%s/%s.output.json\n' "$(phase2_agents_dir_path_for_slug "$1")" "$2"
}

phase2_agent_attempt_output_path_for_slug() {
    printf '%s/%s.attempt-%02d.output.json\n' "$(phase2_agent_attempts_dir_path_for_slug "$1")" "$2" "$3"
}

phase2_agent_attempt_normalized_output_path_for_slug() {
    printf '%s/%s.attempt-%02d.normalized.json\n' "$(phase2_agent_attempts_dir_path_for_slug "$1")" "$2" "$3"
}

phase2_agent_review_path_for_slug() {
    printf '%s/%s.review.r%s.json\n' "$(phase2_agents_dir_path_for_slug "$1")" "$2" "${3:-1}"
}

phase2_agent_revision_path_for_slug() {
    printf '%s/%s.revision.r%s.json\n' "$(phase2_agents_dir_path_for_slug "$1")" "$2" "${3:-1}"
}

phase2_agent_revision_normalized_path_for_slug() {
    printf '%s/%s.revision.r%s.normalized.json\n' "$(phase2_agents_dir_path_for_slug "$1")" "$2" "${3:-1}"
}

phase2_agent_worker_snapshot_path_for_slug() {
    printf '%s/%s.worker.initial.json\n' "$(phase2_agents_dir_path_for_slug "$1")" "$2"
}

phase2_merge_ready_path_for_slug() {
    printf '%s/merge-ready\n' "$(phase2_agents_dir_path_for_slug "$1")"
}

phase2_merged_archive_path_for_slug() {
    printf '%s/%s-phase2.merged.json\n' "$PHASE2_DIR" "$1"
}

phase2_local_output_path_for_slug() {
    printf '%s/%s-phase2.local.json\n' "$PHASE2_DIR" "$1"
}

phase2_state_path_for_slug() {
    printf '%s/%s-phase2.state.json\n' "$PHASE2_DIR" "$1"
}

phase2_provider_policy_path_for_slug() {
    printf '%s/%s-provider-policy.json\n' "$PHASE2_DIR" "$1"
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

logs_phase2_chunked_run_err_path() {
    printf '%s/run.err\n' "$(logs_phase2_chunked_dir "$1")"
}

logs_phase2_chunked_run_live_path() {
    printf '%s/run.live.log\n' "$(logs_phase2_chunked_dir "$1")"
}

logs_phase2_chunked_agents_dir() {
    printf '%s/agents\n' "$(logs_phase2_chunked_dir "$1")"
}

logs_phase2_chunked_agent_dir() {
    printf '%s/%s\n' "$(logs_phase2_chunked_agents_dir "$1")" "$2"
}

logs_phase2_chunked_agent_attempt_dir() {
    printf '%s/attempt-%02d\n' "$(logs_phase2_chunked_agent_dir "$1" "$2")" "${3:-1}"
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

logs_phase2_cluster_stage_raw_log_path() {
    printf '%s/%s.%s.raw.log\n' "$(logs_phase2_cluster_dir "$1")" "$2" "$3"
}

logs_phase2_cluster_stage_last_message_path() {
    printf '%s/%s.%s.last-message.txt\n' "$(logs_phase2_cluster_dir "$1")" "$2" "$3"
}

logs_phase2_chunked_failures_path() {
    printf '%s/failures.json\n' "$(logs_phase2_chunked_dir "$1")"
}

logs_phase2_chunked_run_summary_path() {
    printf '%s/run.summary.json\n' "$(logs_phase2_chunked_dir "$1")"
}

logs_phase2_chunked_agent_run_log_path() {
    printf '%s/stderr.err\n' "$(logs_phase2_chunked_agent_attempt_dir "$1" "$2" "${3:-1}")"
}

logs_phase2_chunked_agent_run_live_path() {
    printf '%s/assistant.live.log\n' "$(logs_phase2_chunked_agent_attempt_dir "$1" "$2" "${3:-1}")"
}

logs_phase2_chunked_agent_provider_raw_path() {
    printf '%s/provider.raw.log\n' "$(logs_phase2_chunked_agent_attempt_dir "$1" "$2" "${3:-1}")"
}

logs_phase2_chunked_agent_last_message_path() {
    printf '%s/last-message.txt\n' "$(logs_phase2_chunked_agent_attempt_dir "$1" "$2" "${3:-1}")"
}

logs_phase2_chunked_agent_review_log_path() {
    printf '%s/review.r%s.log\n' "$(logs_phase2_chunked_agent_dir "$1" "$2")" "${3:-1}"
}

logs_phase2_chunked_agent_review_live_log_path() {
    printf '%s/review.r%s.live.log\n' "$(logs_phase2_chunked_agent_dir "$1" "$2")" "${3:-1}"
}

logs_phase2_chunked_agent_review_last_message_path() {
    printf '%s/review.r%s.last-message.txt\n' "$(logs_phase2_chunked_agent_dir "$1" "$2")" "${3:-1}"
}

logs_phase2_chunked_agent_revision_log_path() {
    printf '%s/revision.r%s.log\n' "$(logs_phase2_chunked_agent_dir "$1" "$2")" "${3:-1}"
}

logs_phase2_chunked_agent_revision_live_log_path() {
    printf '%s/revision.r%s.live.log\n' "$(logs_phase2_chunked_agent_dir "$1" "$2")" "${3:-1}"
}

logs_phase2_chunked_agent_revision_last_message_path() {
    printf '%s/revision.r%s.last-message.txt\n' "$(logs_phase2_chunked_agent_dir "$1" "$2")" "${3:-1}"
}

logs_phase2_chunked_agent_review_raw_log_path() {
    printf '%s/review.r%s.raw.log\n' "$(logs_phase2_chunked_agent_dir "$1" "$2")" "${3:-1}"
}

logs_phase2_chunked_agent_revision_raw_log_path() {
    printf '%s/revision.r%s.raw.log\n' "$(logs_phase2_chunked_agent_dir "$1" "$2")" "${3:-1}"
}

logs_phase3_provider_err_path() {
    printf '%s/%s.err\n' "$(logs_phase3_providers_dir "$1")" "$2"
}

logs_phase3_provider_live_path() {
    printf '%s/%s.live.log\n' "$(logs_phase3_providers_dir "$1")" "$2"
}

logs_phase3_provider_raw_path() {
    printf '%s/%s.raw.log\n' "$(logs_phase3_providers_dir "$1")" "$2"
}

logs_phase3_run_err_path() {
    printf '%s/run.err\n' "$(logs_phase3_dir "$1")"
}

logs_phase3_run_live_path() {
    printf '%s/run.live.log\n' "$(logs_phase3_dir "$1")"
}
