# Phase 3b LLM Skeptic Review — `kubio`

## 1. Plugin Overview

**Plugin:** Kubio (kubio)
**Version analyzed:** 2.7.1
**Plugin type:** Full-site editor / page builder for WordPress with cloud snippet storage, starter site demo imports, and AI-assisted design features.
**Entry points in IR:** 168 (REST routes, AJAX handlers, shortcodes)
**Phase 2 findings under review:** 2 (both UNCERTAIN from Phase 3a gate)

Kubio is a block-based site builder that extends the WordPress editor with custom blocks, starter site templates, and cloud-synced design snippets. Its attack surface includes REST API routes for snippet management and cloud API key storage, AJAX handlers for demo site plugin installation/activation, and admin pages for starter site imports.

---

## 2. Validation Summary

| Metric | Count |
|---|---|
| Findings reviewed | 2 |
| Downgraded | 0 |
| Kept (UNCERTAIN) | 2 |
| Upgraded | 0 |

Both findings present code-real vulnerabilities whose practical exploitability depends on deployment context (multisite vs. single-site) and external factors (cloud API behavior). Neither can be confirmed or rejected from source alone.

---

## 3. Detailed Reviews

### 3.1 KUBIO-P2-REV-001

- **Finding ID:** `KUBIO-P2-REV-001`
- **Type:** `Path Traversal`
- **Minimum Role/Capability:** Administrator with `edit_theme_options` (single-site: Administrator; multisite: Site Admin)
- **Status Transition:** UNCERTAIN -> keep
- **Description:** The `/snippet` REST route accepts user-controlled snippet JSON, regex-extracts URL suffixes matching the uploads base URL, and concatenates them directly onto `wp_get_upload_dir()['basedir']` without any path validation before passing to `file_get_contents()`. An attacker with `edit_theme_options` can inject `../` sequences in forged upload URLs within the snippet payload to read arbitrary files from the server filesystem.
- **Highest Impact:** Server-side arbitrary file read (e.g., `wp-config.php`, `/etc/passwd`) bundled into a ZIP archive that is uploaded to Kubio's cloud endpoint — if the attacker controls the cloud API key and can retrieve the uploaded ZIP, full database credentials and secret keys are exposed.

#### PoC

1. **Setup:** WordPress instance (single-site or multisite) with Kubio plugin active. Authenticate as an Administrator.
2. **Activate plugin:** Kubio must be active and the `/kubio/v1/snippet` REST route registered.
3. **Attack:**
   - First, set a controlled cloud API key:
     ```
     POST /wp-json/kubio/v1/kubio-api-key
     Content-Type: application/json
     {"key": "attacker-controlled-api-key"}
     ```
   - Then, submit a crafted snippet with traversal:
     ```
     POST /wp-json/kubio/v1/snippet
     Content-Type: application/json
     {
       "name": "testsnippet",
       "category": "1",
       "screenshot": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVQI12NgAAIABQABNjN9GQAAAAlwSFlzAAAWJQAAFiUBSVIk8AAAAA0lEQVQI12P4z8BQDwAEgAF/QualrQAAAABJRU5ErkJggg==",
       "globalData": {},
       "snippet": ["kubio/section", {"imageURL": "https://TARGET/wp-content/uploads/../../wp-config.php"}, []]
     }
     ```
4. **Verify impact:**
   - Check `get_temp_dir()` on the server for `testsnippet.zip`. Extract and inspect the archive — the `assets/../../wp-config.php` entry should contain the target file's contents.
   - The ZIP is also sent via `wp_remote_post` to `Utils::getSnippetsURL('/save')` with the attacker's API key in the `X-Authorization` header. If the cloud accepts the key, the attacker can retrieve the ZIP from the Kubio cloud dashboard.

#### Counter-Evidence

| Type | File | Line | Detail |
|---|---|---|---|
| guard | `lib/api/colibri.php` | 54 | `permission_callback` requires `current_user_can('edit_theme_options')` — admin-only access. |
| guard | `lib/api/colibri.php` | 281 | `file_exists()` check is present but is not a security control — it merely confirms the traversed path exists. |
| sanitizer | `lib/api/colibri.php` | 283 | `wp_normalize_path()` is applied to the ZIP entry name, NOT to the filesystem path used in `file_get_contents()`. It does not resolve `..` segments. |
| unreachable | `lib/api/colibri.php` | 142 | ZIP contents are sent to Kubio's cloud only — not returned in the HTTP response. Exfiltration requires cloud-side cooperation. |

#### Dynamic Test Plan

1. Set up WordPress with Kubio active. Create an administrator user.
2. POST to `/wp-json/kubio/v1/kubio-api-key` to set an attacker-controlled API key.
3. POST to `/wp-json/kubio/v1/snippet` with a crafted snippet containing a traversal URL (e.g., `uploads/../../wp-config.php`).
4. Check `get_temp_dir()` for the generated ZIP file. Extract and verify if `wp-config.php` content is present.
5. Verify if the ZIP file persists on disk (no `unlink()` observed in code after upload).
6. For full exfiltration chain: use a legitimate Kubio cloud API key, trigger the snippet save, check if the ZIP is retrievable from the cloud dashboard.

#### Why Not Downgraded

The local path traversal is **code-real**: the regex `(.*?)` on line 265 captures arbitrary suffixes including `../` sequences, and the concatenation at line 279 (`$upload_settings['basedir'] . $uploaded_file`) feeds directly into `file_get_contents()` at line 282 with zero validation. Five separate Semgrep rules flagged this file for arbitrary file read and LFI patterns (lines 150, 213, 281, 282). The absence of `realpath()`, `validate_file()`, or any prefix containment check was independently verified. However, the attacker cannot observe the file content from the HTTP response — it is only sent to Kubio's cloud — so measurable impact depends on external cloud behavior.

---

### 3.2 KUBIO-P2-REV-002

- **Finding ID:** `KUBIO-P2-REV-002`
- **Type:** `Broken Access Control`
- **Minimum Role/Capability:** Administrator with `import` capability (single-site: Administrator; multisite: Site Admin without `install_plugins`)
- **Status Transition:** UNCERTAIN -> keep
- **Description:** The `kubio-demo-site-install-plugin` and `kubio-demo-site-activate-plugin` AJAX handlers verify `current_user_can('import')` via `DemoSitesHelpers::verifyAjaxCall()` but never check `install_plugins` or `activate_plugins` before reaching `Plugin_Upgrader->install()` and `activate_plugin()`. On WordPress multisite, site administrators possess `import` but not `install_plugins`, creating a genuine capability boundary bypass.
- **Highest Impact:** On multisite, a site administrator who is intentionally restricted from installing plugins can install and activate arbitrary plugins from the WordPress.org repository, bypassing the network administrator's plugin installation controls.

#### PoC

1. **Setup:** WordPress **multisite** installation with Kubio network-activated. Create a sub-site with a site administrator user who is NOT a Super Admin.
2. **Activate plugin:** Kubio must be active on the sub-site.
3. **Attack:**
   - As the site admin, navigate to the Kubio editor or Starter Sites page. Extract the `kubio-ajax-demo-site-verification` nonce from inline JavaScript (`kubioEditorData.demo_site_ajax_nonce` at `editor-assets.php:378` or the demo-sites page data at `demo-sites.php:201`).
   - Send AJAX request to install a plugin:
     ```
     POST /wp-admin/admin-ajax.php
     Content-Type: application/x-www-form-urlencoded
     action=kubio-demo-site-install-plugin&slug=hello-dolly&nonce=<extracted-nonce>
     ```
   - Send AJAX request to activate it:
     ```
     POST /wp-admin/admin-ajax.php
     Content-Type: application/x-www-form-urlencoded
     action=kubio-demo-site-activate-plugin&slug=hello-dolly&nonce=<extracted-nonce>
     ```
4. **Verify impact:**
   - Check that `hello-dolly` is now installed and active on the sub-site.
   - Attempt the same via WordPress native `plugin-install.php` — should be blocked by `install_plugins` capability check.
   - Compare with the Image Hub handler at `image-hub.php:68` which correctly enforces `current_user_can('install_plugins')`.

#### Counter-Evidence

| Type | File | Line | Detail |
|---|---|---|---|
| guard | `lib/src/DemoSites/DemoSitesHelpers.php` | 16 | `check_ajax_referer('kubio-ajax-demo-site-verification', 'nonce')` prevents CSRF. |
| guard | `lib/src/DemoSites/DemoSitesHelpers.php` | 19 | `current_user_can('import')` IS checked — on single-site, only administrators have this, making the finding admin-only and not a privilege escalation. |
| guard | `lib/src/DemoSites/DemoSites.php` | 331 | `sanitize_text_field()` applied to slug. `plugins_api()` resolves the slug against WordPress.org repository only — no arbitrary URL installation. |
| guard | `lib/admin-pages/main-page/demo-sites.php` | 7 | The Starter Sites page checks `edit_theme_options` before rendering content including the nonce. |

#### Dynamic Test Plan

1. Set up WordPress multisite with Kubio network-activated.
2. Create a site administrator (not Super Admin) on a sub-site. Verify `current_user_can('import')` returns true and `current_user_can('install_plugins')` returns false.
3. Obtain the `kubio-ajax-demo-site-verification` nonce from the Kubio editor page source.
4. POST to `admin-ajax.php` with `action=kubio-demo-site-install-plugin&slug=hello-dolly&nonce=<nonce>`.
5. Verify the plugin was installed. POST with `action=kubio-demo-site-activate-plugin` to activate it.
6. Confirm the site admin cannot install plugins through WordPress's native plugin installation UI.
7. Check if `DISALLOW_FILE_MODS` or filesystem method restrictions block the operation at a lower level.

#### Why Not Downgraded

The capability mismatch is **code-real** and **intentional comparison available**: the Image Hub handler at `image-hub.php:68` uses `current_user_can('install_plugins')` for the identical `PluginsManager::installPlugin()` call, proving the developers understood this check was needed. The demo-site handlers at `DemoSites.php:327-365` skip it entirely, relying only on `import`. On multisite, this creates a genuine privilege boundary bypass where site administrators gain plugin installation capabilities that the Super Admin intentionally withheld. The finding is not downgraded because the capability gap is unambiguous in code; it remains UNCERTAIN only because the practical impact requires multisite deployment verification.

---

## 4. Negative Findings

Phase 2 identified six negative findings (KUBIO-P2-NEG-001 through NEG-006) and two out-of-scope items. These were not re-reviewed as they are not in the PLAUSIBLE/UNCERTAIN set. Brief notes on why the reviewed areas hold:

- **Menu REST routes (NEG-001):** Verified — both menu controllers enforce `edit_theme_options` in permission callbacks. Not exploitable.
- **Get-started tab include (NEG-002):** Verified — `sanitize_key()` on the tab parameter with hardcoded tab-to-partial mapping prevents LFI.
- **Contact/newsletter shortcode XSS (NEG-003):** Verified — `wp_kses_post()`, `esc_html()`, and `esc_attr()` are applied consistently.
- **Image Hub installer (NEG-004):** Verified — correctly checks `current_user_can('install_plugins')` at `image-hub.php:68`. This is the correct pattern that Finding 002's demo-site handlers are missing.
- **Preview changeset deletion (NEG-005):** Verified — nonce + ownership check present.
- **Admin-gated REST surfaces (NEG-006):** Verified — AI, settings, entity, and theme import routes consistently enforce `edit_theme_options`.

---

## 5. Overall Assessment

Kubio presents a generally well-guarded attack surface: the majority of its REST routes and AJAX handlers enforce `edit_theme_options` or higher capabilities, and Phase 2 correctly identified most flagged items as false positives.

The two remaining UNCERTAIN findings are both **code-real but deployment-dependent**:

1. **KUBIO-P2-REV-001 (Path Traversal):** The local file read vulnerability is genuine — no path validation exists between regex extraction and `file_get_contents()`. Five Semgrep rules independently corroborate this. The limiting factor is exfiltration: file contents go into a ZIP sent to Kubio's cloud, not to the attacker's HTTP response. If the cloud accepts attacker-controlled API keys and allows ZIP retrieval, this becomes a high-severity file disclosure. If not, the impact is limited to server-side file reads with no observable data leakage.

2. **KUBIO-P2-REV-002 (Broken Access Control):** The capability mismatch between `import` and `install_plugins`/`activate_plugins` is unambiguous. The same codebase's Image Hub handler demonstrates the correct pattern. On single-site, this is admin-only with no escalation. On multisite, this is a genuine privilege boundary bypass allowing site administrators to install arbitrary WordPress.org plugins despite network restrictions.

**Neither finding meets the threshold for CONFIRMED** from static analysis alone. Both require dynamic testing on specific deployment configurations (multisite for Finding 002, cloud API behavior for Finding 001) to determine measurable impact. The recommended priority is:

1. **Finding 002** — test on multisite first; lower complexity, higher confidence in the capability gap.
2. **Finding 001** — test the local ZIP file creation first; then investigate cloud retrieval.
