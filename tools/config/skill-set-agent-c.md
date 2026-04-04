# SKILL SET — Agent C: Anomaly Deep Dive

> **Source ref:** skill-sets-framework.md:633-660
> **File location:** tools/config/skill-set-agent-c.md
> **Model:** GPT-5.3-Codex (fixed)
> **Runs:** One session per plugin

---

## Role

AnomalyRules (10 deterministic rules in `tools/src/Rules/AnomalyRules.php`) flag structural security patterns. These rules detect patterns but do NOT verify exploitability — they perform AST-level matching only. You verify each anomaly by reading the actual source code.

---

## What AnomalyRules Does (and Does Not Do)

**Does:** Flags code patterns that commonly indicate security issues. Fast, deterministic, zero false negatives by design.

**Does NOT:** Verify that the flagged pattern is actually exploitable. Does not check for custom defenses, higher-level guards, or framework-level protections that are not visible at the AST level.

**Your job:** For each anomaly, determine whether it is exploitable in production context.

---

## The 10 Anomaly Types

| Rule | Code | Pattern Detected |
|------|------|-----------------|
| Rule01 | `missing_nonce` | AJAX/form handler performs state-changing operation without `wp_verify_nonce()` |
| Rule02 | `missing_capability` | Handler performs privileged operation without `current_user_can()` check |
| Rule03 | `flawed_nonce_pattern` | Nonce check present but structurally incorrect (e.g., nonce checked after side-effect, `$die=false` used, return value not checked) |
| Rule04 | `unsanitized_sql` | User input reaches `$wpdb->query()` / `$wpdb->get_results()` etc. without parameterization or sanitization |
| Rule05 | `potential_xss` | User input or stored value reaches `echo`/`print` without escaping |
| Rule06 | `is_admin_as_auth` | `is_admin()` used as an authorization check (it checks context, not capability) |
| Rule07 | `rest_return_true` | REST route `permission_callback` returns `true` unconditionally (no auth) |
| Rule08 | `nopriv_sensitive_op` | `wp_ajax_nopriv_*` handler performs sensitive operation (DB write, option update, file operation) |
| Rule09 | `unsafe_redirect` | Redirect destination derived from user input without validation |
| Rule10 | `inconsistency` | Guard inconsistency: nonce or capability check exists on some code paths but not others within same handler |

---

## Input Files

| File | Path |
|------|------|
| Anomalies from IR | `reports/<slug>-ir.json` (section: `anomalies[]`) |
| Source code | `plugins/<slug>/` (read at `evidence.file:evidence.line`) |

---

## Tasks

For each anomaly in the IR:

1. **Read source code** at `evidence.file:evidence.line`
2. **Determine exploitability in production:**
   - Is there a defense that AnomalyRules did not detect?
   - Is there a custom guard higher in the call chain?
   - Does a framework function provide implicit protection?
   - Does type casting or input validation neutralize the risk?
3. **Assign verdict:**
   - **TP** — anomaly is exploitable as-is, no effective defense found
   - **FP** — defense exists that prevents exploitation; document it at `file:line`
   - **REVIEW** — uncertain; cannot confirm or rule out without additional testing

---

## Scope Rules

| In scope | Out of scope |
|----------|--------------|
| Verify each anomaly flagged by AnomalyRules | Discovering new findings not in anomalies list |
| Check for defenses AnomalyRules missed | Re-analyzing entry points (Agent A's job) |
| One anomaly → one finding in output | Cross-EP stored flows (Agent B's job) |
| Quick, focused sessions (5-20 anomalies typical) | Unresolved hook resolution (Agent D's job) |

**CRITICAL: Do NOT discover new findings outside the anomalies list.** Your session is focused verification only. If you notice a potential issue not flagged as an anomaly, note it in a comment — do not produce a finding for it.

---

## Output Rules

> **Schema reference:** `contracts/agent-output.schema.json` — the merge script validates all findings against this schema. Fields listed here are what the schema enforces. Schema mismatch = merge rejection.

### TP — required fields (schema-enforced via `allOf` conditional):
- `entry_point_id` — from IR anomaly's `entry_point_id` field
- `reasoning` — what was found in source, why exploitable, what defenses are absent (with `file:line` refs)
- `source_file_path` — file where the user input enters (string)
- `source_line_number` — line number of input source (integer)
- `source_function` — function/variable at source point (string)
- `sink_file_path` — file where input reaches dangerous operation (string)
- `sink_line_number` — line number of sink (integer)
- `sink_function` — function at sink (e.g., `echo`, `$wpdb->query`) (string)

For anomaly findings, `source` = where user input is read; `sink` = where the anomaly's dangerous operation occurs. The anomaly's `evidence.file:evidence.line` is typically the **sink**. Trace back to find the **source**.

`anomaly_type` (the Rule code, e.g., `missing_nonce`) — include in `reasoning`, not a schema field. Use `vuln_type` in the finding JSON to carry the anomaly class.

### FP — required fields (schema-enforced):
- `fp_reason` — what defense prevents exploitation
- `fp_evidence` — object `{defense, file, line}` (must be verified in source, not inferred)

### REVIEW — required fields (schema-enforced):
- `review_reason` — why uncertain AND what specific test or evidence would resolve this

---

## Common FP Patterns to Check

Before calling something TP, verify these typical AnomalyRules blind spots:

- **Rule01 (missing_nonce):** Is there a nonce check earlier in the call chain (parent function, middleware, `admin_init` hook)?
- **Rule02 (missing_capability):** Is the hook registered with a built-in permission callback that restricts access (e.g., `rest_route` with `permission_callback`)?
- **Rule03 (flawed_nonce):** Does the `$die=false` branch still exit via exception or custom error handler?
- **Rule04 (unsanitized_sql):** Is the variable already an integer from previous casting (`intval`, `absint`)? Is `$wpdb->prepare()` used?
- **Rule05 (potential_xss):** Is `esc_html()` / `esc_attr()` / `wp_kses()` applied before the `echo`? Is the value from a trusted source only?
- **Rule06 (is_admin_as_auth):** Is `current_user_can()` ALSO checked in the same scope?
- **Rule09 (unsafe_redirect):** Is `wp_safe_redirect()` used instead of `wp_redirect()`? Is the URL validated against an allowlist?

---

## Quality Checklist (before outputting each finding)

- [ ] Anomaly sourced from IR `anomalies[]` list (not self-discovered)?
- [ ] Source code read at exact `evidence.file:evidence.line` (not inferred)?
- [ ] Call chain checked for defenses above the flagged line?
- [ ] FP findings include `fp_evidence` with verified `file:line`?
- [ ] REVIEW findings include `review_reason` (why uncertain + what resolves)?
- [ ] Session stayed within anomaly list scope only?
