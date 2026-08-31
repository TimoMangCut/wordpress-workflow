---
name: wp-security-audit
description: Source-first WordPress plugin security review methodology. Use for `/wp-security-audit <plugin>`, WordPress plugin audits, vulnerability tracing, exploitability assessment, and evidence-bound review without scanner-first bias.
---

# WordPress Security Audit

Invoke reliably with:

```text
/wp-security-audit <plugin-path-or-slug>
```

Treat `$ARGUMENTS` as one plugin path or slug plus optional scope constraints. Resolve a slug under `plugins/<slug>`. If the target is missing, ambiguous, or outside the intended workspace, ask before proceeding.

## Required active context

Read only these active references at the start:

- `../../../docs/wp-context.md`
- `../../../docs/review-methodology.md`
- `../../../AGENTS.md`

Do not load `wordpress-pattern-catalogue.md`, bounty rules, archived context, scanner reports, or legacy phase artifacts during initial discovery.

## Execution model — single agent, no pipeline

You perform the entire review yourself in this one session. Do **not** spawn Worker/Reviewer sub-agents, mappers, investigators, validators, parallel agents, or extra sessions, and do **not** run the legacy Phase 1/2/3 pipeline, cluster consensus, voting, or revisions. Those patterns add no evidence and only waste quota. If a single high-impact disputed trace needs an independent double-check, re-derive it from scratch inline yourself.

The method is a strict order: **self-parse first, then run the required tools, then reconcile, then adjudicate.**

## Default execution

1. Establish target, scope, constraints, available source/dependencies, and whether reportability is requested. Maintain authoritative state using lifecycle `DISCOVERING → TRACING → ADJUDICATING → COMPLETE`.
2. **Self-parse (no tools).** Read the plugin source and build your own IR/AST/SAST-style understanding by reasoning alone — file/load graph, every registration (hooks, REST, AJAX, shortcodes, cron, CLI) and resolved callback, data-flow edges, sinks, persistence read/write edges, and trust boundaries. Do not run any tool during this step. Seal this as the source-derived coverage ledger and a bounded trace queue of hypotheses (not vulnerabilities).
3. **Run the required tools.** Only after the self-parse is sealed, run the packaged read-only baseline, then optional corroboration when a concrete question exists:

   ```bash
   bash tools/bin/wp-audit-tools.sh inventory <plugin-path> [output-dir]
   bash tools/bin/wp-audit-tools.sh ast <plugin-path> [output-dir]
   bash tools/bin/wp-audit-tools.sh search <plugin-path> <pattern> [output-dir]
   bash tools/bin/wp-audit-tools.sh semgrep <plugin-path> [output-dir]
   bash tools/bin/wp-audit-tools.sh psalm <plugin-path> [output-dir]
   ```

4. **Reconcile — the difference is the signal.** Compare your own parse against the tool output. Every parser-only surface, source-only surface, parse gap, unresolved callback, and dynamic edge is an obligation re-opened in source. Parser absence is never negative evidence. Unresolved obligations block `COMPLETE`.
5. **Trace and refute.** Using both your own parse and the tool results, trace each hypothesis `registration → callback → attacker control → propagation/storage → transformations → guards → sensitive operation → impact`, and attempt at least one concrete refutation per mature hypothesis.
6. **Adjudicate and report.** You own the verdict. Perform final refutation, evidence re-check, unified adjudication, and coverage reconciliation, then return one unified review. Persist a JSON/Markdown report only if requested or needed for resume.

## Knowledge disclosure

During the tracing passes (step 5) or a late recall/precision audit, consult `../../../docs/review-techniques.md` — the single-agent technique catalogue: the five analysis passes, recall blind spots, guard three-state discipline, anti-hallucination anchoring, threat-profile weighting, and large-target chunking for one agent.

After the source-led trace queue exists, read `../../../docs/wordpress-pattern-catalogue.md` only for a late coverage audit or a concrete unresolved question. New candidates from it must be traced from source like any other hypothesis.

Read `../../../docs/reportability-policy.md` and program rules only after technical verdicts are stable and the user requested reportability. Keep technical and policy conclusions separate.

## Tool policy

Your own reading and reasoning is the source of every semantic conclusion; the self-parse in step 2 must precede any tool run. The Docker helper is required in-session support, not a pipeline: `inventory` and `ast` are mandatory coverage evidence, while `semgrep` and `psalm` are non-blocking corroboration. Semgrep runs Community-only — no Pro key/engine is provisioned, a known limitation; treat Pro-only rules as unavailable, never as negative evidence.

Before an optional `search`/`semgrep`/`psalm` run, record a concrete question, the static evidence gap your own parse could not close, the minimal command, and the expected evidence. Never run an `all`-analyzer command; none exists. Treat all tool output as independent, untrusted coverage evidence — never a finding source and never a verdict authority. The plugin mount is read-only.

Do not modify plugin source, install payloads, fuzz, brute force, send exploit traffic, or run destructive commands. Request approval before any diagnostic that could mutate persistent state.

## Verdict and evidence contract

Use exactly one of:

- `CONFIRMED`
- `UNCERTAIN`
- `RISK_NOTE`
- `REJECTED`

Every mature conclusion requires exact `path:line` anchors and at least one concrete refutation attempt. A confirmed issue requires a reachable path, attacker control, ineffective or absent defenses, supported impact, and no unresolved material link.

Severity, confidence, exploitability, and reportability are independent fields. Follow `../../../contracts/methodology-review.schema.json` when producing machine-readable output.

## Final response

Report target/scope, architecture and trust boundaries, sealed source-ledger summary, inventory/AST artifact references, structural reconciliation records, coverage ledger, findings by verdict, traces and refutations, secure areas reviewed, unresolved gaps, optional diagnostics performed, and explicit limitations. Never claim the whole plugin is clean; describe the reviewed scope.
</content>
