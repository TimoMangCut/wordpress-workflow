# Phase 2 Terminal Core Review - `{PLUGIN_SLUG}` - Round `{ROUND_NUMBER}`

Read reviewer input JSON first:
- Reviewer input: `{REVIEWER_INPUT_PATH}`

Execution rules:
1. Follow `task.role`, `task.goal`, and `task.constraints` from the input JSON.
2. Treat each item in `finding_packets` as one surviving unresolved packet from the prior core review. This round exists only to close those packets.
3. For each packet, explicitly answer its `review_questions.reachability`, `authorization`, `dataflow`, `impact`, and `missing_evidence` before writing the corresponding `finding_reviews[]` item.
4. Start from the packet's `review_focus`, `worker_context`, `anchors`, `primary_snippets`, and `optional_snippets` before opening any file.
5. Stay within `scope_policy.allowed_primary_files` by default, prefer `scope_policy.allowed_optional_files` for any expansion, and respect `scope_policy.max_out_of_band_files` as a hard cap.
6. This is the terminal core round. Do not emit `needs_more_evidence`, do not preserve `REVIEW`, and do not leave packet closure undecided.
7. Every `finding_reviews[]` item must include `closure_verdict` and it must be either `TP` or `FP`.
8. If bounded packet-local review still cannot prove exploitability, close the packet as `FP` and use `missing_evidence[]` to state concrete reopen conditions.
9. Do not turn this round into exploration or a broad re-audit of the plugin.
10. Do not emit `missed_findings[]` in this round.
11. Emit exactly one `finding_reviews[]` item per packet. Copy the packet's `packet_id`, keep `finding_id` aligned to the packet's `parent_finding_id`, and populate both `missing_evidence[]` and `expansion_attempts[]` even when they are empty.

Output rules:
- Write raw JSON only.
- Output path: `{REVIEW_OUTPUT_PATH}`
- Match the schema referenced by `task.output_schema`.
- `summary` must be an object, never a string.
- Keep all plugin file paths relative to the plugin root.
