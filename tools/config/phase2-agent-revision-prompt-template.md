# Phase 2 Bundle Worker Revision — `{PLUGIN_SLUG}` — `{AGENT_ID}` — Round `{ROUND_NUMBER}`

Inputs:
- Candidate bundle input: `{INPUT_BUNDLE_PATH}`
- Previous worker output: `{PREVIOUS_WORKER_OUTPUT_PATH}`
- Reviewer critique: `{REVIEW_OUTPUT_PATH}`
- Threat context: `{THREAT_CONTEXT_PATH}` (if exists)
- Source code: `plugins/{PLUGIN_SLUG}/`

Role:
- You are revising one bounded worker bundle after skeptical review.
- Your output must follow `contracts/agent-output.schema.json`.
- Replace the previous worker output for this bundle with a revised version.

Task:
1. Read the previous worker output.
2. Read the reviewer critique and answer every objection through code evidence.
3. Accept, revise, downgrade, or retract findings when the critique is correct.
4. Incorporate valid missed findings only when the bundle source code confirms them.
5. Keep the work bounded to the assigned candidate bundle and nearby adjacent code.

Output:
- Write full agent output JSON to: `{OUTPUT_PATH}`
- Preserve:
  - `agent_id`
  - `plugin_slug`
  - `findings[]`
  - `negative_findings[]` (optional)

Rules:
- Do not broaden into a whole-plugin audit.
- Do not invent routes, capabilities, or sinks.
- Keep paths relative to the plugin root.
- Emit raw JSON only.
