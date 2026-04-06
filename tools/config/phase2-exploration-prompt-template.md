# Phase 2 Reviewer Explore Loop - `{PLUGIN_SLUG}` - Round `{ROUND_NUMBER}`

Read reviewer input JSON first:
- Reviewer input: `{REVIEWER_INPUT_PATH}`

Execution rules:
1. Follow `task.role`, `task.goal`, and `task.constraints` from the input JSON.
2. Treat `worker_findings` as the current coverage map. `finding_packets` may be empty by design in this stage.
3. Start from `phase1_context.top_anomalies`, `phase1_context.unresolved_hooks`, top-level `evidence.primary_anchors`, and `evidence.primary_snippets` before opening arbitrary files.
4. Use `evidence.optional_evidence`, `phase1_context.related_entry_points`, and `threat_context_summary` only to extend one step beyond those leads and avoid duplicate coverage.
5. Respect `task.max_candidates` as the hard cap for `missed_findings[]`.
6. Do not relitigate the existing finding set unless you need to explain why a candidate is already covered.
7. This is the only reviewer stage that may emit `missed_findings[]`.
8. Once the bounded leads are exhausted and no stronger uncovered path remains, write the JSON immediately instead of reopening more surfaces.

Output rules:
- Write raw JSON only.
- Output path: `{REVIEW_OUTPUT_PATH}`
- Match the schema referenced by `task.output_schema`.
- `summary` must be an object, never a string.
- Keep all plugin file paths relative to the plugin root.
- `missed_findings[]` must stay concrete and evidence-bound.
