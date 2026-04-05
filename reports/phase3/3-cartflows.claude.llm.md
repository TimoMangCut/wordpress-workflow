# Phase 3b LLM Skeptic Review — CartFlows

**Reviewer:** Claude (Anthropic)
**Plugin:** CartFlows v2.2.2
**Review date:** 2026-04-05
**Input findings:** 6 UNCERTAIN (0 PLAUSIBLE)
**Plugin root:** `plugins/cartflows/`

---

## 1. Plugin Overview

CartFlows is a WooCommerce-based checkout funnel builder for WordPress. It introduces a custom post type (`cartflows_step`), a set of unauthenticated and authenticated AJAX handlers for checkout interactions (file upload, email lookup, coupon management), a Gutenberg block that renders the checkout form via `do_shortcode('[cartflows_checkout]')`, and a localization pipeline that emits nonces and configuration values into all checkout page visitors' JavaScript context.

The attack surface reviewed focuses on:
- Two unauthenticated/any-user AJAX file-upload handlers (`wcf_upload_checkout_file`)
- One unauthenticated email-enumeration handler (`wcf_check_email_exists`)
- One LFI candidate via the Gutenberg block's `layout` attribute reaching an `include` statement
- Two duplicate/overlapping file-upload findings with code-evidence errors

---

## 2. Validation Summary

| Metric | Count |
|--------|-------|
| Findings reviewed | 6 |
| **Downgraded** | **2** (cf-c-anom_5, cf-c-anom_35) |
| **Kept UNCERTAIN** | **4** (cartflows-a1-001, cartflows-a1-002, agent-a2-f22, agent-a4) |
| Upgraded | 0 |
| Field corrections issued | 5 findings |

---

## 3. Detailed Reviews

---

### Finding ID: `cartflows-a1-001`
**Type:** Arbitrary File Upload
**Minimum Role/Capability:** None (unauthenticated)
**Status Transition:** `UNCERTAIN → keep`

**Description:** The `wp_ajax_nopriv_wcf_upload_checkout_file` hook registered at `checkout-ajax.php:58` fires for all unauthenticated visitors. `upload_checkout_file()` at `:293` has no capability check and, when `field_key` and `checkout_id` are absent, `get_field_restrictions()` returns an empty extension list (`:363-364`) causing fallback to the full master allowlist at `:319-321`.

**Highest Impact:** Any unauthenticated visitor who loads a CartFlows checkout page can upload attacker-controlled media and document files (jpg, pdf, mp4, etc.) into `wp-content/uploads`, obtaining a persistent public URL on the victim site usable for phishing or malware distribution.

**PoC:**
1. **Setup:** Install CartFlows, create one checkout step (public), configure WooCommerce.
2. **Activate plugin:** CartFlows checkout page is live at its permalink.
3. **Attack:** Load checkout page, extract `cartflows.wcf_file_upload_nonce`; POST to `/wp-admin/admin-ajax.php` with `action=wcf_upload_checkout_file`, `security=<nonce>`, `wcf_checkout_file=@evil.pdf`; omit `field_key` and `checkout_id`.
4. **Verify impact:** JSON response contains `data.url` pointing to a publicly accessible file in `wp-content/uploads/`.

**Counter-evidence:**
- `modules/checkout/classes/class-cartflows-checkout-ajax.php:295` — `check_ajax_referer('wcf-file-upload','security',false)` + `wp_send_json_error()` on failure terminates execution. Effective CSRF guard; not an access-control boundary because the nonce is emitted to all checkout visitors at `checkout-markup.php:1776`.
- `modules/checkout/classes/class-cartflows-checkout-ajax.php:331` — `wp_check_filetype_and_ext()` + master allowlist at `classes/class-cartflows-helper.php:1934` (`jpg,jpeg,png,gif,webp,ico,pdf,mp3,m4a,wav,mp4,m4v,mov`). PHP/script execution blocked; this is not RCE.
- `modules/checkout/classes/class-cartflows-checkout-markup.php:1804` — `has_file_field` detection loop: client-side UI guard only; no server-side gate on the AJAX handler.

**Dynamic test plan:**
1. Load any CartFlows checkout page without a session; extract `cartflows.wcf_file_upload_nonce`.
2. POST `action=wcf_upload_checkout_file`, `security=<nonce>`, `wcf_checkout_file=@test.pdf` (omit `field_key`/`checkout_id`) to `/wp-admin/admin-ajax.php`.
3. Expect 200 JSON success with `data.url` → publicly accessible file confirms the finding.
4. Repeat with `.php` extension to confirm RCE is blocked by allowlist.
5. Repeat with `field_key=bad&checkout_id=0` to confirm fallback to master allowlist when context is invalid.

---

### Finding ID: `cartflows-a1-002`
**Type:** Broken Access Control
**Minimum Role/Capability:** None (unauthenticated)
**Status Transition:** `UNCERTAIN → keep`

**Description:** `wp_ajax_nopriv_wcf_check_email_exists` registered at `checkout-ajax.php:54` fires for all unauthenticated users; `check_email_exists()` at `:205` calls `email_exists($email_address)` at `:211` and returns a binary `success` flag plus distinct human-readable messages (`'Email Exist.'` vs `'Email not exist'`) at `:214-216` via `wp_send_json_success()` at `:219`. The nonce `check-email-exist` is emitted unconditionally at `checkout-markup.php:1772`; no rate-limiting or response normalization exists in the handler.

**Highest Impact:** Any unauthenticated visitor who reaches a CartFlows checkout page can enumerate registered WordPress/WooCommerce customer emails at scale, reducing the cost of credential-stuffing attacks and enabling targeted phishing against site customers.

**PoC:**
1. **Setup:** Install CartFlows; have at least one WooCommerce customer account registered.
2. **Activate plugin:** Checkout page live.
3. **Attack:** Extract `cartflows.check_email_exist_nonce`; script POST requests to `/wp-admin/admin-ajax.php` with `action=wcf_check_email_exists`, `security=<nonce>`, `email_address=<candidate>`.
4. **Verify impact:** `success:true, msg:'Email Exist.'` for registered emails vs `success:false, msg:'Email not exist'` for unregistered.

**Counter-evidence:**
- `modules/checkout/classes/class-cartflows-checkout-ajax.php:207` — `check_ajax_referer('check-email-exist','security')` dies on nonce failure. Nonce name matches `checkout-markup.php:1772`. Prevents CSRF; nonce is publicly accessible so this is not an access-control barrier.
- `modules/checkout/classes/class-cartflows-checkout-ajax.php:209` — `sanitize_email(wp_unslash(...))` normalizes input correctly. Does not prevent the enumeration oracle.

**Dynamic test plan:**
1. Extract `cartflows.check_email_exist_nonce` from checkout page.
2. POST `action=wcf_check_email_exists`, `security=<nonce>`, `email_address=<known_customer_email>` → expect `success:true`.
3. Repeat with `email_address=<random_never_registered>` → expect `success:false`.
4. Send 100+ requests in rapid succession to confirm no rate-limiting is applied.
5. Confirm nonce remains valid across repeated requests without a new page load (12-hour nonce window).

---

### Finding ID: `agent-a2-f22-upload-checkout-file`
**Type:** Arbitrary File Upload
**Minimum Role/Capability:** Subscriber — corrected from Phase 2 claim of `none`
**Status Transition:** `UNCERTAIN → keep` (with field correction)

**Description:** This finding targets the authenticated hook `wp_ajax_wcf_upload_checkout_file` at `checkout-ajax.php:57`. It shares the same handler as `cartflows-a1-001` with identical logic: no capability check, same fallback-to-master-allowlist path when context parameters are absent. The Phase 2 `auth_required:none` is wrong for this entry point — WordPress only fires `wp_ajax_` (priv) hooks for logged-in users, so minimum auth is a valid WordPress session (subscriber role). The vulnerability claim itself is well-supported.

**Highest Impact:** Any logged-in WordPress subscriber (e.g., a WooCommerce customer who created an account) can upload arbitrary allowed-type files into `wp-content/uploads` without any CartFlows capability check.

**PoC:**
1. **Setup:** Install CartFlows; create a subscriber-role user.
2. **Activate plugin:** Checkout page live.
3. **Attack:** Log in as subscriber; load checkout page; extract `cartflows.wcf_file_upload_nonce`; POST `action=wcf_upload_checkout_file`, `security=<nonce>`, `wcf_checkout_file=@test.jpg` (omit `field_key`/`checkout_id`).
4. **Verify impact:** JSON success response with public file URL confirms missing capability gate.

**Counter-evidence:**
- `modules/checkout/classes/class-cartflows-checkout-ajax.php:57` — `add_action('wp_ajax_wcf_upload_checkout_file',...)` fires only for authenticated users. Phase 2 `auth_required:none` is incorrect for this entry point; minimum is subscriber.
- `modules/checkout/classes/class-cartflows-checkout-ajax.php:295` — Same nonce guard as `cartflows-a1-001`. Effective CSRF guard; nonce is available to any user who loads a checkout page.

**Dynamic test plan:**
1. Create subscriber-role account; log in.
2. Load CartFlows checkout page; extract `cartflows.wcf_file_upload_nonce`.
3. POST `action=wcf_upload_checkout_file`, `security=<nonce>`, `wcf_checkout_file=@test.jpg`; omit `field_key`/`checkout_id`.
4. Verify 200 JSON success with `data.url` → upload succeeded for subscriber with no CartFlows permissions.
5. Compare with `cartflows-a1-001` to confirm both priv and nopriv hooks are independently reachable.

---

### Finding ID: `agent-a4-review-checkout-block-layout-include`
**Type:** Broken Access Control
**Minimum Role/Capability:** Editor — corrected from Phase 2 claim of `unknown`
**Status Transition:** `UNCERTAIN → keep` (with field corrections)

**Description:** `render_html()` in `class-wcfb-checkout-form.php:858` registers a filter that returns the raw, unsanitized block attribute `layout` as the `wcf-checkout-layout` value. This value flows unmodified through `get_checkout_meta_value()` at `class-cartflows-default-meta.php:546` to `checkout_shortcode_markup()` at `checkout-markup.php:526`, which passes it through `apply_filters('cartflows_checkout_layout_template', $checkout_layout)` at `:530` — no registered handler in this plugin transforms the value — then to `file_exists($template_layout)` at `:532` and `include $template_layout` at `:533`. The AJAX preview path at `class-cartflows-init-blocks.php:232` applies `sanitize_title()` which strips path separators, but this sanitizer is absent in the block render path. An Editor can save an arbitrary string in the block's stored `post_content` via the Gutenberg REST API and trigger LFI from the frontend.

**Highest Impact:** An authenticated Editor can include arbitrary readable server-side files (e.g., `wp-config.php`) in the checkout page frontend response, disclosing database credentials; if an attacker-controlled `.php` file is already on the server, this escalates to code execution.

**PoC:**
1. **Setup:** Install CartFlows, create an Editor-role account.
2. **Activate plugin:** A checkout step (`cartflows_step`) post exists.
3. **Attack:** As Editor, PUT to `/wp-json/wp/v2/cartflows_step/<id>` with `post_content` containing `<!-- wp:wcfb/checkout-form {"layout":"/etc/passwd","block_id":"test"} /-->`.
4. **Verify impact:** Visit checkout step frontend URL as unauthenticated visitor; inspect rendered HTML for `/etc/passwd` content.

**Counter-evidence:**
- `modules/gutenberg/classes/class-cartflows-init-blocks.php:232` — In the AJAX preview path, `$attributes['layout']` is set from `sanitize_title(wp_unslash($_POST['layout']))`, stripping slashes and path traversal characters. This sanitizer is **not** present in the block `render_html()` path.
- `modules/checkout/classes/class-cartflows-checkout-markup.php:532` — `file_exists($template_layout)` gates the include. Non-existent paths fall back to the default template. This does not block LFI of any existing readable file.
- `modules/flow/classes/class-cartflows-step-post-type.php:198` — `'create_posts' => 'do_not_allow'` blocks new step creation. With `capability_type:'post'` + `map_meta_cap:true`, editing published posts requires `edit_published_posts` (Editor role minimum).

**Dynamic test plan:**
1. Create Editor-role user; log in.
2. Via REST API: `PUT /wp-json/wp/v2/cartflows_step/<id>` with `{"content": "<!-- wp:wcfb/checkout-form {\"layout\":\"/etc/passwd\",\"block_id\":\"test\"} /-->"}`.
3. Visit the checkout step frontend URL as unauthenticated visitor.
4. Inspect rendered HTML for `/etc/passwd` content (`root:x:0:0`). Positive match → CONFIRMED LFI.
5. Repeat with `layout` set to absolute path of `wp-config.php` → test for database credential disclosure.
6. Repeat with `layout` set to an attacker-controlled `.php` file already on the server → test for RCE.
7. Confirm that the AJAX preview path with same value is sanitized by `sanitize_title` to establish the path distinction.

---

### Finding ID: `cf-c-anom_5`
**Type:** Broken Access Control
**Minimum Role/Capability:** Subscriber (corrected from Phase 2 `none`)
**Status Transition:** `UNCERTAIN → downgrade`

**Description:** This finding targets `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file` — the authenticated upload hook at `checkout-ajax.php:57` — but claims `auth_required:none`. WordPress only routes requests to `wp_ajax_` hooks for authenticated users; the `auth_required:none` claim is factually wrong for this entry point. The underlying missing-capability observation is real but duplicates `agent-a2-f22-upload-checkout-file` with worse evidence precision. The `critical` severity is unsupported: the master allowlist at `classes/class-cartflows-helper.php:1934` blocks PHP, HTML, SVG, and XML; only media and document types (`jpg/jpeg/png/gif/webp/ico/pdf/mp3/m4a/wav/mp4/m4v/mov`) are allowed.

**Highest Impact:** Subscriber-level authenticated user can upload allowed media/document types without CartFlows capability check — medium severity, not critical.

**PoC:**
1. Log in as subscriber; load checkout page; extract nonce.
2. POST `action=wcf_upload_checkout_file`, `security=<nonce>`, `wcf_checkout_file=@test.pdf`.
3. Verify upload success at subscriber level; attempt `.php`/`.html`/`.svg` to confirm all are blocked.

**Counter-evidence:**
- `modules/checkout/classes/class-cartflows-checkout-ajax.php:57` — `add_action('wp_ajax_wcf_upload_checkout_file',...)` fires only for authenticated users. `auth_required:none` is incorrect; minimum is subscriber.
- `classes/class-cartflows-helper.php:1934` — Master allowlist excludes `.html`, `.svg`, `.xml`. Phase 2 claim that these types can be uploaded as XSS vectors is wrong.

**Dynamic test plan:**
1. Log in as subscriber; extract `cartflows.wcf_file_upload_nonce` from checkout page.
2. POST `action=wcf_upload_checkout_file`, `security=<nonce>`, `wcf_checkout_file=@test.pdf` → expect upload success.
3. Retry with `wcf_checkout_file=@test.html` → expect `'File type is not allowed.'` error (refutes Phase 2 claim).
4. Retry with `wcf_checkout_file=@test.svg` → expect same block.
5. Log out and repeat Step 2 to confirm unauthenticated requests hit the nopriv hook (not this priv hook).

---

### Finding ID: `cf-c-anom_35`
**Type:** Broken Access Control
**Minimum Role/Capability:** None (unauthenticated)
**Status Transition:** `UNCERTAIN → downgrade`

**Description:** This finding contains multiple material code-evidence errors. (1) The claimed sink at line 325 is not `wp_handle_upload` — line 325 is the closing line of `wp_send_json_error()` for a blocked file type; `wp_handle_upload` is called at line 425 inside `move_uploaded_file()`. (2) The PoC uses the wrong form field name `wcf_upload_file`; the actual field is `wcf_checkout_file` (verified at `checkout-ajax.php:301,311`). A PoC with the wrong name triggers `'No file uploaded'` at `:302` and aborts before any upload. (3) Phase 2 claims `.html`, `.svg`, and `.xml` uploads are possible — all three are absent from the master allowlist at `classes/class-cartflows-helper.php:1934`. The core observation (unauthenticated upload, no capability check) is real but fully and accurately documented by `cartflows-a1-001`.

**Highest Impact:** Same as `cartflows-a1-001` when the correct field name is used — but as written, the PoC does not execute.

**PoC:**
1. Extract nonce; POST with correct field name `wcf_checkout_file=@test.pdf` (not `wcf_upload_file`).
2. Verify success; retry with wrong field name to confirm the Phase 2 PoC as written fails with `'No file uploaded'`.

**Counter-evidence:**
- `modules/checkout/classes/class-cartflows-checkout-ajax.php:325` — Line 325 is `wp_send_json_error(...)` for blocked file types, not `wp_handle_upload`. The actual sink is at line 425.
- `modules/checkout/classes/class-cartflows-checkout-ajax.php:301` — `$_FILES['wcf_checkout_file']` is the upload field. Using `wcf_upload_file` (Phase 2 PoC) would trigger the empty check at `:301-304` and abort the handler.
- `classes/class-cartflows-helper.php:1934` — Master allowlist excludes `.html`, `.svg`, `.xml`. Phase 2 claim that these are uploadable XSS vectors is wrong.

**Dynamic test plan:**
1. Extract nonce; POST `wcf_checkout_file=@test.pdf` (correct field name) → confirm upload success reaches line 425.
2. Retry with field name `wcf_upload_file` → confirm `'No file uploaded'` error (PoC as written in Phase 2 does not work).
3. Attempt `wcf_checkout_file=@test.html` → confirm `'File type is not allowed.'` (refutes Phase 2 XSS claim).
4. Attempt `wcf_checkout_file=@test.svg` and `@test.xml` → confirm same block.
5. Verify upload persisted at `wp-content/uploads/` to confirm sink is line 425, not 325.

---

## 4. Negative Findings

**File upload — No PHP/script/HTML/SVG execution:**
`classes/class-cartflows-helper.php:1934` and `checkout-ajax.php:331` together block PHP, HTML, SVG, XML and all script types. Neither the priv nor nopriv upload endpoint provides RCE or stored XSS via file upload. Any finding claiming those impact types for this endpoint is wrong given the current allowlist.

**Nonce enforcement is real:**
`checkout-ajax.php:295`: `check_ajax_referer('wcf-file-upload','security',false)` with `wp_send_json_error()` on failure calls `wp_die()` and terminates execution. The Phase 1 IR's characterization of this nonce as ineffective because `die` is not directly passed is misleading: `wp_send_json_error()` internally calls `wp_die()`. The nonce is an effective CSRF guard.

**Email input is sanitized:**
`checkout-ajax.php:209`: `sanitize_email(wp_unslash(...))` correctly normalizes the email. The `cartflows-a1-002` vulnerability is behavioral (oracle disclosure), not an injection issue.

**AJAX preview layout is sanitized:**
`class-cartflows-init-blocks.php:232`: `sanitize_title(wp_unslash($_POST['layout']))` strips path traversal characters in the AJAX preview handler. The LFI risk exists only in the block `render_html()` server-side render path, not in the admin preview flow.

**New step creation is blocked:**
`class-cartflows-step-post-type.php:198`: `'create_posts' => 'do_not_allow'` prevents non-administrators from creating new `cartflows_step` posts. The LFI attack surface is narrowed to users who can edit existing steps (Editor+), not all authenticated users.

---

## 5. Overall Assessment

CartFlows has one high-confidence UNCERTAIN cluster (the file upload handlers) and one lower-confidence UNCERTAIN finding (the LFI via Gutenberg block layout attribute).

**The file upload findings (cartflows-a1-001, agent-a2-f22)** are structurally well-supported: the code path is clear, the nonce is public, the capability check is absent, and the fallback logic is confirmed. Both should be prioritized for dynamic testing. The two downgraded findings (`cf-c-anom_5`, `cf-c-anom_35`) cover the same vulnerability with evidence errors and should be treated as duplicate candidates of the two kept findings rather than independent bugs.

**The LFI finding (agent-a4)** has a credible code path but a significant access barrier (Editor role) and requires dynamic confirmation that block attribute values pass through to the include without WordPress core coercion. If confirmed, it would be the most severe finding in this set.

**The email enumeration finding (cartflows-a1-002)** is the most straightforwardly evidenced of all six: the code is unambiguous and the feature is intentional (UX for returning customers), which is precisely why it lacks mitigation. Severity is low but evidence quality is the strongest in this review.

**Priority for dynamic testing:**
1. `cartflows-a1-001` — unauthenticated file upload (high probability, medium impact)
2. `agent-a4-review-checkout-block-layout-include` — LFI (lower probability, high impact if confirmed)
3. `cartflows-a1-002` — user enumeration (near-certain, low impact)
4. `agent-a2-f22` — subscriber file upload (overlaps with #1, confirms additional role vector)
