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
COST_TELEMETRY_BIN="${BIN_DIR}/cost_telemetry.py"
PROVIDER_STRATEGY_BIN="${BIN_DIR}/provider_strategy.py"
PHASE2_TERMINAL_CLOSURE_BIN="${BIN_DIR}/phase2_terminal_closure.py"

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
RESUME_PUBLIC_REQUESTED=false
INTERACTIVE=false
WITH_CLAUDE=false
PROVIDERS_EXPLICIT=false
RUN_RESULT=""
LLM_PROVIDERS="${LLM_PROVIDERS:-${LLM_PROVIDER:-}}"
CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_MODEL="${CODEX_MODEL:-${LLM_MODEL:-}}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
# Reasoning effort for every claude CLI call (low|medium|high|xhigh|max).
CLAUDE_EFFORT="${CLAUDE_EFFORT:-xhigh}"
export CLAUDE_EFFORT
CLAUDE_MODEL="${CLAUDE_MODEL:-${LLM_MODEL:-}}"
CLAUDE_SAFE_TOOLS="${CLAUDE_SAFE_TOOLS:-Read,Grep,Glob,Write}"
PHASE2_PRIMARY_PROVIDER="${PHASE2_PRIMARY_PROVIDER:-}"
PHASE2_PROVIDER_TIMEOUT_SECONDS="${PHASE2_PROVIDER_TIMEOUT_SECONDS:-600}"
PHASE2_WORKER_TIMEOUT_SECONDS="${PHASE2_WORKER_TIMEOUT_SECONDS:-900}"
PHASE2_REVISION_TIMEOUT_SECONDS="${PHASE2_REVISION_TIMEOUT_SECONDS:-600}"
PHASE2_REVIEWER_TIMEOUT_SECONDS="${PHASE2_REVIEWER_TIMEOUT_SECONDS:-600}"
PHASE2_EXPLORATION_TIMEOUT_SECONDS="${PHASE2_EXPLORATION_TIMEOUT_SECONDS:-240}"
PHASE2_REVIEWER_BATCH_RETRY_LIMIT="${PHASE2_REVIEWER_BATCH_RETRY_LIMIT:-3}"
PHASE2_REVIEWER_BATCH_RETRY_BACKOFF_SECONDS="${PHASE2_REVIEWER_BATCH_RETRY_BACKOFF_SECONDS:-3}"
PHASE2_ENABLE_CLUSTER_CONSENSUS="${PHASE2_ENABLE_CLUSTER_CONSENSUS:-true}"
PHASE2_CLUSTER_LIMIT="${PHASE2_CLUSTER_LIMIT:-}"
# Provider precedence: CLI flag > operator env (.claude/settings*.json) > Wave 6 tier policy > default.
# The default expansions below erase the difference between "operator set this" and "script defaulted it",
# so record the origin first. These snapshots are read-only after this point; the per-plugin resolver
# must never write back into them or provider N-1 leaks into plugin N in batch loops.
PHASE2_WORKER_PROVIDER_FROM_ENV=false
PHASE2_REVIEWER_PROVIDER_FROM_ENV=false
PHASE2_EXPLORE_PROVIDER_FROM_ENV=false
PHASE2_CLUSTER_SYNTH_PROVIDER_FROM_ENV=false
PHASE2_CLUSTER_CHALLENGER_PROVIDER_FROM_ENV=false
if [ -n "${PHASE2_WORKER_PROVIDER:-}" ]; then PHASE2_WORKER_PROVIDER_FROM_ENV=true; fi
if [ -n "${PHASE2_REVIEWER_PROVIDER:-}" ]; then PHASE2_REVIEWER_PROVIDER_FROM_ENV=true; fi
if [ -n "${PHASE2_EXPLORE_PROVIDER:-}" ]; then PHASE2_EXPLORE_PROVIDER_FROM_ENV=true; fi
if [ -n "${PHASE2_CLUSTER_SYNTH_PROVIDER:-}" ]; then PHASE2_CLUSTER_SYNTH_PROVIDER_FROM_ENV=true; fi
if [ -n "${PHASE2_CLUSTER_CHALLENGER_PROVIDER:-}" ]; then PHASE2_CLUSTER_CHALLENGER_PROVIDER_FROM_ENV=true; fi

PHASE2_WORKER_PROVIDER="${PHASE2_WORKER_PROVIDER:-codex}"
PHASE2_REVIEWER_PROVIDER="${PHASE2_REVIEWER_PROVIDER:-codex}"
PHASE2_EXPLORE_PROVIDER="${PHASE2_EXPLORE_PROVIDER:-}"
PHASE2_CLUSTER_SYNTH_PROVIDER="${PHASE2_CLUSTER_SYNTH_PROVIDER:-codex}"
PHASE2_CLUSTER_CHALLENGER_PROVIDER="${PHASE2_CLUSTER_CHALLENGER_PROVIDER:-codex}"
PHASE2_WORKER_EXECUTION_MODE="${PHASE2_WORKER_EXECUTION_MODE:-adaptive}"
PHASE2_WORKER_CHUNK_PARALLEL_LIMIT="${PHASE2_WORKER_CHUNK_PARALLEL_LIMIT:-4}"
PHASE2_CHUNKED_RESUME_MISSING_ONLY="${PHASE2_CHUNKED_RESUME_MISSING_ONLY:-false}"
PHASE2_WORKER_CODEX_MODEL="${PHASE2_WORKER_CODEX_MODEL:-gpt-5.4}"
PHASE2_WORKER_CLAUDE_MODEL="${PHASE2_WORKER_CLAUDE_MODEL:-${CLAUDE_MODEL:-claude-opus-4-7}}"
PHASE2_REVIEWER_CODEX_MODEL="${PHASE2_REVIEWER_CODEX_MODEL:-gpt-5.4}"
PHASE2_REVIEWER_CLAUDE_MODEL="${PHASE2_REVIEWER_CLAUDE_MODEL:-claude-opus-4-7}"
PHASE2_CLUSTER_SYNTH_CODEX_MODEL="${PHASE2_CLUSTER_SYNTH_CODEX_MODEL:-gpt-5.4}"
PHASE2_CLUSTER_SYNTH_CLAUDE_MODEL="${PHASE2_CLUSTER_SYNTH_CLAUDE_MODEL:-${CLAUDE_MODEL:-claude-opus-4-7}}"
PHASE2_CLUSTER_CHALLENGER_CODEX_MODEL="${PHASE2_CLUSTER_CHALLENGER_CODEX_MODEL:-gpt-5.4}"
PHASE2_CLUSTER_CHALLENGER_CLAUDE_MODEL="${PHASE2_CLUSTER_CHALLENGER_CLAUDE_MODEL:-${CLAUDE_MODEL:-claude-opus-4-7}}"
PHASE2_MAX_REVIEW_ROUNDS="${PHASE2_MAX_REVIEW_ROUNDS:-1}"
PHASE2_ENABLE_FORCED_EXPLORATION="${PHASE2_ENABLE_FORCED_EXPLORATION:-true}"
PHASE2_MAX_EXPLORATION_CANDIDATES="${PHASE2_MAX_EXPLORATION_CANDIDATES:-3}"

START_SET=false
END_SET=false
THREADS_SET=false
WORKER_PROVIDER_EXPLICIT=false
REVIEWER_PROVIDER_EXPLICIT=false
REVIEW_ROUNDS_EXPLICIT=false
FORCED_EXPLORATION_EXPLICIT=false
EXPLORATION_CANDIDATES_EXPLICIT=false
REVISION_TIMEOUT_EXPLICIT=false
REVIEWER_TIMEOUT_EXPLICIT=false
EXPLORATION_TIMEOUT_EXPLICIT=false

PHASE2_BASELINE_MAX_REVIEW_ROUNDS=1
PHASE2_BASELINE_ENABLE_FORCED_EXPLORATION=true
PHASE2_BASELINE_MAX_EXPLORATION_CANDIDATES=3
PHASE2_BASELINE_REVISION_TIMEOUT_SECONDS=600
PHASE2_BASELINE_REVIEWER_TIMEOUT_SECONDS=600
PHASE2_BASELINE_EXPLORATION_TIMEOUT_SECONDS=240

usage() {
    cat <<'EOF'
Usage:
  run-phase2.sh <plugin-slug>
  run-phase2.sh --slug <plugin-slug> [--force] [--force-deep]
  run-phase2.sh --slug <plugin-slug> --resume [--force] [--force-deep]
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
  --force-deep           Override adaptive quick-triage fallback and always run deep prompt.
  --resume               Preferred public resume flag. Reuse existing worker/review artifacts and, if Phase 2 goes chunked, let the coordinator rerun only missing worker bundles.
  --resume-existing      Resume from existing worker/review artifacts instead of restarting from round 1.
  --with-claude          Explicit provider-set shorthand for --providers codex,claude.
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
  --worker-provider <p>  Phase 2 worker provider (default: codex).
  --reviewer-provider <p> Phase 2 reviewer provider (default: codex).
  --worker-codex-model <name>   Codex model for worker role (default: gpt-5.4).
  --worker-claude-model <name>  Claude model for worker role.
  --reviewer-codex-model <name> Codex model for reviewer role.
  --reviewer-claude-model <name> Claude model for reviewer role (default: claude-opus-4-7).
  --max-review-rounds <N> Worker/reviewer loop rounds (default: 1).
  --forced-exploration         Run one final reviewer-driven expansion round (default: on).
  --no-forced-exploration      Skip the final expansion round.
  --max-exploration-candidates <N> Cap the final exploration candidates (default: 3).
  --codex-bin <path>     Codex CLI binary/path (default: env CODEX_BIN or codex).
  --claude-bin <path>    Claude Code binary/path (default: env CLAUDE_BIN or claude).

Notes:
  - Phase 2 depth is adaptive by default.
  - High-signal plugins may automatically switch worker round 1 to candidate-chunked execution
    before the canonical reviewer_core/reviewer_explore + cluster/consensus path continues.
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
        --resume)
            RESUME_EXISTING=true
            RESUME_PUBLIC_REQUESTED=true
            shift
            ;;
        --resume-existing)
            RESUME_EXISTING=true
            shift
            ;;
        --with-claude)
            WITH_CLAUDE=true
            LLM_PROVIDERS="codex,claude"
            PROVIDERS_EXPLICIT=true
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
            REVISION_TIMEOUT_EXPLICIT=true
            shift 2
            ;;
        --reviewer-timeout)
            PHASE2_REVIEWER_TIMEOUT_SECONDS="${2:-}"
            REVIEWER_TIMEOUT_EXPLICIT=true
            shift 2
            ;;
        --exploration-timeout)
            PHASE2_EXPLORATION_TIMEOUT_SECONDS="${2:-}"
            EXPLORATION_TIMEOUT_EXPLICIT=true
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
            REVIEW_ROUNDS_EXPLICIT=true
            shift 2
            ;;
        --forced-exploration)
            PHASE2_ENABLE_FORCED_EXPLORATION=true
            FORCED_EXPLORATION_EXPLICIT=true
            shift
            ;;
        --no-forced-exploration)
            PHASE2_ENABLE_FORCED_EXPLORATION=false
            FORCED_EXPLORATION_EXPLICIT=true
            shift
            ;;
        --max-exploration-candidates)
            PHASE2_MAX_EXPLORATION_CANDIDATES="${2:-}"
            EXPLORATION_CANDIDATES_EXPLICIT=true
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

if [ "$RESUME_PUBLIC_REQUESTED" = true ]; then
    PHASE2_CHUNKED_RESUME_MISSING_ONLY=true
fi

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

TERMINAL_REVIEW_PROMPT_TEMPLATE=""
for candidate in \
    "${TOOLS_DIR}/config/phase2-terminal-review-prompt-template.md" \
    "${ROOT_DIR}/phase2-terminal-review-prompt-template.md"
do
    if [ -f "$candidate" ]; then
        TERMINAL_REVIEW_PROMPT_TEMPLATE="$candidate"
        break
    fi
done

if [ -z "$TERMINAL_REVIEW_PROMPT_TEMPLATE" ]; then
    log_error_block "phase2 terminal review prompt template not found" \
        "checked" "${TOOLS_DIR}/config/phase2-terminal-review-prompt-template.md" \
        "checked" "${ROOT_DIR}/phase2-terminal-review-prompt-template.md"
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

PHASE2_REVIEW_TERMINAL_CORE_SCHEMA="${ROOT_DIR}/contracts/phase2-review-terminal-core-output.schema.json"
if [ ! -f "$PHASE2_REVIEW_TERMINAL_CORE_SCHEMA" ]; then
    log_error_block "phase2 review terminal core schema not found" \
        "checked" "${PHASE2_REVIEW_TERMINAL_CORE_SCHEMA}"
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

PHASE2_AGENT_INPUT_PREPARER="${ROOT_DIR}/tools/bin/prepare_agent_inputs.py"
PHASE2_MULTI_WORKER_ORCHESTRATOR="${ROOT_DIR}/tools/bin/orchestrate-agents.sh"

PHASE2_CLUSTER_BUILDER="${PHASE2_CLUSTER_BUILDER:-${ROOT_DIR}/tools/bin/build_candidate_clusters.py}"
PHASE2_CLUSTER_PACK_BUILDER="${PHASE2_CLUSTER_PACK_BUILDER:-${ROOT_DIR}/tools/bin/build_cluster_evidence_pack.py}"
PHASE2_CLUSTER_RUNNER="${PHASE2_CLUSTER_RUNNER:-${ROOT_DIR}/tools/bin/run-phase2-clusters.py}"
PHASE2_CONSENSUS_WRITER="${PHASE2_CONSENSUS_WRITER:-${ROOT_DIR}/tools/bin/write_phase2_consensus.py}"
CLAUDE_STREAM_PARSER="${ROOT_DIR}/tools/bin/claude_stream_to_text.py"

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
    SYSTEM_PROMPT_PHASE2='Apply the WordPress AppSec workflow stated in the prompt and project docs directly. Do not rely on auto-loaded skills.'
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
    SYSTEM_PROMPT_PHASE2_REVIEW_CORE='You are the core reviewer for the Phase 2 WordPress plugin audit. Apply the WordPress AppSec workflow stated in the prompt and project docs directly.'
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
    SYSTEM_PROMPT_PHASE2_REVIEW_EXPLORE='You are the explore reviewer for the Phase 2 WordPress plugin audit. Apply the WordPress AppSec workflow stated in the prompt and project docs directly.'
fi

SYSTEM_PROMPT_PHASE2_REVIEW_TERMINAL=""
SYSTEM_PROMPT_PHASE2_REVIEW_TERMINAL_PATH=""
for candidate in \
    "${TOOLS_DIR}/config/system-prompt-phase2-review-terminal.md" \
    "${ROOT_DIR}/system-prompt-phase2-review-terminal.md"
do
    if [ -f "$candidate" ]; then
        SYSTEM_PROMPT_PHASE2_REVIEW_TERMINAL="$(cat "$candidate")"
        SYSTEM_PROMPT_PHASE2_REVIEW_TERMINAL_PATH="$candidate"
        break
    fi
done

if [ -z "$SYSTEM_PROMPT_PHASE2_REVIEW_TERMINAL" ]; then
    SYSTEM_PROMPT_PHASE2_REVIEW_TERMINAL='You are the terminal core reviewer for the Phase 2 WordPress plugin audit. This round must close every unresolved packet as TP or FP and may not leave ambiguity behind.'
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
    log_warn "Invalid PHASE2_MAX_REVIEW_ROUNDS=$PHASE2_MAX_REVIEW_ROUNDS. Using default ${PHASE2_BASELINE_MAX_REVIEW_ROUNDS}."
    PHASE2_MAX_REVIEW_ROUNDS="$PHASE2_BASELINE_MAX_REVIEW_ROUNDS"
fi

PHASE2_ENABLE_FORCED_EXPLORATION="$(printf '%s' "$PHASE2_ENABLE_FORCED_EXPLORATION" | tr '[:upper:]' '[:lower:]')"
if [[ "$PHASE2_ENABLE_FORCED_EXPLORATION" != "true" && "$PHASE2_ENABLE_FORCED_EXPLORATION" != "false" ]]; then
    log_warn "Invalid PHASE2_ENABLE_FORCED_EXPLORATION=$PHASE2_ENABLE_FORCED_EXPLORATION. Using default ${PHASE2_BASELINE_ENABLE_FORCED_EXPLORATION}."
    PHASE2_ENABLE_FORCED_EXPLORATION="$PHASE2_BASELINE_ENABLE_FORCED_EXPLORATION"
fi

if ! [[ "$PHASE2_MAX_EXPLORATION_CANDIDATES" =~ ^[0-9]+$ ]] || [ "$PHASE2_MAX_EXPLORATION_CANDIDATES" -lt 1 ]; then
    log_warn "Invalid PHASE2_MAX_EXPLORATION_CANDIDATES=$PHASE2_MAX_EXPLORATION_CANDIDATES. Using default ${PHASE2_BASELINE_MAX_EXPLORATION_CANDIDATES}."
    PHASE2_MAX_EXPLORATION_CANDIDATES="$PHASE2_BASELINE_MAX_EXPLORATION_CANDIDATES"
fi

PHASE2_WORKER_EXECUTION_MODE="$(printf '%s' "$PHASE2_WORKER_EXECUTION_MODE" | tr '[:upper:]' '[:lower:]')"
if [[ "$PHASE2_WORKER_EXECUTION_MODE" != "adaptive" && "$PHASE2_WORKER_EXECUTION_MODE" != "monolithic" && "$PHASE2_WORKER_EXECUTION_MODE" != "chunked" ]]; then
    log_warn "Invalid PHASE2_WORKER_EXECUTION_MODE=$PHASE2_WORKER_EXECUTION_MODE. Using adaptive."
    PHASE2_WORKER_EXECUTION_MODE="adaptive"
fi

if ! [[ "$PHASE2_WORKER_CHUNK_PARALLEL_LIMIT" =~ ^[0-9]+$ ]] || [ "$PHASE2_WORKER_CHUNK_PARALLEL_LIMIT" -lt 1 ]; then
    log_warn "Invalid PHASE2_WORKER_CHUNK_PARALLEL_LIMIT=$PHASE2_WORKER_CHUNK_PARALLEL_LIMIT. Using default 4."
    PHASE2_WORKER_CHUNK_PARALLEL_LIMIT=4
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

# Frozen provider baseline: CLI flags have been applied, no plugin has been resolved yet.
# phase2_resolve_stage_providers reads these instead of the mutable PHASE2_*_PROVIDER globals,
# which it rewrites per plugin.
PHASE2_BASELINE_WORKER_PROVIDER="$PHASE2_WORKER_PROVIDER"
PHASE2_BASELINE_REVIEWER_PROVIDER="$PHASE2_REVIEWER_PROVIDER"
PHASE2_BASELINE_EXPLORE_PROVIDER="$PHASE2_EXPLORE_PROVIDER"
PHASE2_BASELINE_CLUSTER_SYNTH_PROVIDER="$PHASE2_CLUSTER_SYNTH_PROVIDER"
PHASE2_BASELINE_CLUSTER_CHALLENGER_PROVIDER="$PHASE2_CLUSTER_CHALLENGER_PROVIDER"

# A role is operator-pinned when the operator named it: a role flag, an explicit provider list
# (--provider/--providers/--with-claude), or an env value from .claude/settings*.json.
# Pinned roles are exempt from Wave 6 tier reassignment.
PHASE2_WORKER_PROVIDER_PINNED=false
PHASE2_REVIEWER_PROVIDER_PINNED=false
if [ "$WORKER_PROVIDER_EXPLICIT" = true ] || [ "$PROVIDERS_EXPLICIT" = true ] || [ "$WITH_CLAUDE" = true ] || [ "$PHASE2_WORKER_PROVIDER_FROM_ENV" = true ]; then
    PHASE2_WORKER_PROVIDER_PINNED=true
fi
if [ "$REVIEWER_PROVIDER_EXPLICIT" = true ] || [ "$PROVIDERS_EXPLICIT" = true ] || [ "$WITH_CLAUDE" = true ] || [ "$PHASE2_REVIEWER_PROVIDER_FROM_ENV" = true ]; then
    PHASE2_REVIEWER_PROVIDER_PINNED=true
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
    local threat_context_file
    threat_context_file="$(threat_context_path_for_slug "$slug")"
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
    if [ -n "$SYSTEM_PROMPT_PHASE2_REVIEW_TERMINAL_PATH" ]; then
        inputs+=("$SYSTEM_PROMPT_PHASE2_REVIEW_TERMINAL_PATH")
    fi
    if [ -f "$REVIEW_PROMPT_TEMPLATE" ]; then
        inputs+=("$REVIEW_PROMPT_TEMPLATE")
    fi
    if [ -f "$TERMINAL_REVIEW_PROMPT_TEMPLATE" ]; then
        inputs+=("$TERMINAL_REVIEW_PROMPT_TEMPLATE")
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
    if [ -f "$PHASE2_REVIEW_TERMINAL_CORE_SCHEMA" ]; then
        inputs+=("$PHASE2_REVIEW_TERMINAL_CORE_SCHEMA")
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
    if [ -f "$PHASE2_AGENT_INPUT_PREPARER" ]; then
        inputs+=("$PHASE2_AGENT_INPUT_PREPARER")
    fi
    if [ -f "$PHASE2_MULTI_WORKER_ORCHESTRATOR" ]; then
        inputs+=("$PHASE2_MULTI_WORKER_ORCHESTRATOR")
    fi
    if [ -f "$PROVIDER_STRATEGY_BIN" ]; then
        inputs+=("$PROVIDER_STRATEGY_BIN")
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
    if [ -f "$PHASE2_TERMINAL_CLOSURE_BIN" ]; then
        inputs+=("$PHASE2_TERMINAL_CLOSURE_BIN")
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

    freshness_is_fresh "$output" "${inputs[@]}" || return 1
    python3 - "$output" <<'PY' >/dev/null 2>&1
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(1)
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if data.get("trust_state") == "success" else 1)
PY
}

phase2_stage_model() {
    local stage="$1"
    local provider="$2"
    case "${stage}:${provider}" in
        worker:codex) printf '%s' "$PHASE2_WORKER_CODEX_MODEL" ;;
        worker:claude) printf '%s' "$PHASE2_WORKER_CLAUDE_MODEL" ;;
        reviewer_core:codex|reviewer_explore:codex) printf '%s' "$PHASE2_REVIEWER_CODEX_MODEL" ;;
        reviewer_core:claude|reviewer_explore:claude) printf '%s' "$PHASE2_REVIEWER_CLAUDE_MODEL" ;;
        cluster_synth:codex) printf '%s' "$PHASE2_CLUSTER_SYNTH_CODEX_MODEL" ;;
        cluster_synth:claude) printf '%s' "$PHASE2_CLUSTER_SYNTH_CLAUDE_MODEL" ;;
        cluster_challenger:codex) printf '%s' "$PHASE2_CLUSTER_CHALLENGER_CODEX_MODEL" ;;
        cluster_challenger:claude) printf '%s' "$PHASE2_CLUSTER_CHALLENGER_CLAUDE_MODEL" ;;
        phase3_primary:codex|phase3_skeptic:codex) printf '%s' "$CODEX_MODEL" ;;
        phase3_primary:claude|phase3_skeptic:claude) printf '%s' "$CLAUDE_MODEL" ;;
        *) printf '' ;;
    esac
}

phase2_provider_policy_export_assignments() {
    local policy_path="$1"
    python3 - "$policy_path" <<'PY'
import json
import shlex
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(1)
doc = json.loads(path.read_text(encoding="utf-8"))
final = doc.get("final") if isinstance(doc.get("final"), dict) else {}
stage = final.get("stage_providers") if isinstance(final.get("stage_providers"), dict) else {}
phase3 = final.get("phase3_recommendation") if isinstance(final.get("phase3_recommendation"), dict) else {}
assignments = {
    "PHASE2_PROVIDER_POLICY_TIER": final.get("tier_id") or "",
    "PHASE2_PROVIDER_POLICY_LABEL": final.get("tier_label") or "",
    "PHASE2_PROVIDER_POLICY_HIGH_VALUE": "true" if final.get("high_value_potential") else "false",
    "PHASE2_PROVIDER_POLICY_REASONS": ",".join(str(item) for item in (final.get("trigger_reasons") or []) if str(item)),
    "PHASE2_PROVIDER_POLICY_WORKER": stage.get("worker") or "",
    "PHASE2_PROVIDER_POLICY_REVIEWER_CORE": stage.get("reviewer_core") or "",
    "PHASE2_PROVIDER_POLICY_REVIEWER_EXPLORE": stage.get("reviewer_explore") or "",
    "PHASE2_PROVIDER_POLICY_CLUSTER_SYNTH": stage.get("cluster_synth") or "",
    "PHASE2_PROVIDER_POLICY_CLUSTER_CHALLENGER": stage.get("cluster_challenger") or "",
    "PHASE2_PROVIDER_POLICY_PHASE3_PRIMARY": phase3.get("primary_provider") or "",
    "PHASE2_PROVIDER_POLICY_PHASE3_PROVIDERS": ",".join(str(item) for item in (phase3.get("providers") or []) if str(item)),
}
for key, value in assignments.items():
    print(f"{key}={shlex.quote(str(value))}")
PY
}

phase2_provider_policy_resolve_prephase2() {
    local slug="$1"
    local ir_file="$2"
    local threat_context_file="$3"
    local adaptive_profile="$4"
    local signal_score="$5"
    local output_path="$6"
    python3 "$PROVIDER_STRATEGY_BIN" prephase2 \
        --slug "$slug" \
        --reports-dir "$REPORTS_DIR" \
        --ir "$ir_file" \
        --threat-context "$threat_context_file" \
        --adaptive-profile "$adaptive_profile" \
        --signal-score "$signal_score" \
        --output "$output_path" >/dev/null
}

phase2_provider_policy_write_fallback() {
    local slug="$1"
    local adaptive_profile="$2"
    local signal_score="$3"
    local output_path="$4"
    local worker_provider="$5"
    local reviewer_core_provider="$6"
    local reviewer_explore_provider="$7"
    local cluster_synth_provider="$8"
    local cluster_challenger_provider="$9"
    python3 "$PROVIDER_STRATEGY_BIN" fallback \
        --slug "$slug" \
        --output "$output_path" \
        --worker-provider "$worker_provider" \
        --reviewer-core-provider "$reviewer_core_provider" \
        --reviewer-explore-provider "$reviewer_explore_provider" \
        --cluster-synth-provider "$cluster_synth_provider" \
        --cluster-challenger-provider "$cluster_challenger_provider" \
        --phase3-primary "${PRIMARY_PROVIDER:-codex}" \
        --phase3-providers "${LLM_PROVIDERS:-codex}" \
        --adaptive-profile "$adaptive_profile" \
        --signal-score "$signal_score" \
        --reasons "resolver_failed" \
        --label "resolver_failed_baseline" >/dev/null
}

phase2_provider_policy_apply_postreview() {
    local policy_path="$1"
    local worker_output="$2"
    local review_output="$3"
    python3 "$PROVIDER_STRATEGY_BIN" postreview \
        --policy "$policy_path" \
        --worker-output "$worker_output" \
        --review-output "$review_output" \
        --output "$policy_path" >/dev/null
}

phase2_dispatch_apply_provider_overrides() {
    local dispatch_path="$1"
    local synth_provider="$2"
    local synth_model="$3"
    local challenger_provider="$4"
    local challenger_model="$5"
    [ -f "$dispatch_path" ] || return 0
    python3 - "$dispatch_path" "$synth_provider" "$synth_model" "$challenger_provider" "$challenger_model" <<'PY'
import json
import sys
from pathlib import Path

dispatch_path = Path(sys.argv[1])
doc = json.loads(dispatch_path.read_text(encoding="utf-8"))
doc["cluster_synth_provider"] = sys.argv[2]
doc["cluster_synth_model"] = sys.argv[3]
doc["cluster_challenger_provider"] = sys.argv[4]
doc["cluster_challenger_model"] = sys.argv[5]
dispatch_path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
}

phase2_dispatch_assert_runtime_contract() {
    local dispatch_path="$1"
    local expected_worker_provider="$2"
    local expected_reviewer_provider="$3"
    local expected_primary_provider="$4"
    [ -f "$dispatch_path" ] || return 1
    python3 - "$dispatch_path" "$expected_worker_provider" "$expected_reviewer_provider" "$expected_primary_provider" <<'PY'
import json
import sys
from pathlib import Path

dispatch_path = Path(sys.argv[1])
expected_worker = sys.argv[2]
expected_reviewer = sys.argv[3]
expected_primary = sys.argv[4]

doc = json.loads(dispatch_path.read_text(encoding="utf-8"))
provider_map = doc.get("provider_map") or {}
agents = doc.get("agents") or []
default_provider = doc.get("default_provider") or ""
reviewer_provider = doc.get("reviewer_provider") or ""

worker_agents = [agent for agent in agents if str(agent).startswith("agent-w")]
mismatches = []
for agent in worker_agents:
    actual = provider_map.get(agent, default_provider or "codex")
    if actual != expected_worker:
        mismatches.append(f"{agent}={actual}")

if expected_reviewer and reviewer_provider != expected_reviewer:
    print(
        f"dispatch reviewer_provider mismatch: expected {expected_reviewer!r}, got {reviewer_provider!r}",
        file=sys.stderr,
    )
    raise SystemExit(1)

if expected_primary and default_provider != expected_primary:
    print(
        f"dispatch default_provider mismatch: expected {expected_primary!r}, got {default_provider!r}",
        file=sys.stderr,
    )
    raise SystemExit(1)

if mismatches:
    print(
        f"dispatch worker provider mismatch: expected {expected_worker!r}, got {', '.join(mismatches[:8])}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

phase2_output_trust_state() {
    local phase2_file="$1"
    python3 "$ARTIFACT_FRESHNESS_BIN" phase2-trust-state --path "$phase2_file" 2>/dev/null || true
}

phase2_output_is_trusted() {
    local phase2_file="$1"
    python3 "$ARTIFACT_FRESHNESS_BIN" phase2-is-trusted --path "$phase2_file" >/dev/null 2>&1
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
    threat_context_rel_for_slug "$1"
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

phase2_dispatch_path() {
    phase2_dispatch_path_for_slug "$1"
}

phase2_candidate_inventory_path() {
    phase2_candidate_inventory_path_for_slug "$1"
}

phase2_cluster_plan_path() {
    printf '%s/%s-cluster-plan.json' "$PHASE2_DIR" "$1"
}

phase2_cluster_errlog_path() {
    logs_phase2_cluster_run_err_path "$1"
}

phase2_cluster_live_log_path() {
    logs_phase2_cluster_run_live_path "$1"
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
    if [ "$role" = "worker" ]; then
        logs_phase2_worker_err_path "$slug" "$provider" "$round" "$label"
    else
        logs_phase2_reviewer_err_path "$slug" "$provider" "$round" "$label"
    fi
}

annotate_phase2_review_output_runtime() {
    local review_output_path="$1"
    local provider="$2"
    local model="$3"
    local review_mode="$4"
    local round="$5"
    local provider_tier="${6:-}"
    python3 - "$review_output_path" "$provider" "$model" "$review_mode" "$round" "$provider_tier" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
runtime = data.get("phase2_runtime") if isinstance(data.get("phase2_runtime"), dict) else {}
runtime.update(
    {
        "reviewer_provider": sys.argv[2],
        "reviewer_model": sys.argv[3] or None,
        "review_mode": sys.argv[4],
        "round": int(sys.argv[5]),
        "provider_strategy_tier": sys.argv[6] or None,
    }
)
data["phase2_runtime"] = runtime
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

phase2_loop_live_log_path() {
    printf '%s\n' "$(live_log_path_from_errlog "$(phase2_loop_errlog_path "$@")")"
}

phase2_errlog_path() {
    logs_phase2_run_err_path "$1" "$3"
}

phase2_live_log_path() {
    logs_phase2_run_live_path "$1" "$3"
}

phase2_state_path() {
    phase2_state_path_for_slug "$1"
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

phase2_existing_chunked_output_count() {
    local slug="$1"
    local agents_dir
    agents_dir="$(phase2_agents_dir_path_for_slug "$slug")"
    python3 - "$agents_dir" <<'PY'
import sys
from pathlib import Path

agents_dir = Path(sys.argv[1])
count = 0
if agents_dir.exists():
    count = sum(1 for path in agents_dir.glob("agent-w*.output.json") if path.is_file())
print(count)
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

render_phase2_terminal_review_prompt() {
    python3 - "$TERMINAL_REVIEW_PROMPT_TEMPLATE" "$1" "$2" "$3" "$4" <<'PY'
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
    local source_review_path="${8:-}"
    local threat_context_path="${ROOT_DIR}/$(phase2_threat_context_rel "$slug")"

    mkdir -p "$(dirname "$errlog")"
    : >> "$errlog"

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
    if [ -n "$source_review_path" ]; then
        cmd+=(--source-review "$source_review_path")
    fi
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

    mkdir -p "$(dirname "$errlog")"
    : >> "$errlog"

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

phase2_review_batch_total() {
    local batch_plan_path="$1"
    python3 - "$batch_plan_path" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
print(len(data.get("batches") or []))
PY
}

merge_phase2_reviewer_batches() {
    local batch_plan_path="$1"
    local review_output_path="$2"
    local errlog="$3"

    mkdir -p "$(dirname "$errlog")"
    : >> "$errlog"

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
    local worker_output_path="${4:-}"
    local schema_path
    schema_path="$(phase2_review_schema_for_mode "$review_mode")"
    python3 - "$review_output" "$schema_path" "$review_mode" "$worker_output_path" >>"$errlog" 2>&1 <<'PY'
import json
import sys
from pathlib import Path

review_path = Path(sys.argv[1])
schema_path = Path(sys.argv[2])
review_mode = sys.argv[3]
worker_output_path = Path(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else None
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

allowed_statuses = {"stable", "needs_revision"}
if normalized_mode == "terminal_core":
    allowed_statuses = {"stable"}
if data.get("review_status") not in allowed_statuses:
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

if normalized_mode in {"core", "terminal_core"}:
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
    elif normalized_mode in {"core", "terminal_core"} and summary.get("new_candidate_count") not in (None, 0):
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

if normalized_mode == "terminal_core":
    if worker_output_path is None or not worker_output_path.exists():
        print("[ERROR] terminal_core validation requires an existing worker output artifact")
        raise SystemExit(1)
    worker_doc = json.loads(worker_output_path.read_text(encoding="utf-8"))
    worker_findings = {
        str(item.get("finding_id")): item
        for item in (worker_doc.get("findings") or [])
        if item.get("finding_id")
    }
    current_review_ids = {
        finding_id
        for finding_id, item in worker_findings.items()
        if str(item.get("verdict") or "").upper() == "REVIEW"
    }
    if not current_review_ids:
        print("[ERROR] terminal_core validation requires at least one current REVIEW finding in the worker artifact")
        raise SystemExit(1)
    reviewed_ids = set()
    for item in finding_reviews:
        finding_id = str(item.get("parent_finding_id") or item.get("finding_id") or item.get("packet_id") or "")
        closure_verdict = item.get("closure_verdict")
        assessment = str(item.get("assessment") or "").strip().lower()
        if closure_verdict not in {"TP", "FP"}:
            print(f"[ERROR] terminal_core finding {finding_id or '<unknown>'} missing valid closure_verdict")
            raise SystemExit(1)
        if assessment == "needs_more_evidence":
            print(f"[ERROR] terminal_core finding {finding_id or '<unknown>'} must not use needs_more_evidence")
            raise SystemExit(1)
        if closure_verdict == "TP" and assessment not in {"keep", "field_fix"}:
            print(f"[ERROR] terminal_core finding {finding_id or '<unknown>'} uses incompatible TP closure assessment {assessment!r}")
            raise SystemExit(1)
        if closure_verdict == "FP" and assessment == "keep":
            print(f"[ERROR] terminal_core finding {finding_id or '<unknown>'} must not combine closure_verdict=FP with assessment=keep")
            raise SystemExit(1)
        worker_finding = worker_findings.get(finding_id)
        if worker_finding is None:
            print(f"[ERROR] terminal_core finding {finding_id or '<unknown>'} is not present in the current worker artifact")
            raise SystemExit(1)
        if finding_id in reviewed_ids:
            print(f"[ERROR] terminal_core finding {finding_id or '<unknown>'} appears multiple times")
            raise SystemExit(1)
        reviewed_ids.add(finding_id)
        if str(worker_finding.get("verdict") or "").upper() != "REVIEW":
            print(f"[ERROR] terminal_core finding {finding_id or '<unknown>'} is not a current REVIEW finding")
            raise SystemExit(1)
        if worker_finding and str(worker_finding.get("verdict") or "").upper() == "REVIEW" and assessment == "keep" and closure_verdict != "TP":
            print(f"[ERROR] terminal_core finding {finding_id or '<unknown>'} attempted keep+REVIEW without TP closure")
            raise SystemExit(1)
    missing_review_ids = sorted(current_review_ids - reviewed_ids)
    if missing_review_ids:
        print("[ERROR] terminal_core review did not cover current REVIEW findings: " + ", ".join(missing_review_ids))
        raise SystemExit(1)
PY
}

accept_phase2_review_output_after_failure() {
    local review_output="$1"
    local review_mode="$2"
    local errlog="$3"
    local rc="$4"
    local worker_output_path="${5:-}"

    if [ ! -f "$review_output" ]; then
        return 1
    fi
    if ! validate_phase2_review_output "$review_output" "$review_mode" "$errlog" "$worker_output_path"; then
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

phase2_review_followup_counts() {
    python3 - "$1" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("0|0")
    raise SystemExit(0)

finding_reviews = data.get("finding_reviews") or []
unresolved = 0
field_fix = 0

for item in finding_reviews:
    assessment = str(item.get("assessment") or "").strip().lower()
    if assessment == "field_fix":
        field_fix += 1
    elif assessment and assessment != "keep":
        unresolved += 1

print(f"{unresolved}|{field_fix}")
PY
}

phase2_worker_terminally_closed() {
    local worker_path="$1"
    if [ -z "${worker_path:-}" ] || [ ! -f "$worker_path" ]; then
        return 1
    fi
    python3 - "$worker_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    doc = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)

closure = doc.get("phase2_terminal_closure")
if not isinstance(closure, dict):
    raise SystemExit(1)

needs_review = doc.get("needs_review")
if isinstance(needs_review, int) and needs_review == 0:
    raise SystemExit(0)

for item in (doc.get("findings") or []):
    if str(item.get("verdict") or "").upper() == "REVIEW":
        raise SystemExit(1)

raise SystemExit(0)
PY
}

phase2_review_runtime_meta() {
    python3 - "$1" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
runtime = data.get("phase2_runtime") if isinstance(data.get("phase2_runtime"), dict) else {}
provider = runtime.get("reviewer_provider") or ""
model = runtime.get("reviewer_model") or ""
mode = runtime.get("review_mode") or ""
print(f"{provider}|{model}|{mode}")
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
    local live_log_rel="$9"
    local tp="${10}"
    local fp="${11}"
    local rv="${12}"
    local total="${13}"
    local risk="${14}"
    local delta_json="${15}"

    python3 - "$events_path" "$round" "$worker_mode" "$provider" "$model" "$duration" "$output_rel" "$errlog_rel" "$live_log_rel" "$tp" "$fp" "$rv" "$total" "$risk" "$delta_json" <<'PY'
import json
import sys
from pathlib import Path

events_path = Path(sys.argv[1])
try:
    delta = json.loads(sys.argv[15])
except Exception:
    delta = {"raw_text": sys.argv[15]}
payload = {
    "role": "worker",
    "round": int(sys.argv[2]),
    "mode": sys.argv[3],
    "provider": sys.argv[4],
    "model": sys.argv[5] or None,
    "duration_seconds": int(sys.argv[6]),
    "output_path": sys.argv[7],
    "errlog_path": sys.argv[8],
    "live_log_path": sys.argv[9] or None,
    "counts": {
        "tp": int(sys.argv[10]),
        "fp": int(sys.argv[11]),
        "review": int(sys.argv[12]),
        "total": int(sys.argv[13]),
        "risk": sys.argv[14],
    },
    "delta_from_previous_worker": delta,
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
    local live_log_rel="$9"
    local review_status="${10}"
    local finding_reviews_count="${11}"
    local missed_findings_count="${12}"
    local material_flag="${13}"

    python3 - "$events_path" "$round" "$review_mode" "$provider" "$model" "$duration" "$output_rel" "$errlog_rel" "$live_log_rel" "$review_status" "$finding_reviews_count" "$missed_findings_count" "$material_flag" <<'PY'
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
    "live_log_path": sys.argv[9] or None,
    "review_status": sys.argv[10],
    "finding_reviews_count": int(sys.argv[11]),
    "missed_findings_count": int(sys.argv[12]),
    "material_feedback": sys.argv[13] == "1",
}
with events_path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(payload, separators=(",", ":")) + "\n")
PY
}

write_phase2_state() {
    local state_path="$1"
    local slug="$2"
    local stage="$3"
    local status="$4"
    local role="$5"
    local round="$6"
    local provider="$7"
    local model="$8"
    local output_path="$9"
    local errlog_path="${10}"
    local live_log_path="${11}"
    shift 11

    python3 - "$state_path" "$slug" "$stage" "$status" "$role" "$round" "$provider" "$model" "$output_path" "$errlog_path" "$live_log_path" "$@" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

def _coerce_value(key: str, raw: str):
    lowered = raw.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if raw in {"", "null", "None"}:
        return None
    if key in {"degradation_signals", "notes"}:
        return [item for item in raw.split(",") if item]
    try:
        return int(raw)
    except Exception:
        pass
    try:
        if any(ch in raw for ch in (".", "e", "E")):
            return float(raw)
    except Exception:
        pass
    return raw

detail_args = sys.argv[12:]
details = {}
details_parse_error = None
if detail_args:
    if len(detail_args) % 2 != 0:
        details_parse_error = f"unpaired_detail_arguments:{detail_args!r}"
        details["raw_args"] = detail_args
    else:
        try:
            for idx in range(0, len(detail_args), 2):
                key = detail_args[idx]
                value = detail_args[idx + 1]
                details[key] = _coerce_value(key, value)
        except Exception:
            details_parse_error = "detail_coercion_failed"
            details["raw_args"] = detail_args

payload = {
    "plugin_slug": sys.argv[2],
    "stage": sys.argv[3],
    "status": sys.argv[4],
    "role": sys.argv[5] or None,
    "round": int(sys.argv[6]) if sys.argv[6] and sys.argv[6] != "0" else None,
    "provider": sys.argv[7] or None,
    "model": sys.argv[8] or None,
    "output_path": sys.argv[9] or None,
    "errlog_path": sys.argv[10] or None,
    "live_log_path": sys.argv[11] or None,
    "updated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "details": details,
}
trust_state = details.get("trust_state")
if trust_state is None:
    status = payload["status"]
    if status == "failed":
        trust_state = "failed"
    elif status == "partial":
        trust_state = "partial_success"
    elif status in {"running", "completed"}:
        trust_state = "in_progress"
    elif status == "success":
        trust_state = "success"
    else:
        trust_state = None
if trust_state is not None:
    payload["trust_state"] = trust_state
if isinstance(details.get("degradation_signals"), list):
    payload["degradation_signals"] = details["degradation_signals"]
if details_parse_error:
    payload["details_parse_error"] = details_parse_error

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

errlog_path = payload.get("errlog_path")
if details_parse_error and errlog_path:
    errlog = Path(errlog_path)
    errlog.parent.mkdir(parents=True, exist_ok=True)
    with errlog.open("a", encoding="utf-8") as handle:
        handle.write(
            f"[WARN] phase2 state detail parsing failed: {details_parse_error}; raw_args={detail_args[:20]}\n"
        )
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
    local adaptive_depth_profile="${PHASE2_ADAPTIVE_DEPTH_PROFILE:-}"
    local adaptive_signal_score="${PHASE2_ADAPTIVE_SIGNAL_SCORE:-0}"
    local adaptive_depth_reasons="${PHASE2_ADAPTIVE_DEPTH_REASONS:-}"
    local worker_execution_strategy="${PHASE2_ACTIVE_WORKER_STRATEGY:-monolithic}"
    local effective_revision_timeout="${PHASE2_REVISION_TIMEOUT_SECONDS:-}"
    local effective_reviewer_timeout="${PHASE2_REVIEWER_TIMEOUT_SECONDS:-}"
    local effective_exploration_timeout="${PHASE2_EXPLORATION_TIMEOUT_SECONDS:-}"
    local reviewer_core_provider="$reviewer_provider"
    local reviewer_core_model="$reviewer_model"
    local reviewer_explore_provider="${PHASE2_EXPLORE_PROVIDER:-$reviewer_core_provider}"
    local reviewer_explore_model
    reviewer_explore_model="$(phase2_stage_model reviewer_explore "$reviewer_explore_provider")"
    local provider_policy_tier="${PHASE2_PROVIDER_POLICY_TIER:-}"
    local provider_policy_label="${PHASE2_PROVIDER_POLICY_LABEL:-}"
    local provider_policy_reasons="${PHASE2_PROVIDER_POLICY_REASONS:-}"

    python3 - "$summary_path" "$events_path" "$slug" "$initial_mode" "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" "$max_review_rounds" "$completed_worker_rounds" "$completed_review_rounds" "$final_review_status" "$stop_reason" "$execution_status" "$runtime_seconds" "$canonical_output_rel" "$final_worker_rel" "$final_review_rel" "$final_tp" "$final_fp" "$final_rv" "$final_total" "$final_risk" "$forced_exploration_enabled" "$max_exploration_candidates" "$adaptive_depth_profile" "$adaptive_signal_score" "$adaptive_depth_reasons" "$worker_execution_strategy" "$effective_revision_timeout" "$effective_reviewer_timeout" "$effective_exploration_timeout" "$reviewer_core_provider" "$reviewer_core_model" "$reviewer_explore_provider" "$reviewer_explore_model" "$provider_policy_tier" "$provider_policy_label" "$provider_policy_reasons" <<'PY'
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
        try:
            rounds.append(json.loads(raw))
        except Exception:
            rounds.append({
                "role": "telemetry_error",
                "raw_text": raw,
            })

def maybe_int(value):
    if value in {"", "null", "None"}:
        return None
    return int(value)

def derive_trust_state(execution_status: str, artifact_rel: str, summary_path: Path):
    root = summary_path.parent.parent.parent
    signals: list[str] = []
    trust_state = None
    closure_complete = None
    artifact_rel = artifact_rel or ""
    artifact_path = (root / artifact_rel).resolve() if artifact_rel else None
    if artifact_path and artifact_path.exists():
        try:
            artifact = json.loads(artifact_path.read_text(encoding="utf-8"))
        except Exception:
            signals.append("artifact_unreadable")
        else:
            existing = artifact.get("trust_state")
            if isinstance(existing, str) and existing:
                trust_state = existing
            for container in (artifact, artifact.get("consensus"), artifact.get("merge_stats")):
                if not isinstance(container, dict):
                    continue
                value = container.get("closure_complete")
                if isinstance(value, bool):
                    closure_complete = value
                    break
            if closure_complete is None:
                needs_review = artifact.get("needs_review")
                if isinstance(needs_review, int):
                    closure_complete = needs_review == 0
                elif isinstance(artifact.get("findings"), list):
                    closure_complete = True
                    for finding in artifact["findings"]:
                        if isinstance(finding, dict) and str(finding.get("verdict") or "").upper() == "REVIEW":
                            closure_complete = False
                            break
            for container_key in ("degradation_signals",):
                values = artifact.get(container_key)
                if isinstance(values, list):
                    signals.extend(str(item) for item in values if str(item))
            merge_stats = artifact.get("merge_stats")
            if isinstance(merge_stats, dict):
                values = merge_stats.get("degradation_signals")
                if isinstance(values, list):
                    signals.extend(str(item) for item in values if str(item))
            consensus = artifact.get("consensus")
            if isinstance(consensus, dict):
                values = consensus.get("degradation_signals")
                if isinstance(values, list):
                    signals.extend(str(item) for item in values if str(item))
    if closure_complete is False and "closure_incomplete" not in signals:
        signals.append("closure_incomplete")
    signals = sorted(set(signals))
    if execution_status == "failed":
        trust_state = "failed"
    elif execution_status == "partial":
        trust_state = "partial_success"
    elif trust_state is None:
        trust_state = "degraded_success" if signals else "success"
    return trust_state, signals

payload = {
    "plugin_slug": sys.argv[3],
    "execution_status": sys.argv[14],
    "initial_mode": sys.argv[4],
    "worker_provider": sys.argv[5],
    "reviewer_provider": sys.argv[6],
    "worker_model": sys.argv[7] or None,
    "reviewer_model": sys.argv[8] or None,
    "reviewer_core_provider": sys.argv[33],
    "reviewer_core_model": sys.argv[34] or None,
    "reviewer_explore_provider": sys.argv[35],
    "reviewer_explore_model": sys.argv[36] or None,
    "max_review_rounds": int(sys.argv[9]),
    "forced_exploration_enabled": sys.argv[24].lower() == "true",
    "max_exploration_candidates": int(sys.argv[25]),
    "adaptive_depth_policy": {
        "profile": sys.argv[26] or None,
        "signal_score": int(sys.argv[27]),
        "reasons": [item for item in sys.argv[28].split(",") if item],
        "worker_execution_strategy": sys.argv[29] or None,
        "effective_timeouts": {
            "revision_seconds": int(sys.argv[30]) if sys.argv[30] else None,
            "reviewer_seconds": int(sys.argv[31]) if sys.argv[31] else None,
            "exploration_seconds": int(sys.argv[32]) if sys.argv[32] else None,
        },
    },
    "provider_strategy": {
        "tier": sys.argv[37] or None,
        "label": sys.argv[38] or None,
        "reasons": [item for item in sys.argv[39].split(",") if item],
    },
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
trust_state, degradation_signals = derive_trust_state(sys.argv[14], sys.argv[16], summary_path)
payload["trust_state"] = trust_state
payload["degradation_signals"] = degradation_signals
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
    local component="${8:-}"
    local role="${9:-}"
    local agent_id="${10:-}"
    local cluster_id="${11:-}"
    local attempt="${12:-}"
    local timeout_seconds="${13:-}"
    local quota_signal="${14:-}"
    local input_path="${15:-}"
    local output_path="${16:-}"
    local errlog_path="${17:-}"
    local live_log_path="${18:-}"
    local raw_log_path="${19:-}"
    python3 "$COST_TELEMETRY_BIN" append-event \
        --ledger "$QUOTA_LEDGER" \
        --phase "$phase" \
        --slug "$slug" \
        --run-id "${AUDIT_RUN_ID:-}" \
        --mode "$mode" \
        --provider "$provider" \
        --model "$model" \
        --status "$status" \
        --duration "$duration" \
        --component "$component" \
        --role "$role" \
        --agent-id "$agent_id" \
        --cluster-id "$cluster_id" \
        --attempt "$attempt" \
        --timeout-seconds "$timeout_seconds" \
        --quota-signal "$quota_signal" \
        --input-path "$input_path" \
        --output-path "$output_path" \
        --errlog-path "$errlog_path" \
        --live-log-path "$live_log_path" \
        --raw-log-path "$raw_log_path" >/dev/null
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
    ("hit your limit", "provider_usage_limit"),
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

# --- Reviewer batch concurrency (bash 3.2: no `wait -n`, no associative arrays) ---
PHASE2_REVIEWER_BATCH_PIDS=""
PHASE2_REVIEWER_RUNNING_COUNT=0

phase2_reviewer_prune_pids() {
    local pid alive=0 remaining=""
    for pid in $PHASE2_REVIEWER_BATCH_PIDS; do
        [ -n "$pid" ] || continue
        if kill -0 "$pid" 2>/dev/null; then
            alive=$((alive + 1))
            remaining="${remaining} ${pid}"
        fi
    done
    PHASE2_REVIEWER_BATCH_PIDS="$remaining"
    PHASE2_REVIEWER_RUNNING_COUNT="$alive"
}

phase2_reviewer_throttle() {
    local limit="$1"
    phase2_reviewer_prune_pids
    while [ "$PHASE2_REVIEWER_RUNNING_COUNT" -ge "$limit" ]; do
        sleep 2
        phase2_reviewer_prune_pids
    done
}

phase2_reviewer_parallel_limit() {
    local limit="${PHASE2_REVIEWER_BATCH_PARALLEL_LIMIT:-${PHASE2_WORKER_CHUNK_PARALLEL_LIMIT:-4}}"
    case "$limit" in
        ''|*[!0-9]*) limit=4 ;;
    esac
    [ "$limit" -lt 1 ] && limit=1
    printf '%s' "$limit"
}

# Runs one reviewer batch to completion (including retries) and records the outcome in a
# status file, because a background subshell cannot hand state back to the caller.
# Status format: <ok|fail>|<duration_seconds>|<reason>
phase2_run_reviewer_batch() {
    local slug="$1" round="$2" review_mode="$3" provider="$4" system_prompt="$5" batch_prompt="$6"
    local batch_errlog="$7" model="$8" timeout_seconds="$9" batch_output_path="${10}"
    local worker_output_path="${11}" batch_id="${12}" status_file="${13}"
    local retry_count=0 duration=0 rc=0 reason=""
    local retry_limit="${PHASE2_REVIEWER_BATCH_RETRY_LIMIT:-3}"

    while true; do
        rm -f "$batch_output_path"
        rc=0
        run_llm_prompt "$slug" "review-r${round}-${review_mode}-${batch_id}" "$provider" \
            "$system_prompt" "$batch_prompt" "$batch_errlog" "$model" "$timeout_seconds" || rc=$?
        duration=$((duration + ${PHASE2_LAST_DURATION_SECONDS:-0}))

        if [ "$rc" -eq 0 ]; then
            # A successful provider call can still emit a schema-invalid batch (e.g. a complete
            # review that omits review_status). Re-prompt instead of losing the whole round.
            if validate_phase2_review_output "$batch_output_path" "$review_mode" "$batch_errlog" "$worker_output_path"; then
                printf 'ok|%s|\n' "$duration" > "$status_file"
                return 0
            fi
            if [ "$retry_count" -lt "$retry_limit" ]; then
                retry_count=$((retry_count + 1))
                printf '[WARN] reviewer %s batch %s schema_invalid; retry %s/%s\n' \
                    "$review_mode" "$batch_id" "$retry_count" "$retry_limit" >> "$batch_errlog"
                phase2_sleep_if_positive "${PHASE2_REVIEWER_BATCH_RETRY_BACKOFF_SECONDS:-3}"
                continue
            fi
            printf 'fail|%s|schema_invalid_after_%s_retries\n' "$duration" "$retry_limit" > "$status_file"
            return 1
        fi

        if accept_phase2_review_output_after_failure "$batch_output_path" "$review_mode" "$batch_errlog" "$rc" "$worker_output_path"; then
            printf 'ok|%s|\n' "$duration" > "$status_file"
            return 0
        fi
        reason="$(summarize_provider_errlog "$batch_errlog")"
        if phase2_reviewer_batch_retryable_failure "$provider" "$batch_errlog" && [ "$retry_count" -lt "$retry_limit" ]; then
            retry_count=$((retry_count + 1))
            printf '[WARN] reviewer %s batch %s %s; retry %s/%s\n' \
                "$review_mode" "$batch_id" "$reason" "$retry_count" "$retry_limit" >> "$batch_errlog"
            phase2_sleep_if_positive "${PHASE2_REVIEWER_BATCH_RETRY_BACKOFF_SECONDS:-3}"
            continue
        fi
        printf 'fail|%s|%s\n' "$duration" "$reason" > "$status_file"
        if [ "$reason" = "provider_usage_limit" ]; then
            : > "${PHASE2_QUOTA_SENTINEL:-/dev/null}"
        fi
        return 1
    done
}

phase2_reviewer_batch_retryable_failure() {
    local provider="$1"
    local errlog="$2"
    local failure_reason
    failure_reason="$(summarize_provider_errlog "$errlog")"
    # Transient provider conditions, not provider-specific. This used to be gated on
    # provider=codex, which meant an all-Claude topology never retried a single batch.
    case "$failure_reason" in
        provider_usage_limit|provider_rate_limit|provider_timeout)
            return 0
            ;;
    esac
    return 1
}

phase2_sleep_if_positive() {
    local seconds="${1:-0}"
    if [ "${seconds:-0}" -gt 0 ] 2>/dev/null; then
        sleep "$seconds"
    fi
}

phase2_pipeline_progress_enabled() {
    [ "${PIPELINE_PROGRESS_MODE:-off}" != "off" ] && [ "${PIPELINE_PROGRESS_PHASE2_WEIGHT:-0}" -gt 0 ] 2>/dev/null
}

phase2_pipeline_overall_percent() {
    local phase_percent="${1:-0}"
    local phase1_weight="${PIPELINE_PROGRESS_PHASE1_WEIGHT:-0}"
    local phase2_weight="${PIPELINE_PROGRESS_PHASE2_WEIGHT:-0}"
    local overall=$(( phase1_weight + (phase2_weight * phase_percent) / 100 ))
    if [ "$overall" -gt 100 ]; then
        overall=100
    fi
    printf '%s' "$overall"
}

phase2_progress_format_seconds() {
    local seconds="${1:-0}"
    local hours minutes
    if [ "$seconds" -lt 60 ] 2>/dev/null; then
        printf '%ss' "$seconds"
        return 0
    fi
    if [ "$seconds" -lt 3600 ] 2>/dev/null; then
        minutes=$((seconds / 60))
        printf '%sm' "$minutes"
        return 0
    fi
    hours=$((seconds / 3600))
    minutes=$(((seconds % 3600) / 60))
    if [ "$minutes" -gt 0 ] 2>/dev/null; then
        printf '%sh%sm' "$hours" "$minutes"
    else
        printf '%sh' "$hours"
    fi
}

phase2_progress_eta_suffix() {
    local overall="${1:-0}"
    local now elapsed estimated_total remaining

    phase2_pipeline_progress_enabled || return 0
    [ -n "${PIPELINE_PROGRESS_START_TS:-}" ] || return 0
    if [ "$overall" -le 0 ] 2>/dev/null; then
        return 0
    fi
    if [ "$overall" -ge 100 ] 2>/dev/null; then
        printf ' | ETA 0s'
        return 0
    fi

    now="$(date +%s)"
    elapsed=$((now - PIPELINE_PROGRESS_START_TS))
    if [ "$elapsed" -lt 1 ] 2>/dev/null; then
        elapsed=1
    fi
    estimated_total=$(( (elapsed * 100 + overall - 1) / overall ))
    remaining=$((estimated_total - elapsed))
    if [ "$remaining" -lt 0 ] 2>/dev/null; then
        remaining=0
    fi
    printf ' | ETA ~%s' "$(phase2_progress_format_seconds "$remaining")"
}

phase2_progress_suffix() {
    local phase_percent="${1:-0}"
    local overall
    phase2_pipeline_progress_enabled || return 0
    overall="$(phase2_pipeline_overall_percent "$phase_percent")"
    printf ' | Phase 2 ~%s%% | Pipeline ~%s%%%s' "$phase_percent" "$overall" "$(phase2_progress_eta_suffix "$overall")"
}

phase2_progress_for_review_batch() {
    local review_mode="$1"
    local batch_index="${2:-1}"
    local batch_total="${3:-1}"
    local start=40
    local end=70
    local span progress_index

    case "$review_mode" in
        terminal_core)
            start=84
            end=89
            ;;
        explore|forced_exploration)
            start=92
            end=96
            ;;
        *)
            start=40
            end=70
            ;;
    esac

    if [ "$batch_total" -le 1 ] 2>/dev/null; then
        printf '%s' "$start"
        return 0
    fi

    span=$((end - start))
    progress_index=$((batch_index - 1))
    if [ "$progress_index" -lt 0 ] 2>/dev/null; then
        progress_index=0
    fi
    printf '%s' $(( start + (span * progress_index) / batch_total ))
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

promote_int_if_auto() {
    local current="$1"
    local target="$2"
    local explicit="$3"

    if [ "$explicit" = true ]; then
        printf '%s' "$current"
        return 0
    fi
    if [ "$target" -gt "$current" ]; then
        printf '%s' "$target"
    else
        printf '%s' "$current"
    fi
}

promote_bool_if_auto() {
    local current="$1"
    local target="$2"
    local explicit="$3"

    if [ "$explicit" = true ]; then
        printf '%s' "$current"
        return 0
    fi
    if [ "$target" = "true" ]; then
        printf 'true'
    else
        printf '%s' "$current"
    fi
}

phase2_adaptive_depth_policy() {
    local mode="$1"
    local ep_count="$2"
    local anom_count="$3"
    local unauth_ep="$4"
    local sensitive_sinks="$5"
    local sql_sinks="$6"
    local rest_json_sources="$7"
    local output_sinks="$8"
    local source_count="$9"
    local sink_count="${10}"
    local coverage_gaps_count="${11}"
    local current_max_review_rounds="${12}"
    local current_forced_exploration="${13}"
    local current_max_exploration_candidates="${14}"
    local current_revision_timeout="${15}"
    local current_reviewer_timeout="${16}"
    local current_exploration_timeout="${17}"
    local review_rounds_explicit="${18}"
    local forced_exploration_explicit="${19}"
    local exploration_candidates_explicit="${20}"
    local revision_timeout_explicit="${21}"
    local reviewer_timeout_explicit="${22}"
    local exploration_timeout_explicit="${23}"

    local signal_score=0
    local profile="deep-standard"
    local target_max_review_rounds="$current_max_review_rounds"
    local target_forced_exploration="$current_forced_exploration"
    local target_max_exploration_candidates="$current_max_exploration_candidates"
    local target_revision_timeout="$current_revision_timeout"
    local target_reviewer_timeout="$current_reviewer_timeout"
    local target_exploration_timeout="$current_exploration_timeout"
    local effective_max_review_rounds effective_forced_exploration effective_max_exploration_candidates
    local effective_revision_timeout effective_reviewer_timeout effective_exploration_timeout
    local -a reasons=()
    local reasons_csv

    signal_score=$(( signal_score + (unauth_ep * 4) ))
    signal_score=$(( signal_score + (sensitive_sinks * 2) ))
    signal_score=$(( signal_score + (sql_sinks * 3) ))
    signal_score=$(( signal_score + (rest_json_sources * 2) ))
    signal_score=$(( signal_score + (coverage_gaps_count * 3) ))
    if [ "$ep_count" -ge 5 ]; then
        signal_score=$((signal_score + 2))
    elif [ "$ep_count" -ge 2 ]; then
        signal_score=$((signal_score + 1))
    fi
    if [ "$anom_count" -ge 8 ]; then
        signal_score=$((signal_score + 2))
    elif [ "$anom_count" -ge 4 ]; then
        signal_score=$((signal_score + 1))
    fi
    if [ "$source_count" -ge 15 ]; then
        signal_score=$((signal_score + 1))
    fi
    if [ "$sink_count" -ge 15 ]; then
        signal_score=$((signal_score + 1))
    fi
    if [ "$output_sinks" -ge 8 ]; then
        signal_score=$((signal_score + 1))
    fi

    if [ "$unauth_ep" -gt 0 ]; then
        reasons+=("unauth_entry_points=${unauth_ep}")
    fi
    if [ "$sensitive_sinks" -gt 0 ]; then
        reasons+=("sensitive_sinks=${sensitive_sinks}")
    fi
    if [ "$sql_sinks" -gt 0 ]; then
        reasons+=("sql_sinks=${sql_sinks}")
    fi
    if [ "$rest_json_sources" -gt 0 ]; then
        reasons+=("rest_json_sources=${rest_json_sources}")
    fi
    if [ "$coverage_gaps_count" -gt 0 ]; then
        reasons+=("coverage_gaps=${coverage_gaps_count}")
    fi
    if [ "$anom_count" -gt 0 ]; then
        reasons+=("anomalies=${anom_count}")
    fi
    if [ "$ep_count" -gt 0 ]; then
        reasons+=("entry_points=${ep_count}")
    fi

    if [ "$mode" = "quick" ]; then
        profile="quick-triage"
        if [ ${#reasons[@]} -eq 0 ]; then
            reasons+=("low_signal_surface")
        fi
    elif [ "$coverage_gaps_count" -ge 4 ] \
        || [ "$unauth_ep" -ge 3 ] \
        || [ "$sql_sinks" -ge 2 ] \
        || [ "$sensitive_sinks" -ge 8 ] \
        || [ "$rest_json_sources" -ge 8 ] \
        || [ "$signal_score" -ge 18 ]; then
        profile="deep-extended"
        target_max_review_rounds=2
        target_forced_exploration=true
        target_max_exploration_candidates=5
        target_revision_timeout=720
        target_reviewer_timeout=900
        target_exploration_timeout=360
    elif [ "$coverage_gaps_count" -ge 2 ] \
        || [ "$unauth_ep" -ge 1 ] \
        || [ "$sql_sinks" -ge 1 ] \
        || [ "$sensitive_sinks" -ge 4 ] \
        || [ "$rest_json_sources" -ge 4 ] \
        || [ "$anom_count" -ge 6 ] \
        || [ "$signal_score" -ge 10 ]; then
        profile="deep-elevated"
        target_max_review_rounds=2
        target_forced_exploration=true
        target_max_exploration_candidates=4
        target_revision_timeout=660
        target_reviewer_timeout=720
        target_exploration_timeout=300
    fi

    effective_max_review_rounds="$(promote_int_if_auto "$current_max_review_rounds" "$target_max_review_rounds" "$review_rounds_explicit")"
    effective_forced_exploration="$(promote_bool_if_auto "$current_forced_exploration" "$target_forced_exploration" "$forced_exploration_explicit")"
    effective_max_exploration_candidates="$(promote_int_if_auto "$current_max_exploration_candidates" "$target_max_exploration_candidates" "$exploration_candidates_explicit")"
    effective_revision_timeout="$(promote_int_if_auto "$current_revision_timeout" "$target_revision_timeout" "$revision_timeout_explicit")"
    effective_reviewer_timeout="$(promote_int_if_auto "$current_reviewer_timeout" "$target_reviewer_timeout" "$reviewer_timeout_explicit")"
    effective_exploration_timeout="$(promote_int_if_auto "$current_exploration_timeout" "$target_exploration_timeout" "$exploration_timeout_explicit")"

    reasons_csv=""
    if [ ${#reasons[@]} -gt 0 ]; then
        local old_ifs="$IFS"
        IFS=,
        reasons_csv="${reasons[*]}"
        IFS="$old_ifs"
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s' \
        "$profile" \
        "$effective_max_review_rounds" \
        "$effective_forced_exploration" \
        "$effective_max_exploration_candidates" \
        "$effective_revision_timeout" \
        "$effective_reviewer_timeout" \
        "$effective_exploration_timeout" \
        "$signal_score" \
        "$reasons_csv"
}

phase2_worker_execution_strategy() {
    local mode="$1"
    local profile="$2"
    local signal_score="$3"
    local entry_points="$4"
    local source_count="$5"
    local sink_count="$6"
    local strategy_mode="${PHASE2_WORKER_EXECUTION_MODE:-adaptive}"
    local strategy="monolithic"
    local reason="default_monolithic"

    case "$strategy_mode" in
        monolithic|chunked)
            strategy="$strategy_mode"
            reason="manual_${strategy_mode}_override"
            ;;
        *)
            if [ "$mode" != "deep" ]; then
                strategy="monolithic"
                reason="quick_mode"
            elif [ "$profile" = "deep-extended" ] || [ "$profile" = "deep-elevated" ]; then
                strategy="chunked"
                reason="adaptive_profile_${profile}"
            elif [ "$signal_score" -ge 120 ] || [ "$entry_points" -ge 20 ] || [ "$source_count" -ge 180 ] || [ "$sink_count" -ge 250 ]; then
                strategy="chunked"
                reason="adaptive_signal_threshold"
            else
                strategy="monolithic"
                reason="adaptive_monolithic"
            fi
            ;;
    esac

    printf '%s|%s' "$strategy" "$reason"
}

phase2_effective_chunk_parallel_limit() {
    local dispatch_path="$1"
    local base_limit="${2:-$PHASE2_WORKER_CHUNK_PARALLEL_LIMIT}"
    local agent_count="0"
    if [ -f "$dispatch_path" ]; then
        agent_count="$(python3 - "$dispatch_path" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    print(len(data.get("agents") or []))
except Exception:
    print(0)
PY
)"
    fi

    if [ "$agent_count" -ge 48 ] && [ "$base_limit" -lt 8 ]; then
        printf '%s|%s' "8" "high_bundle_volume"
    elif [ "$agent_count" -ge 24 ] && [ "$base_limit" -lt 6 ]; then
        printf '%s|%s' "6" "medium_bundle_volume"
    else
        printf '%s|%s' "$base_limit" "base_limit"
    fi
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
    local live_log raw_log
    model="${model_override:-$(provider_model "$provider")}"
    bin="$(provider_bin "$provider")"
    timeout_seconds="${8:-$PHASE2_PROVIDER_TIMEOUT_SECONDS}"
    live_log="$(live_log_path_from_errlog "$errlog")"
    raw_log="$(raw_log_path_from_errlog "$errlog")"
    reset_log_file "$errlog"
    reset_log_file "$live_log"
    reset_log_file "$raw_log"
    append_log_marker "$errlog" "phase2 llm start slug=${slug} mode=${mode} provider=${provider} model=${model:-default} timeout_seconds=${timeout_seconds}"
    append_log_marker "$live_log" "phase2 llm start slug=${slug} mode=${mode} provider=${provider} model=${model:-default} timeout_seconds=${timeout_seconds}"
    start_ts="$(date +%s)"
    if [ "$provider" = "codex" ]; then
        (
            cd "$ROOT_DIR"
            local cmd=("$bin" exec --full-auto --sandbox workspace-write --skip-git-repo-check)
            if [ -n "$model" ]; then
                cmd+=(--model "$model")
            fi
            cmd+=("${system_prompt}"$'\n\n'"${prompt}")
            set +e
            if [ "$timeout_seconds" -gt 0 ]; then
                timeout_run "$timeout_seconds" "${cmd[@]}" \
                    > >(tee -a "$live_log" >/dev/null) \
                    2> >(tee -a "$errlog" "$live_log" >/dev/null)
            else
                "${cmd[@]}" \
                    > >(tee -a "$live_log" >/dev/null) \
                    2> >(tee -a "$errlog" "$live_log" >/dev/null)
            fi
            rc=$?
            set -e
            exit "$rc"
        )
        rc=$?
    else
        local system_prompt_file
        system_prompt_file="$(mktemp)"
        printf '%s\n' "$system_prompt" > "$system_prompt_file"
        (
            cd "$ROOT_DIR"
            local cmd=("$bin" -p --disable-slash-commands --permission-mode bypassPermissions --tools "$CLAUDE_SAFE_TOOLS"
                       --verbose
                       --effort "$CLAUDE_EFFORT"
                       --output-format stream-json
                       --include-partial-messages)
            if [ -n "$model" ]; then
                cmd+=(--model "$model")
            fi
            cmd+=(--append-system-prompt-file "$system_prompt_file" "$prompt")
            set +e
            if [ "$timeout_seconds" -gt 0 ]; then
                timeout_run "$timeout_seconds" "${cmd[@]}" \
                    2> >(tee -a "$errlog" "$live_log" >/dev/null) \
                    | tee -a "$raw_log" \
                    | python3 -u "$CLAUDE_STREAM_PARSER" 2> >(tee -a "$errlog" "$live_log" >/dev/null) \
                    | tee -a "$live_log" >/dev/null
                printf '%s' "${PIPESTATUS[0]}" > "${errlog}.pipestatus"
            else
                "${cmd[@]}" \
                    2> >(tee -a "$errlog" "$live_log" >/dev/null) \
                    | tee -a "$raw_log" \
                    | python3 -u "$CLAUDE_STREAM_PARSER" 2> >(tee -a "$errlog" "$live_log" >/dev/null) \
                    | tee -a "$live_log" >/dev/null
                printf '%s' "${PIPESTATUS[0]}" > "${errlog}.pipestatus"
            fi
            set -e
        )
        rc="$(cat "${errlog}.pipestatus" 2>/dev/null || echo 1)"
        rm -f "$system_prompt_file" "${errlog}.pipestatus"
    fi
    if [ "$rc" -eq 124 ]; then
        printf '[ERROR] provider timed out after %ss\n' "$timeout_seconds" >> "$errlog"
        printf '[ERROR] provider timed out after %ss\n' "$timeout_seconds" >> "$live_log"
    fi
    end_ts="$(date +%s)"
    duration=$((end_ts - start_ts))
    PHASE2_LAST_DURATION_SECONDS="$duration"
    status="ok"
    if [ "$rc" -ne 0 ]; then
        status="failed"
    fi
    append_log_marker "$errlog" "phase2 llm end slug=${slug} mode=${mode} provider=${provider} status=${status} rc=${rc} duration_seconds=${duration}"
    append_log_marker "$live_log" "phase2 llm end slug=${slug} mode=${mode} provider=${provider} status=${status} rc=${rc} duration_seconds=${duration}"
    append_quota_log "phase2" "$slug" "$mode" "$provider" "$model" "$status" "$duration" \
        "llm_prompt" "" "" "" "" "$timeout_seconds" "" "" "" "$errlog" "$live_log" "$raw_log"
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
        terminal_core)
            printf '%s' "$PHASE2_REVIEW_TERMINAL_CORE_SCHEMA"
            ;;
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
        terminal_core)
            base_prompt="$SYSTEM_PROMPT_PHASE2_REVIEW_TERMINAL"
            ;;
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

apply_phase2_terminal_closure() {
    local slug="$1"
    local worker_input_path="$2"
    local review_input_path="$3"
    local output_path="$4"
    local raw_path="$5"
    local errlog="$6"

    if [ ! -f "$PHASE2_TERMINAL_CLOSURE_BIN" ]; then
        printf '[ERROR] terminal closure helper missing: %s\n' "$PHASE2_TERMINAL_CLOSURE_BIN" >>"$errlog"
        return 1
    fi

    mkdir -p "$(dirname "$output_path")" "$(dirname "$raw_path")" "$(dirname "$errlog")"
    reset_log_file "$errlog"

    if ! python3 "$PHASE2_TERMINAL_CLOSURE_BIN" \
        --slug "$slug" \
        --worker-input "$worker_input_path" \
        --review-input "$review_input_path" \
        --output "$output_path" >>"$errlog" 2>&1; then
        printf '[ERROR] phase2 terminal closure failed for %s\n' "$output_path" >>"$errlog"
        return 1
    fi
    if [ ! -f "$output_path" ]; then
        printf '[ERROR] terminal closure output missing: %s\n' "$output_path" >>"$errlog"
        return 1
    fi

    cp -f "$output_path" "$raw_path" 2>/dev/null || true
    if [ -f "${BIN_DIR}/phase2_postprocess.py" ]; then
        if ! postprocess_phase2_output "$slug" "$output_path"; then
            printf '[ERROR] phase2_postprocess failed for terminal closure output %s\n' "$output_path" >>"$errlog"
            return 1
        fi
    fi
}

run_phase2_chunked_worker_round() {
    local slug="$1"
    local round="$2"
    local worker_mode="$3"
    local provider="$4"
    local output_path="$5"
    local raw_path="$6"
    local errlog="$7"
    local live_log chunked_errlog chunked_live_log dispatch_path inventory_path local_phase2_path
    local effective_parallel_limit parallel_limit_reason
    local start_ts end_ts duration status
    local chunked_console_stdout_pattern chunked_console_stderr_pattern

    live_log="$(live_log_path_from_errlog "$errlog")"
    chunked_errlog="$(logs_phase2_chunked_run_err_path "$slug")"
    chunked_live_log="$(logs_phase2_chunked_run_live_path "$slug")"
    dispatch_path="$(phase2_dispatch_path "$slug")"
    inventory_path="$(phase2_candidate_inventory_path "$slug")"
    local_phase2_path="$(phase2_local_output_path "$slug")"

    if [ ! -f "$PHASE2_AGENT_INPUT_PREPARER" ]; then
        printf '[ERROR] chunked worker prep script missing: %s\n' "$PHASE2_AGENT_INPUT_PREPARER" >> "$errlog"
        return 1
    fi
    if [ ! -f "$PHASE2_MULTI_WORKER_ORCHESTRATOR" ]; then
        printf '[ERROR] chunked worker orchestrator missing: %s\n' "$PHASE2_MULTI_WORKER_ORCHESTRATOR" >> "$errlog"
        return 1
    fi

    reset_log_file "$errlog"
    reset_log_file "$live_log"
    reset_log_file "$chunked_errlog"
    reset_log_file "$chunked_live_log"
    append_log_marker "$errlog" "chunked worker start slug=${slug} round=${round} mode=${worker_mode} provider=${provider} parallel_limit=${PHASE2_WORKER_CHUNK_PARALLEL_LIMIT}"
    append_log_marker "$live_log" "chunked worker start slug=${slug} round=${round} mode=${worker_mode} provider=${provider} parallel_limit=${PHASE2_WORKER_CHUNK_PARALLEL_LIMIT}"
    append_log_marker "$errlog" "chunked scheduler logs err=${chunked_errlog} live=${chunked_live_log}"
    append_log_marker "$live_log" "chunked scheduler logs err=${chunked_errlog} live=${chunked_live_log}"

    start_ts="$(date +%s)"
    append_log_marker "$chunked_errlog" "chunked prep start slug=${slug}"
    append_log_marker "$chunked_live_log" "chunked prep start slug=${slug}"
    log_info "Chunked prep: building candidate bundles for ${slug} (details: ${chunked_live_log})"
    local chunked_worker_provider chunked_reviewer_provider chunked_primary_provider
    local chunked_cluster_synth_provider chunked_cluster_challenger_provider
    chunked_worker_provider="$provider"
    chunked_reviewer_provider="${reviewer_provider:-$PHASE2_REVIEWER_PROVIDER}"
    chunked_primary_provider="$chunked_worker_provider"
    chunked_cluster_synth_provider="${cluster_synth_provider:-$PHASE2_CLUSTER_SYNTH_PROVIDER}"
    chunked_cluster_challenger_provider="${cluster_challenger_provider:-$PHASE2_CLUSTER_CHALLENGER_PROVIDER}"
    if ! PHASE2_BUNDLE_REVIEW_ENABLED=true \
        PHASE2_SUPPORT_AGENTS_ENABLED=false \
        PHASE2_MAX_REVIEW_ROUNDS="$PHASE2_MAX_REVIEW_ROUNDS" \
        PHASE2_WORKER_PROVIDER="$chunked_worker_provider" \
        PHASE2_REVIEWER_PROVIDER="$chunked_reviewer_provider" \
        PHASE2_PRIMARY_PROVIDER="$chunked_primary_provider" \
        PHASE2_WORKER_CLAUDE_MODEL="$PHASE2_WORKER_CLAUDE_MODEL" \
        PHASE2_WORKER_CODEX_MODEL="$PHASE2_WORKER_CODEX_MODEL" \
        PHASE2_REVIEWER_CLAUDE_MODEL="$PHASE2_REVIEWER_CLAUDE_MODEL" \
        PHASE2_REVIEWER_CODEX_MODEL="$PHASE2_REVIEWER_CODEX_MODEL" \
        PHASE2_CLUSTER_SYNTH_PROVIDER="$chunked_cluster_synth_provider" \
        PHASE2_CLUSTER_SYNTH_CLAUDE_MODEL="$PHASE2_CLUSTER_SYNTH_CLAUDE_MODEL" \
        PHASE2_CLUSTER_SYNTH_CODEX_MODEL="$PHASE2_CLUSTER_SYNTH_CODEX_MODEL" \
        PHASE2_CLUSTER_CHALLENGER_PROVIDER="$chunked_cluster_challenger_provider" \
        PHASE2_CLUSTER_CHALLENGER_CLAUDE_MODEL="$PHASE2_CLUSTER_CHALLENGER_CLAUDE_MODEL" \
        PHASE2_CLUSTER_CHALLENGER_CODEX_MODEL="$PHASE2_CLUSTER_CHALLENGER_CODEX_MODEL" \
        PHASE2_PROVIDER_TIMEOUT_SECONDS="$PHASE2_WORKER_TIMEOUT_SECONDS" \
        CODEX_QUOTA_ACCOUNT="${CODEX_QUOTA_ACCOUNT:-}" \
        run_command_with_file_logs "$chunked_live_log" "$chunked_errlog" \
        python3 "$PHASE2_AGENT_INPUT_PREPARER" "$slug" --output-dir "$REPORTS_DIR"; then
        printf '[ERROR] prepare_agent_inputs.py failed for %s\n' "$slug" >> "$errlog"
        append_log_marker "$live_log" "chunked worker prep failed slug=${slug}"
        return 1
    fi
    append_log_marker "$chunked_errlog" "chunked prep done slug=${slug} dispatch=${dispatch_path} inventory=${inventory_path}"
    append_log_marker "$chunked_live_log" "chunked prep done slug=${slug}"

    if [ ! -f "$dispatch_path" ] || [ ! -f "$inventory_path" ]; then
        printf '[ERROR] chunked worker artifacts missing dispatch=%s inventory=%s\n' "$dispatch_path" "$inventory_path" >> "$errlog"
        append_log_marker "$live_log" "chunked worker artifacts missing"
        return 1
    fi
    if ! phase2_dispatch_assert_runtime_contract "$dispatch_path" "$chunked_worker_provider" "$chunked_reviewer_provider" "$chunked_primary_provider" >>"$chunked_errlog" 2>&1; then
        printf '[ERROR] chunked dispatch runtime contract mismatch for %s\n' "$slug" >> "$errlog"
        append_log_marker "$live_log" "chunked dispatch runtime contract mismatch"
        return 1
    fi

    IFS='|' read -r effective_parallel_limit parallel_limit_reason <<< "$(phase2_effective_chunk_parallel_limit "$dispatch_path" "$PHASE2_WORKER_CHUNK_PARALLEL_LIMIT")"
    append_log_marker "$errlog" "chunked worker parallel_limit=${effective_parallel_limit} reason=${parallel_limit_reason}"
    append_log_marker "$live_log" "chunked worker parallel_limit=${effective_parallel_limit} reason=${parallel_limit_reason}"
    append_log_marker "$chunked_errlog" "chunked orchestrator start slug=${slug} parallel_limit=${effective_parallel_limit} reason=${parallel_limit_reason}"
    append_log_marker "$chunked_live_log" "chunked orchestrator start slug=${slug} parallel_limit=${effective_parallel_limit}"
    log_info "Chunked worker orchestrator: worker=${chunked_worker_provider}, reviewer=${chunked_reviewer_provider}, parallel_limit=${effective_parallel_limit} (details: ${chunked_live_log})"

    local -a chunked_orchestrator_cmd=(
        bash "$PHASE2_MULTI_WORKER_ORCHESTRATOR" "$slug"
        --parallel-limit "$effective_parallel_limit"
        --stop-after-merge
        --no-single-agent-fallback
    )
    if [ "$PHASE2_CHUNKED_RESUME_MISSING_ONLY" = true ]; then
        chunked_orchestrator_cmd+=(--resume-missing-only)
    fi

    chunked_console_stdout_pattern='^\[orchestrate-agents\] INFO  (=== Multi-agent orchestrator starting|timeout:|bundle_review_enabled:|Preflight|=== Step 4:|Retrying |Running reviewer loop|Running worker revision|Reviewer loop for |=== Step 5:|Completed:|Failed:|All agents finished\.|=== Step 6:|Merge complete\.|=== Step 6\.5:|Cluster planning complete\.|=== Step 6\.6:|Cluster evidence pack build complete\.|=== Step 6\.7:|=== Step 6\.8:|=== Step 7:|Sentinel written|=== Orchestration complete|Successful agents:|Next step:)'
    chunked_console_stderr_pattern='^\[orchestrate-agents\] (WARN|ERROR)'

    if ! run_command_with_filtered_console_logs "$chunked_live_log" "$chunked_errlog" "$chunked_console_stdout_pattern" "$chunked_console_stderr_pattern" \
        env \
        PHASE2_BUNDLE_REVIEW_ENABLED=true \
        PHASE2_SUPPORT_AGENTS_ENABLED=false \
        PHASE2_MAX_REVIEW_ROUNDS="$PHASE2_MAX_REVIEW_ROUNDS" \
        PHASE2_WORKER_PROVIDER="$chunked_worker_provider" \
        PHASE2_REVIEWER_PROVIDER="$chunked_reviewer_provider" \
        PHASE2_PRIMARY_PROVIDER="$chunked_primary_provider" \
        PHASE2_WORKER_CLAUDE_MODEL="$PHASE2_WORKER_CLAUDE_MODEL" \
        PHASE2_WORKER_CODEX_MODEL="$PHASE2_WORKER_CODEX_MODEL" \
        PHASE2_REVIEWER_CLAUDE_MODEL="$PHASE2_REVIEWER_CLAUDE_MODEL" \
        PHASE2_REVIEWER_CODEX_MODEL="$PHASE2_REVIEWER_CODEX_MODEL" \
        PHASE2_CLUSTER_SYNTH_PROVIDER="$chunked_cluster_synth_provider" \
        PHASE2_CLUSTER_SYNTH_CLAUDE_MODEL="$PHASE2_CLUSTER_SYNTH_CLAUDE_MODEL" \
        PHASE2_CLUSTER_SYNTH_CODEX_MODEL="$PHASE2_CLUSTER_SYNTH_CODEX_MODEL" \
        PHASE2_CLUSTER_CHALLENGER_PROVIDER="$chunked_cluster_challenger_provider" \
        PHASE2_CLUSTER_CHALLENGER_CLAUDE_MODEL="$PHASE2_CLUSTER_CHALLENGER_CLAUDE_MODEL" \
        PHASE2_CLUSTER_CHALLENGER_CODEX_MODEL="$PHASE2_CLUSTER_CHALLENGER_CODEX_MODEL" \
        PHASE2_PROVIDER_TIMEOUT_SECONDS="$PHASE2_WORKER_TIMEOUT_SECONDS" \
        CODEX_QUOTA_ACCOUNT="${CODEX_QUOTA_ACCOUNT:-}" \
        "${chunked_orchestrator_cmd[@]}"; then
        printf '[ERROR] chunked worker orchestrator failed for %s\n' "$slug" >> "$errlog"
        append_log_marker "$live_log" "chunked worker orchestrator failed slug=${slug}"
        return 1
    fi
    append_log_marker "$chunked_errlog" "chunked orchestrator done slug=${slug}"
    append_log_marker "$chunked_live_log" "chunked orchestrator done slug=${slug}"

    if [ ! -f "$local_phase2_path" ]; then
        printf '[ERROR] chunked worker local phase2 missing: %s\n' "$local_phase2_path" >> "$errlog"
        append_log_marker "$live_log" "chunked worker local phase2 missing"
        return 1
    fi

    cp -f "$local_phase2_path" "$output_path"
    cp -f "$local_phase2_path" "$raw_path" 2>/dev/null || true

    end_ts="$(date +%s)"
    duration=$((end_ts - start_ts))
    PHASE2_LAST_DURATION_SECONDS="$duration"
    status="ok"
    append_log_marker "$errlog" "chunked worker end slug=${slug} round=${round} status=${status} duration_seconds=${duration} output=${output_path}"
    append_log_marker "$live_log" "chunked worker end slug=${slug} round=${round} status=${status} duration_seconds=${duration} output=${output_path}"
    append_quota_log "phase2" "$slug" "worker-r${round}-${worker_mode}-chunked" "multi-agent" "candidate_chunk_v2" "$status" "$duration" \
        "chunked_scheduler" "worker" "" "" "$round" "" "" "$dispatch_path" "$output_path" "$chunked_errlog" "$chunked_live_log"
    return 0
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

    if [ "$round" -eq 1 ] && [ "$worker_mode" = "deep" ] && [ "${PHASE2_ACTIVE_WORKER_STRATEGY:-monolithic}" = "chunked" ]; then
        if ! run_phase2_chunked_worker_round "$slug" "$round" "$worker_mode" "$provider" "$output_path" "$raw_path" "$errlog"; then
            return 1
        fi
    else
        if ! run_llm_prompt "$slug" "worker-r${round}-${worker_mode}" "$provider" "$system_prompt" "$prompt" "$errlog" "$model" "$timeout_seconds"; then
            return 1
        fi
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
    local source_review_rel="${6:-}"
    local review_output_path review_output_rel review_input_path review_input_rel prompt errlog live_log system_prompt model timeout_seconds
    local worker_output_path
    local batch_plan_path batch_plan_rel batch_id batch_input_rel batch_output_rel batch_packet_count batch_load
    local batch_errlog batch_prompt batch_output_path total_reviewer_duration batch_total batch_index batch_failure_reason
    local batch_retry_count batch_retry_limit
    local reviewer_parallel_limit reviewer_batch_failures status_file status_entry
    local status_path status_rest status_batch_id status_index status_line
    local status_state status_tail status_duration status_reason
    local -a reviewer_batch_status_files

    review_output_path="$(phase2_review_output_path "$slug" "$round")"
    review_output_rel="$(phase2_review_output_rel "$slug" "$round")"
    review_input_path="$(phase2_review_input_path "$slug" "$round" "$review_mode")"
    review_input_rel="$(phase2_review_input_rel "$slug" "$round" "$review_mode")"
    worker_output_path="${ROOT_DIR}/${worker_output_rel}"
    system_prompt="$(phase2_review_system_prompt "$review_mode" "$provider")"
    model="$(phase2_role_model reviewer "$provider")"
    timeout_seconds="$(phase2_timeout_for_review_mode "$review_mode")"
    errlog="$(phase2_loop_errlog_path "$slug" reviewer "$provider" "$round" "$review_mode")"
    live_log="$(phase2_loop_live_log_path "$slug" reviewer "$provider" "$round" "$review_mode")"
    reset_log_file "$errlog"
    reset_log_file "$live_log"
    append_log_marker "$errlog" "review round start slug=${slug} round=${round} mode=${review_mode} provider=${provider} worker_output=${worker_output_rel}"
    append_log_marker "$live_log" "review round start slug=${slug} round=${round} mode=${review_mode} provider=${provider}"
    if ! build_phase2_reviewer_input "$slug" "$round" "$review_mode" "$worker_output_path" "$review_output_path" "$review_input_path" "$errlog" "${source_review_rel:+${ROOT_DIR}/${source_review_rel}}"; then
        return 1
    fi

    if [ "$review_mode" = "core" ]; then
        batch_plan_path="$(phase2_review_batch_plan_path "$slug" "$round")"
        batch_plan_rel="$(phase2_review_batch_plan_rel "$slug" "$round")"
        if ! build_phase2_reviewer_batches "$review_input_path" "$batch_plan_path" "$errlog"; then
            return 1
        fi
        batch_total="$(phase2_review_batch_total "$batch_plan_path" 2>/dev/null || echo 0)"
        log_info "Reviewer core round ${round} plan: ${batch_total} batch(es)$(phase2_progress_suffix 40)"
        total_reviewer_duration=0
        batch_index=0
        reviewer_parallel_limit="$(phase2_reviewer_parallel_limit)"
        reviewer_batch_status_files=()
        PHASE2_REVIEWER_BATCH_PIDS=""
        PHASE2_QUOTA_SENTINEL="$(phase2_loop_errlog_path "$slug" reviewer "$provider" "$round" "${review_mode}.quota-exhausted")"
        rm -f "$PHASE2_QUOTA_SENTINEL"
        export PHASE2_QUOTA_SENTINEL
        log_info "Reviewer core round ${round}: fan-out parallel_limit=${reviewer_parallel_limit}"
        while IFS='|' read -r batch_id batch_input_rel batch_output_rel batch_packet_count batch_load; do
            [ -n "$batch_id" ] || continue
            batch_index=$((batch_index + 1))
            batch_output_path="${ROOT_DIR}/${batch_output_rel}"
            batch_errlog="$(phase2_loop_errlog_path "$slug" reviewer "$provider" "$round" "${review_mode}.${batch_id}")"
            batch_prompt="$(render_phase2_review_prompt "$slug" "$round" "$batch_input_rel" "$batch_output_rel")"
            printf '[INFO] reviewer core batch %s packets=%s load=%s input=%s output=%s plan=%s\n' \
                "$batch_id" "$batch_packet_count" "$batch_load" "$batch_input_rel" "$batch_output_rel" "$batch_plan_rel" >> "$errlog"
            log_info "Reviewer core batch ${batch_index}/${batch_total}: ${batch_id} (${batch_packet_count} packet(s), load=${batch_load})$(phase2_progress_suffix "$(phase2_progress_for_review_batch "$review_mode" "$batch_index" "$batch_total")")"
            if [ "$RESUME_EXISTING" = true ] && [ -f "$batch_output_path" ]; then
                if validate_phase2_review_output "$batch_output_path" "$review_mode" "$batch_errlog" "$worker_output_path"; then
                    printf '[INFO] reviewer core batch %s reused validated output=%s\n' \
                        "$batch_id" "$batch_output_rel" >> "$errlog"
                    log_info "Reviewer core batch ${batch_index}/${batch_total}: ${batch_id} reuse validated output$(phase2_progress_suffix "$(phase2_progress_for_review_batch "$review_mode" "$batch_index" "$batch_total")")"
                    total_reviewer_duration=$((total_reviewer_duration + ${PHASE2_LAST_DURATION_SECONDS:-0}))
                    continue
                fi
                printf '[WARN] reviewer core batch %s existing output invalid; rerunning output=%s\n' \
                    "$batch_id" "$batch_output_rel" >> "$errlog"
            fi
            if [ -n "${PHASE2_QUOTA_SENTINEL:-}" ] && [ -f "$PHASE2_QUOTA_SENTINEL" ]; then
                printf '[ERROR] reviewer %s: subscription quota exhausted; not launching batch %s\n' \
                    "$review_mode" "$batch_id" >> "$errlog"
                continue
            fi
            status_file="${batch_errlog}.status"
            rm -f "$status_file"
            reviewer_batch_status_files+=("${status_file}|${batch_id}|${batch_index}")
            phase2_reviewer_throttle "$reviewer_parallel_limit"
            phase2_run_reviewer_batch "$slug" "$round" "$review_mode" "$provider" "$system_prompt" \
                "$batch_prompt" "$batch_errlog" "$model" "$timeout_seconds" "$batch_output_path" \
                "$worker_output_path" "$batch_id" "$status_file" &
            PHASE2_REVIEWER_BATCH_PIDS="${PHASE2_REVIEWER_BATCH_PIDS} $!"
        done < <(phase2_review_batch_entries "$batch_plan_path")

        wait || true
        PHASE2_REVIEWER_BATCH_PIDS=""

        reviewer_batch_failures=0
        for status_entry in "${reviewer_batch_status_files[@]}"; do
            [ -n "$status_entry" ] || continue
            status_path="${status_entry%%|*}"
            status_rest="${status_entry#*|}"
            status_batch_id="${status_rest%%|*}"
            status_index="${status_rest#*|}"
            if [ ! -f "$status_path" ]; then
                printf '[ERROR] reviewer %s batch %s produced no status file\n' "$review_mode" "$status_batch_id" >> "$errlog"
                log_warn "Reviewer ${review_mode} batch ${status_index}/${batch_total} (${status_batch_id}) produced no status file"
                reviewer_batch_failures=$((reviewer_batch_failures + 1))
                continue
            fi
            status_line="$(cat "$status_path" 2>/dev/null)"
            status_state="${status_line%%|*}"
            status_tail="${status_line#*|}"
            status_duration="${status_tail%%|*}"
            status_reason="${status_tail#*|}"
            case "$status_duration" in
                ''|*[!0-9]*) status_duration=0 ;;
            esac
            total_reviewer_duration=$((total_reviewer_duration + status_duration))
            if [ "$status_state" = "ok" ]; then
                log_info "Reviewer ${review_mode} batch ${status_index}/${batch_total}: ${status_batch_id} done (${status_duration}s)$(phase2_progress_suffix "$(phase2_progress_for_review_batch "$review_mode" "$status_index" "$batch_total")")"
            else
                printf '[ERROR] reviewer %s batch %s failed reason=%s errlog=%s\n' \
                    "$review_mode" "$status_batch_id" "$status_reason" "${status_path%.status}" >> "$errlog"
                log_warn "Reviewer ${review_mode} batch ${status_index}/${batch_total} failed: ${status_reason}"
                reviewer_batch_failures=$((reviewer_batch_failures + 1))
            fi
        done
        if [ "$reviewer_batch_failures" -gt 0 ]; then
            log_error "Reviewer ${review_mode} round ${round}: ${reviewer_batch_failures}/${batch_total} batch(es) failed"
            return 1
        fi
        if ! merge_phase2_reviewer_batches "$batch_plan_path" "$review_output_path" "$errlog"; then
            return 1
        fi
        PHASE2_LAST_DURATION_SECONDS="$total_reviewer_duration"
        if ! validate_phase2_review_output "$review_output_path" "$review_mode" "$errlog" "$worker_output_path"; then
            return 1
        fi
        annotate_phase2_review_output_runtime "$review_output_path" "$provider" "$model" "$review_mode" "$round" "${PHASE2_PROVIDER_POLICY_TIER:-}"
        return 0
    fi

    if [ "$review_mode" = "forced_exploration" ] || [ "$review_mode" = "explore" ]; then
        prompt="$(render_phase2_exploration_prompt "$slug" "$round" "$review_input_rel" "$review_output_rel" "$PHASE2_MAX_EXPLORATION_CANDIDATES")"
    elif [ "$review_mode" = "terminal_core" ]; then
        prompt="$(render_phase2_terminal_review_prompt "$slug" "$round" "$review_input_rel" "$review_output_rel")"
    else
        prompt="$(render_phase2_review_prompt "$slug" "$round" "$review_input_rel" "$review_output_rel")"
    fi

    rm -f "$review_output_path"
    if run_llm_prompt "$slug" "review-r${round}-${review_mode}" "$provider" "$system_prompt" "$prompt" "$errlog" "$model" "$timeout_seconds"; then
        :
    else
        local review_rc=$?
        if ! accept_phase2_review_output_after_failure "$review_output_path" "$review_mode" "$errlog" "$review_rc" "$worker_output_path"; then
            return 1
        fi
    fi
    if ! validate_phase2_review_output "$review_output_path" "$review_mode" "$errlog" "$worker_output_path"; then
        return 1
    fi
    annotate_phase2_review_output_runtime "$review_output_path" "$provider" "$model" "$review_mode" "$round" "${PHASE2_PROVIDER_POLICY_TIER:-}"
}

run_phase2_cluster_pipeline() {
    local slug="$1"
    local local_phase2_path="$2"
    local errlog="$3"
    local live_log
    local cluster_plan_path cluster_total
    local cluster_consensus_enabled=false
    local -a cluster_cmd=()

    if [ "$PHASE2_ENABLE_CLUSTER_CONSENSUS" = true ]; then
        cluster_consensus_enabled=true
    fi

    live_log="$(live_log_path_from_errlog "$errlog")"
    mkdir -p "$(dirname "$errlog")" "$(dirname "$live_log")"
    if [ ! -f "$PHASE2_CONSENSUS_WRITER" ]; then
        printf '[ERROR] consensus stage blocked: missing %s\n' "$PHASE2_CONSENSUS_WRITER" >> "$errlog"
        append_log_marker "$live_log" "consensus-missing-script path=${PHASE2_CONSENSUS_WRITER}"
        log_error "Consensus stage blocked; missing script: $PHASE2_CONSENSUS_WRITER"
        return 1
    fi
    if [ "$cluster_consensus_enabled" = true ]; then
        for required in \
            "$PHASE2_CLUSTER_BUILDER" \
            "$PHASE2_CLUSTER_PACK_BUILDER" \
            "$PHASE2_CLUSTER_RUNNER"
        do
            if [ ! -f "$required" ]; then
                printf '[ERROR] cluster stage blocked: missing %s\n' "$required" >> "$errlog"
                append_log_marker "$live_log" "cluster-missing-script path=${required}"
                log_error "Cluster stage blocked; missing script: $required"
                return 1
            fi
        done
    fi

    : > "$errlog"
    : > "$live_log"
    printf '[INFO] cluster pipeline start slug=%s local_phase2=%s\n' "$slug" "$local_phase2_path" >> "$errlog"
    append_log_marker "$live_log" "cluster pipeline start slug=${slug} local_phase2=${local_phase2_path}"

    if [ "$cluster_consensus_enabled" = true ]; then
        append_log_marker "$errlog" "cluster-plan start"
        append_log_marker "$live_log" "cluster-plan start"
            if ! run_command_with_file_logs "$live_log" "$errlog" python3 "$PHASE2_CLUSTER_BUILDER" "$slug" --reports-dir "$REPORTS_DIR" --phase2-json "$local_phase2_path"; then
            printf '[ERROR] cluster plan build failed; refusing canonical publish\n' >> "$errlog"
            append_log_marker "$live_log" "cluster-plan failed"
            log_error "Cluster planning failed for ${slug}; refusing canonical Phase 2 publish."
            return 1
        else
            append_log_marker "$errlog" "cluster-plan done"
            append_log_marker "$live_log" "cluster-plan done"
            append_log_marker "$errlog" "cluster-pack start"
            append_log_marker "$live_log" "cluster-pack start"
            if ! run_command_with_file_logs "$live_log" "$errlog" python3 "$PHASE2_CLUSTER_PACK_BUILDER" "$slug" --reports-dir "$REPORTS_DIR"; then
                printf '[ERROR] cluster evidence pack build failed; refusing canonical publish\n' >> "$errlog"
                append_log_marker "$live_log" "cluster-pack failed"
                log_error "Cluster evidence pack build failed for ${slug}; refusing canonical Phase 2 publish."
                return 1
            else
                append_log_marker "$errlog" "cluster-pack done"
                append_log_marker "$live_log" "cluster-pack done"
                cluster_plan_path="$(phase2_cluster_plan_path "$slug")"
                cluster_total="$(phase2_cluster_count "$cluster_plan_path")"
                if [ "${cluster_total:-0}" -gt 0 ]; then
                    cluster_cmd=(python3 "$PHASE2_CLUSTER_RUNNER" "$slug" --codex-bin "$CODEX_BIN" --claude-bin "$CLAUDE_BIN" --claude-safe-tools "${PHASE2_CLUSTER_CLAUDE_SAFE_TOOLS:-Read,Grep,Glob}")
                    if [ -n "$PHASE2_CLUSTER_LIMIT" ]; then
                        cluster_cmd+=(--limit "$PHASE2_CLUSTER_LIMIT")
                    fi
                    append_log_marker "$errlog" "cluster-run start total_clusters=${cluster_total}"
                    append_log_marker "$live_log" "cluster-run start total_clusters=${cluster_total}"
                    if ! run_command_with_file_logs "$live_log" "$errlog" "${cluster_cmd[@]}"; then
                        printf '[ERROR] cluster synth/challenge returned non-zero; refusing canonical publish\n' >> "$errlog"
                        append_log_marker "$live_log" "cluster-run non-zero failing=true"
                        log_error "Cluster synth/challenge was not clean for ${slug}; refusing canonical Phase 2 publish."
                        return 1
                    else
                        append_log_marker "$errlog" "cluster-run done"
                        append_log_marker "$live_log" "cluster-run done"
                    fi
                else
                    printf '[INFO] cluster plan has zero active clusters; synth/challenge skipped\n' >> "$errlog"
                    append_log_marker "$live_log" "cluster-run skipped total_clusters=0"
                fi
            fi
        fi
    else
        append_log_marker "$errlog" "cluster disabled; local-only consensus publish path"
        append_log_marker "$live_log" "cluster disabled; local-only consensus publish path"
    fi

    append_log_marker "$errlog" "consensus start"
    append_log_marker "$live_log" "consensus start"
    if ! run_command_with_file_logs "$live_log" "$errlog" python3 "$PHASE2_CONSENSUS_WRITER" "$slug" --reports-dir "$REPORTS_DIR"; then
        printf '[ERROR] consensus writer failed; canonical publish blocked\n' >> "$errlog"
        append_log_marker "$live_log" "consensus failed"
        log_error "Consensus writer failed for ${slug}; canonical Phase 2 publish blocked."
        return 1
    fi

    printf '[INFO] cluster pipeline completed successfully for %s\n' "$slug" >> "$errlog"
    append_log_marker "$live_log" "consensus done"
    append_log_marker "$live_log" "cluster pipeline completed successfully slug=${slug}"
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
    local adaptive_depth_profile="${PHASE2_ADAPTIVE_DEPTH_PROFILE:-}"
    local adaptive_signal_score="${PHASE2_ADAPTIVE_SIGNAL_SCORE:-0}"
    local adaptive_depth_reasons="${PHASE2_ADAPTIVE_DEPTH_REASONS:-}"
    local worker_execution_strategy="${PHASE2_ACTIVE_WORKER_STRATEGY:-monolithic}"
    local effective_revision_timeout="${PHASE2_REVISION_TIMEOUT_SECONDS:-}"
    local effective_reviewer_timeout="${PHASE2_REVIEWER_TIMEOUT_SECONDS:-}"
    local effective_exploration_timeout="${PHASE2_EXPLORATION_TIMEOUT_SECONDS:-}"
    local reviewer_core_provider="$reviewer_provider"
    local reviewer_core_model="$reviewer_model"
    local reviewer_explore_provider="${PHASE2_EXPLORE_PROVIDER:-$reviewer_core_provider}"
    local reviewer_explore_model
    reviewer_explore_model="$(phase2_stage_model reviewer_explore "$reviewer_explore_provider")"
    local provider_policy_tier="${PHASE2_PROVIDER_POLICY_TIER:-}"
    local provider_policy_label="${PHASE2_PROVIDER_POLICY_LABEL:-}"
    local provider_policy_reasons="${PHASE2_PROVIDER_POLICY_REASONS:-}"

    python3 - "$output_path" "$slug" "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" "$initial_mode" "$completed_worker_rounds" "$completed_review_rounds" "$max_review_rounds" "$final_review_status" "$final_worker_rel" "$final_review_rel" "$summary_rel" "$stop_reason" "$runtime_seconds" "$execution_status" "$forced_exploration_enabled" "$max_exploration_candidates" "$adaptive_depth_profile" "$adaptive_signal_score" "$adaptive_depth_reasons" "$worker_execution_strategy" "$effective_revision_timeout" "$effective_reviewer_timeout" "$effective_exploration_timeout" "$reviewer_core_provider" "$reviewer_core_model" "$reviewer_explore_provider" "$reviewer_explore_model" "$provider_policy_tier" "$provider_policy_label" "$provider_policy_reasons" <<'PY'
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
    "reviewer_core_provider": sys.argv[27],
    "reviewer_core_model": sys.argv[28] or None,
    "reviewer_explore_provider": sys.argv[29],
    "reviewer_explore_model": sys.argv[30] or None,
    "initial_mode": sys.argv[7],
    "completed_worker_rounds": int(sys.argv[8]),
    "completed_review_rounds": int(sys.argv[9]),
    "max_review_rounds": int(sys.argv[10]),
    "forced_exploration_enabled": sys.argv[18].lower() == "true",
    "max_exploration_candidates": int(sys.argv[19]),
    "adaptive_depth_policy": {
        "profile": sys.argv[20] or None,
        "signal_score": int(sys.argv[21]),
        "reasons": [item for item in sys.argv[22].split(",") if item],
        "worker_execution_strategy": sys.argv[23] or None,
        "effective_timeouts": {
            "revision_seconds": int(sys.argv[24]) if sys.argv[24] else None,
            "reviewer_seconds": int(sys.argv[25]) if sys.argv[25] else None,
            "exploration_seconds": int(sys.argv[26]) if sys.argv[26] else None,
        },
    },
    "final_review_status": sys.argv[11],
    "stop_reason": sys.argv[15],
    "runtime_seconds": int(sys.argv[16]),
    "status": sys.argv[17],
    "summary_path": sys.argv[14] or None,
    "artifacts": {
        "final_worker_output": sys.argv[12],
        "final_review_output": sys.argv[13] or None,
    },
    "provider_strategy": {
        "tier": sys.argv[31] or None,
        "label": sys.argv[32] or None,
        "reasons": [item for item in sys.argv[33].split(",") if item],
    },
}
summary_rel = sys.argv[14] or ""
if summary_rel:
    root = out_path.parent.parent
    summary_path = (root / summary_rel).resolve()
    if summary_path.exists():
        try:
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
        except Exception:
            pass
        else:
            if isinstance(summary.get("trust_state"), str):
                data["phase2_loop"]["trust_state"] = summary["trust_state"]
            if isinstance(summary.get("degradation_signals"), list):
                data["phase2_loop"]["degradation_signals"] = summary["degradation_signals"]
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

phase2_trust_summary() {
    local execution_status="$1"
    local artifact_path="$2"
    local canonical_published="${3:-false}"
    python3 - "$execution_status" "$artifact_path" "$canonical_published" <<'PY'
import json
import sys
from pathlib import Path

execution_status = sys.argv[1]
artifact_path = Path(sys.argv[2]) if sys.argv[2] else None
canonical_published = sys.argv[3].lower() == "true"
signals = []
trust_state = None
closure_complete = None

if artifact_path and artifact_path.exists():
    try:
        data = json.loads(artifact_path.read_text(encoding="utf-8"))
    except Exception:
        signals.append("artifact_unreadable")
    else:
        if isinstance(data.get("trust_state"), str) and data["trust_state"]:
            trust_state = data["trust_state"]
        for container in (data, data.get("consensus"), data.get("merge_stats")):
            if not isinstance(container, dict):
                continue
            value = container.get("closure_complete")
            if isinstance(value, bool):
                closure_complete = value
                break
        if closure_complete is None:
            needs_review = data.get("needs_review")
            if isinstance(needs_review, int):
                closure_complete = needs_review == 0
            elif isinstance(data.get("findings"), list):
                closure_complete = True
                for finding in data["findings"]:
                    if isinstance(finding, dict) and str(finding.get("verdict") or "").upper() == "REVIEW":
                        closure_complete = False
                        break
        for key in ("degradation_signals",):
            value = data.get(key)
            if isinstance(value, list):
                signals.extend(str(item) for item in value if str(item))
        merge_stats = data.get("merge_stats")
        if isinstance(merge_stats, dict):
            value = merge_stats.get("degradation_signals")
            if isinstance(value, list):
                signals.extend(str(item) for item in value if str(item))
        consensus = data.get("consensus")
        if isinstance(consensus, dict):
            value = consensus.get("degradation_signals")
            if isinstance(value, list):
                signals.extend(str(item) for item in value if str(item))
if closure_complete is False and "closure_incomplete" not in signals:
    signals.append("closure_incomplete")

signals = sorted(set(signals))
if execution_status == "failed":
    trust_state = "failed"
elif execution_status == "partial":
    trust_state = "partial_success"
elif not canonical_published:
    trust_state = "partial_success"
    if "canonical_not_published" not in signals:
        signals.append("canonical_not_published")
elif trust_state is None:
    trust_state = "degraded_success" if signals else "success"

print(f"{trust_state}|{','.join(sorted(set(signals)))}")
PY
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
    local phase2_logs_root
    local errlog_deep errlog_quick live_log_deep live_log_quick
    local state_path
    local provider_policy_path threat_context_file
    local worker_provider="$PHASE2_BASELINE_WORKER_PROVIDER"
    local reviewer_provider="$PHASE2_BASELINE_REVIEWER_PROVIDER"
    local explore_reviewer_provider="$PHASE2_BASELINE_EXPLORE_PROVIDER"
    local worker_model reviewer_model explore_reviewer_model
    local cluster_synth_provider="$PHASE2_BASELINE_CLUSTER_SYNTH_PROVIDER"
    local cluster_challenger_provider="$PHASE2_BASELINE_CLUSTER_CHALLENGER_PROVIDER"
    local cluster_synth_model cluster_challenger_model
    local final_review_status="not_reviewed"
    local last_review_rel=""
    local last_review_path=""
    local current_worker_round=1
    local completed_review_rounds=0
    local resume_active=false chunked_resume_active=false existing_worker_round=0 existing_review_round=0 existing_review_mode="core"
    local existing_rounds review_round_start
    local loop_started_ts loop_finished_ts total_runtime_seconds stop_reason="not_started"
    local execution_status="success"
    local forced_exploration_already_completed=false
    local terminal_core_review_ready=false
    local existing_chunked_output_count=0

    if [ -z "${AUDIT_RUN_ID:-}" ]; then
        AUDIT_RUN_ID="${slug}-phase2-$(date -u +%Y%m%dT%H%M%SZ)-$$"
        export AUDIT_RUN_ID
    fi

    phase2_logs_root="$(logs_phase2_dir "$slug")"
    errlog_deep="$(logs_phase2_run_err_path "$slug" deep)"
    errlog_quick="$(logs_phase2_run_err_path "$slug" quick)"
    live_log_deep="$(logs_phase2_run_live_path "$slug" deep)"
    live_log_quick="$(logs_phase2_run_live_path "$slug" quick)"
    state_path="$(phase2_state_path "$slug")"
    provider_policy_path="$(phase2_provider_policy_path_for_slug "$slug")"
    threat_context_file="$(threat_context_path_for_slug "$slug")"

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
    echo "  Mode default: adaptive deep (with quick-triage fallback for low-signal plugins)"
    worker_model="$(phase2_role_model worker "$worker_provider")"
    reviewer_model="$(phase2_role_model reviewer "$reviewer_provider")"
    echo "  Base worker provider: ${worker_provider} (${worker_model:-default model})"
    echo "  Base reviewer provider: ${reviewer_provider} (${reviewer_model:-default model})"
    echo "  Worker execution mode: ${PHASE2_WORKER_EXECUTION_MODE} (chunk parallel limit=${PHASE2_WORKER_CHUNK_PARALLEL_LIMIT})"
    echo "  Base max review rounds: ${PHASE2_MAX_REVIEW_ROUNDS}"
    echo "  Base forced exploration: ${PHASE2_ENABLE_FORCED_EXPLORATION} (max candidates=${PHASE2_MAX_EXPLORATION_CANDIDATES})"
    echo "  Cluster consensus: ${PHASE2_ENABLE_CLUSTER_CONSENSUS}${PHASE2_CLUSTER_LIMIT:+ (limit=${PHASE2_CLUSTER_LIMIT})}"
    echo "  Base timeout policy: worker=${PHASE2_WORKER_TIMEOUT_SECONDS}s, revision=${PHASE2_REVISION_TIMEOUT_SECONDS}s, reviewer=${PHASE2_REVIEWER_TIMEOUT_SECONDS}s, exploration=${PHASE2_EXPLORATION_TIMEOUT_SECONDS}s (${TIMEOUT_BACKEND})"

    if [ "$RESUME_EXISTING" = true ]; then
        existing_rounds="$(phase2_existing_rounds "$slug" "$PHASE2_DIR")"
        IFS='|' read -r existing_worker_round existing_review_round <<< "$existing_rounds"
        if [ "${existing_worker_round:-0}" -gt 0 ]; then
            resume_active=true
            echo "  Resume existing artifacts: worker_r${existing_worker_round}, review_r${existing_review_round}"
        elif [ "$PHASE2_CHUNKED_RESUME_MISSING_ONLY" = true ]; then
            local resume_dispatch_path resume_inventory_path
            resume_dispatch_path="$(phase2_dispatch_path "$slug")"
            resume_inventory_path="$(phase2_candidate_inventory_path "$slug")"
            existing_chunked_output_count="$(phase2_existing_chunked_output_count "$slug")"
            if [ -f "$resume_dispatch_path" ] || [ -f "$resume_inventory_path" ] || [ "${existing_chunked_output_count:-0}" -gt 0 ]; then
                chunked_resume_active=true
                echo "  Resume existing chunked artifacts: ${existing_chunked_output_count} bundle output(s) already present; missing bundles will rerun if worker strategy resolves to chunked."
            else
                echo "  Resume requested but no existing worker or chunked artifacts found; restarting from round 1."
            fi
        else
            echo "  Resume requested but no existing worker artifacts found; restarting from round 1."
        fi
    fi

    rm -f "$output" "$raw_output" "$errlog_deep" "$errlog_quick" "$live_log_deep" "$live_log_quick" "$provider_policy_path"
    rm -f "$loop_summary_path" "$loop_events_path"
    if [ "$resume_active" != true ] && [ "$chunked_resume_active" != true ]; then
        rm -rf "$phase2_logs_root"
        rm -rf "$(phase2_prep_dir_path_for_slug "$slug")" "$(phase2_agents_dir_path_for_slug "$slug")"
        rm -f "$(phase2_state_path "$slug")"
        rm -f "${PHASE2_DIR}/${slug}-phase2.worker.r"*.json \
              "${PHASE2_DIR}/${slug}-phase2.worker.r"*.raw.json \
              "${PHASE2_DIR}/${slug}-phase2.review.r"*.json
        for provider in codex claude; do
            rm -f "$(phase2_output_path "$slug" "$provider")" \
                  "$(phase2_raw_path "$slug" "$provider")"
        done
    fi

    reset_log_file "$errlog_deep"
    reset_log_file "$live_log_deep"
    append_log_marker "$errlog_deep" "phase2 envelope start slug=${slug}"
    append_log_marker "$live_log_deep" "phase2 envelope start slug=${slug}"
    write_phase2_state "$state_path" "$slug" "bootstrap" "running" "" 0 "" "" "" "$errlog_deep" "$live_log_deep" \
        message "phase2 bootstrap started"

    if [ "$ep_count" -eq 0 ] || { [ "$anom_count" = "0" ] && [ "$source_count" = "0" ] && [ "$sink_count" = "0" ]; }; then
        local lite_local_path lite_cluster_errlog lite_canonical_source="not_published" lite_canonical_published=false
        local lite_trust_state lite_degradation_signals
        lite_local_path="$(phase2_local_output_path "$slug")"
        lite_cluster_errlog="$(phase2_cluster_errlog_path "$slug")"
        echo "  AST triage: low/no surface -> writing deterministic phase2-lite output (no LLM)."
        rm -f "$output" "$raw_output"
        write_lite_output "$slug" "$lite_local_path" "Phase2-lite deterministic triage completed" \
            "$anom_count" "$ep_count" "$unauth_ep" "$sensitive_sinks" "$sql_sinks" "$rest_json_sources" "$output_sinks" "$source_count" "$sink_count"
        stop_reason="deterministic_lite_no_surface"
        final_review_status="not_applicable"
        loop_finished_ts="$(date +%s)"
        total_runtime_seconds=$((loop_finished_ts - loop_started_ts))
        write_phase2_loop_summary "$loop_summary_path" "$loop_events_path" \
            "$slug" "lite" "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" \
            "$PHASE2_MAX_REVIEW_ROUNDS" 0 0 "$final_review_status" "$stop_reason" "success" "$total_runtime_seconds" \
            "reports/phase2/${slug}-phase2.json" "" "" 0 0 0 0 "LOW" "$PHASE2_ENABLE_FORCED_EXPLORATION" "$PHASE2_MAX_EXPLORATION_CANDIDATES"
        annotate_phase2_loop_output "$slug" "$lite_local_path" \
            "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" \
            "lite" 0 0 "$PHASE2_MAX_REVIEW_ROUNDS" "$final_review_status" "" "" \
            "$loop_summary_rel" "$stop_reason" "$total_runtime_seconds" "success" \
            "$PHASE2_ENABLE_FORCED_EXPLORATION" "$PHASE2_MAX_EXPLORATION_CANDIDATES"
        local provider
        for provider in "${LLM_PROVIDER_ARRAY[@]}"; do
            cp -f "$lite_local_path" "$(phase2_output_path "$slug" "$provider")" 2>/dev/null || true
            cp -f "$lite_local_path" "$(phase2_raw_path "$slug" "$provider")" 2>/dev/null || true
        done
        append_log_marker "$errlog_deep" "consensus-authoritative publish start slug=${slug} mode=lite"
        append_log_marker "$live_log_deep" "consensus-authoritative publish start slug=${slug} mode=lite"
        write_phase2_state "$state_path" "$slug" "cluster" "running" "cluster" 0 "" "" "$(root_relative_path "$lite_local_path")" "$lite_cluster_errlog" "$(phase2_cluster_live_log_path "$slug")" \
            mode "lite"
        if run_phase2_cluster_pipeline "$slug" "$lite_local_path" "$lite_cluster_errlog"; then
            lite_canonical_source="consensus"
            lite_canonical_published=true
            cp -f "$lite_local_path" "$raw_output" 2>/dev/null || true
            append_log_marker "$errlog_deep" "consensus-authoritative publish finished slug=${slug} mode=lite status=success"
            append_log_marker "$live_log_deep" "consensus-authoritative publish finished slug=${slug} mode=lite status=success"
            IFS='|' read -r lite_trust_state lite_degradation_signals <<< "$(phase2_trust_summary "success" "$output" "true")"
            write_phase2_state "$state_path" "$slug" "done" "success" "" 0 "" "" "reports/phase2/${slug}-phase2.json" "$errlog_deep" "$live_log_deep" \
                stop_reason "$stop_reason" tp "0" fp "0" review "0" risk "LOW" canonical_published "true" canonical_source "consensus" mode "lite" \
                trust_state "$lite_trust_state" degradation_signals "$lite_degradation_signals"
        else
            rm -f "$output" "$raw_output"
            append_log_marker "$errlog_deep" "consensus-authoritative publish finished slug=${slug} mode=lite status=failed"
            append_log_marker "$live_log_deep" "consensus-authoritative publish finished slug=${slug} mode=lite status=failed"
            IFS='|' read -r lite_trust_state lite_degradation_signals <<< "$(phase2_trust_summary "failed" "$lite_local_path" "false")"
            write_phase2_state "$state_path" "$slug" "done" "failed" "" 0 "" "" "$(root_relative_path "$lite_local_path")" "$errlog_deep" "$live_log_deep" \
                stop_reason "cluster_pipeline_failed" tp "0" fp "0" review "0" risk "LOW" canonical_published "false" canonical_source "not_published" mode "lite" \
                trust_state "$lite_trust_state" degradation_signals "$lite_degradation_signals"
            RUN_RESULT="failed"
            return 1
        fi
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
    local configured_max_review_rounds configured_forced_exploration configured_max_exploration_candidates
    local configured_revision_timeout configured_reviewer_timeout configured_exploration_timeout
    local adaptive_policy adaptive_depth_profile adaptive_signal_score adaptive_depth_reasons
    local effective_max_review_rounds effective_forced_exploration effective_max_exploration_candidates
    local effective_revision_timeout effective_reviewer_timeout effective_exploration_timeout
    local worker_execution_strategy worker_execution_reason

    configured_max_review_rounds="$PHASE2_MAX_REVIEW_ROUNDS"
    configured_forced_exploration="$PHASE2_ENABLE_FORCED_EXPLORATION"
    configured_max_exploration_candidates="$PHASE2_MAX_EXPLORATION_CANDIDATES"
    configured_revision_timeout="$PHASE2_REVISION_TIMEOUT_SECONDS"
    configured_reviewer_timeout="$PHASE2_REVIEWER_TIMEOUT_SECONDS"
    configured_exploration_timeout="$PHASE2_EXPLORATION_TIMEOUT_SECONDS"
    coverage_gaps_count=$(python3 -c "import json; print(len(json.load(open('${ir_file}')).get('coverage_gaps', [])))" 2>/dev/null || echo "0")

    mode="deep"
    if [ "$FORCE_DEEP" != true ] && [ "$anom_count" = "0" ] && [ "$unauth_ep" = "0" ] && [ "$sensitive_sinks" = "0" ] && [ "$sql_sinks" = "0" ] && [ "$rest_json_sources" = "0" ] && [ "$coverage_gaps_count" = "0" ]; then
        mode="quick"
    fi

    adaptive_policy="$(phase2_adaptive_depth_policy \
        "$mode" "$ep_count" "$anom_count" "$unauth_ep" "$sensitive_sinks" "$sql_sinks" "$rest_json_sources" "$output_sinks" "$source_count" "$sink_count" "$coverage_gaps_count" \
        "$configured_max_review_rounds" "$configured_forced_exploration" "$configured_max_exploration_candidates" \
        "$configured_revision_timeout" "$configured_reviewer_timeout" "$configured_exploration_timeout" \
        "$REVIEW_ROUNDS_EXPLICIT" "$FORCED_EXPLORATION_EXPLICIT" "$EXPLORATION_CANDIDATES_EXPLICIT" \
        "$REVISION_TIMEOUT_EXPLICIT" "$REVIEWER_TIMEOUT_EXPLICIT" "$EXPLORATION_TIMEOUT_EXPLICIT")"
    IFS='|' read -r adaptive_depth_profile effective_max_review_rounds effective_forced_exploration effective_max_exploration_candidates effective_revision_timeout effective_reviewer_timeout effective_exploration_timeout adaptive_signal_score adaptive_depth_reasons <<< "$adaptive_policy"

    IFS='|' read -r worker_execution_strategy worker_execution_reason <<< "$(phase2_worker_execution_strategy "$mode" "$adaptive_depth_profile" "$adaptive_signal_score" "$ep_count" "$source_count" "$sink_count")"

    local PHASE2_MAX_REVIEW_ROUNDS="$effective_max_review_rounds"
    local PHASE2_ENABLE_FORCED_EXPLORATION="$effective_forced_exploration"
    local PHASE2_MAX_EXPLORATION_CANDIDATES="$effective_max_exploration_candidates"
    local PHASE2_REVISION_TIMEOUT_SECONDS="$effective_revision_timeout"
    local PHASE2_REVIEWER_TIMEOUT_SECONDS="$effective_reviewer_timeout"
    local PHASE2_EXPLORATION_TIMEOUT_SECONDS="$effective_exploration_timeout"
    local PHASE2_ADAPTIVE_DEPTH_PROFILE="$adaptive_depth_profile"
    local PHASE2_ADAPTIVE_SIGNAL_SCORE="$adaptive_signal_score"
    local PHASE2_ADAPTIVE_DEPTH_REASONS="$adaptive_depth_reasons"
    local PHASE2_ACTIVE_WORKER_STRATEGY="$worker_execution_strategy"

    if phase2_provider_policy_resolve_prephase2 "$slug" "$ir_file" "$threat_context_file" "$PHASE2_ADAPTIVE_DEPTH_PROFILE" "$PHASE2_ADAPTIVE_SIGNAL_SCORE" "$provider_policy_path"; then
        eval "$(phase2_provider_policy_export_assignments "$provider_policy_path")"
    else
        log_warn "Provider policy resolver failed for ${slug}; continuing with baseline provider configuration."
        if phase2_provider_policy_write_fallback "$slug" "$PHASE2_ADAPTIVE_DEPTH_PROFILE" "$PHASE2_ADAPTIVE_SIGNAL_SCORE" "$provider_policy_path" "$worker_provider" "$reviewer_provider" "${explore_reviewer_provider:-$reviewer_provider}" "$cluster_synth_provider" "$cluster_challenger_provider"; then
            eval "$(phase2_provider_policy_export_assignments "$provider_policy_path")"
        else
            PHASE2_PROVIDER_POLICY_TIER="fallback"
            PHASE2_PROVIDER_POLICY_LABEL="resolver_failed_baseline"
            PHASE2_PROVIDER_POLICY_HIGH_VALUE="false"
            PHASE2_PROVIDER_POLICY_REASONS="resolver_failed"
            PHASE2_PROVIDER_POLICY_WORKER="$worker_provider"
            PHASE2_PROVIDER_POLICY_REVIEWER_CORE="$reviewer_provider"
            PHASE2_PROVIDER_POLICY_REVIEWER_EXPLORE="${explore_reviewer_provider:-$reviewer_provider}"
            PHASE2_PROVIDER_POLICY_CLUSTER_SYNTH="$cluster_synth_provider"
            PHASE2_PROVIDER_POLICY_CLUSTER_CHALLENGER="$cluster_challenger_provider"
        fi
    fi

    if [ "$PHASE2_WORKER_PROVIDER_PINNED" != true ] && [ -n "${PHASE2_PROVIDER_POLICY_WORKER:-}" ]; then
        worker_provider="$PHASE2_PROVIDER_POLICY_WORKER"
    fi
    if [ "$PHASE2_REVIEWER_PROVIDER_PINNED" != true ] && [ -n "${PHASE2_PROVIDER_POLICY_REVIEWER_CORE:-}" ]; then
        reviewer_provider="$PHASE2_PROVIDER_POLICY_REVIEWER_CORE"
    fi
    if [ "$PHASE2_EXPLORE_PROVIDER_FROM_ENV" != true ] || [ -z "${explore_reviewer_provider:-}" ]; then
        explore_reviewer_provider="${PHASE2_PROVIDER_POLICY_REVIEWER_EXPLORE:-$reviewer_provider}"
    fi
    if [ "$PHASE2_CLUSTER_SYNTH_PROVIDER_FROM_ENV" != true ] && [ -n "${PHASE2_PROVIDER_POLICY_CLUSTER_SYNTH:-}" ]; then
        cluster_synth_provider="$PHASE2_PROVIDER_POLICY_CLUSTER_SYNTH"
    fi
    if [ "$PHASE2_CLUSTER_CHALLENGER_PROVIDER_FROM_ENV" != true ] && [ -n "${PHASE2_PROVIDER_POLICY_CLUSTER_CHALLENGER:-}" ]; then
        cluster_challenger_provider="$PHASE2_PROVIDER_POLICY_CLUSTER_CHALLENGER"
    fi
    PHASE2_CLUSTER_SYNTH_PROVIDER="$cluster_synth_provider"
    PHASE2_CLUSTER_CHALLENGER_PROVIDER="$cluster_challenger_provider"
    PHASE2_EXPLORE_PROVIDER="$explore_reviewer_provider"

    worker_model="$(phase2_role_model worker "$worker_provider")"
    reviewer_model="$(phase2_role_model reviewer "$reviewer_provider")"
    explore_reviewer_model="$(phase2_stage_model reviewer_explore "$explore_reviewer_provider")"
    cluster_synth_model="$(phase2_stage_model cluster_synth "$cluster_synth_provider")"
    cluster_challenger_model="$(phase2_stage_model cluster_challenger "$cluster_challenger_provider")"

    echo "  Adaptive depth policy: ${PHASE2_ADAPTIVE_DEPTH_PROFILE} (signal_score=${PHASE2_ADAPTIVE_SIGNAL_SCORE}${PHASE2_ADAPTIVE_DEPTH_REASONS:+; reasons=${PHASE2_ADAPTIVE_DEPTH_REASONS}})"
    echo "  Provider strategy: ${PHASE2_PROVIDER_POLICY_TIER:-unknown} (${PHASE2_PROVIDER_POLICY_LABEL:-unavailable}${PHASE2_PROVIDER_POLICY_REASONS:+; reasons=${PHASE2_PROVIDER_POLICY_REASONS}})"
    echo "  Stage providers: worker=${worker_provider}, reviewer_core=${reviewer_provider}, reviewer_explore=${explore_reviewer_provider}, cluster_synth=${cluster_synth_provider}, cluster_challenger=${cluster_challenger_provider}"
    echo "  Worker execution strategy: ${PHASE2_ACTIVE_WORKER_STRATEGY} (${worker_execution_reason})"
    echo "  Effective review policy: mode=${mode}, rounds=${PHASE2_MAX_REVIEW_ROUNDS}, forced_exploration=${PHASE2_ENABLE_FORCED_EXPLORATION} (max candidates=${PHASE2_MAX_EXPLORATION_CANDIDATES})"
    echo "  Effective timeout policy: revision=${PHASE2_REVISION_TIMEOUT_SECONDS}s, reviewer=${PHASE2_REVIEWER_TIMEOUT_SECONDS}s, exploration=${PHASE2_EXPLORATION_TIMEOUT_SECONDS}s"
    echo "  Worker provider: ${worker_provider} (${worker_model:-default model})"
    echo "  Reviewer core provider: ${reviewer_provider} (${reviewer_model:-default model})"
    echo "  Reviewer explore provider: ${explore_reviewer_provider} (${explore_reviewer_model:-default model})"
    echo "  Cluster providers: synth=${cluster_synth_provider} (${cluster_synth_model:-default model}), challenger=${cluster_challenger_provider} (${cluster_challenger_model:-default model})"
    append_log_marker "$errlog_deep" "phase2 resolved providers worker_provider=${worker_provider} reviewer_provider=${reviewer_provider} reviewer_explore_provider=${explore_reviewer_provider} cluster_synth_provider=${cluster_synth_provider} cluster_challenger_provider=${cluster_challenger_provider}"
    append_log_marker "$live_log_deep" "phase2 resolved providers worker=${worker_provider} reviewer_core=${reviewer_provider} reviewer_explore=${explore_reviewer_provider}"
    append_log_marker "$errlog_deep" "phase2 policy mode=${mode} adaptive_profile=${PHASE2_ADAPTIVE_DEPTH_PROFILE} signal_score=${PHASE2_ADAPTIVE_SIGNAL_SCORE} worker_strategy=${PHASE2_ACTIVE_WORKER_STRATEGY} provider_tier=${PHASE2_PROVIDER_POLICY_TIER:-unknown}"
    append_log_marker "$live_log_deep" "phase2 policy mode=${mode} worker_strategy=${PHASE2_ACTIVE_WORKER_STRATEGY} review_rounds=${PHASE2_MAX_REVIEW_ROUNDS} forced_exploration=${PHASE2_ENABLE_FORCED_EXPLORATION} provider_tier=${PHASE2_PROVIDER_POLICY_TIER:-unknown}"

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
            0 "$(root_relative_path "$current_worker_path")" "$(root_relative_path "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$current_worker_round" "$mode")")" "$(root_relative_path "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" "$current_worker_round" "$mode")")" \
            "$tp" "$fp" "$rv" "$total" "$risk" "$worker_delta_json"
        echo "  Resumed worker round ${current_worker_round}: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}"

        if [ "${existing_review_round:-0}" -gt 0 ]; then
            local resumed_review_provider resumed_review_model resumed_review_mode_hint
            last_review_path="$(phase2_review_output_path "$slug" "$existing_review_round")"
            last_review_rel="$(phase2_review_output_rel "$slug" "$existing_review_round")"
            if [ "$existing_review_round" -gt "$PHASE2_MAX_REVIEW_ROUNDS" ]; then
                existing_review_mode="explore"
            fi
            IFS='|' read -r resumed_review_provider resumed_review_model resumed_review_mode_hint <<< "$(phase2_review_runtime_meta "$last_review_path" 2>/dev/null || echo '||')"
            if [ -z "${resumed_review_mode_hint:-}" ]; then
                resumed_review_mode_hint="$existing_review_mode"
            fi
            if [ -z "${resumed_review_provider:-}" ]; then
                if [ "$resumed_review_mode_hint" = "explore" ]; then
                    resumed_review_provider="$explore_reviewer_provider"
                    resumed_review_model="$explore_reviewer_model"
                else
                    resumed_review_provider="$reviewer_provider"
                    resumed_review_model="$reviewer_model"
                fi
            fi
            review_meta="$(phase2_review_meta "$last_review_path")"
            IFS='|' read -r review_status review_finding_count review_missed_count review_material <<< "$review_meta"
            completed_review_rounds="$existing_review_round"
            final_review_status="$review_status"
            append_phase2_loop_reviewer_event "$loop_events_path" "$existing_review_round" "$resumed_review_mode_hint" "$resumed_review_provider" "$resumed_review_model" \
                0 "$(root_relative_path "$last_review_path")" "$(root_relative_path "$(phase2_loop_errlog_path "$slug" reviewer "$resumed_review_provider" "$existing_review_round" "$resumed_review_mode_hint")")" "$(root_relative_path "$(phase2_loop_live_log_path "$slug" reviewer "$resumed_review_provider" "$existing_review_round" "$resumed_review_mode_hint")")" \
                "$review_status" "$review_finding_count" "$review_missed_count" "$review_material"
            echo "  Resumed reviewer ${resumed_review_mode_hint} round ${existing_review_round}: ${review_status} | finding_reviews=${review_finding_count}, missed_findings=${review_missed_count}"
            if [ "$resumed_review_mode_hint" = "explore" ]; then
                forced_exploration_already_completed=true
                if [ "$review_status" = "stable" ]; then
                    stop_reason="forced_exploration_stable_no_new_candidates"
                fi
            elif [ "$resumed_review_mode_hint" = "terminal_core" ] && [ "$review_status" = "stable" ]; then
                terminal_core_review_ready=true
            fi
        fi
    else
        echo "  Worker round 1 (${mode}): ${worker_provider}$(phase2_progress_suffix 5)"
        append_log_marker "$errlog_deep" "worker round start round=1 mode=${mode} provider=${worker_provider}"
        append_log_marker "$live_log_deep" "worker round start round=1 mode=${mode} provider=${worker_provider}"
        write_phase2_state "$state_path" "$slug" "worker" "running" "worker" 1 "$worker_provider" "$worker_model" "" "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" 1 "$mode")" "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" 1 "$mode")" \
            mode "$mode"
        if ! run_phase2_worker_round "$slug" 1 "$mode" "$worker_provider"; then
            stop_reason="worker_round_failed"
            execution_status="failed"
            loop_finished_ts="$(date +%s)"
            total_runtime_seconds=$((loop_finished_ts - loop_started_ts))
            write_phase2_state "$state_path" "$slug" "worker" "failed" "worker" 1 "$worker_provider" "$worker_model" "" "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" 1 "$mode")" "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" 1 "$mode")" \
                mode "$mode"
            write_phase2_loop_summary "$loop_summary_path" "$loop_events_path" \
                "$slug" "$mode" "$worker_provider" "$reviewer_provider" "$worker_model" "$reviewer_model" \
                "$PHASE2_MAX_REVIEW_ROUNDS" 0 0 "$final_review_status" "$stop_reason" "$execution_status" "$total_runtime_seconds" \
                "reports/phase2/${slug}-phase2.json" "" "" "" "" "" "" "" "$PHASE2_ENABLE_FORCED_EXPLORATION" "$PHASE2_MAX_EXPLORATION_CANDIDATES"
            log_error_block "Phase 2 worker round failed" \
                "slug" "$slug" \
                "round" "1" \
                "provider" "$worker_provider" \
                "reason" "$(summarize_provider_errlog "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" 1 "$mode")")" \
                "log" "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" 1 "$mode")" \
                "live_log" "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" 1 "$mode")"
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
            "$worker_duration" "$(root_relative_path "$current_worker_path")" "$(root_relative_path "$initial_worker_errlog")" "$(root_relative_path "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" 1 "$mode")")" \
            "$tp" "$fp" "$rv" "$total" "$risk" "$worker_delta_json"
        echo "  Worker round 1 results: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}$(phase2_progress_suffix 35)"
        append_log_marker "$errlog_deep" "worker round done round=1 mode=${mode} provider=${worker_provider} tp=${tp} fp=${fp} review=${rv} risk=${risk}"
        append_log_marker "$live_log_deep" "worker round done round=1 mode=${mode} provider=${worker_provider}"
        write_phase2_state "$state_path" "$slug" "worker" "completed" "worker" 1 "$worker_provider" "$worker_model" "$(root_relative_path "$current_worker_path")" "$initial_worker_errlog" "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" 1 "$mode")" \
            tp "$tp" fp "$fp" review "$rv" risk "$risk"
    fi

    if [ "$resume_active" = true ] \
        && [ "$completed_review_rounds" -eq "$current_worker_round" ] \
        && [ "$final_review_status" != "stable" ]; then
        next_worker_round=$((current_worker_round + 1))
        echo "  Resume pending worker revision round ${next_worker_round}: ${worker_provider}"
        prev_worker_path="$current_worker_path"
        prev_worker_rel="$current_worker_rel"
        write_phase2_state "$state_path" "$slug" "worker" "running" "worker" "$next_worker_round" "$worker_provider" "$worker_model" "" "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$next_worker_round" revision)" "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" "$next_worker_round" revision)" \
            mode "revision" previous_worker_round "$current_worker_round" review_round "$completed_review_rounds"
        if ! run_phase2_worker_round "$slug" "$next_worker_round" "revision" "$worker_provider" "$current_worker_rel" "$last_review_rel"; then
            stop_reason="worker_revision_failed"
            execution_status="failed"
            loop_finished_ts="$(date +%s)"
            total_runtime_seconds=$((loop_finished_ts - loop_started_ts))
            write_phase2_state "$state_path" "$slug" "worker" "failed" "worker" "$next_worker_round" "$worker_provider" "$worker_model" "" "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$next_worker_round" revision)" "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" "$next_worker_round" revision)" \
                mode "revision" stop_reason "$stop_reason" previous_worker_round "$current_worker_round" review_round "$completed_review_rounds"
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
                "log" "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$next_worker_round" revision)" \
                "live_log" "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" "$next_worker_round" revision)"
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
            "$worker_duration" "$(root_relative_path "$current_worker_path")" "$(root_relative_path "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$current_worker_round" revision)")" "$(root_relative_path "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" "$current_worker_round" revision)")" \
            "$tp" "$fp" "$rv" "$total" "$risk" "$worker_delta_json"
        echo "  Worker revision ${current_worker_round} results: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}$(phase2_progress_suffix 82)"
        write_phase2_state "$state_path" "$slug" "worker" "completed" "worker" "$current_worker_round" "$worker_provider" "$worker_model" "$(root_relative_path "$current_worker_path")" "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$current_worker_round" revision)" "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" "$current_worker_round" revision)" \
            mode "revision" tp "$tp" fp "$fp" review "$rv" risk "$risk"
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
                "log" "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$next_worker_round" expansion)" \
                "live_log" "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" "$next_worker_round" expansion)"
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
            "$worker_duration" "$(root_relative_path "$current_worker_path")" "$(root_relative_path "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$current_worker_round" expansion)")" "$(root_relative_path "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" "$current_worker_round" expansion)")" \
            "$tp" "$fp" "$rv" "$total" "$risk" "$worker_delta_json"
        stop_reason="forced_exploration_completed"
        echo "  Worker expansion ${current_worker_round} results: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}$(phase2_progress_suffix 97)"
    fi

    review_round_start=1
    if [ "$completed_review_rounds" -gt 0 ]; then
        review_round_start=$((completed_review_rounds + 1))
    fi

    for ((review_round=review_round_start; review_round<=PHASE2_MAX_REVIEW_ROUNDS; review_round++)); do
        echo "  Reviewer core round ${review_round}: ${reviewer_provider}$(phase2_progress_suffix 40)"
        append_log_marker "$errlog_deep" "reviewer round start round=${review_round} mode=core provider=${reviewer_provider}"
        append_log_marker "$live_log_deep" "reviewer round start round=${review_round} mode=core provider=${reviewer_provider}"
        write_phase2_state "$state_path" "$slug" "reviewer" "running" "reviewer" "$review_round" "$reviewer_provider" "$reviewer_model" "" "$(phase2_loop_errlog_path "$slug" reviewer "$reviewer_provider" "$review_round" core)" "$(phase2_loop_live_log_path "$slug" reviewer "$reviewer_provider" "$review_round" core)" \
            mode "core"
        if ! run_phase2_review_round "$slug" "$review_round" "$reviewer_provider" "$current_worker_rel" "core"; then
            stop_reason="reviewer_round_failed"
            execution_status="failed"
            loop_finished_ts="$(date +%s)"
            total_runtime_seconds=$((loop_finished_ts - loop_started_ts))
            write_phase2_state "$state_path" "$slug" "reviewer" "failed" "reviewer" "$review_round" "$reviewer_provider" "$reviewer_model" "" "$(phase2_loop_errlog_path "$slug" reviewer "$reviewer_provider" "$review_round" core)" "$(phase2_loop_live_log_path "$slug" reviewer "$reviewer_provider" "$review_round" core)" \
                mode "core"
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
                "log" "$(phase2_loop_errlog_path "$slug" reviewer "$reviewer_provider" "$review_round" core)" \
                "live_log" "$(phase2_loop_live_log_path "$slug" reviewer "$reviewer_provider" "$review_round" core)"
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
            "$reviewer_duration" "$(root_relative_path "$last_review_path")" "$(root_relative_path "$(phase2_loop_errlog_path "$slug" reviewer "$reviewer_provider" "$review_round" core)")" "$(root_relative_path "$(phase2_loop_live_log_path "$slug" reviewer "$reviewer_provider" "$review_round" core)")" \
            "$review_status" "$review_finding_count" "$review_missed_count" "$review_material"
        echo "  Reviewer core round ${review_round} verdict: ${review_status} | finding_reviews=${review_finding_count}, missed_findings=${review_missed_count}$(phase2_progress_suffix 70)"
        append_log_marker "$errlog_deep" "reviewer round done round=${review_round} mode=core provider=${reviewer_provider} status=${review_status} finding_reviews=${review_finding_count} missed=${review_missed_count}"
        append_log_marker "$live_log_deep" "reviewer round done round=${review_round} mode=core provider=${reviewer_provider} status=${review_status}"
        write_phase2_state "$state_path" "$slug" "reviewer" "completed" "reviewer" "$review_round" "$reviewer_provider" "$reviewer_model" "$(root_relative_path "$last_review_path")" "$(phase2_loop_errlog_path "$slug" reviewer "$reviewer_provider" "$review_round" core)" "$(phase2_loop_live_log_path "$slug" reviewer "$reviewer_provider" "$review_round" core)" \
            mode "core" review_status "$review_status" finding_reviews "$review_finding_count" missed_findings "$review_missed_count"

        if [ "$review_status" = "stable" ]; then
            stop_reason="reviewer_marked_stable"
            break
        fi

        next_worker_round=$((current_worker_round + 1))
        echo "  Worker revision round ${next_worker_round}: ${worker_provider}$(phase2_progress_suffix 72)"
        prev_worker_path="$current_worker_path"
        prev_worker_rel="$current_worker_rel"
        write_phase2_state "$state_path" "$slug" "worker" "running" "worker" "$next_worker_round" "$worker_provider" "$worker_model" "" "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$next_worker_round" revision)" "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" "$next_worker_round" revision)" \
            mode "revision" previous_worker_round "$current_worker_round" review_round "$completed_review_rounds"
        if ! run_phase2_worker_round "$slug" "$next_worker_round" "revision" "$worker_provider" "$current_worker_rel" "$last_review_rel"; then
            stop_reason="worker_revision_failed"
            execution_status="failed"
            loop_finished_ts="$(date +%s)"
            total_runtime_seconds=$((loop_finished_ts - loop_started_ts))
            write_phase2_state "$state_path" "$slug" "worker" "failed" "worker" "$next_worker_round" "$worker_provider" "$worker_model" "" "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$next_worker_round" revision)" "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" "$next_worker_round" revision)" \
                mode "revision" stop_reason "$stop_reason" previous_worker_round "$current_worker_round" review_round "$completed_review_rounds"
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
                "log" "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$next_worker_round" revision)" \
                "live_log" "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" "$next_worker_round" revision)"
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
            "$worker_duration" "$(root_relative_path "$current_worker_path")" "$(root_relative_path "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$current_worker_round" revision)")" "$(root_relative_path "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" "$current_worker_round" revision)")" \
            "$tp" "$fp" "$rv" "$total" "$risk" "$worker_delta_json"
        echo "  Worker revision ${current_worker_round} results: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}$(phase2_progress_suffix 82)"
        write_phase2_state "$state_path" "$slug" "worker" "completed" "worker" "$current_worker_round" "$worker_provider" "$worker_model" "$(root_relative_path "$current_worker_path")" "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$current_worker_round" revision)" "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" "$current_worker_round" revision)" \
            mode "revision" tp "$tp" fp "$fp" review "$rv" risk "$risk"
    done

    if [ "$execution_status" = "success" ] && [ -f "$provider_policy_path" ] && [ -f "$current_worker_path" ] && [ -n "$last_review_path" ] && [ -f "$last_review_path" ]; then
        local previous_provider_tier dispatch_path
        previous_provider_tier="${PHASE2_PROVIDER_POLICY_TIER:-}"
        dispatch_path="$(phase2_dispatch_path "$slug")"
        if phase2_provider_policy_apply_postreview "$provider_policy_path" "$current_worker_path" "$last_review_path"; then
            eval "$(phase2_provider_policy_export_assignments "$provider_policy_path")"
            if [ "$PHASE2_EXPLORE_PROVIDER_FROM_ENV" != true ]; then
                explore_reviewer_provider="${PHASE2_PROVIDER_POLICY_REVIEWER_EXPLORE:-$explore_reviewer_provider}"
            fi
            if [ "$PHASE2_CLUSTER_SYNTH_PROVIDER_FROM_ENV" != true ]; then
                cluster_synth_provider="${PHASE2_PROVIDER_POLICY_CLUSTER_SYNTH:-$cluster_synth_provider}"
            fi
            if [ "$PHASE2_CLUSTER_CHALLENGER_PROVIDER_FROM_ENV" != true ]; then
                cluster_challenger_provider="${PHASE2_PROVIDER_POLICY_CLUSTER_CHALLENGER:-$cluster_challenger_provider}"
            fi
            PHASE2_EXPLORE_PROVIDER="$explore_reviewer_provider"
            PHASE2_CLUSTER_SYNTH_PROVIDER="$cluster_synth_provider"
            PHASE2_CLUSTER_CHALLENGER_PROVIDER="$cluster_challenger_provider"
            explore_reviewer_model="$(phase2_stage_model reviewer_explore "$explore_reviewer_provider")"
            cluster_synth_model="$(phase2_stage_model cluster_synth "$cluster_synth_provider")"
            cluster_challenger_model="$(phase2_stage_model cluster_challenger "$cluster_challenger_provider")"
            phase2_dispatch_apply_provider_overrides "$dispatch_path" "$cluster_synth_provider" "${cluster_synth_model:-}" "$cluster_challenger_provider" "${cluster_challenger_model:-}"
            if [ "${PHASE2_PROVIDER_POLICY_TIER:-}" != "${previous_provider_tier:-}" ]; then
                echo "  Provider strategy escalation: ${previous_provider_tier:-unknown} -> ${PHASE2_PROVIDER_POLICY_TIER:-unknown} (${PHASE2_PROVIDER_POLICY_REASONS:-no_reason_recorded})"
            else
                echo "  Provider strategy confirmed: ${PHASE2_PROVIDER_POLICY_TIER:-unknown} (${PHASE2_PROVIDER_POLICY_REASONS:-no_reason_recorded})"
            fi
            echo "  Updated selective stages: reviewer_explore=${explore_reviewer_provider}, cluster_challenger=${cluster_challenger_provider}"
            append_log_marker "$errlog_deep" "provider policy updated tier=${PHASE2_PROVIDER_POLICY_TIER:-unknown} explore=${explore_reviewer_provider} cluster_challenger=${cluster_challenger_provider}"
            append_log_marker "$live_log_deep" "provider policy updated tier=${PHASE2_PROVIDER_POLICY_TIER:-unknown}"
        else
            log_warn "Post-review provider policy update failed for ${slug}; keeping pre-Phase-2 stage providers."
        fi
    fi

    local core_unresolved_review_items core_field_fix_review_items
    core_unresolved_review_items=0
    core_field_fix_review_items=0
    if [ -n "${last_review_path:-}" ] && [ -f "$last_review_path" ]; then
        IFS='|' read -r core_unresolved_review_items core_field_fix_review_items <<< "$(phase2_review_followup_counts "$last_review_path")"
    fi

    if [ "$execution_status" = "success" ] \
        && [ "$current_worker_round" -gt "$completed_review_rounds" ] \
        && phase2_worker_terminally_closed "$current_worker_path"; then
        core_unresolved_review_items=0
        final_review_status="terminally_closed"
        forced_exploration_already_completed=true
        append_log_marker "$errlog_deep" "resume detected prior terminal closure on worker_round=${current_worker_round}; skipping additional terminal_core rerun"
        append_log_marker "$live_log_deep" "resume detected prior terminal closure on worker_round=${current_worker_round}"
        echo "  Resumed worker round ${current_worker_round} already reflects terminal closure; skipping additional terminal_core."
    fi

    if [ "$execution_status" = "success" ] && [ "$terminal_core_review_ready" = true ] && [ "$current_worker_round" -eq "$completed_review_rounds" ]; then
        local resumed_closure_round resumed_closure_provider resumed_closure_model
        local resumed_closure_output_path resumed_closure_output_rel resumed_closure_raw_path
        local resumed_closure_errlog resumed_closure_live_log resumed_closure_started_ts resumed_closure_finished_ts resumed_closure_duration
        resumed_closure_round=$((current_worker_round + 1))
        resumed_closure_provider="deterministic"
        resumed_closure_model="phase2-terminal-closure-v2"
        resumed_closure_output_path="$(phase2_worker_output_path "$slug" "$resumed_closure_round")"
        resumed_closure_output_rel="$(phase2_worker_output_rel "$slug" "$resumed_closure_round")"
        resumed_closure_raw_path="$(phase2_worker_raw_path "$slug" "$resumed_closure_round")"
        resumed_closure_errlog="$(phase2_loop_errlog_path "$slug" worker "$resumed_closure_provider" "$resumed_closure_round" terminal_closure)"
        resumed_closure_live_log="$(phase2_loop_live_log_path "$slug" worker "$resumed_closure_provider" "$resumed_closure_round" terminal_closure)"

        echo "  Resume pending terminal closure round ${resumed_closure_round}: apply reviewer closure decisions$(phase2_progress_suffix 89)"
        write_phase2_state "$state_path" "$slug" "worker" "running" "worker" "$resumed_closure_round" "$resumed_closure_provider" "$resumed_closure_model" "$(root_relative_path "$resumed_closure_output_path")" "$resumed_closure_errlog" "$resumed_closure_live_log" \
            mode "terminal_closure" unresolved_review_items 0
        resumed_closure_started_ts="$(date +%s)"
        prev_worker_path="$current_worker_path"
        prev_worker_rel="$current_worker_rel"
        if apply_phase2_terminal_closure "$slug" "$current_worker_path" "$last_review_path" "$resumed_closure_output_path" "$resumed_closure_raw_path" "$resumed_closure_errlog"; then
            resumed_closure_finished_ts="$(date +%s)"
            resumed_closure_duration=$((resumed_closure_finished_ts - resumed_closure_started_ts))
            current_worker_round="$resumed_closure_round"
            current_worker_path="$resumed_closure_output_path"
            current_worker_rel="$resumed_closure_output_rel"
            current_worker_raw="$resumed_closure_raw_path"
            loop_errlogs+=("$resumed_closure_errlog")
            counts="$(phase2_counts "$current_worker_path")"
            IFS='|' read -r tp fp rv total risk <<< "$counts"
            worker_delta_json="$(phase2_transition_meta "$prev_worker_path" "$current_worker_path")"
            append_phase2_loop_worker_event "$loop_events_path" "$current_worker_round" "terminal_closure" "$resumed_closure_provider" "$resumed_closure_model" \
                "$resumed_closure_duration" "$(root_relative_path "$current_worker_path")" "$(root_relative_path "$resumed_closure_errlog")" "$(root_relative_path "$resumed_closure_live_log")" \
                "$tp" "$fp" "$rv" "$total" "$risk" "$worker_delta_json"
            final_review_status="terminally_closed"
            forced_exploration_already_completed=true
            stop_reason="terminal_core_closure_applied"
            echo "  Terminal closure ${current_worker_round} results: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}$(phase2_progress_suffix 92)"
            write_phase2_state "$state_path" "$slug" "worker" "completed" "worker" "$current_worker_round" "$resumed_closure_provider" "$resumed_closure_model" "$(root_relative_path "$current_worker_path")" "$resumed_closure_errlog" "$resumed_closure_live_log" \
                mode "terminal_closure" tp "$tp" fp "$fp" review "$rv" risk "$risk" unresolved_review_items 0
        else
            execution_status="failed"
            stop_reason="terminal_core_closure_failed"
            write_phase2_state "$state_path" "$slug" "worker" "failed" "worker" "$resumed_closure_round" "$resumed_closure_provider" "$resumed_closure_model" "$prev_worker_rel" "$resumed_closure_errlog" "$resumed_closure_live_log" \
                mode "terminal_closure" reason "$stop_reason" unresolved_review_items 0
            log_error "Terminal closure failed while resuming a completed terminal_core review; cannot publish canonical Phase 2."
        fi
    fi

    if [ "$execution_status" = "success" ] && [ "$current_worker_round" -gt "$completed_review_rounds" ] && [ "${core_unresolved_review_items:-0}" -gt 0 ]; then
            local terminal_review_round terminal_review_status terminal_review_finding_count terminal_review_missed_count terminal_review_material
            local terminal_review_errlog terminal_review_live_log terminal_review_duration
            local closure_round closure_provider closure_model closure_errlog closure_live_log
            local closure_output_path closure_output_rel closure_raw_path closure_started_ts
            local closure_finished_ts closure_duration
            local terminal_source_review_path terminal_source_review_rel terminal_review_failed=false
            terminal_review_round=$((completed_review_rounds + 1))
            terminal_source_review_path="$last_review_path"
            terminal_source_review_rel="$last_review_rel"
            echo "  Reviewer terminal core round ${terminal_review_round}: ${reviewer_provider}$(phase2_progress_suffix 84)"
            append_log_marker "$errlog_deep" "reviewer round start round=${terminal_review_round} mode=terminal_core provider=${reviewer_provider}"
            append_log_marker "$live_log_deep" "reviewer round start round=${terminal_review_round} mode=terminal_core provider=${reviewer_provider}"
            terminal_review_errlog="$(phase2_loop_errlog_path "$slug" reviewer "$reviewer_provider" "$terminal_review_round" terminal_core)"
            terminal_review_live_log="$(phase2_loop_live_log_path "$slug" reviewer "$reviewer_provider" "$terminal_review_round" terminal_core)"
            write_phase2_state "$state_path" "$slug" "reviewer" "running" "reviewer" "$terminal_review_round" "$reviewer_provider" "$reviewer_model" "" "$terminal_review_errlog" "$terminal_review_live_log" \
                mode "terminal_core" source_review_round "$completed_review_rounds" unresolved_review_items "$core_unresolved_review_items"
            if run_phase2_review_round "$slug" "$terminal_review_round" "$reviewer_provider" "$current_worker_rel" "terminal_core" "$terminal_source_review_rel"; then
                last_review_path="$(phase2_review_output_path "$slug" "$terminal_review_round")"
                last_review_rel="$(phase2_review_output_rel "$slug" "$terminal_review_round")"
                loop_errlogs+=("$terminal_review_errlog")
                review_meta="$(phase2_review_meta "$last_review_path")"
                IFS='|' read -r terminal_review_status terminal_review_finding_count terminal_review_missed_count terminal_review_material <<< "$review_meta"
                completed_review_rounds="$terminal_review_round"
                final_review_status="$terminal_review_status"
                terminal_review_duration="${PHASE2_LAST_DURATION_SECONDS:-0}"
                append_phase2_loop_reviewer_event "$loop_events_path" "$terminal_review_round" "terminal_core" "$reviewer_provider" "$reviewer_model" \
                    "$terminal_review_duration" "$(root_relative_path "$last_review_path")" "$(root_relative_path "$terminal_review_errlog")" "$(root_relative_path "$terminal_review_live_log")" \
                    "$terminal_review_status" "$terminal_review_finding_count" "$terminal_review_missed_count" "$terminal_review_material"
                echo "  Reviewer terminal core round ${terminal_review_round} verdict: ${terminal_review_status} | finding_reviews=${terminal_review_finding_count}, missed_findings=${terminal_review_missed_count}$(phase2_progress_suffix 89)"
                append_log_marker "$errlog_deep" "reviewer round done round=${terminal_review_round} mode=terminal_core provider=${reviewer_provider} status=${terminal_review_status} finding_reviews=${terminal_review_finding_count}"
                append_log_marker "$live_log_deep" "reviewer round done round=${terminal_review_round} mode=terminal_core provider=${reviewer_provider} status=${terminal_review_status}"
                write_phase2_state "$state_path" "$slug" "reviewer" "completed" "reviewer" "$terminal_review_round" "$reviewer_provider" "$reviewer_model" "$(root_relative_path "$last_review_path")" "$terminal_review_errlog" "$terminal_review_live_log" \
                    mode "terminal_core" review_status "$terminal_review_status" finding_reviews "$terminal_review_finding_count" missed_findings "$terminal_review_missed_count" unresolved_review_items 0
                terminal_core_review_ready=true
            else
                terminal_review_failed=true
                append_log_marker "$errlog_deep" "reviewer round failed round=${terminal_review_round} mode=terminal_core provider=${reviewer_provider}"
                append_log_marker "$live_log_deep" "reviewer round failed round=${terminal_review_round} mode=terminal_core provider=${reviewer_provider}"
                log_warn "Terminal core reviewer failed; attempting deterministic fallback closure from the last core review."
            fi

            closure_round=$((current_worker_round + 1))
            closure_provider="deterministic"
            closure_model="phase2-terminal-closure-v2"
            closure_output_path="$(phase2_worker_output_path "$slug" "$closure_round")"
            closure_output_rel="$(phase2_worker_output_rel "$slug" "$closure_round")"
            closure_raw_path="$(phase2_worker_raw_path "$slug" "$closure_round")"
            closure_errlog="$(phase2_loop_errlog_path "$slug" worker "$closure_provider" "$closure_round" terminal_closure)"
            closure_live_log="$(phase2_loop_live_log_path "$slug" worker "$closure_provider" "$closure_round" terminal_closure)"

            echo "  Terminal closure round ${closure_round}: apply reviewer closure decisions$(phase2_progress_suffix 89)"
            append_log_marker "$errlog_deep" "terminal closure start round=${closure_round} source_worker_round=${current_worker_round} source_review_round=${completed_review_rounds} unresolved_review_items=${core_unresolved_review_items} terminal_review_ready=${terminal_core_review_ready}"
            append_log_marker "$live_log_deep" "terminal closure start round=${closure_round} unresolved_review_items=${core_unresolved_review_items}"
            write_phase2_state "$state_path" "$slug" "worker" "running" "worker" "$closure_round" "$closure_provider" "$closure_model" "$(root_relative_path "$closure_output_path")" "$closure_errlog" "$closure_live_log" \
                mode "terminal_closure" unresolved_review_items "$core_unresolved_review_items"
            closure_started_ts="$(date +%s)"
            prev_worker_path="$current_worker_path"
            prev_worker_rel="$current_worker_rel"
            if apply_phase2_terminal_closure "$slug" "$current_worker_path" "${last_review_path:-$terminal_source_review_path}" "$closure_output_path" "$closure_raw_path" "$closure_errlog"; then
                closure_finished_ts="$(date +%s)"
                closure_duration=$((closure_finished_ts - closure_started_ts))
                current_worker_round="$closure_round"
                current_worker_path="$closure_output_path"
                current_worker_rel="$closure_output_rel"
                current_worker_raw="$closure_raw_path"
                loop_errlogs+=("$closure_errlog")
                counts="$(phase2_counts "$current_worker_path")"
                IFS='|' read -r tp fp rv total risk <<< "$counts"
                worker_delta_json="$(phase2_transition_meta "$prev_worker_path" "$current_worker_path")"
                append_phase2_loop_worker_event "$loop_events_path" "$current_worker_round" "terminal_closure" "$closure_provider" "$closure_model" \
                    "$closure_duration" "$(root_relative_path "$current_worker_path")" "$(root_relative_path "$closure_errlog")" "$(root_relative_path "$closure_live_log")" \
                    "$tp" "$fp" "$rv" "$total" "$risk" "$worker_delta_json"
                final_review_status="terminally_closed"
                forced_exploration_already_completed=true
                if [ "$terminal_review_failed" = true ]; then
                    stop_reason="terminal_core_reviewer_failed_fallback_closure_applied"
                else
                    stop_reason="terminal_core_closure_applied"
                fi
                echo "  Terminal closure ${current_worker_round} results: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}$(phase2_progress_suffix 92)"
                append_log_marker "$errlog_deep" "terminal closure done round=${current_worker_round} stop_reason=${stop_reason} tp=${tp} fp=${fp} review=${rv} risk=${risk}"
                append_log_marker "$live_log_deep" "terminal closure done round=${current_worker_round} stop_reason=${stop_reason}"
                write_phase2_state "$state_path" "$slug" "worker" "completed" "worker" "$current_worker_round" "$closure_provider" "$closure_model" "$(root_relative_path "$current_worker_path")" "$closure_errlog" "$closure_live_log" \
                    mode "terminal_closure" tp "$tp" fp "$fp" review "$rv" risk "$risk" unresolved_review_items 0
            else
                execution_status="failed"
                if [ "$terminal_review_failed" = true ]; then
                    stop_reason="terminal_core_reviewer_failed"
                else
                    stop_reason="terminal_core_closure_failed"
                fi
                append_log_marker "$errlog_deep" "terminal closure failed round=${closure_round} stop_reason=${stop_reason}"
                append_log_marker "$live_log_deep" "terminal closure failed round=${closure_round} stop_reason=${stop_reason}"
                write_phase2_state "$state_path" "$slug" "worker" "failed" "worker" "$closure_round" "$closure_provider" "$closure_model" "$prev_worker_rel" "$closure_errlog" "$closure_live_log" \
                    mode "terminal_closure" reason "$stop_reason" unresolved_review_items "$core_unresolved_review_items"
                log_error "Terminal closure failed after worker revision ${current_worker_round}; cannot publish canonical Phase 2."
            fi
    elif [ "$execution_status" = "success" ] && [ "$PHASE2_ENABLE_FORCED_EXPLORATION" = true ] && [ "$forced_exploration_already_completed" != true ]; then
            local explore_review_round
            local explore_review_status explore_review_finding_count explore_review_missed_count explore_review_material
            local explore_reviewer_duration
            local exploration_errlog
            explore_review_round=$((completed_review_rounds + 1))
            echo "  Reviewer explore round ${explore_review_round}: ${explore_reviewer_provider}$(phase2_progress_suffix 92)"
            append_log_marker "$errlog_deep" "reviewer round start round=${explore_review_round} mode=explore provider=${explore_reviewer_provider}"
            append_log_marker "$live_log_deep" "reviewer round start round=${explore_review_round} mode=explore provider=${explore_reviewer_provider}"
            write_phase2_state "$state_path" "$slug" "reviewer" "running" "reviewer" "$explore_review_round" "$explore_reviewer_provider" "$explore_reviewer_model" "" "$(phase2_loop_errlog_path "$slug" reviewer "$explore_reviewer_provider" "$explore_review_round" explore)" "$(phase2_loop_live_log_path "$slug" reviewer "$explore_reviewer_provider" "$explore_review_round" explore)" \
                mode "explore"
            if run_phase2_review_round "$slug" "$explore_review_round" "$explore_reviewer_provider" "$current_worker_rel" "explore"; then
            last_review_path="$(phase2_review_output_path "$slug" "$explore_review_round")"
            last_review_rel="$(phase2_review_output_rel "$slug" "$explore_review_round")"
            exploration_errlog="$(phase2_loop_errlog_path "$slug" reviewer "$explore_reviewer_provider" "$explore_review_round" explore)"
            loop_errlogs+=("$exploration_errlog")
            review_meta="$(phase2_review_meta "$last_review_path")"
            IFS='|' read -r explore_review_status explore_review_finding_count explore_review_missed_count explore_review_material <<< "$review_meta"
            completed_review_rounds="$explore_review_round"
            final_review_status="$explore_review_status"
            explore_reviewer_duration="${PHASE2_LAST_DURATION_SECONDS:-0}"
            append_phase2_loop_reviewer_event "$loop_events_path" "$explore_review_round" "explore" "$explore_reviewer_provider" "$explore_reviewer_model" \
                "$explore_reviewer_duration" "$(root_relative_path "$last_review_path")" "$(root_relative_path "$exploration_errlog")" "$(root_relative_path "$(phase2_loop_live_log_path "$slug" reviewer "$explore_reviewer_provider" "$explore_review_round" explore)")" \
                "$explore_review_status" "$explore_review_finding_count" "$explore_review_missed_count" "$explore_review_material"
            echo "  Reviewer explore verdict: ${explore_review_status} | missed_findings=${explore_review_missed_count}$(phase2_progress_suffix 95)"
            append_log_marker "$errlog_deep" "reviewer round done round=${explore_review_round} mode=explore provider=${explore_reviewer_provider} status=${explore_review_status} missed=${explore_review_missed_count}"
            append_log_marker "$live_log_deep" "reviewer round done round=${explore_review_round} mode=explore provider=${explore_reviewer_provider} status=${explore_review_status}"
            write_phase2_state "$state_path" "$slug" "reviewer" "completed" "reviewer" "$explore_review_round" "$explore_reviewer_provider" "$explore_reviewer_model" "$(root_relative_path "$last_review_path")" "$exploration_errlog" "$(phase2_loop_live_log_path "$slug" reviewer "$explore_reviewer_provider" "$explore_review_round" explore)" \
                mode "explore" review_status "$explore_review_status" missed_findings "$explore_review_missed_count"

            if [ "$explore_review_status" != "stable" ]; then
                next_worker_round=$((current_worker_round + 1))
                echo "  Worker expansion round ${next_worker_round}: ${worker_provider}$(phase2_progress_suffix 95)"
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
                        "$worker_duration" "$(root_relative_path "$current_worker_path")" "$(root_relative_path "$(phase2_loop_errlog_path "$slug" worker "$worker_provider" "$current_worker_round" expansion)")" "$(root_relative_path "$(phase2_loop_live_log_path "$slug" worker "$worker_provider" "$current_worker_round" expansion)")" \
                        "$tp" "$fp" "$rv" "$total" "$risk" "$worker_delta_json"
                    stop_reason="forced_exploration_completed"
                    echo "  Worker expansion ${current_worker_round} results: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}$(phase2_progress_suffix 97)"
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

    local local_phase2_path cluster_errlog final_phase2_output final_phase2_output_rel canonical_phase2_source canonical_published
    local_phase2_path="$(phase2_local_output_path "$slug")"
    cluster_errlog="$(phase2_cluster_errlog_path "$slug")"
    canonical_phase2_source="not_published"
    canonical_published=false

    cp -f "$current_worker_path" "$local_phase2_path"
    rm -f "$output" "$raw_output"
    cp -f "$current_worker_path" "$(phase2_output_path "$slug" "$worker_provider")" 2>/dev/null || true
    cp -f "$current_worker_raw" "$(phase2_raw_path "$slug" "$worker_provider")" 2>/dev/null || true

    if [ "$execution_status" = "success" ]; then
        append_log_marker "$errlog_deep" "consensus-authoritative publish start slug=${slug}"
        append_log_marker "$live_log_deep" "consensus-authoritative publish start slug=${slug}"
        echo "  Cluster consensus publish: synth -> challenge -> consensus$(phase2_progress_suffix 97)"
        write_phase2_state "$state_path" "$slug" "cluster" "running" "cluster" 0 "" "" "$(root_relative_path "$local_phase2_path")" "$cluster_errlog" "$(phase2_cluster_live_log_path "$slug")"
        if run_phase2_cluster_pipeline "$slug" "$local_phase2_path" "$cluster_errlog"; then
            canonical_phase2_source="consensus"
            canonical_published=true
            append_log_marker "$errlog_deep" "consensus-authoritative publish finished slug=${slug} status=success"
            append_log_marker "$live_log_deep" "consensus-authoritative publish finished slug=${slug} status=success"
            write_phase2_state "$state_path" "$slug" "cluster" "completed" "cluster" 0 "" "" "reports/phase2/${slug}-phase2.json" "$cluster_errlog" "$(phase2_cluster_live_log_path "$slug")"
        else
            execution_status="failed"
            stop_reason="cluster_pipeline_failed"
            rm -f "$output" "$raw_output"
            append_log_marker "$errlog_deep" "consensus-authoritative publish finished slug=${slug} status=failed"
            append_log_marker "$live_log_deep" "consensus-authoritative publish finished slug=${slug} status=failed"
            write_phase2_state "$state_path" "$slug" "cluster" "failed" "cluster" 0 "" "" "$(root_relative_path "$local_phase2_path")" "$cluster_errlog" "$(phase2_cluster_live_log_path "$slug")" \
                reason "cluster_pipeline_failed"
        fi
        if [ -f "$cluster_errlog" ]; then
            loop_errlogs+=("$cluster_errlog")
        fi
    else
        append_log_marker "$errlog_deep" "consensus-authoritative publish skipped slug=${slug} execution_status=${execution_status}"
        append_log_marker "$live_log_deep" "consensus-authoritative publish skipped slug=${slug} execution_status=${execution_status}"
    fi

    if [ "$mode" = "quick" ] && [ -f "$initial_worker_errlog" ]; then
        cp -f "$initial_worker_errlog" "$errlog_quick" 2>/dev/null || true
        cp -f "$(live_log_path_from_errlog "$initial_worker_errlog")" "$live_log_quick" 2>/dev/null || true
    fi

    final_phase2_output="$output"
    if [ ! -f "$final_phase2_output" ]; then
        final_phase2_output="$local_phase2_path"
    fi
    final_phase2_output_rel="$(root_relative_path "$final_phase2_output")"
    counts="$(phase2_counts "$final_phase2_output")"
    IFS='|' read -r tp fp rv total risk <<< "$counts"
    echo "  Final Phase 2 results: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}$(phase2_progress_suffix 100)"
    echo "  Phase 2 final artifact source: ${canonical_phase2_source}"
    if [ -f "$output" ]; then
        echo "  Canonical output: ${output}"
    else
        echo "  Canonical output: not published (local-only at ${local_phase2_path})"
    fi
    if [ -f "$raw_output" ]; then
        echo "  Canonical raw output: ${raw_output}"
    else
        echo "  Canonical raw output: not published"
    fi
    local final_trust_state final_degradation_signals
    IFS='|' read -r final_trust_state final_degradation_signals <<< "$(phase2_trust_summary "$execution_status" "$final_phase2_output" "$canonical_published")"
    append_log_marker "$errlog_deep" "phase2 envelope done slug=${slug} status=${execution_status} trust_state=${final_trust_state} stop_reason=${stop_reason} tp=${tp} fp=${fp} review=${rv} risk=${risk}"
    append_log_marker "$live_log_deep" "phase2 envelope done slug=${slug} status=${execution_status} trust_state=${final_trust_state} stop_reason=${stop_reason}"
    write_phase2_state "$state_path" "$slug" "done" "$execution_status" "" 0 "" "" "$final_phase2_output_rel" "$errlog_deep" "$live_log_deep" \
        stop_reason "$stop_reason" tp "$tp" fp "$fp" review "$rv" risk "$risk" canonical_published "$canonical_published" canonical_source "$canonical_phase2_source" \
        trust_state "$final_trust_state" degradation_signals "$final_degradation_signals"

    log_section "Done: ${slug}"
    if [ "$execution_status" = "success" ]; then
        RUN_RESULT="done"
        return 0
    fi
    RUN_RESULT="failed"
    return 1
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
DONE_INDEX_CSV=""
DEGRADED_INDEX_CSV=""
while IFS='|' read -r idx slug; do
    [ -n "$idx" ] || continue
    local_phase2_path="${PHASE2_DIR}/${slug}-phase2.json"
    if [ ! -f "$local_phase2_path" ]; then
        continue
    fi
    if phase2_output_is_trusted "$local_phase2_path"; then
        if [ -n "$DONE_INDEX_CSV" ]; then
            DONE_INDEX_CSV+=",${idx}"
        else
            DONE_INDEX_CSV="${idx}"
        fi
    else
        if [ -n "$DEGRADED_INDEX_CSV" ]; then
            DEGRADED_INDEX_CSV+=",${idx}"
        else
            DEGRADED_INDEX_CSV="${idx}"
        fi
    fi
done < "$INDEXED_FILE"
if [ -z "$DONE_INDEX_CSV" ]; then
    DONE_INDEX_CSV="none"
fi
if [ -z "$DEGRADED_INDEX_CSV" ]; then
    DEGRADED_INDEX_CSV="none"
fi

if [ "$INTERACTIVE" != true ] && [ "$START_SET" != true ] && [ "$END_SET" != true ] && [ "$THREADS_SET" != true ]; then
    INTERACTIVE=true
fi

log_section "Phase 2 Batch"
echo "  Available plugins: ${AVAILABLE_COUNT}"
echo "  Indexes (IR-order): [${AVAILABLE_INDEX_CSV}]"
echo "  Already has trusted phase2 output: [${DONE_INDEX_CSV}]"
echo "  Has degraded/untrusted phase2 output: [${DEGRADED_INDEX_CSV}]"
echo "  Force: ${FORCE}"
echo "  Force deep: ${FORCE_DEEP}"
echo "  Adaptive depth: enabled"
echo "  Worker provider: ${PHASE2_WORKER_PROVIDER} ($(phase2_role_model worker "$PHASE2_WORKER_PROVIDER" || true))"
echo "  Reviewer provider: ${PHASE2_REVIEWER_PROVIDER} ($(phase2_role_model reviewer "$PHASE2_REVIEWER_PROVIDER" || true))"
echo "  Worker execution mode: ${PHASE2_WORKER_EXECUTION_MODE} (chunk parallel limit=${PHASE2_WORKER_CHUNK_PARALLEL_LIMIT})"
echo "  Base max review rounds: ${PHASE2_MAX_REVIEW_ROUNDS}"
echo "  Prompt template: ${PROMPT_TEMPLATE}"
echo "  Base timeout policy: worker=${PHASE2_WORKER_TIMEOUT_SECONDS}s, revision=${PHASE2_REVISION_TIMEOUT_SECONDS}s, reviewer=${PHASE2_REVIEWER_TIMEOUT_SECONDS}s, exploration=${PHASE2_EXPLORATION_TIMEOUT_SECONDS}s"

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
