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
Provider is configurable per agent (Codex CLI or Claude Code CLI). Outputs are
merged by `merge_agent_outputs.py`, refined through deterministic cluster/consensus
stages, and then consumed by the Phase 3 gate.

```
prepare_agent_inputs.py
        ↓
  <slug>-dispatch.json           (dispatch config, written by prep step)
        ↓
orchestrate-agents.sh <slug>
        ↓
  agent-w01 [claude -p] ─┐
  agent-w02 [claude -p]  │  (default: 4-way concurrency; tune with --parallel-limit)
  agent-b   [codex exec] │  (provider per-agent from dispatch provider_map)
  agent-c   [claude -p] ─┘
        ↓
  <slug>-agent-*.json           (one file per agent, in reports/)
        ↓
merge_agent_outputs.py <slug>
        ↓
  reports/<slug>-phase2-merged.json         (archive, top-level reports/)
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
   - Produces `reports/<slug>-dispatch.json`
   - Produces `reports/<slug>-candidate-bundle-agent-wNN.json` per worker bundle
   - Also produces `reports/<slug>-ir-slice-*.json` per legacy EP group
3. Threat context available: `reports/<slug>-threat-context.json`
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
```

For a specific slug, this runs:
Phase 1 → Threat Context → Prep → Orchestrate → Merge → Gate → Report

If you omit `<slug>`, multi-agent mode uses existing `reports/phase1/*-ir.json`
artifacts, refreshes threat context per slug when plugin source is present,
and runs Prep → Orchestrate → Merge → Gate → Report for each slug.

### Manual Mode (quota-controlled)

**Step 1: Phase 1 scan**
```bash
bash tools/bin/scan-all.sh plugins/<slug>/
```

This also generates `reports/<slug>-threat-context.json` when fresh output is not already available.

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

**Step 4: Verify merge output**
```bash
cat reports/phase2/<slug>-phase2.json | python3 -m json.tool > /dev/null && echo "Valid"
```

**Step 5: Gate + Report**
```bash
bash tools/bin/run-phase3.sh --slug <slug>
```

---

## Dispatch Config Format

`reports/<slug>-dispatch.json`:

```json
{
  "slug": "plugin-name",
  "strategy": "candidate_chunk_v2",
  "agents": ["agent-w01", "agent-w02", "agent-b", "agent-c", "agent-d"],
  "inputs": {
    "agent-w01": "reports/<slug>-candidate-bundle-agent-w01.json",
    "agent-w02": "reports/<slug>-candidate-bundle-agent-w02.json",
    "agent-b":  "reports/phase1/<slug>-ir.json",
    "agent-c":  "reports/phase1/<slug>-ir.json",
    "agent-d":  "reports/phase1/<slug>-ir.json"
  },
  "source_dir": "plugins/<slug>/",
  "threat_context_path": "reports/<slug>-threat-context.json",
  "timeout_seconds": 600,
  "quota_account": "",
  "provider_map": {
    "agent-w01": "claude",
    "agent-w02": "claude"
  },
  "default_provider": "codex",
  "model_map": {
    "agent-w01": "claude-sonnet-4.6",
    "agent-w02": "claude-sonnet-4.6"
  },
  "bundle_inventory": "reports/<slug>-candidate-inventory.json"
  "bundle_review_enabled": true,
  "reviewer_provider": "codex",
  "reviewer_model": "gpt-5.4",
  "review_rounds": 1,
  "cluster_synth_provider": "codex",
  "cluster_synth_model": "gpt-5.4",
  "cluster_challenger_provider": "claude",
  "cluster_challenger_model": "claude-sonnet-4.6"
}
```

**Provider routing:**
- `default_provider`: used for any agent not listed in `provider_map`. Values: `"codex"` (Codex CLI) | `"claude"` (Claude Code CLI).
- `provider_map`: per-agent override. Leave empty (`{}`) to use `default_provider` for all agents.
- `model_map`: optional per-agent model pin (only meaningful when provider is `"claude"`). If omitted for an agent, the Claude CLI's current default model is used. Recommended: set explicitly for reproducibility.
- `quota_account`: optional string to tag which Codex account was used (for traceability across quota exhaustion events). Set via `CODEX_QUOTA_ACCOUNT` env var before running `prepare_agent_inputs.py`.

---

## orchestrate-agents.sh Options

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
| `reports/<slug>-candidate-bundle-agent-wNN.json` | Bounded worker bundle with embedded IR/Semgrep/Psalm subset |
| `reports/<slug>-candidate-inventory.json` | Candidate list + bundle plan emitted by prep |
| `reports/<slug>-agent-{id}.json` | Raw output from each agent |
| `reports/<slug>-phase2-merged.json` | Merged archive (pre-verify, top-level reports/) |
| `reports/phase2/<slug>-phase2.local.json` | Deterministic merge result before cluster/consensus stages |
| `reports/phase2/<slug>-phase2.json` | Canonical Phase 2 output after consensus (gate reads this) |
| `reports/phase2/<slug>-cluster-plan.json` | Deterministic cross-bundle synthesis plan |
| `reports/phase2/<slug>-cluster-cNN.json` | Cluster artifact for later synth/challenge rounds |
| `reports/phase2/<slug>-cluster-cNN.input.json` | Compact JSON-first cluster input |
| `reports/phase2/<slug>-cluster-cNN.pack.json` | Evidence-pack-driven cluster artifact for synth/challenge |
| `reports/phase2/<slug>-cluster-cNN.synth.json` | Cluster synthesizer output (LLM, bounded to one cluster) |
| `reports/phase2/<slug>-cluster-cNN.challenge.json` | Cluster challenger output (LLM, bounded to one cluster) |
| `reports/phase2/<slug>-phase2.consensus.json` | Deterministic consensus artifact used to rewrite canonical Phase 2 |
| `reports/<slug>-merge-ready` | Sentinel — written after successful merge |
| `reports/logs/<slug>-failures.json` | Failure log (see FAILURE-MODES.md) |
| `reports/logs/<slug>-agent-{id}.log` | Per-agent stderr log |

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
# Watch orchestrator log (stdout)
bash tools/bin/orchestrate-agents.sh woocommerce 2>&1 | tee /tmp/orch-woocommerce.log

# Watch a specific worker log
tail -f reports/logs/woocommerce-agent-w01.log

# Check which output files have arrived
ls -la reports/woocommerce-agent-*.json

# Check merge-ready sentinel
ls -la reports/woocommerce-merge-ready
```

---

## See Also

- `docs/FAILURE-MODES.md` — How the orchestrator handles errors
- `7-workflow-wp/multi-agent-plan.md` — Architecture specification
- `tools/bin/prepare_agent_inputs.py` — Generates dispatch config + IR slices
- `tools/bin/merge_agent_outputs.py` — Merges agent outputs into Phase 2 canonical
