#!/usr/bin/env bash
# orchestrate-agents.sh — Multi-agent Phase 2 orchestrator
#
# Usage:
#   bash tools/bin/orchestrate-agents.sh <slug> [options]
#
# Options:
#   --parallel-limit N    Max agents to run concurrently (default: 2)
#   --timeout N           Override timeout_seconds from dispatch config (seconds)
#   --dispatch-file PATH  Override dispatch config path (default: reports/<slug>-dispatch.json)
#   --help                Show this help message
#
# Pipeline:
#   1. Read reports/<slug>-dispatch.json
#   2. Launch Codex CLI agents (up to --parallel-limit concurrently)
#   3. Poll each agent for output file existence + valid JSON
#   4. Call python3 tools/bin/merge_agent_outputs.py <slug>
#   5. Write reports/<slug>-merge-ready sentinel
#
# Failures are logged to reports/logs/<slug>-failures.json
# Source: multi-agent-plan.md:400-520
#
# Compatibility: POSIX sh + bash 3.2+ (no declare -A, no mapfile)

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PARALLEL_LIMIT=2
POLL_INTERVAL=15       # seconds between completion polls
TIMEOUT_OVERRIDE=""    # empty = read from dispatch config
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
  <slug>                Plugin slug (e.g. woocommerce)

Options:
  --parallel-limit N    Max agents running concurrently (default: 2)
  --timeout N           Timeout in seconds per agent (overrides dispatch config)
  --dispatch-file PATH  Path to dispatch config JSON (default: reports/<slug>-dispatch.json)
  --help                Show this message

Examples:
  bash tools/bin/orchestrate-agents.sh woocommerce
  bash tools/bin/orchestrate-agents.sh woocommerce --parallel-limit 3
  bash tools/bin/orchestrate-agents.sh woocommerce --timeout 600
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
# ---------------------------------------------------------------------------
FAILURES_JSON_ARRAY="[]"

append_failure() {
  local phase="$1" agent="$2" failure_type="$3" retry_count="$4" resolution="$5" impact="$6"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local entry
  entry=$(python3 -c "
import json, sys
entry = {
  'phase':        sys.argv[1],
  'agent':        sys.argv[2],
  'failure_type': sys.argv[3],
  'timestamp':    sys.argv[4],
  'retry_count':  int(sys.argv[5]),
  'resolution':   sys.argv[6],
  'impact':       sys.argv[7],
}
print(json.dumps(entry))
" "$phase" "$agent" "$failure_type" "$ts" "$retry_count" "$resolution" "$impact")
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
# Step 1: Read dispatch config
# ---------------------------------------------------------------------------
log_info "=== Session 18 (post-review): Multi-agent orchestrator starting for slug: $SLUG ==="
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
log_info "timeout: ${TIMEOUT_SECONDS}s | parallel-limit: $PARALLEL_LIMIT | source_dir: $SOURCE_DIR | quota_account: ${QUOTA_ACCOUNT:-(not set)}"

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
    append_failure "phase2" "$agent" "missing_input" "0" "skipped" "No input file in dispatch config for agent '$agent'."
    continue
  fi

  # Resolve path relative to repo root if not absolute
  local_path="$INPUT_FILE"
  [[ "$INPUT_FILE" != /* ]] && local_path="$REPO_ROOT/$INPUT_FILE"

  if [[ ! -f "$local_path" ]]; then
    log_warn "Input file for '$agent' not found: $INPUT_FILE — IR slice empty. Skipping."
    append_failure "phase2" "$agent" "missing_input_file" "0" "skipped" "IR slice not found for '$agent' — no EPs in group (not an error)."
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
# Preflight: quota probe — single trivial codex exec before committing full run
# Catches quota exhaustion early so all 8 agent slots are not wasted.
# Skip by setting SKIP_QUOTA_PROBE=1 in environment.
# ---------------------------------------------------------------------------
if [[ "${SKIP_QUOTA_PROBE:-0}" != "1" ]]; then
  log_info "Preflight: probing Codex quota before launching agents..."
  PROBE_OUT=$(mktemp /tmp/orchestrate-probe-XXXXXX.json)
  PROBE_ERR=$(mktemp /tmp/orchestrate-probe-err-XXXXXX.txt)
  # Send minimal prompt — just ask for valid JSON output
  echo '{"probe": true, "task": "reply only with: {\"ok\":true}"}' \
    | codex exec \
        --dangerously-bypass-approvals-and-sandbox \
        -C "$REPO_ROOT" \
        --output-last-message "$PROBE_OUT" \
        2>"$PROBE_ERR" || true

  # Check for quota-exhausted signal in stderr
  if grep -qi "usage limit\|usage exhausted\|rate limit\|quota" "$PROBE_ERR" 2>/dev/null; then
    PROBE_ERR_TEXT=$(cat "$PROBE_ERR")
    log_error "Preflight FAILED: Codex quota exhausted."
    log_error "Error output: $PROBE_ERR_TEXT"
    log_error "Aborting — no agents launched. Retry after quota reset."
    append_failure "phase2" "preflight" "quota_exhausted" "0" "aborted" \
      "Codex quota probe failed before any agent launched: $PROBE_ERR_TEXT"
    flush_failures
    rm -f "$PROBE_OUT" "$PROBE_ERR"
    exit 2
  fi

  log_info "Preflight quota probe: OK"
  rm -f "$PROBE_OUT" "$PROBE_ERR"
fi

# ---------------------------------------------------------------------------
# skill_set_file_for_agent — maps agent-id prefix to SKILL SET markdown file
# ---------------------------------------------------------------------------
skill_set_file_for_agent() {
  local agent="$1"
  case "$agent" in
    agent-a*) echo "$SKILL_SETS_DIR/skill-set-agent-a.md" ;;
    agent-b*)  echo "$SKILL_SETS_DIR/skill-set-agent-b.md" ;;
    agent-c*)  echo "$SKILL_SETS_DIR/skill-set-agent-c.md" ;;
    agent-d*)  echo "$SKILL_SETS_DIR/skill-set-agent-d.md" ;;
    *)         echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# launch_agent — starts a single agent via Codex CLI (codex exec) in background
# ---------------------------------------------------------------------------
launch_agent() {
  local agent="$1"
  local input_file out_file skill_set_file prompt_file

  input_file=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get('inputs',{}).get(sys.argv[2],''))
" "$DISPATCH_FILE" "$agent")

  out_file="$(agent_output_file "$agent")"
  skill_set_file="$(skill_set_file_for_agent "$agent")"

  log_info "Launching agent: $agent  input=$input_file  output=$out_file  skill_set=$skill_set_file"

  if [[ -z "$skill_set_file" || ! -f "$skill_set_file" ]]; then
    log_error "No SKILL SET file found for agent '$agent' (resolved: '$skill_set_file'). Skipping."
    append_failure "phase2" "$agent" "missing_skill_set" "0" "skipped" \
      "No SKILL SET file found for agent '$agent'."
    return 1
  fi

  # Build prompt file: SKILL SET content + runtime context block appended
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
    echo "- **Source directory:** $REPO_ROOT/plugins/${SLUG}/"
    echo ""
    echo "Write your JSON output to: \`${out_file}\`"
    echo "The output must conform to the agent-output schema."
  } > "$prompt_file"

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

  local pid=$!
  state_set "$agent" "pid"    "$pid"
  state_set "$agent" "start"  "$(date +%s)"
  state_set "$agent" "status" "running"
  # Note: prompt_file is NOT removed here; codex exec reads it via stdin.
  # It lives in /tmp and will be cleaned up by the OS. The STATE_DIR cleanup
  # (trap cleanup EXIT) does not touch /tmp prompt files — acceptable.
  log_info "Agent '$agent' launched with PID $pid (prompt: $prompt_file)"
}

# ---------------------------------------------------------------------------
# Steps 2 & 3: Launch in parallel batches + poll
# ---------------------------------------------------------------------------
log_info "=== Step 2: Launching agents (parallel-limit=${PARALLEL_LIMIT}) ==="

OUTPUT_FILES=()
FAILED_AGENTS=()

# Pending queue (bash-3 indexed array)
PENDING_AGENTS=("${AGENTS_TO_RUN[@]}")
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
    elapsed=$(( $(date +%s) - start ))

    # --- Completed: output file exists and is valid JSON ---
    if [[ -f "$out_file" ]] && is_valid_json "$out_file"; then
      log_info "Agent '$agent' completed → $out_file (${elapsed}s)"
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
          "Agent '$agent' timed out after retry — EP group findings may be incomplete."
        kill "$new_pid" 2>/dev/null || true
        wait "$new_pid" 2>/dev/null || true
        continue
      fi
    fi

    # --- Process exited early (no valid output yet) ---
    if ! kill -0 "$pid" 2>/dev/null; then
      exit_code=0
      wait "$pid" 2>/dev/null && exit_code=$? || exit_code=$?

      if [[ -f "$out_file" ]]; then
        # File exists but may be malformed
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
            "Agent '$agent' produced malformed JSON — output rejected."
        fi
      else
        log_error "Agent '$agent' exited (code=$exit_code) with no output file."
        append_failure "phase2" "$agent" "missing_output" "0" "skipped" \
          "Agent '$agent' wrote no output — EP group findings absent."
      fi
      state_set "$agent" "status" "failed"
      FAILED_AGENTS+=("$agent")
      continue
    fi

    # Still running
    log_info "Agent '$agent' still running (${elapsed}s elapsed)..."
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
# Step 3: Completion summary
# ---------------------------------------------------------------------------
log_info "=== Step 3: Completion summary ==="
log_info "Completed: ${#OUTPUT_FILES[@]} agent(s)"
log_info "Failed:    ${#FAILED_AGENTS[@]} agent(s)"

# ---------------------------------------------------------------------------
# All-agents-fail: fallback to single-agent Phase 2 (per multi-agent-plan.md:490)
# ---------------------------------------------------------------------------
if [[ ${#OUTPUT_FILES[@]} -eq 0 ]]; then
  log_error "All agents failed. Falling back to single-agent Phase 2 pipeline."
  # Write structured multi_agent_fallback field in failure log so downstream
  # manifest tooling can detect it without text-parsing the impact string.
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
  'multi_agent_fallback': True,
  'impact':               'All agents failed — invoking run-phase2.sh $SLUG (single-agent fallback).',
})
print(json.dumps(arr, indent=2))
" "$FAILURES_JSON_ARRAY")
  flush_failures

  PHASE2_SCRIPT="$SCRIPT_DIR/run-phase2.sh"
  if [[ ! -f "$PHASE2_SCRIPT" ]]; then
    log_error "Fallback script not found: $PHASE2_SCRIPT. Exiting."
    exit 2
  fi
  log_info "Invoking fallback: bash $PHASE2_SCRIPT $SLUG"
  # Disable set -e around the fallback call so we control the exit code ourselves.
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
# Step 4: Merge — pass full expected-agents list so agents_missing is populated
# ---------------------------------------------------------------------------
log_info "=== Step 4: Calling merge script ==="
if [[ ! -f "$MERGE_SCRIPT" ]]; then
  log_error "Merge script not found: $MERGE_SCRIPT"
  exit 1
fi

# Build --expected-agents args from the full runnable agent list (includes failed ones).
# merge_agent_outputs.py uses this to diff against agents_seen and populate agents_missing.
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
# Step 5: Write merge-ready sentinel
# ---------------------------------------------------------------------------
log_info "=== Step 5: Writing merge-ready sentinel ==="
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
  log_warn "See $FAILURES_LOG for details."
fi
log_info "Next step: Claude Code reads reports/${SLUG}-phase2.json (or run-phase3.sh for gate)."
