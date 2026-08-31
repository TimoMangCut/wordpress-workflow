# Executable WordPress Review Methodology

This is the canonical workflow for IDE-agent review. It replaces the Phase 1 → Phase 2 → Phase 3 runtime as the default. Legacy scripts remain optional diagnostics.

## Operating principles

1. Source-first: understand plugin behavior before consulting machine extraction, pattern catalogues, or scanner output.
2. Coverage-accountable: record what was inspected, what remains unresolved, and why.
3. Independent structural corroboration: seal a source-derived ledger, then compare it with read-only inventory and AST/IR artifacts.
4. Hypothesis-driven: suspicious code becomes a question, not a finding.
5. Evidence-bound: trace registration → control → transformations → defenses → sensitive effect.
6. Refute-first: attempt to disprove every mature hypothesis.
7. Unified adjudication: use one verdict vocabulary; do not translate between phase states.
8. Optional scanners: Semgrep and Psalm are non-blocking corroboration, never completion prerequisites or verdict authorities.
9. Technical-first: determine exploitability before external bounty eligibility.

## Review lifecycle

```text
DISCOVERING → TRACING → ADJUDICATING → COMPLETE
```

### 1. DISCOVERING

Understand plugin purpose, bootstrap, modules, dependencies, trust boundaries, sensitive assets, persistence, and external integrations. Map reachable surfaces from source without machine artifacts or scanner output.

Maintain a source-derived coverage ledger for:

- loaded PHP files and relevant templates/assets;
- registrations and resolved callbacks;
- anonymous, authenticated, privileged, cross-site, and external-system boundaries;
- state-changing and sensitive read operations;
- persistence writers/readers;
- unresolved dynamic dispatch and unavailable dependency code.

Seal this ledger before loading machine-generated structural artifacts. Then run the read-only baseline:

```bash
bash tools/bin/wp-audit-tools.sh inventory <plugin-path> [output-dir]
bash tools/bin/wp-audit-tools.sh ast <plugin-path> [output-dir]
```

Reconcile source and parser views before finalizing the trace queue:

- inventory file-set differences;
- parser-only and source-only registrations, callbacks, sinks, and persistence edges;
- parse/read failures and degraded extraction;
- unresolved or ambiguous hooks, callbacks, permission callbacks, dynamic dispatch, and call-depth boundaries.

Every discrepancy is an obligation. Re-open it in source and record a resolution or a bounded manual coverage disposition. Parser silence is not negative evidence. An unresolved obligation blocks `COMPLETE`.

Create a prioritized trace queue after reconciliation. Queue entries are hypotheses, not vulnerabilities.

### 2. TRACING

For each prioritized hypothesis:

```text
registration → callback → attacker control → propagation/storage
→ transformations → guards → sensitive operation → impact
```

Read callees and writers/readers of persistent state as needed. Do not stop at one function merely because it contains a familiar source and sink.

Record defenses in context: authentication, nonce/signature, capability, object ownership, type/domain validation, prepared query, path containment, output encoding, framework defaults, and termination behavior.

### 3. ADJUDICATING

Attempt explicit refutations:

- Is the callback loaded and reachable under the claimed conditions?
- Is the value actually attacker-controlled at this point?
- Does an earlier caller, wrapper, or framework layer enforce the missing property?
- Does failure of the guard terminate all paths to the effect?
- Is the sensitive effect constrained to the attacker's own authorized object?
- Does encoding/validation match the final sink context?
- Does the claimed impact require absent code, unusual configuration, another vulnerability, or an unsupported runtime assumption?

Assign exactly one verdict from `CONFIRMED`, `UNCERTAIN`, `RISK_NOTE`, `REJECTED`. The main agent owns the final verdict. A sub-agent proposal is advisory.

### 4. COMPLETE

Re-open cited locations and verify file, line, symbol, reachability, transformations, defenses, prerequisites, and impact. Reconcile the coverage ledger. State secure areas reviewed and material limitations.

Do not mark `COMPLETE` until:

- inventory and AST/IR extraction ran successfully against the selected source, or an extraction failure is explicitly recorded and every affected file is manually covered;
- every parser-only/source-only discrepancy has a resolved disposition;
- every parse gap and unresolved dynamic edge is resolved or manually bounded with evidence;
- no machine-only candidate remains unreviewed in source.

Semgrep/Psalm absence, lack of authentication/Pro engine, or diagnostic failure does not block completion. Record it only when relevant.

Do not claim that a plugin is clean. State that no confirmed finding was identified within the documented scope and limitations.

## Sub-agent economy

Default sequence:

1. `wp-surface-mapper` performs bounded source inventory.
2. The main agent seals the source ledger, runs inventory + AST/IR, and resolves structural discrepancies.
3. `wp-trace-investigator` traces the reconciled queue and records refutations.
4. The main agent adjudicates, re-checks evidence, and reports.

Do not create Worker/Reviewer rounds, voting, cluster consensus, or parallel agents reading the same scope. Invoke `wp-evidence-validator` only when the user explicitly asks for independent validation or a high-impact claim has a concrete unresolved contradiction. Never delegate recursively.

For a small plugin, the main agent may perform mapping and tracing directly if delegation would cost more context than it saves. The required structural baseline, reconciliation ledger, and output contract still apply.

## Tool protocol

### Required structural baseline

`inventory` and `ast` run after the source ledger is sealed. They do not require a vulnerability hypothesis or scanner authorization. Keep the plugin mount read-only and artifacts in an explicit output directory.

AST/IR is a structural coverage index, not a finding source. Its parser-only entries, omissions, failures, and unresolved edges must be rechecked against source.

### Optional diagnostics

Before `search`, `semgrep`, or `psalm`, write:

```text
Question: ...
Static gap: ...
Minimal tool: search|semgrep|psalm
Expected evidence: ...
```

Rules:

- Semgrep Community is sufficient when used; Pro authentication is optional.
- Semgrep and Psalm are best-effort and non-blocking.
- Tool severity, rule ID, and confidence never become finding verdict or severity.
- Do not run `all`; there is intentionally no all-tools command.
- Keep plugin mounts read-only and write artifacts only to an explicit output directory.

## Minimum final output

1. Target, scope, version assumptions, and constraints.
2. Architecture and trust boundaries.
3. Sealed source ledger summary.
4. Inventory/AST artifact references and structural reconciliation records.
5. Coverage ledger, resolved parser gaps, and unresolved material limitations.
6. Findings grouped by verdict.
7. For each mature issue: hypothesis, attacker prerequisites, ordered trace with `path:line`, defenses, refutation attempts, impact, severity, confidence, and reopening conditions where applicable.
8. Secure areas reviewed.
9. Optional reportability section, clearly separated and policy-dated.
10. Optional diagnostics performed, or `None`.

The machine-readable contract is `contracts/methodology-review.schema.json`. While it remains at v1, represent the sealed ledger through `coverage.files_reviewed` and `coverage.surfaces`, record required inventory/AST runs in `tool_diagnostics`, and place any unresolved reconciliation obligation in `coverage.gaps`; do not emit undeclared top-level fields. The lifecycle gate above remains mandatory even though full machine enforcement awaits the v2 contract migration.
