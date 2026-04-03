# Phase 2 Deep Analysis - `{PLUGIN_SLUG}`

Inputs:
- Phase 1 IR: `reports/phase1/{PLUGIN_SLUG}-ir.json`
- Semgrep: `reports/phase1/{PLUGIN_SLUG}-semgrep.json` (if exists)
- Psalm SARIF: `reports/phase1/{PLUGIN_SLUG}-psalm.sarif` (if exists, corroboration signal)
- Source code: `plugins/{PLUGIN_SLUG}/`

Task:
1. Read IR map first, then verify directly in source code.
2. Prioritize high-value targets:
   - unauth/subscriber entry points
   - SQL/file/redirect/include/deserialization sinks
   - anomalies high/critical
3. Validate every candidate using source->sink trace with exact file:line.
4. Refute-first:
   - check nonce/capability guards
   - check sanitizer/prepare correctness
   - check realistic exploitability
5. Keep only meaningful findings (Patchstack-oriented impact).
6. Unresolved Hooks: check `ir.unresolved_hooks[]` for dynamic hook registrations.
   - For each entry, inspect the surrounding source code at `file:line` to determine the hook name value at runtime.
   - Pay special attention to `hook_arg_type=concatenation`: common dangerous patterns include
     `'wp_ajax_nopriv_' . $action` (unauthenticated AJAX), `'wp_ajax_' . $action` (subscriber AJAX),
     and REST namespace concatenation (`$namespace . '/route'`). These are the highest-value targets
     per wp-context (REST API = single most critically exploited surface; wp_ajax_nopriv = zero auth).
   - If the hook resolves to a security-relevant hook, attempt to trace its callback for missing nonce/cap checks.
   - If the hook name cannot be determined statically, note it in `negative_findings` with reason `dynamic_hook_unresolved`.
7. Coverage Gaps: check `ir.coverage_gaps[]` for files that contain WP security signals but no discovered entry point.
   - Each entry has: `file` (plugin-relative path), `signals[]` (list of detected signal strings), `reason` (`has_security_functions_but_no_entry_point`).
   - For each gap entry, inspect the file at `file` to determine whether it is a missed entry point (e.g., a class loaded via `add_action` in a bootstrap file not yet traced) or a helper/utility file called from a known entry point.
   - If the file appears to be a missed entry point (direct hook registration, direct AJAX handler, direct REST handler), attempt to trace its inputs for missing nonce/cap checks and add findings accordingly.
   - If the file is a helper called from a known entry point already in IR, note it in `negative_findings` with reason `coverage_gap_helper_not_entry_point`.
   - If the file's role cannot be determined statically, note it in `negative_findings` with reason `coverage_gap_unresolved`.

Output format (strict):
- Write JSON to: `{OUTPUT_PATH}`
- Include top-level fields:
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

Finding requirements:
- Each TP/REVIEW must include:
  - finding_id
  - verdict (TP|FP|REVIEW)
  - vuln_type
  - cwe_id
  - severity
  - auth_required
  - confidence
  - entry_point_id
  - source_function
  - sink_function
  - source_file_path + source_line_number
  - sink_file_path + sink_line_number
  - file_path + line_number (alias of sink path/line)
  - reasoning (hypothesis, trace, defenses, refutation, conclusion)
  - poc_description
  - cvss_vector (or null)
  - remediation
  - patchstack_eligible
- For stored/second-order flows: include storage_key when identifiable.
- All `source_file_path`, `sink_file_path`, and `file_path` values must be relative to the plugin root. Never prefix them with `plugins/{PLUGIN_SLUG}/`.
- For FP verdict (MANDATORY — no exceptions):
  - fp_reason: one sentence explaining what specific defense makes this not exploitable
  - fp_evidence: {"defense": "<type>", "file": "<plugin-relative path>", "line": <int>}
  - Allowed defense types: no_user_input_reachable | sanitized_before_sink | hardcoded_value | internal_call_only | capability_required_enforced | nonce_enforced | dead_code | other

Important:
- Do not invent constants, nonces, routes, capability strings, option/meta keys.
- If evidence is insufficient, mark as REVIEW (not TP).
