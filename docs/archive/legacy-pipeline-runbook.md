# Legacy Phase 1/2/3 pipeline runbook

> **Archived operational guide — non-default as of 2026-08-28.** This runbook exists only for historical reproduction and explicit corroboration. New audits must use `/wp-security-audit <plugin>` and must not preload these artifacts. The legacy pipeline is scanner/Worker/Reviewer/Phase-3 oriented, consumes substantially more provider quota, and uses different authority/contracts from the methodology workflow.

## Scope and safety

Run all commands from the repository root. Put targets under `plugins/<slug>/` unless an entrypoint accepts an explicit directory. The scripts write under `reports/`, `data/audit.db`, and logs; they are not read-only review primitives. Do not run them against the only copy of a target or treat their output as a current methodology verdict.

Before a historical run, record:

- repository commit and dirty state;
- target slug, source hash/version, and source location;
- PHP, Composer, Python, Semgrep, Psalm, Codex, and Claude versions;
- relevant environment/config overrides;
- selected providers/models and quota account;
- command line and start time.

## Host setup

This path intentionally preserves the old host-managed environment. The Docker helper is for bounded tools and does not replace the full multi-provider pipeline.

### PHP and Composer

Use PHP 8.3 with CLI support and the extensions required by the old toolchain, including DOM/SimpleXML, mbstring, SOAP, PDO, and SQLite. Verify the runtime before installing locked PHP dependencies:

```bash
php --version
php -m | grep -E 'dom|SimpleXML|mbstring|soap|PDO|pdo_sqlite'
cd tools && composer install && cd ..
```

Do not update `tools/composer.lock` merely to reproduce a run. `scan-all.sh` skips IR extraction when `tools/vendor/autoload.php` is absent.

### Python and Semgrep venv

The batch scripts default to `${PWD}/tmmc/bin/activate`. Create or restore a dedicated venv and select the exact Semgrep version associated with the historical run:

```bash
python3 -m venv tmmc
source tmmc/bin/activate
python3 -m pip install 'semgrep==<recorded-version>'
semgrep --version
```

For a venv elsewhere, export its activation path:

```bash
export SEMGREP_VENV=/absolute/path/to/venv/bin/activate
```

### Provider CLIs and authentication

Phase 2/3 may invoke Codex and/or Claude. Install and authenticate those CLIs outside the repository, then verify they are callable:

```bash
codex --version
claude --version
```

Never store API keys, session tokens, or credential files in this repository. Provider defaults may be loaded from `.claude/settings.json` or `.claude/settings.local.json`; CLI flags override operator environment/settings, which override tier recommendations and script defaults. Useful overrides include:

```bash
export CODEX_BIN=codex
export CLAUDE_BIN=claude
export CODEX_MODEL=<recorded-codex-model>
export CLAUDE_MODEL=<recorded-claude-model>
export CLAUDE_EFFORT=xhigh
```

Check the entrypoint's current `--help` before reproducing a dated run because provider options evolved with the legacy implementation.

## Command matrix

### Full single-plugin pipeline

Phase 1 → Phase 2 → Phase 3:

```bash
bash tools/bin/run-single-plugin.sh <slug>
bash tools/bin/run-single-plugin.sh --plugin-dir plugins/<slug>
```

Resume available artifacts and missing chunked bundles:

```bash
bash tools/bin/run-single-plugin.sh <slug> --resume
```

Force Phase 2/3 recomputation, or stop before Phase 3:

```bash
bash tools/bin/run-single-plugin.sh <slug> --force
bash tools/bin/run-single-plugin.sh <slug> --phase2-only
bash tools/bin/run-single-plugin.sh <slug> --force-deep --phase2-only
```

Examples of explicit provider behavior:

```bash
bash tools/bin/run-single-plugin.sh <slug> --provider codex
bash tools/bin/run-single-plugin.sh <slug> --providers codex,claude --primary-provider codex
bash tools/bin/run-single-plugin.sh <slug> --llm-mode off
```

`--resume-existing` is the lower-level Phase 2 resume mode. `--apply-review` enables the old Phase 3 feedback loop. Neither changes the fact that this is a legacy workflow.

### Phase 1 only

```bash
bash tools/bin/scan-all.sh plugins/<slug>/
```

Its fixed sequence is surface map → Semgrep → Psalm (non-blocking) → PHP IR/rules/SQLite → deterministic threat context. Individual failures can be logged while later steps continue; a zero exit alone does not prove every tool produced trustworthy output.

Semgrep-only parallel scan:

```bash
bash tools/bin/batch-scan-parallel.sh plugins 4
```

Legacy parallel Phase 1 batch with index range:

```bash
bash tools/bin/batch.sh plugins 4 1 100
```

The optional fifth positional argument `--clean` deletes prior Phase 1/2/3 reports and logs before the batch. Treat it as destructive and back up required artifacts first.

### Phase 2 only

One plugin:

```bash
bash tools/bin/run-phase2.sh --slug <slug>
bash tools/bin/run-phase2.sh --slug <slug> --resume
bash tools/bin/run-phase2.sh --slug <slug> --resume-existing
bash tools/bin/run-phase2.sh --slug <slug> --force --force-deep
```

Range/batch and interactive modes:

```bash
bash tools/bin/run-phase2.sh --start-index 1 --end-index 100 --threads 4
bash tools/bin/run-phase2.sh --interactive
```

Useful historical controls include `--clusters|--no-clusters`, `--cluster-limit`, `--max-review-rounds`, `--forced-exploration|--no-forced-exploration`, worker/reviewer provider/model options, and timeout options. These implement the retired Worker/Reviewer/cluster topology and are not equivalents of methodology sub-agents.

### Phase 3 only

One plugin with deterministic gate and conditional skeptic:

```bash
bash tools/bin/run-phase3.sh --slug <slug> --llm-mode auto
bash tools/bin/run-phase3.sh --slug <slug> --llm-mode off
bash tools/bin/run-phase3.sh --slug <slug> --llm-mode force --force
bash tools/bin/run-phase3.sh --slug <slug> --apply-review
```

Without a slug, `run-phase3.sh` enters its interactive index/thread batch flow. `--with-claude`, `--provider`, `--providers`, model flags, and `--primary-provider` select the old LLM skeptic behavior.

## Artifact layout and authority

Shared directories are defined by `tools/bin/report-paths.sh`:

```text
reports/phase1/   scanner, surface, Psalm, and IR artifacts
reports/context/  <slug>-threat-context.json
reports/phase2/   agent attempts, prep bundles, merge/consensus and canonical Phase 2
reports/phase3/   deterministic/LLM outputs and rendered reports
reports/cost/     per-run provider usage summaries
reports/logs/     phase/provider logs and quota-ledger.jsonl
data/audit.db     legacy SQLite extraction store
```

Common artifacts include:

```text
reports/phase1/<slug>-surface.txt
reports/phase1/<slug>-semgrep.json
reports/phase1/<slug>-psalm.sarif
reports/phase1/<slug>-ir.json
reports/context/<slug>-threat-context.json
reports/phase2/<slug>-phase2.local.json
reports/phase2/<slug>-phase2.consensus.json
reports/phase2/<slug>-phase2.json
reports/phase2/<slug>-phase2.state.json
reports/phase3/<slug>-phase3.json
reports/phase3/<slug>-phase3.final.json
```

Authority rules for historical interpretation:

1. Phase 1 outputs are evidence inputs, never findings by themselves. Missing/timeout Psalm or scanner output is a coverage limitation, not negative evidence.
2. `reports/phase2/<slug>-phase2.json` is canonical for the old Phase 3 gate only after authoritative publish. A file merely existing is insufficient.
3. Phase 2 is trusted only when its resolved `trust_state` is `success` and closure is not explicitly incomplete. Inspect state/consensus and provider logs before using it.
4. Resume/freshness logic is primarily mtime-based against direct inputs; it does not fingerprint the entire runtime, model, environment, ruleset, or provider behavior.
5. For Phase 3, prefer `<slug>-phase3.final.json` only when it exists and is not older than `<slug>-phase3.json`; otherwise use the gate artifact. A rendered Markdown report is authoritative only relative to the canonical JSON it was generated from.
6. Legacy `TP/FP/REVIEW` translations, Phase 3 scoring, and provider consensus do not override methodology verdicts. If used as corroboration, record the exact bounded question and re-open source evidence.

Useful integrity checks:

```bash
python3 -m json.tool reports/phase1/<slug>-ir.json >/dev/null
python3 -m json.tool reports/phase2/<slug>-phase2.json >/dev/null
python3 -m json.tool reports/phase3/<slug>-phase3.json >/dev/null
python3 tools/bin/artifact_freshness.py phase2-trust-state --path reports/phase2/<slug>-phase2.json
python3 tools/bin/artifact_freshness.py phase2-is-trusted --path reports/phase2/<slug>-phase2.json
python3 tools/bin/artifact_freshness.py canonical-phase3 --phase3-dir reports/phase3 --slug <slug>
```

## Resume, reset, and cleanup

Prefer `--resume` when preserving provenance. Use `--force` only after recording why cached/fresh artifacts must be replaced. Do not manually mix artifacts from different source hashes, commits, provider/model settings, or rule versions under the same slug.

For a clean historical rerun, archive the entire relevant slug set first (Phase 1, context, Phase 2 prep/agents/state/canonical, Phase 3, costs, logs, and database provenance). Then remove only the selected slug's artifacts after reviewing paths. The legacy `batch.sh ... --clean` performs broad recursive deletion across Phase 1/2/3/log directories and is not the preferred selective reset.

Never delete `plugins/<slug>/` as part of report cleanup. Never copy legacy output into `reports/methodology/<slug>/`; keep legacy/scanner evidence separate so it cannot silently become methodology authority.

## Troubleshooting order

1. Confirm target path and expected slug.
2. Read `reports/logs/<slug>/` before rerunning.
3. Validate JSON syntax and Phase 2 trust/closure state.
4. Compare artifact mtimes with source/config/rule inputs.
5. Confirm provider authentication, model names, timeout, and quota ledger.
6. Re-run the smallest failed phase or use `--resume`; avoid a forced full pipeline unless historical reproduction specifically requires it.
