# Phase 2 Cluster Synthesis — `{PLUGIN_SLUG}` — `{CLUSTER_ID}`

Read the evidence pack JSON at `{CLUSTER_PACK_PATH}` first.

Role:
- You are the cluster synthesizer.
- Your job is to reason only across the compact cluster input, not to reread all worker prose.

Goal:
- Decide whether the listed member findings compose into a stronger cross-bundle hypothesis, or should stay separate.
- You may brainstorm beyond the obvious links, but only within the exploration budget declared in the JSON input.

Allowed evidence:
- Start with `shared_context.primary_anchors`, `shared_context.primary_files`, and `evidence_pack.primary_snippets` from `{CLUSTER_PACK_PATH}`
- If that is insufficient, you may expand into `shared_context.optional_files` and `evidence_pack.optional_snippets` within the JSON budget
- Source code under `plugins/{PLUGIN_SLUG}/`, but only when needed to validate those anchors

Hard constraints:
- Stay bounded to the cluster evidence pack.
- Do not reopen the whole plugin.
- Do not restate full worker reasoning.
- Prefer refutation over inflation.
- Use exact file:line anchors when possible.
- If you open `optional_files`, record that in `expansion_attempts`.
- If you inspect files outside both `primary_files` and `optional_files`, stay within `exploration_budget.max_out_of_band_files` and record them in `expansion_attempts`.
- Use `open_questions` and `missing_evidence` instead of forcing premature true/false answers.

Output:
- Write raw JSON to `{OUTPUT_PATH}`
- Must follow `contracts/phase2-cluster-output.schema.json`
- Set `stage="synthesis"`
- `summary` must be an object, never a string
- Include bounded-brainstorm fields when relevant:
  - `open_questions`
  - `missing_evidence`
  - `expansion_attempts`
