# Executable WordPress Review Methodology

This is the canonical workflow for IDE-agent review. It replaces the Phase 1 → Phase 2 → Phase 3 runtime as the default and is the only sanctioned way to run a review in this project. The legacy pipeline scripts are never executed as a review path.

## Execution model — single agent, no pipeline

One model performs the entire review in one session. This project **never** spawns Worker/Reviewer sub-agents, never runs the legacy Phase 1/2/3 pipeline, never uses cluster consensus, voting, revisions, or parallel fan-out. Those patterns only burn quota on redundant sub-agents and sessions. The reviewing model does all of the work itself:

1. **Model-native parse first (no tools).** The model reads the plugin source and builds its own IR/AST/SAST-style understanding by reasoning alone — file/load graph, every registration and resolved callback, data-flow edges, sinks, persistence read/write edges, and trust boundaries — with zero tool assistance. This self-parse is sealed as the source-derived ledger.
2. **Then run the required Docker tools.** Only after the self-parse is sealed does the model run the packaged analyzers (`inventory`, `ast`/IR, and corroborating `semgrep`/`psalm`). These are mandatory support for the model's own parse, not optional extras.
3. **Reconcile — the difference is the signal.** The model compares its own parse against the tool output. Every parser-only surface, source-only surface, parse gap, and unresolved dynamic edge is an obligation re-opened in source.
4. **The same model adjudicates.** Using both its own parse and the tool results, the one model traces, refutes, reads everything, and produces a single unified verdict. No proposal from any other agent is involved.

## Operating principles

1. Source-first: the model builds its own structural understanding of plugin behavior before consulting machine extraction, pattern catalogues, or scanner output.
2. Coverage-accountable: record what was inspected, what remains unresolved, and why.
3. Independent structural corroboration: seal the model's self-parse ledger, then compare it with read-only inventory and AST/IR artifacts — the delta is coverage signal, not a verdict.
4. Hypothesis-driven: suspicious code becomes a question, not a finding.
5. Evidence-bound: trace registration → control → transformations → defenses → sensitive effect.
6. Refute-first: attempt to disprove every mature hypothesis.
7. Unified adjudication: one model, one verdict vocabulary; no phase states, no sub-agent proposals to translate.
8. Required tools, non-authoritative: inventory and AST/IR are mandatory coverage support; Semgrep and Psalm are corroboration. None of them is ever a completion gate skip, a verdict, or a severity authority.
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

**Pass 0 — Trust boundaries & intended flow (do this FIRST).** Before any input→sink hunt, map every trust boundary (client↔store, store↔platform, role↔role, and step↔step within a flow) and for each crossing ask: what proves it legitimate, and can that proof be forged / replayed / confused / skipped? A trust-boundary break is **not necessarily** IDOR/BOLA/BAC — it includes data-authenticity trust (acting on unverified/unsigned data), origin trust (a client header/UA as proof of origin), value trust (a client amount/price/status treated as authoritative), control-disabling (nonce/verification turned off), invariant/flow-sequencing violations (mark paid without paying, reuse a one-time token, out-of-order state, races), and second-order trust (low-priv actor writes data trusted downstream). For each core flow state its security invariant in one line, then hunt the path that violates it. The full method is in `review-techniques.md` → "Pass 0". Then run the five surface passes:

1. **Per-surface trace** — group entry points by type in privilege-risk order (unauth AJAX → auth AJAX → REST → shortcode/block → cron/filters) and trace each to a verdict before opening the next.
2. **Stored / cross-entry-point two-hop sweep** — match storage writes to reads **by key**; score reachability on the write leg; check sanitization at both write and read.
3. **Signal / anomaly triage** — adjudicate every flagged `file:line`; do not invent new findings here; a rejection names the defense at `file:line`.
4. **Unresolved-hook & coverage-gap backstop** — resolve dynamic hook names by hand; investigate files that use WP security functions but expose no mapped entry point.
5. **Self-verify** — re-read the highest-severity chains and confirm each cited `file:line` lands on the claimed source/sink.

The full technique catalogue for each pass — recall blind spots, guard three-state discipline, anti-hallucination anchoring, threat-profile weighting, and large-target chunking for one agent — is in `review-techniques.md` (on-demand reference; consult during these passes or for a late recall/precision audit).

Core invariants: guard effectiveness is three-state (effective / ineffective / **unknown is not safe**); detect guards by structure, not by name; a signal is never a finding; never allow a silent drop — log every unresolved hook or unfollowed call; resolve structure before adjudicating exploitability; watch the hedging trap (`UNCERTAIN` is a backlog with a resolution path, not a wastebasket).

Coverage & labelling discipline (learned the hard way):

- **IR labels are navigation, not verdicts.** `auth_level: unknown` (or any unresolved `permission_callback`) means **UNAUDITED — read it**; resolve the real permission (follow inherited methods) and read the callback body for internal capability checks. Never treat "unknown" as a priority discount or a clean verdict.
- **No whole-plugin conclusion over a sampled surface.** Do not say "no finding" / "clean" / "the candidate list is complete" for a surface class until every surface in it is read; a bounded result must be labelled slice-scoped. Work the `slice_ir.py` plan batch by batch — do not cherry-pick.
- **Finding one issue is not a stopping condition.** Continue until the surface is covered; the output is the full set per verdict, with coverage proof.
- **Ground severity in least-privilege reachability.** For each finding, state the lowest privilege that can reach it and answer "does it grant a capability the actor does not already have?" A break reachable only at a role that already holds the impacted power has no concrete impact — downgrade and say so.
- **Do not anchor on known CVEs / model priors.** Check the version, reason from source; a remembered CVE is Tier-5 signal, often already patched.

### 3. ADJUDICATING

Attempt explicit refutations:

- Is the callback loaded and reachable under the claimed conditions?
- Is the value actually attacker-controlled at this point?
- Does an earlier caller, wrapper, or framework layer enforce the missing property?
- Does failure of the guard terminate all paths to the effect?
- Is the sensitive effect constrained to the attacker's own authorized object?
- Does encoding/validation match the final sink context?
- Does the claimed impact require absent code, unusual configuration, another vulnerability, or an unsupported runtime assumption?

Assign exactly one verdict from `CONFIRMED`, `UNCERTAIN`, `RISK_NOTE`, `REJECTED`. The single reviewing model owns the verdict; there is no separate proposer.

### 4. COMPLETE

Re-open cited locations and verify file, line, symbol, reachability, transformations, defenses, prerequisites, and impact. Reconcile the coverage ledger. State secure areas reviewed and material limitations.

Do not mark `COMPLETE` until:

- inventory and AST/IR extraction ran successfully against the selected source, or an extraction failure is explicitly recorded and every affected file is manually covered;
- every parser-only/source-only discrepancy has a resolved disposition;
- every parse gap and unresolved dynamic edge is resolved or manually bounded with evidence;
- no machine-only candidate remains unreviewed in source;
- the machine-readable review passes both enforcement checks (below).

This gate is enforced by code, not honour system. Produce the review JSON, then run:

```bash
python3 tools/bin/validate_review.py <review.json>          # schema conformance
python3 tools/bin/complete_gate.py <review.json> --slug <slug>   # reconciliation obligations
```

`validate_review.py` must exit 0 (output conforms to `contracts/methodology-review.schema.json`). `complete_gate.py` must exit 0 — it fails closed when a finding lacks an anchored refutation, an `UNRESOLVED` surface lacks a disposition, a required tool artifact is missing, any IR `unresolved_hook`/`coverage_gap`/`entry_point` is unaccounted for, or **the accounted fraction of IR entry points is below the coverage floor** (default 90% via `--min-ep-coverage`; the guard against declaring a whole-plugin verdict over a sampled surface). A deliberately partial run must pass `--min-ep-coverage 0` and be reported as slice-scoped, not COMPLETE. Do not claim `COMPLETE` while either exits non-zero; resolve the reported obligations and re-run. A conforming golden example lives at `contracts/examples/`.

For an intrinsic quality read (no external ground truth, so no known-CVE bias), run `python3 tools/bin/review_metrics.py <review.json> --ir <ir.json>` — surface/IR coverage, anchored-refutation rate, and the `UNCERTAIN` rate (a rising rate is the hedging-trap signal). `--compare <review_b.json>` reports run-to-run finding overlap as a reproducibility proxy.

Semgrep/Psalm absence, lack of authentication/Pro engine, or diagnostic failure does not block completion. Record it only when relevant.

Do not claim that a plugin is clean. State that no confirmed finding was identified within the documented scope and limitations.

## Single-agent execution

The whole review is performed by one model in one session:

1. The model self-parses the source (IR/AST/SAST by reasoning, no tools) and seals the source ledger.
2. The same model runs the required inventory + AST/IR baseline and resolves every structural discrepancy against source.
3. The same model traces the reconciled queue, records refutations, and adjudicates.
4. The same model re-checks evidence and reports.

Do not spawn Worker/Reviewer sub-agents, mappers, investigators, or validators; do not use voting, cluster consensus, or parallel agents reading the same scope; do not delegate. Additional sub-agents and sessions only waste quota without adding evidence. If independent double-checking of a single high-impact disputed trace is genuinely needed, the same model re-derives it from scratch and states the second-pass reasoning inline — it does not fan out to another agent. The required structural baseline, reconciliation ledger, and output contract always apply.

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

The machine-readable contract is `contracts/methodology-review.schema.json` (v1.1.0). Represent the sealed ledger through `coverage.files_reviewed` and `coverage.surfaces`, record inventory/AST runs in `tool_diagnostics`, and place any unresolved reconciliation obligation in `coverage.gaps`; do not emit undeclared fields. For WordPress-specific finding classes use the v1.1 optional fields: anchor stored/second-order two-hop flows with `finding.storage_link` (write leg + read leg + `storage_key`), record normalized privilege in `surface.auth_required`, and note `surface.resolution_confidence` for dynamically-resolved hooks. The lifecycle gate above remains mandatory even though full machine enforcement awaits the v2 contract migration.
