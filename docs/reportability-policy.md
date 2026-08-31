# Reportability Policy Boundary

Reportability is optional post-verdict analysis. It must never influence whether a technical issue is `CONFIRMED`, `UNCERTAIN`, `RISK_NOTE`, or `REJECTED`.

## Activation

Do not load bounty rules during discovery or tracing. Consult a program policy only when:

1. technical adjudication is stable;
2. the user requests submission triage; and
3. the target program and effective date are known.

## Required policy metadata

Every reportability conclusion must state:

- program name;
- source URL or repository snapshot;
- effective/last-verified date;
- target component/version and public availability;
- active-install evidence if required;
- required attacker role;
- CVSS version/vector if used;
- explicit acceptance/exclusion rule;
- unresolved policy conflicts.

Use `eligible`, `ineligible`, or `unknown`. Default to `unknown` when current rules or target metadata cannot be verified.

## Repository snapshots

- `bug-bounty-rules-summary.md` is a historical convenience summary and contains thresholds that may be stale.
- `archive/wp-context-full-legacy.md` includes a later Patchstack snapshot, but it is still time-sensitive and not live program authority.
- `.codex/skills/Review-Code/references/patchstack-rules.md` may disagree with the summary.

Do not silently choose one conflicting threshold. Current program rules should be verified from the official source before submission advice. A technically confirmed issue can remain reportability `unknown`.
