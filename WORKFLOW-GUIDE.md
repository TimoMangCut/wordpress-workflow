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

There is no required Phase 1 scan, Worker/Reviewer loop, cluster consensus, or separate Phase 3, and no sub-agent delegation. One IDE model owns authoritative state and the final verdict, and does the entire review itself.

## Single-agent execution

One model performs the whole review in one session:

1. Establish scope and active semantics.
2. **Self-parse (no tools):** the model reads the source and builds its own IR/AST/SAST-style map — surfaces, registrations, resolved callbacks, data-flow, sinks, persistence, trust boundaries — by reasoning alone, then seals the source ledger.
3. **Run the required tools:** the same model runs read-only inventory + AST/IR extraction (and corroborating Semgrep/Psalm as needed) and reconciles every structural discrepancy or parser gap against source.
4. **Trace and refute:** the same model finalizes a bounded, reconciled trace queue and traces source → transformations → guards → sinks → impact, with explicit refutations.
5. **Adjudicate:** the same model re-opens evidence, assigns one verdict, verifies no structural obligation remains open, and reports.

Do not spawn mappers, investigators, validators, or any Worker/Reviewer sub-agents; do not use repeated review rounds, voting, parallel fan-out, or recursive delegation. Extra sub-agents and sessions only waste quota without adding evidence. If a single high-impact disputed trace needs an independent double-check, the same model re-derives it from scratch inline rather than delegating.

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
