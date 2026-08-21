# FAILURE-MODES.md — Phase 2 Failure Handling and Trust Signals

This document describes the current Phase 2 failure-handling contract after
Wave 1 and Wave 2 hardening.

It covers:
- where failures are logged
- which log family contains which class of information
- how to read trust state from Phase 2 artifacts
- what each major failure mode means downstream

---

## Failure Log Location

Chunked orchestration failures are appended to:

```text
reports/logs/<slug>/phase2/chunked/failures.json
```

The file is written at the end of orchestration runs, including clean runs with
an empty `failures` array.

Example shape:

```json
{
  "failures": [
    {
      "phase": "phase2",
      "agent": "agent-w09",
      "failure_type": "timeout",
      "timestamp": "2026-04-08T10:30:00Z",
      "retry_count": 1,
      "resolution": "skipped",
      "impact": "Bundle findings may be absent from local merge",
      "provider": "claude",
      "quota_account": "",
      "stderr_excerpt": "..."
    }
  ]
}
```

---

## Log Families

Phase 2 now separates scheduler, provider, assistant, and stderr channels.

| Path | Message Class |
|------|---------------|
| `reports/logs/<slug>/phase2/run.live.log` | Phase 2 envelope / coordinator progress |
| `reports/logs/<slug>/phase2/run.err` | Phase 2 envelope warnings/errors |
| `reports/logs/<slug>/phase2/chunked/run.live.log` | Chunked scheduler progress |
| `reports/logs/<slug>/phase2/chunked/run.err` | Chunked scheduler warnings/errors |
| `reports/logs/<slug>/phase2/chunked/failures.json` | Structured chunked failure audit trail |
| `reports/logs/<slug>/phase2/chunked/agents/<agent>/attempt-XX/assistant.live.log` | Parsed assistant text stream for one worker attempt |
| `reports/logs/<slug>/phase2/chunked/agents/<agent>/attempt-XX/provider.raw.log` | Raw provider output for one worker attempt |
| `reports/logs/<slug>/phase2/chunked/agents/<agent>/attempt-XX/stderr.err` | Provider stderr for one worker attempt |
| `reports/logs/<slug>/phase2/chunked/agents/<agent>/attempt-XX/last-message.txt` | Last assistant message snapshot for one worker attempt |
| `reports/logs/<slug>/phase2/chunked/agents/<agent>/review.r1.live.log` | Reviewer live text |
| `reports/logs/<slug>/phase2/chunked/agents/<agent>/review.r1.raw.log` | Reviewer raw provider log |
| `reports/logs/<slug>/phase2/chunked/agents/<agent>/revision.r1.live.log` | Revision live text |
| `reports/logs/<slug>/phase2/chunked/agents/<agent>/revision.r1.raw.log` | Revision raw provider log |
| `reports/logs/<slug>/phase2/cluster/run.live.log` | Cluster scheduler progress |
| `reports/logs/<slug>/phase2/cluster/run.err` | Cluster warnings/errors |

Rule of thumb:
- read `run.live.log` when you want scheduler progress
- read `assistant.live.log` when you want the LLM's text stream
- read `provider.raw.log` when you need low-level provider facts
- read `stderr.err` when you suspect CLI/runtime failures

---

## Trust State

Phase 2 now emits explicit trust semantics instead of forcing operators to infer
trust from warning tone alone.

Primary artifacts:

```text
reports/phase2/<slug>-phase2.state.json
reports/phase2/<slug>-phase2.local.json
reports/phase2/<slug>-phase2.consensus.json
reports/phase2/<slug>-phase2.json
```

Current values:

| Value | Meaning |
|-------|---------|
| `success` | Required validation layers completed without known degradation |
| `degraded_success` | Output was produced, but degradation signals were recorded |
| `partial_success` | The phase produced partial output but did not complete the full contract |
| `failed` | The phase failed and the output must not be treated as canonical |
| `in_progress` | Runtime state only; work is still active |

Common degradation signals:
- `agents_missing`
- `schema_errors`
- `conflicts_present`
- `unresolved_clusters`
- `open_questions_present`
- `missing_evidence_present`
- `cluster_synthesis_incomplete`
- `cluster_challenge_incomplete`
- `cluster_plan_missing`

Canonical publish rule:
- `reports/phase2/<slug>-phase2.json` is authoritative only after the consensus
  writer succeeds.
- `reports/phase2/<slug>-phase2.local.json` is a local merge artifact, not
  downstream truth.

---

## Failure Modes

### 1. Empty Execution Surface

Condition:
- dispatch produced no runnable agents

Current behavior:
- if prep metadata indicates `total_bundles=0`, orchestration exits cleanly as a
  justified no-op
- if the dispatch is broken and still claims runnable work, orchestration fails
  closed with `failure_type: "empty_execution_surface"`

Downstream impact:
- broken dispatch: no merge, no canonical Phase 2 output
- explicit zero-bundle workload: no-op, not an integrity failure

### 2. Worker Timeout

Condition:
- a bundle does not produce a valid attempt-local output before timeout

Current behavior:
1. mark attempt timeout
2. kill process tree
3. retry once with a new attempt-local output path
4. if both attempts fail, record `failure_type: "timeout"`

Downstream impact:
- the affected bundle may be absent from local merge
- merge trust state should surface degradation if expected bundles are missing

### 3. Invalid or Drifted Worker Output

Condition:
- provider output exists but fails JSON/schema expectations

Current behavior:
1. keep raw provider artifact
2. normalize into attempt-local normalized output
3. promote only if normalized output validates
4. otherwise record failure and skip bundle

Downstream impact:
- raw evidence remains available for repair/debug
- canonical per-agent output is not promoted from malformed data

### 4. Reviewer or Revision Drift

Condition:
- reviewer/revision returns structurally valid JSON that still drifts from
  `agent-output.schema.json`

Current behavior:
- revision artifacts are normalized before promotion
- if normalization still cannot satisfy the schema, the original worker output
  is preserved and the run emits warnings

Downstream impact:
- the bundle remains mergeable, but the revised view is not adopted
- trust may degrade if the resulting merge misses expected coverage

### 5. Quota or Usage Exhaustion

Condition:
- provider exits early or signals usage exhaustion

Current behavior:
- record failure entry with provider/quota context
- keep prior valid outputs
- resume path is:

```bash
bash tools/bin/orchestrate-agents.sh <slug> --resume-missing-only
```

Downstream impact:
- unaffected bundles still merge
- cost ledger still records the failed call if the provider surfaced telemetry

### 6. All Agents Failed

Condition:
- no bundle produced a valid canonical per-agent output

Current behavior:
- record `failure_type: "all_agents_failed"`
- unless `--no-single-agent-fallback` is set, recurse into `run-phase2.sh`

Downstream impact:
- successful fallback yields a single-agent Phase 2 path
- failed fallback yields no canonical Phase 2 output

### 7. Merge Failure

Condition:
- `merge_agent_outputs.py` returns non-zero

Current behavior:
- orchestrator records `failure_type: "merge_failed"` and exits non-zero

Downstream impact:
- no local merge artifact is produced
- no consensus/canonical publish can occur

### 8. Cluster or Consensus Degradation

Condition:
- cluster planning, pack building, synth/challenge, or consensus writing fails

Current behavior:
- cluster-stage failures are recorded
- trust/degradation signals are propagated into summary artifacts when output is
  still produced
- consensus failure in the canonical Phase 2 coordinator must fail closed and
  block `phase2.json`

Downstream impact:
- local merge may exist
- canonical publish must not proceed if consensus-authoritative write fails

---

## Recovery Checklist

```bash
# 1. Read structured failures
cat reports/logs/<slug>/phase2/chunked/failures.json | python3 -m json.tool

# 2. Read scheduler progress
tail -f reports/logs/<slug>/phase2/chunked/run.live.log

# 3. Read one agent's assistant stream
tail -f reports/logs/<slug>/phase2/chunked/agents/<agent>/attempt-01/assistant.live.log

# 4. Read one agent's raw provider stream
tail -f reports/logs/<slug>/phase2/chunked/agents/<agent>/attempt-01/provider.raw.log

# 5. Inspect state and trust
cat reports/phase2/<slug>-phase2.state.json | python3 -m json.tool
cat reports/phase2/<slug>-phase2.local.json | python3 -m json.tool
cat reports/phase2/<slug>-phase2.consensus.json | python3 -m json.tool
```

For per-run cost accountability:

```bash
python3 tools/bin/quota-report.py --run-id <run_id> --days 30
```

---

## See Also

- `/Volumes/External_Disk/timo/WORDPRESS-PLUGIN-RESEARCH/docs/ORCHESTRATION.md`
- `/Volumes/External_Disk/timo/WORDPRESS-PLUGIN-RESEARCH/WORKFLOW-GUIDE.md`
- `/Volumes/External_Disk/timo/WORDPRESS-PLUGIN-RESEARCH/tools/bin/orchestrate-agents.sh`
- `/Volumes/External_Disk/timo/WORDPRESS-PLUGIN-RESEARCH/tools/bin/merge_agent_outputs.py`
- `/Volumes/External_Disk/timo/WORDPRESS-PLUGIN-RESEARCH/tools/bin/write_phase2_consensus.py`
