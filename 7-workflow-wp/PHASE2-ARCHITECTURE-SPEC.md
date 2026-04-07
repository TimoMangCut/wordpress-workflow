# PHASE2-ARCHITECTURE-SPEC.md — Execution Model for Phase 2

> Status: Draft for implementation
> Scope: Phase 2 only
> Purpose: lock the execution model before further Batch 4.5/5 changes

---

## 1. Why This Spec Exists

Phase 2 no longer has a “missing one more fix” problem.

It now has a **shape problem**:
- several correct pieces already exist
- but they do not yet compose into one closed execution model

Current debugging has proven these points:
- worker chunking is real and valuable
- bundle-local review is useful
- JSON-first artifacts are the right direction
- cluster synthesis currently still behaves too much like exploration

This spec freezes the intended model so future work does not continue as
serial prompt/timeout patching.

---

## 2. What Already Works

These parts are worth preserving:

1. Deterministic preparation
- IR, Semgrep, Psalm, threat context, candidate inventory, and bundle planning
- freshness/canonical artifact handling from earlier batches

2. Worker chunking
- bounded `agent-wNN` bundles materially reduce runtime and context pressure

3. Bundle-local review loop
- `worker -> reviewer -> worker revision` is a valid local-correction layer

4. Deterministic merge
- bundle outputs can already be merged reproducibly

5. JSON-first cluster artifacts
- cluster inputs are materially smaller and easier to validate than prose-heavy docs

These are not to be thrown away. They are the foundation.

---

## 3. What Is Actually Missing

The missing piece is a **closed Phase 2 execution architecture**.

Specifically:

1. Discovery and synthesis are still mixed
- cluster synth is still doing too much exploration

2. Prompt guidance is stronger than execution enforcement
- the model can still broad-search beyond intended scope

3. There is no canonical `consensus` layer
- outputs exist at bundle and cluster levels, but not yet as one explicit Phase 2 conclusion artifact

4. Evidence is not yet packed tightly enough for synthesis stages
- cluster stages still depend too much on model-driven code search

5. Validation is still patch-driven
- debugging has been useful, but no longer sufficient as the main operating mode

---

## 4. Design Principles

1. Discovery and synthesis must be separate jobs.
2. Bundle stages may read source trees; synthesis stages should prefer evidence packs.
3. Prompt text should be thin; artifacts and schemas should carry the work.
4. Brainstorm is allowed, but only with explicit budget and audit trail.
5. Canonical Phase 2 output must be written by a deterministic consensus layer.
6. Phase 2 should optimize for evidence quality, not raw model freedom.

---

## 5. Roles and Model Policy

### 5.1 Bundle Stage

- Bundle worker: `claude-sonnet-4.6`
- Bundle reviewer: `gpt-5.4`
- Bundle revision worker: `claude-sonnet-4.6`

### 5.2 Cluster Stage

- Cluster core synthesizer: `gpt-5.4`
- Cluster challenger: `claude-sonnet-4.6` or `gpt-5.4`
- `Claude Opus` is excluded from cluster-stage defaults

### 5.3 Global Exploration

- Primary: `gpt-5.4`
- Optional secondary pass: `claude-sonnet-4.6`
- `Claude Opus` remains out of scope for the target architecture

---

## 6. Target Phase 2 Pipeline

```text
Phase 1 deterministic artifacts
        ↓
Candidate inventory + bundle plan
        ↓
Bundle tracing workers
        ↓
Bundle-local reviewer loop
        ↓
Deterministic merge
        ↓
Cluster planning
        ↓
Cluster evidence pack builder
        ↓
Cluster core synth
        ↓
Cluster challenge
        ↓
Global exploration
        ↓
Consensus writer
        ↓
reports/phase2/<slug>-phase2.consensus.json
        ↓
reports/phase2/<slug>-phase2.json   (canonical downstream artifact)
```

---

## 7. Stage Definitions

### 7.1 Stage A — Candidate Inventory and Bundle Plan

Owner: deterministic Python

Inputs:
- `reports/phase1/<slug>-ir.json`
- `reports/phase1/<slug>-semgrep.json` if present
- `reports/phase1/<slug>-psalm.sarif` if present
- `reports/context/<slug>-threat-context.json` if present

Outputs:
- `reports/<slug>-candidate-inventory.json`
- `reports/<slug>-candidate-bundle-agent-wNN.json`
- `reports/<slug>-dispatch.json`

Purpose:
- convert raw signals into bounded trace hypotheses
- classify by bug family, sink family, surface, trust boundary, and complexity
- pack by execution budget rather than only entry-point grouping

Notes:
- this already exists in partial form and should remain deterministic

### 7.2 Stage B — Bundle Tracing

Owner: Sonnet workers

Inputs:
- one bounded worker bundle
- source tree for the target plugin

Output:
- `reports/<slug>-agent-wNN.json`

Purpose:
- trace local paths
- attempt local refutation
- produce finding candidates with anchors and evidence

Rules:
- bundle workers are allowed full source access within plugin scope
- they are the correct place for discovery-heavy tracing

### 7.3 Stage C — Bundle-Local Review

Owner: GPT-5.4 reviewer + Sonnet revision worker

Inputs:
- worker bundle output
- original bundle input
- threat context if present

Outputs:
- `reports/phase2/<slug>-agent-wNN-review.r1.json`
- `reports/phase2/<slug>-agent-wNN-revised.r1.json`

Purpose:
- local challenge only
- catch weak paths, duplicates, malformed evidence, shallow refutation

Non-goal:
- do not reason about whole-plugin chains here

### 7.4 Stage D — Deterministic Merge

Owner: deterministic Python

Inputs:
- all valid bundle outputs after local review

Outputs:
- `reports/<slug>-phase2-merged.json`
- `reports/phase2/<slug>-phase2.local.json`

Purpose:
- merge local results only
- this is not the canonical final Phase 2 artifact

### 7.5 Stage E — Cluster Planning

Owner: deterministic Python

Inputs:
- `reports/phase2/<slug>-phase2.local.json`

Outputs:
- `reports/phase2/<slug>-cluster-plan.json`
- `reports/phase2/<slug>-cluster-cNN.json`
- `reports/phase2/<slug>-cluster-cNN.input.json`

Purpose:
- group related local findings for cross-bundle reasoning

Important:
- cluster planning must stay structural and deterministic
- cluster planning is not allowed to become a second discovery engine

### 7.6 Stage F — Cluster Evidence Pack Builder

Owner: deterministic Python

This stage is currently missing and is the next required implementation.

Inputs:
- `cluster-cNN.input.json`
- source tree

Outputs:
- `reports/phase2/<slug>-cluster-cNN.pack.json`

The pack should contain:
- cluster metadata
- member finding summaries
- `primary_anchors`
- `primary_files`
- `optional_files`
- extracted snippets around source/sink/guard anchors
- limited optional snippets
- explicit exploration budget

Purpose:
- make cluster synthesis evidence-pack driven instead of file-search driven

Critical rule:
- cluster synth should start from the pack, not from raw code search

### 7.7 Stage G — Cluster Core Synth

Owner: `gpt-5.4`

Inputs:
- `cluster-cNN.pack.json`

Outputs:
- `reports/phase2/<slug>-cluster-cNN.synth.json`

Purpose:
- decide join/split/keep-separate relationships
- identify missing evidence
- produce open questions

Allowed freedom:
- bounded exploration only
- any expansion beyond packed evidence must be logged in `expansion_attempts`

Non-goal:
- not responsible for unrestricted plugin rediscovery

### 7.8 Stage H — Cluster Challenge

Owner: `claude-sonnet-4.6` or `gpt-5.4`

Inputs:
- `cluster-cNN.pack.json`
- `cluster-cNN.synth.json`

Outputs:
- `reports/phase2/<slug>-cluster-cNN.challenge.json`

Purpose:
- refute weak joins
- force justification of shared trust boundary, shared guard model, or cross-bundle path

### 7.9 Stage I — Global Exploration

Owner: `gpt-5.4` primarily

Inputs:
- cluster outputs
- unresolved hooks
- coverage gaps
- anomalies not absorbed by any cluster

Outputs:
- `reports/phase2/<slug>-global-exploration.json`

Purpose:
- one bounded missed-finding pass after local and cluster reasoning

This stage exists so cluster synth does not need to double as a global explorer.

### 7.10 Stage J — Consensus Writer

Owner: deterministic Python

This stage is also currently missing and must be implemented before Batch 5 is considered complete.

Inputs:
- `phase2.local.json`
- all valid `cluster-cNN.synth.json`
- all valid `cluster-cNN.challenge.json`
- `global-exploration.json`

Outputs:
- `reports/phase2/<slug>-phase2.consensus.json`
- `reports/phase2/<slug>-phase2.json`

Purpose:
- write the canonical Phase 2 conclusion artifact
- make explicit which claims survived:
  - local tracing
  - local critique
  - cross-bundle synthesis
  - cross-bundle challenge
  - global missed-finding pass

Rule:
- downstream Phase 3 should read the canonical `phase2.json`
- but that file should be written only after consensus exists

---

## 8. Artifact Contracts

### 8.1 Local Artifacts

- `reports/<slug>-candidate-inventory.json`
- `reports/<slug>-candidate-bundle-agent-wNN.json`
- `reports/<slug>-agent-wNN.json`
- `reports/phase2/<slug>-agent-wNN-review.r1.json`
- `reports/phase2/<slug>-agent-wNN-revised.r1.json`
- `reports/phase2/<slug>-phase2.local.json`

### 8.2 Cross-Bundle Artifacts

- `reports/phase2/<slug>-cluster-plan.json`
- `reports/phase2/<slug>-cluster-cNN.input.json`
- `reports/phase2/<slug>-cluster-cNN.pack.json`
- `reports/phase2/<slug>-cluster-cNN.synth.json`
- `reports/phase2/<slug>-cluster-cNN.challenge.json`
- `reports/phase2/<slug>-global-exploration.json`

### 8.3 Canonical Artifacts

- `reports/phase2/<slug>-phase2.consensus.json`
- `reports/phase2/<slug>-phase2.json`

---

## 9. Enforcement Model

Prompt guidance alone is not enough for synthesis stages.

Target enforcement rules:

1. Bundle stages
- may search the plugin source tree

2. Cluster stages
- should consume evidence packs
- should not start from arbitrary file search

3. Exploration beyond pack
- is allowed only under an explicit budget
- must be written into `expansion_attempts`

4. If expansion exceeds budget
- the stage should be considered invalid or downgraded to `needs_followup`

This is the core architectural shift still missing from current code.

---

## 10. Validation Matrix

Validation should no longer be “patch one thing and see what happens”.

Use this fixed matrix:

### 10.1 `cartflows`

Purpose:
- cross-bundle and cluster behavior

Checks:
- cluster synth produces artifact
- cluster challenge produces artifact
- no runaway broad search
- useful `open_questions` / `missing_evidence`

### 10.2 `hostinger-reach`

Purpose:
- worker/reviewer runtime stability

Checks:
- worker completes under role timeout
- reviewer loop is real and produces valid critique
- revised output remains schema-valid

### 10.3 `duplicator`

Purpose:
- negative control

Checks:
- architecture does not inflate findings on a relatively quiet target

Only after this matrix passes should Batch 5 be considered open.

---

## 11. What Not To Do

1. Do not keep solving cluster runtime only with larger timeouts.
2. Do not let cluster synth double as whole-plugin exploration.
3. Do not migrate worker/reviewer fully to JSON-first before cluster architecture is stable.
4. Do not introduce Opus back into cluster stages.
5. Do not treat `phase2.local.json` as the final Phase 2 truth.

---

## 12. Immediate Implementation Order

This is the recommended next sequence after adopting this spec.

### Step 1
Implement `build_cluster_evidence_pack.py`

### Step 2
Change cluster synth/challenge to consume `cluster-cNN.pack.json` instead of raw source search as the default reasoning surface

### Step 3
Implement deterministic `write_phase2_consensus.py`

### Step 4
Validate the matrix in this order:
- `cartflows`
- `hostinger-reach`
- `duplicator`

### Step 5
Only then resume broader worker/reviewer JSON-first migration

---

## 13. Exit Criteria for Batch 4.5

Batch 4.5 is complete only when all of the following are true:

1. `cartflows` cluster synth and challenge both complete from evidence-pack-driven inputs
2. cluster stages no longer rely on unconstrained broad search
3. `phase2.consensus.json` exists and writes canonical `phase2.json`
4. `hostinger-reach` bundle worker/reviewer loop is stable
5. `duplicator` does not show clear finding inflation

Until then, the architecture is promising but not closed.
