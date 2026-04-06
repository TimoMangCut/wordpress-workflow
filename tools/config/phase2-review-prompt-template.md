# Phase 2 Reviewer Core Loop - `{PLUGIN_SLUG}` - Round `{ROUND_NUMBER}`

Read reviewer input JSON first:
- Reviewer input: `{REVIEWER_INPUT_PATH}`

Execution rules:
1. Follow `task.role`, `task.goal`, and `task.constraints` from the input JSON.
2. Treat each item in `finding_packets` as one claim packet. Review packet-by-packet, not plugin-wide.
3. For each packet, explicitly answer its `review_questions.reachability`, `authorization`, `dataflow`, `impact`, and `missing_evidence` before writing the corresponding `finding_reviews[]` item.
4. Start from the packet's `review_focus`, `worker_context`, `anchors`, `primary_snippets`, and `optional_snippets` before opening any file. Treat `worker_context.reasoning_excerpt` as the packet-local reviewer brief; only consult `worker_context.original_*` if you need to understand the worker's original claim wording.
5. Treat `scope_policy.allowed_primary_files` as the default scope, `scope_policy.allowed_optional_files` as the only preferred expansion scope, and `scope_policy.max_out_of_band_files` as a hard cap for any out-of-band file opens.
6. If packet-local evidence is still insufficient, return `needs_more_evidence` instead of exploring for new findings.
7. Do not reopen `artifacts.worker_output_path` during core review unless the packet data is internally inconsistent and the path is present.
8. Do not use `artifacts.ir_path`, `artifacts.semgrep_path`, `artifacts.psalm_path`, or `artifacts.threat_context_path` to restart whole-plugin hunting.
9. Do not inspect translation files, asset bundles, vendor-style dependency trees, or unrelated plugin surfaces during core review.
10. Keep review bounded and evidence-first. Prefer refutation, field fixes, precise counter-evidence, and explicit missing-evidence notes over rewriting the findings set.
11. Obey `review_focus.stop_conditions` and `review_focus.disallowed_drift`. If `review_focus.sink_semantics` says the packet ends at hook dispatch, JSON response handling, or guard logic, do not compensate by expanding into whole-plugin tracing.
12. `missed_findings[]` is not part of the core output contract. Do not invent or emit it in this round.
13. Emit exactly one `finding_reviews[]` item per packet. Copy the packet's `packet_id`, keep `finding_id` aligned to the packet's `parent_finding_id`, and populate both `missing_evidence[]` and `expansion_attempts[]` even when they are empty.

Output rules:
- Write raw JSON only.
- Output path: `{REVIEW_OUTPUT_PATH}`
- Match the schema referenced by `task.output_schema`.
- `summary` must be an object, never a string.
- Keep all plugin file paths relative to the plugin root.
