# AGENTS.md - WordPress Audit Workspace

> Project-local routing for methodology-first WordPress review. Reusable AppSec identity belongs in skills; project semantics and policy snapshots live under `docs/`.

## Default entrypoint

Use the workspace skill:

```text
/wp-security-audit <plugin-path-or-slug>
```

The skill reviews source directly. After source-led mapping is sealed, read-only inventory plus AST/IR extraction and source reconciliation are required coverage evidence. Semgrep, Psalm, legacy Phase 1/2/3 scripts, and scanner artifacts remain optional diagnostics, not prerequisites or default context.

## Active context

Read first:

- `docs/wp-context.md` — stable WordPress semantics, not a vulnerability catalogue
- `docs/review-methodology.md` — source-first tracing, refutation, coverage, and adjudication

Do not load these during initial discovery:

- `docs/wordpress-pattern-catalogue.md` — late recall/on-demand only
- `docs/reportability-policy.md` and bounty rules — post-verdict and only when requested
- `docs/archive/wp-context-full-legacy.md` — historical research only
- scanner or legacy phase outputs — only for a written, bounded evidence question

If project semantics conflict with generic assumptions, verify against current WordPress behavior and observed source rather than silently choosing either claim.

## Workspace purpose

- Full-source or targeted security review of WordPress plugins and adjacent components.
- Source-led architecture understanding, attack-surface mapping, trust-boundary analysis, tracing, refutation, and evidence-bound reporting.
- Tooling may support a concrete investigation question but must not define the review agenda.

## Local rules

- Derive priorities from the selected plugin's behavior and assets, not a finite bug taxonomy.
- Identify the relevant trust boundary before rating severity.
- Authentication, intent/nonce, authorization, validation, and output encoding are distinct properties.
- Ground exploitability in a complete reachable trace with exact code evidence.
- Attempt at least one concrete refutation for every mature issue.
- Separate technical exploitability, severity, confidence, and reportability.
- Record secure areas reviewed and material coverage gaps.
- Seal the source-derived ledger before loading inventory/AST artifacts; reconcile every parser-only/source-only surface, parse gap, and unresolved dynamic edge before `COMPLETE`.
- Treat AST/IR as independent coverage evidence, never as a finding or verdict authority.
- Keep Semgrep and Psalm optional and non-blocking; no authentication or Pro engine is required.
- Never modify the selected plugin during an audit unless the user later requests remediation as a separate task.

## Output contract

- Use exactly one of `CONFIRMED`, `UNCERTAIN`, `RISK_NOTE`, or `REJECTED` per issue.
- Every mature conclusion includes `path:line`, attacker prerequisites, defenses considered, refutation result, impact, and assumptions.
- Missing context stays explicit; do not force a conclusion.
- Follow `contracts/methodology-review.schema.json` for the current machine-readable finding/review shape.
- Until the pending v2 contract migration, encode the sealed source-ledger summary in `coverage.files_reviewed`/`coverage.surfaces`, inventory and AST records in `tool_diagnostics`, and every unresolved reconciliation obligation in `coverage.gaps`. Do not add schema-v1 fields that `additionalProperties: false` rejects.

## Legacy compatibility

The shell pipeline under `tools/bin/` remains available for historical reproduction and optional corroboration. It is documented in `WORKFLOW-GUIDE.md` but is no longer the canonical audit workflow.
