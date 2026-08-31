# WordPress plugin security audit knowledge base

**This is a comprehensive, technically precise reference for auditing WordPress 6.x plugins**, synthesizing real CVE data from 2023–2025, official WordPress developer documentation, and research from Wordfence, Patchstack, and WPScan. The WordPress plugin ecosystem saw **7,966 new vulnerabilities in 2024 alone** (a 34% increase over 2023), with XSS accounting for 47.7% of all findings, broken access control at 14.2%, and CSRF at 11.4%. REST API and AJAX endpoints are the most critically exploited attack surfaces. What follows is every detail a professional security auditor needs.

---

## 1. Exhaustive plugin attack surface catalog

### AJAX handlers (wp_ajax_*, wp_ajax_nopriv_*)

WordPress routes all AJAX through `wp-admin/admin-ajax.php`. Plugins register handlers via `add_action('wp_ajax_{action}', 'callback')` for authenticated users, and `add_action('wp_ajax_nopriv_{action}', 'callback')` for unauthenticated users. **WordPress provides zero built-in authorization for AJAX handlers** — no automatic nonce check, no capability check. The plugin developer must implement both `wp_verify_nonce()` and `current_user_can()`.

The `nopriv` variant is especially dangerous: it makes the endpoint accessible to anyone on the internet without authentication. Many plugins register `nopriv` variants unnecessarily, exposing admin-level functionality. The WPForms vulnerability CVE-2024-11205 (CVSS 8.5) exemplifies this: the `wpforms_is_admin_ajax()` function verified the nonce but never checked user capabilities, allowing **subscriber-level users to issue Stripe refunds and cancel subscriptions**. Similarly, Essential Addons for Elementor (CVE-2023-32243, CVSS 9.8) exposed password reset functionality via an AJAX handler that never validated the reset key.

**Required security controls for every AJAX handler:**
- `check_ajax_referer('action_name', 'security')` or `wp_verify_nonce()` for CSRF protection
- `current_user_can('required_capability')` for authorization
- Sanitization of all `$_POST`/`$_GET` parameters
- `wp_send_json_success()`/`wp_send_json_error()` for safe responses

### REST API routes (register_rest_route)

The REST API is the **single most critically exploited attack surface** in WordPress plugins during 2023–2025. The most impactful CVEs of this period — Really Simple Security (CVE-2024-10924, CVSS 9.8), WooCommerce Payments (CVE-2023-28121, CVSS 9.8), LiteSpeed Cache (CVE-2024-28000, CVSS 9.8), and AIOSEO (CVE-2021-25036, CVSS 9.9) — all exploited REST API endpoints with broken permission callbacks.

Routes are registered via `register_rest_route('namespace/v1', '/path', $args)`. Since **WordPress 5.5**, omitting `permission_callback` triggers a `_doing_it_wrong` notice, but the endpoint still functions as public. The notice is informational only. Using `'permission_callback' => '__return_true'` explicitly makes endpoints public — this was found in production plugins like Download Monitor.

Permission callbacks execute after authentication is resolved. For cookie-based auth, the `wp_rest` nonce must be passed via `X-WP-Nonce` header or `_wpnonce` parameter — without it, the current user is set to ID 0 (unauthenticated), even if the user has valid cookies. Application Passwords authenticate via HTTP Basic Auth before permission callbacks run.

**REST API namespace discovery** at `/wp-json/` exposes all registered namespaces, and `/wp-json/namespace/v1` lists all routes with their methods and argument schemas. This provides attackers a complete map of available endpoints.

### Shortcodes

Shortcodes (`add_shortcode('name', 'callback')`) are parsed from post content and executed server-side. Their primary attack surface is **attribute injection**: shortcode attributes are passed as an array to the callback without any automatic sanitization. The `shortcode_atts()` function provides default merging but no security filtering. Contributors can embed shortcodes in post content, making contributor-level Stored XSS the dominant vulnerability pattern.

Common vulnerability: `extract(shortcode_atts(['style' => ''], $atts))` followed by `echo '<div style="' . $style . '">'` — the `$style` attribute reaches HTML output unescaped. Every shortcode attribute must be escaped with the context-appropriate function (`esc_attr()`, `esc_html()`, `esc_url()`).

### Gutenberg blocks (detailed in Section 7)

The block editor introduces multiple attack surfaces: `render_callback` functions that output unescaped attributes, **block comment delimiter JSON** that bypasses wp_kses filtering, the `/wp/v2/block-renderer/` REST endpoint accessible to contributors, and `ServerSideRender` which can trigger server-side execution of block rendering with attacker-controlled attributes.

### Admin pages and menus

`admin_menu`, `admin_init`, `admin_post_*`, and `admin_post_nopriv_*` hooks create admin-side attack surfaces. **Critical misconception**: `is_admin()` checks whether the request targets wp-admin, not whether the user is an administrator. All authenticated AJAX requests go through `admin-ajax.php` in wp-admin, so `is_admin()` returns `true` for any logged-in user making AJAX calls. Always use `current_user_can()` instead.

`admin_init` fires on every admin page load — including `admin-ajax.php` and `admin-post.php` — making it a particularly broad attack surface if permission checks are absent. `admin_post_nopriv_*` actions are accessible to unauthenticated users, identical in risk to `wp_ajax_nopriv_*`.

### XML-RPC, WP-CLI, and Cron

**XML-RPC** (`xmlrpc.php`) exposes methods for remote content management and pingbacks. Plugins extend it via `xmlrpc_methods` filter. The pingback feature was exploited for **blind SSRF via DNS rebinding** (CVE-2022-3590). XML-RPC authentication uses username/password per request (no session), enabling brute-force attacks. Best practice is to disable it entirely unless required.

**WP-CLI commands** registered by plugins execute with the filesystem permissions of the CLI user (typically root or www-data), which may exceed WordPress capabilities. Commands should still validate input and use WordPress API functions rather than direct database/file operations.

**Cron jobs** (`wp_schedule_event`) execute via `wp-cron.php`, triggered by site visits. WP-Cron requests are internal HTTP requests that may bypass authentication. If a cron callback performs privileged operations without validation, it could be exploited. LiteSpeed Cache's crawler simulation feature (CVE-2024-28000) demonstrates how cron/crawler functions can create critical attack surfaces.

### Elementor and WooCommerce attack surfaces

**Elementor** adds an extensive secondary attack surface: widget controls, template import/export, AJAX handlers for the editor, and custom CSS/JS fields. CVE-2023-48777 (CVSS 8.8) exploited the template import AJAX handler for arbitrary file upload → RCE, and CVE-2023-3124 (CVSS 8.8) exploited `update_page_option` AJAX handler for subscriber-level arbitrary options update.

**WooCommerce** payment gateway integrations create critical surfaces: order status manipulation, price/quantity modification via checkout hooks, and payment callback endpoints. CVE-2023-28121 (CVSS 9.8) demonstrated that trusting a custom HTTP header (`X-WCPAY-PLATFORM-CHECKOUT-USER`) for authentication enabled unauthenticated admin access.

### Multisite-specific attack surfaces

In multisite, Site Admins have a restricted capability set compared to Super Admins. They lack `install_plugins`, `edit_plugins`, `edit_themes`, `unfiltered_html`, and all `manage_network_*` capabilities. Vulnerabilities that are "by design" for single-site admins become legitimate security issues in multisite because Site Admins should not be able to affect other sites or escalate to Super Admin. Cross-site data access and network-wide option modification are key multisite attack vectors.

### Additional entry points

- **Webhook/callback endpoints**: Payment gateways (Stripe, PayPal) require publicly accessible callback URLs. These must validate signatures/tokens from the payment provider, not just check for expected parameters.
- **oEmbed providers**: Custom oEmbed endpoints registered via `wp_oembed_add_provider()` can introduce SSRF if they fetch user-controlled URLs server-side.
- **Custom rewrite rules**: `add_rewrite_rule()` and `template_redirect` hook can create custom URL endpoints. Missing auth checks make these exploitable.
- **wp_mail**: Email header injection via unsanitized `To`, `From`, `CC`, `BCC` headers. Carriage returns (`\r\n`) in header values inject additional headers.
- **Filesystem API**: `WP_Filesystem` and direct PHP file functions. Path traversal via `../` sequences targets `wp-config.php`, `.htaccess`, and `wp-content/debug.log`.
- **Transient API**: `set_transient()`/`get_transient()` stores data in `wp_options` (or object cache). Transients with user-controlled keys can be overwritten. If transient data is used unsanitized in output or queries, it becomes a stored attack vector.
- **Object cache**: `wp_cache_set()`/`wp_cache_get()` data can be poisoned if cache keys are predictable and the caching backend (Redis, Memcached) is accessible.
- **wp_options autoload**: Options with `autoload=yes` load on every page request. Plugins storing large serialized data with autoload enabled create performance issues; storing user-controlled serialized data creates object injection risks.
- **Custom database tables**: Direct `$wpdb->query()` calls on custom tables bypass WordPress's built-in sanitization. Every variable in SQL must use `$wpdb->prepare()`.
- **Import/Export**: File upload (ZIP, XML, CSV) combined with parsing creates surfaces for XXE, Zip Slip, CSV injection, and path traversal.
- **Bulk action handlers**: `admin_action_*` hooks for bulk operations often lack per-item capability checks, enabling mass manipulation.

---

## 2. WordPress 6.x security mechanisms reference

### Nonce system behavior and edge cases

WordPress nonces are **HMAC hashes, not true one-time tokens**. They are generated from `$tick | $action | $user_id | $session_token` using `wp_hash()`. The default lifetime is **24 hours** (configurable via `nonce_life` filter), split into two 12-hour ticks. `wp_verify_nonce()` returns **1** for current tick (0–12h old), **2** for previous tick (12–24h old), or **false** for expired/invalid.

**Critical limitations:**
- **Not one-time-use**: The same nonce is generated for the same user+action during an entire tick period. This means nonces do not prevent replay attacks.
- **Guest users (ID 0) all receive identical nonces** — providing zero CSRF protection for unauthenticated forms. The `nonce_user_logged_out` filter can mitigate this.
- **Nonces verify intent, not authorization**. A valid nonce only proves the request originated from a page WordPress generated for that user. Any logged-in user can obtain valid nonces for any action. **Always pair `wp_verify_nonce()` with `current_user_can()`**.

**Core nonce functions:**
- `wp_create_nonce($action)` — Returns ~10-char alphanumeric hash
- `wp_verify_nonce($nonce, $action)` — Returns 1, 2, or false; does NOT terminate execution
- `check_admin_referer($action, $query_arg)` — Verifies nonce AND HTTP referer; calls `wp_die()` on failure
- `check_ajax_referer($action, $query_arg, $stop)` — Checks nonce only (not referer); inspects `_wpnonce`, `_ajax_nonce` params and `X-WP-Nonce` header

### REST API permission_callback enforcement (WP 5.5+)

Since WordPress 5.5, `register_rest_route()` issues a `_doing_it_wrong` notice when `permission_callback` is omitted. **The endpoint still functions as public** — the notice is informational only. WordPress cannot distinguish intentional public endpoints from accidental omissions. Using `'permission_callback' => '__return_true'` explicitly documents public intent.

Permission callbacks run **after** authentication is resolved. For cookie-based auth, the `wp_rest` nonce must be present, or the user is treated as unauthenticated (ID 0). Permission callbacks should use `current_user_can()`, not manual nonce verification — the REST API handles the `wp_rest` nonce automatically via `rest_cookie_check_errors()`.

### $wpdb->prepare() in WordPress 6.x

**Placeholders**: `%s` (string, auto-quoted), `%d` (integer), `%f` (float), **`%i` (identifier, backtick-quoted — added in WP 6.2)**. The `%i` placeholder allows safe table/column name parameterization: `$wpdb->prepare('SELECT * FROM %i WHERE %i = %s', $table, $column, $value)` produces `` SELECT * FROM `table` WHERE `column` = 'value' ``.

**Validation rules**: placeholder count must match argument count; positional placeholders (`%1$s`) are supported but do not auto-quote; `%%` produces literal `%`; for LIKE: `'%' . $wpdb->esc_like($search) . '%'` inside `prepare()`; IN clauses require dynamic placeholder construction; **named placeholders are NOT supported**.

### WordPress 6.x security changes

- **WP 6.2** (March 2023): `%i` identifier placeholder in `$wpdb->prepare()`
- **WP 6.4.3** (January 2024): POP chain vulnerability fix (potential RCE via WP_HTML_TOKEN deserialization)
- **WP 6.5** (March 2024): Block Bindings API with `edit_block_binding` capability; Interactivity API
- **WP 6.8** (April 2025): **Major password hashing overhaul** — phpass replaced by **bcrypt with SHA-384 pre-hashing** (prefix `$wp$2y$`). Application passwords and security keys use **BLAKE2b via Sodium**. Old `$P$` hashes remain valid and auto-rehash on login. Optional Argon2 support via `wp_hash_password_algorithm` filter.

### wp_safe_redirect vs wp_redirect

`wp_redirect($location)` sets the Location header with **no host validation** — vulnerable to open redirect with user-supplied URLs. `wp_safe_redirect($location)` validates the target host against an allowlist via `wp_validate_redirect()` (default: current site host only; extensible via `allowed_redirect_hosts` filter). If the host is not allowed, it falls back to `admin_url()`. **Neither function calls `exit`** — the developer must follow with `exit;` or `die;`.

### REST API authentication methods

- **Cookie + Nonce (built-in)**: Default for same-origin requests. Nonce action: `wp_rest`. Pass via `X-WP-Nonce` header or `_wpnonce` parameter. No valid nonce = user set to 0.
- **Application Passwords (WP 5.6+, built-in)**: HTTP Basic Auth (`Authorization: Basic base64(username:app_password)`). HTTPS required by default. 24-character passwords (~142 bits entropy), stored hashed (BLAKE2b in WP 6.8). Cannot be used for wp-login.php. Individually revocable.
- **OAuth (plugin-required)**: OAuth 1.0a or 2.0. Best for third-party integrations.
- **JWT (plugin-required)**: Stateless token-based. Not native to WordPress.

---

## 3. Complete WordPress security functions reference

### Sanitization functions

| Function | Behavior | Use case | Does NOT protect against |
|----------|----------|----------|-------------------------|
| `sanitize_text_field($str)` | Strips tags, removes line breaks/tabs/extra whitespace, strips octets | Single-line text input | SQL injection |
| `sanitize_textarea_field($str)` | Same as above but preserves line breaks | Multi-line text | SQL injection |
| `sanitize_email($email)` | Strips disallowed chars; does NOT validate format (use `is_email()`) | Email addresses | Invalid emails |
| `sanitize_file_name($filename)` | Removes special chars, replaces whitespace with dashes | File uploads | Path traversal (add `validate_file()`) |
| `sanitize_html_class($class)` | Keeps only A-Za-z0-9_- | CSS class names | — |
| `sanitize_key($key)` | Lowercases, keeps only a-z0-9_- | Option/meta keys | — |
| `sanitize_mime_type($mime)` | Keeps only a-zA-Z0-9._+-/ | MIME type strings | Fake MIME types |
| `sanitize_sql_orderby($orderby)` | Validates ORDER BY pattern; returns false if invalid | SQL ORDER BY | Complex injection patterns |
| `sanitize_title($title)` | Generates URL slug; strips tags, converts accents | URL slugs | NOT for display |
| `sanitize_url($url)` | Strips invalid chars, removes dangerous protocols | URL storage | Open redirects |
| `sanitize_user($username, $strict)` | Strips tags; strict: a-zA-Z0-9 _.@- only | Usernames | — |
| `absint($value)` | `abs(intval($value))` | Non-negative integers | Range validation |
| `wp_kses($content, $allowed_html)` | HTML filter keeping only specified tags/attributes | Rich HTML input | — |
| `wp_kses_post($data)` | wp_kses with 'post' context (extensive allowed tags) | Post content | XSS in allowed attributes |
| `wp_filter_nohtml_kses($data)` | Strips ALL HTML | Plain text only | — |

### Escaping functions

| Function | Context | Behavior |
|----------|---------|----------|
| `esc_html($text)` | Text inside HTML elements | Converts `& < > " '` to HTML entities |
| `esc_attr($text)` | HTML attribute values | Same entity conversion; does NOT double-encode |
| `esc_url($url)` | `href`/`src` attributes | Validates URL, strips dangerous protocols (javascript:, data:), encodes entities |
| `esc_url_raw($url)` | Database storage, API calls | Same as `esc_url` without entity encoding |
| `esc_js($text)` | Inline JS string literals | Escapes `' " & < >`, adds slashes |
| `esc_textarea($text)` | Inside `<textarea>` tags | `htmlspecialchars` with double-encoding |
| `esc_sql($data)` | **DEPRECATED** — use `$wpdb->prepare()` | `mysqli_real_escape_string` wrapper; does NOT add quotes |
| `esc_xml($text)` | XML content | Escapes for XML context |
| `wp_json_encode($data)` | JavaScript data embedding | `json_encode` with `JSON_HEX_TAG\|JSON_HEX_AMP\|JSON_HEX_APOS\|JSON_HEX_QUOT` — safe for `<script>` blocks |
| `tag_escape($tag_name)` | HTML tag names | Lowercases, strips non-alphanumeric chars except `_:` |

### Database security ($wpdb methods)

`$wpdb->prepare()` is the primary SQL injection defense. `$wpdb->insert()`, `$wpdb->update()`, `$wpdb->delete()`, and `$wpdb->replace()` use `prepare()` internally and are safe when used correctly. `$wpdb->query()`, `$wpdb->get_var()`, `$wpdb->get_row()`, `$wpdb->get_col()`, and `$wpdb->get_results()` require explicit `prepare()` for any variable data. `$wpdb->esc_like($text)` escapes `%` and `_` for LIKE queries — must be used inside `prepare()`.

### File upload security

- `wp_check_filetype($filename, $mimes)` — Extension-based only; does NOT examine file contents
- `wp_check_filetype_and_ext($file, $filename, $mimes)` — Checks actual file content via `finfo`/`getimagesize` plus extension
- `wp_handle_upload($file, $overrides)` — Complete upload handler: validates MIME type, moves to uploads dir, returns result array
- `validate_file($file, $allowed_files)` — Returns 0 (valid), 1 (contains `..`), 2 (contains `:/` or starts with `/`), 3 (not in allowed list) — **critical for preventing directory traversal**

### Cryptographic functions

- `wp_hash_password($password)` — As of WP 6.8: **bcrypt with SHA-384 pre-hashing** (prefix `$wp$2y$`). Previously phpass (MD5-based). Password length limit: 4096 chars.
- `wp_check_password($password, $hash, $user_id)` — Verifies password against hash; auto-rehashes old `$P$` format to bcrypt on verification
- `wp_generate_password($length, $special_chars, $extra_special_chars)` — Uses `wp_rand()` (cryptographically secure via `random_int()`)
- `wp_hash($data, $scheme)` — HMAC-MD5 using salts from wp-config.php
- `wp_rand($min, $max)` — CSPRNG wrapper using `random_int()` (PHP 7+)
- `wp_generate_uuid4()` — RFC 4122 UUID v4 using `random_bytes()`

---

## 4. Real CVEs and vulnerability patterns in major plugins (2023–2025)

### The most dangerous vulnerabilities of this period

**CVE-2024-10924 — Really Simple Security authentication bypass (CVSS 9.8)**. Affected 4 million installations. The `check_login_and_get_user()` function in the 2FA REST API returned a valid user object even on error conditions. Unauthenticated attackers could log in as any user, including admin, by sending crafted REST API requests with a `user_id` and invalid nonce. Wordfence called this "the most dangerous vulnerability they've seen in 12 years." WordPress.org forced an automatic security update.

**CVE-2023-28121 — WooCommerce Payments authentication bypass (CVSS 9.8)**. The `determine_current_user_for_platform_checkout()` function hooked into WordPress's `determine_current_user` filter and returned the user ID from the `X-WCPAY-PLATFORM-CHECKOUT-USER` HTTP header **without any validation**. Adding `X-WCPAY-PLATFORM-CHECKOUT-USER: 1` to any request authenticated as user ID 1 (admin). Wordfence detected **1.3 million attacks against 157,000 sites** on July 16, 2023.

**CVE-2024-28000 — LiteSpeed Cache privilege escalation (CVSS 9.8)**. The crawler simulation feature used `mt_rand()` seeded with microsecond time to generate security hashes — producing only ~1 million possible values. An unauthenticated AJAX endpoint (`async_litespeed`) had no capability or nonce checks, allowing anyone to trigger hash generation. The hash could then be brute-forced within hours to create admin accounts via the REST API.

**CVE-2023-32243 — Essential Addons for Elementor privilege escalation (CVSS 9.8)**. The password reset function in the Login/Register Form widget never validated the `rp_key` (reset key). It directly changed the user's password without calling `check_password_reset_key()`. The nonce was obtainable from the frontend page source. Wordfence blocked 6,900+ exploit attempts within days; Sucuri observed mass infection campaigns.

**CVE-2023-48777 — Elementor arbitrary file upload to RCE (CVSS 8.8)**. The template import AJAX handler allowed contributor-level users to upload files via base64-encoded `fileData`. A path traversal in the filename parameter (`/../../../../shell.php`) placed PHP webshells in web-accessible directories.

### Recurring vulnerability patterns

**Pattern 1: Missing/broken authorization on AJAX handlers** — The single most dangerous recurring pattern. Functions hooked to `wp_ajax_*` that check nonces but not capabilities. Affects WPForms, LiteSpeed Cache, Elementor Pro, and hundreds of smaller plugins.

**Pattern 2: XSS via insufficient output escaping** — 47.7% of all vulnerabilities in 2024. Most commonly Stored XSS at contributor+ level via shortcode attributes, widget settings, custom field values, and block attributes. Direct concatenation of user input into HTML output without `esc_attr()`, `esc_html()`, or `wp_kses()`.

**Pattern 3: Authentication bypass via REST API** — Improper `permission_callback` implementations, custom authentication hooks trusting user-supplied headers, error handling that falls through to success states, and case-sensitivity mismatches in route matching.

**Pattern 4: Weak/predictable security tokens** — Using `mt_rand()` with predictable seeds, empty API key hash comparisons (CleanTalk CVE-2024-10781), and non-constant-time string comparison for tokens.

**Pattern 5: PHP Object Injection** — Growing trend. UpdraftPlus (CVE-2024-10957), GiveWP (CVE-2024-9634), SEOPress (CVE-2024-5488). Using `unserialize()` or `maybe_unserialize()` on user-controlled data, combinable with POP chains in bundled libraries for RCE.

### Vulnerability statistics

| Metric | 2023 | 2024 | H1 2025 |
|--------|------|------|---------|
| Total new vulnerabilities | ~5,943 | 7,966 | ~6,700 |
| XSS percentage | ~45% | 47.7% | — |
| Broken access control | ~13% | 14.2% | — |
| CSRF | ~12% | 11.4% | — |
| Unauthenticated exploitation | ~40% | 43% | 57% |
| Contributor-level exploitation | ~30% | 34% | — |
| Unpatched rate | — | ~35% | — |

**96% of vulnerabilities originate from plugins**, 4% from themes, with only 7 in WordPress core (none critical) in 2024. In 2024, **1,018 vulnerabilities** were found in plugins with 100K+ installs, 115 in plugins with 1M+ installs, and 7 in plugins with 10M+ installs.

---

## 5. CVSS scoring calibration for WordPress context

### How authentication levels map to CVSS

CVSS v3.1's "Privileges Required" metric has only three levels (None, Low, High), while WordPress has 6+ distinct roles. This creates a fundamental mapping problem:

| WordPress Role | CVSS PR | Typical CVSS Range | Notes |
|---------------|---------|-------------------|-------|
| Unauthenticated | None | 9.0–10.0 (Critical) | No login required |
| Subscriber+ | Low | 7.0–8.5 (High) | Easiest authenticated role to obtain |
| Contributor+ | Low | 6.0–7.0 (Medium) | **34% of 2024 vulns** (Wordfence); same CVSS as subscriber |
| Author+ | Low | 5.5–7.0 (Medium) | Can upload files; same CVSS as subscriber/contributor |
| Editor+ | High or Low | 4.0–6.0 (Medium) | Inconsistently mapped |
| Administrator | High | 4.0–5.5 (Medium/Low) | Often "informational" or "won't fix" |

**Subscriber, contributor, and author all map to PR:Low** — a significant loss of nuance. Patchstack explicitly notes that "CVSS score is a way to evaluate and rank reported vulnerabilities in a standardized and repeatable way but which is not ideal for WordPress."

### Admin-only vulnerabilities: CVE vs won't fix

WordPress's security model **explicitly trusts administrators** on single-site installations. Admins have `unfiltered_html`, `install_plugins`, `edit_files` capabilities by design. Admin-only XSS on single-site is generally considered "by design."

**CVEs are assigned for admin-only vulnerabilities when:**
- The vulnerability affects **multisite** (where Site Admins ≠ Super Admins)
- The vulnerability involves **CSRF chains** (unauthenticated attacker tricks admin into action)
- Admin capabilities are **bypassed** (action executes without proper `current_user_can()` check)

**Company policies:**
- **Wordfence** assigns CVEs but flags admin-only issues as `"informational": true` in their data feed, scoring them with PR:High (typically CVSS 4–5)
- **Patchstack** assigns CVEs and CVSS scores but marks them "Low" priority in their proprietary system
- **WordPress HackerOne program** excludes vulnerabilities with CVSS below 4.0 unless chainable

### Patchstack Priority system vs raw CVSS

Patchstack created a WordPress-specific priority system in November 2023, acknowledging that **64.7% of WordPress vulnerabilities receive "Medium" CVSS scores** (even when requiring high privileges and unlikely to be exploited in practice). Their system categorizes into three levels:

- **High Priority** (patch in 0 days): Expected to be or already actively exploited. Only **11.6%** of vulnerabilities qualify.
- **Medium Priority** (patch in 7 days): Potentially exploitable in targeted attacks.
- **Low Priority** (patch in 30 days): Unlikely to be exploited in practice.

This reduces actionable alerts by **69.5%** compared to raw CVSS scoring.

### CNA ecosystem

Patchstack and Wordfence are both CVE Numbering Authorities (CNAs). In 2025, **Patchstack became the #1 CNA globally** with 7,007 CVEs assigned — more than Microsoft or Google. Together, Patchstack and Wordfence account for 10,000+ combined CVEs, making WordPress plugin security the dominant category of CVE issuance worldwide. All three major WordPress security databases (Wordfence, Patchstack, WPScan) use **CVSS v3.1** — none have adopted CVSS v4.0 as of early 2026.

---

## 6. Advanced attack techniques specific to WordPress

### PHP Object Injection and available gadget chains

When user-controlled data reaches `unserialize()` or `maybe_unserialize()`, attackers inject serialized PHP objects that exploit `__wakeup()`, `__destruct()`, or `__toString()` magic methods. The PHPGGC tool includes WordPress-specific POP chains. A documented chain uses `WC_Log_Handler_File::__destruct()` → `Requests_Utility_FilteredIterator::current()` → `call_user_func($this->callback, $value)` for RCE. Libraries bundled with plugins (Guzzle, Monolog, SwiftMailer, Symfony) provide additional gadget chains.

**WordPress core** fixed a POP chain vulnerability in WP 6.4.3 (January 2024) involving `WP_HTML_TOKEN` deserialization. Mitigation: use `json_encode()`/`json_decode()` instead of `serialize()`. If `unserialize()` is necessary, use the `allowed_classes` parameter: `unserialize($data, ['allowed_classes' => ['SafeClass']])`.

### Phar deserialization

PHP automatically deserializes Phar archive metadata when any filesystem function (`file_exists()`, `is_file()`, `fopen()`, `md5_file()`) encounters a `phar://` stream wrapper. Attackers upload a Phar file disguised as a JPEG (with valid image headers), then trigger file operations using `phar://path/to/malicious.jpg`. Sam Thomas demonstrated at Black Hat 2018 that author-level users could exploit `wp_get_attachment_thumb_file()` for RCE via this technique. **PHP 8.0+ disabled automatic Phar metadata deserialization**, but many sites still run PHP 7.x.

### Server-Side Template Injection

**WPML** (CVE-2024-6386, CVSS 9.9) is the landmark example. The WPML Multilingual CMS plugin (1M+ installations) used Twig to render shortcode content. The `[wpml_language_switcher]` shortcode passed content directly to `Twig_Environment::render()`. Injecting `{{ 4 * 7 }}` returned 28, confirming SSTI. RCE was achieved despite WordPress HTML-encoding quotes by using Twig's `block` feature and `_charset` variable to construct strings without quote characters. The **Timber** plugin (popular WordPress-Twig integration) has similar risk if user input reaches `Timber::compile_string()`.

### SSRF via WordPress HTTP functions

`wp_remote_get($url)` has **no URL validation** — full SSRF if the URL is user-controlled. `wp_safe_remote_get($url)` uses `wp_http_validate_url()` which restricts protocols (http/https), blocks private IPs, and limits ports (80, 443, 8080). **But it's vulnerable to DNS rebinding** (TOCTOU): CVE-2022-3590 demonstrated that the pingback feature validates URLs via DNS at check time, but the actual HTTP request may resolve to a different (internal) IP.

### Race conditions

WordPress plugins using check-then-act patterns (`get_user_meta()` → check → `update_user_meta()`) without database-level locking are vulnerable to concurrent request exploitation. MySQL's default `autocommit` mode means `FOR UPDATE` locks expire after each individual statement. Real examples include CVE-2022-3590 (SSRF via DNS rebinding TOCTOU) and vote manipulation in YOP Poll ≤ 6.5.26. Mitigation: use database transactions with `SELECT ... FOR UPDATE` within `BEGIN`/`COMMIT` blocks.

### XXE in WordPress

CVE-2021-29447 demonstrated XXE via the getID3 audio metadata library. On PHP 8+, `libxml_disable_entity_loader()` was deprecated and removed, re-enabling XXE. Crafted WAVE files with malicious iXML metadata exploit blind XXE to exfiltrate `wp-config.php` via the `LIBXML_NOENT` flag in `simplexml_load_string()`. SVG uploads are another vector — SVG files are XML-based, and plugins allowing SVG uploads without sanitization enable entity injection.

### CSV injection, timing attacks, path traversal, and Zip Slip

**CSV injection** affects any plugin with export-to-CSV functionality. Cells starting with `=`, `+`, `-`, `@`, `|` are interpreted as formulas in Excel/LibreOffice. Real CVEs include Contact Form 7 DB Extension (CVE-2018-9035) and Import Export WordPress Users (CVE-2019-15092). Mitigation: prefix cells with `'` (single quote).

**Timing attacks** exploit non-constant-time string comparison. WordPress Core uses `hash_equals()` since WP 3.9.2, but many plugins use `==` or `===` for token comparison (e.g., LiteSpeed Cache CVE-2024-28000).

**Path traversal** targets `wp-config.php`, `.htaccess`, and `wp-content/debug.log`. `validate_file()` checks for `..` and `:` but doesn't normalize paths. CVE-2018-12895 allowed author-level users to delete `wp-config.php` via directory traversal in the post thumbnail `unlink()` call, triggering WordPress reinstall for privilege escalation.

**Zip Slip**: WordPress < 4.8.2 was vulnerable in both `_unzip_file_ziparchive()` and `_unzip_file_pclzip()` — neither verified that the extracted path was within the target directory. Plugin import features that extract ZIP files (e.g., WP All Import < 3.6.9) often inherit this vulnerability.

---

## 7. Gutenberg block editor security deep dive

### The render_callback attack surface

Dynamic blocks use `render_callback` to generate HTML at render time. The callback receives `$attributes`, `$content`, and `$block`. **WordPress validates attributes against JSON Schema** via `rest_validate_value_from_schema()` — but this only checks types, not content. A `string` type attribute accepts any string, including XSS payloads. **No automatic HTML sanitization is applied** to attribute values.

The most critical pattern: block attributes stored in comment delimiter JSON (`<!-- wp:block {"attr":"value"} -->`) are **not subject to wp_kses filtering**. KSES operates on HTML content, not on JSON within HTML comments. A contributor can craft malicious JSON values in the Code Editor that pass type validation but contain XSS payloads, which then reach `render_callback` unescaped.

**CVE-2024-4439 (Avatar Block XSS, CVSS 7.2)** demonstrates the escaping order-of-operations pitfall: `esc_attr()` ran before `sprintf()`, so `$comment->comment_author` was inserted after escaping, bypassing it entirely. **Rule: escape as late as possible, after all string formatting.**

### Block comment delimiter manipulation

For dynamic blocks (`save` returns `null`), only the comment delimiter with JSON attributes is stored in `post_content`:
```
<!-- wp:latest-posts {"postsToShow":4,"displayPostDate":true} /-->
```

This JSON is parsed by WordPress's block parser and passed directly to `render_callback` as a PHP array. **Contributors can manipulate this JSON** via the Code Editor to inject attribute values that:
- Pass JSON Schema type validation but contain malicious strings
- Exploit XSS in unescaped `render_callback` output
- Trigger SQL injection if attributes are used in database queries
- Persist without wp_kses sanitization

### ServerSideRender and the block-renderer endpoint

`ServerSideRender` makes REST API requests to `/wp/v2/block-renderer/{block-name}`. The permission model requires `edit_posts` capability (contributors+ have this). Attribute validation uses `rest_validate_value_from_schema()` with `additionalProperties: false`. A contributor can trigger server-side rendering of any registered dynamic block with arbitrary type-valid attributes, enabling exploitation of render_callback vulnerabilities.

### Full Site Editing and Interactivity API

FSE templates (`wp_template`, `wp_template_part`) require `edit_theme_options` capability (Administrators only). Global styles use a special KSES filter `wp_filter_global_styles_post`. The **Interactivity API (WP 6.5+)** was designed with security as a priority: directive values are **references to named functions** in the store, not executable code. `data-wp-on--click="actions.toggle"` is valid; `data-wp-on--click="alert('xss')"` is not. The API is CSP-compliant and does not use `eval()` or `Function()`.

**Block Hooks (WP 6.4+)** allow plugins to auto-inject blocks into templates. Only dynamic blocks (save = null) can be hooked. Hooked blocks cannot be injected into user-modified templates or post content — only into theme-provided templates/parts/patterns. Users retain ultimate control via the Site Editor.

### Contributor-level block exploitation patterns

Contributors can access the full block editor, the Code Editor, the Custom HTML block, and the `/wp/v2/block-renderer/` endpoint. Key CVEs demonstrate the attack patterns:

- **Template Part Block** (< WP 6.5.5): Contributor+ Stored XSS via `tagName` attribute — `"tagName":"img src=x onerror=alert(1)"` exploited `esc_attr()` being used on a value placed as an HTML tag name
- **Avatar Block** (CVE-2024-4439): Escaping order-of-operations failure
- **Navigation Links Block** (< WP 6.3.2): Contributor+ Stored XSS
- Third-party block plugins (Spectra, Rank Math HowTo, etc.): Missing `esc_attr()`/`esc_html()` in render_callback output

---

## 8. Anti-patterns that lead to vulnerabilities

### The ten most dangerous coding mistakes

**1. Missing capability checks in AJAX handlers.** Hooks like `wp_ajax_*`, `admin_action_*`, `admin_post_*`, and `admin_init` provide zero built-in authorization. The Filester plugin (60K+ installs, CVE-2024-7031) verified the nonce but never called `current_user_can()`, allowing any subscriber to change plugin settings.

**2. Conditional nonce checks that can be bypassed.** If the nonce check is inside an `if (isset($_POST['action']))` block, omitting the `action` parameter skips verification entirely. Always check the nonce unconditionally.

**3. Using `is_admin()` as a security check.** This function checks whether the request targets wp-admin, not whether the user is an administrator. `admin-ajax.php` is in wp-admin, so `is_admin()` returns `true` for any authenticated user making AJAX requests.

**4. `esc_sql()` without quotes in SQL.** `esc_sql()` is useless for ORDER BY clauses because the value is unquoted. This caused blind SQL injection in NextGEN Gallery. **Allowlist column names** for ORDER BY; use `$wpdb->prepare()` with `%s`/`%d`/`%i` for everything else.

**5. Wrong escaping function for context.** Using `esc_html()` inside HTML attributes (doesn't escape quotes), `esc_attr()` for URLs (doesn't validate protocols), or no encoding for JavaScript contexts. The correct mapping: `esc_html()` for HTML body text, `esc_attr()` for attribute values, `esc_url()` for href/src, `wp_json_encode()` for JavaScript data.

**6. `wp_redirect()` without `exit`.** Code continues executing after the redirect header is set. Sensitive operations following the redirect still run. Always follow `wp_redirect()` or `wp_safe_redirect()` with `exit;`.

**7. Unescaped `add_query_arg()` output.** This function does NOT escape output. This caused XSS in dozens of major plugins including WP Super Cache, Jetpack, and Yoast SEO. Always wrap with `esc_url()`: `echo '<a href="' . esc_url(add_query_arg('foo', 'bar')) . '">Link</a>'`.

**8. LIKE queries without `esc_like()`.** User-supplied `%` and `_` characters in LIKE patterns create wildcard injection. Correct: `'%' . $wpdb->esc_like($search) . '%'` inside `$wpdb->prepare()`.

**9. Deserializing user input.** Using `unserialize()` on untrusted data enables PHP Object Injection. GiveWP (CVE-2024-9634, 100K+ installs) was exploited via an improperly deserialized parameter. Use `json_decode()` instead.

**10. Trusting database data in subsequent queries.** Second-order SQL injection occurs when data stored safely via `update_user_meta()` is later retrieved with `get_user_meta()` and concatenated into SQL without `$wpdb->prepare()`. Ultimate Member (CVE-2024-1071, CVSS 9.8) had an unauthenticated SQL injection via a `sorting` parameter where the ORDER BY clause lacked `$wpdb->prepare()`.

### REST API permission callback anti-patterns

The most common mistakes in REST API routes are: using `'__return_true'` as `permission_callback` (found in Download Monitor and Product Catalog Enquiry), creating a permission function that simply returns `true`, checking nonces instead of capabilities (which only proves the user is logged in, not authorized), omitting `permission_callback` entirely (public by default before WP 5.5, warning-only after), and inconsistent permission checks across related endpoints (GET properly restricted but DELETE using `__return_true`).

**Correct REST API endpoint pattern:**
```php
register_rest_route('myplugin/v1', '/settings', [
    'methods'             => WP_REST_Server::EDITABLE,
    'callback'            => 'update_settings_callback',
    'permission_callback' => function() {
        return current_user_can('manage_options');
    },
    'args' => [
        'setting_name' => [
            'required'          => true,
            'validate_callback' => function($value) {
                return is_string($value) && strlen($value) < 255;
            },
            'sanitize_callback' => 'sanitize_text_field',
        ],
    ],
]);
```

### File upload mistakes

The Advanced File Manager plugin (100K+ installs) used `strpos()` on `sanitize_file_name()` output to block `.htaccess` uploads, but `sanitize_file_name()` strips the leading dot, bypassing the check. Attackers uploaded `.htaccess` files to enable PHP execution in upload directories, then uploaded PHP webshells. Always use `wp_handle_upload()` with explicit MIME type allowlists rather than implementing custom upload validation.

---

RESEARCH RESOURCES

### WordPress-Specific Security Research

**Primary:**
- https://wpscan.com/vulnerabilities — WPScan vulnerability database
- https://www.wordfence.com/threat-intel/ — Wordfence threat intelligence
- https://patchstack.com/database/ — Patchstack vulnerability database
- https://plugins.trac.wordpress.org/ — WordPress plugin SVN (source code history & diffs)
- https://patchstack.com/academy/wordpress/getting-started/
- https://patchstack.com/academy/wordpress/getting-started/wp-hacking/
- https://patchstack.com/academy/wordpress/getting-started/wordpress-setup/
- https://patchstack.com/academy/wordpress/getting-started/wordpress-tips-and-tricks/
- https://patchstack.com/academy/wordpress/getting-started/cve-reversing/
- https://patchstack.com/academy/wordpress/vulnerabilities/arbitrary-file-deletion/
- https://patchstack.com/academy/wordpress/vulnerabilities/arbitrary-file-read/
- https://patchstack.com/academy/wordpress/vulnerabilities/arbitrary-file-upload/
- https://patchstack.com/academy/wordpress/vulnerabilities/broken-access-control/
- https://patchstack.com/academy/wordpress/vulnerabilities/content-injection/
- https://patchstack.com/academy/wordpress/vulnerabilities/cross-site-request-forgery/
- https://patchstack.com/academy/wordpress/vulnerabilities/cross-site-scripting/
- https://patchstack.com/academy/wordpress/vulnerabilities/local-file-inclusion/
- https://patchstack.com/academy/wordpress/vulnerabilities/open-redirect/
- https://patchstack.com/academy/wordpress/vulnerabilities/php-object-injection/
- https://patchstack.com/academy/wordpress/vulnerabilities/privilege-escalation/
- https://patchstack.com/academy/wordpress/vulnerabilities/race-condition/
- https://patchstack.com/academy/wordpress/vulnerabilities/remote-code-execution/
- https://patchstack.com/academy/wordpress/vulnerabilities/sensitive-data-exposure/
- https://patchstack.com/academy/wordpress/vulnerabilities/server-side-request-forgery/
- https://patchstack.com/academy/wordpress/vulnerabilities/sql-injection/
- https://patchstack.com/academy/wordpress/vulnerabilities/type-juggling/
- https://patchstack.com/academy/wordpress/wordpress-internals/functions/
- https://patchstack.com/academy/wordpress/wordpress-internals/hooks/	

**Researcher Blogs & Write-ups:**
- https://blog.wpscan.com — WPScan research blog
- https://www.wordfence.com/blog/ — Wordfence vulnerability disclosures (rất chi tiết)
- https://patchstack.com/articles/ — Patchstack research articles
- https://www.rcesecurity.com — RCE Security (WP focus)
- https://blog.nintechnet.com — NinTechNet (NinjaFirewall) research

**WordPress Core Security:**
- https://developer.wordpress.org/apis/security/ — Official security documentation
- https://developer.wordpress.org/rest-api/ — REST API documentation
- https://core.trac.wordpress.org/ — WordPress core Trac (bugs & patches)

### General Web Security (áp dụng cho WP)
- https://cheatsheetseries.owasp.org — OWASP Cheat Sheet Series
- https://portswigger.net/web-security — PortSwigger Web Security Academy
- https://cwe.mitre.org — CWE (Common Weakness Enumeration)

### Chinese Security Resources (WP-relevant)
- https://www.freebuf.com — FreeBuf (search "WordPress" cho PoCs)
- https://xz.aliyun.com — Xianzhilou (search "WordPress plugin" cho Chinese researcher write-ups)
- https://paper.seebug.org — Seebug papers (WordPress exploit analysis)


## Conclusion

The WordPress plugin security landscape in 2023–2025 reveals that **the same vulnerability patterns recur with striking consistency** across plugins of all sizes. Missing authorization checks on AJAX/REST endpoints, insufficient output escaping, and broken authentication logic in REST API permission callbacks account for the vast majority of critical vulnerabilities. The REST API has displaced traditional AJAX as the primary attack surface for critical-severity issues, while contributor-level Stored XSS via block attributes and shortcodes dominates the volume statistics.

Three architectural insights stand out. First, WordPress's "nonces verify intent, not authorization" design means that every plugin developer must actively implement authorization — the framework provides no safety net. Second, the Gutenberg block comment delimiter JSON creates a sanitization gap: `wp_kses` filters HTML content but does not touch JSON in block comments, making `render_callback` escaping the sole defense against Stored XSS in dynamic blocks. Third, WordPress 6.8's shift to bcrypt password hashing and BLAKE2b for application passwords represents the most significant cryptographic upgrade in WordPress history, but plugin-level cryptographic storage (API keys, tokens) remains overwhelmingly insecure.

For security auditors, the priority matrix is clear: **audit all AJAX and REST API endpoints first** (check every handler for both nonce verification AND capability checking), then review all output contexts for proper escaping (especially `render_callback` in blocks and shortcode output), then examine authentication/authorization logic in custom login/registration flows, and finally review file operations and database queries for injection vulnerabilities. The Patchstack Priority system's finding that only 11.6% of vulnerabilities are truly high-risk (versus CVSS's 34.8% high/critical classification) should guide triage decisions in large audit engagements.


-------------
# Patchstack bug bounty program: complete rules and guidelines

**Patchstack operates the WordPress ecosystem's largest bug bounty program, with rules that diverge sharply from generic vulnerability programs by enforcing WordPress-specific thresholds for CVSS scores, user roles, install counts, and vulnerability impact.** The current ruleset — the "2026 edition" updated February 1, 2026 — spans 26 sections governing everything from scope and scoring to payouts up to **$33,000** per vulnerability. The program uses CVSS v3.1 base scores as its primary severity metric but layers on a proprietary "Patchstack Priority" system that classifies real-world exploitability into High, Medium, and Low tiers. Understanding these rules is essential for researchers: roughly **69.6%** of all reported vulnerabilities receive Low priority (considered theoretical), and the program explicitly rejects admin-only bugs, low-CVSS issues, and several common vulnerability classes outright.

---

## Scope: what Patchstack accepts and what it rejects

### In-scope components

The program accepts vulnerability reports for three component categories in the WordPress ecosystem: **WordPress core, WordPress plugins, and WordPress themes** — both free and premium versions. For premium components, researchers must supply the original, unmodified archive file for validation, along with any dependent plugins a theme requires. Components must be publicly available through WordPress.org, the vendor's official website, GitHub, CodeCanyon, or ThemeForest. Custom-made, modified, or privately distributed components are excluded.

### Active install thresholds

A component must have **100 or more active installs** to qualify, with two narrow exceptions. First, components enrolled in an active Patchstack mVDP (managed Vulnerability Disclosure Program) are accepted regardless of install count. Second, vulnerabilities scoring **CVSS 8.0+** in components with at least **50 active installs** qualify if the prerequisite is not admin or higher. Components whose last version was released more than **three years ago** are out of scope, as are vulnerabilities that no longer exist in the latest version (silently patched but never disclosed).

### Out-of-scope categories

The following are explicitly excluded from the program:

- **Admin-only vulnerabilities**: Any vulnerability requiring Administrator, Super Admin, or equivalent custom role privileges is rejected outright — no exceptions
- **CVSS below 5.3**: Not accepted for direct submission, with one exception pathway (vendor confirms the issue and requests Patchstack CVE assignment) and one threshold reduction (CVSS **4.3+** accepted if the component has **100,000+ active installs** or an active mVDP program)
- **CAPTCHA or Turing test bypass**: Categorically rejected
- **Arbitrary user registration**: Rejected unless it results in creation of an arbitrary administrator account
- **CSV injection**: Rejected because it depends on external actions outside WordPress
- **IP spoofing**: Rejected unless it directly affects a feature relying on IP integrity (such as IP-based blocking) that is explicitly intended to resist spoofing
- **Race conditions below CVSS 7.0**: Rejected unless clear security impact is demonstrated (a stricter threshold than the general 5.3 minimum)
- **Authenticated shortcode preview issues** (Contributor+): Rejected unless sensitive/PII data is disclosed with measurable impact — however, this exclusion **does not apply to XSS vulnerabilities**
- **CSRF or Broken Access Control that only dismisses notices**: Rejected unless the dismissal creates real security impact
- **IP bypass for non-critical actions**: Likes, views, counters, and similar non-security-relevant functionality are excluded
- **Closed, inaccessible, or non-publicly-distributed components**

---

## Vulnerability type rules: what qualifies and what doesn't

### XSS: stored versus reflected, and authentication levels

Patchstack accepts XSS at all non-admin privilege levels. **Contributor+ Stored XSS** is the most commonly reported type in the WordPress ecosystem, typically exploiting shortcode, Gutenberg block, or Elementor widget implementations where a Contributor creates a drafted post with an XSS payload and sends a preview link to privileged users. Subscriber+ and Unauthenticated Stored XSS are accepted and valued progressively higher. Reflected XSS is accepted at all non-admin levels but scores lower on CVSS due to the user interaction requirement. Notably, the shortcode preview exclusion (Rule 3.4) specifically exempts XSS — XSS via shortcode previews **is** accepted even when other shortcode preview issues would be rejected. For testing Editor+ or Admin+ XSS, researchers must disable `unfiltered_html` via `DISALLOW_UNFILTERED_HTML` in wp-config.php, since WordPress grants this capability to Administrators and Editors by default on single-site installations.

### CSRF: accepted but devalued

CSRF vulnerabilities are accepted but carry the **lowest XP multiplier at x0.25**, reflecting their lower impact assessment. The critical exception: **CSRF that chains to another vulnerability type** (e.g., CSRF leading to RCE, SQLi, or Stored XSS) receives **both multipliers** — so CSRF-to-RCE would be x0.25 × x3. CSRF or Broken Access Control issues that merely dismiss admin notices are rejected unless the dismissal creates genuine security impact. All CSRF submissions must still meet the CVSS 5.3+ floor.

### SQL injection

SQLi receives a **x2 XP multiplier** and is accepted at all non-admin privilege levels. Patchstack notes that WordPress's `wp_magic_quotes()` auto-escapes inputs, making many seemingly vulnerable code paths unexploitable in practice — researchers must demonstrate actual exploitability. Common vectors include improper `$wpdb->prepare()` usage, direct string concatenation in SQL queries, and ORDER BY clause injection. Unauthenticated SQLi leading to full site compromise qualifies for Zeroday bounties.

### File upload, deletion, and download

**Arbitrary file upload** and **arbitrary file deletion** both receive the **highest multiplier (x3)** — file upload because uploading a PHP backdoor equals full site compromise, and file deletion because deleting wp-config.php can reset a WordPress installation. Arbitrary file deletion was upgraded from x1.5 in previous editions to x3 in the current rules. **Arbitrary file download/read** receives a **x1.5 multiplier**.

### PHP Object Injection and Insecure Deserialization

Both receive a **x2 multiplier**. For Zeroday bounty eligibility, any required POP (Property Oriented Programming) chain must exist in the latest WordPress core version at submission time or within the affected component itself — chains relying on third-party plugins or outdated core versions do not qualify.

### Privilege escalation and authentication bypass

Privilege escalation to Admin gets the **x3 multiplier** (highest tier), while escalation to non-Admin roles gets **x1.5**. Authentication bypass is classified based on what access it grants. Unauthenticated authentication bypass leading to admin access qualifies for Zeroday bounties at the highest payout tier.

### SSRF, open redirect, information disclosure, and DoS

**SSRF** is accepted and tracked in the database but carries no special multiplier (default x1). **Open redirect** is recognized but often scores CVSS 4.3–4.7, which may place many instances below the 5.3 acceptance threshold — only open redirects in very popular components (100K+ installs with the 4.3 threshold) or those with higher CVSS scores would qualify. **Information disclosure** must demonstrate "clear and measurable security impact" — generic information leaks without measurable impact are rejected, while PII exposure is accepted. **DoS and rate limiting** are not explicitly addressed in the rules, have no specific multiplier, and would need to meet the general CVSS 5.3+ threshold with demonstrated measurable impact.

---

## CVSS scoring and Patchstack Priority: a dual system

### CVSS v3.1 base score requirements

Patchstack uses **only the CVSS v3.1 base score** (not Temporal or Environmental scores) for all calculations, computed via the official FIRST calculator. They explicitly acknowledge that "CVSS score is a way to evaluate and rank reported vulnerabilities in a standardized and repeatable way, but it is not ideal for WordPress/CMSs." To compensate, they add WordPress-specific context — most importantly mapping the "Privileges Required" vector to WordPress roles (Unauthenticated = "None"; any logged-in user including Subscriber = "Low"). The severity bands used in the Patchstack dashboard are: **Low** (0.0–3.9), **Medium** (4.0–6.9), **High** (7.0–8.9), and **Critical** (9.0+).

### Patchstack Priority: the real-world exploitability layer

Introduced in November 2023, Patchstack Priority supplements CVSS with dynamic, WordPress-specific threat assessment. **High Priority** vulnerabilities are expected to become actively mass-exploited or are already known to be exploited — they receive a virtual patching (vPatch) rule and carry a recommended time-to-patch of **0 days**. **Medium Priority** vulnerabilities could be exploited in targeted attacks, receive a vPatch rule, and carry a **7-day** patching window. **Low Priority** vulnerabilities are "not expected to become exploited," are considered "often theoretical," do **not** receive a vPatch, and carry a **30-day** patching window. In 2024 data, **11.6%** received High priority, **18.8%** Medium, and **69.6%** Low — meaning Patchstack Priority helps users cut noise by roughly 70% compared to CVSS alone.

The Priority system analyzes seven variables: vulnerability prerequisites, vulnerability type (RCE is more exploitation-prone than CSRF), software characteristics and install count, standard CVSS scores, active exploitation attempts monitored in real-time, historical exploitation patterns for similar vulnerabilities, and Known Exploited Vulnerabilities (KEV) tracking. Priority is **dynamic** — it updates as new threat data emerges.

---

## Reporting requirements, PoC standards, and duplicate handling

### Proof of concept requirements

Every report must include four mandatory elements: a clear, **step-by-step text-based proof of concept** starting from plugin/theme installation and ending with successful exploitation; all required **raw HTTP requests in text form**; the **exact payloads** used during testing; and a submission through the official reporting form at patchstack.com/database/report. Video screenshots are "highly appreciated" but not strictly required. Reports sent via email or any other channel are rejected. The reporting form requires: component type, name, slug, vulnerable version (format: ≤ X.X.X), OWASP Top 10 class, specific vulnerability type, minimum privilege required, description, and step-by-step reproduction instructions.

### Duplicate and resubmission policies

All vulnerabilities must be new and unique — not previously reported or publicly disclosed. If multiple researchers report the same vulnerability (even across different parameters or endpoints), **credit goes to the first valid submission only**. Attempting to manipulate this through multiple accounts or cross-program duplicate submissions can result in account suspension. One exception exists: vulnerabilities first reported directly to the vendor before Patchstack submission are accepted if the vendor confirms and indicates willingness to patch. This is **mandatory** for Automattic components, which must first go through Automattic's HackerOne program.

Incomplete patches that are publicly disclosed are **not** considered new vulnerabilities. However, if an incomplete patch introduces a **genuinely new attack vector** not previously possible, it may qualify as a new submission. Researchers get **up to two chances** to fix and resubmit rejected reports. Three rejected submissions within one month triggers suspension for the remainder of that month plus the following month. Repeated AI-generated false-positive submissions trigger a one-month cooldown; continued abuse results in permanent account lock.

---

## User interaction, multisite, and premium plugin rules

### When user interaction matters

User interaction is factored into CVSS scoring through the User Interaction vector. For **regular bounties**, vulnerabilities requiring user interaction (reflected XSS, CSRF, Contributor+ stored XSS via post preview) are fully accepted but naturally score lower on CVSS. Database entries for such vulnerabilities note: "successful exploitation requires a privileged user to perform an action — such as clicking a malicious link, visiting a crafted page, or submitting a form." For **Zeroday bounties**, user interaction is a hard disqualifier — exploitation must require **zero user interaction**, along with default settings, latest stable version, common environment, and no additional vulnerabilities.

### Multisite versus single-site

The bug bounty rules contain **no explicit multisite vs. single-site distinction**. The primary relevant difference is WordPress's `unfiltered_html` capability: on single-site installations, both Administrators and Editors have it, while on multisite, only Super Admins do. This means an Admin-level XSS on multisite could theoretically have more impact (since Admin lacks `unfiltered_html`), but since admin-level prerequisites are categorically excluded from the bounty program, this distinction has limited practical relevance. Vulnerabilities affecting only multisite installations remain valid if they meet all other criteria.

### Premium versus free components

Both free and premium plugins/themes are accepted **under identical conditions**. The only additional requirement for premium components is that researchers must provide the original, unmodified archive file for validation. Active install counts for premium products are estimated based on sales volume rather than WordPress.org install metrics. The mVDP program is free for all developers regardless of whether their software is free or premium.

---

## Disclosure timeline and escalation protocol

Patchstack validates submitted vulnerabilities within **72 hours** of receipt. After validation, the vendor is contacted through the most efficient publicly listed contact channels — Patchstack will not create accounts for vendor support forums or ticketing systems. The standard disclosure window is **30 days** from the first vendor contact attempt. If a vendor fails to respond within **7 days**, Patchstack reserves the right to disclose immediately. The bug bounty rules add that if a vendor does not respond within **14 days**, Patchstack may proceed with public disclosure and notify relevant security teams. For mVDP-enrolled components, timelines may be extended, while disclosure may be **accelerated** in cases of active exploitation or third-party disclosure.

Starting with the 2026 edition, all publications comply with **EU Cyber Resilience Act** requirements: disclosure is instant once the patch is released and validated. Patches must be released as dedicated security-only updates with no bundled code modifications, and the version number or changelog must clearly indicate a security fix. Researchers are prohibited from disclosing vulnerability details to any third party before official Patchstack public disclosure (when the vulnerability becomes publicly visible in the database and the CVE is published). Patchstack is a CVE Numbering Authority (CNA), assigning unique CVE IDs to each valid submission, with assignment potentially delayed to prevent conflicts between multiple CNAs in the WordPress ecosystem.

---

## Bounty structure and XP calculation mechanics

### Monthly competition

Monthly competitions run from the first to the last day of each month (UTC). Patchstack guarantees a minimum monthly pool of **$8,800** distributed across the top 20 researchers: 1st place earns **$2,000**, 2nd gets $1,400, 3rd gets $800, scaling down to $50 for 20th place plus one randomly selected researcher outside the top 20 who submitted at least one valid report with XP greater than zero. XP is calculated as: **CVSS base score × Active install multiplier × Privilege requirement multiplier × Vulnerability type multiplier**. No XP is awarded if the component has fewer than 500 active installs or requires admin/super-admin role, though CVE IDs are still issued.

### Zeroday bounties

Separate from the monthly competition, Zeroday bounties reward individual high-impact vulnerabilities on a per-report basis. Requirements are strict: the vulnerability must lead to **full site compromise** including ability to upload and access a functional backdoor, be exploitable by unauthenticated users or Subscriber/Customer roles, include a working exploit, require no user interaction, no prerequisites beyond default settings, and not be previously known. Payouts scale from **$125** (Subscriber-level, 1,000+ installs) to **$33,000** (unauthenticated, 15M+ installs or WordPress core). Zeroday XP does not contribute to monthly competition rankings or level progression since they are rewarded separately.

### Level rewards

Researchers earn passive rewards through cumulative XP across monthly competitions, custom events, and Zeroday bounties. Twelve levels range from Level 1 ($50 at 100 XP) through Level 12 ($5,000 at 19,000 XP). Levels reset to Level 1 at the start of each calendar year.

---

## Conclusion

Patchstack's bug bounty program is unusually prescriptive compared to generic programs, reflecting the specific threat landscape of WordPress's plugin ecosystem. The most consequential rules for researchers are the **blanket exclusion of admin-level vulnerabilities**, the **CVSS 5.3 floor** (reduced to 4.3 only for very popular components), and the **100-install minimum** — together, these three gates filter out the majority of potential submissions before any technical evaluation begins. The Patchstack Priority system's finding that nearly 70% of reported vulnerabilities are "theoretical" and unlikely to be exploited underscores the program's emphasis on **meaningful, real-world impact** over vulnerability volume. Recent 2024–2026 updates show a clear trajectory: higher bounties (doubled pool, Zeroday payouts up to $33,000), stricter quality controls (AI false-positive penalties, dedicated security-only patch requirements), and EU regulatory alignment through instant post-patch disclosure. Researchers maximizing their returns should focus on unauthenticated or subscriber-level vulnerabilities in plugins with 100K+ installs, prioritizing RCE, arbitrary file upload/deletion, and privilege escalation to admin — the vulnerability types that earn both the highest XP multipliers and Zeroday bounty eligibility.