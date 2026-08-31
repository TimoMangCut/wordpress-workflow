# AGENTS.md - WordPress Audit Workspace

> Project-local routing for methodology-first WordPress review. Reusable AppSec identity belongs in skills; project semantics and policy snapshots live under `docs/`.

## Default entrypoint

Use the workspace skill:

```text
/wp-security-audit <plugin-path-or-slug>
```

The skill reviews source directly. One model performs the whole review in one session: it first self-parses the source into its own IR/AST/SAST-style understanding by reasoning alone (no tools), seals that source-led ledger, then runs the required read-only inventory + AST/IR extraction and reconciles the machine parse against its own. Semgrep and Psalm are corroboration; the legacy Phase 1/2/3 scripts and scanner artifacts are never a review path. This project never spawns Worker/Reviewer sub-agents, mappers, investigators, validators, or parallel sessions — that only wastes quota.

## Active context

Read first:

- `docs/wp-context.md` — stable WordPress semantics, not a vulnerability catalogue
- `docs/review-methodology.md` — source-first tracing, refutation, coverage, and adjudication

Consult on-demand (not during initial discovery, but during the tracing passes or a late audit):

- `docs/review-techniques.md` — single-agent detection/precision technique catalogue (five analysis passes, recall blind spots, guard three-state discipline, threat-profile weighting, large-target chunking)

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
- Encode the sealed source-ledger summary in `coverage.files_reviewed`/`coverage.surfaces`, inventory and AST records in `tool_diagnostics`, and every unresolved reconciliation obligation in `coverage.gaps`. For WordPress-specific classes, the v1.1 contract adds `finding.storage_link` (two-hop stored flows), `surface.auth_required` (normalized privilege enum), and `surface.resolution_confidence`. Do not emit fields the schema's `additionalProperties: false` rejects.

## Legacy compatibility

The shell pipeline under `tools/bin/` is retained only for historical reproduction and is never run as a review path. The single-agent methodology above is the only sanctioned workflow. The Docker helper (`wp-audit-tools.sh`) that packages inventory/AST/Semgrep/Psalm is a required in-session support tool, not a pipeline; see `WORKFLOW-GUIDE.md`.
