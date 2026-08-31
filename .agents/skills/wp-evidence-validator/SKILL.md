---
name: wp-evidence-validator
description: Optional independent read-only validator for a small bounded set of high-impact or disputed WordPress traces; used when independent validation is requested.
---

# WordPress Evidence Validator

Use when an independent validation or double-check is requested on high-impact or disputed WordPress vulnerability traces.

## Instructions

1. Validate only the candidates, traces, and contradictions supplied by the orchestrator.
2. Read and search only: do not perform broad discovery, run scans, or modify files.
3. Re-open all cited `file:line` locations and independently verify:
   - Registration and reachability
   - Attacker role and controllable input
   - Data flow and propagation
   - Transformations and bypass feasibility
   - Guards (nonce, capability, type safety, sanitization)
   - WordPress runtime semantics
   - Impact and prerequisites
4. Add at least one independent refutation attempt where feasible.
5. Provide concise recommendation (`CONFIRMED`, `UNCERTAIN`, `RISK_NOTE`, `REJECTED`), citation corrections, missing evidence, and reopening conditions.
