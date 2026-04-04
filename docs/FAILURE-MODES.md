# FAILURE-MODES.md — Multi-Agent Orchestration Failure Handling

> Source authority: `7-workflow-wp/multi-agent-plan.md:483-512`
> This document describes how `orchestrate-agents.sh` handles each failure condition
> and what the downstream impact is.

---

## Failure Log Location

All failures are appended to:

```
reports/logs/<slug>-failures.json
```

Format:

```json
{
  "failures": [
    {
      "phase": "phase2",
      "agent": "agent-a2",
      "failure_type": "timeout",
      "timestamp": "2025-01-15T10:30:00Z",
      "retry_count": 1,
      "resolution": "skipped",
      "impact": "AJAX auth findings may be incomplete"
    }
  ]
}
```

The file is written at the end of every orchestration run, even on success (empty `failures` array).

---

## Failure Mode Reference

### 1. Agent Timeout

**Condition:** Agent does not write a valid output file within `timeout_seconds`
(from dispatch config, or `--timeout` override).

**Action:**
1. Kill the agent process.
2. Retry once (same agent, same input).
3. If retry also times out → skip agent, log `failure_type: "timeout"`, `retry_count: 1`.

**Downstream impact:** Findings for the timed-out agent's EP group are absent from
the merge. The merge proceeds with the remaining agents' output.

**Log entry example:**
```json
{
  "failure_type": "timeout",
  "agent": "agent-a2",
  "retry_count": 1,
  "resolution": "skipped",
  "impact": "AJAX auth findings may be incomplete"
}
```

**Recovery:** Re-run the single agent manually and re-merge, or accept findings
for the remaining groups as partial coverage.

---

### 2. Agent Malformed / Invalid JSON Output

**Condition:** Agent writes an output file but it is not valid JSON.

**Action:**
1. Attempt JSON repair via Python (load with error handling).
2. If repair succeeds → treat as done.
3. If repair fails → reject agent output, log `failure_type: "invalid_json"`.
   Merge continues with remaining valid outputs.

**Downstream impact:** The offending agent's findings are excluded from the merge.
Other agents' findings are unaffected.

**Log entry example:**
```json
{
  "failure_type": "invalid_json",
  "agent": "agent-b",
  "retry_count": 0,
  "resolution": "rejected",
  "impact": "Full-IR agent output rejected — stored XSS / SQLi findings for other EPs may be absent"
}
```

**Recovery:** Inspect `reports/logs/<slug>-agent-b.log` for the agent's stderr.
Re-run the agent with a longer timeout or adjusted prompt, then re-merge.

---

### 3. Agent Missing Output File

**Condition:** Agent process exits (any exit code) without creating the expected
`reports/<slug>-agent-{id}.json` file.

**Action:**
- Log `failure_type: "missing_output"`, `resolution: "skipped"`.
- Merge proceeds with remaining agents' output.

**Downstream impact:** Same as timeout — findings for this EP group absent.

**Log entry example:**
```json
{
  "failure_type": "missing_output",
  "agent": "agent-c",
  "retry_count": 0,
  "resolution": "skipped",
  "impact": "Shortcode EP findings absent from merge"
}
```

**Note:** If the IR slice for this agent was empty (no EPs in group), an absent
output file is expected and is logged as `missing_input_file` at startup — not
a failure.

---

### 4. Agent Missing Input / Empty IR Slice

**Condition:** The dispatch config lists an agent but its input file does not
exist, or the file is empty / not found on disk.

**Action:**
- Skip the agent before launch (no Codex CLI call made).
- Log `failure_type: "missing_input_file"`, `resolution: "skipped"`.

**Downstream impact:** None — an absent IR slice means no EPs in that group.
This is expected behavior, not an error.

**Log entry example:**
```json
{
  "failure_type": "missing_input_file",
  "agent": "agent-d",
  "retry_count": 0,
  "resolution": "skipped",
  "impact": "REST EP findings absent from merge — IR slice empty (no REST endpoints)"
}
```

---

### 5. All Agents Fail

**Condition:** Every agent in the dispatch config either times out, writes no
output, or writes malformed JSON.

**Action:**
- Orchestrator exits with code `2`.
- No merge is attempted.
- Logs `failure_type: "all_agents_failed"` for agent `"ALL"`.
- Sentinel file is NOT written.

**Downstream impact:** The multi-agent pipeline produces no Phase 2 output.
Fallback: run single-agent Phase 2 manually.

```bash
# Fallback: single-agent Phase 2
bash tools/bin/run-phase2.sh --slug <slug>
```

Set `multi_agent_fallback: true` in the run manifest if you trigger this fallback.

---

### 6. Merge Script Failure

**Condition:** `merge_agent_outputs.py` returns a non-zero exit code.

**Action:**
- Orchestrator logs `failure_type: "merge_failed"`, exits with code `1`.
- Sentinel file is NOT written.

**Downstream impact:** No canonical `<slug>-phase2.json` written. Gate cannot run.

**Recovery:** Inspect agent output files manually. Re-run merge:
```bash
python3 tools/bin/merge_agent_outputs.py <slug>
```

---

### 7. Claude Code Verify Fail / Timeout (Phase 2.9)

**Condition:** The optional Claude Code verify step (Session 21) fails or times out.

**Action (handled outside this script):**
- Accept `<slug>-phase2.json` as produced by merge (unverified output).
- Flag `unverified: true` in the run manifest.
- Gate runs on merged output.

**Note:** This script writes `<slug>-merge-ready` sentinel after successful merge.
The verify step runs after the sentinel is present. If verify is skipped or fails,
the gate still has the merged output to work with.

---

### 8. High Conflict Rate in Merge

**Condition (detected by merge_agent_outputs.py):** More than 50% of findings
have conflicting verdicts across agents.

**Action (handled by merge script):**
- Flag `high_conflict_rate: true` in the merged output.
- Escalate: Claude Code performs full review instead of spot-check.

**Downstream impact:** Increased Claude Code review time and token cost, but
higher output quality.

**This orchestrator's role:** None beyond writing the sentinel. The merge script
handles conflict detection and escalation flagging.

---

## Quick Reference

| Failure Type | Retry? | Merge Continues? | Sentinel Written? | Exit Code |
|--------------|--------|-----------------|-------------------|-----------|
| timeout | 1x | Yes (if others ok) | Yes (if merge ok) | 0 |
| invalid_json | No | Yes (if others ok) | Yes (if merge ok) | 0 |
| missing_output | No | Yes (if others ok) | Yes (if merge ok) | 0 |
| missing_input_file | No (skip at start) | Yes | Yes (if merge ok) | 0 |
| all_agents_failed | — | No | **No** | **2** |
| merge_failed | No | — | **No** | **1** |

---

## Diagnosing Failures

```bash
# View failure log
cat reports/logs/<slug>-failures.json | python3 -m json.tool

# View per-agent stderr
cat reports/logs/<slug>-agent-<id>.log

# Check which agents produced output
ls -la reports/<slug>-agent-*.json

# Check if merge-ready sentinel was written
ls -la reports/<slug>-merge-ready

# Check merged output validity
python3 -c "import json; json.load(open('reports/<slug>-phase2.json'))" && echo "Valid"
```

---

## See Also

- `docs/ORCHESTRATION.md` — Pipeline usage guide
- `7-workflow-wp/multi-agent-plan.md:483-512` — Failure mode specification
- `tools/bin/orchestrate-agents.sh` — Orchestrator implementation
- `tools/bin/merge_agent_outputs.py` — Merge script
