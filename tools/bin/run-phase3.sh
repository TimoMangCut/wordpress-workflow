#!/bin/bash
# run-phase3.sh - Phase 3 gate-first validation with optional LLM skeptic review.
# Usage:
#   run-phase3.sh <plugin-slug>
#   run-phase3.sh --slug <plugin-slug> [--force] [--apply-review]
#   run-phase3.sh [--force] [--apply-review]

set -euo pipefail

BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$(cd "${BIN_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${TOOLS_DIR}/.." && pwd)"
source "${TOOLS_DIR}/bin/report-paths.sh"
source "${TOOLS_DIR}/bin/console-ui.sh"
resolve_report_dirs "${ROOT_DIR}/reports"
PLUGINS_DIR="${ROOT_DIR}/plugins"
ARTIFACT_FRESHNESS_BIN="${BIN_DIR}/artifact_freshness.py"
COST_TELEMETRY_BIN="${BIN_DIR}/cost_telemetry.py"
PHASE3_REVIEW_CONTRACT_BIN="${BIN_DIR}/phase3_review_contract.py"

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
FORCE=false
APPLY_REVIEW=false
LLM_MODE="auto"
WITH_CLAUDE=false
PROVIDERS_EXPLICIT=false
RUN_RESULT=""
LLM_PROVIDERS="${LLM_PROVIDERS:-${LLM_PROVIDER:-codex}}"
CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_MODEL="${CODEX_MODEL:-${LLM_MODEL:-}}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_MODEL="${CLAUDE_MODEL:-${LLM_MODEL:-}}"
PHASE3_PRIMARY_PROVIDER="${PHASE3_PRIMARY_PROVIDER:-codex}"

usage() {
    cat <<'EOF'
Usage:
  run-phase3.sh <plugin-slug>
  run-phase3.sh --slug <plugin-slug> [--force] [--apply-review] [--llm-mode auto|off|force]
  run-phase3.sh [--force] [--apply-review] [--llm-mode auto|off|force]

Notes:
  Batch mode is interactive:
  1) Show available Phase2 output indexes (IR-order)
  2) Ask start index / end index
  3) Ask thread count

  Freshness-aware by default:
  - `phase3.json` is reused when it is newer than direct gate inputs
  - `phase3.final.json` is canonical only when it is not older than `phase3.json`
  - markdown is re-rendered only when its canonical Phase 3 input changes

Flags:
  --apply-review   Optional feedback loop. Apply phase3-review corrections to phase2 and re-run gate.
  --llm-mode       auto: only when gate has uncertain/risk_note findings (default)
                   off: never run phase3 LLM reviewer
                   force: always run phase3 LLM reviewer
  --with-claude    Convenience flag: run both codex and claude
  --provider       Single LLM provider shorthand: codex|claude
  --providers      Provider list, comma-separated (for example: codex,claude)
  --model          Set the same model for both providers
  --codex-model    Codex model override
  --claude-model   Claude model override
  --primary-provider Canonical provider when multiple providers run
  --codex-bin      Codex CLI binary/path (default: env CODEX_BIN or codex)
  --claude-bin     Claude Code binary/path (default: env CLAUDE_BIN or claude)
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
        --force)
            FORCE=true
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
            PHASE3_PRIMARY_PROVIDER="${2:-}"
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

if [[ "$LLM_MODE" != "auto" && "$LLM_MODE" != "off" && "$LLM_MODE" != "force" ]]; then
    log_error "Invalid --llm-mode: $LLM_MODE (expected: auto|off|force)"
    exit 1
fi

if [ "$WITH_CLAUDE" = true ] && [ "$PROVIDERS_EXPLICIT" != true ]; then
    LLM_PROVIDERS="codex,claude"
fi

PROMPT_TEMPLATE=""
for candidate in \
    "${TOOLS_DIR}/config/phase3-prompt-template.md" \
    "${ROOT_DIR}/phase3-prompt-template.md"
do
    if [ -f "$candidate" ]; then
        PROMPT_TEMPLATE="$candidate"
        break
    fi
done

ensure_report_dirs

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

phase3_pipeline_progress_enabled() {
    [ "${PIPELINE_PROGRESS_MODE:-off}" != "off" ] && [ "${PIPELINE_PROGRESS_PHASE3_WEIGHT:-0}" -gt 0 ] 2>/dev/null
}

phase3_pipeline_overall_percent() {
    local phase_percent="${1:-0}"
    local phase1_weight="${PIPELINE_PROGRESS_PHASE1_WEIGHT:-0}"
    local phase2_weight="${PIPELINE_PROGRESS_PHASE2_WEIGHT:-0}"
    local phase3_weight="${PIPELINE_PROGRESS_PHASE3_WEIGHT:-0}"
    local overall=$(( phase1_weight + phase2_weight + (phase3_weight * phase_percent) / 100 ))
    if [ "$overall" -gt 100 ]; then
        overall=100
    fi
    printf '%s' "$overall"
}

phase3_progress_format_seconds() {
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

phase3_progress_eta_suffix() {
    local overall="${1:-0}"
    local now elapsed estimated_total remaining

    phase3_pipeline_progress_enabled || return 0
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
    printf ' | ETA ~%s' "$(phase3_progress_format_seconds "$remaining")"
}

phase3_progress_suffix() {
    local phase_percent="${1:-0}"
    local overall
    phase3_pipeline_progress_enabled || return 0
    overall="$(phase3_pipeline_overall_percent "$phase_percent")"
    printf ' | Phase 3 ~%s%% | Pipeline ~%s%%%s' "$phase_percent" "$overall" "$(phase3_progress_eta_suffix "$overall")"
}

if ! provider_in_list "$PHASE3_PRIMARY_PROVIDER"; then
    PHASE3_PRIMARY_PROVIDER="${LLM_PROVIDER_ARRAY[0]}"
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

phase3_canonical_path() {
    python3 "$ARTIFACT_FRESHNESS_BIN" canonical-phase3 --phase3-dir "$PHASE3_DIR" --slug "$1" 2>/dev/null || true
}

phase2_output_trust_state() {
    local phase2_file="$1"
    python3 "$ARTIFACT_FRESHNESS_BIN" phase2-trust-state --path "$phase2_file" 2>/dev/null || true
}

phase2_output_is_trusted() {
    local phase2_file="$1"
    python3 "$ARTIFACT_FRESHNESS_BIN" phase2-is-trusted --path "$phase2_file" >/dev/null 2>&1
}

phase3_gate_is_fresh() {
    local slug="$1"
    local phase2_file="${PHASE2_DIR}/${slug}-phase2.json"
    local ir_file="${PHASE1_DIR}/${slug}-ir.json"
    local ir_supplement_file="${PHASE1_DIR}/${slug}-ir-supplement.json"
    local semgrep_file="${PHASE1_DIR}/${slug}-semgrep.json"
    local psalm_file="${PHASE1_DIR}/${slug}-psalm.sarif"
    local plugin_dir="${PLUGINS_DIR}/${slug}"
    local gate_output="${PHASE3_DIR}/${slug}-phase3.json"
    local -a inputs=("$phase2_file" "$ir_file" "$plugin_dir" "${BIN_DIR}/phase3_gate.py" "${BIN_DIR}/run-phase3.sh")
    if [ -f "$ir_supplement_file" ]; then
        inputs+=("$ir_supplement_file")
    fi
    if [ -f "$semgrep_file" ]; then
        inputs+=("$semgrep_file")
    fi
    if [ -f "$psalm_file" ]; then
        inputs+=("$psalm_file")
    fi
    phase2_output_is_trusted "$phase2_file" || return 1
    freshness_is_fresh "$gate_output" "${inputs[@]}"
}

phase3_reviews_are_fresh() {
    local slug="$1"
    local idx="$2"
    local gate_output="${PHASE3_DIR}/${slug}-phase3.json"
    local canonical_review_json="${PHASE3_DIR}/${slug}-phase3-review.json"
    local review_json md_path
    local -a inputs=("$gate_output" "${BIN_DIR}/phase3_llm_review.py" "${BIN_DIR}/run-phase3.sh")

    if [ -n "$PROMPT_TEMPLATE" ]; then
        inputs+=("$PROMPT_TEMPLATE")
    fi

    if ! freshness_is_fresh "$canonical_review_json" "${inputs[@]}"; then
        return 1
    fi
    phase3_review_json_is_valid "$slug" "$canonical_review_json" || return 1

    local provider
    for provider in "${LLM_PROVIDER_ARRAY[@]}"; do
        review_json="$(phase3_review_json_path "$slug" "$provider")"
        md_path="$(phase3_review_md_path "$slug" "$idx" "$provider")"
        if ! freshness_is_fresh "$review_json" "${inputs[@]}"; then
            return 1
        fi
        phase3_review_json_is_valid "$slug" "$review_json" || return 1
        if ! freshness_is_fresh "$md_path" "${inputs[@]}"; then
            return 1
        fi
    done

    return 0
}

phase3_final_is_fresh() {
    local slug="$1"
    local gate_output="${PHASE3_DIR}/${slug}-phase3.json"
    local review_json="${PHASE3_DIR}/${slug}-phase3-review.json"
    local final_output="${PHASE3_DIR}/${slug}-phase3.final.json"
    local -a inputs=("$gate_output" "$review_json" "${BIN_DIR}/phase3_apply_review.py" "${BIN_DIR}/run-phase3.sh")
    phase3_review_json_is_valid "$slug" "$review_json" || return 1
    freshness_is_fresh "$final_output" "${inputs[@]}"
}

phase3_markdown_is_fresh() {
    local slug="$1"
    local idx="$2"
    local phase2_file="${PHASE2_DIR}/${slug}-phase2.json"
    local markdown_path="${PHASE3_DIR}/${idx}-${slug}.md"
    local final_report_path="${REPORTS_DIR}/final/${idx}-${slug}.md"
    local canonical_path
    canonical_path="$(phase3_canonical_path "$slug")"
    if [ -z "$canonical_path" ]; then
        return 1
    fi
    local -a inputs=("$canonical_path" "$phase2_file" "${BIN_DIR}/phase3_write_md.py")
    freshness_is_fresh "$markdown_path" "${inputs[@]}" || return 1
    freshness_is_fresh "$final_report_path" "${inputs[@]}"
}

provider_model() {
    case "$1" in
        codex) printf '%s' "$CODEX_MODEL" ;;
        claude) printf '%s' "$CLAUDE_MODEL" ;;
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

phase3_review_json_path() {
    printf '%s/%s-phase3-review.%s.json' "$PHASE3_DIR" "$1" "$2"
}

phase3_review_md_path() {
    printf '%s/%s-%s.%s.llm.md' "$PHASE3_DIR" "$2" "$1" "$3"
}

phase3_errlog_path() {
    logs_phase3_provider_err_path "$1" "$2"
}

phase3_live_log_path() {
    logs_phase3_provider_live_path "$1" "$2"
}

phase3_raw_log_path() {
    logs_phase3_provider_raw_path "$1" "$2"
}

phase3_canonical_errlog_path() {
    logs_phase3_run_err_path "$1"
}

phase3_canonical_live_log_path() {
    logs_phase3_run_live_path "$1"
}

phase3_review_json_is_valid() {
    local slug="$1"
    local review_json="$2"
    [ -f "$review_json" ] || return 1
    python3 "$PHASE3_REVIEW_CONTRACT_BIN" validate-file --path "$review_json" --slug "$slug" --write-normalized >/dev/null 2>&1
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
    local errlog_path="${10:-}"
    local live_log_path="${11:-}"
    local raw_log_path="${12:-}"

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
        --errlog-path "$errlog_path" \
        --live-log-path "$live_log_path" \
        --raw-log-path "$raw_log_path" >/dev/null
}

IR_FILES=()
while IFS= read -r ir_file; do
    IR_FILES+=("$ir_file")
done < <(find "$PHASE1_DIR" -maxdepth 1 -type f -name '*-ir.json' | sort)
if [ "${#IR_FILES[@]}" -eq 0 ]; then
    log_error "No Phase 1 IR files found in $PHASE1_DIR"
    exit 1
fi

ir_index_for_slug() {
    local target_slug="$1"
    local ir_file file_slug idx
    idx=0
    for ir_file in "${IR_FILES[@]}"; do
        file_slug="$(basename "$ir_file" -ir.json)"
        case "$file_slug" in
            plugin-*) continue ;;
        esac
        idx=$((idx + 1))
        if [ "$file_slug" = "$target_slug" ]; then
            printf '%s' "$idx"
            return 0
        fi
    done
    return 1
}

run_phase3_provider_reviews() {
    local slug="$1"
    local idx="$2"
    local canonical_review_json="${PHASE3_DIR}/${slug}-phase3-review.json"
    local stage_dir pids provider review_json md_path err_path live_path raw_path model start_ts end_ts duration status
    local selected_provider=""
    stage_dir="$(mktemp -d)"
    pids=()
    rm -f "$canonical_review_json" "${PHASE3_DIR}/${idx}-${slug}.llm.md"
    rm -f "$(phase3_canonical_errlog_path "$slug")" "$(phase3_canonical_live_log_path "$slug")"
    for provider in codex claude; do
        rm -f "$(phase3_review_json_path "$slug" "$provider")" \
              "$(phase3_review_md_path "$slug" "$idx" "$provider")" \
              "$(phase3_errlog_path "$slug" "$provider")" \
              "$(phase3_live_log_path "$slug" "$provider")"
    done

    for provider in "${LLM_PROVIDER_ARRAY[@]}"; do
        review_json="$(phase3_review_json_path "$slug" "$provider")"
        md_path="$(phase3_review_md_path "$slug" "$idx" "$provider")"
        err_path="$(phase3_errlog_path "$slug" "$provider")"
        live_path="$(phase3_live_log_path "$slug" "$provider")"
        raw_path="$(phase3_raw_log_path "$slug" "$provider")"
        reset_log_file "$err_path"
        reset_log_file "$live_path"
        reset_log_file "$raw_path"
        append_log_marker "$live_path" "phase3 llm start slug=${slug} provider=${provider} output_json=${review_json} output_md=${md_path}"

        (
            local cmd
            cmd=(python3 "${BIN_DIR}/phase3_llm_review.py" "$slug" --reports-dir "$REPORTS_DIR" --plugins-dir "$PLUGINS_DIR" --index "$idx" --provider "$provider" --codex-bin "$CODEX_BIN" --claude-bin "$CLAUDE_BIN" --review-output-path "$review_json" --output-path "$md_path" --err-path "$err_path" --raw-path "$raw_path")
            model="$(provider_model "$provider")"
            if [ -n "$model" ]; then
                cmd+=(--model "$model")
            fi
            if [ "$FORCE" = true ]; then
                cmd+=(--force)
            fi
            if [ -n "$PROMPT_TEMPLATE" ]; then
                cmd+=(--prompt-template "$PROMPT_TEMPLATE")
            fi

            start_ts="$(date +%s)"
            set +e
            "${cmd[@]}" >>"$live_path" 2>>"$live_path"
            llm_rc=$?
            set -e
            end_ts="$(date +%s)"
            duration=$((end_ts - start_ts))
            status="ok"
            if [ "$llm_rc" -ne 0 ]; then
                status="failed"
            fi
            append_log_marker "$live_path" "phase3 llm end slug=${slug} provider=${provider} status=${status} rc=${llm_rc} duration_seconds=${duration}"
            append_quota_log "phase3" "$slug" "llm_skeptic" "$provider" "$model" "$status" "$duration" \
                "phase3_llm_review" "reviewer" "$err_path" "$live_path" "$raw_path"
            echo "$llm_rc" > "${stage_dir}/${provider}.rc"
        ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    for provider in "${LLM_PROVIDER_ARRAY[@]}"; do
        if [ "$(cat "${stage_dir}/${provider}.rc" 2>/dev/null || echo 1)" -ne 0 ]; then
            log_warn_block "Phase 3b ${provider} review failed (non-blocking)" \
                "slug" "$slug" \
                "reason" "$(summarize_provider_errlog "$(phase3_errlog_path "$slug" "$provider")")" \
                "log" "$(phase3_errlog_path "$slug" "$provider")" \
                "live_log" "$(phase3_live_log_path "$slug" "$provider")"
        fi
    done

    if provider_in_list "$PHASE3_PRIMARY_PROVIDER" && [ -f "$(phase3_review_json_path "$slug" "$PHASE3_PRIMARY_PROVIDER")" ]; then
        if phase3_review_json_is_valid "$slug" "$(phase3_review_json_path "$slug" "$PHASE3_PRIMARY_PROVIDER")"; then
            selected_provider="$PHASE3_PRIMARY_PROVIDER"
        else
            log_warn "Primary provider review artifact is invalid and will not be selected: $(phase3_review_json_path "$slug" "$PHASE3_PRIMARY_PROVIDER")"
        fi
    else
        for provider in "${LLM_PROVIDER_ARRAY[@]}"; do
            if phase3_review_json_is_valid "$slug" "$(phase3_review_json_path "$slug" "$provider")"; then
                selected_provider="$provider"
                break
            elif [ -f "$(phase3_review_json_path "$slug" "$provider")" ]; then
                log_warn "Skipping invalid Phase 3 review artifact: $(phase3_review_json_path "$slug" "$provider")"
            fi
        done
    fi

    if [ -n "$selected_provider" ]; then
        cp -f "$(phase3_review_json_path "$slug" "$selected_provider")" "$canonical_review_json"
        if [ -f "$(phase3_errlog_path "$slug" "$selected_provider")" ]; then
            cp -f "$(phase3_errlog_path "$slug" "$selected_provider")" "$(phase3_canonical_errlog_path "$slug")"
        fi
        if [ -f "$(phase3_live_log_path "$slug" "$selected_provider")" ]; then
            cp -f "$(phase3_live_log_path "$slug" "$selected_provider")" "$(phase3_canonical_live_log_path "$slug")"
        fi
        log_info "Selected provider review: ${selected_provider}"
    fi

    rm -rf "$stage_dir"
}

run_one() {
    local slug="$1"
    local idx="${2:-}"
    local phase2_file="${PHASE2_DIR}/${slug}-phase2.json"
    local ir_file="${PHASE1_DIR}/${slug}-ir.json"
    local plugin_dir="${PLUGINS_DIR}/${slug}"
    local gate_output="${PHASE3_DIR}/${slug}-phase3.json"
    local canonical_review_json="${PHASE3_DIR}/${slug}-phase3-review.json"
    if [ -z "$idx" ]; then
        idx="$(ir_index_for_slug "$slug" 2>/dev/null || true)"
    fi
    local gate_md="${PHASE3_DIR}/${idx}-${slug}.md"
    local final_report="${REPORTS_DIR}/final/${idx}-${slug}.md"
    local did_work=false

    if [ -z "${AUDIT_RUN_ID:-}" ]; then
        AUDIT_RUN_ID="${slug}-phase3-$(date -u +%Y%m%dT%H%M%SZ)-$$"
        export AUDIT_RUN_ID
    fi

    if [ ! -f "$phase2_file" ]; then
        log_error_block "Phase 2 output not found" \
            "slug" "$slug" \
            "path" "$phase2_file"
        RUN_RESULT="failed"
        return 1
    fi

    local phase2_trust_state
    phase2_trust_state="$(phase2_output_trust_state "$phase2_file")"
    if ! phase2_output_is_trusted "$phase2_file"; then
        log_error_block "Phase 2 canonical is not trusted for Phase 3" \
            "slug" "$slug" \
            "path" "$phase2_file" \
            "trust_state" "${phase2_trust_state:-missing}"
        RUN_RESULT="failed"
        return 1
    fi

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

    if [ -z "$idx" ]; then
        log_error_block "Could not resolve IR-order index" \
            "slug" "$slug"
        RUN_RESULT="failed"
        return 1
    fi

    log_section "Phase 3: ${slug}"
    echo "  Reports dir: ${REPORTS_DIR}"
    echo "  Plugins dir: ${PLUGINS_DIR}"
    echo "  LLM mode: ${LLM_MODE}"
    echo "  LLM providers: [${LLM_PROVIDERS}]"
    echo "  Canonical provider: ${PHASE3_PRIMARY_PROVIDER}"
    if [ -n "$CODEX_MODEL" ]; then
        echo "  Codex model: ${CODEX_MODEL}"
    fi
    if [ -n "$CLAUDE_MODEL" ]; then
        echo "  Claude model: ${CLAUDE_MODEL}"
    fi
    if [ -n "$PROMPT_TEMPLATE" ]; then
        echo "  Prompt template: ${PROMPT_TEMPLATE}"
    else
        echo "  Prompt template: built-in default"
    fi

    # Step 1: deterministic gate (authoritative).
    if [ "$FORCE" = true ] || ! phase3_gate_is_fresh "$slug"; then
        log_stage "Phase 3a: Deterministic Gate$(phase3_progress_suffix 10)"
        python3 "${BIN_DIR}/phase3_gate.py" "$slug" \
            --reports-dir "$REPORTS_DIR" \
            --plugins-dir "$PLUGINS_DIR" || {
            log_error_block "Phase 3a gate failed" \
                "slug" "$slug"
            RUN_RESULT="failed"
            return 1
        }
        did_work=true
    else
        log_info "Reuse ${slug}: phase3 gate output is fresh"
    fi

    if [ ! -f "$gate_output" ]; then
        log_error_block "Gate output not generated" \
            "slug" "$slug" \
            "path" "$gate_output"
        RUN_RESULT="failed"
        return 1
    fi

    local needs_llm confirmed
    needs_llm=$(python3 -c "
import json
d = json.load(open('${gate_output}'))
p3 = d.get('phase3_summary', {})
print(int(p3.get('uncertain', 0)) + int(p3.get('risk_note', 0)))
" 2>/dev/null || echo "0")

    confirmed=$(python3 -c "
import json
d = json.load(open('${gate_output}'))
print(int(d.get('phase3_summary', {}).get('confirmed', 0)))
" 2>/dev/null || echo "0")

    log_info "Gate results: ${confirmed} confirmed, ${needs_llm} need LLM review$(phase3_progress_suffix 55)"

    # Step 2: optional LLM skeptic review.
    local run_llm=false
    if [ "$LLM_MODE" = "force" ]; then
        run_llm=true
    elif [ "$LLM_MODE" = "off" ]; then
        run_llm=false
    elif [ "$needs_llm" -gt 0 ]; then
        run_llm=true
    fi

    if [ "$run_llm" = true ]; then
        if [ "$FORCE" = true ] || ! phase3_reviews_are_fresh "$slug" "$idx"; then
            log_stage "Phase 3b: LLM Skeptic Review$(phase3_progress_suffix 70)"
            run_phase3_provider_reviews "$slug" "$idx"
            did_work=true
        else
            log_info "Reuse ${slug}: phase3 review artifacts are fresh"
        fi
    else
        log_stage "Phase 3b: SKIPPED (llm-mode=${LLM_MODE}, needs_llm=${needs_llm})$(phase3_progress_suffix 90)"
    fi

    if [ "$APPLY_REVIEW" = true ] && [ -f "${BIN_DIR}/phase3_apply_review.py" ] && [ -f "$canonical_review_json" ]; then
        if [ "$FORCE" = true ] || ! phase3_final_is_fresh "$slug"; then
            log_stage "Applying review corrections (optional)$(phase3_progress_suffix 90)"
            python3 "${BIN_DIR}/phase3_apply_review.py" "$slug" \
                --reports-dir "$REPORTS_DIR" \
                --plugins-dir "$PLUGINS_DIR" || true
            did_work=true
        else
            log_info "Reuse ${slug}: phase3 final snapshot is fresh"
        fi
    fi

    local canonical_path
    canonical_path="$(phase3_canonical_path "$slug")"
    if [ -z "$canonical_path" ]; then
        log_error_block "Canonical Phase 3 artifact not found" \
            "slug" "$slug"
        RUN_RESULT="failed"
        return 1
    fi

    if [ "$FORCE" = true ] || ! phase3_markdown_is_fresh "$slug" "$idx"; then
        python3 "${BIN_DIR}/phase3_write_md.py" "$slug" \
            --reports-dir "$REPORTS_DIR" \
            --index "$idx" || true
        did_work=true
    else
        log_info "Reuse ${slug}: phase3 markdown is fresh"
    fi

    echo "  Deterministic report: ${gate_md}"
    echo "  Final report: ${final_report}"
    echo "  Canonical Phase 3 artifact: ${canonical_path}"
    if [ ! -f "$final_report" ]; then
        log_error_block "Final report not generated" \
            "slug" "$slug" \
            "path" "$final_report"
        RUN_RESULT="failed"
        return 1
    fi
    local provider_md
    for provider in "${LLM_PROVIDER_ARRAY[@]}"; do
        provider_md="$(phase3_review_md_path "$slug" "$idx" "$provider")"
        if [ -f "$provider_md" ]; then
            echo "  LLM skeptic report (${provider}): ${provider_md}"
        fi
    done
    if phase3_pipeline_progress_enabled; then
        echo "  Pipeline progress: $(phase3_pipeline_overall_percent 100)% (Phase 3 complete)"
    fi
    if [ "$did_work" = true ]; then
        RUN_RESULT="done"
    else
        log_info "Skip ${slug}: phase3 artifacts are fresh"
        RUN_RESULT="skipped"
    fi
    log_section "Done Phase 3: ${slug}"
    return 0
}

if [ -n "$SPECIFIC_SLUG" ]; then
    run_one "$SPECIFIC_SLUG"
    exit $?
fi

# Collect trusted Phase 2 outputs with IR-order index.
PHASE2_FILES=()
while IFS= read -r phase2_file; do
    PHASE2_FILES+=("$phase2_file")
done < <(find "$PHASE2_DIR" -maxdepth 1 -type f -name '*-phase2.json' | sort)
if [ "${#PHASE2_FILES[@]}" -eq 0 ]; then
    log_error "No Phase 2 files found in $PHASE2_DIR"
    exit 1
fi

INDEXED_FILE="$(mktemp)"
trap 'rm -f "${INDEXED_FILE:-}" "${WORKER_FILE:-}" "${STATUS_FILE:-}" "${SELECTED_FILE:-}"' EXIT

UNTRUSTED_COUNT=0

for phase2_file in "${PHASE2_FILES[@]}"; do
    slug="$(basename "$phase2_file" -phase2.json)"
    case "$slug" in
        plugin-*) continue ;;
    esac

    if ! phase2_output_is_trusted "$phase2_file"; then
        UNTRUSTED_COUNT=$((UNTRUSTED_COUNT + 1))
        continue
    fi

    idx="$(ir_index_for_slug "$slug" 2>/dev/null || true)"
    if [ -z "$idx" ]; then
        continue
    fi
    printf '%s|%s\n' "$idx" "$slug" >> "$INDEXED_FILE"
done

if [ ! -s "$INDEXED_FILE" ]; then
    log_error "No trusted Phase 2 outputs matched Phase 1 index map"
    exit 1
fi

INDEXED_PHASE2=()
while IFS= read -r entry; do
    INDEXED_PHASE2+=("$entry")
done < <(sort -t'|' -k1,1n "$INDEXED_FILE")

AVAILABLE_COUNT=0
AVAILABLE_INDEX_CSV=""
for entry in "${INDEXED_PHASE2[@]}"; do
    idx="${entry%%|*}"
    AVAILABLE_COUNT=$((AVAILABLE_COUNT + 1))
    if [ -n "$AVAILABLE_INDEX_CSV" ]; then
        AVAILABLE_INDEX_CSV+="${idx},"
    else
        AVAILABLE_INDEX_CSV="${idx},"
    fi
done
AVAILABLE_INDEX_CSV="${AVAILABLE_INDEX_CSV%,}"

log_section "Phase 3 Batch (Interactive)"
echo "  Trusted Phase2 outputs available: ${AVAILABLE_COUNT}"
echo "  Untrusted Phase2 outputs skipped: ${UNTRUSTED_COUNT}"
echo "  Indexes (IR-order): [${AVAILABLE_INDEX_CSV}]"
echo "  Force overwrite: ${FORCE}"
echo "  Apply review corrections: ${APPLY_REVIEW}"
echo "  LLM mode: ${LLM_MODE}"
echo "  LLM providers: [${LLM_PROVIDERS}]"
echo "  Canonical provider: ${PHASE3_PRIMARY_PROVIDER}"
if [ -n "$CODEX_MODEL" ]; then
    echo "  Codex model: ${CODEX_MODEL}"
fi
if [ -n "$CLAUDE_MODEL" ]; then
    echo "  Claude model: ${CLAUDE_MODEL}"
fi
if [ -n "$PROMPT_TEMPLATE" ]; then
    echo "  Prompt template: ${PROMPT_TEMPLATE}"
else
    echo "  Prompt template: built-in default"
fi

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

SELECTED_FILE="$(mktemp)"
SELECTED_COUNT=0

for entry in "${INDEXED_PHASE2[@]}"; do
    idx="${entry%%|*}"
    if [ "$idx" -lt "$START_INDEX" ] || [ "$idx" -gt "$END_INDEX" ]; then
        continue
    fi
    printf '%s\n' "$entry" >> "$SELECTED_FILE"
    SELECTED_COUNT=$((SELECTED_COUNT + 1))
done

if [ "$SELECTED_COUNT" -eq 0 ]; then
    log_error "No Phase2 outputs found in selected range ${START_INDEX}..${END_INDEX}"
    exit 1
fi

SELECTED_INDEX_CSV="$(cut -d'|' -f1 "$SELECTED_FILE" | paste -sd, -)"
echo "  Selected count: ${SELECTED_COUNT}"
echo "  Selected indexes: [${SELECTED_INDEX_CSV}]"
echo "  Threads: ${THREADS}"

WORKER_FILE="$(mktemp)"
STATUS_FILE="$(mktemp)"

cat > "$WORKER_FILE" <<'EOF'
#!/bin/bash
set -euo pipefail

entry="$1"
idx="${entry%%|*}"
slug="${entry#*|}"
cmd=(bash "${SELF_SCRIPT}" --slug "$slug" --llm-mode "$LLM_MODE")
if [ "${FORCE}" = true ]; then
    cmd+=(--force)
fi
if [ "${APPLY_REVIEW}" = true ]; then
    cmd+=(--apply-review)
fi
set +e
out="$("${cmd[@]}" 2>&1)"
rc=$?
set -e
echo "$out"
if [ $rc -ne 0 ]; then
    echo "failed|${idx}|${slug}" >> "$STATUS_FILE"
elif echo "$out" | grep -Eq '^\[(INFO|=)\] Skip '; then
    echo "skipped|${idx}|${slug}" >> "$STATUS_FILE"
else
    echo "done|${idx}|${slug}" >> "$STATUS_FILE"
fi

exit 0
EOF

chmod +x "$WORKER_FILE"
export SELF_SCRIPT="${BIN_DIR}/run-phase3.sh" FORCE APPLY_REVIEW STATUS_FILE LLM_MODE LLM_PROVIDERS CODEX_BIN CODEX_MODEL CLAUDE_BIN CLAUDE_MODEL PHASE3_PRIMARY_PROVIDER

echo ""
log_section "Running Phase 3 (Gate -> LLM Skeptic)"

xargs -P "$THREADS" -I {} "$WORKER_FILE" "{}" < "$SELECTED_FILE"

DONE=$(grep -c '^done|' "$STATUS_FILE" 2>/dev/null || true)
SKIPPED=$(grep -c '^skipped|' "$STATUS_FILE" 2>/dev/null || true)
FAILED=$(grep -c '^failed|' "$STATUS_FILE" 2>/dev/null || true)

echo ""
log_section "Phase 3 Batch Complete"
echo "  Considered: ${SELECTED_COUNT}"
echo "  Done:    ${DONE}"
echo "  Failed:  ${FAILED}"
echo "  Skipped: ${SKIPPED}"
echo "  Quota ledger: ${QUOTA_LEDGER}"

if [ -f "${BIN_DIR}/quota-report.py" ]; then
    echo ""
    python3 "${BIN_DIR}/quota-report.py" --reports-dir "$REPORTS_DIR" --phase phase3 --days 1 --limit 10 || true
fi

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi

exit 0
