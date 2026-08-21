# ORCHESTRATION.md — Multi-Agent Phase 2 Pipeline

> Source authority: `7-workflow-wp/multi-agent-plan.md:400-520`
> Current stabilization target: `7-workflow-wp/PHASE2-ARCHITECTURE-SPEC.md`
> This document describes how to run the multi-agent Phase 2 pipeline.

---

## Overview

The multi-agent pipeline distributes Phase 2 (LLM triage) across several agents.
Prep now computes candidate hypotheses from IR + Semgrep + Psalm, classifies them
by bug family / sink family / trust boundary, and packs bounded worker bundles
(`agent-wNN`). Legacy per-entry-point-group slices are still written for compatibility,
but dispatch prefers bundle workers plus the specialized full-IR agents B/C/D.
Provider is configurable per agent (Codex CLI or Claude Code CLI). Wave 6 keeps
Codex as the baseline provider and only routes Claude into selective
contradiction-heavy stages when `reports/phase2/<slug>-provider-policy.json`
records a high-value potential or post-review escalation. Outputs are merged by
`merge_agent_outputs.py`, refined through deterministic cluster/consensus
stages, and then consumed by the Phase 3 gate.

```
prepare_agent_inputs.py
        ↓
  reports/phase2/prep/<slug>/dispatch.json
        ↓
orchestrate-agents.sh <slug>
        ↓
  agent-w01 [codex exec] ─┐
  agent-w02 [codex exec]  │  (default: 4-way concurrency; tune with --parallel-limit)
  agent-b   [codex exec]  │  (provider per-agent from dispatch provider_map / provider policy)
  agent-c   [claude -p] ──┘  (only when provider policy escalates a selective stage)
        ↓
  reports/phase2/agents/<slug>/*.output.json
        ↓
merge_agent_outputs.py <slug>
        ↓
  reports/phase2/<slug>-phase2.merged.json  (archive)
  reports/phase2/<slug>-phase2.local.json   (local merged result)
        ↓
build_candidate_clusters.py <slug>
        ↓
  reports/phase2/<slug>-cluster-plan.json   (cross-bundle synthesis plan)
  reports/phase2/<slug>-cluster-cNN.json    (bounded cluster artifacts)
  reports/phase2/<slug>-cluster-cNN.input.json
        ↓
build_cluster_evidence_pack.py <slug>
        ↓
  reports/phase2/<slug>-cluster-cNN.pack.json
        ↓
  cluster synthesizer / challenger
        ↓
  reports/phase2/<slug>-cluster-cNN.synth.json
  reports/phase2/<slug>-cluster-cNN.challenge.json
        ↓
write_phase2_consensus.py <slug>
        ↓
  reports/phase2/<slug>-phase2.consensus.json
  reports/phase2/<slug>-phase2.json         (canonical — gate reads this)
        ↓
  <slug>-merge-ready            (sentinel, written by orchestrator)
        ↓
run-phase3.sh --slug <slug>
```

---

## Prerequisites

1. Phase 1 scan complete: `reports/phase1/<slug>-ir.json` exists.
2. Agent inputs prepared: `python3 tools/bin/prepare_agent_inputs.py <slug>`
   - Produces `reports/phase2/prep/<slug>/dispatch.json`
   - Produces `reports/phase2/prep/<slug>/candidate-bundles/agent-wNN.input.json` per worker bundle
   - Also produces `reports/phase2/prep/<slug>/legacy-slices/<slug>-ir-slice-*.json` per legacy EP group
3. Provider routing is authority-driven by `reports/phase2/<slug>-provider-policy.json`; `--with-claude` should be read as explicit shorthand for `--providers codex,claude`, not as a best-effort hint.
4. Threat context available: `reports/context/<slug>-threat-context.json`
   - Generated automatically by `scan-all.sh`
   - Passed into agent runtime prompts during orchestration
4. Provider CLIs on `$PATH`:
   - **Codex CLI** — required for any agent with `provider=codex` (default).
   - **Claude Code CLI** (`claude`) — required only if `provider_map` routes any agent to `claude`. The orchestrator's Step 3b preflight will fail fast with a clear error if the CLI is missing or auth is broken.

---

## Running the Pipeline

### Automation Mode (recommended)

```bash
bash tools/bin/run-pipeline.sh <slug> --multi-agent
bash tools/bin/run-pipeline.sh <slug> --multi-agent --resume
```

For a specific slug, this now runs the canonical coordinator path with chunked
worker mode forced inside `run-phase2.sh`:
Phase 1 → Threat Context → canonical chunked Phase 2 → Gate → Report

`--resume` là public recovery flag cho wrapper này:
- giữ nguyên adaptive parallelism hiện có
- không bypass quota preflight
- map nội bộ xuống `run-phase2.sh --resume-existing` và `PHASE2_CHUNKED_RESUME_MISSING_ONLY=true`

If you omit `<slug>`, multi-agent mode uses existing `reports/phase1/*-ir.json`
artifacts, refreshes threat context per slug when plugin source is present,
and runs canonical chunked Phase 2 → Gate → Report for each slug.

### Manual Mode (quota-controlled)

**Step 1: Phase 1 scan**
```bash
bash tools/bin/scan-all.sh plugins/<slug>/
```

This also generates `reports/context/<slug>-threat-context.json` when fresh output is not already available.

**Step 2: Prepare agent inputs**
```bash
python3 tools/bin/prepare_agent_inputs.py <slug>
```

**Step 3: Run orchestrator**
```bash
bash tools/bin/orchestrate-agents.sh <slug>
# Optional overrides:
bash tools/bin/orchestrate-agents.sh <slug> --parallel-limit 2   # parallel (quota-permitting)
bash tools/bin/orchestrate-agents.sh <slug> --timeout 1200        # longer timeout
bash tools/bin/orchestrate-agents.sh <slug> --resume-missing-only # skip already-completed agents
```

**Step 4: Verify state and merge output**
```bash
cat reports/phase2/<slug>-phase2.state.json | python3 -m json.tool
cat reports/phase2/<slug>-phase2.local.json | python3 -m json.tool > /dev/null && echo "Local merge valid"
# Canonical only exists after consensus-authoritative publish:
cat reports/phase2/<slug>-phase2.json | python3 -m json.tool > /dev/null && echo "Canonical valid"
```

**Step 5: Gate + Report**
```bash
bash tools/bin/run-phase3.sh --slug <slug>
```

---

## Dispatch Config Format

`reports/phase2/prep/<slug>/dispatch.json`:

```json
{
  "slug": "plugin-name",
  "strategy": "candidate_chunk_v2",
  "agents": ["agent-w01", "agent-w02", "agent-b", "agent-c", "agent-d"],
  "inputs": {
    "agent-w01": "reports/phase2/prep/<slug>/candidate-bundles/agent-w01.input.json",
    "agent-w02": "reports/phase2/prep/<slug>/candidate-bundles/agent-w02.input.json",
    "agent-b":  "reports/phase1/<slug>-ir.json",
    "agent-c":  "reports/phase1/<slug>-ir.json",
    "agent-d":  "reports/phase1/<slug>-ir.json"
  },
  "source_dir": "plugins/<slug>/",
  "threat_context_path": "reports/context/<slug>-threat-context.json",
  "timeout_seconds": 600,
  "quota_account": "",
  "provider_map": {},
  "default_provider": "codex",
  "model_map": {},
  "bundle_inventory": "reports/phase2/prep/<slug>/candidate-inventory.json",
  "agent_output_dir": "reports/phase2/agents/<slug>",
  "phase2_state_path": "reports/phase2/<slug>-phase2.state.json",
  "bundle_review_enabled": true,
  "reviewer_provider": "codex",
  "reviewer_model": "gpt-5.4",
  "review_rounds": 1,
  "cluster_synth_provider": "codex",
  "cluster_synth_model": "gpt-5.4",
  "cluster_challenger_provider": "codex",
  "cluster_challenger_model": "gpt-5.4"
}
```

**Provider routing:**
- `default_provider`: used for any agent not listed in `provider_map`. Values: `"codex"` (Codex CLI) | `"claude"` (Claude Code CLI).
- `provider_map`: per-agent override. Leave empty (`{}`) to use `default_provider` for all agents.
- `model_map`: optional per-agent model pin (only meaningful when provider is `"claude"`). If omitted for an agent, the Claude CLI's current default model is used. Recommended: set explicitly for reproducibility.
- `quota_account`: optional string to tag which Codex account was used (for traceability across quota exhaustion events). Set via `CODEX_QUOTA_ACCOUNT` env var before running `prepare_agent_inputs.py`.

---

## orchestrate-agents.sh Options

`orchestrate-agents.sh` remains available for manual debugging/recovery, but it is
no longer the public authority behind `run-pipeline.sh --multi-agent`.

```
Usage: orchestrate-agents.sh <slug> [options]

Arguments:
  <slug>                Plugin slug (e.g. woocommerce)

Options:
  --parallel-limit N       Max agents running concurrently (default: 4)
  --timeout N              Timeout in seconds per agent (overrides dispatch config)
  --dispatch-file PATH     Path to dispatch config JSON
  --resume-missing-only    Skip agents whose valid output file already exists
  --help                   Show usage message

Environment variables:
  SKIP_QUOTA_PROBE=1       Skip both preflight probes (Codex + Claude).
                           Use only when quota/auth is confirmed healthy.
  CODEX_QUOTA_ACCOUNT      Codex account identifier logged in failures/ledger.
```

### Preflight probes

The orchestrator runs two preflight checks before launching agents:

| Probe | When active | What it checks |
|-------|-------------|----------------|
| **3a Codex** | Any pending agent has `provider=codex` | `codex exec` trivial prompt; catches quota exhaustion before first launch |
| **3b Claude** | Any pending agent has `provider=claude` | `claude` CLI on PATH + auth OK + model accessible; aborts on failure |

Both probes are skipped by `SKIP_QUOTA_PROBE=1`. Both use `cwd=$REPO_ROOT` and
share the same failure log format.

---

## Output Files

| File | Description |
|------|-------------|
| `reports/phase2/prep/<slug>/candidate-bundles/agent-wNN.input.json` | Bounded worker bundle with embedded IR/Semgrep/Psalm subset |
| `reports/phase2/prep/<slug>/candidate-inventory.json` | Candidate list + bundle plan emitted by prep |
| `reports/phase2/agents/<slug>/<agent>.output.json` | Canonical normalized output from each worker/support agent |
| `reports/phase2/agents/<slug>/attempts/<agent>.attempt-XX.output.json` | Attempt-local raw output used for safe retry promotion |
| `reports/phase2/agents/<slug>/attempts/<agent>.attempt-XX.normalized.json` | Attempt-local normalized output used for validation/promote decisions |
| `reports/phase2/agents/<slug>/<agent>.review.r1.json` | Bundle-local reviewer output |
| `reports/phase2/agents/<slug>/<agent>.revision.r1.json` | Bundle-local revision output |
| `reports/phase2/<slug>-phase2.merged.json` | Merged archive before cluster/consensus |
| `reports/phase2/<slug>-phase2.local.json` | Deterministic merge result before cluster/consensus stages |
| `reports/phase2/<slug>-phase2.state.json` | Phase-level runtime state and trust summary |
| `reports/phase2/<slug>-provider-policy.json` | Provider tier, trigger reasons, stage providers, and Phase 3 recommendation |
| `reports/phase2/<slug>-phase2.json` | Canonical Phase 2 output after consensus (gate reads this) |
| `reports/phase2/<slug>-cluster-plan.json` | Deterministic cross-bundle synthesis plan |
| `reports/phase2/<slug>-cluster-cNN.json` | Cluster artifact for later synth/challenge rounds |
| `reports/phase2/<slug>-cluster-cNN.input.json` | Compact JSON-first cluster input |
| `reports/phase2/<slug>-cluster-cNN.pack.json` | Evidence-pack-driven cluster artifact for synth/challenge |
| `reports/phase2/<slug>-cluster-cNN.synth.json` | Cluster synthesizer output (LLM, bounded to one cluster) |
| `reports/phase2/<slug>-cluster-cNN.challenge.json` | Cluster challenger output (LLM, bounded to one cluster) |
| `reports/phase2/<slug>-phase2.consensus.json` | Deterministic consensus artifact used to rewrite canonical Phase 2 |
| `reports/phase2/agents/<slug>/merge-ready` | Sentinel — written after successful merge |
| `reports/logs/<slug>/phase2/run.live.log` | Phase 2 envelope / coordinator progress |
| `reports/logs/<slug>/phase2/run.err` | Phase 2 envelope warnings/errors |
| `reports/logs/<slug>/phase2/chunked/run.live.log` | Chunked scheduler progress |
| `reports/logs/<slug>/phase2/chunked/run.err` | Chunked scheduler warnings/errors |
| `reports/logs/<slug>/phase2/chunked/failures.json` | Failure log (see FAILURE-MODES.md) |
| `reports/logs/<slug>/phase2/chunked/agents/<agent>/attempt-XX/assistant.live.log` | Parsed assistant stream for that attempt |
| `reports/logs/<slug>/phase2/chunked/agents/<agent>/attempt-XX/provider.raw.log` | Raw provider stream / stderr for that attempt |
| `reports/logs/<slug>/phase2/chunked/agents/<agent>/attempt-XX/stderr.err` | Provider stderr for that attempt |
| `reports/cost/<slug>/<run_id>.cost.json` | Per-run cost and token accountability summary |

---

## State and Trust

`reports/phase2/<slug>-phase2.state.json` is the phase-level runtime state file.

Important fields:
- `stage`
- `status`
- `role`
- `round`
- `provider`
- `model`
- `output_path`
- `errlog_path`
- `live_log_path`
- `trust_state`
- `details`

Current trust values:
- `success`
- `degraded_success`
- `partial_success`
- `failed`
- `in_progress` (runtime only)

Canonical publish rule:
- `reports/phase2/<slug>-phase2.local.json` is a deterministic local merge, not downstream truth.
- `reports/phase2/<slug>-phase2.json` becomes authoritative only after the consensus writer succeeds.
- Degraded runs surface `trust_state` and `degradation_signals` directly in the state file and consensus artifact.

---

## Claude Code Verify Step (Phase 2.9)

After orchestration completes and `<slug>-merge-ready` is written, Claude Code
may optionally review and correct the merged output:

```bash
cp reports/phase2/<slug>-phase2.json reports/phase2/<slug>-phase2-pre-verify.json  # backup
# Claude Code reviews and overwrites reports/phase2/<slug>-phase2.json
```

If verify fails or times out, the gate runs on the merged (unverified) output
from merge_agent_outputs.py. See `multi-agent-plan.md:439-444`.

**Note:** The Claude Code verify step (Session 21) is NOT part of this script.

---

## Parallel Limit Guidance

| Scenario | Recommended --parallel-limit |
|----------|-------------------------------|
| Normal quota | 4 (default) |
| High quota / fast run needed | 4–6 |
| Quota-limited / shared account | 1 |
| Single-agent debug | 1 |

**Why bounded-parallel by default:** worker bundles are now smaller, so 4-way
concurrency is a better baseline. For shared accounts or quota-sensitive runs,
drop back to `--parallel-limit 1`.

## Cluster Model Policy

Cluster stages are intentionally narrower than bundle review:

- `cluster synthesizer`: `gpt-5.4` by default
- `cluster challenger`: `claude-sonnet-4.6` by default
- `Claude Opus` is intentionally excluded from cluster-stage defaults

If a Claude model override for cluster stages contains `opus`, the deterministic
cluster builder clamps it back to `claude-sonnet-4.6`.

**Resuming after quota exhaustion:**
```bash
bash tools/bin/orchestrate-agents.sh <slug> --resume-missing-only
```
This skips any agent whose output file already exists and is valid JSON, then
runs the remaining agents serially.

---

## Monitoring

Watch orchestration progress in real time:

```bash
# Watch chunked scheduler progress
tail -f reports/logs/woocommerce/phase2/chunked/run.live.log

# Watch one worker assistant stream
tail -f reports/logs/woocommerce/phase2/chunked/agents/agent-w01/attempt-01/assistant.live.log

# Watch one raw provider stream
tail -f reports/logs/woocommerce/phase2/chunked/agents/agent-w01/attempt-01/provider.raw.log

# Check structured failures
cat reports/logs/woocommerce/phase2/chunked/failures.json | python3 -m json.tool

# Check current phase state
cat reports/phase2/woocommerce-phase2.state.json | python3 -m json.tool

# Check per-run cost accountability
python3 tools/bin/quota-report.py --run-id <run_id> --days 30
```

---

## See Also

- `docs/FAILURE-MODES.md` — How the orchestrator handles errors
- `7-workflow-wp/multi-agent-plan.md` — Architecture specification
- `tools/bin/prepare_agent_inputs.py` — Generates dispatch config + IR slices
- `tools/bin/merge_agent_outputs.py` — Merges agent outputs into local Phase 2 artifacts
