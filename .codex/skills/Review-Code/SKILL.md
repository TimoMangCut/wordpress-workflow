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

One model does the whole review in one session — no sub-agents, no pipeline. Strict order: self-parse first, then required tools, then reconcile, then adjudicate.

1. **Self-parse (no tools):** read the source and build your own IR/AST/SAST-style understanding by reasoning alone — surfaces, registrations, resolved callbacks, data-flow, sinks, persistence, trust boundaries. Seal a source-derived coverage ledger and a bounded hypothesis queue.
2. **Required tools:** only then run `inventory` + `ast` (mandatory coverage support) and corroborating `semgrep`/`psalm` via `tools/bin/wp-audit-tools.sh`. Semgrep is Community-only (no Pro key provisioned).
3. **Reconcile:** compare your own parse with the tool output; re-open every parser-only/source-only surface, parse gap, and unresolved dynamic edge in source. Open obligations block completion.
4. **Trace & refute:** trace registration → attacker control → transform/storage → defenses → sensitive operation → impact, with at least one concrete refutation per mature hypothesis.
5. **Adjudicate:** assign `CONFIRMED`, `UNCERTAIN`, `RISK_NOTE`, or `REJECTED` yourself; re-open cited evidence and reconcile coverage before reporting.

Do not use Phase 1/2/3, Worker/Reviewer loops, cluster consensus, sub-agent delegation, or scanner severity as review authority. `inventory`/`ast` are required support; `semgrep`/`psalm` are optional corroboration answering a concrete recorded question. No tool is ever a verdict authority.

After source-led discovery, consult `../../../docs/wordpress-pattern-catalogue.md` only for late recall. Consult `../../../docs/reportability-policy.md` and a dated official program policy only after technical verdicts are stable and reportability was requested.

Follow `../../../contracts/methodology-review.schema.json` for machine-readable output. Every mature conclusion requires exact `path:line`, attacker prerequisites, defenses, refutation result, impact, and explicit assumptions.
