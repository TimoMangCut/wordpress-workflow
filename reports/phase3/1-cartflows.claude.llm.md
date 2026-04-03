# Phase 3b LLM Skeptic Review — `cartflows`

_Reviewer role: SKEPTIC — searching for counter-evidence against Phase 2 conclusions._
_Review date: 2026-04-02_
_Plugin version: 2.2.4_

---

## 1. Plugin Overview

CartFlows 2.2.4 is a WooCommerce funnel-builder plugin providing custom checkout pages, order-bump upsells, opt-in flows, and thank-you pages. It ships 119 AJAX/REST/init entry points across 333 PHP files (104 k LOC). Its public attack surface is intentionally narrow: guest-facing checkout helpers that operate inside the caller's WooCommerce session, and administrator-or-capability-gated REST/AJAX surfaces for flow and settings management. The plugin also includes a bundled WordPress Abilities API layer (42 abilities, write-gated by a default-off option) and a NPS survey library with its own REST routes.

---

## 2. Validation Summary

| Metric | Count |
|---|---|
| Phase 3a PLAUSIBLE findings reviewed | 0 |
| Phase 3a UNCERTAIN findings reviewed | 0 |
| Downgraded | 0 |
| Kept | 0 |
| Upgraded | 0 |

**Phase 3a `validated_findings` is empty.** Phase 2 produced no true-positive or REVIEW findings — `findings: []`. There is nothing within the skeptic reviewer's mandatory scope (PLAUSIBLE / UNCERTAIN) to challenge.

---

## 3. Detailed Reviews

_None. No PLAUSIBLE or UNCERTAIN findings were produced by the deterministic gate (Phase 3a). Per the task constraint, the skeptic reviewer only challenges findings that Phase 3a marked PLAUSIBLE or UNCERTAIN._

---

## 4. Negative Findings — Independent Verification Pass

The skeptic's role is to find reasons findings might be **wrong**. With no findings to attack, the skeptic's independent value-add is to verify that the zero-finding outcome was not a Phase 2 coverage failure. The following surfaces were independently spot-checked against actual source code.

### 4.1 `nopriv` AJAX Handlers (7 hooks)

**Hooks checked:**
- `wp_ajax_nopriv_wcf_woo_apply_coupon`
- `wp_ajax_nopriv_wcf_woo_remove_coupon`
- `wp_ajax_nopriv_wcf_woo_remove_cart_product`
- `wp_ajax_nopriv_wcf_check_email_exists`
- `wp_ajax_nopriv_wcf_woocommerce_login`
- `wp_ajax_nopriv_wcf_upload_checkout_file`
- `wp_ajax_nopriv_<WP_Async_Request::identifier>` (bundled Action Scheduler library)

**Skeptic challenge:** Could any of these be reached by a lower-privileged actor to mutate state beyond the caller's own session?

**Verdict: No new signal.** All five checkout-specific handlers are intentionally public for guest checkout UX. Each is session-scoped to `WC()->cart` or operates on standard WordPress authentication (`wp_signon()`). The file-upload handler enforces a hardcoded extension allowlist (no scriptable/executable types) and UUID-based filename generation. The bundled `WP_Async_Request::maybe_handle()` uses `check_ajax_referer( $this->identifier, 'nonce' )` without the `false` flag — meaning it calls `wp_die()` on nonce failure rather than continuing. This surface is self-contained to the background-process loopback pattern and is not reachable by an external attacker without a valid server-generated nonce.

**Secure because:** All handlers nonce-gate before reaching state-changing sinks; public routes are session-scoped with no cross-user mutation path; file upload is extension/MIME constrained.

### 4.2 REST Routes — Permission Callback Coverage (9 route files)

**Files checked:**
- `admin-core/api/home-page.php` — `get_items_permissions_check()` on both routes
- `admin-core/api/step-data.php` — `get_item_permissions_check()`
- `admin-core/api/common-settings.php` — requires `cartflows_manage_settings`
- `admin-core/api/webhooks.php` — requires `cartflows_manage_settings`
- `admin-core/api/product/product-data.php` — `get_item_permissions_check()`
- `admin-core/api/flows.php` — `get_items_permissions_check()` / `update_items_permissions_check()`
- `admin-core/api/flow-data.php` — `get_item_permissions_check()`
- `admin-core/api/learn.php` — `get_item_permissions_check()`
- `libraries/nps-survey/classes/nps-survey-script.php` — `manage_options` on both routes

**Skeptic challenge:** Does any `register_rest_route()` call omit `permission_callback` or use `__return_true`?

**Verdict: No omissions or open callbacks found.** Every `register_rest_route()` call in the plugin carries an explicit `permission_callback`. The NPS survey library — a third-party bundle that is a common source of open REST routes — uses `current_user_can( 'manage_options' )` (line 251 of `nps-survey-script.php`). The nonce for the NPS survey is also only localized when `current_user_can( 'manage_options' )` returns true (line 158).

**Secure because:** All REST routes enforce capability checks via explicit permission callbacks; no `__return_true` or missing callbacks were found.

### 4.3 Semgrep `check_ajax_referer(..., false)` Cluster

**Skeptic challenge:** Phase 2 (NEG-006) claimed all `check_ajax_referer(..., false)` handlers still fail closed. Is there any handler the Phase 2 review missed?

**Verification:** The grep of admin AJAX files (`admin-core/ajax/`) confirms the presence of nonce-check-then-return patterns in `common-settings.php` (line 113), `flows.php` (line 92), `class-cartflows-admin-notices.php` (line 179), and the SureTriggers compatibility class (line 127). No new handler was found where the false-return from `check_ajax_referer` is silently ignored before a state-changing sink.

**Secure because:** In every reviewed handler, the `false` return is checked and triggers `wp_send_json_error()` before the sensitive code path is reached.

---

## 5. Overall Assessment

**No findings to downgrade, keep, or upgrade.**

Phase 3a deterministic gate produced zero PLAUSIBLE or UNCERTAIN items. Phase 2's conclusion — that CartFlows 2.2.4 has no Patchstack-eligible findings after direct source validation — survives independent skeptic scrutiny.

The independent verification pass covered the seven `nopriv` AJAX entry points, all nine REST route registration files, and the Semgrep nonce-bypass signal cluster. No new signals were identified. Every public surface is either session-scoped to the caller, nonce-gated, extension-constrained, or protected by a capability check that requires explicit administrator delegation.

**Residual watch items (not findings):**

1. **Role-manager delegation (NEG-004 reopen condition):** If an administrator deliberately grants CartFlows capabilities to a lower role, those actors gain access to flow/settings mutation surfaces. This is by design, but any future review of a site with non-default role assignments should re-examine these surfaces with the delegated role's actual capability set.

2. **`wcf_check_email_exists` account enumeration (NEG-002 reopen condition):** The public checkout endpoint discloses whether an email address has a WordPress account. This is an intentional UX feature. On sites where account-existence disclosure is a compliance concern (e.g., GDPR Article 5), this warrants a site-level policy discussion rather than a plugin fix.

3. **WordPress Abilities API write gate:** The `get_option('cartflows_abilities_api_write')` flag defaults to off. If a future version changes this default or adds a UI toggle that is too easily reachable, the 42 write-capable abilities should be re-audited against the capability requirements in `class-cartflows-ability-runtime.php`.
