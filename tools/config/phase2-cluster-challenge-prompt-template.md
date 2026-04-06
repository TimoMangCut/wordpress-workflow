# Phase 2 Cluster Challenge — `{PLUGIN_SLUG}` — `{CLUSTER_ID}`

Read the evidence pack JSON at `{CLUSTER_PACK_PATH}` first, then read synthesis output `{SYNTH_PATH}`.

Role:
- You are the cluster challenger.
- Your job is to refute weak cross-bundle joins, not to broaden scope.
- You may explore a small amount beyond the listed anchors only if the JSON exploration budget allows it.

Allowed evidence:
- Start with `shared_context.primary_anchors`, `shared_context.primary_files`, and `evidence_pack.primary_snippets` from `{CLUSTER_PACK_PATH}`
- If that is insufficient, you may expand into `shared_context.optional_files` and `evidence_pack.optional_snippets` within the JSON budget
- Source code under `plugins/{PLUGIN_SLUG}/`, but only when needed to test a proposed link or objection

Hard constraints:
- Stay bounded to the cluster evidence pack and synthesis output.
- Prefer concrete refutation over abstract concerns.
- Do not use Claude Opus. Cluster challengers must be GPT-5.4 or Claude Sonnet 4.6 only.
- Do not restate full worker reasoning.
- If you inspect `optional_files`, record that in `expansion_attempts`.
- If you inspect files outside both `primary_files` and `optional_files`, stay within `exploration_budget.max_out_of_band_files` and record them in `expansion_attempts`.
- Use `open_questions` and `missing_evidence` for unresolved but important doubts.

Output:
- Write raw JSON to `{OUTPUT_PATH}`
- Must follow `contracts/phase2-cluster-output.schema.json`
- Set `stage="challenge"`
- `summary` must be an object, never a string
- Include bounded-brainstorm fields when relevant:
  - `open_questions`
  - `missing_evidence`
  - `expansion_attempts`
