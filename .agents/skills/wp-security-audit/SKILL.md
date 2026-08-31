---
name: wp-security-audit
description: Source-first WordPress plugin security review methodology. Use for `/wp-security-audit <plugin>`, WordPress plugin audits, vulnerability tracing, exploitability assessment, and evidence-bound review without scanner-first bias.
---

# WordPress Security Audit

Invoke reliably with:

```text
/wp-security-audit <plugin-path-or-slug>
```

Treat the target parameter as one plugin path or slug plus optional scope constraints. Resolve a slug under `plugins/<slug>`. If the target is missing, ambiguous, or outside the intended workspace, ask before proceeding.

## Required active context

Read only these active references at the start:

- `../../../docs/wp-context.md`
- `../../../docs/review-methodology.md`
- `../../../AGENTS.md`

Do not load `wordpress-pattern-catalogue.md`, bounty rules, archived context, scanner reports, or legacy phase artifacts during initial discovery.

## Execution model — single agent, no pipeline

You perform the entire review yourself in one session. Do **not** spawn sub-agents, mappers, investigators, validators, Worker/Reviewer rounds, parallel workflows, or extra sessions, and do **not** run the legacy Phase 1/2/3 pipeline, cluster consensus, voting, or revisions. Those patterns add no evidence and only waste quota. If a single high-impact disputed trace needs an independent double-check, re-derive it from scratch inline yourself.

The method is a strict order: **self-parse first, then run the required tools, then reconcile, then adjudicate.**

## Default execution

1. Establish target, scope, constraints, available source/dependencies, and whether reportability is requested. Maintain authoritative state using lifecycle `DISCOVERING → TRACING → ADJUDICATING → COMPLETE`.
2. **Self-parse (no tools).** Read the plugin source and build your own IR/AST/SAST-style understanding by reasoning alone — file/load graph, every registration (hooks, REST, AJAX, shortcodes, cron, CLI) and resolved callback, data-flow edges, sinks, persistence read/write edges, and trust boundaries. Do not run any tool during this step. Seal this as the source-derived coverage ledger with stable `SURF-NNN` identifiers and a bounded trace queue of hypotheses (not vulnerabilities).
3. **Run the required tools.** Only after the self-parse is sealed, run the packaged read-only baseline, then optional corroboration when a concrete question exists:

   ```bash
   bash tools/bin/wp-audit-tools.sh inventory <plugin-path> [output-dir]
   bash tools/bin/wp-audit-tools.sh ast <plugin-path> [output-dir]
   bash tools/bin/wp-audit-tools.sh search <plugin-path> <pattern> [output-dir]
   bash tools/bin/wp-audit-tools.sh semgrep <plugin-path> [output-dir]
   bash tools/bin/wp-audit-tools.sh psalm <plugin-path> [output-dir]
   ```

4. **Reconcile — the difference is the signal.** Compare your own parse against the tool output. Every parser-only surface, source-only surface, parse gap, unresolved callback, and dynamic edge is an obligation re-opened in source. Parser absence is never negative evidence. Unresolved obligations block `COMPLETE`.
5. **Trace and refute.** First run a trust-boundary & intended-flow pass (`../../../docs/review-techniques.md` → "Pass 0"): a broken trust boundary is **not necessarily** IDOR/BOLA/BAC — it includes trusting unverified/unsigned data, a client header/value as authoritative, disabling a control, or violating a flow invariant (e.g. marked paid without paying). Then, using both your own parse and the tool results, run the five surface passes — trace each hypothesis `registration → callback → attacker control → propagation/storage → transformations → guards → sensitive operation → impact`, evaluate guards in exact WordPress/control-flow context, and attempt at least one concrete refutation per mature hypothesis. IR `auth_level: unknown` means UNAUDITED (read it), not low-priority; do not conclude "no finding/clean" for a surface class until every surface in it is read (work the `slice_ir.py` plan, don't cherry-pick); ground each finding's severity in least-privilege reachability.
6. **Adjudicate and report.** You own the verdict. Perform final refutation, evidence re-check, unified adjudication, and coverage reconciliation, then produce the machine-readable review matching `../../../contracts/methodology-review.schema.json` (golden example in `contracts/examples/`). Before claiming `COMPLETE`, run the enforcement checks and resolve anything they report — the gate is code, not honour system:

   ```bash
   python3 tools/bin/validate_review.py <review.json>              # must exit 0 (schema conformance)
   python3 tools/bin/complete_gate.py <review.json> --slug <slug>  # must exit 0 (reconciliation obligations)
   ```

   Persist to `reports/methodology/<slug>/` only if requested.

## Knowledge disclosure

After the source-led trace queue exists, read `../../../docs/wordpress-pattern-catalogue.md` only for a late coverage audit or a concrete unresolved question. New candidates from it must be traced from source like any other hypothesis.

Read `../../../docs/reportability-policy.md` and program rules only after technical verdicts are stable and the user requested reportability. Keep technical and policy conclusions strictly separated.

## Tool policy

Your own reading and reasoning is the source of every semantic conclusion; the self-parse in step 2 must precede any tool run. The Docker helper is required in-session support, not a pipeline: `inventory` and `ast` are mandatory coverage evidence, while `semgrep` and `psalm` are non-blocking corroboration. Semgrep runs Community-only — no Pro key/engine is provisioned, a known limitation; treat Pro-only rules as unavailable, never as negative evidence.

Before an optional `search`/`semgrep`/`psalm` run, record a concrete question, the static evidence gap your own parse could not close, the minimal command, and the expected evidence. Never run an `all`-analyzer command; none exists. Treat all tool output as independent, untrusted coverage evidence — never a finding source and never a verdict authority. The plugin mount is read-only.

Do not modify plugin source, install payloads, fuzz, brute force, send exploit traffic, or run destructive commands.

## Verdict and evidence contract

Use exactly one of:

- `CONFIRMED`: complete reachable evidence supports exploitability and concrete refutations failed.
- `UNCERTAIN`: a material code, dependency, configuration, or runtime fact remains unresolved.
- `RISK_NOTE`: a security-relevant weakness or hardening concern exists without a demonstrated exploitable path.
- `REJECTED`: evidence refutes the hypothesis, shows adequate protection, or does not support the claim.

Every mature conclusion requires exact `path:line` anchors, attacker prerequisites & role, ordered trace steps, defenses evaluated, concrete refutation attempts, impact & assumptions, and reopening conditions (for `UNCERTAIN`/`REJECTED`). Severity, confidence, exploitability, and reportability are independent fields.

## Final response structure

1. Target, scope, version assumptions, and constraints.
2. Architecture and trust boundaries.
3. Sealed source ledger summary.
4. Inventory/AST artifact references and structural reconciliation records.
5. Coverage ledger, resolved parser gaps, and unresolved material limitations.
6. Findings grouped by verdict.
7. Traces and refutations with exact `file:line` links.
8. Secure areas reviewed.
9. Optional reportability section (if requested).
10. Optional diagnostics performed, or `None`.
11. Explicit limitations (never claim the whole plugin is clean; describe reviewed scope).
</content>
