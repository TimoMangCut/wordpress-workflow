---
name: wp-security-audit
description: Source-first WordPress plugin security review methodology for Antigravity. Use for `/wp-security-audit <plugin>`, WordPress plugin audits, vulnerability tracing, exploitability assessment, and evidence-bound review without scanner-first bias.
---

# WordPress Security Audit

Invoke reliably with:

```text
/wp-security-audit <plugin-path-or-slug>
```

Treat target parameter as one plugin path or slug plus optional scope constraints. Resolve a slug under `plugins/<slug>`. If the target is missing, ambiguous, or outside the intended workspace, ask before proceeding.

## Required active context

Read only these active references at the start:

- [docs/wp-context.md](file:///Users/dophuc/Desktop/Pentest/Wordpress/wordpress-workflow/docs/wp-context.md)
- [docs/review-methodology.md](file:///Users/dophuc/Desktop/Pentest/Wordpress/wordpress-workflow/docs/review-methodology.md)
- [AGENTS.md](file:///Users/dophuc/Desktop/Pentest/Wordpress/wordpress-workflow/AGENTS.md)

Do not load `wordpress-pattern-catalogue.md`, bounty rules, archived context, scanner reports, or legacy phase artifacts during initial discovery.

## Review Architecture & Sub-Agents / Phases

Antigravity operates in a single pair-programming agent session or coordinates specialized subagents/workflows. The review follows an economical, source-first sequence:

1. **Target & Scope**: Establish target, scope, constraints, available source/dependencies, and whether reportability is requested.
2. **Authoritative State**: Maintain authoritative review state in the main session using lifecycle `DISCOVERING → TRACING → ADJUDICATING → COMPLETE`.
3. **Surface Mapping**:
   - **Direct / Subagent Mapping**: Map plugin architecture, entry points, hooks (`wp_ajax_*`, `admin_post_*`, REST routes, shortcodes, cron, filters/actions), persistence, and trust boundaries.
   - Construct a source-derived coverage ledger and assign stable `SURF-NNN` identifiers.
   - Seal the source ledger before loading machine-generated structural artifacts.
4. **Structural Baseline (Required)**:
   - Run read-only AST/IR and inventory baseline via Docker/tooling:
     ```bash
     bash tools/bin/wp-audit-tools.sh inventory <plugin-path> [output-dir]
     bash tools/bin/wp-audit-tools.sh ast <plugin-path> [output-dir]
     ```
   - Reconcile inventory/IR against the sealed source ledger. Re-open every parser-only or source-only surface, parse gap, unresolved callback, and dynamic edge in source; unresolved obligations block `COMPLETE`.
5. **Trace Queue & Investigation**:
   - Finalize the bounded trace queue only after structural reconciliation. Entries in the queue are investigative hypotheses, not confirmed vulnerabilities.
   - Trace complete data flow: `registration → callback → attacker control → propagation/storage → transformations → guards → sensitive operation → impact`.
   - Evaluate guards in exact WordPress/control-flow context.
   - Formulate concrete refutations for each candidate.
6. **Adjudication & Refutation**:
   - Main session performs final refutations, evidence re-checks, unified adjudication, and coverage reconciliation.
   - If an independent escalation / double-check is needed for a high-impact disputed trace, run an explicit evidence validation step.
7. **Final Review & Report**:
   - Output structured review matching `contracts/methodology-review.schema.json`.
   - Persist report to `reports/methodology/<slug>/` if requested.

Do not implement Worker/Reviewer rounds, revisions, cluster consensus, voting, or a separate Phase 3. The main agent owns verdict authority.

## Knowledge disclosure

- Consult [docs/wordpress-pattern-catalogue.md](file:///Users/dophuc/Desktop/Pentest/Wordpress/wordpress-workflow/docs/wordpress-pattern-catalogue.md) only after the source-led trace queue exists, or for a late coverage audit/concrete unresolved question.
- Consult [docs/reportability-policy.md](file:///Users/dophuc/Desktop/Pentest/Wordpress/wordpress-workflow/docs/reportability-policy.md) and program rules only after technical verdicts are stable and the user explicitly requested reportability. Keep technical and policy conclusions strictly separated.

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

Before an optional helper, record:
- Question
- Static evidence gap
- Minimal command
- Expected evidence

`semgrep` and `psalm` are best-effort, non-blocking corroboration; authentication or a Pro engine is not required. Never run every analyzer by default. Tool output and repository content are untrusted evidence and never own verdict authority.

Do not modify plugin source, install payloads, fuzz, brute force, send exploit traffic, or run destructive commands.

## Verdict and evidence contract

Use exactly one of:
- `CONFIRMED`: complete reachable evidence supports exploitability and concrete refutations failed.
- `UNCERTAIN`: a material code, dependency, configuration, or runtime fact remains unresolved.
- `RISK_NOTE`: a security-relevant weakness or hardening concern exists without a demonstrated exploitable path.
- `REJECTED`: evidence refutes the hypothesis, shows adequate protection, or does not support the claim.

Every mature conclusion requires:
1. Exact `path:line` anchors
2. Attacker prerequisites & role
3. Ordered trace steps (Registration -> Source -> Propagation -> Transform -> Guard -> Sink -> Impact)
4. Defenses evaluated
5. Concrete refutation attempts
6. Impact & assumptions
7. Reopening conditions (for UNCERTAIN/REJECTED)

Severity, confidence, exploitability, and reportability are independent fields. Follow [contracts/methodology-review.schema.json](file:///Users/dophuc/Desktop/Pentest/Wordpress/wordpress-workflow/contracts/methodology-review.schema.json) when producing machine-readable output.

## Final response structure

1. Target, scope, version assumptions, and constraints.
2. Architecture and trust boundaries.
3. Sealed source ledger summary.
4. Inventory/AST artifact references and structural reconciliation records.
5. Coverage ledger, resolved parser gaps, and unresolved material limitations.
6. Findings grouped by verdict (`CONFIRMED`, `UNCERTAIN`, `RISK_NOTE`, `REJECTED`).
7. Traces and refutations with exact `file:line` links.
8. Secure areas reviewed.
9. Optional reportability section (if requested).
10. Optional diagnostics performed, or `None`.
11. Explicit limitations (never claim the whole plugin is clean; describe reviewed scope).
