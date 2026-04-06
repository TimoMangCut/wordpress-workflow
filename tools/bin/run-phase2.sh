#!/bin/bash
# run-phase2.sh - Phase 2 analysis with deterministic triage + optional parallel batch.
# Usage:
#   run-phase2.sh <plugin-slug>
#   run-phase2.sh --slug <plugin-slug> [--force] [--force-deep]
#   run-phase2.sh --start-index <N> --end-index <M> [--threads <N>] [--force] [--force-deep]
#   run-phase2.sh --interactive [--force] [--force-deep]

set -euo pipefail

BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$(cd "${BIN_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${TOOLS_DIR}/.." && pwd)"
source "${TOOLS_DIR}/bin/report-paths.sh"
source "${TOOLS_DIR}/bin/console-ui.sh"
source "${TOOLS_DIR}/bin/timeout-utils.sh"
resolve_report_dirs "${ROOT_DIR}/reports"
PLUGINS_DIR="${ROOT_DIR}/plugins"
ARTIFACT_FRESHNESS_BIN="${BIN_DIR}/artifact_freshness.py"

apply_project_claude_env_defaults() {
    local helper="${BIN_DIR}/load_claude_env.py"
    [ -f "$helper" ] || return 0

    local line key is_set
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        key="${line#export }"
        key="${key%%=*}"
        eval "is_set=\${${key}+x}"
        if [ -z "${is_set:-}" ]; then
            eval "$line"
        fi
    done < <(python3 "$helper" --root "$ROOT_DIR" 2>/dev/null || true)
}

apply_project_claude_env_defaults

SPECIFIC_SLUG=""
START_INDEX=1
END_INDEX=1000000
THREADS=1
FORCE=false
FORCE_DEEP=false
RESUME_EXISTING=false
INTERACTIVE=false
WITH_CLAUDE=false
PROVIDERS_EXPLICIT=false
RUN_RESULT=""
LLM_PROVIDERS="${LLM_PROVIDERS:-${LLM_PROVIDER:-}}"
CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_MODEL="${CODEX_MODEL:-${LLM_MODEL:-}}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_MODEL="${CLAUDE_MODEL:-${LLM_MODEL:-}}"
PHASE2_PRIMARY_PROVIDER="${PHASE2_PRIMARY_PROVIDER:-}"
PHASE2_PROVIDER_TIMEOUT_SECONDS="${PHASE2_PROVIDER_TIMEOUT_SECONDS:-600}"
PHASE2_WORKER_TIMEOUT_SECONDS="${PHASE2_WORKER_TIMEOUT_SECONDS:-900}"
PHASE2_REVISION_TIMEOUT_SECONDS="${PHASE2_REVISION_TIMEOUT_SECONDS:-600}"
PHASE2_REVIEWER_TIMEOUT_SECONDS="${PHASE2_REVIEWER_TIMEOUT_SECONDS:-600}"
PHASE2_EXPLORATION_TIMEOUT_SECONDS="${PHASE2_EXPLORATION_TIMEOUT_SECONDS:-300}"
PHASE2_ENABLE_CLUSTER_CONSENSUS="${PHASE2_ENABLE_CLUSTER_CONSENSUS:-true}"
PHASE2_CLUSTER_LIMIT="${PHASE2_CLUSTER_LIMIT:-}"
PHASE2_WORKER_PROVIDER="${PHASE2_WORKER_PROVIDER:-claude}"
PHASE2_REVIEWER_PROVIDER="${PHASE2_REVIEWER_PROVIDER:-codex}"
PHASE2_WORKER_CODEX_MODEL="${PHASE2_WORKER_CODEX_MODEL:-gpt-5.4}"
PHASE2_WORKER_CLAUDE_MODEL="${PHASE2_WORKER_CLAUDE_MODEL:-${CLAUDE_MODEL:-claude-sonnet-4.6}}"
PHASE2_REVIEWER_CODEX_MODEL="${PHASE2_REVIEWER_CODEX_MODEL:-gpt-5.4}"
PHASE2_REVIEWER_CLAUDE_MODEL="${PHASE2_REVIEWER_CLAUDE_MODEL:-claude-opus-4.6}"
PHASE2_MAX_REVIEW_ROUNDS="${PHASE2_MAX_REVIEW_ROUNDS:-1}"
PHASE2_ENABLE_FORCED_EXPLORATION="${PHASE2_ENABLE_FORCED_EXPLORATION:-true}"
PHASE2_MAX_EXPLORATION_CANDIDATES="${PHASE2_MAX_EXPLORATION_CANDIDATES:-3}"

START_SET=false
END_SET=false
THREADS_SET=false
WORKER_PROVIDER_EXPLICIT=false
REVIEWER_PROVIDER_EXPLICIT=false

usage() {
    cat <<'EOF'
Usage:
  run-phase2.sh <plugin-slug>
  run-phase2.sh --slug <plugin-slug> [--force] [--force-deep]
  run-phase2.sh --slug <plugin-slug> --resume-existing [--force] [--force-deep]
  run-phase2.sh --start-index <N> --end-index <M> [--threads <N>] [--force] [--force-deep]
  run-phase2.sh --interactive [--force] [--force-deep]

Options:
  --slug <slug>          Run one plugin.
  --start-index <N>      Batch start index (IR-order, 1-based).
  --end-index <N>        Batch end index (IR-order, 1-based).
  --threads <N>          Parallel workers for batch mode (default: 1).
  --interactive          Show index list and ask Start/End/Threads.
  --force                Re-run even if the existing phase2 output is still fresh.
  --force-deep           Skip quick-triage and always run deep prompt.
  --resume-existing      Resume from existing worker/review artifacts instead of restarting from round 1.
  --with-claude          Convenience flag: run both codex and claude.
  --provider <name>      Single LLM provider shorthand: codex|claude.
  --providers <list>     Provider list, comma-separated (for example: codex,claude).
  --model <name>         Set the same model for both providers.
  --codex-model <name>   Codex model override.
  --claude-model <name>  Claude model override.
  --primary-provider <p> Legacy compatibility knob. Canonical Phase 2 output still comes from the worker role.
  --worker-timeout <sec> Worker timeout for round 1 quick/deep analysis (default: 900).
  --revision-timeout <sec> Worker timeout for revision/expansion rounds (default: 600).
  --reviewer-timeout <sec> Reviewer timeout for core review rounds (default: 600).
  --exploration-timeout <sec> Reviewer timeout for explore round (default: 240).
  --clusters                   Enable deterministic cluster/consensus stage after the local Phase 2 loop (default: on).
  --no-clusters                Skip deterministic cluster/consensus stage.
  --cluster-limit <N>          Limit cluster synth/challenge to the first N clusters during the canonical Phase 2 run.
  --worker-provider <p>  Phase 2 worker provider (default: claude).
  --reviewer-provider <p> Phase 2 reviewer provider (default: codex).
  --worker-codex-model <name>   Codex model for worker role (default: gpt-5.4).
  --worker-claude-model <name>  Claude model for worker role.
  --reviewer-codex-model <name> Codex model for reviewer role.
  --reviewer-claude-model <name> Claude model for reviewer role (default: claude-opus-4.6).
  --max-review-rounds <N> Worker/reviewer loop rounds (default: 1).
  --forced-exploration         Run one final reviewer-driven expansion round (default: on).
  --no-forced-exploration      Skip the final expansion round.
  --max-exploration-candidates <N> Cap the final exploration candidates (default: 3).
  --codex-bin <path>     Codex CLI binary/path (default: env CODEX_BIN or codex).
  --claude-bin <path>    Claude Code binary/path (default: env CLAUDE_BIN or claude).
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
        --start-index)
            START_INDEX="${2:-}"
            START_SET=true
            shift 2
            ;;
        --end-index)
            END_INDEX="${2:-}"
            END_SET=true
            shift 2
            ;;
        --threads)
            THREADS="${2:-}"
            THREADS_SET=true
            shift 2
            ;;
        --interactive)
            INTERACTIVE=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --force-deep)
            FORCE_DEEP=true
            shift
            ;;
        --resume-existing)
            RESUME_EXISTING=true
            shift
            ;;
        --with-claude)
            WITH_CLAUDE=true
            shift
            ;;
        --provider)
            LLM_PROVIDERS="${2:-}"
            PROVIDERS_EXPLICIT=true
            shift 2
            ;;
        --providers)
            LLM_PROVIDERS="${2:-}"
            PROVIDERS_EXPLICIT=true
            shift 2
            ;;
        --model)
            CODEX_MODEL="${2:-}"
            CLAUDE_MODEL="${2:-}"
            shift 2
            ;;
        --codex-model)
            CODEX_MODEL="${2:-}"
            shift 2
            ;;
        --claude-model)
            CLAUDE_MODEL="${2:-}"
            shift 2
            ;;
        --primary-provider)
            PHASE2_PRIMARY_PROVIDER="${2:-}"
            shift 2
            ;;
        --worker-timeout)
            PHASE2_WORKER_TIMEOUT_SECONDS="${2:-}"
            shift 2
            ;;
        --revision-timeout)
            PHASE2_REVISION_TIMEOUT_SECONDS="${2:-}"
            shift 2
            ;;
        --reviewer-timeout)
            PHASE2_REVIEWER_TIMEOUT_SECONDS="${2:-}"
            shift 2
            ;;
        --exploration-timeout)
            PHASE2_EXPLORATION_TIMEOUT_SECONDS="${2:-}"
            shift 2
            ;;
        --clusters)
            PHASE2_ENABLE_CLUSTER_CONSENSUS=true
            shift
            ;;
        --no-clusters)
            PHASE2_ENABLE_CLUSTER_CONSENSUS=false
            shift
            ;;
        --cluster-limit)
            PHASE2_CLUSTER_LIMIT="${2:-}"
            shift 2
            ;;
        --worker-provider)
            PHASE2_WORKER_PROVIDER="${2:-}"
            WORKER_PROVIDER_EXPLICIT=true
            shift 2
            ;;
        --reviewer-provider)
            PHASE2_REVIEWER_PROVIDER="${2:-}"
            REVIEWER_PROVIDER_EXPLICIT=true
            shift 2
            ;;
        --worker-codex-model)
            PHASE2_WORKER_CODEX_MODEL="${2:-}"
            shift 2
            ;;
        --worker-claude-model)
            PHASE2_WORKER_CLAUDE_MODEL="${2:-}"
            shift 2
            ;;
        --reviewer-codex-model)
            PHASE2_REVIEWER_CODEX_MODEL="${2:-}"
            shift 2
            ;;
        --reviewer-claude-model)
            PHASE2_REVIEWER_CLAUDE_MODEL="${2:-}"
            shift 2
            ;;
        --max-review-rounds)
            PHASE2_MAX_REVIEW_ROUNDS="${2:-}"
            shift 2
            ;;
        --forced-exploration)
            PHASE2_ENABLE_FORCED_EXPLORATION=true
            shift
            ;;
        --no-forced-exploration)
            PHASE2_ENABLE_FORCED_EXPLORATION=false
            shift
            ;;
        --max-exploration-candidates)
            PHASE2_MAX_EXPLORATION_CANDIDATES="${2:-}"
            shift 2
            ;;
        --codex-bin)
            CODEX_BIN="${2:-}"
            shift 2
            ;;
        --claude-bin)
            CLAUDE_BIN="${2:-}"
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
            shift
            ;;
    esac
done

if [ "$WITH_CLAUDE" = true ] && [ "$PROVIDERS_EXPLICIT" != true ]; then
    LLM_PROVIDERS="codex,claude"
fi

REVIEW_PROMPT_TEMPLATE=""
for candidate in \
    "${TOOLS_DIR}/config/phase2-review-prompt-template.md" \
    "${ROOT_DIR}/phase2-review-prompt-template.md"
do
    if [ -f "$candidate" ]; then
        REVIEW_PROMPT_TEMPLATE="$candidate"
        break
    fi
done

if [ -z "$REVIEW_PROMPT_TEMPLATE" ]; then
    log_error_block "phase2 review prompt template not found" \
        "checked" "${TOOLS_DIR}/config/phase2-review-prompt-template.md" \
        "checked" "${ROOT_DIR}/phase2-review-prompt-template.md"
    exit 1
fi

EXPLORATION_PROMPT_TEMPLATE=""
for candidate in \
    "${TOOLS_DIR}/config/phase2-exploration-prompt-template.md" \
    "${ROOT_DIR}/phase2-exploration-prompt-template.md"
do
    if [ -f "$candidate" ]; then
        EXPLORATION_PROMPT_TEMPLATE="$candidate"
        break
    fi
done

if [ -z "$EXPLORATION_PROMPT_TEMPLATE" ]; then
    log_error_block "phase2 exploration prompt template not found" \
        "checked" "${TOOLS_DIR}/config/phase2-exploration-prompt-template.md" \
        "checked" "${ROOT_DIR}/phase2-exploration-prompt-template.md"
    exit 1
fi

REVISION_PROMPT_TEMPLATE=""
for candidate in \
    "${TOOLS_DIR}/config/phase2-revision-prompt-template.md" \
    "${ROOT_DIR}/phase2-revision-prompt-template.md"
do
    if [ -f "$candidate" ]; then
        REVISION_PROMPT_TEMPLATE="$candidate"
        break
    fi
done

if [ -z "$REVISION_PROMPT_TEMPLATE" ]; then
    log_error_block "phase2 revision prompt template not found" \
        "checked" "${TOOLS_DIR}/config/phase2-revision-prompt-template.md" \
        "checked" "${ROOT_DIR}/phase2-revision-prompt-template.md"
    exit 1
fi

PHASE2_REVIEW_CORE_SCHEMA="${ROOT_DIR}/contracts/phase2-review-core-output.schema.json"
if [ ! -f "$PHASE2_REVIEW_CORE_SCHEMA" ]; then
    log_error_block "phase2 review core schema not found" \
        "checked" "${PHASE2_REVIEW_CORE_SCHEMA}"
    exit 1
fi

PHASE2_REVIEW_EXPLORE_SCHEMA="${ROOT_DIR}/contracts/phase2-review-explore-output.schema.json"
if [ ! -f "$PHASE2_REVIEW_EXPLORE_SCHEMA" ]; then
    log_error_block "phase2 review explore schema not found" \
        "checked" "${PHASE2_REVIEW_EXPLORE_SCHEMA}"
    exit 1
fi

PHASE2_REVIEWER_INPUT_SCHEMA="${ROOT_DIR}/contracts/phase2-reviewer-input.schema.json"
if [ ! -f "$PHASE2_REVIEWER_INPUT_SCHEMA" ]; then
    log_error_block "phase2 reviewer input schema not found" \
        "checked" "${PHASE2_REVIEWER_INPUT_SCHEMA}"
    exit 1
fi

PHASE2_REVIEWER_INPUT_BUILDER="${ROOT_DIR}/tools/bin/build_phase2_reviewer_input.py"
if [ ! -f "$PHASE2_REVIEWER_INPUT_BUILDER" ]; then
    log_error_block "phase2 reviewer input builder not found" \
        "checked" "${PHASE2_REVIEWER_INPUT_BUILDER}"
    exit 1
fi

PHASE2_REVIEW_BATCH_PLAN_SCHEMA="${ROOT_DIR}/contracts/phase2-review-batch-plan.schema.json"
if [ ! -f "$PHASE2_REVIEW_BATCH_PLAN_SCHEMA" ]; then
    log_error_block "phase2 review batch plan schema not found" \
        "checked" "${PHASE2_REVIEW_BATCH_PLAN_SCHEMA}"
    exit 1
fi

PHASE2_REVIEWER_BATCH_BUILDER="${ROOT_DIR}/tools/bin/build_phase2_reviewer_batches.py"
if [ ! -f "$PHASE2_REVIEWER_BATCH_BUILDER" ]; then
    log_error_block "phase2 reviewer batch builder not found" \
        "checked" "${PHASE2_REVIEWER_BATCH_BUILDER}"
    exit 1
fi

PHASE2_REVIEWER_BATCH_MERGER="${ROOT_DIR}/tools/bin/merge_phase2_reviewer_batches.py"
if [ ! -f "$PHASE2_REVIEWER_BATCH_MERGER" ]; then
    log_error_block "phase2 reviewer batch merger not found" \
        "checked" "${PHASE2_REVIEWER_BATCH_MERGER}"
    exit 1
fi

PHASE2_REVISION_INPUT_BUILDER="${ROOT_DIR}/tools/bin/build_phase2_revision_input.py"
if [ ! -f "$PHASE2_REVISION_INPUT_BUILDER" ]; then
    log_error_block "phase2 revision input builder not found" \
        "checked" "${PHASE2_REVISION_INPUT_BUILDER}"
    exit 1
fi

PHASE2_CLUSTER_BUILDER="${ROOT_DIR}/tools/bin/build_candidate_clusters.py"
PHASE2_CLUSTER_PACK_BUILDER="${ROOT_DIR}/tools/bin/build_cluster_evidence_pack.py"
PHASE2_CLUSTER_RUNNER="${ROOT_DIR}/tools/bin/run-phase2-clusters.py"
PHASE2_CONSENSUS_WRITER="${ROOT_DIR}/tools/bin/write_phase2_consensus.py"

PHASE2_CLUSTER_INPUT_SCHEMA="${ROOT_DIR}/contracts/phase2-cluster-input.schema.json"
PHASE2_CLUSTER_OUTPUT_SCHEMA="${ROOT_DIR}/contracts/phase2-cluster-output.schema.json"
PHASE2_CLUSTER_PACK_SCHEMA="${ROOT_DIR}/contracts/phase2-cluster-pack.schema.json"
PHASE2_CONSENSUS_SCHEMA="${ROOT_DIR}/contracts/phase2-consensus.schema.json"

CLUSTER_SYNTH_PROMPT_TEMPLATE="${ROOT_DIR}/tools/config/phase2-cluster-synthesis-prompt-template.md"
CLUSTER_CHALLENGE_PROMPT_TEMPLATE="${ROOT_DIR}/tools/config/phase2-cluster-challenge-prompt-template.md"

PROMPT_TEMPLATE=""
for candidate in \
    "${TOOLS_DIR}/config/phase2-prompt-template.md" \
    "${ROOT_DIR}/phase2-prompt-template.md"
do
    if [ -f "$candidate" ]; then
        PROMPT_TEMPLATE="$candidate"
        break
    fi
done

if [ -z "$PROMPT_TEMPLATE" ]; then
    log_error_block "phase2 prompt template not found" \
        "checked" "${TOOLS_DIR}/config/phase2-prompt-template.md" \
        "checked" "${ROOT_DIR}/phase2-prompt-template.md"
    exit 1
fi

SYSTEM_PROMPT_PHASE2=""
SYSTEM_PROMPT_PHASE2_PATH=""
for candidate in \
    "${TOOLS_DIR}/config/system-prompt-phase2.md" \
    "${ROOT_DIR}/system-prompt-phase2.md"
do
    if [ -f "$candidate" ]; then
        SYSTEM_PROMPT_PHASE2="$(cat "$candidate")"
        SYSTEM_PROMPT_PHASE2_PATH="$candidate"
        break
    fi
done

if [ -z "$SYSTEM_PROMPT_PHASE2" ]; then
    SYSTEM_PROMPT_PHASE2='Hay ap dung truc tiep WordPress AppSec workflow trong prompt va project docs. Khong duoc phu thuoc vao skill auto-load.'
fi

SYSTEM_PROMPT_PHASE2_REVISION=""
SYSTEM_PROMPT_PHASE2_REVISION_PATH=""
for candidate in \
    "${TOOLS_DIR}/config/system-prompt-phase2-revision.md" \
    "${ROOT_DIR}/system-prompt-phase2-revision.md"
do
    if [ -f "$candidate" ]; then
        SYSTEM_PROMPT_PHASE2_REVISION="$(cat "$candidate")"
        SYSTEM_PROMPT_PHASE2_REVISION_PATH="$candidate"
        break
    fi
done

if [ -z "$SYSTEM_PROMPT_PHASE2_REVISION" ]; then
    SYSTEM_PROMPT_PHASE2_REVISION="$SYSTEM_PROMPT_PHASE2"
fi

SYSTEM_PROMPT_PHASE2_REVIEW_CORE=""
SYSTEM_PROMPT_PHASE2_REVIEW_CORE_PATH=""
for candidate in \
    "${TOOLS_DIR}/config/system-prompt-phase2-review-core.md" \
    "${ROOT_DIR}/system-prompt-phase2-review-core.md" \
    "${TOOLS_DIR}/config/system-prompt-phase2-review.md" \
    "${ROOT_DIR}/system-prompt-phase2-review.md"
do
    if [ -f "$candidate" ]; then
        SYSTEM_PROMPT_PHASE2_REVIEW_CORE="$(cat "$candidate")"
        SYSTEM_PROMPT_PHASE2_REVIEW_CORE_PATH="$candidate"
        break
    fi
done

if [ -z "$SYSTEM_PROMPT_PHASE2_REVIEW_CORE" ]; then
    SYSTEM_PROMPT_PHASE2_REVIEW_CORE='Ban la reviewer core cho Phase 2 WordPress plugin audit. Hay ap dung truc tiep WordPress AppSec workflow trong prompt va project docs.'
fi

SYSTEM_PROMPT_PHASE2_REVIEW_EXPLORE=""
SYSTEM_PROMPT_PHASE2_REVIEW_EXPLORE_PATH=""
for candidate in \
    "${TOOLS_DIR}/config/system-prompt-phase2-review-explore.md" \
    "${ROOT_DIR}/system-prompt-phase2-review-explore.md" \
    "${TOOLS_DIR}/config/system-prompt-phase2-review.md" \
    "${ROOT_DIR}/system-prompt-phase2-review.md"
do
    if [ -f "$candidate" ]; then
        SYSTEM_PROMPT_PHASE2_REVIEW_EXPLORE="$(cat "$candidate")"
        SYSTEM_PROMPT_PHASE2_REVIEW_EXPLORE_PATH="$candidate"
        break
    fi
done

if [ -z "$SYSTEM_PROMPT_PHASE2_REVIEW_EXPLORE" ]; then
    SYSTEM_PROMPT_PHASE2_REVIEW_EXPLORE='Ban la reviewer explore cho Phase 2 WordPress plugin audit. Hay ap dung truc tiep WordPress AppSec workflow trong prompt va project docs.'
fi

ensure_report_dirs
resolve_timeout_backend || true

if ! [[ "$PHASE2_PROVIDER_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid PHASE2_PROVIDER_TIMEOUT_SECONDS=$PHASE2_PROVIDER_TIMEOUT_SECONDS. Using default 600s."
    PHASE2_PROVIDER_TIMEOUT_SECONDS=600
fi

if ! [[ "$PHASE2_WORKER_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid PHASE2_WORKER_TIMEOUT_SECONDS=$PHASE2_WORKER_TIMEOUT_SECONDS. Using fallback ${PHASE2_PROVIDER_TIMEOUT_SECONDS}s."
    PHASE2_WORKER_TIMEOUT_SECONDS="$PHASE2_PROVIDER_TIMEOUT_SECONDS"
fi

if ! [[ "$PHASE2_REVISION_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid PHASE2_REVISION_TIMEOUT_SECONDS=$PHASE2_REVISION_TIMEOUT_SECONDS. Using fallback ${PHASE2_PROVIDER_TIMEOUT_SECONDS}s."
    PHASE2_REVISION_TIMEOUT_SECONDS="$PHASE2_PROVIDER_TIMEOUT_SECONDS"
fi

if ! [[ "$PHASE2_REVIEWER_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid PHASE2_REVIEWER_TIMEOUT_SECONDS=$PHASE2_REVIEWER_TIMEOUT_SECONDS. Using fallback ${PHASE2_PROVIDER_TIMEOUT_SECONDS}s."
    PHASE2_REVIEWER_TIMEOUT_SECONDS="$PHASE2_PROVIDER_TIMEOUT_SECONDS"
fi

if ! [[ "$PHASE2_EXPLORATION_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid PHASE2_EXPLORATION_TIMEOUT_SECONDS=$PHASE2_EXPLORATION_TIMEOUT_SECONDS. Using fallback ${PHASE2_REVIEWER_TIMEOUT_SECONDS}s."
    PHASE2_EXPLORATION_TIMEOUT_SECONDS="$PHASE2_REVIEWER_TIMEOUT_SECONDS"
fi

if ! [[ "$PHASE2_MAX_REVIEW_ROUNDS" =~ ^[0-9]+$ ]] || [ "$PHASE2_MAX_REVIEW_ROUNDS" -lt 1 ]; then
    log_warn "Invalid PHASE2_MAX_REVIEW_ROUNDS=$PHASE2_MAX_REVIEW_ROUNDS. Using default 1."
    PHASE2_MAX_REVIEW_ROUNDS=1
fi

PHASE2_ENABLE_FORCED_EXPLORATION="$(printf '%s' "$PHASE2_ENABLE_FORCED_EXPLORATION" | tr '[:upper:]' '[:lower:]')"
if [[ "$PHASE2_ENABLE_FORCED_EXPLORATION" != "true" && "$PHASE2_ENABLE_FORCED_EXPLORATION" != "false" ]]; then
    log_warn "Invalid PHASE2_ENABLE_FORCED_EXPLORATION=$PHASE2_ENABLE_FORCED_EXPLORATION. Using default true."
    PHASE2_ENABLE_FORCED_EXPLORATION=true
fi

if ! [[ "$PHASE2_MAX_EXPLORATION_CANDIDATES" =~ ^[0-9]+$ ]] || [ "$PHASE2_MAX_EXPLORATION_CANDIDATES" -lt 1 ]; then
    log_warn "Invalid PHASE2_MAX_EXPLORATION_CANDIDATES=$PHASE2_MAX_EXPLORATION_CANDIDATES. Using default 3."
    PHASE2_MAX_EXPLORATION_CANDIDATES=3
fi

normalize_providers() {
    python3 - "$1" <<'PY'
import sys

allowed = {"codex", "claude"}
seen = []
raw = sys.argv[1]
for item in raw.replace(",", " ").split():
    item = item.strip().lower()
    if item in allowed and item not in seen:
        seen.append(item)
if not seen:
    seen = ["codex"]
print(",".join(seen))
PY
}

LLM_PROVIDERS="$(normalize_providers "$LLM_PROVIDERS")"
IFS=',' read -r -a LLM_PROVIDER_ARRAY <<< "$LLM_PROVIDERS"

if { [ "$PROVIDERS_EXPLICIT" = true ] || [ "$WITH_CLAUDE" = true ]; } && { [ "$WORKER_PROVIDER_EXPLICIT" != true ] || [ "$REVIEWER_PROVIDER_EXPLICIT" != true ]; }; then
    if [ "${#LLM_PROVIDER_ARRAY[@]}" -eq 1 ]; then
        if [ "$WORKER_PROVIDER_EXPLICIT" != true ]; then
            PHASE2_WORKER_PROVIDER="${LLM_PROVIDER_ARRAY[0]}"
        fi
        if [ "$REVIEWER_PROVIDER_EXPLICIT" != true ]; then
            PHASE2_REVIEWER_PROVIDER="${LLM_PROVIDER_ARRAY[0]}"
        fi
    elif [ "${#LLM_PROVIDER_ARRAY[@]}" -ge 2 ]; then
        if [ "$WORKER_PROVIDER_EXPLICIT" != true ]; then
            PHASE2_WORKER_PROVIDER="${LLM_PROVIDER_ARRAY[0]}"
        fi
        if [ "$REVIEWER_PROVIDER_EXPLICIT" != true ]; then
            PHASE2_REVIEWER_PROVIDER="${LLM_PROVIDER_ARRAY[1]}"
        fi
    fi
fi

if [ "$PROVIDERS_EXPLICIT" != true ] && [ "$WITH_CLAUDE" != true ]; then
    local_provider_list="$PHASE2_WORKER_PROVIDER"
    if [ "$PHASE2_REVIEWER_PROVIDER" != "$PHASE2_WORKER_PROVIDER" ]; then
        local_provider_list="${local_provider_list},${PHASE2_REVIEWER_PROVIDER}"
    fi
    LLM_PROVIDERS="$(normalize_providers "$local_provider_list")"
    IFS=',' read -r -a LLM_PROVIDER_ARRAY <<< "$LLM_PROVIDERS"
fi

provider_in_list() {
    local needle="$1"
    local provider
    for provider in "${LLM_PROVIDER_ARRAY[@]}"; do
        if [ "$provider" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

if [ -z "$PHASE2_PRIMARY_PROVIDER" ] || ! provider_in_list "$PHASE2_PRIMARY_PROVIDER"; then
    PHASE2_PRIMARY_PROVIDER="$PHASE2_WORKER_PROVIDER"
fi

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

phase2_output_is_fresh() {
    local slug="$1"
    local output="${PHASE2_DIR}/${slug}-phase2.json"
    local ir_file="${PHASE1_DIR}/${slug}-ir.json"
    local plugin_dir="${PLUGINS_DIR}/${slug}"
    local semgrep_file="${PHASE1_DIR}/${slug}-semgrep.json"
    local psalm_file="${PHASE1_DIR}/${slug}-psalm.sarif"
    local threat_context_file="${REPORTS_DIR}/${slug}-threat-context.json"
    local -a inputs=("$ir_file" "$plugin_dir" "$PROMPT_TEMPLATE" "${BIN_DIR}/run-phase2.sh")

    if [ -n "$SYSTEM_PROMPT_PHASE2_PATH" ]; then
        inputs+=("$SYSTEM_PROMPT_PHASE2_PATH")
    fi
    if [ -n "$SYSTEM_PROMPT_PHASE2_REVISION_PATH" ]; then
        inputs+=("$SYSTEM_PROMPT_PHASE2_REVISION_PATH")
    fi
    if [ -n "$SYSTEM_PROMPT_PHASE2_REVIEW_CORE_PATH" ]; then
        inputs+=("$SYSTEM_PROMPT_PHASE2_REVIEW_CORE_PATH")
    fi
    if [ -n "$SYSTEM_PROMPT_PHASE2_REVIEW_EXPLORE_PATH" ]; then
        inputs+=("$SYSTEM_PROMPT_PHASE2_REVIEW_EXPLORE_PATH")
    fi
    if [ -f "$REVIEW_PROMPT_TEMPLATE" ]; then
        inputs+=("$REVIEW_PROMPT_TEMPLATE")
    fi
    if [ -f "$EXPLORATION_PROMPT_TEMPLATE" ]; then
        inputs+=("$EXPLORATION_PROMPT_TEMPLATE")
    fi
    if [ -f "$REVISION_PROMPT_TEMPLATE" ]; then
        inputs+=("$REVISION_PROMPT_TEMPLATE")
    fi
    if [ -f "$PHASE2_REVIEW_CORE_SCHEMA" ]; then
        inputs+=("$PHASE2_REVIEW_CORE_SCHEMA")
    fi
    if [ -f "$PHASE2_REVIEW_EXPLORE_SCHEMA" ]; then
        inputs+=("$PHASE2_REVIEW_EXPLORE_SCHEMA")
    fi
    if [ -f "$PHASE2_REVIEW_BATCH_PLAN_SCHEMA" ]; then
        inputs+=("$PHASE2_REVIEW_BATCH_PLAN_SCHEMA")
    fi
    if [ -f "$PHASE2_REVIEWER_INPUT_BUILDER" ]; then
        inputs+=("$PHASE2_REVIEWER_INPUT_BUILDER")
    fi
    if [ -f "$PHASE2_REVIEWER_BATCH_BUILDER" ]; then
        inputs+=("$PHASE2_REVIEWER_BATCH_BUILDER")
    fi
    if [ -f "$PHASE2_REVIEWER_BATCH_MERGER" ]; then
        inputs+=("$PHASE2_REVIEWER_BATCH_MERGER")
    fi
    if [ -f "$PHASE2_REVISION_INPUT_BUILDER" ]; then
        inputs+=("$PHASE2_REVISION_INPUT_BUILDER")
    fi
    if [ "$PHASE2_ENABLE_CLUSTER_CONSENSUS" = true ]; then
        for path in \
            "$PHASE2_CLUSTER_BUILDER" \
            "$PHASE2_CLUSTER_PACK_BUILDER" \
            "$PHASE2_CLUSTER_RUNNER" \
            "$PHASE2_CONSENSUS_WRITER" \
            "$PHASE2_CLUSTER_INPUT_SCHEMA" \
            "$PHASE2_CLUSTER_OUTPUT_SCHEMA" \
            "$PHASE2_CLUSTER_PACK_SCHEMA" \
            "$PHASE2_CONSENSUS_SCHEMA" \
            "$CLUSTER_SYNTH_PROMPT_TEMPLATE" \
            "$CLUSTER_CHALLENGE_PROMPT_TEMPLATE"
        do
            if [ -f "$path" ]; then
                inputs+=("$path")
            fi
        done
    fi
    if [ -f "${BIN_DIR}/phase2_postprocess.py" ]; then
        inputs+=("${BIN_DIR}/phase2_postprocess.py")
    fi
    if [ -f "${ROOT_DIR}/.claude/settings.json" ]; then
        inputs+=("${ROOT_DIR}/.claude/settings.json")
    fi
    if [ -f "${ROOT_DIR}/.claude/settings.local.json" ]; then
        inputs+=("${ROOT_DIR}/.claude/settings.local.json")
    fi
    if [ -f "$semgrep_file" ]; then
        inputs+=("$semgrep_file")
    fi
    if [ -f "$psalm_file" ]; then
        inputs+=("$psalm_file")
    fi
    if [ -f "$threat_context_file" ]; then
        inputs+=("$threat_context_file")
    fi

    freshness_is_fresh "$output" "${inputs[@]}"
}

provider_model() {
    case "$1" in
        codex) printf '%s' "$CODEX_MODEL" ;;
        claude) printf '%s' "$CLAUDE_MODEL" ;;
        *) printf '' ;;
    esac
}

phase2_role_model() {
    case "$1:$2" in
        worker:codex) printf '%s' "$PHASE2_WORKER_CODEX_MODEL" ;;
        worker:claude) printf '%s' "$PHASE2_WORKER_CLAUDE_MODEL" ;;
        reviewer:codex) printf '%s' "$PHASE2_REVIEWER_CODEX_MODEL" ;;
        reviewer:claude) printf '%s' "$PHASE2_REVIEWER_CLAUDE_MODEL" ;;
        *) printf '' ;;
    esac
}

provider_bin() {
    case "$1" in
        codex) printf '%s' "$CODEX_BIN" ;;
        claude) printf '%s' "$CLAUDE_BIN" ;;
        *) printf '' ;;
    esac
}

phase2_output_path() {
    printf '%s/%s-phase2.%s.json' "$PHASE2_DIR" "$1" "$2"
}

phase2_raw_path() {
    printf '%s/%s-phase2.%s.raw.json' "$PHASE2_DIR" "$1" "$2"
}

phase2_output_rel() {
    printf 'reports/phase2/%s-phase2.%s.json' "$1" "$2"
}

phase2_threat_context_rel() {
    printf 'reports/%s-threat-context.json' "$1"
}

phase2_worker_output_path() {
    printf '%s/%s-phase2.worker.r%s.json' "$PHASE2_DIR" "$1" "$2"
}

phase2_worker_raw_path() {
    printf '%s/%s-phase2.worker.r%s.raw.json' "$PHASE2_DIR" "$1" "$2"
}

phase2_worker_output_rel() {
    printf 'reports/phase2/%s-phase2.worker.r%s.json' "$1" "$2"
}

phase2_revision_input_path() {
    printf '%s/%s-phase2.worker.r%s.%s.input.json' "$PHASE2_DIR" "$1" "$2" "$3"
}

phase2_revision_input_rel() {
    printf 'reports/phase2/%s-phase2.worker.r%s.%s.input.json' "$1" "$2" "$3"
}

phase2_review_output_path() {
    printf '%s/%s-phase2.review.r%s.json' "$PHASE2_DIR" "$1" "$2"
}

phase2_review_output_rel() {
    printf 'reports/phase2/%s-phase2.review.r%s.json' "$1" "$2"
}

phase2_review_input_path() {
    printf '%s/%s-phase2.review.r%s.%s.input.json' "$PHASE2_DIR" "$1" "$2" "$3"
}

phase2_review_input_rel() {
    printf 'reports/phase2/%s-phase2.review.r%s.%s.input.json' "$1" "$2" "$3"
}

phase2_review_batch_plan_path() {
    printf '%s/%s-phase2.review.r%s.core.batch-plan.json' "$PHASE2_DIR" "$1" "$2"
}

phase2_review_batch_plan_rel() {
    printf 'reports/phase2/%s-phase2.review.r%s.core.batch-plan.json' "$1" "$2"
}

phase2_local_output_path() {
    printf '%s/%s-phase2.local.json' "$PHASE2_DIR" "$1"
}

phase2_consensus_output_path() {
    printf '%s/%s-phase2.consensus.json' "$PHASE2_DIR" "$1"
}

phase2_cluster_plan_path() {
    printf '%s/%s-cluster-plan.json' "$PHASE2_DIR" "$1"
}

phase2_cluster_errlog_path() {
    printf '%s/%s-phase2-clusters.err' "$LOGS_DIR" "$1"
}

phase2_loop_summary_path() {
    printf '%s/%s-phase2.loop-summary.json' "$PHASE2_DIR" "$1"
}

phase2_loop_summary_rel() {
    printf 'reports/phase2/%s-phase2.loop-summary.json' "$1"
}

phase2_loop_errlog_path() {
    local slug="$1"
    local role="$2"
    local provider="$3"
    local round="$4"
    local label="${5:-}"
    if [ -n "$label" ]; then
        printf '%s/%s-phase2-%s.r%s.%s.%s.err' "$LOGS_DIR" "$slug" "$role" "$round" "$provider" "$label"
    else
        printf '%s/%s-phase2-%s.r%s.%s.err' "$LOGS_DIR" "$slug" "$role" "$round" "$provider"
    fi
}

phase2_errlog_path() {
    if [ "$3" = "quick" ]; then
        printf '%s/%s-phase2-quick.%s.err' "$LOGS_DIR" "$1" "$2"
    else
        printf '%s/%s-phase2.%s.err' "$LOGS_DIR" "$1" "$2"
    fi
}

phase2_existing_rounds() {
    local slug="$1"
    local phase2_dir="$2"
    python3 - "$slug" "$phase2_dir" <<'PY'
import re
import sys
from pathlib import Path

slug = sys.argv[1]
phase2_dir = Path(sys.argv[2])

worker_pattern = re.compile(rf"^{re.escape(slug)}-phase2\.worker\.r(\d+)\.json$")
review_pattern = re.compile(rf"^{re.escape(slug)}-phase2\.review\.r(\d+)\.json$")

latest_worker = 0
latest_review = 0

if phase2_dir.exists():
    for path in phase2_dir.iterdir():
        name = path.name
        match = worker_pattern.match(name)
        if match:
            latest_worker = max(latest_worker, int(match.group(1)))
            continue
        match = review_pattern.match(name)
        if match:
            latest_review = max(latest_review, int(match.group(1)))

print(f"{latest_worker}|{latest_review}")
PY
}

phase2_cluster_count() {
    local plan_path="$1"
    python3 - "$plan_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print("0")
    raise SystemExit(0)
try:
    data = json.loads(path.read_text())
except Exception:
    print("0")
    raise SystemExit(0)
print(int(data.get("total_clusters", len(data.get("clusters", [])))))
PY
}

root_relative_path() {
    local path="$1"
    case "$path" in
        "${ROOT_DIR}/"*)
            printf '%s' "${path#${ROOT_DIR}/}"
            ;;
        *)
            printf '%s' "$path"
            ;;
    esac
}

render_phase2_template_prompt() {
    python3 - "$PROMPT_TEMPLATE" "$1" "$2" "$3" <<'PY'
from pathlib import Path
import sys

template_path, slug, output_path, threat_context_path = sys.argv[1:5]
text = Path(template_path).read_text(encoding="utf-8", errors="replace")
text = text.replace("{PLUGIN_SLUG}", slug)
text = text.replace("{OUTPUT_PATH}", output_path)
text = text.replace("{THREAT_CONTEXT_PATH}", threat_context_path)
print(text, end="")
PY
}

render_phase2_quick_prompt() {
    local slug="$1"
    local output_rel="$2"
    local threat_context_rel="$3"
    printf 'Quick triage mode for plugin `%s`.\nInputs:\n- Phase 1 IR: `reports/phase1/%s-ir.json`\n- Semgrep: `reports/phase1/%s-semgrep.json` (if exists)\n- Psalm SARIF: `reports/phase1/%s-psalm.sarif` (if exists; corroboration only)\n- Threat context: `%s` (if exists; use matched_categories + priority_vulns to prioritize review)\n- Source: `plugins/%s/`\n\nTask:\n1) Read IR (AST-derived) first. If threat context exists, read it next and prioritize `priority_vulns[]` plus matched plugin categories before spot-checking source.\n2) Spot-check only high-risk code paths in source.\n3) Focus on meaningful security impact only (Patchstack-eligible first).\n4) If nothing meaningful, return empty findings with concise negative_findings.\n5) Check `ir.coverage_gaps[]` for files with WP security signals but no discovered entry point. If any gap file appears to be a missed entry point, note it — do not ignore it.\n6) Keep reasoning concise, but evidence-bound.\n\nSchema requirements (critical):\n- Every TP/REVIEW MUST include: entry_point_id, source_file_path+source_line_number, sink_file_path+sink_line_number, source_function, sink_function.\n- `confidence` must be numeric in the range 0.0-1.0; do not emit labels like low/medium/high.\n- All path fields must be relative to the plugin root. Never prefix them with `plugins/%s/`.\n- Keep backcompat aliases: file_path = sink_file_path, line_number = sink_line_number.\n- Stored/second-order: include storage_key when literal; otherwise mark REVIEW and explain.\n\nOutput strictly to `%s`.' "$slug" "$slug" "$slug" "$slug" "$threat_context_rel" "$slug" "$slug" "$output_rel"
}

render_phase2_review_prompt() {
    python3 - "$REVIEW_PROMPT_TEMPLATE" "$1" "$2" "$3" "$4" <<'PY'
from pathlib import Path
import sys

template_path, slug, round_number, reviewer_input_path, review_output_path = sys.argv[1:6]
text = Path(template_path).read_text(encoding="utf-8", errors="replace")
replacements = {
    "{PLUGIN_SLUG}": slug,
    "{ROUND_NUMBER}": round_number,
    "{REVIEWER_INPUT_PATH}": reviewer_input_path,
    "{REVIEW_OUTPUT_PATH}": review_output_path,
}
for needle, value in replacements.items():
    text = text.replace(needle, value)
print(text, end="")
PY
}

render_phase2_exploration_prompt() {
    python3 - "$EXPLORATION_PROMPT_TEMPLATE" "$1" "$2" "$3" "$4" "$5" <<'PY'
from pathlib import Path
import sys

template_path, slug, round_number, reviewer_input_path, review_output_path, max_candidates = sys.argv[1:7]
text = Path(template_path).read_text(encoding="utf-8", errors="replace")
replacements = {
    "{PLUGIN_SLUG}": slug,
    "{ROUND_NUMBER}": round_number,
    "{REVIEWER_INPUT_PATH}": reviewer_input_path,
    "{REVIEW_OUTPUT_PATH}": review_output_path,
    "{MAX_CANDIDATES}": max_candidates,
}
for needle, value in replacements.items():
    text = text.replace(needle, value)
print(text, end="")
PY
}

build_phase2_reviewer_input() {
    local slug="$1"
    local round="$2"
    local review_mode="$3"
    local worker_output_path="$4"
    local review_output_path="$5"
    local review_input_path="$6"
    local errlog="$7"
    local threat_context_path="${ROOT_DIR}/$(phase2_threat_context_rel "$slug")"

    local cmd=(
        python3
        "$PHASE2_REVIEWER_INPUT_BUILDER"
        "$slug"
        --round "$round"
        --review-mode "$review_mode"
        --worker-output "$worker_output_path"
        --review-output "$review_output_path"
        --output "$review_input_path"
    )
    if [ -f "$threat_context_path" ]; then
        cmd+=(--threat-context "$threat_context_path")
    fi
    if [ "$review_mode" = "forced_exploration" ] || [ "$review_mode" = "explore" ]; then
        cmd+=(--max-candidates "$PHASE2_MAX_EXPLORATION_CANDIDATES")
    fi

    if ! "${cmd[@]}" >>"$errlog" 2>&1; then
        return 1
    fi
}

build_phase2_reviewer_batches() {
    local review_input_path="$1"
    local batch_plan_path="$2"
    local errlog="$3"

    if ! python3 "$PHASE2_REVIEWER_BATCH_BUILDER" \
        --input "$review_input_path" \
        --output-plan "$batch_plan_path" >>"$errlog" 2>&1; then
        return 1
    fi
}

phase2_review_batch_entries() {
    local batch_plan_path="$1"
    python3 - "$batch_plan_path" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
for batch in data.get("batches") or []:
    print(
        "|".join(
            [
                str(batch.get("batch_id") or ""),
                str(batch.get("input_path") or ""),
                str(batch.get("output_path") or ""),
                str(batch.get("packet_count") or 0),
                str(batch.get("load_score") or 0),
            ]
        )
    )
PY
}

merge_phase2_reviewer_batches() {
    local batch_plan_path="$1"
    local review_output_path="$2"
    local errlog="$3"

    if ! python3 "$PHASE2_REVIEWER_BATCH_MERGER" \
        --plan "$batch_plan_path" \
        --output "$review_output_path" >>"$errlog" 2>&1; then
        return 1
    fi
}

build_phase2_revision_input() {
    local slug="$1"
    local round="$2"
    local worker_mode="$3"
    local previous_worker_output_path="$4"
    local review_output_path="$5"
    local revision_input_path="$6"
    local errlog="$7"

    if ! python3 "$PHASE2_REVISION_INPUT_BUILDER" "$slug" \
        --root "$ROOT_DIR" \
        --round "$round" \
        --worker-mode "$worker_mode" \
        --previous-worker-output "$previous_worker_output_path" \
        --review-output "$review_output_path" \
        --output "$revision_input_path" >>"$errlog" 2>&1; then
        return 1
    fi
}

render_phase2_revision_prompt() {
    python3 - "$REVISION_PROMPT_TEMPLATE" "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
from pathlib import Path
import sys

template_path, slug, round_number, previous_worker_output_path, review_output_path, output_path, threat_context_path, revision_input_path = sys.argv[1:9]
text = Path(template_path).read_text(encoding="utf-8", errors="replace")
replacements = {
    "{PLUGIN_SLUG}": slug,
    "{ROUND_NUMBER}": round_number,
    "{PREVIOUS_WORKER_OUTPUT_PATH}": previous_worker_output_path,
    "{REVIEW_OUTPUT_PATH}": review_output_path,
    "{OUTPUT_PATH}": output_path,
    "{THREAT_CONTEXT_PATH}": threat_context_path,
    "{REVISION_INPUT_PATH}": revision_input_path,
}
for needle, value in replacements.items():
    text = text.replace(needle, value)
print(text, end="")
PY
}

validate_phase2_review_output() {
    local review_output="$1"
    local review_mode="${2:-core}"
    local errlog="$3"
    local schema_path
    schema_path="$(phase2_review_schema_for_mode "$review_mode")"
    python3 - "$review_output" "$schema_path" "$review_mode" >>"$errlog" 2>&1 <<'PY'
import json
import sys
from pathlib import Path

review_path = Path(sys.argv[1])
schema_path = Path(sys.argv[2])
review_mode = sys.argv[3]
normalized_mode = {"skeptical": "core", "forced_exploration": "explore"}.get(review_mode, review_mode)

if not review_path.exists():
    print(f"[ERROR] review output missing: {review_path}")
    raise SystemExit(1)

try:
    data = json.loads(review_path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"[ERROR] invalid review json: {exc}")
    raise SystemExit(1)

required = ["plugin_slug", "review_round", "review_status", "summary", "finding_reviews"]
if normalized_mode == "explore":
    required.append("missed_findings")
missing = [key for key in required if key not in data]
if missing:
    print(f"[ERROR] review output missing required keys: {missing}")
    raise SystemExit(1)

if data.get("review_status") not in {"stable", "needs_revision"}:
    print(f"[ERROR] invalid review_status: {data.get('review_status')!r}")
    raise SystemExit(1)

if not isinstance(data.get("finding_reviews"), list):
    print("[ERROR] finding_reviews must be a list")
    raise SystemExit(1)

finding_reviews = data.get("finding_reviews") or []
changed = False
for item in finding_reviews:
    finding_id = item.get("finding_id")
    if finding_id and "packet_id" not in item:
        item["packet_id"] = finding_id
        changed = True
    if finding_id and "parent_finding_id" not in item:
        item["parent_finding_id"] = finding_id
        changed = True
    if "missing_evidence" not in item:
        item["missing_evidence"] = []
        changed = True
    if "expansion_attempts" not in item:
        item["expansion_attempts"] = []
        changed = True

if normalized_mode == "core":
    if "missed_findings" in data:
        print("[ERROR] missed_findings is not allowed in reviewer core output")
        raise SystemExit(1)
    missed_findings = []
else:
    if not isinstance(data.get("missed_findings"), list):
        print("[ERROR] missed_findings must be a list")
        raise SystemExit(1)
    missed_findings = data.get("missed_findings") or []

summary = data.get("summary")
if isinstance(summary, str):
    material = bool(missed_findings)
    for item in finding_reviews:
        if item.get("assessment") != "keep":
            material = True
            break
    data["summary"] = {
        "worker_findings_reviewed": len(finding_reviews),
        "material_issues_found": material,
        "new_candidate_count": len(missed_findings),
        "notes": summary,
    }
    changed = True
elif isinstance(summary, dict):
    if "worker_findings_reviewed" not in summary:
        summary["worker_findings_reviewed"] = len(finding_reviews)
        changed = True
    if "material_issues_found" not in summary:
        material = bool(missed_findings)
        for item in finding_reviews:
            if item.get("assessment") != "keep":
                material = True
                break
        summary["material_issues_found"] = material
        changed = True
    if "new_candidate_count" not in summary:
        summary["new_candidate_count"] = len(missed_findings)
        changed = True
    elif normalized_mode == "core" and summary.get("new_candidate_count") not in (None, 0):
        print("[ERROR] reviewer core output must not report new candidates")
        raise SystemExit(1)

if changed:
    review_path.write_text(json.dumps(data, indent=2), encoding="utf-8")

if schema_path.exists():
    try:
        import jsonschema
    except ImportError:
        print("[WARN] jsonschema not installed; review schema validation skipped")
    else:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        jsonschema.validate(instance=data, schema=schema)
PY
}

accept_phase2_review_output_after_failure() {
    local review_output="$1"
    local review_mode="$2"
    local errlog="$3"
    local rc="$4"

    if [ ! -f "$review_output" ]; then
        return 1
    fi
    if ! validate_phase2_review_output "$review_output" "$review_mode" "$errlog"; then
        return 1
    fi
    printf '[WARN] accepting validated review output despite provider rc=%s: %s\n' "$rc" "$review_output" >>"$errlog"
    return 0
}

phase2_review_meta() {
    python3 - "$1" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
summary = data.get("summary") or {}
status = data.get("review_status", "needs_revision")
finding_reviews = data.get("finding_reviews") or []
missed_findings = data.get("missed_findings") or []
material = bool(summary.get("material_issues_found")) or bool(missed_findings)
for item in finding_reviews:
    if item.get("assessment") not in {"keep", "field_fix"}:
        material = True
        break
print(f"{status}|{len(finding_reviews)}|{len(missed_findings)}|{1 if material else 0}")
PY
}

phase2_transition_meta() {
    python3 - "${1:-}" "$2" <<'PY'
import json
import sys
from pathlib import Path

before_arg = sys.argv[1]
after_arg = sys.argv[2]

rank = {
    "FP": 0,
    "REJECTED": 0,
    "REVIEW": 1,
    "UNCERTAIN": 1,
    "RISK_NOTE": 1,
    "TP": 2,
    "CONFIRMED": 2,
}

def load(path_arg):
    if not path_arg:
        return {}
    path = Path(path_arg)
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    findings = {}
    for idx, finding in enumerate(data.get("findings") or []):
        key = (
            finding.get("finding_id")
            or "|".join(
                str(part or "")
                for part in (
                    finding.get("entry_point_id"),
                    finding.get("sink_file_path") or finding.get("file_path"),
                    finding.get("sink_line_number") or finding.get("line_number"),
                    finding.get("source_file_path"),
                    finding.get("source_line_number"),
                    finding.get("title"),
                    idx,
                )
            )
        )
        findings[key] = finding.get("verdict") or ""
    return findings

before = load(before_arg)
after = load(after_arg)

added = 0
removed = 0
verdict_changed = 0
upgraded = 0
downgraded = 0
unchanged = 0

for key, verdict in after.items():
    if key not in before:
        added += 1
        continue
    old_verdict = before[key]
    if old_verdict == verdict:
        unchanged += 1
        continue
    verdict_changed += 1
    old_rank = rank.get(old_verdict, 0)
    new_rank = rank.get(verdict, 0)
    if new_rank > old_rank:
        upgraded += 1
    elif new_rank < old_rank:
        downgraded += 1

for key in before:
    if key not in after:
        removed += 1

result = {
    "added": added,
    "removed": removed,
    "verdict_changed": verdict_changed,
    "upgraded": upgraded,
    "downgraded": downgraded,
    "unchanged": unchanged,
    "total_before": len(before),
    "total_after": len(after),
    "material_change": any(
        value > 0 for value in (added, removed, verdict_changed)
    ),
}
print(json.dumps(result, separators=(",", ":")))
PY
}

append_phase2_loop_worker_event() {
    local events_path="$1"
    local round="$2"
    local worker_mode="$3"
    local provider="$4"
    local model="$5"
    local duration="$6"
    local output_rel="$7"
    local errlog_rel="$8"
    local tp="$9"
    local fp="${10}"
    local rv="${11}"
    local total="${12}"
    local risk="${13}"
    local delta_json="${14}"

    python3 - "$events_path" "$round" "$worker_mode" "$provider" "$model" "$duration" "$output_rel" "$errlog_rel" "$tp" "$fp" "$rv" "$total" "$risk" "$delta_json" <<'PY'
import json
import sys
from pathlib import Path

events_path = Path(sys.argv[1])
payload = {
    "role": "worker",
    "round": int(sys.argv[2]),
    "mode": sys.argv[3],
    "provider": sys.argv[4],
    "model": sys.argv[5] or None,
    "duration_seconds": int(sys.argv[6]),
    "output_path": sys.argv[7],
    "errlog_path": sys.argv[8],
    "counts": {
        "tp": int(sys.argv[9]),
        "fp": int(sys.argv[10]),
        "review": int(sys.argv[11]),
        "total": int(sys.argv[12]),
        "risk": sys.argv[13],
    },
    "delta_from_previous_worker": json.loads(sys.argv[14]),
}
with events_path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(payload, separators=(",", ":")) + "\n")
PY
}

append_phase2_loop_reviewer_event() {
    local events_path="$1"
    local round="$2"
    local review_mode="$3"
    local provider="$4"
    local model="$5"
    local duration="$6"
    local output_rel="$7"
    local errlog_rel="$8"
    local review_status="$9"
    local finding_reviews_count="${10}"
    local missed_findings_count="${11}"
    local material_flag="${12}"

    python3 - "$events_path" "$round" "$review_mode" "$provider" "$model" "$duration" "$output_rel" "$errlog_rel" "$review_status" "$finding_reviews_count" "$missed_findings_count" "$material_flag" <<'PY'
import json
import sys
from pathlib import Path

events_path = Path(sys.argv[1])
payload = {
    "role": "reviewer",
    "round": int(sys.argv[2]),
    "mode": sys.argv[3],
    "provider": sys.argv[4],
    "model": sys.argv[5] or None,
    "duration_seconds": int(sys.argv[6]),
    "output_path": sys.argv[7],
    "errlog_path": sys.argv[8],
    "review_status": sys.argv[9],
    "finding_reviews_count": int(sys.argv[10]),
    "missed_findings_count": int(sys.argv[11]),
    "material_feedback": sys.argv[12] == "1",
}
with events_path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(payload, separators=(",", ":")) + "\n")
PY
}

write_phase2_loop_summary() {
    local summary_path="$1"
    local events_path="$2"
    local slug="$3"
    local initial_mode="$4"
    local worker_provider="$5"
    local reviewer_provider="$6"
    local worker_model="$7"
    local reviewer_model="$8"
    local max_review_rounds="$9"
    local completed_worker_rounds="${10}"
    local completed_review_rounds="${11}"
    local final_review_status="${12}"
    local stop_reason="${13}"
    local execution_status="${14}"
    local runtime_seconds="${15}"
    local canonical_output_rel="${16}"
    local final_worker_rel="${17}"
    local final_review_rel="${18}"
    local final_tp="${19}"
    local final_fp="${20}"
    local final_rv="${21}"
    local final_total="${22}"
    local final_risk="${23}"
    local forced_exploration_enabled="${24}"
    local max_exploration_candidates="${25}"

    python3 - "$summary_path" "$events_path" "$slug" "$initial_mode" "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" "$max_review_rounds" "$completed_worker_rounds" "$completed_review_rounds" "$final_review_status" "$stop_reason" "$execution_status" "$runtime_seconds" "$canonical_output_rel" "$final_worker_rel" "$final_review_rel" "$final_tp" "$final_fp" "$final_rv" "$final_total" "$final_risk" "$forced_exploration_enabled" "$max_exploration_candidates" <<'PY'
import json
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
events_path = Path(sys.argv[2])
rounds = []
if events_path.exists():
    for raw in events_path.read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        rounds.append(json.loads(raw))

def maybe_int(value):
    if value in {"", "null", "None"}:
        return None
    return int(value)

payload = {
    "plugin_slug": sys.argv[3],
    "execution_status": sys.argv[14],
    "initial_mode": sys.argv[4],
    "worker_provider": sys.argv[5],
    "reviewer_provider": sys.argv[6],
    "worker_model": sys.argv[7] or None,
    "reviewer_model": sys.argv[8] or None,
    "max_review_rounds": int(sys.argv[9]),
    "forced_exploration_enabled": sys.argv[24].lower() == "true",
    "max_exploration_candidates": int(sys.argv[25]),
    "completed_worker_rounds": int(sys.argv[10]),
    "completed_review_rounds": int(sys.argv[11]),
    "final_review_status": sys.argv[12],
    "stop_reason": sys.argv[13],
    "runtime_seconds": int(sys.argv[15]),
    "artifacts": {
        "canonical_phase2": sys.argv[16],
        "final_worker_output": sys.argv[17] or None,
        "final_review_output": sys.argv[18] or None,
    },
    "final_counts": {
        "tp": maybe_int(sys.argv[19]),
        "fp": maybe_int(sys.argv[20]),
        "review": maybe_int(sys.argv[21]),
        "total": maybe_int(sys.argv[22]),
        "risk": sys.argv[23] or None,
    },
    "rounds": rounds,
}
summary_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY
}

append_quota_log() {
    local phase="$1"
    local slug="$2"
    local mode="$3"
    local provider="$4"
    local model="$5"
    local status="$6"
    local duration="$7"
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf '{"ts":"%s","phase":"%s","slug":"%s","mode":"%s","provider":"%s","model":"%s","status":"%s","duration_sec":%s}\n' \
        "$ts" "$phase" "$slug" "$mode" "$provider" "$model" "$status" "$duration" >> "$QUOTA_LEDGER"
}

summarize_provider_errlog() {
    local errlog="$1"
    python3 - "$errlog" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
if not path.exists():
    print("log_missing")
    raise SystemExit(0)

text = path.read_text(encoding="utf-8", errors="replace")
lines = [line.strip() for line in text.splitlines() if line.strip()]
tail_lines = lines[-60:]
tail_text = "\n".join(tail_lines)
tail_lower = tail_text.lower()

patterns = [
    ("provider timed out", "provider_timeout"),
    ("timed out", "provider_timeout"),
    ("usage limit", "provider_usage_limit"),
    ("rate limit", "provider_rate_limit"),
    ("not found", "provider_binary_not_found"),
    ("no such file or directory", "provider_binary_not_found"),
    ("permission denied", "provider_permission_denied"),
]

for needle, label in patterns:
    if needle in tail_lower:
        print(label)
        raise SystemExit(0)

for line in reversed(tail_lines):
    lower_line = line.lower()
    if lower_line.startswith("error:"):
        if "usage limit" in lower_line:
            print("provider_usage_limit")
        elif "rate limit" in lower_line:
            print("provider_rate_limit")
        elif "authentication" in lower_line or "api key" in lower_line:
            print("provider_auth_error")
        elif "not found" in lower_line or "no such file or directory" in lower_line:
            print("provider_binary_not_found")
        elif "permission denied" in lower_line:
            print("provider_permission_denied")
        else:
            print(line[:200])
        raise SystemExit(0)

if tail_lines:
    print(tail_lines[-1][:200])
else:
    print("unknown_provider_error")
PY
}

anomaly_count() {
    local ir_file="$1"
    python3 -c "import json; print(len(json.load(open('${ir_file}')).get('anomalies', [])))" 2>/dev/null || echo "0"
}

entrypoint_count() {
    local ir_file="$1"
    python3 -c "import json; print(len(json.load(open('${ir_file}')).get('entry_points', [])))" 2>/dev/null || echo "0"
}

# Output format:
# unauth_ep|sensitive_sinks|sql_sinks|rest_json_sources|output_sinks|source_count|sink_count
ast_metrics() {
    local ir_file="$1"
    python3 -c "
import json
ir=json.load(open('${ir_file}'))
eps=ir.get('entry_points',[])
sinks=ir.get('sinks',[])
sources=ir.get('sources',[])
unauth=sum(1 for ep in eps if ep.get('auth_level')=='none')
sens_cats={'sql','file_write','file_delete','option_update','meta_update','eval','deserialization','include','remote_request'}
sens=sum(1 for s in sinks if s.get('category') in sens_cats)
sql=sum(1 for s in sinks if s.get('category')=='sql')
rest_json=sum(1 for s in sources if s.get('type') in {'rest_json','rest_body','rest_body_params'})
out=sum(1 for s in sinks if s.get('category') in {'output','output_return'})
print(f'{unauth}|{sens}|{sql}|{rest_json}|{out}|{len(sources)}|{len(sinks)}')
" 2>/dev/null || echo "0|0|0|0|0|0|0"
}

normalize_system_prompt_for_provider() {
    local provider="$1"
    local prompt="$2"
    local fallback_file="${TOOLS_DIR}/config/claude-headless-appsec-fallback.md"

    printf '%s' "$prompt" | python3 - "$provider" "$fallback_file" <<'PY'
import re
import sys
from pathlib import Path

provider = sys.argv[1]
fallback_file = Path(sys.argv[2])
text = sys.stdin.read()
lines = []
for line in text.splitlines():
    lower = line.lower()
    if "application-security" in lower or "load skill" in lower:
        continue
    lines.append(line)
text = "\n".join(lines).strip()
extra = fallback_file.read_text(encoding="utf-8", errors="replace").strip() if fallback_file.exists() else (
    "Apply the WordPress audit workflow and evidence rules written in this prompt "
    "directly. Do not assume external skill auto-loading."
)
prefix = f"Provider note: you are running via {provider}. Keep the workflow self-contained; do not rely on provider-specific skill auto-loading."
if text:
    print(f"{text}\n\n{prefix}\n\n{extra}", end="")
else:
    print(f"{prefix}\n\n{extra}", end="")
PY
}

run_llm_prompt() {
    local slug="$1"
    local mode="$2"
    local provider="$3"
    local system_prompt="$4"
    local prompt="$5"
    local errlog="$6"
    local model_override="${7:-}"
    local model bin timeout_seconds
    local start_ts end_ts rc duration status
    model="${model_override:-$(provider_model "$provider")}"
    bin="$(provider_bin "$provider")"
    timeout_seconds="${8:-$PHASE2_PROVIDER_TIMEOUT_SECONDS}"
    start_ts="$(date +%s)"
    if [ "$provider" = "codex" ]; then
        (
            cd "$ROOT_DIR"
            local cmd=("$bin" exec --full-auto --skip-git-repo-check)
            if [ -n "$model" ]; then
                cmd+=(--model "$model")
            fi
            cmd+=("${system_prompt}"$'\n\n'"${prompt}")
            if [ "$timeout_seconds" -gt 0 ]; then
                timeout_run "$timeout_seconds" "${cmd[@]}" 2>"$errlog"
            else
                "${cmd[@]}" 2>"$errlog"
            fi
        )
        rc=$?
    else
        local system_prompt_file
        system_prompt_file="$(mktemp)"
        printf '%s\n' "$system_prompt" > "$system_prompt_file"
        (
            cd "$ROOT_DIR"
            local cmd=("$bin" -p --dangerously-skip-permissions
                       --verbose
                       --output-format stream-json
                       --include-partial-messages)
            if [ -n "$model" ]; then
                cmd+=(--model "$model")
            fi
            cmd+=(--append-system-prompt-file "$system_prompt_file" "$prompt")
            if [ "$timeout_seconds" -gt 0 ]; then
                timeout_run "$timeout_seconds" "${cmd[@]}" 2>"$errlog" \
                    | python3 -u - 2>>"$errlog" <<'PYEOF'
import sys, json
for raw in sys.stdin.buffer:
    line = raw.decode("utf-8", errors="replace").rstrip("\n")
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        print(line, flush=True)
        continue
    t = obj.get("type", "")
    if t == "content_block_delta":
        delta = obj.get("delta", {})
        if delta.get("type") == "text_delta":
            print(delta.get("text", ""), end="", flush=True)
    elif t == "message_stop":
        print(flush=True)
PYEOF
                echo "${PIPESTATUS[0]}" > "${errlog}.pipestatus"
            else
                "${cmd[@]}" 2>"$errlog" \
                    | python3 -u - 2>>"$errlog" <<'PYEOF'
import sys, json
for raw in sys.stdin.buffer:
    line = raw.decode("utf-8", errors="replace").rstrip("\n")
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        print(line, flush=True)
        continue
    t = obj.get("type", "")
    if t == "content_block_delta":
        delta = obj.get("delta", {})
        if delta.get("type") == "text_delta":
            print(delta.get("text", ""), end="", flush=True)
    elif t == "message_stop":
        print(flush=True)
PYEOF
                echo "${PIPESTATUS[0]}" > "${errlog}.pipestatus"
            fi
        )
        rc="$(cat "${errlog}.pipestatus" 2>/dev/null || echo 1)"
        rm -f "$system_prompt_file" "${errlog}.pipestatus"
    fi
    if [ "$rc" -eq 124 ]; then
        printf '[ERROR] provider timed out after %ss\n' "$timeout_seconds" >> "$errlog"
    fi
    end_ts="$(date +%s)"
    duration=$((end_ts - start_ts))
    PHASE2_LAST_DURATION_SECONDS="$duration"
    status="ok"
    if [ "$rc" -ne 0 ]; then
        status="failed"
    fi
    append_quota_log "phase2" "$slug" "$mode" "$provider" "$model" "$status" "$duration"
    return "$rc"
}

phase2_timeout_for_worker_mode() {
    local worker_mode="$1"
    case "$worker_mode" in
        revision|expansion)
            printf '%s' "$PHASE2_REVISION_TIMEOUT_SECONDS"
            ;;
        *)
            printf '%s' "$PHASE2_WORKER_TIMEOUT_SECONDS"
            ;;
    esac
}

phase2_timeout_for_review_mode() {
    local review_mode="$1"
    case "$review_mode" in
        forced_exploration|explore)
            printf '%s' "$PHASE2_EXPLORATION_TIMEOUT_SECONDS"
            ;;
        *)
            printf '%s' "$PHASE2_REVIEWER_TIMEOUT_SECONDS"
            ;;
    esac
}

phase2_review_schema_for_mode() {
    local review_mode="${1:-core}"
    case "$review_mode" in
        forced_exploration|explore)
            printf '%s' "$PHASE2_REVIEW_EXPLORE_SCHEMA"
            ;;
        *)
            printf '%s' "$PHASE2_REVIEW_CORE_SCHEMA"
            ;;
    esac
}

phase2_review_system_prompt() {
    local review_mode="${1:-core}"
    local provider="$2"
    local base_prompt="$SYSTEM_PROMPT_PHASE2_REVIEW_CORE"

    case "$review_mode" in
        forced_exploration|explore)
            base_prompt="$SYSTEM_PROMPT_PHASE2_REVIEW_EXPLORE"
            ;;
    esac

    normalize_system_prompt_for_provider "$provider" "$base_prompt"
}

postprocess_phase2_output() {
    local slug="$1"
    local output_path="$2"
    local semgrep_path="${PHASE1_DIR}/${slug}-semgrep.json"
    local semgrep_arg=""
    if [ -f "$semgrep_path" ]; then
        semgrep_arg="--semgrep-report ${semgrep_path}"
    fi
    python3 "${BIN_DIR}/phase2_postprocess.py" "$slug" \
        --reports-dir "$REPORTS_DIR" \
        --plugins-dir "$PLUGINS_DIR" \
        --phase2-path "$output_path" \
        ${semgrep_arg} \
        --in-place
}

run_phase2_worker_round() {
    local slug="$1"
    local round="$2"
    local worker_mode="$3"
    local provider="$4"
    local previous_worker_rel="${5:-}"
    local review_rel="${6:-}"
    local threat_context_rel output_path output_rel raw_path prompt errlog system_prompt model timeout_seconds
    local revision_input_path="" revision_input_rel=""

    output_path="$(phase2_worker_output_path "$slug" "$round")"
    output_rel="$(phase2_worker_output_rel "$slug" "$round")"
    raw_path="$(phase2_worker_raw_path "$slug" "$round")"
    threat_context_rel="$(phase2_threat_context_rel "$slug")"
    errlog="$(phase2_loop_errlog_path "$slug" worker "$provider" "$round" "$worker_mode")"
    case "$worker_mode" in
        revision|expansion)
            system_prompt="$(normalize_system_prompt_for_provider "$provider" "$SYSTEM_PROMPT_PHASE2_REVISION")"
            ;;
        *)
            system_prompt="$(normalize_system_prompt_for_provider "$provider" "$SYSTEM_PROMPT_PHASE2")"
            ;;
    esac
    model="$(phase2_role_model worker "$provider")"
    timeout_seconds="$(phase2_timeout_for_worker_mode "$worker_mode")"

    if [ "$round" -eq 1 ]; then
        if [ "$worker_mode" = "quick" ]; then
            prompt="$(render_phase2_quick_prompt "$slug" "$output_rel" "$threat_context_rel")"
        else
            prompt="$(render_phase2_template_prompt "$slug" "$output_rel" "$threat_context_rel")"
        fi
    else
        revision_input_path="$(phase2_revision_input_path "$slug" "$round" "$worker_mode")"
        revision_input_rel="$(phase2_revision_input_rel "$slug" "$round" "$worker_mode")"
        if ! build_phase2_revision_input "$slug" "$((round - 1))" "$worker_mode" \
            "${ROOT_DIR}/${previous_worker_rel}" "${ROOT_DIR}/${review_rel}" "$revision_input_path" "$errlog"; then
            return 1
        fi
        prompt="$(render_phase2_revision_prompt "$slug" "$round" "$previous_worker_rel" "$review_rel" "$output_rel" "$threat_context_rel" "$revision_input_rel")"
    fi

    if ! run_llm_prompt "$slug" "worker-r${round}-${worker_mode}" "$provider" "$system_prompt" "$prompt" "$errlog" "$model" "$timeout_seconds"; then
        return 1
    fi
    if [ ! -f "$output_path" ]; then
        printf '[ERROR] worker output missing: %s\n' "$output_path" >> "$errlog"
        return 1
    fi

    cp -f "$output_path" "$raw_path" 2>/dev/null || true
    if [ -f "${BIN_DIR}/phase2_postprocess.py" ]; then
        if ! postprocess_phase2_output "$slug" "$output_path"; then
            printf '[ERROR] phase2_postprocess failed for %s\n' "$output_path" >> "$errlog"
            return 1
        fi
    fi
}

run_phase2_review_round() {
    local slug="$1"
    local round="$2"
    local provider="$3"
    local worker_output_rel="$4"
    local review_mode="${5:-core}"
    local review_output_path review_output_rel review_input_path review_input_rel prompt errlog system_prompt model timeout_seconds
    local worker_output_path
    local batch_plan_path batch_plan_rel batch_id batch_input_rel batch_output_rel batch_packet_count batch_load
    local batch_errlog batch_prompt batch_output_path total_reviewer_duration

    review_output_path="$(phase2_review_output_path "$slug" "$round")"
    review_output_rel="$(phase2_review_output_rel "$slug" "$round")"
    review_input_path="$(phase2_review_input_path "$slug" "$round" "$review_mode")"
    review_input_rel="$(phase2_review_input_rel "$slug" "$round" "$review_mode")"
    worker_output_path="${ROOT_DIR}/${worker_output_rel}"
    system_prompt="$(phase2_review_system_prompt "$review_mode" "$provider")"
    model="$(phase2_role_model reviewer "$provider")"
    timeout_seconds="$(phase2_timeout_for_review_mode "$review_mode")"
    errlog="$(phase2_loop_errlog_path "$slug" reviewer "$provider" "$round" "$review_mode")"
    if ! build_phase2_reviewer_input "$slug" "$round" "$review_mode" "$worker_output_path" "$review_output_path" "$review_input_path" "$errlog"; then
        return 1
    fi

    if [ "$review_mode" = "core" ]; then
        batch_plan_path="$(phase2_review_batch_plan_path "$slug" "$round")"
        batch_plan_rel="$(phase2_review_batch_plan_rel "$slug" "$round")"
        if ! build_phase2_reviewer_batches "$review_input_path" "$batch_plan_path" "$errlog"; then
            return 1
        fi
        total_reviewer_duration=0
        while IFS='|' read -r batch_id batch_input_rel batch_output_rel batch_packet_count batch_load; do
            [ -n "$batch_id" ] || continue
            batch_output_path="${ROOT_DIR}/${batch_output_rel}"
            batch_errlog="$(phase2_loop_errlog_path "$slug" reviewer "$provider" "$round" "${review_mode}.${batch_id}")"
            batch_prompt="$(render_phase2_review_prompt "$slug" "$round" "$batch_input_rel" "$batch_output_rel")"
            printf '[INFO] reviewer core batch %s packets=%s load=%s input=%s output=%s plan=%s\n' \
                "$batch_id" "$batch_packet_count" "$batch_load" "$batch_input_rel" "$batch_output_rel" "$batch_plan_rel" >> "$errlog"
            rm -f "$batch_output_path"
            if run_llm_prompt "$slug" "review-r${round}-${review_mode}-${batch_id}" "$provider" "$system_prompt" "$batch_prompt" "$batch_errlog" "$model" "$timeout_seconds"; then
                :
            else
                local batch_rc=$?
                if ! accept_phase2_review_output_after_failure "$batch_output_path" "$review_mode" "$batch_errlog" "$batch_rc"; then
                    return 1
                fi
            fi
            total_reviewer_duration=$((total_reviewer_duration + ${PHASE2_LAST_DURATION_SECONDS:-0}))
            if ! validate_phase2_review_output "$batch_output_path" "$review_mode" "$batch_errlog"; then
                return 1
            fi
        done < <(phase2_review_batch_entries "$batch_plan_path")
        if ! merge_phase2_reviewer_batches "$batch_plan_path" "$review_output_path" "$errlog"; then
            return 1
        fi
        PHASE2_LAST_DURATION_SECONDS="$total_reviewer_duration"
        if ! validate_phase2_review_output "$review_output_path" "$review_mode" "$errlog"; then
            return 1
        fi
        return 0
    fi

    if [ "$review_mode" = "forced_exploration" ] || [ "$review_mode" = "explore" ]; then
        prompt="$(render_phase2_exploration_prompt "$slug" "$round" "$review_input_rel" "$review_output_rel" "$PHASE2_MAX_EXPLORATION_CANDIDATES")"
    else
        prompt="$(render_phase2_review_prompt "$slug" "$round" "$review_input_rel" "$review_output_rel")"
    fi

    rm -f "$review_output_path"
    if run_llm_prompt "$slug" "review-r${round}-${review_mode}" "$provider" "$system_prompt" "$prompt" "$errlog" "$model" "$timeout_seconds"; then
        :
    else
        local review_rc=$?
        if ! accept_phase2_review_output_after_failure "$review_output_path" "$review_mode" "$errlog" "$review_rc"; then
            return 1
        fi
    fi
    if ! validate_phase2_review_output "$review_output_path" "$review_mode" "$errlog"; then
        return 1
    fi
}

run_phase2_cluster_pipeline() {
    local slug="$1"
    local local_phase2_path="$2"
    local errlog="$3"
    local cluster_plan_path cluster_total
    local -a cluster_cmd=()

    if [ "$PHASE2_ENABLE_CLUSTER_CONSENSUS" != true ]; then
        return 0
    fi

    for required in \
        "$PHASE2_CLUSTER_BUILDER" \
        "$PHASE2_CLUSTER_PACK_BUILDER" \
        "$PHASE2_CLUSTER_RUNNER" \
        "$PHASE2_CONSENSUS_WRITER"
    do
        if [ ! -f "$required" ]; then
            printf '[WARN] cluster stage skipped: missing %s\n' "$required" >> "$errlog"
            log_warn "Cluster/consensus stage skipped; missing script: $required"
            return 0
        fi
    done

    : > "$errlog"
    printf '[INFO] cluster pipeline start slug=%s local_phase2=%s\n' "$slug" "$local_phase2_path" >> "$errlog"

    if ! python3 "$PHASE2_CLUSTER_BUILDER" "$slug" --reports-dir "$REPORTS_DIR" --phase2-json "$local_phase2_path" >> "$errlog" 2>&1; then
        printf '[WARN] cluster plan build failed; preserving local phase2 canonical\n' >> "$errlog"
        log_warn "Cluster planning failed for ${slug}; preserving local Phase 2 canonical output."
    else
        if ! python3 "$PHASE2_CLUSTER_PACK_BUILDER" "$slug" --reports-dir "$REPORTS_DIR" >> "$errlog" 2>&1; then
            printf '[WARN] cluster evidence pack build failed; skipping cluster synth/challenge\n' >> "$errlog"
            log_warn "Cluster evidence pack build failed for ${slug}; cluster synth/challenge skipped."
        else
            cluster_plan_path="$(phase2_cluster_plan_path "$slug")"
            cluster_total="$(phase2_cluster_count "$cluster_plan_path")"
            if [ "${cluster_total:-0}" -gt 0 ]; then
                cluster_cmd=(python3 "$PHASE2_CLUSTER_RUNNER" "$slug")
                if [ -n "$PHASE2_CLUSTER_LIMIT" ]; then
                    cluster_cmd+=(--limit "$PHASE2_CLUSTER_LIMIT")
                fi
                if ! "${cluster_cmd[@]}" >> "$errlog" 2>&1; then
                    printf '[WARN] cluster synth/challenge returned non-zero; continuing to consensus with available artifacts\n' >> "$errlog"
                    log_warn "Cluster synth/challenge was not fully clean for ${slug}; continuing to consensus with available artifacts."
                fi
            else
                printf '[INFO] cluster plan has zero active clusters; synth/challenge skipped\n' >> "$errlog"
            fi
        fi
    fi

    if ! python3 "$PHASE2_CONSENSUS_WRITER" "$slug" --reports-dir "$REPORTS_DIR" >> "$errlog" 2>&1; then
        printf '[WARN] consensus writer failed; preserving local phase2 canonical\n' >> "$errlog"
        log_warn "Consensus writer failed for ${slug}; preserving local Phase 2 canonical output."
        return 0
    fi

    printf '[INFO] cluster pipeline completed successfully for %s\n' "$slug" >> "$errlog"
    return 0
}

annotate_phase2_loop_output() {
    local slug="$1"
    local output_path="$2"
    local worker_provider="$3"
    local reviewer_provider="$4"
    local worker_model="$5"
    local reviewer_model="$6"
    local initial_mode="$7"
    local completed_worker_rounds="$8"
    local completed_review_rounds="$9"
    local max_review_rounds="${10}"
    local final_review_status="${11}"
    local final_worker_rel="${12}"
    local final_review_rel="${13}"
    local summary_rel="${14}"
    local stop_reason="${15}"
    local runtime_seconds="${16}"
    local execution_status="${17}"
    local forced_exploration_enabled="${18}"
    local max_exploration_candidates="${19}"

    python3 - "$output_path" "$slug" "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" "$initial_mode" "$completed_worker_rounds" "$completed_review_rounds" "$max_review_rounds" "$final_review_status" "$final_worker_rel" "$final_review_rel" "$summary_rel" "$stop_reason" "$runtime_seconds" "$execution_status" "$forced_exploration_enabled" "$max_exploration_candidates" <<'PY'
import json
import sys
from pathlib import Path

out_path = Path(sys.argv[1])
data = json.loads(out_path.read_text(encoding="utf-8"))
data["phase2_loop"] = {
    "worker_provider": sys.argv[3],
    "reviewer_provider": sys.argv[4],
    "worker_model": sys.argv[5] or None,
    "reviewer_model": sys.argv[6] or None,
    "initial_mode": sys.argv[7],
    "completed_worker_rounds": int(sys.argv[8]),
    "completed_review_rounds": int(sys.argv[9]),
    "max_review_rounds": int(sys.argv[10]),
    "forced_exploration_enabled": sys.argv[18].lower() == "true",
    "max_exploration_candidates": int(sys.argv[19]),
    "final_review_status": sys.argv[11],
    "stop_reason": sys.argv[15],
    "runtime_seconds": int(sys.argv[16]),
    "status": sys.argv[17],
    "summary_path": sys.argv[14] or None,
    "artifacts": {
        "final_worker_output": sys.argv[12],
        "final_review_output": sys.argv[13] or None,
    },
}
out_path.write_text(json.dumps(data, indent=2), encoding="utf-8")
PY
}

phase2_counts() {
    local output="$1"
    python3 -c "
import json
try:
    d=json.load(open('${output}'))
    tp=int(d.get('true_positives',0))
    fp=int(d.get('false_positives',0))
    rv=int(d.get('needs_review',0))
    total=int(d.get('total_findings_analyzed',0))
    risk=str(d.get('overall_risk','?'))
    print(f'{tp}|{fp}|{rv}|{total}|{risk}')
except Exception:
    print('0|0|0|0|?')
" 2>/dev/null || echo "0|0|0|0|?"
}

write_lite_output() {
    local slug="$1"
    local output="$2"
    local summary="$3"
    local anom_count="$4"
    local ep_count="$5"
    local unauth_ep="$6"
    local sensitive_sinks="$7"
    local sql_sinks="$8"
    local rest_json_sources="$9"
    local output_sinks="${10}"
    local source_count="${11}"
    local sink_count="${12}"

    cat > "$output" <<EOF
{
  "plugin_slug": "$slug",
  "analysis_summary": "$summary",
  "overall_risk": "none",
  "total_findings_analyzed": 0,
  "true_positives": 0,
  "false_positives": 0,
  "needs_review": 0,
  "findings": [],
  "negative_findings": [
    "Phase2-lite deterministic triage: no meaningful attack surface for actionable security findings",
    "LLM deep review skipped intentionally to preserve quota"
  ],
  "out_of_scope": [],
  "phase2_lite": {
    "mode": "deterministic",
    "llm_invoked": false,
    "reasons": [
      "entry_points=$ep_count",
      "anomalies=$anom_count",
      "sources=$source_count",
      "sinks=$sink_count"
    ],
    "metrics": {
      "unauth_ep": $unauth_ep,
      "sensitive_sinks": $sensitive_sinks,
      "sql_sinks": $sql_sinks,
      "rest_json_sources": $rest_json_sources,
      "output_sinks": $output_sinks,
      "sources": $source_count,
      "sinks": $sink_count
    },
    "artifacts": {
      "ir": "reports/phase1/$slug-ir.json",
      "semgrep": "reports/phase1/$slug-semgrep.json",
      "psalm": "reports/phase1/$slug-psalm.sarif"
    }
  }
}
EOF
}

run_phase2_stage() {
    local slug="$1"
    local stage="$2"
    shift 2
    local providers=("$@")
    local stage_dir pids provider system_prompt prompt errlog output_rel threat_context_rel
    stage_dir="$(mktemp -d)"
    pids=()
    threat_context_rel="$(phase2_threat_context_rel "$slug")"

    for provider in "${providers[@]}"; do
        system_prompt="$(normalize_system_prompt_for_provider "$provider" "$SYSTEM_PROMPT_PHASE2")"
        output_rel="$(phase2_output_rel "$slug" "$provider")"
        if [ "$stage" = "quick" ]; then
            prompt="$(render_phase2_quick_prompt "$slug" "$output_rel" "$threat_context_rel")"
        else
            prompt="$(render_phase2_template_prompt "$slug" "$output_rel" "$threat_context_rel")"
        fi
        errlog="$(phase2_errlog_path "$slug" "$provider" "$stage")"

        (
            if run_llm_prompt "$slug" "$stage" "$provider" "$system_prompt" "$prompt" "$errlog"; then
                echo 0 > "${stage_dir}/${provider}.rc"
            else
                echo $? > "${stage_dir}/${provider}.rc"
            fi
        ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    LAST_STAGE_DIR="$stage_dir"
}

run_one() {
    local slug="$1"
    local ir_file="${PHASE1_DIR}/${slug}-ir.json"
    local plugin_dir="${PLUGINS_DIR}/${slug}"
    local output="${PHASE2_DIR}/${slug}-phase2.json"
    local raw_output="${PHASE2_DIR}/${slug}-phase2.raw.json"
    local loop_summary_path="${PHASE2_DIR}/${slug}-phase2.loop-summary.json"
    local loop_summary_rel="reports/phase2/${slug}-phase2.loop-summary.json"
    local loop_events_path="${PHASE2_DIR}/${slug}-phase2.loop-summary.events.jsonl"
    local errlog_deep="${LOGS_DIR}/${slug}-phase2.err"
    local errlog_quick="${LOGS_DIR}/${slug}-phase2-quick.err"
    local worker_provider="$PHASE2_WORKER_PROVIDER"
    local reviewer_provider="$PHASE2_REVIEWER_PROVIDER"
    local worker_model reviewer_model
    local final_review_status="not_reviewed"
    local last_review_rel=""
    local last_review_path=""
    local current_worker_round=1
    local completed_review_rounds=0
    local resume_active=false existing_worker_round=0 existing_review_round=0 existing_review_mode="core"
    local existing_rounds review_round_start
    local loop_started_ts loop_finished_ts total_runtime_seconds stop_reason="not_started"
    local execution_status="success"
    local forced_exploration_already_completed=false

    loop_started_ts="$(date +%s)"

    if [ ! -f "$ir_file" ]; then
        log_error_block "Phase 1 IR not found" \
            "slug" "$slug" \
            "path" "$ir_file"
        RUN_RESULT="failed"
        return 1
    fi

    if [ ! -d "$plugin_dir" ]; then
        log_error_block "Plugin source not found" \
            "slug" "$slug" \
            "path" "$plugin_dir"
        RUN_RESULT="failed"
        return 1
    fi

    if [ "$FORCE" != true ] && phase2_output_is_fresh "$slug"; then
        log_info "Skip ${slug}: phase2 output is fresh"
        RUN_RESULT="skipped"
        return 0
    fi

    local anom_count ep_count
    anom_count="$(anomaly_count "$ir_file")"
    ep_count="$(entrypoint_count "$ir_file")"

    local metrics unauth_ep sensitive_sinks sql_sinks rest_json_sources output_sinks source_count sink_count
    metrics="$(ast_metrics "$ir_file")"
    IFS='|' read -r unauth_ep sensitive_sinks sql_sinks rest_json_sources output_sinks source_count sink_count <<< "$metrics"

    log_section "Phase 2: ${slug}"
    echo "  Entry points: ${ep_count}"
    echo "  Phase 1 anomalies: ${anom_count}"
    echo "  AST metrics: unauth_ep=${unauth_ep}, sensitive_sinks=${sensitive_sinks}, sql_sinks=${sql_sinks}, rest_json_sources=${rest_json_sources}, output_sinks=${output_sinks}, sources=${source_count}, sinks=${sink_count}"
    echo "  Prompt template: ${PROMPT_TEMPLATE}"
    echo "  Mode default: deep (with quick-triage fallback for low-signal plugins)"
    worker_model="$(phase2_role_model worker "$worker_provider")"
    reviewer_model="$(phase2_role_model reviewer "$reviewer_provider")"
    echo "  Worker provider: ${worker_provider} (${worker_model:-default model})"
    echo "  Reviewer provider: ${reviewer_provider} (${reviewer_model:-default model})"
    echo "  Max review rounds: ${PHASE2_MAX_REVIEW_ROUNDS}"
    echo "  Forced exploration: ${PHASE2_ENABLE_FORCED_EXPLORATION} (max candidates=${PHASE2_MAX_EXPLORATION_CANDIDATES})"
    echo "  Cluster consensus: ${PHASE2_ENABLE_CLUSTER_CONSENSUS}${PHASE2_CLUSTER_LIMIT:+ (limit=${PHASE2_CLUSTER_LIMIT})}"
    echo "  Timeout policy: worker=${PHASE2_WORKER_TIMEOUT_SECONDS}s, revision=${PHASE2_REVISION_TIMEOUT_SECONDS}s, reviewer=${PHASE2_REVIEWER_TIMEOUT_SECONDS}s, exploration=${PHASE2_EXPLORATION_TIMEOUT_SECONDS}s (${TIMEOUT_BACKEND})"

    if [ "$RESUME_EXISTING" = true ]; then
        existing_rounds="$(phase2_existing_rounds "$slug" "$PHASE2_DIR")"
        IFS='|' read -r existing_worker_round existing_review_round <<< "$existing_rounds"
        if [ "${existing_worker_round:-0}" -gt 0 ]; then
            resume_active=true
            echo "  Resume existing artifacts: worker_r${existing_worker_round}, review_r${existing_review_round}"
        else
            echo "  Resume requested but no existing worker artifacts found; restarting from round 1."
        fi
    fi

    rm -f "$output" "$raw_output" "$errlog_deep" "$errlog_quick"
    rm -f "$loop_summary_path" "$loop_events_path"
    if [ "$resume_active" != true ]; then
        rm -f "${PHASE2_DIR}/${slug}-phase2.worker.r"*.json \
              "${PHASE2_DIR}/${slug}-phase2.worker.r"*.raw.json \
              "${PHASE2_DIR}/${slug}-phase2.review.r"*.json \
              "${LOGS_DIR}/${slug}-phase2-worker.r"*.err \
              "${LOGS_DIR}/${slug}-phase2-reviewer.r"*.err
        for provider in codex claude; do
            rm -f "$(phase2_output_path "$slug" "$provider")" \
                  "$(phase2_raw_path "$slug" "$provider")" \
                  "$(phase2_errlog_path "$slug" "$provider" deep)" \
                  "$(phase2_errlog_path "$slug" "$provider" quick)"
        done
    fi

    if [ "$ep_count" -eq 0 ] || { [ "$anom_count" = "0" ] && [ "$source_count" = "0" ] && [ "$sink_count" = "0" ]; }; then
        echo "  AST triage: low/no surface -> writing deterministic phase2-lite output (no LLM)."
        write_lite_output "$slug" "$output" "Phase2-lite deterministic triage completed" \
            "$anom_count" "$ep_count" "$unauth_ep" "$sensitive_sinks" "$sql_sinks" "$rest_json_sources" "$output_sinks" "$source_count" "$sink_count"
        stop_reason="deterministic_lite_no_surface"
        final_review_status="not_applicable"
        loop_finished_ts="$(date +%s)"
        total_runtime_seconds=$((loop_finished_ts - loop_started_ts))
        write_phase2_loop_summary "$loop_summary_path" "$loop_events_path" \
            "$slug" "lite" "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" \
            "$PHASE2_MAX_REVIEW_ROUNDS" 0 0 "$final_review_status" "$stop_reason" "success" "$total_runtime_seconds" \
            "reports/phase2/${slug}-phase2.json" "" "" 0 0 0 0 "LOW" "$PHASE2_ENABLE_FORCED_EXPLORATION" "$PHASE2_MAX_EXPLORATION_CANDIDATES"
        annotate_phase2_loop_output "$slug" "$output" \
            "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" \
            "lite" 0 0 "$PHASE2_MAX_REVIEW_ROUNDS" "$final_review_status" "" "" \
            "$loop_summary_rel" "$stop_reason" "$total_runtime_seconds" "success" \
            "$PHASE2_ENABLE_FORCED_EXPLORATION" "$PHASE2_MAX_EXPLORATION_CANDIDATES"
        cp -f "$output" "$raw_output" 2>/dev/null || true
        local provider
        for provider in "${LLM_PROVIDER_ARRAY[@]}"; do
            cp -f "$output" "$(phase2_output_path "$slug" "$provider")" 2>/dev/null || true
            cp -f "$output" "$(phase2_raw_path "$slug" "$provider")" 2>/dev/null || true
        done
        RUN_RESULT="done"
        return 0
    fi

    local mode review_round next_worker_round
    local current_worker_path current_worker_rel current_worker_raw
    local review_meta review_status review_finding_count review_missed_count review_material
    local counts tp fp rv total risk
    local initial_worker_errlog
    local worker_delta_json reviewer_duration worker_duration prev_worker_path prev_worker_rel
    local -a loop_errlogs
    loop_errlogs=()
    local coverage_gaps_count
    coverage_gaps_count=$(python3 -c "import json; print(len(json.load(open('${ir_file}')).get('coverage_gaps', [])))" 2>/dev/null || echo "0")

    mode="deep"
    if [ "$FORCE_DEEP" != true ] && [ "$anom_count" = "0" ] && [ "$unauth_ep" = "0" ] && [ "$sensitive_sinks" = "0" ] && [ "$sql_sinks" = "0" ] && [ "$rest_json_sources" = "0" ] && [ "$coverage_gaps_count" = "0" ]; then
        mode="quick"
    fi

    if [ "$resume_active" = true ]; then
        current_worker_round="$existing_worker_round"
        current_worker_path="$(phase2_worker_output_path "$slug" "$current_worker_round")"
        current_worker_rel="$(phase2_worker_output_rel "$slug" "$current_worker_round")"
        current_worker_raw="$(phase2_worker_raw_path "$slug" "$current_worker_round")"
        if [ ! -f "$current_worker_raw" ] && [ -f "$current_worker_path" ]; then
            cp -f "$current_worker_path" "$current_worker_raw" 2>/dev/null || true
        fi
        counts="$(phase2_counts "$current_worker_path")"
        IFS='|' read -r tp fp rv total risk <<< "$counts"
        worker_delta_json="$(phase2_transition_meta "" "$current_worker_path")"
        append_phase2_loop_worker_event "$loop_events_path" "$current_worker_round" "$mode" "$worker_provider" "$worker_model" \
            0 "$(root_relative_path "$current_worker_path")" "" \
            "$tp" "$fp" "$rv" "$total" "$risk" "$worker_delta_json"
        echo "  Resumed worker round ${current_worker_round}: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}"

        if [ "${existing_review_round:-0}" -gt 0 ]; then
            last_review_path="$(phase2_review_output_path "$slug" "$existing_review_round")"
            last_review_rel="$(phase2_review_output_rel "$slug" "$existing_review_round")"
            if [ "$existing_review_round" -gt "$PHASE2_MAX_REVIEW_ROUNDS" ]; then
                existing_review_mode="explore"
            fi
            review_meta="$(phase2_review_meta "$last_review_path")"
            IFS='|' read -r review_status review_finding_count review_missed_count review_material <<< "$review_meta"
            completed_review_rounds="$existing_review_round"
            final_review_status="$review_status"
            append_phase2_loop_reviewer_event "$loop_events_path" "$existing_review_round" "$existing_review_mode" "$reviewer_provider" "$reviewer_model" \
                0 "$(root_relative_path "$last_review_path")" "" \
                "$review_status" "$review_finding_count" "$review_missed_count" "$review_material"
            echo "  Resumed reviewer ${existing_review_mode} round ${existing_review_round}: ${review_status} | finding_reviews=${review_finding_count}, missed_findings=${review_missed_count}"
            if [ "$existing_review_mode" = "explore" ]; then
                forced_exploration_already_completed=true
                if [ "$review_status" = "stable" ]; then
                    stop_reason="forced_exploration_stable_no_new_candidates"
                fi
            fi
        fi
    else
        echo "  Worker round 1 (${mode}): ${worker_provider}"
        if ! run_phase2_worker_round "$slug" 1 "$mode" "$worker_provider"; then
            stop_reason="worker_round_failed"
            execution_status="failed"
            loop_finished_ts="$(date +%s)"
            total_runtime_seconds=$((loop_finished_ts - loop_started_ts))
            write_phase2_loop_summary "$loop_summary_path" "$loop_events_path" \
                "$slug" "$mode" "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" \
                "$PHASE2_MAX_REVIEW_ROUNDS" 0 0 "$final_review_status" "$stop_reason" "$execution_status" "$total_runtime_seconds" \
                "reports/phase2/${slug}-phase2.json" "" "" "" "" "" "" "" "$PHASE2_ENABLE_FORCED_EXPLORATION" "$PHASE2_MAX_EXPLORATION_CANDIDATES"
            log_error_block "Phase 2 worker round failed" \
                "slug" "$slug" \
                "round" "1" \
                "provider" "$worker_provider" \
                "reason" "$(summarize_provider_errlog "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" 1 "$mode")")" \
                "log" "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" 1 "$mode")"
            RUN_RESULT="failed"
            return 1
        fi
        initial_worker_errlog="$(phase2_loop_errlog_path "$slug" worker "$worker_provider" 1 "$mode")"
        loop_errlogs+=("$initial_worker_errlog")
        current_worker_path="$(phase2_worker_output_path "$slug" 1)"
        current_worker_rel="$(phase2_worker_output_rel "$slug" 1)"
        current_worker_raw="$(phase2_worker_raw_path "$slug" 1)"
        counts="$(phase2_counts "$current_worker_path")"
        IFS='|' read -r tp fp rv total risk <<< "$counts"
        worker_duration="${PHASE2_LAST_DURATION_SECONDS:-0}"
        worker_delta_json="$(phase2_transition_meta "" "$current_worker_path")"
        append_phase2_loop_worker_event "$loop_events_path" 1 "$mode" "$worker_provider" "$worker_model" \
            "$worker_duration" "$(root_relative_path "$current_worker_path")" "$(root_relative_path "$initial_worker_errlog")" \
            "$tp" "$fp" "$rv" "$total" "$risk" "$worker_delta_json"
        echo "  Worker round 1 results: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}"
    fi

    if [ "$resume_active" = true ] \
        && [ "$completed_review_rounds" -eq "$current_worker_round" ] \
        && [ "$final_review_status" != "stable" ]; then
        next_worker_round=$((current_worker_round + 1))
        echo "  Resume pending worker revision round ${next_worker_round}: ${worker_provider}"
        prev_worker_path="$current_worker_path"
        prev_worker_rel="$current_worker_rel"
        if ! run_phase2_worker_round "$slug" "$next_worker_round" "revision" "$worker_provider" "$current_worker_rel" "$last_review_rel"; then
            stop_reason="worker_revision_failed"
            execution_status="failed"
            loop_finished_ts="$(date +%s)"
            total_runtime_seconds=$((loop_finished_ts - loop_started_ts))
            write_phase2_loop_summary "$loop_summary_path" "$loop_events_path" \
                "$slug" "$mode" "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" \
                "$PHASE2_MAX_REVIEW_ROUNDS" "$current_worker_round" "$completed_review_rounds" "$final_review_status" "$stop_reason" "$execution_status" "$total_runtime_seconds" \
                "reports/phase2/${slug}-phase2.json" "$current_worker_rel" "$last_review_rel" "$tp" "$fp" "$rv" "$total" "$risk" "$PHASE2_ENABLE_FORCED_EXPLORATION" "$PHASE2_MAX_EXPLORATION_CANDIDATES"
            annotate_phase2_loop_output "$slug" "$current_worker_path" \
                "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" \
                "$mode" "$current_worker_round" "$completed_review_rounds" "$PHASE2_MAX_REVIEW_ROUNDS" \
                "$final_review_status" "$current_worker_rel" "$last_review_rel" \
                "$loop_summary_rel" "$stop_reason" "$total_runtime_seconds" "$execution_status" \
                "$PHASE2_ENABLE_FORCED_EXPLORATION" "$PHASE2_MAX_EXPLORATION_CANDIDATES"
            log_error_block "Phase 2 worker revision failed" \
                "slug" "$slug" \
                "round" "$next_worker_round" \
                "provider" "$worker_provider" \
                "reason" "$(summarize_provider_errlog "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$next_worker_round" revision)")" \
                "log" "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$next_worker_round" revision)"
            RUN_RESULT="failed"
            return 1
        fi

        current_worker_round="$next_worker_round"
        current_worker_path="$(phase2_worker_output_path "$slug" "$current_worker_round")"
        current_worker_rel="$(phase2_worker_output_rel "$slug" "$current_worker_round")"
        current_worker_raw="$(phase2_worker_raw_path "$slug" "$current_worker_round")"
        loop_errlogs+=("$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$current_worker_round" revision)")
        counts="$(phase2_counts "$current_worker_path")"
        IFS='|' read -r tp fp rv total risk <<< "$counts"
        worker_duration="${PHASE2_LAST_DURATION_SECONDS:-0}"
        worker_delta_json="$(phase2_transition_meta "$prev_worker_path" "$current_worker_path")"
        append_phase2_loop_worker_event "$loop_events_path" "$current_worker_round" "revision" "$worker_provider" "$worker_model" \
            "$worker_duration" "$(root_relative_path "$current_worker_path")" "$(root_relative_path "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$current_worker_round" revision)")" \
            "$tp" "$fp" "$rv" "$total" "$risk" "$worker_delta_json"
        echo "  Worker revision ${current_worker_round} results: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}"
    fi

    if [ "$resume_active" = true ] \
        && [ "$forced_exploration_already_completed" = true ] \
        && [ "$completed_review_rounds" -gt "$PHASE2_MAX_REVIEW_ROUNDS" ] \
        && [ "$final_review_status" != "stable" ]; then
        next_worker_round=$((current_worker_round + 1))
        echo "  Resume pending worker expansion round ${next_worker_round}: ${worker_provider}"
        prev_worker_path="$current_worker_path"
        prev_worker_rel="$current_worker_rel"
        if ! run_phase2_worker_round "$slug" "$next_worker_round" "expansion" "$worker_provider" "$current_worker_rel" "$last_review_rel"; then
            stop_reason="forced_exploration_worker_failed"
            execution_status="failed"
            loop_finished_ts="$(date +%s)"
            total_runtime_seconds=$((loop_finished_ts - loop_started_ts))
            write_phase2_loop_summary "$loop_summary_path" "$loop_events_path" \
                "$slug" "$mode" "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" \
                "$PHASE2_MAX_REVIEW_ROUNDS" "$current_worker_round" "$completed_review_rounds" "$final_review_status" "$stop_reason" "$execution_status" "$total_runtime_seconds" \
                "reports/phase2/${slug}-phase2.json" "$current_worker_rel" "$last_review_rel" "$tp" "$fp" "$rv" "$total" "$risk" "$PHASE2_ENABLE_FORCED_EXPLORATION" "$PHASE2_MAX_EXPLORATION_CANDIDATES"
            annotate_phase2_loop_output "$slug" "$current_worker_path" \
                "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" \
                "$mode" "$current_worker_round" "$completed_review_rounds" "$PHASE2_MAX_REVIEW_ROUNDS" \
                "$final_review_status" "$current_worker_rel" "$last_review_rel" \
                "$loop_summary_rel" "$stop_reason" "$total_runtime_seconds" "$execution_status" \
                "$PHASE2_ENABLE_FORCED_EXPLORATION" "$PHASE2_MAX_EXPLORATION_CANDIDATES"
            log_error_block "Phase 2 worker expansion failed" \
                "slug" "$slug" \
                "round" "$next_worker_round" \
                "provider" "$worker_provider" \
                "reason" "$(summarize_provider_errlog "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$next_worker_round" expansion)")" \
                "log" "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$next_worker_round" expansion)"
            RUN_RESULT="failed"
            return 1
        fi

        current_worker_round="$next_worker_round"
        current_worker_path="$(phase2_worker_output_path "$slug" "$current_worker_round")"
        current_worker_rel="$(phase2_worker_output_rel "$slug" "$current_worker_round")"
        current_worker_raw="$(phase2_worker_raw_path "$slug" "$current_worker_round")"
        loop_errlogs+=("$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$current_worker_round" expansion)")
        counts="$(phase2_counts "$current_worker_path")"
        IFS='|' read -r tp fp rv total risk <<< "$counts"
        worker_duration="${PHASE2_LAST_DURATION_SECONDS:-0}"
        worker_delta_json="$(phase2_transition_meta "$prev_worker_path" "$current_worker_path")"
        append_phase2_loop_worker_event "$loop_events_path" "$current_worker_round" "expansion" "$worker_provider" "$worker_model" \
            "$worker_duration" "$(root_relative_path "$current_worker_path")" "$(root_relative_path "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$current_worker_round" expansion)")" \
            "$tp" "$fp" "$rv" "$total" "$risk" "$worker_delta_json"
        stop_reason="forced_exploration_completed"
        echo "  Worker expansion ${current_worker_round} results: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}"
    fi

    review_round_start=1
    if [ "$completed_review_rounds" -gt 0 ]; then
        review_round_start=$((completed_review_rounds + 1))
    fi

    for ((review_round=review_round_start; review_round<=PHASE2_MAX_REVIEW_ROUNDS; review_round++)); do
        echo "  Reviewer core round ${review_round}: ${reviewer_provider}"
        if ! run_phase2_review_round "$slug" "$review_round" "$reviewer_provider" "$current_worker_rel" "core"; then
            stop_reason="reviewer_round_failed"
            execution_status="failed"
            loop_finished_ts="$(date +%s)"
            total_runtime_seconds=$((loop_finished_ts - loop_started_ts))
            write_phase2_loop_summary "$loop_summary_path" "$loop_events_path" \
                "$slug" "$mode" "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" \
                "$PHASE2_MAX_REVIEW_ROUNDS" "$current_worker_round" "$completed_review_rounds" "$final_review_status" "$stop_reason" "$execution_status" "$total_runtime_seconds" \
                "reports/phase2/${slug}-phase2.json" "$current_worker_rel" "$last_review_rel" "$tp" "$fp" "$rv" "$total" "$risk" "$PHASE2_ENABLE_FORCED_EXPLORATION" "$PHASE2_MAX_EXPLORATION_CANDIDATES"
            annotate_phase2_loop_output "$slug" "$current_worker_path" \
                "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" \
                "$mode" "$current_worker_round" "$completed_review_rounds" "$PHASE2_MAX_REVIEW_ROUNDS" \
                "$final_review_status" "$current_worker_rel" "$last_review_rel" \
                "$loop_summary_rel" "$stop_reason" "$total_runtime_seconds" "$execution_status" \
                "$PHASE2_ENABLE_FORCED_EXPLORATION" "$PHASE2_MAX_EXPLORATION_CANDIDATES"
            log_error_block "Phase 2 reviewer round failed" \
                "slug" "$slug" \
                "round" "$review_round" \
                "provider" "$reviewer_provider" \
                "reason" "$(summarize_provider_errlog "$(phase2_loop_errlog_path "$slug" reviewer "$reviewer_provider" "$review_round" core)")" \
                "log" "$(phase2_loop_errlog_path "$slug" reviewer "$reviewer_provider" "$review_round" core)"
            RUN_RESULT="failed"
            return 1
        fi

        last_review_path="$(phase2_review_output_path "$slug" "$review_round")"
        last_review_rel="$(phase2_review_output_rel "$slug" "$review_round")"
        loop_errlogs+=("$(phase2_loop_errlog_path "$slug" reviewer "$reviewer_provider" "$review_round" core)")
        review_meta="$(phase2_review_meta "$last_review_path")"
        IFS='|' read -r review_status review_finding_count review_missed_count review_material <<< "$review_meta"
        completed_review_rounds="$review_round"
        final_review_status="$review_status"
        reviewer_duration="${PHASE2_LAST_DURATION_SECONDS:-0}"
        append_phase2_loop_reviewer_event "$loop_events_path" "$review_round" "core" "$reviewer_provider" "$reviewer_model" \
            "$reviewer_duration" "$(root_relative_path "$last_review_path")" "$(root_relative_path "$(phase2_loop_errlog_path "$slug" reviewer "$reviewer_provider" "$review_round" core)")" \
            "$review_status" "$review_finding_count" "$review_missed_count" "$review_material"
        echo "  Reviewer core round ${review_round} verdict: ${review_status} | finding_reviews=${review_finding_count}, missed_findings=${review_missed_count}"

        if [ "$review_status" = "stable" ]; then
            stop_reason="reviewer_marked_stable"
            break
        fi

        next_worker_round=$((current_worker_round + 1))
        echo "  Worker revision round ${next_worker_round}: ${worker_provider}"
        prev_worker_path="$current_worker_path"
        prev_worker_rel="$current_worker_rel"
        if ! run_phase2_worker_round "$slug" "$next_worker_round" "revision" "$worker_provider" "$current_worker_rel" "$last_review_rel"; then
            stop_reason="worker_revision_failed"
            execution_status="failed"
            loop_finished_ts="$(date +%s)"
            total_runtime_seconds=$((loop_finished_ts - loop_started_ts))
            write_phase2_loop_summary "$loop_summary_path" "$loop_events_path" \
                "$slug" "$mode" "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" \
                "$PHASE2_MAX_REVIEW_ROUNDS" "$current_worker_round" "$completed_review_rounds" "$final_review_status" "$stop_reason" "$execution_status" "$total_runtime_seconds" \
                "reports/phase2/${slug}-phase2.json" "$current_worker_rel" "$last_review_rel" "$tp" "$fp" "$rv" "$total" "$risk" "$PHASE2_ENABLE_FORCED_EXPLORATION" "$PHASE2_MAX_EXPLORATION_CANDIDATES"
            annotate_phase2_loop_output "$slug" "$current_worker_path" \
                "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" \
                "$mode" "$current_worker_round" "$completed_review_rounds" "$PHASE2_MAX_REVIEW_ROUNDS" \
                "$final_review_status" "$current_worker_rel" "$last_review_rel" \
                "$loop_summary_rel" "$stop_reason" "$total_runtime_seconds" "$execution_status" \
                "$PHASE2_ENABLE_FORCED_EXPLORATION" "$PHASE2_MAX_EXPLORATION_CANDIDATES"
            log_error_block "Phase 2 worker revision failed" \
                "slug" "$slug" \
                "round" "$next_worker_round" \
                "provider" "$worker_provider" \
                "reason" "$(summarize_provider_errlog "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$next_worker_round" revision)")" \
                "log" "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$next_worker_round" revision)"
            RUN_RESULT="failed"
            return 1
        fi

        current_worker_round="$next_worker_round"
        current_worker_path="$(phase2_worker_output_path "$slug" "$current_worker_round")"
        current_worker_rel="$(phase2_worker_output_rel "$slug" "$current_worker_round")"
        current_worker_raw="$(phase2_worker_raw_path "$slug" "$current_worker_round")"
        loop_errlogs+=("$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$current_worker_round" revision)")
        counts="$(phase2_counts "$current_worker_path")"
        IFS='|' read -r tp fp rv total risk <<< "$counts"
        worker_duration="${PHASE2_LAST_DURATION_SECONDS:-0}"
        worker_delta_json="$(phase2_transition_meta "$prev_worker_path" "$current_worker_path")"
        append_phase2_loop_worker_event "$loop_events_path" "$current_worker_round" "revision" "$worker_provider" "$worker_model" \
            "$worker_duration" "$(root_relative_path "$current_worker_path")" "$(root_relative_path "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$current_worker_round" revision)")" \
            "$tp" "$fp" "$rv" "$total" "$risk" "$worker_delta_json"
        echo "  Worker revision ${current_worker_round} results: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}"
    done

    if [ "$execution_status" = "success" ] && [ "$PHASE2_ENABLE_FORCED_EXPLORATION" = true ] && [ "$forced_exploration_already_completed" != true ]; then
        local explore_review_round
        local explore_review_status explore_review_finding_count explore_review_missed_count explore_review_material
        local explore_reviewer_duration
        local exploration_errlog
        explore_review_round=$((completed_review_rounds + 1))
        echo "  Reviewer explore round ${explore_review_round}: ${reviewer_provider}"
        if run_phase2_review_round "$slug" "$explore_review_round" "$reviewer_provider" "$current_worker_rel" "explore"; then
            last_review_path="$(phase2_review_output_path "$slug" "$explore_review_round")"
            last_review_rel="$(phase2_review_output_rel "$slug" "$explore_review_round")"
            exploration_errlog="$(phase2_loop_errlog_path "$slug" reviewer "$reviewer_provider" "$explore_review_round" explore)"
            loop_errlogs+=("$exploration_errlog")
            review_meta="$(phase2_review_meta "$last_review_path")"
            IFS='|' read -r explore_review_status explore_review_finding_count explore_review_missed_count explore_review_material <<< "$review_meta"
            completed_review_rounds="$explore_review_round"
            final_review_status="$explore_review_status"
            explore_reviewer_duration="${PHASE2_LAST_DURATION_SECONDS:-0}"
            append_phase2_loop_reviewer_event "$loop_events_path" "$explore_review_round" "explore" "$reviewer_provider" "$reviewer_model" \
                "$explore_reviewer_duration" "$(root_relative_path "$last_review_path")" "$(root_relative_path "$exploration_errlog")" \
                "$explore_review_status" "$explore_review_finding_count" "$explore_review_missed_count" "$explore_review_material"
            echo "  Reviewer explore verdict: ${explore_review_status} | missed_findings=${explore_review_missed_count}"

            if [ "$explore_review_status" != "stable" ]; then
                next_worker_round=$((current_worker_round + 1))
                echo "  Worker expansion round ${next_worker_round}: ${worker_provider}"
                prev_worker_path="$current_worker_path"
                prev_worker_rel="$current_worker_rel"
                if run_phase2_worker_round "$slug" "$next_worker_round" "expansion" "$worker_provider" "$current_worker_rel" "$last_review_rel"; then
                    current_worker_round="$next_worker_round"
                    current_worker_path="$(phase2_worker_output_path "$slug" "$current_worker_round")"
                    current_worker_rel="$(phase2_worker_output_rel "$slug" "$current_worker_round")"
                    current_worker_raw="$(phase2_worker_raw_path "$slug" "$current_worker_round")"
                    loop_errlogs+=("$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$current_worker_round" expansion)")
                    counts="$(phase2_counts "$current_worker_path")"
                    IFS='|' read -r tp fp rv total risk <<< "$counts"
                    worker_duration="${PHASE2_LAST_DURATION_SECONDS:-0}"
                    worker_delta_json="$(phase2_transition_meta "$prev_worker_path" "$current_worker_path")"
                    append_phase2_loop_worker_event "$loop_events_path" "$current_worker_round" "expansion" "$worker_provider" "$worker_model" \
                        "$worker_duration" "$(root_relative_path "$current_worker_path")" "$(root_relative_path "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$current_worker_round" expansion)")" \
                        "$tp" "$fp" "$rv" "$total" "$risk" "$worker_delta_json"
                    stop_reason="forced_exploration_completed"
                    echo "  Worker expansion ${current_worker_round} results: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}"
                else
                    execution_status="partial"
                    stop_reason="forced_exploration_worker_failed"
                    log_warn "Forced exploration worker expansion failed; keeping the current canonical worker artifact."
                fi
            else
                stop_reason="forced_exploration_stable_no_new_candidates"
            fi
        else
            execution_status="partial"
            stop_reason="forced_exploration_reviewer_failed"
            log_warn "Forced exploration reviewer failed; preserving the current canonical worker artifact."
        fi
    fi

    if [ "$execution_status" = "success" ] && [ "$stop_reason" = "not_started" ]; then
        if [ "$completed_review_rounds" -ge "$PHASE2_MAX_REVIEW_ROUNDS" ] && [ "$final_review_status" != "stable" ]; then
            stop_reason="max_review_rounds_exhausted"
        else
            stop_reason="worker_completed_without_reviewer_signal"
        fi
    fi
    loop_finished_ts="$(date +%s)"
    total_runtime_seconds=$((loop_finished_ts - loop_started_ts))
    write_phase2_loop_summary "$loop_summary_path" "$loop_events_path" \
        "$slug" "$mode" "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" \
        "$PHASE2_MAX_REVIEW_ROUNDS" "$current_worker_round" "$completed_review_rounds" "$final_review_status" "$stop_reason" "$execution_status" "$total_runtime_seconds" \
        "reports/phase2/${slug}-phase2.json" "$current_worker_rel" "$last_review_rel" "$tp" "$fp" "$rv" "$total" "$risk" "$PHASE2_ENABLE_FORCED_EXPLORATION" "$PHASE2_MAX_EXPLORATION_CANDIDATES"
    annotate_phase2_loop_output "$slug" "$current_worker_path" \
        "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" \
        "$mode" "$current_worker_round" "$completed_review_rounds" "$PHASE2_MAX_REVIEW_ROUNDS" \
        "$final_review_status" "$current_worker_rel" "$last_review_rel" \
        "$loop_summary_rel" "$stop_reason" "$total_runtime_seconds" "$execution_status" \
        "$PHASE2_ENABLE_FORCED_EXPLORATION" "$PHASE2_MAX_EXPLORATION_CANDIDATES"

    local local_phase2_path cluster_errlog
    local_phase2_path="$(phase2_local_output_path "$slug")"
    cluster_errlog="$(phase2_cluster_errlog_path "$slug")"

    cp -f "$current_worker_path" "$local_phase2_path"
    cp -f "$current_worker_path" "$output"
    cp -f "$current_worker_raw" "$raw_output" 2>/dev/null || true
    cp -f "$current_worker_path" "$(phase2_output_path "$slug" "$worker_provider")" 2>/dev/null || true
    cp -f "$current_worker_raw" "$(phase2_raw_path "$slug" "$worker_provider")" 2>/dev/null || true

    if [ "$PHASE2_ENABLE_CLUSTER_CONSENSUS" = true ]; then
        run_phase2_cluster_pipeline "$slug" "$local_phase2_path" "$cluster_errlog" || true
        if [ -f "$cluster_errlog" ]; then
            loop_errlogs+=("$cluster_errlog")
        fi
    fi

    : > "$errlog_deep"
    local loop_errlog
    for loop_errlog in "${loop_errlogs[@]-}"; do
        [ -f "$loop_errlog" ] || continue
        printf '===== %s =====\n' "$(basename "$loop_errlog")" >> "$errlog_deep"
        cat "$loop_errlog" >> "$errlog_deep"
        printf '\n\n' >> "$errlog_deep"
    done
    if [ "$mode" = "quick" ] && [ -f "$initial_worker_errlog" ]; then
        cp -f "$initial_worker_errlog" "$errlog_quick" 2>/dev/null || true
    fi

    counts="$(phase2_counts "$output")"
    IFS='|' read -r tp fp rv total risk <<< "$counts"
    echo "  Final Phase 2 results: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}"
    echo "  Canonical Phase 2 selected from worker: ${worker_provider}"
    echo "  Canonical output: ${output}"
    echo "  Canonical raw output: ${raw_output}"

    log_section "Done: ${slug}"
    RUN_RESULT="done"
    return 0
}

if [ -n "$SPECIFIC_SLUG" ]; then
    run_one "$SPECIFIC_SLUG"
    exit $?
fi

if ! [[ "$THREADS" =~ ^[0-9]+$ ]] || [ "$THREADS" -lt 1 ]; then
    log_error "threads must be a positive integer."
    exit 1
fi

IR_FILES=()
while IFS= read -r ir_file; do
    IR_FILES+=("$ir_file")
done < <(find "$PHASE1_DIR" -maxdepth 1 -type f -name '*-ir.json' | sort)
if [ "${#IR_FILES[@]}" -eq 0 ]; then
    log_error "No Phase 1 IR files found in $PHASE1_DIR"
    exit 1
fi

INDEXED_FILE="$(mktemp)"
trap 'rm -f "${INDEXED_FILE:-}" "${SELECTED_FILE:-}" "${WORKER_FILE:-}" "${STATUS_FILE:-}"' EXIT

INDEX=0
for ir_file in "${IR_FILES[@]}"; do
    slug="$(basename "$ir_file" -ir.json)"
    case "$slug" in
        plugin-*) continue ;;
    esac
    INDEX=$((INDEX + 1))
    printf '%s|%s\n' "$INDEX" "$slug" >> "$INDEXED_FILE"
done

if [ ! -s "$INDEXED_FILE" ]; then
    log_error "No valid plugins resolved from IR list."
    exit 1
fi

AVAILABLE_COUNT="$(wc -l < "$INDEXED_FILE" | tr -d ' ')"
AVAILABLE_INDEX_CSV="$(cut -d'|' -f1 "$INDEXED_FILE" | paste -sd, -)"
DONE_INDEX_CSV="$(awk -F'|' -v r="$PHASE2_DIR" '{f=r"/"$2"-phase2.json"; if (system("[ -f \""f"\" ]")==0) print $1}' "$INDEXED_FILE" | paste -sd, -)"
if [ -z "$DONE_INDEX_CSV" ]; then
    DONE_INDEX_CSV="none"
fi

if [ "$INTERACTIVE" != true ] && [ "$START_SET" != true ] && [ "$END_SET" != true ] && [ "$THREADS_SET" != true ]; then
    INTERACTIVE=true
fi

log_section "Phase 2 Batch"
echo "  Available plugins: ${AVAILABLE_COUNT}"
echo "  Indexes (IR-order): [${AVAILABLE_INDEX_CSV}]"
echo "  Already has phase2 output: [${DONE_INDEX_CSV}]"
echo "  Force: ${FORCE}"
echo "  Force deep: ${FORCE_DEEP}"
echo "  Worker provider: ${PHASE2_WORKER_PROVIDER} ($(phase2_role_model worker "$PHASE2_WORKER_PROVIDER" || true))"
echo "  Reviewer provider: ${PHASE2_REVIEWER_PROVIDER} ($(phase2_role_model reviewer "$PHASE2_REVIEWER_PROVIDER" || true))"
echo "  Max review rounds: ${PHASE2_MAX_REVIEW_ROUNDS}"
echo "  Prompt template: ${PROMPT_TEMPLATE}"
echo "  Timeout policy: worker=${PHASE2_WORKER_TIMEOUT_SECONDS}s, revision=${PHASE2_REVISION_TIMEOUT_SECONDS}s, reviewer=${PHASE2_REVIEWER_TIMEOUT_SECONDS}s, exploration=${PHASE2_EXPLORATION_TIMEOUT_SECONDS}s"

if [ "$INTERACTIVE" = true ]; then
    while true; do
        read -r -p "Start index: " START_INDEX
        read -r -p "End index: " END_INDEX
        if ! [[ "$START_INDEX" =~ ^[0-9]+$ ]] || ! [[ "$END_INDEX" =~ ^[0-9]+$ ]]; then
            log_error "Start/end must be positive integers. Try again."
            continue
        fi
        if [ "$START_INDEX" -gt "$END_INDEX" ]; then
            log_error "Start index must be <= end index. Try again."
            continue
        fi
        break
    done

    while true; do
        read -r -p "Threads: " THREADS
        if ! [[ "$THREADS" =~ ^[0-9]+$ ]] || [ "$THREADS" -lt 1 ]; then
            log_error "Threads must be a positive integer. Try again."
            continue
        fi
        break
    done
else
    if ! [[ "$START_INDEX" =~ ^[0-9]+$ ]] || ! [[ "$END_INDEX" =~ ^[0-9]+$ ]]; then
        log_error "start-index and end-index must be positive integers."
        exit 1
    fi
    if [ "$START_INDEX" -gt "$END_INDEX" ]; then
        log_error "start-index must be <= end-index."
        exit 1
    fi
fi

SELECTED_FILE="$(mktemp)"
awk -F'|' -v s="$START_INDEX" -v e="$END_INDEX" '$1>=s && $1<=e {print $0}' "$INDEXED_FILE" > "$SELECTED_FILE"
SELECTED_COUNT="$(wc -l < "$SELECTED_FILE" | tr -d ' ')"

if [ "$SELECTED_COUNT" -eq 0 ]; then
    log_error "No plugins found in selected range ${START_INDEX}..${END_INDEX}"
    exit 1
fi

SELECTED_INDEX_CSV="$(cut -d'|' -f1 "$SELECTED_FILE" | paste -sd, -)"
echo "  Selected range: ${START_INDEX}..${END_INDEX}"
echo "  Selected count: ${SELECTED_COUNT}"
echo "  Selected indexes: [${SELECTED_INDEX_CSV}]"
echo "  Threads: ${THREADS}"

DONE=0
SKIPPED=0
FAILED=0

if [ "$THREADS" -le 1 ]; then
    while IFS='|' read -r _idx slug; do
        if run_one "$slug"; then
            case "$RUN_RESULT" in
                done) DONE=$((DONE + 1)) ;;
                skipped) SKIPPED=$((SKIPPED + 1)) ;;
                *) DONE=$((DONE + 1)) ;;
            esac
        else
            FAILED=$((FAILED + 1))
        fi
    done < "$SELECTED_FILE"
else
    WORKER_FILE="$(mktemp)"
    STATUS_FILE="$(mktemp)"

    cat > "$WORKER_FILE" <<'EOF'
#!/bin/bash
set -euo pipefail
entry="$1"
slug="${entry#*|}"
cmd=(bash "${SELF_SCRIPT}" --slug "$slug")
if [ "${FORCE}" = true ]; then
  cmd+=(--force)
fi
if [ "${FORCE_DEEP}" = true ]; then
  cmd+=(--force-deep)
fi
set +e
out="$("${cmd[@]}" 2>&1)"
rc=$?
set -e
echo "$out"
if [ $rc -ne 0 ]; then
  echo "failed|${slug}" >> "$STATUS_FILE"
elif echo "$out" | grep -q '^\[=\] Skip '; then
  echo "skipped|${slug}" >> "$STATUS_FILE"
elif echo "$out" | grep -q '^\[INFO\] Skip '; then
  echo "skipped|${slug}" >> "$STATUS_FILE"
else
  echo "done|${slug}" >> "$STATUS_FILE"
fi
exit 0
EOF

    chmod +x "$WORKER_FILE"
    export SELF_SCRIPT="${BIN_DIR}/run-phase2.sh" FORCE FORCE_DEEP STATUS_FILE \
        LLM_PROVIDERS CODEX_BIN CODEX_MODEL CLAUDE_BIN CLAUDE_MODEL PHASE2_PRIMARY_PROVIDER \
        PHASE2_WORKER_PROVIDER PHASE2_REVIEWER_PROVIDER \
        PHASE2_WORKER_CODEX_MODEL PHASE2_WORKER_CLAUDE_MODEL \
        PHASE2_REVIEWER_CODEX_MODEL PHASE2_REVIEWER_CLAUDE_MODEL \
        PHASE2_MAX_REVIEW_ROUNDS PHASE2_ENABLE_FORCED_EXPLORATION PHASE2_MAX_EXPLORATION_CANDIDATES \
        PHASE2_PROVIDER_TIMEOUT_SECONDS PHASE2_WORKER_TIMEOUT_SECONDS PHASE2_REVISION_TIMEOUT_SECONDS \
        PHASE2_REVIEWER_TIMEOUT_SECONDS PHASE2_EXPLORATION_TIMEOUT_SECONDS

    xargs -P "$THREADS" -I {} "$WORKER_FILE" "{}" < "$SELECTED_FILE"

    DONE=$(grep -c '^done|' "$STATUS_FILE" 2>/dev/null || true)
    SKIPPED=$(grep -c '^skipped|' "$STATUS_FILE" 2>/dev/null || true)
    FAILED=$(grep -c '^failed|' "$STATUS_FILE" 2>/dev/null || true)
fi

echo ""
log_section "Phase 2 Batch Complete"
echo "  Considered: ${SELECTED_COUNT}"
echo "  Done:    ${DONE}"
echo "  Failed:  ${FAILED}"
echo "  Skipped: ${SKIPPED}"
echo "  Quota ledger: ${QUOTA_LEDGER}"

if [ -f "${BIN_DIR}/quota-report.py" ]; then
    echo ""
    python3 "${BIN_DIR}/quota-report.py" --reports-dir "$REPORTS_DIR" --phase phase2 --days 1 --limit 10 || true
fi

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi

exit 0
