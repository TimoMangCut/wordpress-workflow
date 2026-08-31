---
name: wp-security-audit
description: Source-first WordPress plugin security review methodology with evidence tracing, refutation, unified verdicts, optional on-demand tools, and post-verdict bounty triage.
---

# WordPress Security Audit — Compatibility Skill

The canonical methodology is shared with Kiro. Read:

- `../../../docs/wp-context.md`
- `../../../docs/review-methodology.md`
- `../../../AGENTS.md`

Do not load historical archived context, scanner reports, phase artifacts, pattern catalogue, or bounty rules during initial discovery.

## Workflow

1. Understand plugin behavior, architecture, assets, and trust boundaries from source.
2. Maintain a coverage ledger and source-led surface map.
3. Form bounded hypotheses and trace registration → attacker control → transformations/storage → defenses → sensitive operation → impact.
4. Attempt at least one concrete refutation for every mature hypothesis.
5. Adjudicate directly with `CONFIRMED`, `UNCERTAIN`, `RISK_NOTE`, or `REJECTED`.
6. Re-open cited evidence and reconcile coverage before reporting.

Do not use Phase 1/2/3, Worker/Reviewer loops, cluster consensus, or scanner severity as review authority. Tools are optional and may answer a concrete question only after the question and static evidence gap are recorded.

After source-led discovery, consult `../../../docs/wordpress-pattern-catalogue.md` only for late recall. Consult `../../../docs/reportability-policy.md` and a dated official program policy only after technical verdicts are stable and reportability was requested.

Follow `../../../contracts/methodology-review.schema.json` for machine-readable output. Every mature conclusion requires exact `path:line`, attacker prerequisites, defenses, refutation result, impact, and explicit assumptions.
