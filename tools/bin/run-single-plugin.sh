#!/bin/bash
# run-single-plugin.sh - Single-plugin Phase 1 -> Phase 2 -> Phase 3 pipeline.
# Usage:
#   run-single-plugin.sh <plugin-slug|plugin-dir> [options]
#   run-single-plugin.sh --slug <plugin-slug> [options]
#   run-single-plugin.sh --plugin-dir <path> [options]

set -euo pipefail

BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$(cd "${BIN_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${TOOLS_DIR}/.." && pwd)"
PLUGINS_DIR="${ROOT_DIR}/plugins"

source "${TOOLS_DIR}/bin/report-paths.sh"
resolve_report_dirs "${ROOT_DIR}/reports"
ensure_report_dirs

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

PLUGIN_INPUT=""
PLUGIN_DIR_INPUT=""
PLUGIN_SLUG_INPUT=""
FORCE=false
FORCE_DEEP=false
PHASE2_RESUME_EXISTING=false
APPLY_REVIEW=false
WITH_CLAUDE=false
PROVIDERS_EXPLICIT=false
LLM_MODE="auto"
LLM_PROVIDERS="${LLM_PROVIDERS:-${LLM_PROVIDER:-codex}}"
CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_MODEL="${CODEX_MODEL:-${LLM_MODEL:-}}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_MODEL="${CLAUDE_MODEL:-${LLM_MODEL:-}}"
PRIMARY_PROVIDER="${PRIMARY_PROVIDER:-codex}"
PHASE2_WORKER_PROVIDER="${PHASE2_WORKER_PROVIDER:-claude}"
PHASE2_REVIEWER_PROVIDER="${PHASE2_REVIEWER_PROVIDER:-codex}"
PHASE2_WORKER_TIMEOUT_SECONDS="${PHASE2_WORKER_TIMEOUT_SECONDS:-900}"
PHASE2_REVISION_TIMEOUT_SECONDS="${PHASE2_REVISION_TIMEOUT_SECONDS:-600}"
PHASE2_REVIEWER_TIMEOUT_SECONDS="${PHASE2_REVIEWER_TIMEOUT_SECONDS:-600}"
PHASE2_EXPLORATION_TIMEOUT_SECONDS="${PHASE2_EXPLORATION_TIMEOUT_SECONDS:-240}"
PHASE2_WORKER_CODEX_MODEL="${PHASE2_WORKER_CODEX_MODEL:-${CODEX_MODEL:-gpt-5.4}}"
PHASE2_WORKER_CLAUDE_MODEL="${PHASE2_WORKER_CLAUDE_MODEL:-${CLAUDE_MODEL:-claude-sonnet-4.6}}"
PHASE2_REVIEWER_CODEX_MODEL="${PHASE2_REVIEWER_CODEX_MODEL:-${CODEX_MODEL:-gpt-5.4}}"
PHASE2_REVIEWER_CLAUDE_MODEL="${PHASE2_REVIEWER_CLAUDE_MODEL:-claude-opus-4.6}"
PHASE2_MAX_REVIEW_ROUNDS="${PHASE2_MAX_REVIEW_ROUNDS:-1}"
PHASE2_ENABLE_FORCED_EXPLORATION="${PHASE2_ENABLE_FORCED_EXPLORATION:-true}"
PHASE2_MAX_EXPLORATION_CANDIDATES="${PHASE2_MAX_EXPLORATION_CANDIDATES:-3}"

usage() {
    cat <<'EOF'
Usage:
  run-single-plugin.sh <plugin-slug|plugin-dir> [options]
  run-single-plugin.sh --slug <plugin-slug> [options]
  run-single-plugin.sh --plugin-dir <path> [options]

Core options:
  --slug <slug>          Plugin slug under plugins/.
  --plugin-dir <path>    Absolute or relative plugin directory path.
  --force                Re-run Phase 2 and Phase 3 even if canonical outputs exist.
  --resume-existing      Resume Phase 2 from existing worker/review artifacts when available.
  --force-deep           Pass through to Phase 2 to override adaptive quick-triage fallback.
  --apply-review         Pass through to Phase 3 apply-review loop.
  --llm-mode <mode>      Phase 3 LLM mode: auto|off|force (default: auto).

Advanced provider/model overrides:
  --with-claude          Convenience flag: run both codex and claude.
  --provider <name>      Single LLM provider shorthand: codex|claude.
  --providers <list>     Provider list, comma-separated (for example: codex,claude).
  --primary-provider <p> Canonical provider for Phase 3. Phase 2 canonical output always comes from the worker role.
  --model <name>         Set the same model for both providers.
  --codex-model <name>   Codex model override.
  --claude-model <name>  Claude model override.

Advanced Phase 2 tuning:
  --worker-provider <p>  Phase 2 worker provider (default: claude).
  --reviewer-provider <p> Phase 2 reviewer provider (default: codex).
  --worker-timeout <sec> Worker timeout for Phase 2 round 1 quick/deep analysis (default: 900).
  --revision-timeout <sec> Worker timeout for Phase 2 revision/expansion rounds (default: 600).
  --reviewer-timeout <sec> Reviewer timeout for skeptical Phase 2 review rounds (default: 600).
  --exploration-timeout <sec> Reviewer timeout for final forced exploration round (default: 240).
  --worker-codex-model <name>   Codex model for Phase 2 worker role.
  --worker-claude-model <name>  Claude model for Phase 2 worker role.
  --reviewer-codex-model <name> Codex model for Phase 2 reviewer role.
  --reviewer-claude-model <name> Claude model for Phase 2 reviewer role.
  --max-review-rounds <N>       Phase 2 skeptical review rounds.
  --forced-exploration          Enable the final Phase 2 expansion round.
  --no-forced-exploration       Disable the final Phase 2 expansion round.
  --max-exploration-candidates <N> Limit reviewer exploration candidates in the final round.
  --codex-bin <path>     Codex CLI binary/path (default: env CODEX_BIN or codex).
  --claude-bin <path>    Claude Code binary/path (default: env CLAUDE_BIN or claude).
  -h, --help             Show this help message.

Execution model:
  1) Phase 1 via tools/bin/scan-all.sh
     surface map -> semgrep -> psalm -> IR extract -> threat context
  2) Phase 2 via tools/bin/run-phase2.sh
     worker -> reviewer_core -> worker revision -> reviewer_explore -> cluster -> consensus
  3) Phase 3 via tools/bin/run-phase3.sh
     deterministic gate -> optional LLM skeptic

Notes:
  - This is the canonical full-audit entrypoint for one plugin.
  - This wrapper is single-plugin only. It does not support range or interactive batch mode.
  - Advanced Phase 2 tuning flags are passthrough knobs for validation/debug; the workflow topology itself is fixed here.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --slug)
            PLUGIN_SLUG_INPUT="${2:-}"
            shift 2
            ;;
        --plugin-dir)
            PLUGIN_DIR_INPUT="${2:-}"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --resume-existing)
            PHASE2_RESUME_EXISTING=true
            shift
            ;;
        --force-deep)
            FORCE_DEEP=true
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
        --primary-provider)
            PRIMARY_PROVIDER="${2:-}"
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
        --worker-provider)
            PHASE2_WORKER_PROVIDER="${2:-}"
            shift 2
            ;;
        --reviewer-provider)
            PHASE2_REVIEWER_PROVIDER="${2:-}"
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
                echo "[!] Unknown option: $1"
                usage
                exit 1
            fi
            if [ -n "$PLUGIN_INPUT" ]; then
                echo "[!] Too many positional arguments. This wrapper accepts exactly one plugin target."
                usage
                exit 1
            fi
            PLUGIN_INPUT="$1"
            shift
            ;;
    esac
done

if [[ "$LLM_MODE" != "auto" && "$LLM_MODE" != "off" && "$LLM_MODE" != "force" ]]; then
    echo "[!] Invalid --llm-mode: $LLM_MODE (expected: auto|off|force)"
    exit 1
fi

if [ "$WITH_CLAUDE" = true ] && [ "$PROVIDERS_EXPLICIT" != true ]; then
    LLM_PROVIDERS="codex,claude"
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

if [ -n "$PLUGIN_INPUT" ] && { [ -n "$PLUGIN_DIR_INPUT" ] || [ -n "$PLUGIN_SLUG_INPUT" ]; }; then
    echo "[!] Provide exactly one plugin target: positional, --slug, or --plugin-dir."
    exit 1
fi

if [ -n "$PLUGIN_DIR_INPUT" ] && [ -n "$PLUGIN_SLUG_INPUT" ]; then
    echo "[!] Use either --slug or --plugin-dir, not both."
    exit 1
fi

PLUGIN_DIR=""
PLUGIN_SLUG=""

if [ -n "$PLUGIN_DIR_INPUT" ]; then
    if [ ! -d "$PLUGIN_DIR_INPUT" ]; then
        echo "[!] Plugin directory not found: $PLUGIN_DIR_INPUT"
        exit 1
    fi
    PLUGIN_DIR="$(cd "$PLUGIN_DIR_INPUT" && pwd)"
    PLUGIN_SLUG="$(basename "$PLUGIN_DIR")"
elif [ -n "$PLUGIN_SLUG_INPUT" ]; then
    PLUGIN_DIR="${PLUGINS_DIR}/${PLUGIN_SLUG_INPUT}"
    if [ ! -d "$PLUGIN_DIR" ]; then
        echo "[!] Plugin slug not found under plugins/: ${PLUGIN_SLUG_INPUT}"
        exit 1
    fi
    PLUGIN_DIR="$(cd "$PLUGIN_DIR" && pwd)"
    PLUGIN_SLUG="${PLUGIN_SLUG_INPUT}"
elif [ -n "$PLUGIN_INPUT" ]; then
    if [ -d "$PLUGIN_INPUT" ]; then
        PLUGIN_DIR="$(cd "$PLUGIN_INPUT" && pwd)"
        PLUGIN_SLUG="$(basename "$PLUGIN_DIR")"
    elif [ -d "${PLUGINS_DIR}/${PLUGIN_INPUT}" ]; then
        PLUGIN_DIR="$(cd "${PLUGINS_DIR}/${PLUGIN_INPUT}" && pwd)"
        PLUGIN_SLUG="${PLUGIN_INPUT}"
    else
        echo "[!] Could not resolve plugin target: ${PLUGIN_INPUT}"
        echo "    Expected a slug under ${PLUGINS_DIR} or a valid plugin directory path."
        exit 1
    fi
else
    usage
    exit 1
fi

PHASE1_IR="${PHASE1_DIR}/${PLUGIN_SLUG}-ir.json"
PHASE1_SURFACE="${PHASE1_DIR}/${PLUGIN_SLUG}-surface.txt"
PHASE1_SEMGREP="${PHASE1_DIR}/${PLUGIN_SLUG}-semgrep.json"
PHASE1_PSALM="${PHASE1_DIR}/${PLUGIN_SLUG}-psalm.sarif"
THREAT_CONTEXT_JSON="${REPORTS_DIR}/${PLUGIN_SLUG}-threat-context.json"
PHASE1_ERR_LOG="$(logs_phase1_run_err_path "$PLUGIN_SLUG")"
PHASE1_LIVE_LOG="$(logs_phase1_run_live_path "$PLUGIN_SLUG")"
PHASE2_JSON="${PHASE2_DIR}/${PLUGIN_SLUG}-phase2.json"
PHASE2_LOCAL_JSON="${PHASE2_DIR}/${PLUGIN_SLUG}-phase2.local.json"
PHASE2_CONSENSUS_JSON="${PHASE2_DIR}/${PLUGIN_SLUG}-phase2.consensus.json"
PHASE2_LOOP_SUMMARY="${PHASE2_DIR}/${PLUGIN_SLUG}-phase2.loop-summary.json"
PHASE2_CLUSTER_PLAN="${PHASE2_DIR}/${PLUGIN_SLUG}-cluster-plan.json"
PHASE2_ERR_LOG="$(logs_phase2_run_err_path "$PLUGIN_SLUG" deep)"
PHASE2_LIVE_LOG="$(logs_phase2_run_live_path "$PLUGIN_SLUG" deep)"
PHASE2_QUICK_ERR_LOG="$(logs_phase2_run_err_path "$PLUGIN_SLUG" quick)"
PHASE2_QUICK_LIVE_LOG="$(logs_phase2_run_live_path "$PLUGIN_SLUG" quick)"
PHASE2_CLUSTER_ERR_LOG="$(logs_phase2_cluster_run_err_path "$PLUGIN_SLUG")"
PHASE2_CLUSTER_LIVE_LOG="$(logs_phase2_cluster_run_live_path "$PLUGIN_SLUG")"
PHASE3_JSON="${PHASE3_DIR}/${PLUGIN_SLUG}-phase3.json"
PHASE3_FINAL_JSON="${PHASE3_DIR}/${PLUGIN_SLUG}-phase3.final.json"
PHASE3_REVIEW_JSON="${PHASE3_DIR}/${PLUGIN_SLUG}-phase3-review.json"
PHASE3_ERR_LOG="$(logs_phase3_run_err_path "$PLUGIN_SLUG")"
PHASE3_LIVE_LOG="$(logs_phase3_run_live_path "$PLUGIN_SLUG")"
PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-1024M}"
DB_PATH="${ROOT_DIR}/data/audit.db"

resolve_php_bin() {
    local candidate

    if [ -n "${PHP_BIN:-}" ]; then
        if [ -x "${PHP_BIN}" ]; then
            echo "${PHP_BIN}"
            return 0
        fi
        if command -v "${PHP_BIN}" >/dev/null 2>&1; then
            command -v "${PHP_BIN}"
            return 0
        fi
    fi

    for candidate in \
        php \
        php8.4 php84 \
        php8.3 php83 \
        php8.2 php82 \
        php8.1 php81 \
        /opt/homebrew/bin/php \
        /usr/local/bin/php \
        /usr/bin/php
    do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done

    return 1
}

find_phase3_md() {
    find "$PHASE3_DIR" -maxdepth 1 -type f -name "*-${PLUGIN_SLUG}.md" ! -name "*.llm.md" | sort | head -n 1
}

find_phase3_provider_md() {
    local provider="$1"
    find "$PHASE3_DIR" -maxdepth 1 -type f -name "*-${PLUGIN_SLUG}.${provider}.llm.md" | sort | head -n 1
}

print_artifact_status() {
    local label="$1"
    local path="$2"
    if [ -f "$path" ]; then
        echo "  [ok] ${label}: present at ${path}"
    else
        echo "  [..] ${label}: missing"
    fi
}

print_preferred_artifact_status() {
    local label="$1"
    shift
    local path
    for path in "$@"; do
        if [ -f "$path" ]; then
            print_artifact_status "$label" "$path"
            return 0
        fi
    done
    echo "  [..] ${label}: missing"
}

print_execution_topology() {
    echo "  Coordinator: run-single-plugin.sh"
    echo "  Phase 1 engine: tools/bin/scan-all.sh"
    echo "  Phase 2 engine: tools/bin/run-phase2.sh"
    echo "    Topology: worker -> reviewer_core -> worker revision -> reviewer_explore -> cluster -> consensus"
    echo "  Phase 3 engine: tools/bin/run-phase3.sh"
    echo "    Topology: gate -> optional llm skeptic"
}

run_phase1_stage() {
    echo ""
    echo ">>> Phase 1: Deterministic Collection"
    bash "${BIN_DIR}/scan-all.sh" "$PLUGIN_DIR"

    if [ ! -f "$PHASE1_IR" ]; then
        PHP_RUNTIME="$(resolve_php_bin || true)"
        if [ -n "${PHP_RUNTIME:-}" ] && [ -f "${TOOLS_DIR}/vendor/autoload.php" ] && [ -f "${BIN_DIR}/extract.php" ]; then
            echo "  [*] IR artifact missing after scan-all; retrying extract with --force"
            "$PHP_RUNTIME" -d "memory_limit=${PHP_MEMORY_LIMIT}" "${BIN_DIR}/extract.php" "$PLUGIN_DIR" --db="${DB_PATH}" --force || true
        fi
    fi

    if [ ! -f "$PHASE1_IR" ]; then
        echo "[!] Phase 1 finished but required IR output is missing: ${PHASE1_IR}"
        echo "    Check reports/logs for extractor errors before continuing."
        return 1
    fi

    print_artifact_status "surface map" "$PHASE1_SURFACE"
    print_artifact_status "semgrep" "$PHASE1_SEMGREP"
    print_artifact_status "psalm" "$PHASE1_PSALM"
    print_artifact_status "IR" "$PHASE1_IR"
    print_artifact_status "threat context" "$THREAT_CONTEXT_JSON"
    print_artifact_status "phase1 err log" "$PHASE1_ERR_LOG"
    print_artifact_status "phase1 live log" "$PHASE1_LIVE_LOG"
}

run_phase2_stage() {
    echo ""
    echo ">>> Phase 2: Canonical Role Loop + Cluster Consensus"
    "${PHASE2_CMD[@]}"

    if [ ! -f "$PHASE2_JSON" ]; then
        echo "[!] Phase 2 finished but canonical output is missing: ${PHASE2_JSON}"
        return 1
    fi

    print_artifact_status "phase2 loop summary" "$PHASE2_LOOP_SUMMARY"
    print_artifact_status "phase2 local" "$PHASE2_LOCAL_JSON"
    print_artifact_status "phase2 consensus" "$PHASE2_CONSENSUS_JSON"
    print_artifact_status "phase2 canonical" "$PHASE2_JSON"
    print_artifact_status "phase2 cluster plan" "$PHASE2_CLUSTER_PLAN"
    print_preferred_artifact_status "phase2 err log" "$PHASE2_ERR_LOG" "$PHASE2_QUICK_ERR_LOG"
    print_preferred_artifact_status "phase2 live log" "$PHASE2_LIVE_LOG" "$PHASE2_QUICK_LIVE_LOG"
    print_artifact_status "phase2 cluster err log" "$PHASE2_CLUSTER_ERR_LOG"
    print_artifact_status "phase2 cluster live log" "$PHASE2_CLUSTER_LIVE_LOG"
}

run_phase3_stage() {
    local provider provider_md

    echo ""
    echo ">>> Phase 3: Gate + Optional LLM Skeptic"
    "${PHASE3_CMD[@]}"

    PHASE3_MD="$(find_phase3_md)"
    if [ -z "${PHASE3_MD:-}" ]; then
        echo "[!] Phase 3 finished but deterministic markdown is missing for slug: ${PLUGIN_SLUG}"
        return 1
    fi

    print_artifact_status "phase3 gate json" "$PHASE3_JSON"
    print_artifact_status "phase3 final json" "$PHASE3_FINAL_JSON"
    print_artifact_status "phase3 review json" "$PHASE3_REVIEW_JSON"
    print_artifact_status "phase3 markdown" "$PHASE3_MD"
    print_artifact_status "phase3 err log" "$PHASE3_ERR_LOG"
    print_artifact_status "phase3 live log" "$PHASE3_LIVE_LOG"
    for provider in "${LLM_PROVIDER_ARRAY[@]}"; do
        provider_md="$(find_phase3_provider_md "$provider")"
        if [ -n "$provider_md" ]; then
            print_artifact_status "phase3 ${provider} llm" "$provider_md"
        else
            echo "  [..] phase3 ${provider} llm: missing"
        fi
    done
}

PHASE2_CMD=(bash "${BIN_DIR}/run-phase2.sh" --slug "$PLUGIN_SLUG" \
    --clusters \
    --worker-timeout "$PHASE2_WORKER_TIMEOUT_SECONDS" \
    --revision-timeout "$PHASE2_REVISION_TIMEOUT_SECONDS" \
    --reviewer-timeout "$PHASE2_REVIEWER_TIMEOUT_SECONDS" \
    --exploration-timeout "$PHASE2_EXPLORATION_TIMEOUT_SECONDS" \
    --worker-provider "$PHASE2_WORKER_PROVIDER" \
    --reviewer-provider "$PHASE2_REVIEWER_PROVIDER" \
    --worker-codex-model "$PHASE2_WORKER_CODEX_MODEL" \
    --worker-claude-model "$PHASE2_WORKER_CLAUDE_MODEL" \
    --reviewer-codex-model "$PHASE2_REVIEWER_CODEX_MODEL" \
    --reviewer-claude-model "$PHASE2_REVIEWER_CLAUDE_MODEL" \
    --max-review-rounds "$PHASE2_MAX_REVIEW_ROUNDS" \
    --max-exploration-candidates "$PHASE2_MAX_EXPLORATION_CANDIDATES")
PHASE3_CMD=(bash "${BIN_DIR}/run-phase3.sh" --slug "$PLUGIN_SLUG" --llm-mode "$LLM_MODE" --providers "$LLM_PROVIDERS" --primary-provider "$PRIMARY_PROVIDER")

if [ "$FORCE" = true ]; then
    PHASE2_CMD+=(--force)
    PHASE3_CMD+=(--force)
fi
if [ "$PHASE2_RESUME_EXISTING" = true ]; then
    PHASE2_CMD+=(--resume-existing)
fi
if [ "$FORCE_DEEP" = true ]; then
    PHASE2_CMD+=(--force-deep)
fi
if [ "$PHASE2_ENABLE_FORCED_EXPLORATION" = true ]; then
    PHASE2_CMD+=(--forced-exploration)
else
    PHASE2_CMD+=(--no-forced-exploration)
fi
if [ "$APPLY_REVIEW" = true ]; then
    PHASE3_CMD+=(--apply-review)
fi
if [ -n "$CODEX_MODEL" ]; then
    PHASE2_CMD+=(--codex-model "$CODEX_MODEL")
    PHASE3_CMD+=(--codex-model "$CODEX_MODEL")
fi
if [ -n "$CLAUDE_MODEL" ]; then
    PHASE2_CMD+=(--claude-model "$CLAUDE_MODEL")
    PHASE3_CMD+=(--claude-model "$CLAUDE_MODEL")
fi
if [ -n "$CODEX_BIN" ]; then
    PHASE2_CMD+=(--codex-bin "$CODEX_BIN")
    PHASE3_CMD+=(--codex-bin "$CODEX_BIN")
fi
if [ -n "$CLAUDE_BIN" ]; then
    PHASE2_CMD+=(--claude-bin "$CLAUDE_BIN")
    PHASE3_CMD+=(--claude-bin "$CLAUDE_BIN")
fi

echo "========================================="
echo "  Single Plugin Pipeline"
echo "========================================="
echo "  Plugin slug: ${PLUGIN_SLUG}"
echo "  Plugin dir : ${PLUGIN_DIR}"
print_execution_topology
echo "  Phase 2 depth policy: adaptive (use --force-deep only to disable quick fallback)"
echo "  Phase 2 base config: worker=${PHASE2_WORKER_PROVIDER} (${PHASE2_WORKER_CODEX_MODEL}/${PHASE2_WORKER_CLAUDE_MODEL}) reviewer=${PHASE2_REVIEWER_PROVIDER} (${PHASE2_REVIEWER_CODEX_MODEL}/${PHASE2_REVIEWER_CLAUDE_MODEL}) base_rounds=${PHASE2_MAX_REVIEW_ROUNDS} base_forced_exploration=${PHASE2_ENABLE_FORCED_EXPLORATION}/${PHASE2_MAX_EXPLORATION_CANDIDATES}"
echo "  Phase 2 base timeouts: worker=${PHASE2_WORKER_TIMEOUT_SECONDS}s revision=${PHASE2_REVISION_TIMEOUT_SECONDS}s reviewer=${PHASE2_REVIEWER_TIMEOUT_SECONDS}s exploration=${PHASE2_EXPLORATION_TIMEOUT_SECONDS}s"
echo "  Phase 2 resume: ${PHASE2_RESUME_EXISTING}"
echo "  Phase 3 providers: ${LLM_PROVIDERS}"
echo "  LLM mode   : ${LLM_MODE}"
echo "  Reports dir: ${REPORTS_DIR}"

run_phase1_stage
run_phase2_stage
run_phase3_stage

echo ""
echo "========================================="
echo "  Pipeline Complete"
echo "========================================="
echo "  Phase 1 IR : ${PHASE1_IR}"
echo "  Threat ctx : ${THREAT_CONTEXT_JSON}"
echo "  Phase 2 local     : ${PHASE2_LOCAL_JSON}"
echo "  Phase 2 consensus : ${PHASE2_CONSENSUS_JSON}"
echo "  Phase 2    : ${PHASE2_JSON}"
echo "  Phase 3 gate      : ${PHASE3_JSON}"
echo "  Phase 3 final     : ${PHASE3_FINAL_JSON}"
echo "  Phase 3 markdown  : ${PHASE3_MD}"
