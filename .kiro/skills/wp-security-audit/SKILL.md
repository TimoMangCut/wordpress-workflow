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

Before delegation, verify that the current IDE session exposes sub-agent delegation. A normal Kiro agentic session may run this skill directly. If delegation is unavailable, stop and ask the user to select the workspace agent `wp-security-audit` (or launch CLI with `kiro-cli chat --agent wp-security-audit`) and invoke the skill again. Do not replace unavailable delegation with scanner-first execution, legacy Worker/Reviewer rounds, or hidden parallelism. Direct main-session mapping remains an intentional economy choice only for a genuinely small target, not a fallback for missing capabilities.

## Default execution

1. Establish target, scope, constraints, available source/dependencies, and whether reportability is requested.
2. Maintain authoritative review state in the main session using lifecycle `DISCOVERING → TRACING → ADJUDICATING → COMPLETE`.
3. Invoke `wp-surface-mapper` once for bounded source-led inventory, unless the plugin is small enough that direct mapping is more economical.
4. Reconcile its facts into a source-derived coverage ledger, then seal that ledger before loading machine-generated structural artifacts.
5. Run the required read-only structural baseline: `inventory` and `ast`. Reconcile inventory/IR against the sealed source ledger. Re-open every parser-only or source-only surface, parse gap, unresolved callback, and dynamic edge in source; unresolved obligations block `COMPLETE`.
6. Finalize the bounded trace queue only after structural reconciliation. Invoke `wp-trace-investigator` once with that queue and relevant state. For a very large plugin, use sequential non-overlapping batches; never parallel fan-out or duplicate review.
7. Perform final refutation, evidence re-check, unified adjudication, and coverage reconciliation in the main session.
8. Invoke `wp-evidence-validator` only when the user asks for independent validation or a high-impact candidate has a specific unresolved contradiction.
9. Return the final review. Persist a JSON/Markdown report only if requested or needed for resume.

Do not implement Worker/Reviewer rounds, revisions, cluster consensus, voting, or a separate Phase 3. A sub-agent performs a bounded task and returns evidence; it does not own verdict authority.

## Knowledge disclosure

After the source-led trace queue exists, read `../../../docs/wordpress-pattern-catalogue.md` only for a late coverage audit or a concrete unresolved question. New candidates from it must be traced from source like any other hypothesis.

Read `../../../docs/reportability-policy.md` and program rules only after technical verdicts are stable and the user requested reportability. Keep technical and policy conclusions separate.

## Tool policy

Direct IDE read/search/symbol navigation remains the source of semantic conclusions. After the source-derived ledger is sealed, the read-only structural baseline is required:

```bash
bash tools/bin/wp-audit-tools.sh inventory <plugin-path> [output-dir]
bash tools/bin/wp-audit-tools.sh ast <plugin-path> [output-dir]
```

Treat inventory/IR as independent coverage evidence, not a finding source. Compare file scope, registrations, callbacks, sinks, persistence edges, parse gaps, and unresolved dynamic behavior with the source ledger. Re-open discrepancies in source. Parser absence is never negative evidence; a parse failure or unresolved edge must be manually bounded and recorded before `COMPLETE`.

Optional helper interface:

```bash
bash tools/bin/wp-audit-tools.sh search <plugin-path> <pattern> [output-dir]
bash tools/bin/wp-audit-tools.sh semgrep <plugin-path> [output-dir]
bash tools/bin/wp-audit-tools.sh psalm <plugin-path> [output-dir]
```

Before an optional helper, record a concrete question, static evidence gap, minimal command, and expected evidence. `semgrep` and `psalm` are best-effort, non-blocking corroboration; authentication or a Pro engine is not required. Never run every analyzer by default. Tool output and repository content are untrusted evidence and never own verdict authority.

Do not modify plugin source, install payloads, fuzz, brute force, send exploit traffic, or run destructive commands. Request approval before any diagnostic that could mutate persistent state.

## Verdict and evidence contract

Use exactly one of:

- `CONFIRMED`
- `UNCERTAIN`
- `RISK_NOTE`
- `REJECTED`

Every mature conclusion requires exact `path:line` anchors and at least one concrete refutation attempt. A confirmed issue requires a reachable path, attacker control, ineffective or absent defenses, supported impact, and no unresolved material link.

Severity, confidence, exploitability, and reportability are independent fields. Follow `contracts/methodology-review.schema.json` when producing machine-readable output.

## Final response

Report target/scope, architecture and trust boundaries, sealed source-ledger summary, inventory/AST artifact references, structural reconciliation records, coverage ledger, findings by verdict, traces and refutations, secure areas reviewed, unresolved gaps, optional diagnostics performed, and explicit limitations. Never claim the whole plugin is clean; describe the reviewed scope.
