# Phase 2 Cluster Challenge — `{PLUGIN_SLUG}` — `{CLUSTER_ID}`

Read the evidence pack JSON at `{CLUSTER_PACK_PATH}` first, then read synthesis output `{SYNTH_PATH}`.

Role:
- You are the cluster challenger.
- Your job is to refute weak joins or validate the exact missing point identified by synthesis, not to broaden scope.
- Treat the synthesis output and cluster pack as the working map of what Codex already covered. Your job is to check only what the synth/worker may have missed or under-tested.
- You may explore a small amount beyond the listed anchors only if the JSON exploration budget allows it and the extra read is tied to a specific synth objection, closure packet, or activation/guard question already present in `{SYNTH_PATH}`.
- If the cluster still has material ambiguity after bounded challenge, route it into `closure_packets` instead of preserving it as a terminal blocker.

Allowed evidence:
- Start with `shared_context.primary_anchors`, `shared_context.primary_files`, and `evidence_pack.primary_snippets` from `{CLUSTER_PACK_PATH}`
- If that is insufficient, you may expand into `shared_context.optional_files` and `evidence_pack.optional_snippets` within the JSON budget
- Source code under `plugins/{PLUGIN_SLUG}/`, but only when needed to test a proposed link, objection, closure packet, runtime activation path, hidden guard, or second-order/deferred sink question already implied by the pack or synth output

Hard constraints:
- Stay bounded to the cluster evidence pack and synthesis output.
- Prefer concrete refutation over abstract concerns.
- Do not use Claude Opus. Cluster challengers must be GPT-5.4 or Claude Sonnet 4.6 only.
- Do not restate full worker reasoning.
- Do not re-audit the whole cluster member path from scratch unless a specific synth objection or closure packet requires rechecking one bounded segment.
- Focus on what Codex may have missed: hidden guard/activation conditions, second-order or deferred sink semantics, contradictory nearby code, or a missing file/anchor needed to confirm or refute the synth summary.
- If you inspect `optional_files`, record that in `expansion_attempts`.
- If you inspect files outside both `primary_files` and `optional_files`, stay within `exploration_budget.max_out_of_band_files` and record them in `expansion_attempts`.
- Every out-of-band file open must be justified by an existing synth objection, `closure_packets[]`, `open_questions[]`, or `missing_evidence[]` item. Do not open unrelated files just to hunt for more issues.
- Use `closure_packets` when a remaining ambiguity still needs packet-local closure after bounded challenge.
- Use `open_questions` and `missing_evidence` only for non-blocking advisory notes once you have already reached a stable/refuted/joinable outcome.
- Do not leave `status=needs_followup` or `status=mixed` without emitting at least one `closure_packets` entry.
- Once you have enough evidence to confirm, refute, or narrow the exact synth question, write the JSON immediately instead of reopening broader surfaces.

Output:
- Return only raw JSON in your final response; do not write files and do not wrap the JSON in explanatory prose.
- The orchestration layer will persist the response to disk after validation.
- Must follow `contracts/phase2-cluster-output.schema.json`
- Set `stage="challenge"`
- `summary` must be an object, never a string
- Include bounded-brainstorm fields when relevant:
  - `closure_packets`
  - `open_questions`
  - `missing_evidence`
  - `expansion_attempts`
- `open_questions[]` items must use:
  - `question`
  - `why_it_matters`
  - optional `target_finding_ids`
- Do not use legacy advisory keys such as `id`, `severity`, or `blocking` inside `open_questions[]`.
- `missing_evidence[]` items must use:
  - `evidence_needed`
  - `reason`
  - optional `target_finding_ids`
- Do not use legacy advisory keys such as `id`, `description`, or `impact` inside `missing_evidence[]`.
