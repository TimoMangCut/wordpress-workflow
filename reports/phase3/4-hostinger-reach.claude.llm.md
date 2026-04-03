# Phase 3b LLM Skeptic Review — hostinger-reach

**Plugin:** Hostinger Reach
**Version:** 1.4.4
**Reviewer role:** Skeptic (Phase 3b)
**Date:** 2026-04-02

---

## 1. Plugin Overview

Hostinger Reach is a first-party Hostinger email-marketing plugin that connects a WordPress site to the Reach CRM platform. It registers REST API routes for contact submission, tag management, integration imports, and account linking. The account-linking flow is the plugin's primary trust boundary: an admin initiates a connection via `/generate-auth-url`, which produces a short-lived CSRF transient; the Reach platform then calls back to the site's public `/token` endpoint to complete the binding. A secondary "legacy" authorization path reads a server-side file (`/.api_token`) as an alternate CSRF credential for the same token-storage operation.

---

## 2. Validation Summary

| Metric | Count |
|---|---|
| Findings eligible for review (PLAUSIBLE or UNCERTAIN) | 1 |
| Downgraded | 0 |
| Kept (UNCERTAIN → UNCERTAIN) | 1 |
| Upgraded | 0 |

---

## 3. Detailed Reviews

### Finding HOSTINGER-REACH-P2-REV-001

- **Finding ID:** `HOSTINGER-REACH-P2-REV-001`
- **Type:** Broken Access Control
- **Minimum Role/Capability:** none (unauthenticated)
- **Status Transition:** UNCERTAIN → keep (UNCERTAIN)

**Description:**
The public REST route `POST /wp-json/hostinger-reach/v1/token` gates token storage behind a CSRF check that accepts either a short-lived admin-generated transient *or* the contents of a server-side file `/.api_token` as valid authorization material. If an attacker can obtain the `/.api_token` file value through any channel, they can overwrite the plugin's stored Reach API key with an attacker-controlled value without any WordPress authentication.

**Highest Impact:**
An attacker who obtains the `/.api_token` value can rebind the site's Reach account to an attacker-controlled Reach workspace, redirecting all future contact submissions (marketing email data, subscriber PII) to the attacker and disrupting the site owner's email-marketing operations.

---

#### Code Evidence (verified against source)

| Element | File | Line | Verified |
|---|---|---|---|
| Route registration, public permission_callback | `src/Api/Routes/ReachRoutes.php` | 80–101 | ✓ exists |
| `validate_csrf()` — dual-path CSRF logic | `src/Api/ApiKeyManager.php` | 36–48 | ✓ exists |
| `get_order_id()` — reads `.api_token` file | `src/Api/ApiKeyManager.php` | 67–78 | ✓ exists |
| `get_api_token_path()` — constructs path | `src/Api/ApiKeyManager.php` | 80–89 | ✓ exists |
| `store_token()` → `update_option()` sink | `src/Api/ApiKeyManager.php` | 18–22 (line 21) | ✓ exists |
| `post_token_handler()` — calls store_token | `src/Api/Handlers/ReachApiHandler.php` | 212–223 | ✓ exists |

> **Phase 3a code_evidence note corrected:** Phase 3a flagged "sink function not found near line 21." This was a line-matching artefact in the gate: `store_token()` is *declared* at line 18; `update_option(self::API_KEY_NAME, …)` is at line 21. The sink is present and correct. No finding correction needed on this point.

---

#### Trust-Boundary Analysis

**Path A — Admin transient (intended flow):**
1. Admin (must have `manage_options`) calls `POST /generate-auth-url` → `generate_csrf()` sets transient `hostinger_reach_csrf_token` with 500-second expiry and 12-char random value.
2. Reach platform receives the CSRF in the redirect URL and POSTs it back to `/token`.
3. `validate_csrf()` matches transient → stores new Reach API token → clears transient.

This path is sound. The transient is short-lived, admin-gated at creation, and consumed once.

**Path B — `.api_token` file (legacy/provisioning flow):**
1. `get_order_id()` reads `get_api_token_path()` = `/{parts[1]}/{parts[2]}/.api_token` where `parts` = `explode('/', __DIR__)` on the `src/Api` directory.
2. On a typical Hostinger deployment: `__DIR__` = `/home/u123456789/public_html/wp-content/plugins/hostinger-reach/src/Api`, so `parts[1]` = `home`, `parts[2]` = `u123456789`, and the path = `/home/u123456789/.api_token`.
3. This file lives in the Unix home directory, **above the webroot**, and is not HTTP-accessible on a standard Hostinger configuration.
4. `validate_csrf()` treats this value as permanently valid authorization material with no expiry and no consumption — it is reusable indefinitely until the file changes.

---

#### Counter-Evidence Found

**CE-1: `.api_token` file is above webroot (strong)**
- File: `src/Api/ApiKeyManager.php` lines 80–89
- `get_api_token_path()` yields `/home/{username}/.api_token` on Hostinger hosting. This path is not served by the web server; a direct HTTP `GET /.api_token` request will 404 or be blocked.
- This is the primary counter-evidence. Without a disclosure path for this value, unauthenticated exploitation is not demonstrated.

**CE-2: File value never reflected in any public output (strong)**
- File: `src/Api/ApiKeyManager.php` line 67; `vendor/hostinger/hostinger-wp-helper/src/Utils.php` line 81
- Reviewed all public REST handlers (`post_contact_handler`, `post_token_handler`) and all public-facing AJAX callbacks. None return or log the `.api_token` value. The file is only read server-side.

**CE-3: No HTTP alias or symlink in plugin source**
- No `nginx.conf`, `.htaccess`, or symlink in the plugin source exposes the home-directory path. Whether the hosting environment itself has such a configuration is outside the visible source.

---

#### Why UNCERTAIN Is Maintained (not downgraded to REJECTED)

The counter-evidence above is sufficient to block a *CONFIRMED* finding. However, three conditions prevent *REJECTED*:

1. **Long-lived credential with no expiry or consumption.** Path B accepts `get_order_id()` as valid *indefinitely* — unlike the 500-second transient. Any future or existing disclosure path (another plugin, server misconfiguration, backup file exposure) converts this into a 0-click rebind primitive. The design flaw is real regardless of current exploitability.

2. **Other Hostinger plugins share the same token source.** `Utils::getApiToken()` in the bundled vendor helper exposes the same file via a public static method. If *any other* Hostinger plugin installed on the same server calls this method in a public-facing output, the token becomes obtainable.

3. **Patchstack scope.** The `/token` endpoint trusts a long-lived server-side credential as unauthenticated authorization for a privilege-equivalent operation (overwriting the admin-set API key). The design flaw is independently reportable as an improper authentication pattern even without a current public disclosure path.

---

#### PoC

**Setup:**
1. Install Hostinger Reach 1.4.4 on a Hostinger-hosted WordPress site.
2. Confirm `/home/{username}/.api_token` exists and contains a known value (readable via SSH or shared-hosting file manager).
3. Create an attacker-controlled Reach account and obtain its API token.

**Activate plugin:** Plugin is already active.

**Attack:**
```
POST /wp-json/hostinger-reach/v1/token
Content-Type: application/json

{
  "csrf_field": "<contents of /home/{username}/.api_token>",
  "token": "<attacker-reach-api-token>"
}
```

**Verify impact:**
- `wp option get hostinger_reach_api_key` returns the encrypted attacker token.
- All subsequent authenticated Reach operations (contact syncs, overview calls) are routed to the attacker's Reach workspace.

**Current blocking condition:** Attacker cannot retrieve `/home/{username}/.api_token` via HTTP from the target server (no web-accessible path demonstrated).

---

#### Dynamic Test Plan

1. **Determine exact path:** SSH into a live Hostinger instance. Run `php -r "$d=realpath('/path/to/wp-content/plugins/hostinger-reach/src/Api'); $p=explode('/',$d); echo '/'.$p[1].'/'.$p[2].'/.api_token';"` to confirm the resolved path.
2. **HTTP accessibility check:** `curl -sv https://<target>/.api_token` — expect 403/404 if path is above webroot.
3. **Sibling-plugin search:** Grep all other installed Hostinger plugins for `getApiToken` or `get_order_id` usages that return the value in a REST or AJAX response.
4. **Backup/cache exposure check:** Check whether any WordPress backup plugin, object-cache dump, or debug log exposes the file contents.
5. **Exploitation attempt (if token obtained):** Send the crafted POST above. Verify via `wp option get hostinger_reach_api_key` that the stored token changed, then confirm data routing to attacker account.

---

#### Reopening Condition

This finding should be re-evaluated to CONFIRMED if any of the following is demonstrated:
- HTTP accessibility of `/home/{username}/.api_token` (e.g., via server misconfiguration or a web-accessible symlink).
- Any Hostinger-bundled plugin or first-party endpoint that returns `Utils::getApiToken()` output in an unauthenticated HTTP response.
- Any other server-side information disclosure path that exposes the file contents to a remote attacker.

---

## 4. Negative Findings (Areas Confirmed Safe by Phase 2)

The following areas were analyzed in Phase 2 and confirmed as false positives. This review found no reason to reopen any of them.

**All other REST mutation routes (`/integrations`, `/generate-auth-url`, `/overview`, `/tags`, `/forms`, `/contact-lists`, `/import`):**
Protected by `permission_check()` → `current_user_can('manage_options')` at `src/Api/Routes/Routes.php:25–33`. Confirmed in source. No bypass path found.

**Integrations arbitrary option write (Semgrep signal):**
`POST /integrations` requires `manage_options`, validates the integration key against a fixed allowlist, and writes only to the fixed option `hostinger_reach_integrations`. No attacker-controlled option key path. Refuted at `src/Api/Handlers/IntegrationsApiHandler.php:70–85`.

**`wp_ajax_nopriv_abandoned-carts` cross-user read/write:**
Handler scopes all writes to the current WooCommerce session/customer hash. No cross-user data access path. Refuted at `src/Tracking/AbandonedCarts.php:64–70`.

**`SatisfactionSurvey` XSS (`$_SERVER['REQUEST_URI']`):**
`REQUEST_URI` is consumed only by `str_contains()` to gate survey display. It is not echoed or output. Refuted at `src/Admin/Surveys/SatisfactionSurvey.php:50–51`.

**Public contact/subscription intake (`POST /contact`, OptInMonster):**
Intentionally public by design. No WordPress privilege escalation or secret exposure. Out of scope.

**GET `/integrations` information disclosure:**
Returns plugin metadata (titles, install/activation flags). No secrets, API tokens, or privileged state. Out of scope.

---

## 5. Overall Assessment

Hostinger Reach 1.4.4 has a single finding that survives analysis: an **improper authentication design** on the public token-binding route (`POST /wp-json/hostinger-reach/v1/token`). The route's CSRF mechanism has two paths — a sound short-lived transient (Path A) and a long-lived, never-expiring, never-consumed file-based credential (Path B). Path B represents a permanent unauthenticated authorization primitive if the file value is ever disclosed.

**Current exploitability:** Blocked. The `.api_token` file resolves to a home-directory path above the webroot on Hostinger hosting, and no mechanism in this plugin's source exposes it over HTTP. Unauthenticated exploitation cannot be demonstrated from the visible source alone.

**Design risk:** Real and independently reportable. The fallback path treats a static, long-lived server file as equivalent to a time-limited cryptographic nonce for an operation that overwrites admin-set credentials. The correct fix is to remove Path B entirely and require all token exchanges to use the admin-generated transient.

**Patchstack eligibility:** Borderline. Without a demonstrated remote disclosure path for `.api_token`, the finding does not meet a reproducible-PoC standard. If Hostinger's hosting environment or a sibling plugin provides that path, this becomes a straightforward high-severity unauthenticated account takeover primitive. Further testing on a live Hostinger instance is required before submission.

**Recommended verdict after dynamic testing:** CONFIRMED (High) if token disclosure is demonstrated; REJECTED with reopening condition if it cannot be demonstrated on any Hostinger configuration.
