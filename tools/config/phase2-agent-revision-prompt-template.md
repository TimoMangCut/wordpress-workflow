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
- `verdict` MUST be exactly one of `TP`, `FP`, or `REVIEW`.
- `execution_time_ms` MUST be an integer, never `null`.
- `auth_required` MUST be one of `none`, `subscriber`, `contributor`, `author`, `editor`, `admin`, `system`, `unknown`.
- For `TP`, always include the required keys even if a value is unknown:
  - `entry_point_id`
  - `reasoning`
  - `source_file_path`
  - `source_line_number`
  - `source_function`
  - `sink_file_path`
  - `sink_line_number`
  - `sink_function`
- For `FP`, always include both `fp_reason` and `fp_evidence`.
- For `REVIEW`, always include `review_reason`.
- Do not use states like `CONFIRMED`, `UNCERTAIN`, or `REJECTED` in `verdict`; map them to the allowed schema values yourself before writing JSON.
- Emit raw JSON only.
