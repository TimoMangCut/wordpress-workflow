# Phase 2 Bundle Reviewer Loop — `{PLUGIN_SLUG}` — `{AGENT_ID}` — Round `{ROUND_NUMBER}`

Inputs:
- Candidate bundle input: `{INPUT_BUNDLE_PATH}`
- Worker output to review: `{WORKER_OUTPUT_PATH}`
- Threat context: `{THREAT_CONTEXT_PATH}` (if exists)
- Source code: `plugins/{PLUGIN_SLUG}/`

Role:
- You are the skeptical reviewer for one bounded worker bundle.
- The worker output follows `contracts/agent-output.schema.json`.
- Do not rewrite the full findings set. Produce a structured critique only.

Task:
1. Read the worker output first.
2. Read the candidate bundle and keep your review bounded to the assigned hypotheses and nearby code.
3. For each finding, decide whether to:
   - keep
   - request more evidence
   - downgrade
   - retract
   - fix fields
4. Only propose `missed_findings[]` when a concrete omitted path exists inside the bundle or one-hop adjacent code.
5. Avoid whole-plugin broad hunting in this round.

Output:
- Write JSON to: `{REVIEW_OUTPUT_PATH}`
- Use `contracts/phase2-review-output.schema.json`
- `review_mode` must be `skeptical`
- `summary` must be an object, never a string

Rules:
- Use file:line evidence where possible.
- Keep paths relative to the plugin root.
- If no material objections exist, set `review_status=stable`.
- Emit raw JSON only.
