# Phase 2 Worker Revision - `{PLUGIN_SLUG}` - Round `{ROUND_NUMBER}`

Inputs:
- Revision input: `{REVISION_INPUT_PATH}`
- Phase 1 IR: `reports/phase1/{PLUGIN_SLUG}-ir.json`
- Semgrep: `reports/phase1/{PLUGIN_SLUG}-semgrep.json` (if exists)
- Psalm SARIF: `reports/phase1/{PLUGIN_SLUG}-psalm.sarif` (if exists)
- Threat context: `{THREAT_CONTEXT_PATH}` (if exists)
- Previous worker output: `{PREVIOUS_WORKER_OUTPUT_PATH}`
- Reviewer critique: `{REVIEW_OUTPUT_PATH}`
- Source code: `plugins/{PLUGIN_SLUG}/`

Role:
- You are the Phase 2 worker revising your prior output after reviewer critique.
- You MUST respond to the reviewer critique through code evidence, not rhetoric.
- Your output is a complete replacement Phase 2 JSON.

Task:
1. Read `Revision input` JSON first and use `revision_targets[]` as the primary worklist.
2. Only reopen `Previous worker output` or `Reviewer critique` if the grouped revision input is internally inconsistent.
3. Process each target finding in `revision_targets[]`.
4. For each objection:
   - accept it and revise the finding, or
   - reject it with stronger code evidence in the revised finding reasoning.
5. Preserve untouched findings unless direct source evidence now contradicts them.
6. If `review_mode` is `explore` or `forced_exploration`, treat `missed_findings[]` as the primary task:
   - investigate each candidate directly in source,
   - add a new finding only when the code path is real,
   - otherwise add a concise negative finding or refutation note instead of inventing a new issue.
7. Incorporate valid `missed_findings[]` when source code confirms them.
8. Remove or downgrade findings when the reviewer found real counter-evidence.
9. Keep the final artifact evidence-bound and Patchstack-oriented.

Output format (strict):
- Write full Phase 2 JSON to: `{OUTPUT_PATH}`
- Preserve the standard Phase 2 structure:
  - plugin_slug
  - analysis_summary
  - overall_risk
  - total_findings_analyzed
  - true_positives
  - false_positives
  - needs_review
  - findings[]
  - negative_findings[]
  - out_of_scope[]

Additional requirements:
- Do not restart a whole-plugin audit. Default to the files and anchors implied by each `revision_targets[]` entry before opening anything else.
- Each revised finding reasoning should mention how the reviewer objection was resolved when relevant.
- Do not invent routes, capabilities, or option keys.
- Keep all paths relative to plugin root.
- If the reviewer objection is correct and evidence is insufficient, downgrade to REVIEW or FP as appropriate.
