# Phase 2 Reviewer Explore Loop - `{PLUGIN_SLUG}` - Round `{ROUND_NUMBER}`

Read reviewer input JSON first:
- Reviewer input: `{REVIEWER_INPUT_PATH}`

Execution rules:
1. Follow `task.role`, `task.goal`, and `task.constraints` from the input JSON.
2. Treat `worker_findings` as the current coverage map. `finding_packets` may be empty by design in this stage.
3. Treat this round as a bounded second-pass over Codex coverage gaps, not a fresh plugin-wide audit.
4. Start from `phase1_context.top_anomalies`, `phase1_context.unresolved_hooks`, top-level `evidence.primary_anchors`, `evidence.primary_snippets`, existing `worker_findings`, and any already-recorded `open_questions` or `missing_evidence` in the input before opening arbitrary files.
5. Use `evidence.optional_evidence`, `phase1_context.related_entry_points`, and `threat_context_summary` only to test one of these bounded blind spots:
   - second-order or deferred sink behavior around an already-cited sink family
   - hidden guard, activation, preload, or runtime-registration conditions around an already-cited entry path
   - concrete source/sink anchors that IR/AST/SAST or worker coverage hinted at but did not fully localize
   - a specific file/anchor adjacency that could materially change an existing coverage conclusion
6. Do not restart whole-plugin hunting from raw IR/AST/SAST signals. Those signals may only be used when they sharpen an already-bounded lead from the current input.
7. Every extra file open must answer a concrete question tied to an existing lead, current finding, anomaly, hook, or missing-evidence note.
8. If a candidate is already covered by existing worker/core output, record that as duplicate coverage instead of re-auditing the same path.
5. Respect `task.max_candidates` as the hard cap for `missed_findings[]`.
9. Do not relitigate the existing finding set unless you need to explain why a candidate is already covered or why a bounded blind-spot check materially changes confidence.
10. This is the only reviewer stage that may emit `missed_findings[]`.
11. Once the bounded leads are exhausted and no stronger uncovered path remains, write the JSON immediately instead of reopening more surfaces.

Output rules:
- Write raw JSON only.
- Output path: `{REVIEW_OUTPUT_PATH}`
- Match the schema referenced by `task.output_schema`.
- `summary` must be an object, never a string.
- Keep all plugin file paths relative to the plugin root.
- `missed_findings[]` must stay concrete and evidence-bound.
