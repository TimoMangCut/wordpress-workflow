#!/bin/bash
# run-pipeline.sh - Pipeline runner with optional multi-agent orchestration.
# Freshness-aware: downstream stages decide when to skip.
#
# Modes:
#   default      -> Phase 2 (+ cluster consensus) + Phase 3 using existing Phase 1 IR artifacts
#   --multi-agent
#                -> specific slug: Phase 1 -> Prep -> Orchestrate -> Phase 3
#                -> no slug: Prep -> Orchestrate -> Phase 3 for existing Phase 1 IR artifacts
#
# Usage:
#   run-pipeline.sh <slug> [options]
#   run-pipeline.sh --slug <slug> [options]
#   run-pipeline.sh [options]

set -euo pipefail

SPECIFIC_SLUG=""
MULTI_AGENT=false
APPLY_REVIEW=false
LLM_MODE="auto"
PARALLEL_LIMIT=""
TIMEOUT_OVERRIDE=""
RESUME_MISSING_ONLY=false

TOOLS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "${TOOLS_DIR}/.." && pwd)"
PLUGINS_DIR="${ROOT_DIR}/plugins"
ARTIFACT_FRESHNESS_BIN="${TOOLS_DIR}/bin/artifact_freshness.py"
THREAT_CONTEXT_GENERATOR="${TOOLS_DIR}/bin/generate_threat_context.py"
THREAT_PROFILES_PATH="${TOOLS_DIR}/data/threat-profiles.json"

source "${TOOLS_DIR}/bin/report-paths.sh"
source "${TOOLS_DIR}/bin/console-ui.sh"
resolve_report_dirs "${ROOT_DIR}/reports"
ensure_report_dirs

usage() {
    cat <<'EOF'
Usage:
  run-pipeline.sh <slug> [options]
  run-pipeline.sh --slug <slug> [options]
  run-pipeline.sh [options]

Options:
  --slug <slug>            Run one plugin slug.
  --multi-agent            Run Prep -> Orchestrate -> Phase 3 instead of run-phase2.sh.
  --parallel-limit <N>     Pass through to orchestrate-agents.sh in multi-agent mode.
  --timeout <N>            Pass through to orchestrate-agents.sh in multi-agent mode.
  --resume-missing-only    Pass through to orchestrate-agents.sh in multi-agent mode.
  --apply-review           Pass through to run-phase3.sh.
  --llm-mode <mode>        Pass through to run-phase3.sh (default: auto).
  -h, --help               Show this help message.

Notes:
  - Default mode uses existing Phase 1 IR files and runs Phase 2 + cluster consensus + Phase 3.
  - In multi-agent mode, a specific slug triggers scan-all.sh first so threat
    context and Phase 1 artifacts are refreshed before prep/orchestration.
  - Multi-agent mode without --slug uses existing Phase 1 IR files and refreshes
    threat context per slug when plugin source is still present.
EOF
}

if [ $# -eq 1 ] && [[ "${1:-}" != --* ]]; then
    SPECIFIC_SLUG="$1"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --slug)
            SPECIFIC_SLUG="${2:-}"
            shift 2
            ;;
        --multi-agent)
            MULTI_AGENT=true
            shift
            ;;
        --parallel-limit)
            PARALLEL_LIMIT="${2:-}"
            shift 2
            ;;
        --timeout)
            TIMEOUT_OVERRIDE="${2:-}"
            shift 2
            ;;
        --resume-missing-only)
            RESUME_MISSING_ONLY=true
            shift
            ;;
        --apply-review)
            APPLY_REVIEW=true
            shift
            ;;
        --llm-mode)
            LLM_MODE="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [[ "$1" == --* ]]; then
                log_error "Unknown option: $1"
                usage
                exit 1
            fi
            if [ -n "$SPECIFIC_SLUG" ] && [ "$SPECIFIC_SLUG" != "$1" ]; then
                log_error "Too many positional arguments: '$SPECIFIC_SLUG' and '$1'"
                usage
                exit 1
            fi
            SPECIFIC_SLUG="$1"
            shift
            ;;
    esac
done

freshness_is_fresh() {
    local output="$1"
    shift

    local cmd=(python3 "$ARTIFACT_FRESHNESS_BIN" is-fresh --output "$output")
    local path
    for path in "$@"; do
        [ -n "$path" ] || continue
        [ -e "$path" ] || continue
        cmd+=(--input "$path")
    done

    "${cmd[@]}" >/dev/null 2>&1
}

collect_ir_files() {
    if [ -n "$SPECIFIC_SLUG" ]; then
        if [ -f "${PHASE1_DIR}/${SPECIFIC_SLUG}-ir.json" ]; then
            printf '%s\n' "${PHASE1_DIR}/${SPECIFIC_SLUG}-ir.json"
        fi
        return 0
    fi
    find "${PHASE1_DIR}" -maxdepth 1 -type f -name '*-ir.json' | sort
}

agent_inputs_are_fresh() {
    local slug="$1"
    local ir_file="${PHASE1_DIR}/${slug}-ir.json"
    local semgrep_file="${PHASE1_DIR}/${slug}-semgrep.json"
    local prep_script="${TOOLS_DIR}/bin/prepare_agent_inputs.py"
    local dispatch_file="${REPORTS_DIR}/${slug}-dispatch.json"
    local candidate_inventory="${REPORTS_DIR}/${slug}-candidate-inventory.json"
    local -a inputs=("$ir_file" "$prep_script")
    local -a outputs=(
        "$dispatch_file"
        "$candidate_inventory"
        "${REPORTS_DIR}/${slug}-ir-slice-ajax-unauth.json"
        "${REPORTS_DIR}/${slug}-ir-slice-ajax-auth.json"
        "${REPORTS_DIR}/${slug}-ir-slice-rest.json"
        "${REPORTS_DIR}/${slug}-ir-slice-shortcode.json"
        "${REPORTS_DIR}/${slug}-ir-slice-other.json"
        "${REPORTS_DIR}/${slug}-semgrep-filtered-ajax-unauth.json"
        "${REPORTS_DIR}/${slug}-semgrep-filtered-ajax-auth.json"
        "${REPORTS_DIR}/${slug}-semgrep-filtered-rest.json"
        "${REPORTS_DIR}/${slug}-semgrep-filtered-shortcode.json"
        "${REPORTS_DIR}/${slug}-semgrep-filtered-other.json"
    )
    local output

    if [ -f "$semgrep_file" ]; then
        inputs+=("$semgrep_file")
    fi

    local -a candidate_bundles=()
    local bundle
    for bundle in "${REPORTS_DIR}/${slug}"-candidate-bundle-agent-w*.json; do
        [ -e "$bundle" ] || continue
        candidate_bundles+=("$bundle")
    done
    if [ ${#candidate_bundles[@]} -eq 0 ]; then
        return 1
    fi
    outputs+=("${candidate_bundles[@]}")

    for output in "${outputs[@]}"; do
        if ! freshness_is_fresh "$output" "${inputs[@]}"; then
            return 1
        fi
    done
    return 0
}

prepare_agent_inputs_for_slug() {
    local slug="$1"

    if [ ! -f "${PHASE1_DIR}/${slug}-ir.json" ]; then
        log_error_block "Phase 1 IR not found for prep" \
            "slug" "$slug" \
            "path" "${PHASE1_DIR}/${slug}-ir.json"
        return 1
    fi

    if agent_inputs_are_fresh "$slug"; then
        log_info "Skip ${slug}: agent inputs are fresh"
        return 0
    fi

    log_stage "Prep: ${slug}"
    python3 "${TOOLS_DIR}/bin/prepare_agent_inputs.py" "$slug"
}

ensure_threat_context_for_slug() {
    local slug="$1"
    local plugin_dir="${PLUGINS_DIR}/${slug}"
    local output
    output="$(threat_context_path_for_slug "$slug")"

    if [ ! -d "$plugin_dir" ]; then
        log_warn_block "Plugin source missing for threat context generation" \
            "slug" "$slug" \
            "path" "$plugin_dir"
        return 0
    fi

    if [ ! -f "$THREAT_CONTEXT_GENERATOR" ]; then
        log_warn "Threat context generator missing: $THREAT_CONTEXT_GENERATOR"
        return 0
    fi

    if freshness_is_fresh "$output" "$plugin_dir" "$THREAT_PROFILES_PATH" "$THREAT_CONTEXT_GENERATOR"; then
        log_info "Skip ${slug}: threat context is fresh"
        return 0
    fi

    log_stage "Threat Context: ${slug}"
    python3 "$THREAT_CONTEXT_GENERATOR" "$slug" \
        --plugins-dir "$PLUGINS_DIR" \
        --reports-dir "$REPORTS_DIR" \
        --profiles "$THREAT_PROFILES_PATH"
}

run_phase3_for_slug() {
    local slug="$1"
    local cmd=(bash "${TOOLS_DIR}/bin/run-phase3.sh" --slug "$slug" --llm-mode "$LLM_MODE")
    if [ "$APPLY_REVIEW" = true ]; then
        cmd+=(--apply-review)
    fi
    "${cmd[@]}"
}

run_default_pipeline_for_slug() {
    local slug="$1"
    local phase2_ok=true
    echo ""
    if ! bash "${TOOLS_DIR}/bin/run-phase2.sh" --slug "$slug"; then
        phase2_ok=false
        log_warn_block "Phase 2 error" "slug" "$slug"
    fi

    if [ "$phase2_ok" = true ] && [ -f "${PHASE2_DIR}/${slug}-phase2.json" ]; then
        log_stage "Phase 3: Gate Validation (+ optional LLM skeptic)"
        run_phase3_for_slug "$slug" || log_warn_block "Phase 3 error" "slug" "$slug"
    elif [ "$phase2_ok" != true ]; then
        log_warn_block "Skipping Phase 3 because Phase 2 failed" "slug" "$slug"
    fi
}

run_multi_agent_pipeline_for_slug() {
    local slug="$1"
    local plugin_dir="${PLUGINS_DIR}/${slug}"
    local orch_cmd=(bash "${TOOLS_DIR}/bin/orchestrate-agents.sh" "$slug")
    local orchestration_ok=true

    if [ -d "$plugin_dir" ] && [ -n "$SPECIFIC_SLUG" ]; then
        echo ""
        log_stage "Phase 1: ${slug}"
        bash "${TOOLS_DIR}/bin/scan-all.sh" "$plugin_dir" || log_warn_block "Phase 1 error" "slug" "$slug"
    fi

    ensure_threat_context_for_slug "$slug"

    if ! prepare_agent_inputs_for_slug "$slug"; then
        log_warn_block "Prep failed" "slug" "$slug"
        return 1
    fi

    if [ -n "$PARALLEL_LIMIT" ]; then
        orch_cmd+=(--parallel-limit "$PARALLEL_LIMIT")
    fi
    if [ -n "$TIMEOUT_OVERRIDE" ]; then
        orch_cmd+=(--timeout "$TIMEOUT_OVERRIDE")
    fi
    if [ "$RESUME_MISSING_ONLY" = true ]; then
        orch_cmd+=(--resume-missing-only)
    fi

    echo ""
    log_stage "Phase 2 Orchestration: ${slug}"
    if ! "${orch_cmd[@]}"; then
        orchestration_ok=false
        log_warn_block "Orchestration error" "slug" "$slug"
    fi

    if [ "$orchestration_ok" = true ] && [ -f "${PHASE2_DIR}/${slug}-phase2.json" ]; then
        log_stage "Phase 3: Gate Validation (+ optional LLM skeptic)"
        run_phase3_for_slug "$slug" || log_warn_block "Phase 3 error" "slug" "$slug"
    elif [ "$orchestration_ok" != true ]; then
        log_warn_block "Skipping Phase 3 because orchestration failed" "slug" "$slug"
    else
        log_warn_block "Canonical Phase 2 output missing after orchestration" \
            "slug" "$slug" \
            "path" "${PHASE2_DIR}/${slug}-phase2.json"
    fi
}

log_section "Pipeline"
if [ "$MULTI_AGENT" = true ]; then
    echo "  Mode: multi-agent"
else
    echo "  Mode: phase2+phase3"
fi

IR_FILE_ARRAY=()
while IFS= read -r ir_file; do
    [ -n "$ir_file" ] || continue
    IR_FILE_ARRAY+=("$ir_file")
done < <(collect_ir_files)

if [ "$MULTI_AGENT" = true ] && [ -n "$SPECIFIC_SLUG" ] && [ ${#IR_FILE_ARRAY[@]} -eq 0 ]; then
    if [ ! -d "${PLUGINS_DIR}/${SPECIFIC_SLUG}" ]; then
        log_error_block "Plugin source not found" \
            "slug" "$SPECIFIC_SLUG" \
            "path" "${PLUGINS_DIR}/${SPECIFIC_SLUG}"
        exit 1
    fi
    IR_FILE_ARRAY=("${PHASE1_DIR}/${SPECIFIC_SLUG}-ir.json")
fi

if [ ${#IR_FILE_ARRAY[@]} -eq 0 ]; then
    log_error "No Phase 1 IR files found"
    exit 1
fi

for ir_file in "${IR_FILE_ARRAY[@]}"; do
    slug="$(basename "$ir_file" -ir.json)"
    if [ "$MULTI_AGENT" = true ]; then
        run_multi_agent_pipeline_for_slug "$slug"
    else
        run_default_pipeline_for_slug "$slug"
    fi
done

echo ""
log_section "Pipeline Complete"

for f in "${PHASE3_DIR}"/*.md; do
    [ -f "$f" ] || continue
    echo "  $(basename "$f")"
done
