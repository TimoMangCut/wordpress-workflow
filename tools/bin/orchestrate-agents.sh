#!/usr/bin/env bash
# orchestrate-agents.sh — Multi-agent Phase 2 orchestrator
#
# Usage:
#   bash tools/bin/orchestrate-agents.sh <slug> [options]
#
# Options:
#   --parallel-limit N      Max agents running concurrently (default: 1, serial)
#   --timeout N             Override timeout_seconds from dispatch config (seconds)
#   --dispatch-file PATH    Override dispatch config path (default: reports/<slug>-dispatch.json)
#   --resume-missing-only   Skip agents whose output file already exists and is valid JSON
#   --help                  Show this help message
#
# Environment variables:
#   SKIP_QUOTA_PROBE=1      Skip preflight quota check (use when quota is confirmed healthy)
#   CODEX_QUOTA_ACCOUNT     Codex account identifier logged in failures/ledger (overrides dispatch)
#
# Pipeline:
#   1. Read reports/<slug>-dispatch.json
#   2. [Optional] Skip agents with valid existing output (--resume-missing-only)
#   3a. Preflight quota probe (codex exec trivial prompt) — Codex agents only
#   3b. Preflight Claude probe (claude -p trivial prompt) — Claude agents only
#   4. Launch agents serially by default (--parallel-limit 1), or in batches
#   5. Poll each agent for output file existence + valid JSON
#   6. Call python3 tools/bin/merge_agent_outputs.py <slug>
#   7. Write reports/<slug>-merge-ready sentinel
#
# Failures are logged to reports/logs/<slug>-failures.json
# Source: multi-agent-plan.md:400-520
#
# Compatibility: POSIX sh + bash 3.2+ (no declare -A, no mapfile)

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PARALLEL_LIMIT=1        # serial-by-default: Codex quota is expensive
RESUME_MISSING_ONLY=0   # 0 = run all; 1 = skip agents with valid existing output
POLL_INTERVAL=15        # seconds between completion polls
TIMEOUT_OVERRIDE=""     # empty = read from dispatch config
DISPATCH_FILE_OVERRIDE=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: orchestrate-agents.sh <slug> [options]

Arguments:
  <slug>                  Plugin slug (e.g. woocommerce)

Options:
  --parallel-limit N      Max agents running concurrently (default: 1 — serial)
  --timeout N             Timeout in seconds per agent (overrides dispatch config)
  --dispatch-file PATH    Path to dispatch config JSON (default: reports/<slug>-dispatch.json)
  --resume-missing-only   Skip agents whose output file already exists and is valid JSON.
                          Use after a quota-interrupted run to only rerun failed/missing agents.
  --help                  Show this message

Environment variables:
  SKIP_QUOTA_PROBE=1      Bypass preflight quota check
  CODEX_QUOTA_ACCOUNT     Codex account ID for traceability (logged in failures.json)

Examples:
  # Normal serial run (quota-safe default)
  bash tools/bin/orchestrate-agents.sh woocommerce

  # Resume after quota interruption (only run agents that did not write valid output)
  bash tools/bin/orchestrate-agents.sh woocommerce --resume-missing-only

  # Opt-in parallel run for faster processing on fresh quota
  bash tools/bin/orchestrate-agents.sh woocommerce --parallel-limit 3

  # Override timeout
  bash tools/bin/orchestrate-agents.sh woocommerce --timeout 1200
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  usage
  exit 0
fi

SLUG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --parallel-limit)
      PARALLEL_LIMIT="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT_OVERRIDE="$2"
      shift 2
      ;;
    --dispatch-file)
      DISPATCH_FILE_OVERRIDE="$2"
      shift 2
      ;;
    --resume-missing-only)
      RESUME_MISSING_ONLY=1
      shift
      ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "$SLUG" ]]; then
        SLUG="$1"
      else
        echo "ERROR: Unexpected argument: $1" >&2
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  echo "ERROR: <slug> is required." >&2
  usage
  exit 1
fi

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
REPORTS_DIR="$REPO_ROOT/reports"
LOGS_DIR="$REPORTS_DIR/logs"
DISPATCH_FILE="${DISPATCH_FILE_OVERRIDE:-$REPORTS_DIR/${SLUG}-dispatch.json}"
FAILURES_LOG="$LOGS_DIR/${SLUG}-failures.json"
MERGE_READY_SENTINEL="$REPORTS_DIR/${SLUG}-merge-ready"
MERGE_SCRIPT="$SCRIPT_DIR/merge_agent_outputs.py"
SKILL_SETS_DIR="$REPO_ROOT/tools/config"

mkdir -p "$LOGS_DIR"

# ---------------------------------------------------------------------------
# Temp state dir (bash-3-compatible replacement for associative arrays)
# One file per agent per field: $STATE_DIR/<agent>.pid  .start  .status
# ---------------------------------------------------------------------------
STATE_DIR="$(mktemp -d /tmp/orchestrate-${SLUG}-XXXXXX)"
cleanup() { rm -rf "$STATE_DIR"; }
trap cleanup EXIT

state_set() { printf '%s' "$3" > "$STATE_DIR/$1.$2"; }
state_get() { cat "$STATE_DIR/$1.$2" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
LOG_TAG="[orchestrate-agents]"
log_info()  { echo "$LOG_TAG INFO  $*"; }
log_warn()  { echo "$LOG_TAG WARN  $*" >&2; }
log_error() { echo "$LOG_TAG ERROR $*" >&2; }

# ---------------------------------------------------------------------------
# Failures log helpers
#
# append_failure <phase> <agent> <failure_type> <retry_count> <resolution> <impact>
#   [<provider>] [<quota_account>] [<preflight_exit_code>] [<stderr_excerpt>]
#
# Optional positional args 7-10 extend the structured failure record with
# traceability fields: provider, quota_account, preflight_exit_code, stderr_excerpt.
# Callers that don't need them can omit trailing args — Python fills "" defaults.
# ---------------------------------------------------------------------------
FAILURES_JSON_ARRAY="[]"

append_failure() {
  local phase="$1"       agent="$2"      failure_type="$3" retry_count="$4"
  local resolution="$5"  impact="$6"
  local provider="${7:-}"  quota_account="${8:-}"  preflight_exit_code="${9:-}"  stderr_excerpt="${10:-}"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local entry
  entry=$(python3 -c "
import json, sys
phase, agent, ftype, ts, retry, resolution, impact = sys.argv[1:8]
provider, qa, pec, stderr = sys.argv[8], sys.argv[9], sys.argv[10], sys.argv[11]
entry = {
  'phase':        phase,
  'agent':        agent,
  'failure_type': ftype,
  'timestamp':    ts,
  'retry_count':  int(retry),
  'resolution':   resolution,
  'impact':       impact,
}
# Only include optional traceability fields when non-empty
if provider:          entry['provider']             = provider
if qa:                entry['quota_account']        = qa
if pec:               entry['preflight_exit_code']  = pec
if stderr:            entry['stderr_excerpt']       = stderr[:500]  # cap to 500 chars
print(json.dumps(entry))
" "$phase" "$agent" "$failure_type" "$ts" "$retry_count" "$resolution" "$impact" \
  "$provider" "$quota_account" "$preflight_exit_code" "$stderr_excerpt")
  FAILURES_JSON_ARRAY=$(python3 -c "
import json, sys
arr = json.loads(sys.argv[1])
arr.append(json.loads(sys.argv[2]))
print(json.dumps(arr, indent=2))
" "$FAILURES_JSON_ARRAY" "$entry")
}

flush_failures() {
  python3 -c "
import json, sys
print(json.dumps({'failures': json.loads(sys.argv[1])}, indent=2))
" "$FAILURES_JSON_ARRAY" > "$FAILURES_LOG"
  log_info "Failures log written → $FAILURES_LOG"
}

# ---------------------------------------------------------------------------
# JSON validation helper
# ---------------------------------------------------------------------------
is_valid_json() {
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Agent output filename
# Agent IDs in dispatch config already contain the full name (e.g. "agent-a1").
# Output convention: reports/<slug>-<agent-id>.json
#   agent-id="agent-a1" → reports/<slug>-agent-a1.json  (no double prefix)
# ---------------------------------------------------------------------------
agent_output_file() {
  echo "$REPORTS_DIR/${SLUG}-${1}.json"
}

# ---------------------------------------------------------------------------
# provider_for_agent — reads agent-level provider from dispatch (with fallback)
# Dispatch format:
#   "provider_map": { "agent-a1": "codex", "agent-c": "claude" }
#   "default_provider": "codex"
# If neither is set, falls back to "codex" for backwards compatibility.
# ---------------------------------------------------------------------------
provider_for_agent() {
  local agent="$1"
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
pm = d.get('provider_map', {})
default = d.get('default_provider', 'codex')
print(pm.get(sys.argv[2], default))
" "$DISPATCH_FILE" "$agent"
}

# ---------------------------------------------------------------------------
# model_for_agent — reads agent-level model override from dispatch model_map
# Dispatch format:
#   "model_map": { "agent-c": "claude-sonnet-4.6", "agent-d": "claude-sonnet-4.6" }
# Returns empty string if not set (caller uses provider CLI default).
# Only meaningful for provider="claude".
# Source of truth: .claude/settings.local.json CLAUDE_MODEL = "claude-sonnet-4.6"
# ---------------------------------------------------------------------------
model_for_agent() {
  local agent="$1"
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
mm = d.get('model_map', {})
print(mm.get(sys.argv[2], ''))
" "$DISPATCH_FILE" "$agent"
}

# ---------------------------------------------------------------------------
# Step 1: Read dispatch config
# ---------------------------------------------------------------------------
log_info "=== Multi-agent orchestrator starting for slug: $SLUG ==="
log_info "Dispatch config: $DISPATCH_FILE"

if [[ ! -f "$DISPATCH_FILE" ]]; then
  log_error "Dispatch config not found: $DISPATCH_FILE"
  log_error "Run prepare_agent_inputs.py first to generate it."
  exit 1
fi

if ! is_valid_json "$DISPATCH_FILE"; then
  log_error "Dispatch config is not valid JSON: $DISPATCH_FILE"
  exit 1
fi

log_info "Dispatch config valid. Parsing..."

DISPATCH_SLUG=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['slug'])" "$DISPATCH_FILE")
DISPATCH_TIMEOUT=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('timeout_seconds', 900))" "$DISPATCH_FILE")
SOURCE_DIR=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('source_dir', ''))" "$DISPATCH_FILE")
QUOTA_ACCOUNT=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('quota_account','') or '')" "$DISPATCH_FILE")
# Runtime override: CODEX_QUOTA_ACCOUNT env var wins over dispatch value
QUOTA_ACCOUNT="${CODEX_QUOTA_ACCOUNT:-$QUOTA_ACCOUNT}"
TIMEOUT_SECONDS="${TIMEOUT_OVERRIDE:-$DISPATCH_TIMEOUT}"

log_info "slug from dispatch: $DISPATCH_SLUG"
log_info "timeout: ${TIMEOUT_SECONDS}s | parallel-limit: $PARALLEL_LIMIT | source_dir: $SOURCE_DIR"
log_info "quota_account: ${QUOTA_ACCOUNT:-(not set)} | resume_missing_only: $RESUME_MISSING_ONLY"

if [[ "$DISPATCH_SLUG" != "$SLUG" ]]; then
  log_warn "Slug mismatch: CLI arg '$SLUG' vs dispatch config '$DISPATCH_SLUG'. Using CLI arg."
fi

# Build agent list using a while-read loop (bash-3 compatible, no mapfile)
AGENTS_ALL=()
while IFS= read -r agent_id; do
  [[ -n "$agent_id" ]] && AGENTS_ALL+=("$agent_id")
done < <(python3 -c "import json,sys; [print(a) for a in json.load(open(sys.argv[1]))['agents']]" "$DISPATCH_FILE")

log_info "Agents in dispatch (${#AGENTS_ALL[@]}): ${AGENTS_ALL[*]}"

# ---------------------------------------------------------------------------
# Verify agent input files — collect runnable agents
# ---------------------------------------------------------------------------
log_info "Verifying agent input files..."
AGENTS_TO_RUN=()
for agent in "${AGENTS_ALL[@]}"; do
  INPUT_FILE=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get('inputs',{}).get(sys.argv[2],''))
" "$DISPATCH_FILE" "$agent")

  if [[ -z "$INPUT_FILE" ]]; then
    log_warn "No input file mapped for '$agent' in dispatch config. Skipping."
    append_failure "phase2" "$agent" "missing_input" "0" "skipped" \
      "No input file in dispatch config for agent '$agent'."
    continue
  fi

  # Resolve path relative to repo root if not absolute
  local_path="$INPUT_FILE"
  [[ "$INPUT_FILE" != /* ]] && local_path="$REPO_ROOT/$INPUT_FILE"

  if [[ ! -f "$local_path" ]]; then
    log_warn "Input file for '$agent' not found: $INPUT_FILE — IR slice empty. Skipping."
    append_failure "phase2" "$agent" "missing_input_file" "0" "skipped" \
      "IR slice not found for '$agent' — no EPs in group (not an error)."
    continue
  fi

  AGENTS_TO_RUN+=("$agent")
done

log_info "Agents with valid inputs (${#AGENTS_TO_RUN[@]}): ${AGENTS_TO_RUN[*]:-none}"

if [[ ${#AGENTS_TO_RUN[@]} -eq 0 ]]; then
  log_warn "No agents have valid inputs. Nothing to run."
  flush_failures
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 2: --resume-missing-only filter
# Skip agents whose output file already exists and is valid JSON.
# ---------------------------------------------------------------------------
AGENTS_PENDING=()
AGENTS_SKIPPED_RESUME=()

if [[ "$RESUME_MISSING_ONLY" -eq 1 ]]; then
  log_info "=== Resume mode: filtering agents with valid existing output ==="
  for agent in "${AGENTS_TO_RUN[@]}"; do
    out_file="$(agent_output_file "$agent")"
    if [[ -f "$out_file" ]] && is_valid_json "$out_file"; then
      log_info "  SKIP $agent — valid output already exists at $out_file"
      AGENTS_SKIPPED_RESUME+=("$agent")
    else
      log_info "  RUN  $agent — output missing or invalid"
      AGENTS_PENDING+=("$agent")
    fi
  done
  log_info "Resume: skipping ${#AGENTS_SKIPPED_RESUME[@]}, running ${#AGENTS_PENDING[@]}"
else
  AGENTS_PENDING=("${AGENTS_TO_RUN[@]}")
fi

if [[ ${#AGENTS_PENDING[@]} -eq 0 ]]; then
  log_info "All agents have valid output. Nothing to run (--resume-missing-only). Proceeding to merge."
  # Still run merge to ensure canonical file is up to date
  if python3 "$MERGE_SCRIPT" "$SLUG" --expected-agents "${AGENTS_TO_RUN[@]}"; then
    log_info "Merge complete."
  fi
  touch "$MERGE_READY_SENTINEL"
  flush_failures
  log_info "=== Orchestration complete (resume: all agents present) for '$SLUG' ==="
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 3a: Preflight quota probe (Codex only)
# Runs a trivial codex exec to catch quota exhaustion before committing the run.
# Skip by setting SKIP_QUOTA_PROBE=1.
# If agent routing means no Codex agents in AGENTS_PENDING, skip probe automatically.
# ---------------------------------------------------------------------------
NEEDS_CODEX=0
for agent in "${AGENTS_PENDING[@]}"; do
  provider="$(provider_for_agent "$agent")"
  if [[ "$provider" == "codex" ]]; then
    NEEDS_CODEX=1
    break
  fi
done

if [[ "${SKIP_QUOTA_PROBE:-0}" != "1" ]] && [[ "$NEEDS_CODEX" -eq 1 ]]; then
  log_info "Preflight: probing Codex quota before launching agents..."
  PROBE_OUT=$(mktemp /tmp/orchestrate-probe-XXXXXX.json)
  PROBE_ERR=$(mktemp /tmp/orchestrate-probe-err-XXXXXX.txt)
  PROBE_EXIT=0
  echo '{"probe":true,"task":"reply with: {\"ok\":true}"}' \
    | codex exec \
        --dangerously-bypass-approvals-and-sandbox \
        -C "$REPO_ROOT" \
        --output-last-message "$PROBE_OUT" \
        2>"$PROBE_ERR" || PROBE_EXIT=$?

  PROBE_ERR_TEXT="$(cat "$PROBE_ERR" 2>/dev/null || true)"

  if grep -qi "usage limit\|usage exhausted\|rate limit\|quota" "$PROBE_ERR" 2>/dev/null; then
    log_error "Preflight FAILED: Codex quota exhausted (exit=$PROBE_EXIT)."
    log_error "stderr: $PROBE_ERR_TEXT"
    log_error "Aborting — no agents launched. Use --resume-missing-only after quota reset."
    append_failure "phase2" "preflight" "quota_exhausted" "0" "aborted" \
      "Codex quota probe failed before any agent launched." \
      "codex" "$QUOTA_ACCOUNT" "$PROBE_EXIT" "$PROBE_ERR_TEXT"
    flush_failures
    rm -f "$PROBE_OUT" "$PROBE_ERR"
    exit 2
  fi

  log_info "Preflight quota probe: OK (exit=$PROBE_EXIT)"
  rm -f "$PROBE_OUT" "$PROBE_ERR"
elif [[ "${SKIP_QUOTA_PROBE:-0}" == "1" ]]; then
  log_info "Preflight quota probe: SKIPPED (SKIP_QUOTA_PROBE=1)"
else
  log_info "Preflight quota probe: SKIPPED (no Codex agents in pending list)"
fi

# ---------------------------------------------------------------------------
# Step 3b: Preflight Claude check
# If any pending agent uses provider=claude, verify:
#   1. claude CLI is on PATH
#   2. claude responds (auth OK, model accessible)
# Runs claude -p --dangerously-skip-permissions with a trivial prompt.
# If model_map has an entry for any claude agent, probe with that model.
# cwd is pinned to $REPO_ROOT to match launch_agent() behaviour.
# Skip by setting SKIP_QUOTA_PROBE=1 (same flag as Codex probe).
# ---------------------------------------------------------------------------
NEEDS_CLAUDE=0
CLAUDE_PROBE_MODEL=""
for _preflight_agent in "${AGENTS_PENDING[@]}"; do
  _prov="$(provider_for_agent "$_preflight_agent")"
  if [[ "$_prov" == "claude" ]]; then
    NEEDS_CLAUDE=1
    _m="$(model_for_agent "$_preflight_agent")"
    if [[ -n "$_m" && -z "$CLAUDE_PROBE_MODEL" ]]; then
      CLAUDE_PROBE_MODEL="$_m"
    fi
  fi
done

if [[ "${SKIP_QUOTA_PROBE:-0}" != "1" ]] && [[ "$NEEDS_CLAUDE" -eq 1 ]]; then
  log_info "Preflight: probing Claude CLI (model=${CLAUDE_PROBE_MODEL:-<default>})..."

  if ! command -v claude >/dev/null 2>&1; then
    log_error "Preflight FAILED: 'claude' CLI not found on PATH."
    append_failure "phase2" "preflight-claude" "claude_cli_missing" "0" "aborted" \
      "claude CLI not found on PATH. Install Claude Code CLI." \
      "claude" "$QUOTA_ACCOUNT" "127" ""
    flush_failures
    exit 2
  fi

  _CLAUDE_PROBE_ERR="$(mktemp /tmp/orchestrate-claude-probe-err-XXXXXX.txt)"
  _CLAUDE_PROBE_OUT="$(mktemp /tmp/orchestrate-claude-probe-XXXXXX.txt)"
  _CLAUDE_PROBE_EXIT=0
  _CLAUDE_PROBE_CMD=(claude -p --dangerously-skip-permissions --verbose --output-format stream-json)
  if [[ -n "$CLAUDE_PROBE_MODEL" ]]; then
    _CLAUDE_PROBE_CMD+=(--model "$CLAUDE_PROBE_MODEL")
  fi
  (
    cd "$REPO_ROOT"
    echo 'Reply with exactly: {"ok":true}' \
      | "${_CLAUDE_PROBE_CMD[@]}" >"$_CLAUDE_PROBE_OUT" 2>"$_CLAUDE_PROBE_ERR"
  ) || _CLAUDE_PROBE_EXIT=$?

  _CLAUDE_PROBE_ERR_TEXT="$(head -c 500 "$_CLAUDE_PROBE_ERR" 2>/dev/null || true)"

  if [[ "$_CLAUDE_PROBE_EXIT" -ne 0 ]]; then
    log_error "Preflight FAILED: Claude CLI probe exited $_CLAUDE_PROBE_EXIT (model=${CLAUDE_PROBE_MODEL:-<default>})."
    log_error "stderr: $_CLAUDE_PROBE_ERR_TEXT"
    log_error "Aborting — fix Claude auth/model and retry."
    append_failure "phase2" "preflight-claude" "claude_preflight_failed" "0" "aborted" \
      "Claude CLI probe failed (exit=$_CLAUDE_PROBE_EXIT, model=${CLAUDE_PROBE_MODEL:-<default>}). Check auth and model access." \
      "claude" "$QUOTA_ACCOUNT" "$_CLAUDE_PROBE_EXIT" "$_CLAUDE_PROBE_ERR_TEXT"
    flush_failures
    rm -f "$_CLAUDE_PROBE_OUT" "$_CLAUDE_PROBE_ERR"
    exit 2
  fi

  log_info "Preflight Claude probe: OK (exit=$_CLAUDE_PROBE_EXIT model=${CLAUDE_PROBE_MODEL:-<default>})"
  rm -f "$_CLAUDE_PROBE_OUT" "$_CLAUDE_PROBE_ERR"
elif [[ "${SKIP_QUOTA_PROBE:-0}" == "1" ]]; then
  log_info "Preflight Claude probe: SKIPPED (SKIP_QUOTA_PROBE=1)"
else
  log_info "Preflight Claude probe: SKIPPED (no Claude agents in pending list)"
fi

# ---------------------------------------------------------------------------
# skill_set_file_for_agent — maps agent-id prefix to SKILL SET markdown file
# ---------------------------------------------------------------------------
skill_set_file_for_agent() {
  local agent="$1"
  case "$agent" in
    agent-a*) echo "$SKILL_SETS_DIR/skill-set-agent-a.md" ;;
    agent-b*) echo "$SKILL_SETS_DIR/skill-set-agent-b.md" ;;
    agent-c*) echo "$SKILL_SETS_DIR/skill-set-agent-c.md" ;;
    agent-d*) echo "$SKILL_SETS_DIR/skill-set-agent-d.md" ;;
    *)        echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# launch_agent — starts a single agent via provider CLI in background
#
# Provider routing (explicit, not fallback):
#   - "codex"  → codex exec
#   - "claude" → claude --print (non-interactive, Claude Code CLI)
#   Provider is read from dispatch provider_map or default_provider.
# ---------------------------------------------------------------------------
launch_agent() {
  local agent="$1"
  local input_file out_file skill_set_file prompt_file agent_provider agent_model

  input_file=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get('inputs',{}).get(sys.argv[2],''))
" "$DISPATCH_FILE" "$agent")

  out_file="$(agent_output_file "$agent")"
  skill_set_file="$(skill_set_file_for_agent "$agent")"
  agent_provider="$(provider_for_agent "$agent")"
  agent_model="$(model_for_agent "$agent")"

  log_info "Launching agent: $agent  provider=$agent_provider  model=${agent_model:-<default>}  input=$input_file  output=$out_file"

  if [[ -z "$skill_set_file" || ! -f "$skill_set_file" ]]; then
    log_error "No SKILL SET file found for agent '$agent' (resolved: '$skill_set_file'). Skipping."
    append_failure "phase2" "$agent" "missing_skill_set" "0" "skipped" \
      "No SKILL SET file found for agent '$agent'." \
      "$agent_provider" "$QUOTA_ACCOUNT"
    return 1
  fi

  # Build prompt file: SKILL SET content + runtime context block
  prompt_file="$(mktemp /tmp/prompt-${SLUG}-${agent}-XXXXXX.md)"
  {
    cat "$skill_set_file"
    echo ""
    echo "---"
    echo "## Runtime Context (injected by orchestrator)"
    echo ""
    echo "- **Plugin slug:** ${SLUG}"
    echo "- **Input file:** ${input_file}"
    echo "- **Output file:** ${out_file}"
    echo "- **Agent ID:** ${agent}"
    echo "- **Provider:** ${agent_provider}"
    echo "- **Source directory:** $REPO_ROOT/plugins/${SLUG}/"
    echo ""
    echo "Write your JSON output to: \`${out_file}\`"
    echo "The output must conform to the agent-output schema."
  } > "$prompt_file"

  # Launch via the appropriate provider CLI
  if [[ "$agent_provider" == "claude" ]]; then
    # Claude Code CLI branch — hardened to match run-phase2.sh / phase3_llm_review.py contract:
    #   -p / --print          non-interactive, print output
    #   --dangerously-skip-permissions  bypass permission prompts
    #   --output-format stream-json     machine-parseable streaming output
    #   --model <model>       optional: pin model from dispatch model_map
    # cwd is pinned to $REPO_ROOT so relative paths in the prompt (e.g. reports/…)
    # resolve correctly regardless of how the caller launched the script.
    # stdout is streamed through Python to extract final text content,
    # matching the pattern established in run-phase2.sh:477-499.
    local claude_cmd
    claude_cmd=(claude -p --dangerously-skip-permissions --verbose --output-format stream-json)
    if [[ -n "$agent_model" ]]; then
      claude_cmd+=(--model "$agent_model")
    fi
    (
      cd "$REPO_ROOT"
      AGENT_INPUT_FILE="$input_file" \
      AGENT_OUTPUT_FILE="$out_file" \
      AGENT_ID="$agent" \
      AGENT_SLUG="$SLUG" \
      "${claude_cmd[@]}" \
        2>>"$LOGS_DIR/${SLUG}-${agent}.log" \
        < "$prompt_file" \
        | python3 -u - 2>>"$LOGS_DIR/${SLUG}-${agent}.log" \
            > "$LOGS_DIR/${SLUG}-${agent}-last-message.txt" \
<<'PYEOF'
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
        print("", flush=True)
PYEOF
    ) &
  else
    # Default: codex exec
    AGENT_INPUT_FILE="$input_file" \
    AGENT_OUTPUT_FILE="$out_file" \
    AGENT_ID="$agent" \
    AGENT_SLUG="$SLUG" \
    codex exec \
      --dangerously-bypass-approvals-and-sandbox \
      -C "$REPO_ROOT" \
      --output-last-message "$LOGS_DIR/${SLUG}-${agent}-last-message.txt" \
      2>>"$LOGS_DIR/${SLUG}-${agent}.log" \
      < "$prompt_file" \
      &
  fi

  local pid=$!
  state_set "$agent" "pid"      "$pid"
  state_set "$agent" "start"    "$(date +%s)"
  state_set "$agent" "status"   "running"
  state_set "$agent" "provider" "$agent_provider"
  state_set "$agent" "model"    "$agent_model"
  log_info "Agent '$agent' launched with PID $pid (provider=$agent_provider model=${agent_model:-<default>} prompt=$prompt_file)"
}

# ---------------------------------------------------------------------------
# Steps 4 & 5: Launch agents (serial default, parallel opt-in) + poll
# ---------------------------------------------------------------------------
log_info "=== Step 4: Launching agents (parallel-limit=${PARALLEL_LIMIT}) ==="

OUTPUT_FILES=()
FAILED_AGENTS=()

PENDING_AGENTS=("${AGENTS_PENDING[@]}")
RUNNING_AGENTS=()

while true; do
  # Fill running slots from pending
  while [[ ${#RUNNING_AGENTS[@]} -lt $PARALLEL_LIMIT ]] && [[ ${#PENDING_AGENTS[@]} -gt 0 ]]; do
    next_agent="${PENDING_AGENTS[0]}"
    PENDING_AGENTS=("${PENDING_AGENTS[@]:1}")
    launch_agent "$next_agent"
    RUNNING_AGENTS+=("$next_agent")
  done

  # Poll each running agent
  STILL_RUNNING=()
  for agent in "${RUNNING_AGENTS[@]}"; do
    pid="$(state_get "$agent" pid)"
    out_file="$(agent_output_file "$agent")"
    start="$(state_get "$agent" start)"
    agent_provider="$(state_get "$agent" provider)"
    elapsed=$(( $(date +%s) - start ))

    # --- Completed: output file exists and is valid JSON ---
    if [[ -f "$out_file" ]] && is_valid_json "$out_file"; then
      log_info "Agent '$agent' completed → $out_file (${elapsed}s, provider=$agent_provider)"
      state_set "$agent" "status" "done"
      OUTPUT_FILES+=("$out_file")
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      continue
    fi

    # --- Timeout ---
    if [[ $elapsed -ge $TIMEOUT_SECONDS ]]; then
      log_warn "Agent '$agent' timed out after ${elapsed}s. Retrying once..."
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true

      launch_agent "$agent"
      sleep "$POLL_INTERVAL"

      new_pid="$(state_get "$agent" pid)"
      new_out="$(agent_output_file "$agent")"
      elapsed2=$(( $(date +%s) - $(state_get "$agent" start) ))

      if [[ -f "$new_out" ]] && is_valid_json "$new_out"; then
        log_info "Agent '$agent' completed on retry → $new_out"
        state_set "$agent" "status" "done"
        OUTPUT_FILES+=("$new_out")
        kill "$new_pid" 2>/dev/null || true
        wait "$new_pid" 2>/dev/null || true
        continue
      else
        log_error "Agent '$agent' timed out after retry (${elapsed2}s). Skipping."
        state_set "$agent" "status" "failed"
        FAILED_AGENTS+=("$agent")
        append_failure "phase2" "$agent" "timeout" "1" "skipped" \
          "Agent '$agent' timed out after retry — EP group findings may be incomplete." \
          "$agent_provider" "$QUOTA_ACCOUNT"
        kill "$new_pid" 2>/dev/null || true
        wait "$new_pid" 2>/dev/null || true
        continue
      fi
    fi

    # --- Process exited early (no valid output yet) ---
    if ! kill -0 "$pid" 2>/dev/null; then
      exit_code=0
      wait "$pid" 2>/dev/null && exit_code=$? || exit_code=$?

      # Read last few lines of agent log as stderr_excerpt for failure record
      agent_log="$LOGS_DIR/${SLUG}-${agent}.log"
      stderr_excerpt=""
      [[ -f "$agent_log" ]] && stderr_excerpt="$(tail -5 "$agent_log" 2>/dev/null | tr '\n' ' ')"

      if [[ -f "$out_file" ]]; then
        repair_result=$(python3 -c "
import json, sys
try:
    json.load(open(sys.argv[1]))
    print('valid')
except Exception:
    print('invalid')
" "$out_file")
        if [[ "$repair_result" == "valid" ]]; then
          log_info "Agent '$agent' exited (code=$exit_code) — output valid. Treating as done."
          state_set "$agent" "status" "done"
          OUTPUT_FILES+=("$out_file")
          continue
        else
          log_error "Agent '$agent' exited (code=$exit_code) with malformed JSON. Rejecting."
          append_failure "phase2" "$agent" "invalid_json" "0" "rejected" \
            "Agent '$agent' produced malformed JSON — output rejected." \
            "$agent_provider" "$QUOTA_ACCOUNT" "$exit_code" "$stderr_excerpt"
        fi
      else
        log_error "Agent '$agent' exited (code=$exit_code) with no output file."
        # Check if quota exhaustion in log
        quota_signal=""
        if [[ -f "$agent_log" ]] && grep -qi "usage limit\|usage exhausted\|rate limit\|quota" "$agent_log" 2>/dev/null; then
          quota_signal="quota_exhausted_mid_run"
          log_error "  └─ Quota exhaustion detected in agent log. Use --resume-missing-only after quota reset."
        fi
        failure_type="${quota_signal:-missing_output}"
        append_failure "phase2" "$agent" "$failure_type" "0" "skipped" \
          "Agent '$agent' wrote no output — EP group findings absent." \
          "$agent_provider" "$QUOTA_ACCOUNT" "$exit_code" "$stderr_excerpt"
      fi
      state_set "$agent" "status" "failed"
      FAILED_AGENTS+=("$agent")
      continue
    fi

    # Still running
    log_info "Agent '$agent' still running (${elapsed}s elapsed, provider=$agent_provider)..."
    STILL_RUNNING+=("$agent")
  done

  # Rebuild running list without completed/failed agents
  RUNNING_AGENTS=()
  for a in "${STILL_RUNNING[@]+"${STILL_RUNNING[@]}"}"; do
    RUNNING_AGENTS+=("$a")
  done

  # All done?
  if [[ ${#PENDING_AGENTS[@]} -eq 0 ]] && [[ ${#RUNNING_AGENTS[@]} -eq 0 ]]; then
    log_info "All agents finished."
    break
  fi

  sleep "$POLL_INTERVAL"
done

# ---------------------------------------------------------------------------
# Step 5: Completion summary
# ---------------------------------------------------------------------------
log_info "=== Step 5: Completion summary ==="
log_info "Completed: ${#OUTPUT_FILES[@]} agent(s)"
log_info "Failed:    ${#FAILED_AGENTS[@]} agent(s)"
if [[ "$RESUME_MISSING_ONLY" -eq 1 ]] && [[ ${#AGENTS_SKIPPED_RESUME[@]} -gt 0 ]]; then
  log_info "Skipped (resume): ${#AGENTS_SKIPPED_RESUME[@]} agent(s) — ${AGENTS_SKIPPED_RESUME[*]}"
fi

# ---------------------------------------------------------------------------
# All-agents-fail: fallback to single-agent Phase 2 (per multi-agent-plan.md:490)
# ---------------------------------------------------------------------------
if [[ ${#OUTPUT_FILES[@]} -eq 0 ]]; then
  log_error "All agents failed. Falling back to single-agent Phase 2 pipeline."
  FAILURES_JSON_ARRAY=$(python3 -c "
import json, sys
arr = json.loads(sys.argv[1])
arr.append({
  'phase':                'phase2',
  'agent':                'ALL',
  'failure_type':         'all_agents_failed',
  'timestamp':            __import__('datetime').datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
  'retry_count':          0,
  'resolution':           'fallback_single_agent',
  'quota_account':        sys.argv[2],
  'multi_agent_fallback': True,
  'impact':               'All agents failed — invoking run-phase2.sh $SLUG (single-agent fallback).',
})
print(json.dumps(arr, indent=2))
" "$FAILURES_JSON_ARRAY" "$QUOTA_ACCOUNT")
  flush_failures

  PHASE2_SCRIPT="$SCRIPT_DIR/run-phase2.sh"
  if [[ ! -f "$PHASE2_SCRIPT" ]]; then
    log_error "Fallback script not found: $PHASE2_SCRIPT. Exiting."
    exit 2
  fi
  log_info "Invoking fallback: bash $PHASE2_SCRIPT $SLUG"
  set +e
  bash "$PHASE2_SCRIPT" "$SLUG"
  fallback_exit=$?
  set -e
  if [[ $fallback_exit -ne 0 ]]; then
    log_error "Single-agent fallback failed (exit=$fallback_exit)."
    exit 2
  fi
  log_info "Single-agent fallback completed. Pipeline continues from run-phase2.sh output."
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 6: Merge — pass full expected-agents list so agents_missing is populated
# ---------------------------------------------------------------------------
log_info "=== Step 6: Calling merge script ==="
if [[ ! -f "$MERGE_SCRIPT" ]]; then
  log_error "Merge script not found: $MERGE_SCRIPT"
  exit 1
fi

EXPECTED_AGENTS_ARGS=""
for agent in "${AGENTS_TO_RUN[@]}"; do
  EXPECTED_AGENTS_ARGS="$EXPECTED_AGENTS_ARGS $agent"
done

log_info "Running: python3 $MERGE_SCRIPT $SLUG --expected-agents${EXPECTED_AGENTS_ARGS}"
# shellcheck disable=SC2086
if ! python3 "$MERGE_SCRIPT" "$SLUG" --expected-agents $EXPECTED_AGENTS_ARGS; then
  log_error "merge_agent_outputs.py failed for slug '$SLUG'."
  append_failure "phase2" "merge" "merge_failed" "0" "aborted" \
    "merge_agent_outputs.py returned non-zero exit code."
  flush_failures
  exit 1
fi
log_info "Merge complete."

# ---------------------------------------------------------------------------
# Step 7: Write merge-ready sentinel
# ---------------------------------------------------------------------------
log_info "=== Step 7: Writing merge-ready sentinel ==="
touch "$MERGE_READY_SENTINEL"
log_info "Sentinel written → $MERGE_READY_SENTINEL"

# ---------------------------------------------------------------------------
# Flush failures log (audit trail — written even on success)
# ---------------------------------------------------------------------------
flush_failures

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log_info "=== Orchestration complete for '$SLUG' ==="
log_info "Successful agents: ${#OUTPUT_FILES[@]}/${#AGENTS_TO_RUN[@]}"
if [[ ${#FAILED_AGENTS[@]} -gt 0 ]]; then
  log_warn "Failed agents: ${FAILED_AGENTS[*]}"
  log_warn "To resume: bash tools/bin/orchestrate-agents.sh $SLUG --resume-missing-only"
  log_warn "See $FAILURES_LOG for details."
fi
log_info "Next step: run-phase3.sh --slug $SLUG"
