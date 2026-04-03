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
INTERACTIVE=false
WITH_CLAUDE=false
PROVIDERS_EXPLICIT=false
RUN_RESULT=""
LLM_PROVIDERS="${LLM_PROVIDERS:-${LLM_PROVIDER:-codex}}"
CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_MODEL="${CODEX_MODEL:-${LLM_MODEL:-}}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_MODEL="${CLAUDE_MODEL:-${LLM_MODEL:-}}"
PHASE2_PRIMARY_PROVIDER="${PHASE2_PRIMARY_PROVIDER:-codex}"
PHASE2_PROVIDER_TIMEOUT_SECONDS="${PHASE2_PROVIDER_TIMEOUT_SECONDS:-1200}"

START_SET=false
END_SET=false
THREADS_SET=false

usage() {
    cat <<'EOF'
Usage:
  run-phase2.sh <plugin-slug>
  run-phase2.sh --slug <plugin-slug> [--force] [--force-deep]
  run-phase2.sh --start-index <N> --end-index <M> [--threads <N>] [--force] [--force-deep]
  run-phase2.sh --interactive [--force] [--force-deep]

Options:
  --slug <slug>          Run one plugin.
  --start-index <N>      Batch start index (IR-order, 1-based).
  --end-index <N>        Batch end index (IR-order, 1-based).
  --threads <N>          Parallel workers for batch mode (default: 1).
  --interactive          Show index list and ask Start/End/Threads.
  --force                Re-run even if reports/phase2/<slug>-phase2.json exists.
  --force-deep           Skip quick-triage and always run deep prompt.
  --with-claude          Convenience flag: run both codex and claude.
  --provider <name>      Single LLM provider shorthand: codex|claude.
  --providers <list>     Provider list, comma-separated (for example: codex,claude).
  --model <name>         Set the same model for both providers.
  --codex-model <name>   Codex model override.
  --claude-model <name>  Claude model override.
  --primary-provider <p> Canonical provider when multiple providers run.
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
for candidate in \
    "${TOOLS_DIR}/config/system-prompt-phase2.md" \
    "${ROOT_DIR}/system-prompt-phase2.md"
do
    if [ -f "$candidate" ]; then
        SYSTEM_PROMPT_PHASE2="$(cat "$candidate")"
        break
    fi
done

if [ -z "$SYSTEM_PROMPT_PHASE2" ]; then
    SYSTEM_PROMPT_PHASE2='Khi thuc hien WP plugin security audit, LUON load skill `$application-security` truoc.'
fi

ensure_report_dirs
resolve_timeout_backend || true

if ! [[ "$PHASE2_PROVIDER_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid PHASE2_PROVIDER_TIMEOUT_SECONDS=$PHASE2_PROVIDER_TIMEOUT_SECONDS. Using default 1200s."
    PHASE2_PROVIDER_TIMEOUT_SECONDS=1200
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

if ! provider_in_list "$PHASE2_PRIMARY_PROVIDER"; then
    PHASE2_PRIMARY_PROVIDER="${LLM_PROVIDER_ARRAY[0]}"
fi

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

phase2_output_path() {
    printf '%s/%s-phase2.%s.json' "$PHASE2_DIR" "$1" "$2"
}

phase2_raw_path() {
    printf '%s/%s-phase2.%s.raw.json' "$PHASE2_DIR" "$1" "$2"
}

phase2_output_rel() {
    printf 'reports/phase2/%s-phase2.%s.json' "$1" "$2"
}

phase2_errlog_path() {
    if [ "$3" = "quick" ]; then
        printf '%s/%s-phase2-quick.%s.err' "$LOGS_DIR" "$1" "$2"
    else
        printf '%s/%s-phase2.%s.err' "$LOGS_DIR" "$1" "$2"
    fi
}

render_phase2_template_prompt() {
    python3 - "$PROMPT_TEMPLATE" "$1" "$2" <<'PY'
from pathlib import Path
import sys

template_path, slug, output_path = sys.argv[1:4]
text = Path(template_path).read_text(encoding="utf-8", errors="replace")
text = text.replace("{PLUGIN_SLUG}", slug)
text = text.replace("{OUTPUT_PATH}", output_path)
print(text, end="")
PY
}

render_phase2_quick_prompt() {
    local slug="$1"
    local output_rel="$2"
    printf 'Quick triage mode for plugin `%s`.\nInputs:\n- Phase 1 IR: `reports/phase1/%s-ir.json`\n- Semgrep: `reports/phase1/%s-semgrep.json` (if exists)\n- Psalm SARIF: `reports/phase1/%s-psalm.sarif` (if exists; corroboration only)\n- Source: `plugins/%s/`\n\nTask:\n1) Read IR (AST-derived) and spot-check only high-risk code paths in source.\n2) Focus on meaningful security impact only (Patchstack-eligible first).\n3) If nothing meaningful, return empty findings with concise negative_findings.\n4) Keep reasoning concise, but evidence-bound.\n\nSchema requirements (critical):\n- Every TP/REVIEW MUST include: entry_point_id, source_file_path+source_line_number, sink_file_path+sink_line_number, source_function, sink_function.\n- All path fields must be relative to the plugin root. Never prefix them with `plugins/%s/`.\n- Keep backcompat aliases: file_path = sink_file_path, line_number = sink_line_number.\n- Stored/second-order: include storage_key when literal; otherwise mark REVIEW and explain.\n\nOutput strictly to `%s`.' "$slug" "$slug" "$slug" "$slug" "$slug" "$slug" "$output_rel"
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

    if [ "$provider" != "claude" ]; then
        printf '%s' "$prompt"
        return 0
    fi

    printf '%s' "$prompt" | python3 - "$fallback_file" <<'PY'
import re
import sys
from pathlib import Path

fallback_file = Path(sys.argv[1])
text = sys.stdin.read()
lines = [line for line in text.splitlines() if "application-security" not in line]
text = "\n".join(lines).strip()
extra = fallback_file.read_text(encoding="utf-8", errors="replace").strip() if fallback_file.exists() else (
    "Apply the WordPress audit workflow and evidence rules written in this prompt "
    "directly. Do not assume external skill auto-loading."
)
if text:
    print(f"{text}\n\n{extra}", end="")
else:
    print(extra, end="")
PY
}

run_llm_prompt() {
    local slug="$1"
    local mode="$2"
    local provider="$3"
    local system_prompt="$4"
    local prompt="$5"
    local errlog="$6"
    local model bin
    local start_ts end_ts rc duration status
    model="$(provider_model "$provider")"
    bin="$(provider_bin "$provider")"
    start_ts="$(date +%s)"
    if [ "$provider" = "codex" ]; then
        (
            cd "$ROOT_DIR"
            local cmd=("$bin" exec --full-auto --skip-git-repo-check)
            if [ -n "$model" ]; then
                cmd+=(--model "$model")
            fi
            cmd+=("${system_prompt}"$'\n\n'"${prompt}")
            if [ "$PHASE2_PROVIDER_TIMEOUT_SECONDS" -gt 0 ]; then
                timeout_run "$PHASE2_PROVIDER_TIMEOUT_SECONDS" "${cmd[@]}" 2>"$errlog"
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
                       --output-format stream-json
                       --include-partial-messages)
            if [ -n "$model" ]; then
                cmd+=(--model "$model")
            fi
            cmd+=(--append-system-prompt-file "$system_prompt_file" "$prompt")
            if [ "$PHASE2_PROVIDER_TIMEOUT_SECONDS" -gt 0 ]; then
                timeout_run "$PHASE2_PROVIDER_TIMEOUT_SECONDS" "${cmd[@]}" 2>"$errlog" \
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
        printf '[ERROR] provider timed out after %ss\n' "$PHASE2_PROVIDER_TIMEOUT_SECONDS" >> "$errlog"
    fi
    end_ts="$(date +%s)"
    duration=$((end_ts - start_ts))
    status="ok"
    if [ "$rc" -ne 0 ]; then
        status="failed"
    fi
    append_quota_log "phase2" "$slug" "$mode" "$provider" "$model" "$status" "$duration"
    return "$rc"
}

postprocess_phase2_output() {
    local slug="$1"
    local output_path="$2"
    python3 "${BIN_DIR}/phase2_postprocess.py" "$slug" \
        --reports-dir "$REPORTS_DIR" \
        --plugins-dir "$PLUGINS_DIR" \
        --phase2-path "$output_path" \
        --in-place
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
    local stage_dir pids provider system_prompt prompt errlog output_rel
    stage_dir="$(mktemp -d)"
    pids=()

    for provider in "${providers[@]}"; do
        system_prompt="$(normalize_system_prompt_for_provider "$provider" "$SYSTEM_PROMPT_PHASE2")"
        output_rel="$(phase2_output_rel "$slug" "$provider")"
        if [ "$stage" = "quick" ]; then
            prompt="$(render_phase2_quick_prompt "$slug" "$output_rel")"
        else
            prompt="$(render_phase2_template_prompt "$slug" "$output_rel")"
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
    local errlog_deep="${LOGS_DIR}/${slug}-phase2.err"
    local errlog_quick="${LOGS_DIR}/${slug}-phase2-quick.err"
    local selected_provider=""
    local LAST_STAGE_DIR=""

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

    if [ -f "$output" ] && [ "$FORCE" != true ]; then
        log_info "Skip ${slug}: phase2 already exists"
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
    echo "  LLM providers: [${LLM_PROVIDERS}]"
    echo "  Canonical provider: ${PHASE2_PRIMARY_PROVIDER}"
    if [ -n "$CODEX_MODEL" ]; then
        echo "  Codex model: ${CODEX_MODEL}"
    fi
    if [ -n "$CLAUDE_MODEL" ]; then
        echo "  Claude model: ${CLAUDE_MODEL}"
    fi
    if [ "$PHASE2_PROVIDER_TIMEOUT_SECONDS" -gt 0 ]; then
        echo "  Provider timeout: ${PHASE2_PROVIDER_TIMEOUT_SECONDS}s (${TIMEOUT_BACKEND})"
    else
        echo "  Provider timeout: disabled"
    fi

    rm -f "$output" "$raw_output" "$errlog_deep" "$errlog_quick"
    for provider in codex claude; do
        rm -f "$(phase2_output_path "$slug" "$provider")" \
              "$(phase2_raw_path "$slug" "$provider")" \
              "$(phase2_errlog_path "$slug" "$provider" deep)" \
              "$(phase2_errlog_path "$slug" "$provider" quick)"
    done

    if [ "$ep_count" -eq 0 ] || { [ "$anom_count" = "0" ] && [ "$source_count" = "0" ] && [ "$sink_count" = "0" ]; }; then
        echo "  AST triage: low/no surface -> writing deterministic phase2-lite output (no LLM)."
        write_lite_output "$slug" "$output" "Phase2-lite deterministic triage completed" \
            "$anom_count" "$ep_count" "$unauth_ep" "$sensitive_sinks" "$sql_sinks" "$rest_json_sources" "$output_sinks" "$source_count" "$sink_count"
        cp -f "$output" "$raw_output" 2>/dev/null || true
        local provider
        for provider in "${LLM_PROVIDER_ARRAY[@]}"; do
            cp -f "$output" "$(phase2_output_path "$slug" "$provider")" 2>/dev/null || true
            cp -f "$output" "$(phase2_raw_path "$slug" "$provider")" 2>/dev/null || true
        done
        RUN_RESULT="done"
        return 0
    fi

    local mode provider
    local -a providers_for_deep successful_providers
    providers_for_deep=()
    successful_providers=()

    mode="deep"
    if [ "$FORCE_DEEP" != true ] && [ "$anom_count" = "0" ] && [ "$unauth_ep" = "0" ] && [ "$sensitive_sinks" = "0" ] && [ "$sql_sinks" = "0" ] && [ "$rest_json_sources" = "0" ]; then
        mode="quick"
    fi

    if [ "$mode" = "quick" ]; then
        echo "  Running providers in parallel (quick triage)..."
        run_phase2_stage "$slug" "quick" "${LLM_PROVIDER_ARRAY[@]}"

        local quick_counts q_tp q_fp q_rv q_total q_risk provider_output provider_rc
        for provider in "${LLM_PROVIDER_ARRAY[@]}"; do
            provider_output="$(phase2_output_path "$slug" "$provider")"
            provider_rc="$(cat "${LAST_STAGE_DIR}/${provider}.rc" 2>/dev/null || echo 1)"
            if [ "$provider_rc" -ne 0 ]; then
                log_warn_block "${provider} quick triage failed" \
                    "slug" "$slug" \
                    "reason" "$(summarize_provider_errlog "$(phase2_errlog_path "$slug" "$provider" quick)")" \
                    "log" "$(phase2_errlog_path "$slug" "$provider" quick)"
                continue
            fi
            if [ ! -f "$provider_output" ]; then
                log_warn_block "${provider} quick output not generated" \
                    "slug" "$slug" \
                    "output" "$provider_output"
                continue
            fi
            quick_counts="$(phase2_counts "$provider_output")"
            IFS='|' read -r q_tp q_fp q_rv q_total q_risk <<< "$quick_counts"
            echo "  ${provider} quick results: ${q_tp} TP, ${q_fp} FP, ${q_rv} REVIEW | Risk: ${q_risk}"
            if [ "$q_tp" -gt 0 ] || [ "$q_rv" -gt 0 ]; then
                providers_for_deep+=("$provider")
            fi
        done
        rm -rf "$LAST_STAGE_DIR"

        if [ "${#providers_for_deep[@]}" -gt 0 ]; then
            echo "  Quick triage found potential issues -> escalating to deep analysis for: [$(IFS=,; echo "${providers_for_deep[*]}")]"
            run_phase2_stage "$slug" "deep" "${providers_for_deep[@]}"
            local provider_deep_rc
            for provider in "${providers_for_deep[@]}"; do
                provider_deep_rc="$(cat "${LAST_STAGE_DIR}/${provider}.rc" 2>/dev/null || echo 1)"
                if [ "$provider_deep_rc" -ne 0 ]; then
                    log_warn_block "${provider} deep analysis failed" \
                        "slug" "$slug" \
                        "reason" "$(summarize_provider_errlog "$(phase2_errlog_path "$slug" "$provider" deep)")" \
                        "log" "$(phase2_errlog_path "$slug" "$provider" deep)"
                fi
            done
            rm -rf "$LAST_STAGE_DIR"
        fi
    else
        echo "  Running providers in parallel (deep analysis)..."
        run_phase2_stage "$slug" "deep" "${LLM_PROVIDER_ARRAY[@]}"
        local provider_deep_rc
        for provider in "${LLM_PROVIDER_ARRAY[@]}"; do
            provider_deep_rc="$(cat "${LAST_STAGE_DIR}/${provider}.rc" 2>/dev/null || echo 1)"
            if [ "$provider_deep_rc" -ne 0 ]; then
                log_warn_block "${provider} deep analysis failed" \
                    "slug" "$slug" \
                    "reason" "$(summarize_provider_errlog "$(phase2_errlog_path "$slug" "$provider" deep)")" \
                    "log" "$(phase2_errlog_path "$slug" "$provider" deep)"
            fi
        done
        rm -rf "$LAST_STAGE_DIR"
    fi

    local counts tp fp rv total risk provider_output provider_raw
    for provider in "${LLM_PROVIDER_ARRAY[@]}"; do
        provider_output="$(phase2_output_path "$slug" "$provider")"
        provider_raw="$(phase2_raw_path "$slug" "$provider")"
        if [ ! -f "$provider_output" ]; then
            continue
        fi

        cp -f "$provider_output" "$provider_raw" 2>/dev/null || true
        if [ -f "${BIN_DIR}/phase2_postprocess.py" ]; then
            if ! postprocess_phase2_output "$slug" "$provider_output"; then
                log_warn_block "Phase2 postprocess failed" \
                    "slug" "$slug" \
                    "provider" "$provider" \
                    "output" "$provider_output"
                continue
            fi
        fi

        counts="$(phase2_counts "$provider_output")"
        IFS='|' read -r tp fp rv total risk <<< "$counts"
        echo "  ${provider} final results: ${tp} TP, ${fp} FP, ${rv} REVIEW | Risk: ${risk}"
        echo "  ${provider} raw output: ${provider_raw}"
        successful_providers+=("$provider")
    done

    if [ "${#successful_providers[@]}" -eq 0 ]; then
        log_error_block "No provider produced usable Phase 2 output" \
            "slug" "$slug"
        RUN_RESULT="failed"
        return 1
    fi

    if provider_in_list "$PHASE2_PRIMARY_PROVIDER" && [ -f "$(phase2_output_path "$slug" "$PHASE2_PRIMARY_PROVIDER")" ]; then
        selected_provider="$PHASE2_PRIMARY_PROVIDER"
    else
        selected_provider="${successful_providers[0]}"
    fi

    cp -f "$(phase2_output_path "$slug" "$selected_provider")" "$output"
    cp -f "$(phase2_raw_path "$slug" "$selected_provider")" "$raw_output" 2>/dev/null || true
    [ -f "$(phase2_errlog_path "$slug" "$selected_provider" deep)" ] && cp -f "$(phase2_errlog_path "$slug" "$selected_provider" deep)" "$errlog_deep" || true
    [ -f "$(phase2_errlog_path "$slug" "$selected_provider" quick)" ] && cp -f "$(phase2_errlog_path "$slug" "$selected_provider" quick)" "$errlog_quick" || true
    echo "  Canonical Phase 2 selected from provider: ${selected_provider}"
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
echo "  LLM providers: [${LLM_PROVIDERS}]"
echo "  Canonical provider: ${PHASE2_PRIMARY_PROVIDER}"
echo "  Prompt template: ${PROMPT_TEMPLATE}"

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
else
  echo "done|${slug}" >> "$STATUS_FILE"
fi
exit 0
EOF

    chmod +x "$WORKER_FILE"
    export SELF_SCRIPT="${BIN_DIR}/run-phase2.sh" FORCE FORCE_DEEP STATUS_FILE LLM_PROVIDERS CODEX_BIN CODEX_MODEL CLAUDE_BIN CLAUDE_MODEL PHASE2_PRIMARY_PROVIDER

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
