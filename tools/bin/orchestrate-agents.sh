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

mkdir -p "$LOGS_DIR"

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
  local file="$1"
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Step 1: Read dispatch config
# ---------------------------------------------------------------------------
log_info "=== Session 18: Multi-agent orchestrator starting for slug: $SLUG ==="
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

log_info "Dispatch config is valid JSON. Parsing..."

# Extract fields from dispatch config
DISPATCH_SLUG=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['slug'])" "$DISPATCH_FILE")
AGENT_LIST=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print('\n'.join(d['agents']))" "$DISPATCH_FILE")
DISPATCH_TIMEOUT=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('timeout_seconds', 900))" "$DISPATCH_FILE")
SOURCE_DIR=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('source_dir', ''))" "$DISPATCH_FILE")

TIMEOUT_SECONDS="${TIMEOUT_OVERRIDE:-$DISPATCH_TIMEOUT}"

log_info "slug from dispatch: $DISPATCH_SLUG"
log_info "timeout: ${TIMEOUT_SECONDS}s"
log_info "source_dir: $SOURCE_DIR"
log_info "parallel-limit: $PARALLEL_LIMIT"

# Validate slug consistency
if [[ "$DISPATCH_SLUG" != "$SLUG" ]]; then
  log_warn "Slug mismatch: CLI arg '$SLUG' vs dispatch config '$DISPATCH_SLUG'. Using CLI arg."
fi

# Build agent list array
mapfile -t AGENTS <<< "$AGENT_LIST"
log_info "Agents to run (${#AGENTS[@]}): ${AGENTS[*]}"

# Check agent inputs exist
log_info "Verifying agent input files..."
AGENTS_TO_RUN=()
for agent in "${AGENTS[@]}"; do
  [[ -z "$agent" ]] && continue
  INPUT_FILE=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
inputs=d.get('inputs',{})
print(inputs.get(sys.argv[2],''))
" "$DISPATCH_FILE" "$agent")

  if [[ -z "$INPUT_FILE" ]]; then
    log_warn "No input file mapped for agent '$agent' in dispatch config. Skipping."
    append_failure "phase2" "$agent" "missing_input" "0" "skipped" "Agent '$agent' has no input file in dispatch config."
    continue
  fi

  if [[ ! -f "$REPO_ROOT/$INPUT_FILE" ]] && [[ ! -f "$INPUT_FILE" ]]; then
    log_warn "Input file for agent '$agent' not found: $INPUT_FILE — IR slice may be empty. Skipping."
    append_failure "phase2" "$agent" "missing_input_file" "0" "skipped" "IR slice empty or not found for $agent — no EPs in group (not an error)."
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
# Step 2 & 3: Launch agents in parallel batches, poll for completion
# ---------------------------------------------------------------------------
# Track per-agent state
declare -A AGENT_PID       # agent → background PID (or "done"/"skipped")
declare -A AGENT_STATUS    # agent → "pending"|"running"|"done"|"failed"|"skipped"
declare -A AGENT_START     # agent → epoch start time

OUTPUT_FILES=()
FAILED_AGENTS=()

# Function: get expected output file for an agent
agent_output_file() {
  local agent="$1"
  echo "$REPORTS_DIR/${SLUG}-agent-${agent}.json"
}

# Function: launch a single agent via codex CLI
launch_agent() {
  local agent="$1"
  local input_file
  input_file=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
inputs=d.get('inputs',{})
print(inputs.get(sys.argv[2],''))
" "$DISPATCH_FILE" "$agent")

  local out_file
  out_file="$(agent_output_file "$agent")"

  log_info "Launching agent: $agent (input: $input_file → output: $out_file)"

  # Launch codex CLI in background. The agent is expected to write $out_file.
  # We pass the input file and output path as env vars / args per codex convention.
  AGENT_INPUT_FILE="$input_file" \
  AGENT_OUTPUT_FILE="$out_file" \
  AGENT_ID="$agent" \
  AGENT_SLUG="$SLUG" \
  codex run "$agent" "$SLUG" \
    --input "$input_file" \
    --output "$out_file" \
    2>>"$LOGS_DIR/${SLUG}-agent-${agent}.log" \
    &
  AGENT_PID["$agent"]=$!
  AGENT_START["$agent"]=$(date +%s)
  AGENT_STATUS["$agent"]="running"
  log_info "Agent '$agent' launched with PID ${AGENT_PID[$agent]}"
}

# Initialize all agents as pending
for agent in "${AGENTS_TO_RUN[@]}"; do
  AGENT_STATUS["$agent"]="pending"
done

PENDING_AGENTS=("${AGENTS_TO_RUN[@]}")
RUNNING_AGENTS=()

log_info "=== Step 2: Launching agents (parallel-limit=${PARALLEL_LIMIT}) ==="

# Main orchestration loop
while true; do
  # Fill running slots from pending
  while [[ ${#RUNNING_AGENTS[@]} -lt $PARALLEL_LIMIT ]] && [[ ${#PENDING_AGENTS[@]} -gt 0 ]]; do
    next_agent="${PENDING_AGENTS[0]}"
    PENDING_AGENTS=("${PENDING_AGENTS[@]:1}")
    launch_agent "$next_agent"
    RUNNING_AGENTS+=("$next_agent")
  done

  # Poll running agents
  STILL_RUNNING=()
  for agent in "${RUNNING_AGENTS[@]}"; do
    local_pid="${AGENT_PID[$agent]}"
    out_file="$(agent_output_file "$agent")"
    elapsed=$(( $(date +%s) - AGENT_START["$agent"] ))

    # Check if output file exists and is valid JSON (completion signal)
    if [[ -f "$out_file" ]] && is_valid_json "$out_file"; then
      log_info "Agent '$agent' completed → $out_file (${elapsed}s)"
      AGENT_STATUS["$agent"]="done"
      OUTPUT_FILES+=("$out_file")
      # Kill process if still alive (already wrote output)
      kill "$local_pid" 2>/dev/null || true
      wait "$local_pid" 2>/dev/null || true
      continue
    fi

    # Check timeout
    if [[ $elapsed -ge $TIMEOUT_SECONDS ]]; then
      log_warn "Agent '$agent' timed out after ${elapsed}s. Retrying once..."
      kill "$local_pid" 2>/dev/null || true
      wait "$local_pid" 2>/dev/null || true

      # Retry once
      launch_agent "$agent"
      local_retry_pid="${AGENT_PID[$agent]}"
      sleep "$POLL_INTERVAL"
      elapsed2=$(( $(date +%s) - AGENT_START["$agent"] ))

      if [[ -f "$out_file" ]] && is_valid_json "$out_file"; then
        log_info "Agent '$agent' completed on retry → $out_file"
        AGENT_STATUS["$agent"]="done"
        OUTPUT_FILES+=("$out_file")
        kill "$local_retry_pid" 2>/dev/null || true
        wait "$local_retry_pid" 2>/dev/null || true
        continue
      else
        log_error "Agent '$agent' timed out after retry (${elapsed2}s). Skipping."
        AGENT_STATUS["$agent"]="failed"
        FAILED_AGENTS+=("$agent")
        append_failure "phase2" "$agent" "timeout" "1" "skipped" "Agent '$agent' timed out after retry — AJAX/EP findings for this group may be incomplete."
        kill "$local_retry_pid" 2>/dev/null || true
        wait "$local_retry_pid" 2>/dev/null || true
        continue
      fi
    fi

    # Check if process died without writing valid output
    if ! kill -0 "$local_pid" 2>/dev/null; then
      exit_code=0
      wait "$local_pid" 2>/dev/null && exit_code=$? || exit_code=$?

      # Check if it wrote something (invalid JSON or nothing)
      if [[ -f "$out_file" ]]; then
        # Attempt JSON repair via python (load with error recovery)
        repaired=$(python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print('valid')
except json.JSONDecodeError as e:
    # Attempt partial repair: read raw, try truncating to last valid object
    raw = open(sys.argv[1]).read().strip()
    # Last resort: reject
    print('invalid')
" "$out_file")
        if [[ "$repaired" == "valid" ]]; then
          log_info "Agent '$agent' process exited (code=$exit_code) but output is valid — treating as done."
          AGENT_STATUS["$agent"]="done"
          OUTPUT_FILES+=("$out_file")
          continue
        else
          log_error "Agent '$agent' exited (code=$exit_code) with malformed JSON output. Rejecting."
          append_failure "phase2" "$agent" "invalid_json" "0" "rejected" "Agent '$agent' wrote malformed JSON — output rejected, remaining agents merged."
        fi
      else
        log_error "Agent '$agent' exited (code=$exit_code) with no output file written."
        append_failure "phase2" "$agent" "missing_output" "0" "skipped" "Agent '$agent' wrote no output file — findings for this EP group absent."
      fi
      AGENT_STATUS["$agent"]="failed"
      FAILED_AGENTS+=("$agent")
      continue
    fi

    # Still running normally
    log_info "Agent '$agent' still running (${elapsed}s elapsed)..."
    STILL_RUNNING+=("$agent")
  done
  RUNNING_AGENTS=("${STILL_RUNNING[@]+"${STILL_RUNNING[@]}"}")

  # All agents done?
  if [[ ${#PENDING_AGENTS[@]} -eq 0 ]] && [[ ${#RUNNING_AGENTS[@]} -eq 0 ]]; then
    log_info "All agents finished."
    break
  fi

  sleep "$POLL_INTERVAL"
done

# ---------------------------------------------------------------------------
# Step 4: Check all-agents-failed fallback
# ---------------------------------------------------------------------------
log_info "=== Step 3: Completion summary ==="
log_info "Completed: ${#OUTPUT_FILES[@]} agent(s)"
log_info "Failed:    ${#FAILED_AGENTS[@]} agent(s)"

if [[ ${#OUTPUT_FILES[@]} -eq 0 ]]; then
  log_error "All agents failed. Triggering single-agent fallback (manual review required)."
  append_failure "phase2" "ALL" "all_agents_failed" "0" "fallback" "All agents failed — pipeline falls back to single-agent Phase 2. Set multi_agent_fallback=true in manifest."
  flush_failures
  log_error "No merge possible. Exiting with failure."
  exit 2
fi

# ---------------------------------------------------------------------------
# Step 5: Merge
# ---------------------------------------------------------------------------
log_info "=== Step 4: Calling merge script ==="
if [[ ! -f "$MERGE_SCRIPT" ]]; then
  log_error "Merge script not found: $MERGE_SCRIPT"
  exit 1
fi

log_info "Running: python3 $MERGE_SCRIPT $SLUG"
if ! python3 "$MERGE_SCRIPT" "$SLUG"; then
  log_error "merge_agent_outputs.py failed for slug '$SLUG'."
  append_failure "phase2" "merge" "merge_failed" "0" "aborted" "merge_agent_outputs.py returned non-zero exit code."
  flush_failures
  exit 1
fi
log_info "Merge complete."

# ---------------------------------------------------------------------------
# Step 6: Write merge-ready sentinel
# ---------------------------------------------------------------------------
log_info "=== Step 5: Writing merge-ready sentinel ==="
touch "$MERGE_READY_SENTINEL"
log_info "Sentinel written → $MERGE_READY_SENTINEL"

# ---------------------------------------------------------------------------
# Flush failures log (even on success, for audit trail)
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
