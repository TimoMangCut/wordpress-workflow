---
name: wp-security-audit
description:
  WordPress plugin/theme security audit methodology for SAST and multi-phase reasoning.
  Use for audit, exploitability review, Patchstack scope triage, and evidence-based validation.
---

# WP Security Audit Skill (Project Local, EN)

## Language Variants

- Active (English): `SKILL.md`
- Vietnamese version: `SKILL.vi.md`

When this skill is active, also load:

- `references/wp-context.md`
- `references/patchstack-rules.md`

## 1) Core Method

Follow this order:

1. Map attack surface (entry points, auth, guards, sources, sinks)
2. Build source-to-sink trace with file:line evidence
3. Validate defenses (nonce/capability/sanitizer/prepare/ownership)
4. Refute-first reasoning
5. Assess real exploitability and impact
6. Apply Patchstack scope filters

## 2) Entry Point Coverage

Always include:

- REST routes: `register_rest_route`, `permission_callback`, ownership checks
- AJAX hooks: `wp_ajax_*`, `wp_ajax_nopriv_*`
- `admin_post_*`
- Shortcodes and block `render_callback`
- Import/export handlers
- Webhook/cron handlers reachable via user influence

## 3) Source and Sink Rules

### Sources

- `$_GET`, `$_POST`, `$_REQUEST`, `$_COOKIE`, `$_FILES`
- REST params/body/json (`get_param`, `get_json_params`, etc.)
- Shortcode/block attributes
- Stored values with tainted origin (`get_option`, `get_post_meta`, etc.)

### Sinks

- SQL (`$wpdb->query/get_results/get_var/get_row/get_col`)
- HTML/attribute/URL output
- File write/read/include operations
- `include`/`require`
- Redirects
- Deserialization (`unserialize`, `maybe_unserialize`)
- Outbound HTTP (`wp_remote_*`)

## 4) WordPress-Specific Critical Notes

- `is_admin()` is not a role/capability check.
- `admin_init` can still be reached by low-privileged users.
- REST JSON body is not processed by `wp_magic_quotes()`.
- `check_ajax_referer(..., false)` does not stop execution by itself.
- `wp_redirect()` should usually be followed by `exit;`.

## 5) Finding Quality Gates

Keep a finding only when:

- Source-to-sink trace is complete and verifiable
- Security impact is measurable
- Minimum required role and conditions are explicit
- Refutation attempt failed to disprove the issue

If evidence is incomplete:

- Mark as `REVIEW` or `Needs Dynamic Verification`
- Do not force `TP`

## 6) Patchstack Scope Discipline

Reject or mark out-of-scope when applicable:

- Admin-only with negligible impact
- Very low severity/non-exploitable behavior
- Captcha bypass / CSV injection / low-grade race cases outside scope threshold

## 7) Phase Alignment

### Phase 2

- Validate and normalize `phase2.json` in an evidence-bound format.
- Preserve ambiguity as `REVIEW`.

### Phase 3

- Deterministic gate is authoritative.
- LLM only performs skeptic review for `PLAUSIBLE/UNCERTAIN`.

## 8) Output Discipline

- No TODO-list output
- No generic claims
- Every conclusion must be backed by concrete code evidence
