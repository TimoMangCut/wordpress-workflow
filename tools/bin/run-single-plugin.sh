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
COST_TELEMETRY_BIN="${BIN_DIR}/cost_telemetry.py"
ARTIFACT_FRESHNESS_BIN="${BIN_DIR}/artifact_freshness.py"
THREAT_CONTEXT_GENERATOR="${BIN_DIR}/generate_threat_context.py"
THREAT_PROFILES_PATH="${TOOLS_DIR}/data/threat-profiles.json"

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
PHASE2_ONLY=false
APPLY_REVIEW=false
WITH_CLAUDE=false
PROVIDERS_EXPLICIT=false
PRIMARY_PROVIDER_EXPLICIT=false
PHASE2_WORKER_PROVIDER_EXPLICIT=false
PHASE2_REVIEWER_PROVIDER_EXPLICIT=false
LLM_MODE="auto"
# Same precedence rule as Phase 2: CLI flag > operator env (.claude/settings*.json) > Wave 6 tier
# recommendation > default. Record the origin before the defaults below erase it.
LLM_PROVIDERS_FROM_ENV=false
PRIMARY_PROVIDER_FROM_ENV=false
if [ -n "${LLM_PROVIDERS:-${LLM_PROVIDER:-}}" ]; then LLM_PROVIDERS_FROM_ENV=true; fi
if [ -n "${PRIMARY_PROVIDER:-${PHASE3_PRIMARY_PROVIDER:-}}" ]; then PRIMARY_PROVIDER_FROM_ENV=true; fi
LLM_PROVIDERS="${LLM_PROVIDERS:-${LLM_PROVIDER:-codex}}"
CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_MODEL="${CODEX_MODEL:-${LLM_MODEL:-}}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
# Reasoning effort for every claude CLI call (low|medium|high|xhigh|max).
CLAUDE_EFFORT="${CLAUDE_EFFORT:-xhigh}"
export CLAUDE_EFFORT
CLAUDE_MODEL="${CLAUDE_MODEL:-${LLM_MODEL:-}}"
# PHASE3_PRIMARY_PROVIDER is the name used by .claude/settings*.json and run-phase3.sh; accept it here
# too, otherwise this wrapper always forwards --primary-provider codex and the setting is dead.
PRIMARY_PROVIDER="${PRIMARY_PROVIDER:-${PHASE3_PRIMARY_PROVIDER:-codex}}"
PHASE2_WORKER_PROVIDER="${PHASE2_WORKER_PROVIDER:-codex}"
PHASE2_REVIEWER_PROVIDER="${PHASE2_REVIEWER_PROVIDER:-codex}"
PHASE2_WORKER_TIMEOUT_SECONDS="${PHASE2_WORKER_TIMEOUT_SECONDS:-900}"
PHASE2_REVISION_TIMEOUT_SECONDS="${PHASE2_REVISION_TIMEOUT_SECONDS:-600}"
PHASE2_REVIEWER_TIMEOUT_SECONDS="${PHASE2_REVIEWER_TIMEOUT_SECONDS:-600}"
PHASE2_EXPLORATION_TIMEOUT_SECONDS="${PHASE2_EXPLORATION_TIMEOUT_SECONDS:-240}"
PHASE2_ENABLE_CLUSTER_CONSENSUS="${PHASE2_ENABLE_CLUSTER_CONSENSUS:-true}"
PHASE2_WORKER_CODEX_MODEL="${PHASE2_WORKER_CODEX_MODEL:-${CODEX_MODEL:-gpt-5.4}}"
PHASE2_WORKER_CLAUDE_MODEL="${PHASE2_WORKER_CLAUDE_MODEL:-${CLAUDE_MODEL:-claude-opus-4-7}}"
PHASE2_REVIEWER_CODEX_MODEL="${PHASE2_REVIEWER_CODEX_MODEL:-${CODEX_MODEL:-gpt-5.4}}"
PHASE2_REVIEWER_CLAUDE_MODEL="${PHASE2_REVIEWER_CLAUDE_MODEL:-claude-opus-4-7}"
PHASE2_MAX_REVIEW_ROUNDS="${PHASE2_MAX_REVIEW_ROUNDS:-1}"
PHASE2_ENABLE_FORCED_EXPLORATION="${PHASE2_ENABLE_FORCED_EXPLORATION:-true}"
PHASE2_MAX_EXPLORATION_CANDIDATES="${PHASE2_MAX_EXPLORATION_CANDIDATES:-3}"
PIPELINE_PROGRESS_MODE="${PIPELINE_PROGRESS_MODE:-weighted}"
PIPELINE_PROGRESS_WEIGHTS_RAW="${PIPELINE_PROGRESS_WEIGHTS:-10,75,15}"
PIPELINE_PROGRESS_PHASE1_WEIGHT=0
PIPELINE_PROGRESS_PHASE2_WEIGHT=0
PIPELINE_PROGRESS_PHASE3_WEIGHT=0
PIPELINE_PROGRESS_START_TS="${PIPELINE_PROGRESS_START_TS:-}"
COST_SUMMARY_JSON=""
COST_TRACKING_BEFORE=""
COST_TRACKING_AFTER=""
CURRENT_PIPELINE_STAGE="bootstrap"
WAVE6_PROVIDER_TIER=""
WAVE6_PROVIDER_LABEL=""
WAVE6_PROVIDER_REASONS=""
WAVE6_PHASE3_PRIMARY=""
WAVE6_PHASE3_PROVIDERS=""

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
  --resume               Preferred public resume flag. Reuse existing Phase 1/2 artifacts when available and, if Phase 2 goes chunked, rerun only missing worker bundles.
  --resume-existing      Resume Phase 2 from existing worker/review artifacts when available.
  --phase2-only          Run Phase 1 -> Phase 2 only, then stop before Phase 3.
  --progress-mode <mode> Pipeline progress display: weighted|phases|off (default: weighted).
  --progress-weights <a,b,c>
                         Custom Phase 1/2/3 progress weights for --progress-mode weighted (default: 10,75,15).
  --force-deep           Pass through to Phase 2 to override adaptive quick-triage fallback.
  --apply-review         Pass through to Phase 3 apply-review loop.
  --llm-mode <mode>      Phase 3 LLM mode: auto|off|force (default: auto).

Advanced provider/model overrides:
  --with-claude          Explicit Phase 3 provider set shorthand for --providers codex,claude.
  --provider <name>      Single LLM provider shorthand: codex|claude.
  --providers <list>     Provider list, comma-separated (for example: codex,claude).
  --primary-provider <p> Canonical provider for Phase 3. Phase 2 canonical output always comes from the worker role.
  --model <name>         Set the same model for both providers.
  --codex-model <name>   Codex model override.
  --claude-model <name>  Claude model override.

Advanced Phase 2 tuning:
  --worker-provider <p>  Phase 2 worker provider (default: codex).
  --reviewer-provider <p> Phase 2 reviewer provider (default: codex).
  --worker-timeout <sec> Worker timeout for Phase 2 round 1 quick/deep analysis (default: 900).
  --revision-timeout <sec> Worker timeout for Phase 2 revision/expansion rounds (default: 600).
  --reviewer-timeout <sec> Reviewer timeout for skeptical Phase 2 review rounds (default: 600).
  --exploration-timeout <sec> Reviewer timeout for final forced exploration round (default: 240).
  --clusters                   Enable deterministic Phase 2 cluster/consensus publish (default: on).
  --no-clusters                Disable deterministic Phase 2 cluster/consensus publish.
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

phase2_canonical_trust_state() {
    local phase2_file="$1"
    python3 "$ARTIFACT_FRESHNESS_BIN" phase2-trust-state --path "$phase2_file" 2>/dev/null || true
}

phase2_canonical_is_trusted() {
    local phase2_file="$1"
    python3 "$ARTIFACT_FRESHNESS_BIN" phase2-is-trusted --path "$phase2_file" >/dev/null 2>&1
}

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
        --resume)
            PHASE2_RESUME_EXISTING=true
            shift
            ;;
        --resume-existing)
            PHASE2_RESUME_EXISTING=true
            shift
            ;;
        --phase2-only)
            PHASE2_ONLY=true
            shift
            ;;
        --progress-mode)
            PIPELINE_PROGRESS_MODE="${2:-}"
            shift 2
            ;;
        --progress-weights)
            PIPELINE_PROGRESS_WEIGHTS_RAW="${2:-}"
            shift 2
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
        --primary-provider)
            PRIMARY_PROVIDER="${2:-}"
            PRIMARY_PROVIDER_EXPLICIT=true
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
        --worker-provider)
            PHASE2_WORKER_PROVIDER="${2:-}"
            PHASE2_WORKER_PROVIDER_EXPLICIT=true
            shift 2
            ;;
        --reviewer-provider)
            PHASE2_REVIEWER_PROVIDER="${2:-}"
            PHASE2_REVIEWER_PROVIDER_EXPLICIT=true
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

normalize_pipeline_progress_mode() {
    local value
    value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    case "$value" in
        weighted|"")
            printf '%s' "weighted"
            ;;
        phases|phase|equal)
            printf '%s' "phases"
            ;;
        off|none|disabled)
            printf '%s' "off"
            ;;
        *)
            return 1
            ;;
    esac
}

resolve_pipeline_progress_weights() {
    python3 - "$1" "$2" "$3" <<'PY'
import math
import sys

mode = sys.argv[1]
raw = sys.argv[2]
phase2_only = sys.argv[3].lower() == "true"

if mode == "off":
    print("0|0|0")
    raise SystemExit(0)

if mode == "phases":
    weights = [1.0, 1.0, 0.0 if phase2_only else 1.0]
else:
    try:
        parts = [float(item.strip()) for item in raw.split(",")]
    except ValueError:
        raise SystemExit(1)
    if len(parts) != 3 or any(value < 0 for value in parts):
        raise SystemExit(1)
    weights = parts
    if phase2_only:
        weights[2] = 0.0

total = sum(weights)
if total <= 0:
    raise SystemExit(1)

scaled = [(value * 100.0) / total for value in weights]
floors = [math.floor(value) for value in scaled]
remaining = 100 - sum(floors)
fractions = sorted(
    range(3),
    key=lambda idx: (scaled[idx] - floors[idx], -idx),
    reverse=True,
)
for idx in fractions[:remaining]:
    floors[idx] += 1

print("|".join(str(int(value)) for value in floors))
PY
}

pipeline_progress_enabled() {
    [ "${PIPELINE_PROGRESS_MODE}" != "off" ]
}

pipeline_progress_overall_percent() {
    local phase="$1"
    local phase_percent="${2:-0}"
    local overall=0
    case "$phase" in
        phase1)
            overall=$(( (PIPELINE_PROGRESS_PHASE1_WEIGHT * phase_percent) / 100 ))
            ;;
        phase2)
            overall=$(( PIPELINE_PROGRESS_PHASE1_WEIGHT + (PIPELINE_PROGRESS_PHASE2_WEIGHT * phase_percent) / 100 ))
            ;;
        phase3)
            overall=$(( PIPELINE_PROGRESS_PHASE1_WEIGHT + PIPELINE_PROGRESS_PHASE2_WEIGHT + (PIPELINE_PROGRESS_PHASE3_WEIGHT * phase_percent) / 100 ))
            ;;
        *)
            overall=0
            ;;
    esac
    if [ "$overall" -gt 100 ]; then
        overall=100
    fi
    printf '%s' "$overall"
}

emit_pipeline_progress() {
    local phase="$1"
    local phase_percent="${2:-0}"
    local label="${3:-}"
    local overall

    pipeline_progress_enabled || return 0

    overall="$(pipeline_progress_overall_percent "$phase" "$phase_percent")"
    if [ -n "$label" ]; then
        echo "  Pipeline progress: ${overall}%$(pipeline_progress_eta_suffix "$overall") (${label})"
    else
        echo "  Pipeline progress: ${overall}%$(pipeline_progress_eta_suffix "$overall")"
    fi
}

pipeline_progress_format_seconds() {
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

pipeline_progress_eta_suffix() {
    local overall="${1:-0}"
    local now elapsed estimated_total remaining

    pipeline_progress_enabled || return 0
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
    printf ' | ETA ~%s' "$(pipeline_progress_format_seconds "$remaining")"
}

LLM_PROVIDERS="$(normalize_providers "$LLM_PROVIDERS")"
IFS=',' read -r -a LLM_PROVIDER_ARRAY <<< "$LLM_PROVIDERS"

if ! PIPELINE_PROGRESS_MODE="$(normalize_pipeline_progress_mode "$PIPELINE_PROGRESS_MODE")"; then
    echo "[!] Invalid --progress-mode: ${PIPELINE_PROGRESS_MODE} (expected: weighted|phases|off)"
    exit 1
fi
if ! IFS='|' read -r PIPELINE_PROGRESS_PHASE1_WEIGHT PIPELINE_PROGRESS_PHASE2_WEIGHT PIPELINE_PROGRESS_PHASE3_WEIGHT <<< "$(resolve_pipeline_progress_weights "$PIPELINE_PROGRESS_MODE" "$PIPELINE_PROGRESS_WEIGHTS_RAW" "$PHASE2_ONLY")"; then
    echo "[!] Invalid --progress-weights: ${PIPELINE_PROGRESS_WEIGHTS_RAW} (expected: three non-negative numbers like 10,75,15)"
    exit 1
fi
export PIPELINE_PROGRESS_MODE
export PIPELINE_PROGRESS_PHASE1_WEIGHT
export PIPELINE_PROGRESS_PHASE2_WEIGHT
export PIPELINE_PROGRESS_PHASE3_WEIGHT
if pipeline_progress_enabled && [ -z "${PIPELINE_PROGRESS_START_TS:-}" ]; then
    PIPELINE_PROGRESS_START_TS="$(date +%s)"
fi
export PIPELINE_PROGRESS_START_TS

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

if [ -z "${AUDIT_RUN_ID:-}" ]; then
    AUDIT_RUN_ID="${PLUGIN_SLUG}-audit-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    export AUDIT_RUN_ID
fi

PHASE1_IR="${PHASE1_DIR}/${PLUGIN_SLUG}-ir.json"
PHASE1_SURFACE="${PHASE1_DIR}/${PLUGIN_SLUG}-surface.txt"
PHASE1_SEMGREP="${PHASE1_DIR}/${PLUGIN_SLUG}-semgrep.json"
PHASE1_PSALM="${PHASE1_DIR}/${PLUGIN_SLUG}-psalm.sarif"
THREAT_CONTEXT_JSON="$(threat_context_path_for_slug "$PLUGIN_SLUG")"
PHASE1_ERR_LOG="$(logs_phase1_run_err_path "$PLUGIN_SLUG")"
PHASE1_LIVE_LOG="$(logs_phase1_run_live_path "$PLUGIN_SLUG")"
PHASE2_JSON="${PHASE2_DIR}/${PLUGIN_SLUG}-phase2.json"
PHASE2_LOCAL_JSON="${PHASE2_DIR}/${PLUGIN_SLUG}-phase2.local.json"
PHASE2_CONSENSUS_JSON="${PHASE2_DIR}/${PLUGIN_SLUG}-phase2.consensus.json"
PHASE2_PROVIDER_POLICY_JSON="$(phase2_provider_policy_path_for_slug "$PLUGIN_SLUG")"
PHASE2_LOOP_SUMMARY="${PHASE2_DIR}/${PLUGIN_SLUG}-phase2.loop-summary.json"
PHASE2_CLUSTER_PLAN="${PHASE2_DIR}/${PLUGIN_SLUG}-cluster-plan.json"
PHASE2_ERR_LOG="$(logs_phase2_run_err_path "$PLUGIN_SLUG" deep)"
PHASE2_LIVE_LOG="$(logs_phase2_run_live_path "$PLUGIN_SLUG" deep)"
PHASE2_QUICK_ERR_LOG="$(logs_phase2_run_err_path "$PLUGIN_SLUG" quick)"
PHASE2_QUICK_LIVE_LOG="$(logs_phase2_run_live_path "$PLUGIN_SLUG" quick)"
PHASE2_CHUNKED_ERR_LOG="$(logs_phase2_chunked_run_err_path "$PLUGIN_SLUG")"
PHASE2_CHUNKED_LIVE_LOG="$(logs_phase2_chunked_run_live_path "$PLUGIN_SLUG")"
PHASE2_CLUSTER_ERR_LOG="$(logs_phase2_cluster_run_err_path "$PLUGIN_SLUG")"
PHASE2_CLUSTER_LIVE_LOG="$(logs_phase2_cluster_run_live_path "$PLUGIN_SLUG")"
PHASE2_STATE_JSON="$(phase2_state_path_for_slug "$PLUGIN_SLUG")"
PHASE3_JSON="${PHASE3_DIR}/${PLUGIN_SLUG}-phase3.json"
PHASE3_FINAL_JSON="${PHASE3_DIR}/${PLUGIN_SLUG}-phase3.final.json"
PHASE3_REVIEW_JSON="${PHASE3_DIR}/${PLUGIN_SLUG}-phase3-review.json"
PHASE3_FINAL_REPORT=""
PHASE3_ERR_LOG="$(logs_phase3_run_err_path "$PLUGIN_SLUG")"
PHASE3_LIVE_LOG="$(logs_phase3_run_live_path "$PLUGIN_SLUG")"
COST_SUMMARY_JSON="$(cost_run_summary_path_for_slug "$PLUGIN_SLUG" "$AUDIT_RUN_ID")"
COST_TRACKING_BEFORE="$(cost_tracking_snapshot_path_for_slug "$PLUGIN_SLUG" "$AUDIT_RUN_ID" before)"
COST_TRACKING_AFTER="$(cost_tracking_snapshot_path_for_slug "$PLUGIN_SLUG" "$AUDIT_RUN_ID" after)"
PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-1024M}"
DB_PATH="${ROOT_DIR}/data/audit.db"

trap 'finalize_cost_measurement "$?"' EXIT

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

find_final_report_md() {
    find "${REPORTS_DIR}/final" -maxdepth 1 -type f -name "*-${PLUGIN_SLUG}.md" | sort | head -n 1
}

find_phase3_provider_md() {
    local provider="$1"
    find "$PHASE3_DIR" -maxdepth 1 -type f -name "*-${PLUGIN_SLUG}.${provider}.llm.md" | sort | head -n 1
}

build_phase2_cmd() {
    PHASE2_CMD=(bash "${BIN_DIR}/run-phase2.sh" --slug "$PLUGIN_SLUG" \
        --worker-timeout "$PHASE2_WORKER_TIMEOUT_SECONDS" \
        --revision-timeout "$PHASE2_REVISION_TIMEOUT_SECONDS" \
        --reviewer-timeout "$PHASE2_REVIEWER_TIMEOUT_SECONDS" \
        --exploration-timeout "$PHASE2_EXPLORATION_TIMEOUT_SECONDS" \
        --worker-codex-model "$PHASE2_WORKER_CODEX_MODEL" \
        --worker-claude-model "$PHASE2_WORKER_CLAUDE_MODEL" \
        --reviewer-codex-model "$PHASE2_REVIEWER_CODEX_MODEL" \
        --reviewer-claude-model "$PHASE2_REVIEWER_CLAUDE_MODEL" \
        --max-review-rounds "$PHASE2_MAX_REVIEW_ROUNDS" \
        --max-exploration-candidates "$PHASE2_MAX_EXPLORATION_CANDIDATES")

    if [ "$PHASE2_ENABLE_CLUSTER_CONSENSUS" = true ]; then
        PHASE2_CMD+=(--clusters)
    else
        PHASE2_CMD+=(--no-clusters)
    fi

    if [ "$PHASE2_WORKER_PROVIDER_EXPLICIT" = true ]; then
        PHASE2_CMD+=(--worker-provider "$PHASE2_WORKER_PROVIDER")
    fi
    if [ "$PHASE2_REVIEWER_PROVIDER_EXPLICIT" = true ]; then
        PHASE2_CMD+=(--reviewer-provider "$PHASE2_REVIEWER_PROVIDER")
    fi
    if [ "$FORCE" = true ]; then
        PHASE2_CMD+=(--force)
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
    if [ -n "$CODEX_MODEL" ]; then
        PHASE2_CMD+=(--codex-model "$CODEX_MODEL")
    fi
    if [ -n "$CLAUDE_MODEL" ]; then
        PHASE2_CMD+=(--claude-model "$CLAUDE_MODEL")
    fi
    if [ -n "$CODEX_BIN" ]; then
        PHASE2_CMD+=(--codex-bin "$CODEX_BIN")
    fi
    if [ -n "$CLAUDE_BIN" ]; then
        PHASE2_CMD+=(--claude-bin "$CLAUDE_BIN")
    fi
}

build_phase3_cmd() {
    PHASE3_CMD=(bash "${BIN_DIR}/run-phase3.sh" --slug "$PLUGIN_SLUG" --llm-mode "$LLM_MODE" --providers "$LLM_PROVIDERS" --primary-provider "$PRIMARY_PROVIDER")
    if [ "$FORCE" = true ]; then
        PHASE3_CMD+=(--force)
    fi
    if [ "$APPLY_REVIEW" = true ]; then
        PHASE3_CMD+=(--apply-review)
    fi
    if [ -n "$CODEX_MODEL" ]; then
        PHASE3_CMD+=(--codex-model "$CODEX_MODEL")
    fi
    if [ -n "$CLAUDE_MODEL" ]; then
        PHASE3_CMD+=(--claude-model "$CLAUDE_MODEL")
    fi
    if [ -n "$CODEX_BIN" ]; then
        PHASE3_CMD+=(--codex-bin "$CODEX_BIN")
    fi
    if [ -n "$CLAUDE_BIN" ]; then
        PHASE3_CMD+=(--claude-bin "$CLAUDE_BIN")
    fi
}

apply_phase2_provider_strategy_to_phase3() {
    [ -f "$PHASE2_PROVIDER_POLICY_JSON" ] || return 0
    eval "$(
        python3 - "$PHASE2_PROVIDER_POLICY_JSON" <<'PY'
import json
import shlex
import sys
from pathlib import Path

path = Path(sys.argv[1])
doc = json.loads(path.read_text(encoding="utf-8"))
final = doc.get("final") if isinstance(doc.get("final"), dict) else {}
phase3 = final.get("phase3_recommendation") if isinstance(final.get("phase3_recommendation"), dict) else {}
values = {
    "WAVE6_PROVIDER_TIER": final.get("tier_id") or "",
    "WAVE6_PROVIDER_LABEL": final.get("tier_label") or "",
    "WAVE6_PROVIDER_REASONS": ",".join(str(item) for item in (final.get("trigger_reasons") or []) if str(item)),
    "WAVE6_PHASE3_PRIMARY": phase3.get("primary_provider") or "",
    "WAVE6_PHASE3_PROVIDERS": ",".join(str(item) for item in (phase3.get("providers") or []) if str(item)),
}
for key, value in values.items():
    print(f"{key}={shlex.quote(str(value))}")
PY
    )"

    if [ "$PROVIDERS_EXPLICIT" != true ] && [ "$WITH_CLAUDE" != true ] && [ "$LLM_PROVIDERS_FROM_ENV" != true ] && [ -n "${WAVE6_PHASE3_PROVIDERS:-}" ]; then
        LLM_PROVIDERS="$(normalize_providers "$WAVE6_PHASE3_PROVIDERS")"
        IFS=',' read -r -a LLM_PROVIDER_ARRAY <<< "$LLM_PROVIDERS"
    fi
    if [ "$PRIMARY_PROVIDER_EXPLICIT" != true ] && [ "$PRIMARY_PROVIDER_FROM_ENV" != true ] && [ -n "${WAVE6_PHASE3_PRIMARY:-}" ]; then
        PRIMARY_PROVIDER="$WAVE6_PHASE3_PRIMARY"
    fi
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

phase1_resume_outputs_ready() {
    [ -f "$PHASE1_IR" ] && [ -f "$PHASE1_SURFACE" ] && [ -f "$PHASE1_SEMGREP" ]
}

ensure_threat_context_for_plugin() {
    if [ ! -d "$PLUGIN_DIR" ]; then
        return 0
    fi

    if [ ! -f "$THREAT_CONTEXT_GENERATOR" ]; then
        echo "  [..] threat context generator: missing"
        return 0
    fi

    if freshness_is_fresh "$THREAT_CONTEXT_JSON" "$PLUGIN_DIR" "$THREAT_PROFILES_PATH" "$THREAT_CONTEXT_GENERATOR"; then
        return 0
    fi

    python3 "$THREAT_CONTEXT_GENERATOR" "$PLUGIN_SLUG" \
        --plugins-dir "$PLUGINS_DIR" \
        --reports-dir "$REPORTS_DIR" \
        --profiles "$THREAT_PROFILES_PATH" >/dev/null 2>&1 || true
}

capture_tracking_snapshot() {
    local output_path="$1"
    python3 "$COST_TELEMETRY_BIN" tracking-snapshot \
        --output "$output_path" >/dev/null 2>&1 || true
}

write_cost_summary() {
    local exit_code="$1"
    local execution_status="$2"
    local -a cmd=(
        python3 "$COST_TELEMETRY_BIN" summarize-run
        --ledger "$QUOTA_LEDGER" \
        --run-id "$AUDIT_RUN_ID" \
        --slug "$PLUGIN_SLUG" \
        --before "$COST_TRACKING_BEFORE" \
        --after "$COST_TRACKING_AFTER" \
        --output "$COST_SUMMARY_JSON" \
        --exit-code "$exit_code" \
        --execution-status "$execution_status"
    )
    if [ -f "$PHASE2_PROVIDER_POLICY_JSON" ]; then
        cmd+=(--provider-policy "$PHASE2_PROVIDER_POLICY_JSON")
    fi
    "${cmd[@]}" >/dev/null 2>&1 || true
}

finalize_cost_measurement() {
    local exit_code="$1"
    local execution_status="success"
    if [ "$exit_code" -ne 0 ]; then
        execution_status="failed_${CURRENT_PIPELINE_STAGE}"
    fi

    set +e
    if [ -n "${COST_TRACKING_AFTER:-}" ]; then
        capture_tracking_snapshot "$COST_TRACKING_AFTER"
    fi
    if [ -n "${COST_SUMMARY_JSON:-}" ]; then
        write_cost_summary "$exit_code" "$execution_status"
        if [ -f "$COST_SUMMARY_JSON" ]; then
            echo ""
            echo "  Cost summary : ${COST_SUMMARY_JSON}"
        fi
    fi
}

run_phase1_stage() {
    echo ""
    echo ">>> Phase 1: Deterministic Collection"
    emit_pipeline_progress "phase1" 0 "entering Phase 1"
    if [ "$PHASE2_RESUME_EXISTING" = true ] && phase1_resume_outputs_ready; then
        echo "  Resume existing Phase 1 artifacts: reusing surface map, semgrep, and IR"
        ensure_threat_context_for_plugin
        print_artifact_status "surface map" "$PHASE1_SURFACE"
        print_artifact_status "semgrep" "$PHASE1_SEMGREP"
        print_artifact_status "psalm" "$PHASE1_PSALM"
        print_artifact_status "IR" "$PHASE1_IR"
        print_artifact_status "threat context" "$THREAT_CONTEXT_JSON"
        print_artifact_status "phase1 err log" "$PHASE1_ERR_LOG"
        print_artifact_status "phase1 live log" "$PHASE1_LIVE_LOG"
        emit_pipeline_progress "phase1" 100 "Phase 1 complete"
        return 0
    fi

    bash "${BIN_DIR}/scan-all.sh" "$PLUGIN_DIR"
    ensure_threat_context_for_plugin

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
    emit_pipeline_progress "phase1" 100 "Phase 1 complete"
}

run_phase2_stage() {
    echo ""
    echo ">>> Phase 2: Canonical Role Loop + Cluster Consensus"
    emit_pipeline_progress "phase2" 0 "entering Phase 2"
    build_phase2_cmd
    if [ "$PHASE2_RESUME_EXISTING" = true ]; then
        env PHASE2_CHUNKED_RESUME_MISSING_ONLY=true "${PHASE2_CMD[@]}"
    else
        "${PHASE2_CMD[@]}"
    fi

    if [ ! -f "$PHASE2_JSON" ]; then
        echo "[!] Phase 2 finished but canonical output is missing: ${PHASE2_JSON}"
        return 1
    fi

    local phase2_trust_state
    phase2_trust_state="$(phase2_canonical_trust_state "$PHASE2_JSON")"
    if ! phase2_canonical_is_trusted "$PHASE2_JSON"; then
        echo "[!] Phase 2 finished but canonical output is not trusted: ${PHASE2_JSON}"
        echo "    trust_state=${phase2_trust_state:-missing}"
        return 1
    fi

    print_artifact_status "phase2 loop summary" "$PHASE2_LOOP_SUMMARY"
    print_artifact_status "phase2 state" "$PHASE2_STATE_JSON"
    print_artifact_status "phase2 provider policy" "$PHASE2_PROVIDER_POLICY_JSON"
    print_artifact_status "phase2 local" "$PHASE2_LOCAL_JSON"
    print_artifact_status "phase2 consensus" "$PHASE2_CONSENSUS_JSON"
    print_artifact_status "phase2 canonical" "$PHASE2_JSON"
    print_artifact_status "phase2 cluster plan" "$PHASE2_CLUSTER_PLAN"
    print_preferred_artifact_status "phase2 err log" "$PHASE2_ERR_LOG" "$PHASE2_QUICK_ERR_LOG"
    print_preferred_artifact_status "phase2 live log" "$PHASE2_LIVE_LOG" "$PHASE2_QUICK_LIVE_LOG"
    print_artifact_status "phase2 chunked err log" "$PHASE2_CHUNKED_ERR_LOG"
    print_artifact_status "phase2 chunked live log" "$PHASE2_CHUNKED_LIVE_LOG"
    print_artifact_status "phase2 cluster err log" "$PHASE2_CLUSTER_ERR_LOG"
    print_artifact_status "phase2 cluster live log" "$PHASE2_CLUSTER_LIVE_LOG"

    apply_phase2_provider_strategy_to_phase3
    echo "  Phase 3 resolved providers: ${LLM_PROVIDERS} (primary=${PRIMARY_PROVIDER}${WAVE6_PROVIDER_TIER:+; tier=${WAVE6_PROVIDER_TIER}; reasons=${WAVE6_PROVIDER_REASONS}})"
    emit_pipeline_progress "phase2" 100 "Phase 2 complete"
}

run_phase3_stage() {
    local provider provider_md

    echo ""
    echo ">>> Phase 3: Gate + Optional LLM Skeptic"
    emit_pipeline_progress "phase3" 0 "entering Phase 3"
    build_phase3_cmd
    "${PHASE3_CMD[@]}"

    PHASE3_MD="$(find_phase3_md)"
    PHASE3_FINAL_REPORT="$(find_final_report_md)"
    if [ -z "${PHASE3_MD:-}" ]; then
        echo "[!] Phase 3 finished but deterministic markdown is missing for slug: ${PLUGIN_SLUG}"
        return 1
    fi
    if [ -z "${PHASE3_FINAL_REPORT:-}" ]; then
        echo "[!] Phase 3 finished but final report is missing for slug: ${PLUGIN_SLUG}"
        return 1
    fi

    print_artifact_status "phase3 gate json" "$PHASE3_JSON"
    print_artifact_status "phase3 final json" "$PHASE3_FINAL_JSON"
    print_artifact_status "phase3 review json" "$PHASE3_REVIEW_JSON"
    print_artifact_status "phase3 markdown" "$PHASE3_MD"
    print_artifact_status "final report" "$PHASE3_FINAL_REPORT"
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
    emit_pipeline_progress "phase3" 100 "Phase 3 complete"
}

build_phase2_cmd
build_phase3_cmd

echo "========================================="
echo "  Single Plugin Pipeline"
echo "========================================="
echo "  Plugin slug: ${PLUGIN_SLUG}"
echo "  Plugin dir : ${PLUGIN_DIR}"
echo "  Run ID     : ${AUDIT_RUN_ID}"
print_execution_topology
echo "  Phase 2 depth policy: adaptive (use --force-deep only to disable quick fallback)"
echo "  Phase 2 base config: worker=${PHASE2_WORKER_PROVIDER} (${PHASE2_WORKER_CODEX_MODEL}/${PHASE2_WORKER_CLAUDE_MODEL}) reviewer=${PHASE2_REVIEWER_PROVIDER} (${PHASE2_REVIEWER_CODEX_MODEL}/${PHASE2_REVIEWER_CLAUDE_MODEL}) base_rounds=${PHASE2_MAX_REVIEW_ROUNDS} base_forced_exploration=${PHASE2_ENABLE_FORCED_EXPLORATION}/${PHASE2_MAX_EXPLORATION_CANDIDATES}"
echo "  Phase 2 base timeouts: worker=${PHASE2_WORKER_TIMEOUT_SECONDS}s revision=${PHASE2_REVISION_TIMEOUT_SECONDS}s reviewer=${PHASE2_REVIEWER_TIMEOUT_SECONDS}s exploration=${PHASE2_EXPLORATION_TIMEOUT_SECONDS}s"
echo "  Phase 2 clusters: ${PHASE2_ENABLE_CLUSTER_CONSENSUS}"
echo "  Resume mode: ${PHASE2_RESUME_EXISTING}"
echo "  Phase 2 only: ${PHASE2_ONLY}"
echo "  Progress mode: ${PIPELINE_PROGRESS_MODE}"
if pipeline_progress_enabled; then
    echo "  Progress weights: phase1=${PIPELINE_PROGRESS_PHASE1_WEIGHT}%, phase2=${PIPELINE_PROGRESS_PHASE2_WEIGHT}%, phase3=${PIPELINE_PROGRESS_PHASE3_WEIGHT}%"
fi
echo "  Phase 3 providers: ${LLM_PROVIDERS}"
echo "  LLM mode   : ${LLM_MODE}"
echo "  Reports dir: ${REPORTS_DIR}"
emit_pipeline_progress "phase1" 0 "pipeline start"

capture_tracking_snapshot "$COST_TRACKING_BEFORE"

CURRENT_PIPELINE_STAGE="phase1"
run_phase1_stage
CURRENT_PIPELINE_STAGE="phase2"
run_phase2_stage
if [ "$PHASE2_ONLY" = true ]; then
    CURRENT_PIPELINE_STAGE="done"
    emit_pipeline_progress "phase2" 100 "Pipeline complete (--phase2-only)"
else
    CURRENT_PIPELINE_STAGE="phase3"
    run_phase3_stage
    CURRENT_PIPELINE_STAGE="done"
    emit_pipeline_progress "phase3" 100 "Pipeline complete"
fi

echo ""
echo "========================================="
echo "  Pipeline Complete"
echo "========================================="
echo "  Phase 1 IR : ${PHASE1_IR}"
echo "  Threat ctx : ${THREAT_CONTEXT_JSON}"
echo "  Phase 2 local     : ${PHASE2_LOCAL_JSON}"
echo "  Phase 2 consensus : ${PHASE2_CONSENSUS_JSON}"
echo "  Phase 2    : ${PHASE2_JSON}"
echo "  Provider policy   : ${PHASE2_PROVIDER_POLICY_JSON}"
if [ "$PHASE2_ONLY" != true ]; then
    echo "  Phase 3 gate      : ${PHASE3_JSON}"
    echo "  Phase 3 final     : ${PHASE3_FINAL_JSON}"
    echo "  Phase 3 markdown  : ${PHASE3_MD}"
    echo "  Final report      : ${PHASE3_FINAL_REPORT}"
else
    echo "  Phase 3           : skipped (--phase2-only)"
fi
echo "  Cost summary      : ${COST_SUMMARY_JSON}"
