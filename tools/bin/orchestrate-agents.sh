#!/usr/bin/env bash
# orchestrate-agents.sh — Multi-agent Phase 2 orchestrator
#
# Usage:
#   bash tools/bin/orchestrate-agents.sh <slug> [options]
#
# Options:
#   --parallel-limit N      Max agents running concurrently (default: 4)
#   --timeout N             Override timeout_seconds from dispatch config (seconds)
#   --dispatch-file PATH    Override dispatch config path (default: reports/<slug>-dispatch.json)
#   --resume-missing-only   Skip agents whose output file already exists and is valid JSON
#   --stop-after-merge      Exit successfully after deterministic local merge (skip cluster/consensus)
#   --no-single-agent-fallback  Do not recurse into run-phase2.sh if all agents fail
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
# Failures are logged to reports/logs/<slug>/phase2/chunked/failures.json
# Source: multi-agent-plan.md:400-520
#
# Compatibility: POSIX sh + bash 3.2+ (no declare -A, no mapfile)

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PARALLEL_LIMIT=4        # worker bundles are bounded; 4-way concurrency is the default
RESUME_MISSING_ONLY=0   # 0 = run all; 1 = skip agents with valid existing output
POLL_INTERVAL=15        # seconds between completion polls
TIMEOUT_OVERRIDE=""     # empty = read from dispatch config
DISPATCH_FILE_OVERRIDE=""
STOP_AFTER_MERGE=0
NO_SINGLE_AGENT_FALLBACK=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/report-paths.sh"
resolve_report_dirs "$REPO_ROOT/reports"
ensure_report_dirs

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: orchestrate-agents.sh <slug> [options]

Arguments:
  <slug>                  Plugin slug (e.g. woocommerce)

Options:
  --parallel-limit N      Max agents running concurrently (default: 4)
  --timeout N             Timeout in seconds per agent (overrides dispatch config)
  --dispatch-file PATH    Path to dispatch config JSON (default: reports/<slug>-dispatch.json)
  --resume-missing-only   Skip agents whose output file already exists and is valid JSON.
                          Use after a quota-interrupted run to only rerun failed/missing agents.
  --stop-after-merge      Stop after merge_agent_outputs.py writes phase2.local.
                          Skip cluster synth/challenge, consensus writer, and merge-ready sentinel.
  --no-single-agent-fallback
                          If every bundle fails, return non-zero instead of calling run-phase2.sh.
  --help                  Show this message

Environment variables:
  SKIP_QUOTA_PROBE=1      Bypass preflight quota check
  CODEX_QUOTA_ACCOUNT     Codex account ID for traceability (logged in failures.json)

Examples:
  # Default parallel run
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
    --stop-after-merge)
      STOP_AFTER_MERGE=1
      shift
      ;;
    --no-single-agent-fallback)
      NO_SINGLE_AGENT_FALLBACK=1
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
DISPATCH_FILE="${DISPATCH_FILE_OVERRIDE:-$REPORTS_DIR/${SLUG}-dispatch.json}"
FAILURES_LOG="$(logs_phase2_chunked_failures_path "$SLUG")"
MERGE_READY_SENTINEL="$REPORTS_DIR/${SLUG}-merge-ready"
MERGE_SCRIPT="$SCRIPT_DIR/merge_agent_outputs.py"
CLUSTER_SCRIPT="$SCRIPT_DIR/build_candidate_clusters.py"
CLUSTER_PACK_SCRIPT="$SCRIPT_DIR/build_cluster_evidence_pack.py"
CONSENSUS_SCRIPT="$SCRIPT_DIR/write_phase2_consensus.py"
CLAUDE_STREAM_PARSER="$SCRIPT_DIR/claude_stream_to_text.py"
SKILL_SETS_DIR="$REPO_ROOT/tools/config"
REVIEW_SCHEMA="$REPO_ROOT/contracts/phase2-review-output.schema.json"
AGENT_OUTPUT_SCHEMA="$REPO_ROOT/contracts/agent-output.schema.json"
CLUSTER_OUTPUT_SCHEMA="$REPO_ROOT/contracts/phase2-cluster-output.schema.json"
AGENT_REVIEW_PROMPT_TEMPLATE="$REPO_ROOT/tools/config/phase2-agent-review-prompt-template.md"
AGENT_REVISION_PROMPT_TEMPLATE="$REPO_ROOT/tools/config/phase2-agent-revision-prompt-template.md"
CLUSTER_SYNTH_PROMPT_TEMPLATE="$REPO_ROOT/tools/config/phase2-cluster-synthesis-prompt-template.md"
CLUSTER_CHALLENGE_PROMPT_TEMPLATE="$REPO_ROOT/tools/config/phase2-cluster-challenge-prompt-template.md"

mkdir -p "$PHASE2_DIR" \
  "$(logs_phase2_chunked_dir "$SLUG")" \
  "$(logs_phase2_chunked_agents_dir "$SLUG")" \
  "$(logs_phase2_cluster_dir "$SLUG")"

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

threat_context_for_run() {
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('threat_context_path', f'reports/{sys.argv[2]}-threat-context.json'))
" "$DISPATCH_FILE" "$SLUG"
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

bundle_review_enabled() {
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(str(bool(d.get('bundle_review_enabled', False))).lower())
" "$DISPATCH_FILE"
}

reviewer_provider_for_run() {
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('reviewer_provider', 'codex'))
" "$DISPATCH_FILE"
}

reviewer_model_for_run() {
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('reviewer_model', ''))
" "$DISPATCH_FILE"
}

review_rounds_for_run() {
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(int(d.get('review_rounds', 1)))
" "$DISPATCH_FILE"
}

input_for_agent() {
  local agent="$1"
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get('inputs',{}).get(sys.argv[2],''))
" "$DISPATCH_FILE" "$agent"
}

quota_signal_in_log() {
  local path="$1"
  [[ -f "$path" ]] && grep -qi "usage limit\|usage exhausted\|rate limit\|quota" "$path" 2>/dev/null
}

is_valid_agent_output() {
  python3 - "$1" "$AGENT_OUTPUT_SCHEMA" <<'PY' 2>/dev/null
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
schema_path = Path(sys.argv[2])
if not path.exists():
    raise SystemExit(1)
data = json.loads(path.read_text(encoding="utf-8"))
required = {"agent_id", "plugin_slug", "findings"}
if not required.issubset(data):
    raise SystemExit(1)
if schema_path.exists():
    try:
        import jsonschema
    except Exception:
        raise SystemExit(0)
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    jsonschema.validate(instance=data, schema=schema)
PY
}

is_valid_review_output() {
  python3 - "$1" "$REVIEW_SCHEMA" <<'PY' 2>/dev/null
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
schema_path = Path(sys.argv[2])
if not path.exists():
    raise SystemExit(1)
data = json.loads(path.read_text(encoding="utf-8"))
required = {"plugin_slug", "review_round", "review_status", "summary", "finding_reviews", "missed_findings"}
if not required.issubset(data):
    raise SystemExit(1)
if schema_path.exists():
    try:
        import jsonschema
    except Exception:
        raise SystemExit(0)
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    jsonschema.validate(instance=data, schema=schema)
PY
}

is_valid_cluster_output() {
  python3 - "$1" "$CLUSTER_OUTPUT_SCHEMA" <<'PY' 2>/dev/null
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
schema_path = Path(sys.argv[2])
if not path.exists():
    raise SystemExit(1)
data = json.loads(path.read_text(encoding="utf-8"))
required = {"plugin_slug", "cluster_id", "stage", "status", "summary", "suggested_actions", "proposed_links", "objections"}
if not required.issubset(data):
    raise SystemExit(1)
if schema_path.exists():
    try:
        import jsonschema
    except Exception:
        raise SystemExit(0)
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    jsonschema.validate(instance=data, schema=schema)
PY
}

normalize_cluster_output_file() {
  local output_path="$1" stage="$2" cluster_path="$3"
  python3 - "$output_path" "$stage" "$cluster_path" <<'PY' >/dev/null 2>&1 || true
import json
import sys
from pathlib import Path

output_path = Path(sys.argv[1])
stage = sys.argv[2]
cluster_path = Path(sys.argv[3])
if not output_path.exists() or not cluster_path.exists():
    raise SystemExit(0)

data = json.loads(output_path.read_text(encoding="utf-8"))
cluster = json.loads(cluster_path.read_text(encoding="utf-8"))

summary = data.get("summary")
if isinstance(summary, str):
    data["summary"] = {
        "member_findings_reviewed": len(cluster.get("member_findings", [])),
        "material_links_found": len(data.get("proposed_links", [])) if isinstance(data.get("proposed_links"), list) else 0,
        "objections_count": len(data.get("objections", [])) if isinstance(data.get("objections"), list) else 0,
        "notes": summary,
    }
elif not isinstance(summary, dict):
    data["summary"] = {
        "member_findings_reviewed": len(cluster.get("member_findings", [])),
        "material_links_found": 0,
        "objections_count": 0,
        "notes": "",
    }
else:
    data["summary"].setdefault("member_findings_reviewed", len(cluster.get("member_findings", [])))
    data["summary"].setdefault("material_links_found", len(data.get("proposed_links", [])) if isinstance(data.get("proposed_links"), list) else 0)
    data["summary"].setdefault("objections_count", len(data.get("objections", [])) if isinstance(data.get("objections"), list) else 0)
    data["summary"].setdefault("notes", "")

data.setdefault("plugin_slug", cluster.get("plugin_slug", ""))
data.setdefault("cluster_id", cluster.get("cluster_id", ""))
data["stage"] = stage
data.setdefault("status", "needs_followup")
for field in ("suggested_actions", "proposed_links", "objections"):
    if not isinstance(data.get(field), list):
        data[field] = []

output_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
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
BUNDLE_REVIEW_ENABLED="$(bundle_review_enabled)"
REVIEWER_PROVIDER="$(reviewer_provider_for_run)"
REVIEWER_MODEL="$(reviewer_model_for_run)"
REVIEW_ROUNDS="$(review_rounds_for_run)"
# Runtime override: CODEX_QUOTA_ACCOUNT env var wins over dispatch value
QUOTA_ACCOUNT="${CODEX_QUOTA_ACCOUNT:-$QUOTA_ACCOUNT}"
TIMEOUT_SECONDS="${TIMEOUT_OVERRIDE:-$DISPATCH_TIMEOUT}"

log_info "slug from dispatch: $DISPATCH_SLUG"
log_info "timeout: ${TIMEOUT_SECONDS}s | parallel-limit: $PARALLEL_LIMIT | source_dir: $SOURCE_DIR"
log_info "quota_account: ${QUOTA_ACCOUNT:-(not set)} | resume_missing_only: $RESUME_MISSING_ONLY"
log_info "stop_after_merge: $STOP_AFTER_MERGE | no_single_agent_fallback: $NO_SINGLE_AGENT_FALLBACK"
log_info "bundle_review_enabled: $BUNDLE_REVIEW_ENABLED | reviewer=${REVIEWER_PROVIDER} (${REVIEWER_MODEL:-<default>}) | review_rounds=${REVIEW_ROUNDS}"

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
    log_warn "Input file for '$agent' not found: $INPUT_FILE — prepared bundle missing. Skipping."
    append_failure "phase2" "$agent" "missing_input_file" "0" "skipped" \
      "Prepared input bundle not found for '$agent' — nothing assigned to this agent (not an error)."
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
  PROBE_EXIT=0
  PROBE_ERR_TEXT=""
  PROBE_SUCCESS=0
  for probe_attempt in 1 2 3; do
    PROBE_OUT=$(mktemp /tmp/orchestrate-probe.XXXXXX)
    PROBE_ERR=$(mktemp /tmp/orchestrate-probe-err.XXXXXX)
    PROBE_EXIT=0
    echo '{"probe":true,"task":"reply with: {\"ok\":true}"}' \
      | codex exec \
          --dangerously-bypass-approvals-and-sandbox \
          -C "$REPO_ROOT" \
          --output-last-message "$PROBE_OUT" \
          2>"$PROBE_ERR" || PROBE_EXIT=$?

    PROBE_ERR_TEXT="$(cat "$PROBE_ERR" 2>/dev/null || true)"
    if quota_signal_in_log "$PROBE_ERR"; then
      if [[ "$probe_attempt" -lt 3 ]]; then
        log_warn "Codex preflight hit usage-limit signal on attempt ${probe_attempt}/3; retrying after short backoff."
        rm -f "$PROBE_OUT" "$PROBE_ERR"
        sleep 3
        continue
      fi
      log_error "Preflight FAILED: Codex quota exhausted after 3 attempts (exit=$PROBE_EXIT)."
      log_error "stderr: $PROBE_ERR_TEXT"
      log_error "Aborting — no agents launched. Use --resume-missing-only after quota reset."
      append_failure "phase2" "preflight" "quota_exhausted" "3" "aborted" \
        "Codex quota probe failed before any agent launched." \
        "codex" "$QUOTA_ACCOUNT" "$PROBE_EXIT" "$PROBE_ERR_TEXT"
      flush_failures
      rm -f "$PROBE_OUT" "$PROBE_ERR"
      exit 2
    fi
    PROBE_SUCCESS=1
    log_info "Preflight quota probe: OK (exit=$PROBE_EXIT, attempt=$probe_attempt)"
    rm -f "$PROBE_OUT" "$PROBE_ERR"
    break
  done
  if [[ "$PROBE_SUCCESS" -ne 1 ]]; then
    log_error "Preflight FAILED: Codex probe did not succeed."
    exit 2
  fi
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

  _CLAUDE_PROBE_ERR="$(mktemp /tmp/orchestrate-claude-probe-err.XXXXXX)"
  _CLAUDE_PROBE_OUT="$(mktemp /tmp/orchestrate-claude-probe.XXXXXX)"
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
    agent-w*) echo "$SKILL_SETS_DIR/skill-set-agent-worker.md" ;;
    agent-a*) echo "$SKILL_SETS_DIR/skill-set-agent-a.md" ;;
    agent-b*) echo "$SKILL_SETS_DIR/skill-set-agent-b.md" ;;
    agent-c*) echo "$SKILL_SETS_DIR/skill-set-agent-c.md" ;;
    agent-d*) echo "$SKILL_SETS_DIR/skill-set-agent-d.md" ;;
    *)        echo "" ;;
  esac
}

render_agent_review_prompt() {
  local slug="$1" agent="$2" input_path="$3" worker_output_path="$4" review_output_path="$5" threat_context_path="$6" round="$7"
  python3 - "$AGENT_REVIEW_PROMPT_TEMPLATE" "$slug" "$agent" "$input_path" "$worker_output_path" "$review_output_path" "$threat_context_path" "$round" <<'PY'
from pathlib import Path
import sys

template_path, slug, agent, input_path, worker_output_path, review_output_path, threat_context_path, round_number = sys.argv[1:9]
text = Path(template_path).read_text(encoding="utf-8", errors="replace")
for needle, value in {
    "{PLUGIN_SLUG}": slug,
    "{AGENT_ID}": agent,
    "{INPUT_BUNDLE_PATH}": input_path,
    "{WORKER_OUTPUT_PATH}": worker_output_path,
    "{REVIEW_OUTPUT_PATH}": review_output_path,
    "{THREAT_CONTEXT_PATH}": threat_context_path,
    "{ROUND_NUMBER}": round_number,
}.items():
    text = text.replace(needle, value)
print(text, end="")
PY
}

render_agent_revision_prompt() {
  local slug="$1" agent="$2" input_path="$3" prev_worker_output="$4" review_output_path="$5" revised_output_path="$6" threat_context_path="$7" round="$8"
  python3 - "$AGENT_REVISION_PROMPT_TEMPLATE" "$slug" "$agent" "$input_path" "$prev_worker_output" "$review_output_path" "$revised_output_path" "$threat_context_path" "$round" <<'PY'
from pathlib import Path
import sys

template_path, slug, agent, input_path, prev_worker_output, review_output_path, revised_output_path, threat_context_path, round_number = sys.argv[1:10]
text = Path(template_path).read_text(encoding="utf-8", errors="replace")
for needle, value in {
    "{PLUGIN_SLUG}": slug,
    "{AGENT_ID}": agent,
    "{INPUT_BUNDLE_PATH}": input_path,
    "{PREVIOUS_WORKER_OUTPUT_PATH}": prev_worker_output,
    "{REVIEW_OUTPUT_PATH}": review_output_path,
    "{OUTPUT_PATH}": revised_output_path,
    "{THREAT_CONTEXT_PATH}": threat_context_path,
    "{ROUND_NUMBER}": round_number,
}.items():
    text = text.replace(needle, value)
print(text, end="")
PY
}

render_cluster_synthesis_prompt() {
  local slug="$1" cluster_id="$2" cluster_pack_path="$3" output_path="$4"
  python3 - "$CLUSTER_SYNTH_PROMPT_TEMPLATE" "$slug" "$cluster_id" "$cluster_pack_path" "$output_path" <<'PY'
from pathlib import Path
import sys

template_path, slug, cluster_id, cluster_pack_path, output_path = sys.argv[1:6]
text = Path(template_path).read_text(encoding="utf-8", errors="replace")
for needle, value in {
    "{PLUGIN_SLUG}": slug,
    "{CLUSTER_ID}": cluster_id,
    "{CLUSTER_PACK_PATH}": cluster_pack_path,
    "{OUTPUT_PATH}": output_path,
}.items():
    text = text.replace(needle, value)
print(text, end="")
PY
}

render_cluster_challenge_prompt() {
  local slug="$1" cluster_id="$2" cluster_pack_path="$3" synth_path="$4" output_path="$5"
  python3 - "$CLUSTER_CHALLENGE_PROMPT_TEMPLATE" "$slug" "$cluster_id" "$cluster_pack_path" "$synth_path" "$output_path" <<'PY'
from pathlib import Path
import sys

template_path, slug, cluster_id, cluster_pack_path, synth_path, output_path = sys.argv[1:7]
text = Path(template_path).read_text(encoding="utf-8", errors="replace")
for needle, value in {
    "{PLUGIN_SLUG}": slug,
    "{CLUSTER_ID}": cluster_id,
    "{CLUSTER_PACK_PATH}": cluster_pack_path,
    "{SYNTH_PATH}": synth_path,
    "{OUTPUT_PATH}": output_path,
}.items():
    text = text.replace(needle, value)
print(text, end="")
PY
}

run_provider_prompt_sync() {
  local provider="$1" model="$2" prompt_file="$3" log_file="$4" last_message_file="$5"
  local rc=0
  if [[ "$provider" == "claude" ]]; then
    local claude_cmd
    claude_cmd=(claude -p --dangerously-skip-permissions --verbose --output-format stream-json)
    if [[ -n "$model" ]]; then
      claude_cmd+=(--model "$model")
    fi
    (
      cd "$REPO_ROOT"
      "${claude_cmd[@]}" \
        2>>"$log_file" \
        < "$prompt_file" \
        | python3 -u "$CLAUDE_STREAM_PARSER" 2>>"$log_file" \
            > "$last_message_file"
    ) || rc=$?
  else
    (
      cd "$REPO_ROOT"
      codex exec \
        --dangerously-bypass-approvals-and-sandbox \
        -C "$REPO_ROOT" \
        --output-last-message "$last_message_file" \
        2>>"$log_file" \
        < "$prompt_file"
    ) || rc=$?
  fi
  return "$rc"
}

run_coded_prompt_with_usage_retries() {
  local provider="$1" model="$2" prompt_file="$3" log_file="$4" last_message_file="$5"
  local rc=0
  local attempt
  mkdir -p "$(dirname "$log_file")" "$(dirname "$last_message_file")"
  for attempt in 1 2 3; do
    : > "$log_file"
    : > "$last_message_file"
    rc=0
    run_provider_prompt_sync "$provider" "$model" "$prompt_file" "$log_file" "$last_message_file" || rc=$?
    if [[ "$provider" == "codex" ]] && quota_signal_in_log "$log_file"; then
      if [[ "$attempt" -lt 3 ]]; then
        log_warn "Codex usage-limit signal for prompt run (attempt ${attempt}/3); retrying after short backoff."
        sleep 3
        continue
      fi
    fi
    return "$rc"
  done
  return "$rc"
}

run_worker_bundle_review_loop() {
  local agent="$1" worker_output="$2"
  local worker_provider="$3" worker_model="$4"
  local input_file review_path revised_path initial_snapshot threat_context_path review_prompt revision_prompt
  local reviewer_log reviewer_last_message revision_log revision_last_message prompt_file rc=0 review_status=""

  [[ "$agent" == agent-w* ]] || return 0
  [[ "$BUNDLE_REVIEW_ENABLED" == "true" ]] || return 0
  [[ "$REVIEW_ROUNDS" -ge 1 ]] || return 0
  [[ -f "$AGENT_REVIEW_PROMPT_TEMPLATE" ]] || return 0
  [[ -f "$AGENT_REVISION_PROMPT_TEMPLATE" ]] || return 0

  input_file="$(input_for_agent "$agent")"
  threat_context_path="$(threat_context_for_run)"
  initial_snapshot="$PHASE2_DIR/${SLUG}-${agent}-worker.initial.json"
  review_path="$PHASE2_DIR/${SLUG}-${agent}-review.r1.json"
  revised_path="$PHASE2_DIR/${SLUG}-${agent}-revised.r1.json"
  reviewer_log="$(logs_phase2_chunked_agent_review_log_path "$SLUG" "$agent" 1)"
  reviewer_last_message="$(logs_phase2_chunked_agent_review_last_message_path "$SLUG" "$agent" 1)"
  revision_log="$(logs_phase2_chunked_agent_revision_log_path "$SLUG" "$agent" 1)"
  revision_last_message="$(logs_phase2_chunked_agent_revision_last_message_path "$SLUG" "$agent" 1)"

  cp -f "$worker_output" "$initial_snapshot"

  prompt_file="$(mktemp /tmp/review-${SLUG}-${agent}.XXXXXX)"
  render_agent_review_prompt "$SLUG" "$agent" "$input_file" "$initial_snapshot" "$review_path" "$threat_context_path" "1" > "$prompt_file"
  log_info "Running reviewer loop for $agent via $REVIEWER_PROVIDER (${REVIEWER_MODEL:-<default>})"
  rc=0
  run_coded_prompt_with_usage_retries "$REVIEWER_PROVIDER" "$REVIEWER_MODEL" "$prompt_file" "$reviewer_log" "$reviewer_last_message" || rc=$?
  rm -f "$prompt_file"
  if [[ "$rc" -ne 0 ]] || ! is_valid_review_output "$review_path"; then
    log_warn "Reviewer loop for $agent failed or produced invalid critique; preserving worker output."
    return 0
  fi

  review_status="$(python3 -c "import json; d=json.load(open('$review_path')); print(d.get('review_status','needs_revision'))" 2>/dev/null || echo needs_revision)"
  if [[ "$review_status" == "stable" ]]; then
    log_info "Reviewer loop for $agent marked bundle stable."
    return 0
  fi

  prompt_file="$(mktemp /tmp/revise-${SLUG}-${agent}.XXXXXX)"
  render_agent_revision_prompt "$SLUG" "$agent" "$input_file" "$initial_snapshot" "$review_path" "$revised_path" "$threat_context_path" "1" > "$prompt_file"
  log_info "Running worker revision for $agent via $worker_provider (${worker_model:-<default>})"
  rc=0
  run_coded_prompt_with_usage_retries "$worker_provider" "$worker_model" "$prompt_file" "$revision_log" "$revision_last_message" || rc=$?
  rm -f "$prompt_file"
  if [[ "$rc" -ne 0 ]] || ! is_valid_agent_output "$revised_path"; then
    log_warn "Worker revision for $agent failed or produced invalid output; preserving original worker output."
    return 0
  fi

  cp -f "$revised_path" "$worker_output"
  log_info "Reviewer loop for $agent applied revised worker output."
  return 0
}

run_cluster_llm_stage() {
  local cluster_plan="$PHASE2_DIR/${SLUG}-cluster-plan.json"
  local threat_context_path synth_count=0 challenge_count=0
  [[ -f "$cluster_plan" ]] || return 0
  [[ -f "$CLUSTER_SYNTH_PROMPT_TEMPLATE" ]] || return 0
  [[ -f "$CLUSTER_CHALLENGE_PROMPT_TEMPLATE" ]] || return 0

  threat_context_path="$(threat_context_for_run)"

  while IFS=$'\t' read -r cluster_id cluster_path cluster_input_path cluster_pack_path; do
    [[ -n "$cluster_id" && -n "$cluster_path" ]] || continue
    [[ "$cluster_path" != /* ]] && cluster_path="$REPO_ROOT/$cluster_path"
    [[ -f "$cluster_path" ]] || continue
    [[ -z "$cluster_pack_path" ]] && cluster_pack_path="$cluster_input_path"
    [[ -z "$cluster_pack_path" ]] && cluster_pack_path="$cluster_path"
    [[ "$cluster_pack_path" != /* ]] && cluster_pack_path="$REPO_ROOT/$cluster_pack_path"
    [[ -f "$cluster_pack_path" ]] || continue

    local synth_provider synth_model challenge_provider challenge_model
    synth_provider="$(python3 -c "import json; d=json.load(open('$cluster_path')); print(d.get('recommended_models',{}).get('synthesizer',{}).get('provider','codex'))" 2>/dev/null || echo codex)"
    synth_model="$(python3 -c "import json; d=json.load(open('$cluster_path')); print(d.get('recommended_models',{}).get('synthesizer',{}).get('model','gpt-5.4'))" 2>/dev/null || echo gpt-5.4)"
    challenge_provider="$(python3 -c "import json; d=json.load(open('$cluster_path')); print(d.get('recommended_models',{}).get('challenger',{}).get('provider','claude'))" 2>/dev/null || echo claude)"
    challenge_model="$(python3 -c "import json; d=json.load(open('$cluster_path')); print(d.get('recommended_models',{}).get('challenger',{}).get('model','claude-sonnet-4.6'))" 2>/dev/null || echo claude-sonnet-4.6)"

    local synth_path challenge_path synth_log synth_last_message challenge_log challenge_last_message prompt_file rc
    synth_path="$PHASE2_DIR/${SLUG}-${cluster_id}.synth.json"
    challenge_path="$PHASE2_DIR/${SLUG}-${cluster_id}.challenge.json"
    synth_log="$(logs_phase2_cluster_stage_log_path "$SLUG" "$cluster_id" synth)"
    synth_last_message="$(logs_phase2_cluster_stage_last_message_path "$SLUG" "$cluster_id" synth)"
    challenge_log="$(logs_phase2_cluster_stage_log_path "$SLUG" "$cluster_id" challenge)"
    challenge_last_message="$(logs_phase2_cluster_stage_last_message_path "$SLUG" "$cluster_id" challenge)"

    prompt_file="$(mktemp /tmp/cluster-synth-${SLUG}-${cluster_id}.XXXXXX)"
    render_cluster_synthesis_prompt "$SLUG" "$cluster_id" "$cluster_pack_path" "$synth_path" > "$prompt_file"
    log_info "Running cluster synthesizer for $cluster_id via $synth_provider (${synth_model:-<default>})"
    rc=0
    run_coded_prompt_with_usage_retries "$synth_provider" "$synth_model" "$prompt_file" "$synth_log" "$synth_last_message" || rc=$?
    rm -f "$prompt_file"
    normalize_cluster_output_file "$synth_path" "synthesis" "$cluster_pack_path"
    if [[ "$rc" -ne 0 ]] || ! is_valid_cluster_output "$synth_path"; then
      log_warn "Cluster synthesizer for $cluster_id failed or produced invalid output; skipping challenger."
      append_failure "phase2" "$cluster_id" "cluster_synth_failed" "0" "continued" \
        "Cluster synthesis failed or produced invalid JSON; cluster challenge skipped." \
        "$synth_provider" "$QUOTA_ACCOUNT"
      continue
    fi
    synth_count=$((synth_count + 1))

    prompt_file="$(mktemp /tmp/cluster-challenge-${SLUG}-${cluster_id}.XXXXXX)"
    render_cluster_challenge_prompt "$SLUG" "$cluster_id" "$cluster_pack_path" "$synth_path" "$challenge_path" > "$prompt_file"
    log_info "Running cluster challenger for $cluster_id via $challenge_provider (${challenge_model:-<default>})"
    rc=0
    run_coded_prompt_with_usage_retries "$challenge_provider" "$challenge_model" "$prompt_file" "$challenge_log" "$challenge_last_message" || rc=$?
    rm -f "$prompt_file"
    normalize_cluster_output_file "$challenge_path" "challenge" "$cluster_pack_path"
    if [[ "$rc" -ne 0 ]] || ! is_valid_cluster_output "$challenge_path"; then
      log_warn "Cluster challenger for $cluster_id failed or produced invalid output."
      append_failure "phase2" "$cluster_id" "cluster_challenge_failed" "0" "continued" \
        "Cluster challenge failed or produced invalid JSON; synthesis artifact preserved." \
        "$challenge_provider" "$QUOTA_ACCOUNT"
      continue
    fi
    challenge_count=$((challenge_count + 1))
  done < <(python3 - "$cluster_plan" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
for cluster in data.get("clusters", []):
    print(f"{cluster.get('cluster_id','')}\t{cluster.get('path','')}\t{cluster.get('input_path','')}\t{cluster.get('pack_path','')}")
PY
  )

  log_info "Cluster LLM stage complete: synth=${synth_count} challenge=${challenge_count}"
  return 0
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
  local input_file out_file skill_set_file prompt_file agent_provider agent_model threat_context_path
  local agent_log_file agent_live_log_file agent_last_message_file

  input_file=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get('inputs',{}).get(sys.argv[2],''))
" "$DISPATCH_FILE" "$agent")

  out_file="$(agent_output_file "$agent")"
  skill_set_file="$(skill_set_file_for_agent "$agent")"
  agent_provider="$(provider_for_agent "$agent")"
  agent_model="$(model_for_agent "$agent")"
  threat_context_path="$(threat_context_for_run)"
  agent_log_file="$(logs_phase2_chunked_agent_run_log_path "$SLUG" "$agent")"
  agent_live_log_file="$(logs_phase2_chunked_agent_run_live_path "$SLUG" "$agent")"
  agent_last_message_file="$(logs_phase2_chunked_agent_last_message_path "$SLUG" "$agent")"

  mkdir -p "$(dirname "$agent_log_file")"
  : > "$agent_log_file"
  : > "$agent_live_log_file"
  : > "$agent_last_message_file"

  log_info "Launching agent: $agent  provider=$agent_provider  model=${agent_model:-<default>}  input=$input_file  output=$out_file"

  if [[ -z "$skill_set_file" || ! -f "$skill_set_file" ]]; then
    log_error "No SKILL SET file found for agent '$agent' (resolved: '$skill_set_file'). Skipping."
    append_failure "phase2" "$agent" "missing_skill_set" "0" "skipped" \
      "No SKILL SET file found for agent '$agent'." \
      "$agent_provider" "$QUOTA_ACCOUNT"
    return 1
  fi

  # Build prompt file: SKILL SET content + runtime context block
  prompt_file="$(mktemp /tmp/prompt-${SLUG}-${agent}.XXXXXX)"
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
    echo "- **Threat context:** ${threat_context_path}"
    echo ""
    echo "Read the threat context first (matched_categories + priority_vulns) before deep source review."
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
        2> >(tee -a "$agent_log_file" "$agent_live_log_file" >&2) \
        < "$prompt_file" \
        | python3 -u "$CLAUDE_STREAM_PARSER" 2> >(tee -a "$agent_log_file" "$agent_live_log_file" >&2)
    ) | tee -a "$agent_live_log_file" > "$agent_last_message_file" &
  else
    # Default: codex exec
    (
      cd "$REPO_ROOT"
      AGENT_INPUT_FILE="$input_file" \
      AGENT_OUTPUT_FILE="$out_file" \
      AGENT_ID="$agent" \
      AGENT_SLUG="$SLUG" \
      codex exec \
        --dangerously-bypass-approvals-and-sandbox \
        -C "$REPO_ROOT" \
        --output-last-message "$agent_last_message_file" \
        < "$prompt_file" \
        > >(tee -a "$agent_live_log_file") \
        2> >(tee -a "$agent_log_file" "$agent_live_log_file" >&2)
    ) &
  fi

  local pid=$!
  state_set "$agent" "pid"      "$pid"
  state_set "$agent" "start"    "$(date +%s)"
  state_set "$agent" "status"   "running"
  state_set "$agent" "provider" "$agent_provider"
  state_set "$agent" "model"    "$agent_model"
  log_info "Agent '$agent' launched with PID $pid (provider=$agent_provider model=${agent_model:-<default>} prompt=$prompt_file live_log=$agent_live_log_file)"
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
      if [[ "$agent" == agent-w* ]]; then
        run_worker_bundle_review_loop "$agent" "$out_file" "$agent_provider" "$(state_get "$agent" model)" || true
      fi
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
          "Agent '$agent' timed out after retry — assigned bundle findings may be incomplete." \
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
      agent_log="$(logs_phase2_chunked_agent_run_log_path "$SLUG" "$agent")"
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
        if [[ -n "$quota_signal" && "$agent_provider" == "codex" ]]; then
          quota_retries="$(state_get "$agent" quota_retries)"
          quota_retries="${quota_retries:-0}"
          if [[ "$quota_retries" -lt 3 ]]; then
            quota_retries=$((quota_retries + 1))
            state_set "$agent" "quota_retries" "$quota_retries"
            log_warn "Retrying $agent after usage-limit signal (${quota_retries}/3) because cached quota responses can be stale."
            sleep 3
            launch_agent "$agent"
            STILL_RUNNING+=("$agent")
            continue
          fi
        fi
        failure_type="${quota_signal:-missing_output}"
        append_failure "phase2" "$agent" "$failure_type" "0" "skipped" \
          "Agent '$agent' wrote no output — assigned bundle findings absent." \
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
  if [[ "$NO_SINGLE_AGENT_FALLBACK" -eq 1 ]]; then
    log_error "All agents failed and --no-single-agent-fallback is set."
    append_failure "phase2" "ALL" "all_agents_failed" "0" "aborted" \
      "All chunked worker agents failed; no single-agent fallback was allowed."
    flush_failures
    exit 2
  fi
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

if [[ "$STOP_AFTER_MERGE" -eq 1 ]]; then
  flush_failures
  log_info "Stopping after deterministic local merge as requested."
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 6.5: Deterministic cluster planning (cross-bundle synthesis prep)
# ---------------------------------------------------------------------------
if [[ -f "$CLUSTER_SCRIPT" ]]; then
  log_info "=== Step 6.5: Building deterministic cluster plan ==="
  if python3 "$CLUSTER_SCRIPT" "$SLUG" --reports-dir "$REPORTS_DIR"; then
    log_info "Cluster planning complete."
    if [[ -f "$PHASE2_DIR/${SLUG}-cluster-plan.json" && -f "$CLUSTER_PACK_SCRIPT" ]]; then
      log_info "=== Step 6.6: Building deterministic cluster evidence packs ==="
      if python3 "$CLUSTER_PACK_SCRIPT" "$SLUG" --reports-dir "$REPORTS_DIR"; then
        log_info "Cluster evidence pack build complete."
        log_info "=== Step 6.7: Running cluster synthesizer/challenger stage ==="
        run_cluster_llm_stage || true
      else
        log_warn "Cluster evidence pack build failed for slug '$SLUG'. Continuing without cluster LLM stage."
        append_failure "phase2" "cluster-pack" "cluster_pack_build_failed" "0" "continued" \
          "build_cluster_evidence_pack.py returned non-zero exit code; cluster synth/challenge skipped."
      fi
    fi
  else
    log_warn "Cluster planning failed for slug '$SLUG'. Continuing with merged Phase 2 output."
    append_failure "phase2" "cluster-plan" "cluster_build_failed" "0" "continued" \
      "build_candidate_clusters.py returned non-zero exit code; cluster artifacts missing."
  fi
else
  log_warn "Cluster script not found: $CLUSTER_SCRIPT — skipping deterministic cluster planning."
fi

# ---------------------------------------------------------------------------
# Step 6.8: Deterministic consensus writer
# ---------------------------------------------------------------------------
if [[ -f "$CONSENSUS_SCRIPT" ]]; then
  log_info "=== Step 6.8: Writing deterministic Phase 2 consensus ==="
  if ! python3 "$CONSENSUS_SCRIPT" "$SLUG" --reports-dir "$REPORTS_DIR"; then
    log_warn "Consensus writer failed for slug '$SLUG'. Existing canonical Phase 2 may still reflect local merge."
    append_failure "phase2" "consensus" "consensus_write_failed" "0" "continued" \
      "write_phase2_consensus.py returned non-zero exit code."
  fi
else
  log_warn "Consensus script not found: $CONSENSUS_SCRIPT — skipping consensus stage."
fi

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
