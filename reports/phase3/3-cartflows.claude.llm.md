# Phase 3b LLM Skeptic Review — CartFlows

**Plugin:** cartflows
**Review date:** 2026-04-05
**Reviewer:** Claude LLM Skeptic (Phase 3b)
**Source:** `cartflows-phase3-review-input.json` (4 UNCERTAIN findings from Phase 3a gate)

---

## 1. Plugin Overview

CartFlows is a WooCommerce-powered checkout funnel plugin (v2.2.2). It allows site owners to create custom checkout pages ("steps") organized into conversion flows. The plugin registers the `cartflows_step` and `cartflows_flow` custom post types, exposes a Gutenberg block editor integration, and provides multiple AJAX endpoints for unauthenticated checkout interactions (email lookup, file upload, coupon application). The plugin's attack surface is concentrated in its public-facing checkout AJAX handlers and in its block rendering pipeline.

---

## 2. Validation Summary

| Metric | Count |
|---|---|
| Total reviewed | 4 |
| Downgraded | 0 |
| Kept (UNCERTAIN) | 4 |
| Upgraded | 0 |

All four findings survive skeptic review. Evidence supports each source-to-sink path. None are downgraded because counter-evidence found guards/sanitizers that neutralize the most damaging attack variants (PHP RCE, AJAX preview LFI) but not the core vulnerability claim. Field corrections are applied to two findings: auth_required on `agent-a2-f22` (none → subscriber) and auth_required + source line on `agent-a4` (unknown → editor, line 856 → 858).

---

## 3. Detailed Reviews

---

### Finding 1

- **Finding ID:** `cartflows-a1-001`
- **Type:** `arbitrary_file_upload`
- **Minimum Role/Capability:** none (unauthenticated)
- **Status Transition:** UNCERTAIN → keep
- **Description:** The `wp_ajax_nopriv_wcf_upload_checkout_file` AJAX handler accepts file uploads from any unauthenticated visitor who presents a valid nonce, and that nonce (`wcf-file-upload`) is emitted unconditionally to every visitor loading any CartFlows checkout page — regardless of whether that checkout has a file-upload field configured. When `field_key` or `checkout_id` are omitted or invalid, `get_field_restrictions()` returns an empty extension list, which causes `upload_checkout_file()` to fall through to the full master allowlist (jpg, jpeg, png, gif, webp, ico, pdf, mp3, m4a, wav, mp4, m4v, mov), and the file is stored in `wp-content/uploads` with a public URL returned in the JSON response.
- **Highest Impact:** Any unauthenticated internet visitor can store attacker-controlled media and document files (PDFs, images, audio) on the victim's WordPress instance and obtain publicly accessible hosting URLs, enabling phishing lure hosting, malware distribution, and storage abuse — without any checkout context or authentication.

**PoC:**
1. **Setup:** Install CartFlows and WooCommerce; publish any CartFlows checkout step.
2. **Activate plugin:** Verify that visiting the checkout step URL returns a page with `cartflows.wcf_file_upload_nonce` in the inline localized script.
3. **Attack:** `curl -s -X POST https://victim.example/wp-admin/admin-ajax.php -F 'action=wcf_upload_checkout_file' -F 'security=<nonce>' -F 'wcf_checkout_file=@payload.pdf'` (omit field_key and checkout_id).
4. **Verify impact:** A JSON response `{"success":true,"data":{"url":"https://victim.example/wp-content/uploads/2026/04/wcf_<uuid>.pdf",...}}` confirms the file is stored and publicly accessible.

**Counter-evidence identified:**

| Type | File | Line | Detail |
|---|---|---|---|
| guard | `modules/checkout/classes/class-cartflows-checkout-ajax.php` | 295 | `check_ajax_referer('wcf-file-upload', 'security', false)` is present and terminates execution on failure. Effective as CSRF guard; not an access-control boundary because the nonce is publicly visible. |
| sanitizer | `modules/checkout/classes/class-cartflows-checkout-ajax.php` | 331 | `wp_check_filetype_and_ext()` validates MIME type against declared extension. Combined with master allowlist at `classes/class-cartflows-helper.php:1933–1934`, this blocks PHP/script uploads. The finding is not RCE — it is arbitrary public file hosting. |
| guard | `modules/checkout/classes/class-cartflows-checkout-markup.php` | 1804–1818 | `has_file_field` detection checks whether an enabled file field exists on the checkout and exposes this to JS. This flag controls only the JS upload UI (`assets/js/checkout-template.js:885`), **not** any server-side access control on the AJAX handler. |

**Dynamic test plan:**
1. Load a public CartFlows checkout page (no active WP session). Extract `cartflows.wcf_file_upload_nonce` from the page source.
2. `curl -X POST /wp-admin/admin-ajax.php -F 'action=wcf_upload_checkout_file' -F 'security=<nonce>' -F 'wcf_checkout_file=@test.pdf'` (no `field_key`, no `checkout_id`). Expect `{"success":true,"data":{"url":"..."}}`.
3. Confirm the URL is publicly accessible with `curl -I <returned_url>`. Expect HTTP 200.
4. Repeat with `.jpg` to confirm media types work.
5. Attempt with `.php` to confirm RCE is blocked. Expect `{"success":false,"data":{"error":"File type is not allowed."}}`.

---

### Finding 2

- **Finding ID:** `cartflows-a1-002`
- **Type:** `user_enumeration`
- **Minimum Role/Capability:** none (unauthenticated)
- **Status Transition:** UNCERTAIN → keep
- **Description:** The `wp_ajax_nopriv_wcf_check_email_exists` AJAX handler returns a binary, differentiable response — `success:true` with `"Email Exist."` vs `success:false` with `"Email not exist"` — for any attacker-supplied email address, making it a reliable oracle for enumerating registered accounts. The nonce (`check-email-exist`) is emitted to every CartFlows checkout visitor at `class-cartflows-checkout-markup.php:1772`, no rate limiting is applied, and the endpoint is intentionally accessible to unauthenticated users.
- **Highest Impact:** An attacker can enumerate all registered WordPress/WooCommerce customer email addresses by querying this endpoint in bulk, enabling targeted credential-stuffing attacks and personalized phishing campaigns against site customers.

**PoC:**
1. **Setup:** Install CartFlows and WooCommerce; publish a checkout step; register a test customer account.
2. **Activate plugin:** Visit the checkout step and extract `cartflows.check_email_exist_nonce` from the page source.
3. **Attack (positive case):** `curl -X POST /wp-admin/admin-ajax.php -d 'action=wcf_check_email_exists&security=<nonce>&email_address=known@customer.com'`. Expect `{"success":true,"data":{"success":true,"msg":"Email Exist."}}`.
4. **Verify impact (negative case):** Repeat with `email_address=nobody@example.com`. Expect `{"success":true,"data":{"success":false,"msg":"Email not exist"}}`. The binary differentiation confirms enumeration.

**Counter-evidence identified:**

| Type | File | Line | Detail |
|---|---|---|---|
| guard | `modules/checkout/classes/class-cartflows-checkout-ajax.php` | 207 | `check_ajax_referer('check-email-exist', 'security')` terminates on nonce failure. The nonce name matches the emitted nonce at `class-cartflows-checkout-markup.php:1772`. Prevents CSRF but not enumeration. |
| sanitizer | `modules/checkout/classes/class-cartflows-checkout-ajax.php` | 209 | `sanitize_email()` + `wp_unslash()` sanitize the input before passing to `email_exists()`. Correct sanitization but does not affect the disclosure: a well-formed email still gets a differentiable response. |

**Dynamic test plan:**
1. Extract `cartflows.check_email_exist_nonce` from a checkout page.
2. Test with a known registered email: `POST action=wcf_check_email_exists&security=<nonce>&email_address=known@example.com`. Confirm `success:true` + `"Email Exist."`.
3. Test with an unknown email. Confirm `success:false` + `"Email not exist"`.
4. Run 100+ requests in a loop; confirm no rate-limit response (HTTP 200 throughout). Confirms bulk enumeration is viable.
5. Confirm nonce validity window: re-use the same nonce after 30 minutes and after 12 hours to characterize the enumeration window before a new page load is needed.

---

### Finding 3

- **Finding ID:** `agent-a2-f22-upload-checkout-file`
- **Type:** `arbitrary_file_upload`
- **Minimum Role/Capability:** subscriber (any authenticated WordPress user)
- **Status Transition:** UNCERTAIN → keep
- **Description:** This finding targets the authenticated hook (`wp_ajax_wcf_upload_checkout_file` at `class-cartflows-checkout-ajax.php:57`) of the same `upload_checkout_file()` handler analyzed in cartflows-a1-001. Phase 2 recorded `auth_required:none`, which is incorrect — the `ajax_priv` hook requires a valid WordPress session (subscriber or above). The handler still has no capability check, so any logged-in user regardless of role can exploit the identical fallback-to-master-allowlist path.
- **Highest Impact:** Any authenticated WordPress user (subscriber, customer, shop manager) can upload arbitrary media and document files to the server's uploads directory via the authenticated AJAX hook, identical in impact to the unauthenticated variant.

**Field corrections:**  `auth_required: none` → `auth_required: subscriber`

**PoC:**
1. **Setup:** Create a subscriber-role user on the target site.
2. **Activate plugin:** Log in as subscriber. Load a CartFlows checkout page. Extract `cartflows.wcf_file_upload_nonce`.
3. **Attack:** `curl -b 'wordpress_logged_in_<hash>=<session_cookie>' -X POST /wp-admin/admin-ajax.php -F 'action=wcf_upload_checkout_file' -F 'security=<nonce>' -F 'wcf_checkout_file=@test.jpg'` (no `field_key`, no `checkout_id`).
4. **Verify impact:** Confirm JSON success response with public upload URL. Confirm the subscriber role has no CartFlows-specific capabilities and no special permissions.

**Counter-evidence identified:**

| Type | File | Line | Detail |
|---|---|---|---|
| guard | `modules/checkout/classes/class-cartflows-checkout-ajax.php` | 295 | Same nonce guard as cartflows-a1-001. Effective only as CSRF barrier; not an access-control boundary for authenticated subscribers. |

**Dynamic test plan:**
1. Log in as a subscriber-role user. Load a CartFlows checkout page.
2. POST `action=wcf_upload_checkout_file` with a valid nonce and a `.jpg` file (no `field_key`/`checkout_id`).
3. Confirm `{"success":true,...}` with a public URL.
4. Compare with cartflows-a1-001 to confirm both hooks (priv and nopriv) are independently exploitable.
5. Confirm the subscriber has no `cartflows_manage_flows_steps` or any other CartFlows capability to demonstrate that role elevation is not needed.

---

### Finding 4

- **Finding ID:** `agent-a4-review-checkout-block-layout-include`
- **Type:** `local_file_inclusion`
- **Minimum Role/Capability:** editor (existing post edit access on `cartflows_step` CPT)
- **Status Transition:** UNCERTAIN → keep
- **Description:** The `WCFB_Checkout_Form::render_html()` Gutenberg block callback registers a filter on `cartflows_checkout_meta_wcf-checkout-layout` using the raw, unsanitized `$attributes['layout']` value from the saved block content (`class-wcfb-checkout-form.php:858`), which is then returned verbatim by `get_checkout_meta_value()` and — after the `cartflows_checkout_layout_template` filter for which no callbacks are registered — evaluated against `file_exists()` and `include`'d at `class-cartflows-checkout-markup.php:532–533`. The AJAX preview path is safe (it applies `sanitize_title()` at `class-cartflows-init-blocks.php:232`), but the block render path has no equivalent sanitization.
- **Highest Impact:** An Editor-role user can set `layout` to an absolute filesystem path (e.g., `/etc/passwd` on Linux, or `wp-config.php`) in a checkout step's saved block content; when any visitor loads the checkout page, PHP includes and outputs the file, disclosing sensitive server-side files including database credentials.

**Field corrections:** `auth_required: unknown` → `auth_required: editor`; `source_line_number: 856` → `source_line_number: 858`

**PoC:**
1. **Setup:** Install CartFlows + WooCommerce. Ensure at least one `cartflows_step` post of type checkout exists.
2. **Activate plugin:** Log in as an Editor-role user (has `edit_others_posts`, no CartFlows-specific capabilities).
3. **Attack:** Via REST API or Gutenberg editor, update the step's `post_content` to include the serialized block `<!-- wp:wcfb/checkout-form {"layout":"/etc/passwd","block_id":"test123","inputSkins":"modern-label"} /-->`. Save the post.
4. **Verify impact:** As an unauthenticated visitor, load the frontend URL of the checkout step. Inspect the rendered page body for `/etc/passwd` contents (e.g., `root:x:0:0:`). If present, the LFI is confirmed. Repeat with `layout` set to the full server path of `wp-config.php` to confirm database credential disclosure.

**Counter-evidence identified:**

| Type | File | Line | Detail |
|---|---|---|---|
| sanitizer | `modules/gutenberg/classes/class-cartflows-init-blocks.php` | 232 | In the AJAX preview handler (`order_checkout_form_shortcode()`), `$attributes['layout']` is set via `sanitize_title(wp_unslash($_POST['layout']))`, which strips slashes and path-separator characters. This sanitizer is present in the AJAX preview path only; it is **absent** from `WCFB_Checkout_Form::render_html()`. |
| guard | `modules/checkout/classes/class-cartflows-checkout-markup.php` | 532 | `file_exists($template_layout)` gates the `include`. If the path does not exist, the default template is used. This prevents 404-path inclusion but does not block LFI of any existing readable file. |
| guard | `modules/flow/classes/class-cartflows-step-post-type.php` | 198 | `'create_posts' => 'do_not_allow'` prevents non-administrators from creating new `cartflows_step` posts. An attacker must have edit access to an existing step — achievable by an Editor but not a Contributor. |
| guard | `modules/gutenberg/classes/class-cartflows-init-blocks.php` | 200 | The AJAX preview handler checks `current_user_can('cartflows_manage_flows_steps')`. This guard protects the preview endpoint but is entirely independent of the block render path. |

**Dynamic test plan:**
1. As an Editor-role user, locate an existing `cartflows_step` post ID via the REST API (`GET /wp-json/wp/v2/cartflows_step`).
2. Update the post content to contain a `wcfb/checkout-form` block with `"layout":"/etc/passwd"` via `PUT /wp-json/wp/v2/cartflows_step/<id>`.
3. Confirm the save succeeds (HTTP 200) without server-side attribute sanitization stripping the path.
4. As an unauthenticated user, load the checkout step's frontend URL.
5. Check the rendered HTML for the contents of `/etc/passwd`. If lines like `root:x:0:0:` appear in the response body, the LFI is confirmed.
6. Repeat with `layout` pointing to the WordPress `wp-config.php` absolute path to demonstrate database credential exposure.
7. (Risk boundary check) Attempt with a `.php` file path to test whether PHP execution occurs (LFI → RCE boundary).

---

## 4. Negative Findings (Areas Reviewed and Found Safe)

**Nonce bypass on upload endpoint:** The IR flagged `check_ajax_referer(..., false)` as potentially ineffective (soft mode). Code review confirms that the failure branch at `class-cartflows-checkout-ajax.php:295–298` calls `wp_send_json_error()`, which terminates AJAX execution via `wp_die()`. The nonce is not bypassable through the second-parameter behavior. The vulnerability exists because the nonce is publicly accessible, not because it can be bypassed.

**RCE via file upload:** The master allowlist at `classes/class-cartflows-helper.php:1933–1934` restricts uploads to media/document types only (jpg, jpeg, png, gif, webp, ico, pdf, mp3, m4a, wav, mp4, m4v, mov). `wp_check_filetype_and_ext()` validates MIME type against declared extension. PHP uploads are blocked. The file upload findings are rated medium, not critical, because RCE is not achievable.

**LFI via AJAX preview endpoint:** The `order_checkout_form_shortcode()` AJAX handler at `modules/gutenberg/classes/class-cartflows-init-blocks.php:232` applies `sanitize_title()` to the `layout` parameter, stripping path separators. This path is safe. The LFI finding is confined to the Gutenberg block render path.

**Duplicate upload hooks (cartflows-a1-001 vs agent-a2-f22):** Both findings address the same handler via different entry points (nopriv vs priv hooks). The vulnerabilities are independent and both exploitable. There is no scenario where fixing one automatically fixes the other — both hooks call the same function with the same absence of capability checking.

---

## 5. Overall Assessment

CartFlows exposes three security-relevant issues in this review round. Two are variants of the same design flaw (unrestricted file upload without context binding or access control), and one is a local file inclusion path reachable by Editor-role users through unsanitized Gutenberg block attributes.

The most immediately exploitable issues are the file upload findings (`cartflows-a1-001` and `agent-a2-f22-upload-checkout-file`): they are unauthenticated/low-auth, trivially reproducible, and require no knowledge of the site structure beyond the existence of a CartFlows checkout page. The user enumeration finding (`cartflows-a1-002`) is low-severity but technically clean and supports targeted follow-on attacks.

The LFI finding (`agent-a4-review-checkout-block-layout-include`) carries the highest potential severity (up to critical if `wp-config.php` exposure is confirmed) but requires Editor-level access to an existing checkout step, which is a meaningful barrier on most production sites. The finding remains UNCERTAIN because the exact behavior of the block renderer at save time (whether WordPress core coerces string block attributes) and the editor-role reachability path need dynamic verification.

**Priority for dynamic testing:** cartflows-a1-001 (easiest to test, clearest code path), then agent-a4 (highest severity if confirmed), then agent-a2-f22 and cartflows-a1-002.
