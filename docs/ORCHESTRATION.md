# ORCHESTRATION.md — Multi-Agent Phase 2 Pipeline

> Source authority: `7-workflow-wp/multi-agent-plan.md:400-520`
> This document describes how to run the multi-agent Phase 2 pipeline.

---

## Overview

The multi-agent pipeline distributes Phase 2 (LLM triage) across several agents,
each responsible for a subset of entry-point groups (e.g., AJAX-unauth, AJAX-auth,
shortcodes, REST, other). Provider is configurable per agent (Codex CLI or Claude
Code CLI). Outputs are merged by `merge_agent_outputs.py` and then consumed by
the Phase 3 gate.

```
prepare_agent_inputs.py
        ↓
  <slug>-dispatch.json           (dispatch config, written by prep step)
        ↓
orchestrate-agents.sh <slug>
        ↓
  agent-a1 [codex exec]  ─┐
  agent-a2 [codex exec]   │  (serial by default; --parallel-limit N to increase)
  agent-b  [codex exec]   │  (provider per-agent from dispatch provider_map)
  agent-c  [claude -p]   ─┘
        ↓
  <slug>-agent-*.json           (one file per agent, in reports/)
        ↓
merge_agent_outputs.py <slug>
        ↓
  reports/phase2/<slug>-phase2-merged.json     (archive)
  reports/phase2/<slug>-phase2.json            (canonical — gate reads this)
        ↓
  <slug>-merge-ready            (sentinel, written by orchestrator)
        ↓
run-phase3.sh --slug <slug>
```

---

## Prerequisites

1. Phase 1 scan complete: `reports/<slug>-ir.json` exists.
2. Agent inputs prepared: `python3 tools/bin/prepare_agent_inputs.py <slug>`
   - Produces `reports/<slug>-dispatch.json`
   - Produces `reports/<slug>-ir-slice-*.json` per agent group
3. Codex CLI available in `$PATH`.

---

## Running the Pipeline

### Automation Mode (recommended)

```bash
bash tools/bin/run-pipeline.sh <slug> --multi-agent
```

This runs all phases end-to-end:
Phase 1 → Prep → Orchestrate → Merge → Gate → Report

### Manual Mode (quota-controlled)

**Step 1: Phase 1 scan**
```bash
bash tools/bin/scan-all.sh plugins/<slug>/
```

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
  "agents": ["agent-a1", "agent-a2", "agent-b", "agent-c", "agent-d"],
  "inputs": {
    "agent-a1": "reports/<slug>-ir-slice-ajax-unauth.json",
    "agent-a2": "reports/<slug>-ir-slice-ajax-auth.json",
    "agent-b":  "reports/<slug>-ir.json",
    "agent-c":  "reports/<slug>-ir.json",
    "agent-d":  "reports/<slug>-ir.json"
  },
  "source_dir": "plugins/<slug>/",
  "timeout_seconds": 600,
  "quota_account": "",
  "provider_map": {
    "agent-c": "claude",
    "agent-d": "claude"
  },
  "default_provider": "codex",
  "model_map": {
    "agent-c": "claude-sonnet-4-5",
    "agent-d": "claude-sonnet-4-5"
  }
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
  --parallel-limit N       Max agents running concurrently (default: 1, serial)
  --timeout N              Timeout in seconds per agent (overrides dispatch config)
  --dispatch-file PATH     Path to dispatch config JSON
  --resume-missing-only    Skip agents whose valid output file already exists
  --help                   Show usage message
```

---

## Output Files

| File | Description |
|------|-------------|
| `reports/<slug>-agent-{id}.json` | Raw output from each agent |
| `reports/phase2/<slug>-phase2-merged.json` | Merged archive (pre-verify) |
| `reports/phase2/<slug>-phase2.json` | Canonical Phase 2 output (gate reads this) |
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
| Normal quota | 1 (default, serial) |
| High quota / fast run needed | 2–4 |
| Quota-limited / shared account | 1 |
| Single-agent debug | 1 |

**Why serial-by-default:** Codex quota is metered per request. Running agents in
parallel risks exhausting quota mid-run, leaving partial output that must be
resumed. Use `--parallel-limit 2` or higher only when quota is confirmed available.

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

# Watch a specific agent log
tail -f reports/logs/woocommerce-agent-a1.log

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
