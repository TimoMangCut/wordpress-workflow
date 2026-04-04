# SKILL SET — Agent D: Unresolved Hooks + Coverage Gaps

> **Source ref:** skill-sets-framework.md:663-706
> **File location:** tools/config/skill-set-agent-d.md
> **Model:** GPT-5.3-Codex (fixed)
> **Runs:** One session per plugin

---

## Role

The IR parser logs `unresolved_hooks` (dynamic hook names it cannot resolve at parse time) and `coverage_gaps` (files containing WordPress security functions but with no associated entry point in the IR). Deterministic code cannot resolve these — you read source code and reason about intent to resolve them.

**Key distinction:** IR-01 fix only LOGS unresolved hooks. Agent D attempts to RESOLVE them by tracing source code.

---

## IR Supplement — Mandatory Output

For every hook you successfully resolve, you MUST write the resolved entry point to:

```
reports/phase1/<slug>-ir-supplement.json
```

The gate loads this file at startup and merges its contents into the validation indexes. Without this file, the gate cannot run `path_reachable`, `guard_consistent`, or hallucination checks on resolved-dynamic findings.

### IR Supplement Format — FULL (required)

```json
{
  "entry_points": [
    {
      "id": "resolved_dynamic:<hash>",
      "type": "<inferred_type>",
      "file": "<registration_file>",
      "line": <registration_line>,
      "callback": {
        "file": "<handler_file>",
        "function": "<handler_function>",
        "line": <handler_line>
      }
    }
  ],
  "sources": [
    {
      "entry_point_id": "resolved_dynamic:<hash>",
      "type": "superglobal_post",
      "variable": "$_POST['field']",
      "file": "<handler_file>",
      "line": <source_line>
    }
  ],
  "sinks": [
    {
      "entry_point_id": "resolved_dynamic:<hash>",
      "category": "output",
      "function": "echo",
      "file": "<handler_file>",
      "line": <sink_line>
    }
  ],
  "guards": [
    {
      "entry_point_id": "resolved_dynamic:<hash>",
      "type": "nonce_check",
      "is_effective": true,
      "file": "<handler_file>",
      "line": <guard_line>
    }
  ]
}
```

**Entry-points-only supplement is INSUFFICIENT.** The gate requires sources, sinks, AND guards to run `path_reachable` and `guard_consistent` checks. A supplement missing these sections will cause the gate to treat the resolved EP as unchecked.

---

## Entry Point ID Format for Resolved Dynamic Hooks

```
resolved_dynamic:<hash>
```

Where `<hash>` = `sha1(file + ':' + line + ':' + hook_literal_resolved)`

- `file` — the file where the dynamic hook is registered (plugin-relative path)
- `line` — the line number of the `add_action()` / `add_filter()` call
- `hook_literal_resolved` — the actual hook name string after resolution (e.g., `wp_ajax_my_action`)

**Example:**
```
sha1("inc/class-admin.php:142:wp_ajax_my_custom_action") → resolved_dynamic:a3f2c1b...
```

Use this ID consistently: in the finding output AND in the IR supplement `entry_point_id` fields.

---

## Input Files

| File | Path |
|------|------|
| Unresolved hooks | `reports/<slug>-ir.json` (section: `unresolved_hooks[]`) |
| Coverage gaps | `reports/<slug>-ir.json` (section: `coverage_gaps[]`) |
| Source code | `plugins/<slug>/` |
| Output schema | `contracts/agent-output.schema.json` |

---

## Tasks

### Task 1: Unresolved Hooks

For each unresolved hook in `unresolved_hooks[]`:

1. **Read source** at logged `file:line`
2. **Trace the dynamic expression:**

   | Pattern | Resolution approach |
   |---------|---------------------|
   | `'wp_ajax_' . $this->action_name` | Find where `$action_name` is assigned (constructor, `init()`, property declaration) |
   | `self::HOOK_ACTION` / `static::HOOK_NAME` | Find constant definition in class body |
   | `$this->get_hook_name()` | Read method body, trace return value |
   | `sprintf('wp_ajax_%s', $slug)` | Find `$slug` assignment |

3. **If resolved:**
   - Analyze like Agent A: trace source → sink, check guards, attempt refutation
   - Compute `resolved_dynamic:<hash>` ID
   - Include finding in output with that ID as `entry_point_id`
   - Write resolved EP to IR supplement (with sources, sinks, guards)
   - State confidence: `high`

4. **If cannot resolve:**
   - Output REVIEW finding with:
     - `review_reason`: "dynamic hook, resolution failed, manual trace required"
     - What you attempted to trace and why it failed
   - State confidence: `low`
   - Do NOT write to IR supplement (no resolved data to emit)

5. **State confidence level** for every hook (numeric `0.0–1.0` in JSON `confidence` field; explain in `reasoning`):
   - `0.9` — found literal assignment; hook name is certain
   - `0.6` — inferred from naming convention or class structure; hook name is probable
   - `0.3` — guessed from context; hook name is uncertain
   - `0.0` — cannot resolve

### Task 2: Coverage Gaps

For each entry in `coverage_gaps[]`:

1. **Determine why** the file has WordPress security functions (`wp_verify_nonce()`, `$wpdb->query()`, etc.) but no associated entry point in the IR:
   - Dead code (never called in production)
   - Template include (called by a registered EP elsewhere)
   - Form handler via `admin_init` hook (not using `wp_ajax_*`)
   - Standalone AJAX not registered via standard hooks
   - Missing from IR due to parser limitation

2. **If vulnerability found:**
   - Output finding with verdict **REVIEW** by default (needs manual confirmation)
   - Explain why the coverage gap exists and why you believe this code is reachable
   - State assumptions explicitly

3. **If no vulnerability:**
   - Output negative finding: "[file] reviewed, no vulnerability — [reason, e.g., dead code or template-only]"

---

## Scope Rules

| In scope | Out of scope |
|----------|--------------|
| Resolving dynamic hook names via source tracing | Full EP analysis for all EPs (Agent A's job) |
| Coverage gap analysis | Cross-EP stored flows (Agent B's job) |
| Writing IR supplement for resolved EPs | Anomaly verification (Agent C's job) |
| 5-15 hooks per session (keep sessions short) | Hooks already resolved in IR |

---

## Output Rules

> **Schema reference:** `contracts/agent-output.schema.json` — the merge script validates all findings against this. Fields listed here match schema enforcement.

### Resolved hook findings — required fields:
- `entry_point_id`: `resolved_dynamic:<hash>` (computed per formula above)
- `confidence`: numeric `0.0–1.0` per schema (`"type": "number", "minimum": 0, "maximum": 1`)
  - Use `0.9` for high confidence (literal assignment found)
  - Use `0.6` for medium confidence (inferred from naming/structure)
  - Use `0.3` for low confidence (guessed from context)
  - Include human-readable confidence assessment in `reasoning` (e.g., "Confidence: high — found literal assignment at constructor:14")
- Standard TP/FP/REVIEW fields depending on vulnerability verdict (see TP requirements below)

**TP resolved hook findings** additionally require (schema `allOf` conditional):
- `source_file_path`, `source_line_number`, `source_function`
- `sink_file_path`, `sink_line_number`, `sink_function`
- `reasoning`

### Unresolved hook findings — required fields:
- `entry_point_id`: can use `unresolved:<file>:<line>` format (no supplement entry)
- `confidence`: `0.0` (cannot resolve = lowest confidence)
- `review_reason`: "dynamic hook, resolution failed, manual trace required" + what was attempted

### Coverage gap findings:
- Default verdict: **REVIEW**
- `confidence`: numeric, typically `0.3`–`0.5` (lower confidence by nature)
- Must include: why the gap exists, why code is (or might be) reachable, assumptions stated explicitly

---

## Quality Checklist (before outputting each finding)

- [ ] Resolved hook ID uses `resolved_dynamic:<hash>` format with correct hash inputs?
- [ ] IR supplement written with FULL format (entry_points + sources + sinks + guards)?
- [ ] Confidence is numeric `0.0–1.0` (not string labels: high=0.9, medium=0.6, low=0.3, unresolved=0.0)?
- [ ] Unresolved hooks output REVIEW with `review_reason`?
- [ ] Coverage gap findings default to REVIEW with explicit assumptions?
- [ ] Sessions limited to 5-15 hooks (short and focused)?
- [ ] Assumptions stated explicitly — no context gaps filled with guessing?
