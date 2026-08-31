# Workflow Guide — Methodology-First Review

## Canonical workflow

The canonical entrypoint is a Kiro workspace skill:

```text
/wp-security-audit <plugin-path-or-slug>
```

Start a new Kiro session after pulling or changing `.kiro/skills/` so the skill is discovered. A slug resolves under `plugins/<slug>`; an explicit path may also be used.

The review is source-first and has one lifecycle:

```text
DISCOVERING → TRACING → ADJUDICATING → COMPLETE
```

There is no required Phase 1 scan, Worker/Reviewer loop, cluster consensus, or separate Phase 3. The main IDE agent owns authoritative state and final verdicts.

## Agent execution

Default economical sequence:

1. Main agent establishes scope and active semantics.
2. `wp-surface-mapper` maps source-led surfaces without machine artifacts.
3. Main agent seals the source ledger, runs read-only inventory + AST/IR extraction, and reconciles every structural discrepancy or parser gap in source.
4. Main agent finalizes a bounded, reconciled trace queue and delegates it to `wp-trace-investigator`.
5. Investigator traces source, transformations, guards, sinks, impact, and refutations.
6. Main agent re-opens evidence, adjudicates, verifies that no structural obligation remains open, and reports.

`wp-evidence-validator` is optional. Invoke it only when the user requests independent validation or a high-impact claim has a concrete unresolved contradiction. Do not create repeated review rounds, voting, parallel fan-out, or recursive sub-agents.

For small plugins, the main agent may map and trace directly when delegation would cost more context than it saves.

## Context loading

Initial active context:

- `docs/wp-context.md`
- `docs/review-methodology.md`
- `AGENTS.md`

Progressive disclosure:

- `docs/wordpress-pattern-catalogue.md`: late coverage audit or a concrete question only;
- `docs/reportability-policy.md`: after technical verdicts, only when submission triage is requested;
- `docs/archive/wp-context-full-legacy.md`: historical research only;
- scanner/phase artifacts: bounded corroboration only, never initial agenda.

## Verdicts

Use one vocabulary throughout:

- `CONFIRMED`
- `UNCERTAIN`
- `RISK_NOTE`
- `REJECTED`

Each mature issue requires a reachable trace, exact `path:line` evidence, attacker prerequisites, defenses considered, at least one refutation attempt, impact, severity, confidence, and explicit missing evidence/reopening conditions where relevant.

Technical exploitability is separate from reportability. The machine-readable contract is `contracts/methodology-review.schema.json`.

## Structural Docker baseline and optional diagnostics

The image packages PHP 8.3, Composer-locked AST/Psalm dependencies, Semgrep, ripgrep, and required PHP extensions. Build once:

```bash
bash tools/bin/wp-audit-tools.sh build
bash tools/bin/wp-audit-tools.sh versions
```

After the source-derived ledger is sealed, run the required read-only baseline:

```bash
bash tools/bin/wp-audit-tools.sh inventory <plugin-path> [output-dir]
bash tools/bin/wp-audit-tools.sh ast <plugin-path> [output-dir]
```

Reconcile inventory/IR with the source ledger. Re-open parser-only/source-only surfaces, parse gaps, and unresolved dynamic edges in source before `COMPLETE`.

Optional diagnostics require a concrete question and static evidence gap:

```bash
bash tools/bin/wp-audit-tools.sh search <plugin-path> <pattern> [output-dir]
bash tools/bin/wp-audit-tools.sh semgrep <plugin-path> [output-dir]
bash tools/bin/wp-audit-tools.sh psalm <plugin-path> [output-dir]
```

The wrapper mounts plugin source read-only and writes to `reports/tooling/<slug>/` by default. No `all` command exists. AST is required coverage evidence but not a verdict authority. Semgrep and Psalm are optional, non-blocking corroboration.

### Direct Docker form

```bash
docker build -f tools/docker/Dockerfile -t wp-audit-tools:local .
mkdir -p "$PWD/reports/tooling/<slug>"
docker run --rm --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=1g,mode=1777 \
  --tmpfs /opt/wp-audit/reports:rw,noexec,nosuid,size=1g,mode=1777 \
  --tmpfs /opt/wp-audit/data:rw,noexec,nosuid,size=256m,mode=1777 \
  --user "$(id -u):$(id -g)" \
  --mount type=bind,src="$PWD/plugins/<slug>",dst=/workspace/plugin,readonly \
  --mount type=bind,src="$PWD/reports/tooling/<slug>",dst=/workspace/output \
  wp-audit-tools:local inventory
```

Semgrep is installed at an exact image build version. Override it explicitly when rebuilding:

```bash
docker build --build-arg SEMGREP_VERSION=<exact-version> \
  -f tools/docker/Dockerfile -t wp-audit-tools:local .
```

The image uses community Semgrep by default; it does not embed credentials or require Semgrep Pro. No Codex/Claude/Kiro credentials are copied into the image.

## Output

The default response is returned in the IDE session. If persistence or resume is requested, write Markdown and/or JSON under:

```text
reports/methodology/<slug>/
```

Machine-readable output should validate against `contracts/methodology-review.schema.json`. Tool artifacts remain separate under `reports/tooling/<slug>/`.

## Legacy Phase pipeline

The former canonical scripts remain available but are now legacy/explicit paths:

```bash
bash tools/bin/run-single-plugin.sh <slug>
bash tools/bin/scan-all.sh plugins/<slug>/
bash tools/bin/run-phase2.sh --slug <slug>
bash tools/bin/run-phase3.sh --slug <slug> --llm-mode auto
```

They preserve historical Phase 1/2/3 behavior and artifacts. Do not invoke them from the methodology skill unless the user explicitly requests legacy reproduction. Their Worker/Reviewer/cluster/provider configuration and old `phase2.json`/`phase3.json` contracts are not part of the new review authority.

The archived [legacy pipeline runbook](docs/archive/legacy-pipeline-runbook.md) preserves host setup, provider configuration, single/batch/resume/force commands, artifact authority, trust/freshness semantics, report paths, and cleanup guidance. Prefer the Docker helper for bounded tooling rather than installing dependencies into the IDE host.
