# Plugin Overview

Hostinger Reach 1.4.4 is an email-marketing integration plugin that links a WordPress site to a Hostinger Reach tenant, syncs contacts, and exposes a small set of public contact/linking routes plus admin-gated management APIs. This Phase 3b skeptic pass reviewed only the single Phase 3a finding that remained `UNCERTAIN` and focused on counter-evidence, line correction, missing evidence, and dynamic verification.

# Validation Summary

- Reviewed: 1
- Downgraded: 1
- Kept: 0
- Upgraded: 0

# Detailed Reviews

Finding ID: `HOSTINGER-REACH-P2-REV-001`
Type: `Broken Access Control`
Minimum Role/Capability: `none, but only if the attacker first obtains a valid linking secret from either the manage_options flow or the server-held /.api_token file`
Status Transition: `UNCERTAIN -> downgrade`
Description: The Phase 2 public token-linking hypothesis maps to the real `POST /wp-json/hostinger-reach/v1/token` route, and the sink should be corrected to `ApiKeyManager::store_token()` at `plugins/hostinger-reach/src/Api/ApiKeyManager.php:18-21`. I recommend downgrading because the repository does not expose either accepted secret to an unauthenticated actor: the transient is created only behind `current_user_can( 'manage_options' )`, and the `/.api_token` fallback is only read server-side from a server-derived filesystem path.
Highest Impact: If an attacker somehow learns one accepted linking secret, they can overwrite `hostinger_reach_api_key` and rebind later Reach dashboard or sync traffic to a different Reach account.
PoC: `setup -> activate the plugin and, for controlled validation, obtain a real linking secret either by calling POST /wp-json/hostinger-reach/v1/generate-auth-url as an administrator or by reading the resolved /.api_token path out of band; attack -> from an unauthenticated client, POST /wp-json/hostinger-reach/v1/token with csrf_field=<accepted secret>&token=<attacker Reach API token>; verify impact -> use an administrator X-WP-Nonce to GET /wp-json/hostinger-reach/v1/overview and confirm whether the Reach account context changed.`
Counter-evidence + dynamic test plan:
- Counter-evidence: `plugins/hostinger-reach/src/Api/Routes/ReachRoutes.php:86-89` makes `/token` conditional on `ApiKeyManager::validate_csrf()`, so the route is not a bare public write.
- Counter-evidence: `plugins/hostinger-reach/src/Api/Routes/ReachRoutes.php:104-110` and `plugins/hostinger-reach/src/Api/Routes/Routes.php:25-33` show the repo-visible transient minting path, `POST /generate-auth-url`, is gated by `current_user_can( 'manage_options' )`.
- Counter-evidence: `plugins/hostinger-reach/src/Api/Handlers/ReachApiHandler.php:215-220` repeats `validate_csrf()` before `store_token()`, so the same secret check is enforced again at the sink.
- Counter-evidence: `plugins/hostinger-reach/src/Api/ApiKeyManager.php:80-85` computes `/.api_token` from the first two filesystem path segments instead of a plugin or `wp-content` URL path, which is a direct code-level sign that the fallback file is intended to stay server-side.
- Counter-evidence: `plugins/hostinger-reach/src/Providers/SurveysProvider.php:27-36`, `plugins/hostinger-reach/vendor/hostinger/hostinger-wp-surveys/src/Loader.php:54-64`, `plugins/hostinger-reach/vendor/hostinger/hostinger-wp-surveys/src/SurveyLoader.php:23-35`, and `plugins/hostinger-reach/vendor/hostinger/hostinger-wp-menu-manager/src/templates/menu.php:66-70` reuse the token only in server-side outbound headers or a boolean menu check; this review did not find any browser-facing echo or localization of the token value.
- Missing evidence: no repo-visible path lets an unauthenticated or low-privileged user obtain either the admin-generated transient or the contents of the resolved `/.api_token` file.
- Missing evidence: no deployment evidence yet shows that the resolved `/.api_token` path is web-accessible or otherwise reachable from a remote attacker channel.
- Missing evidence: no end-to-end trace yet shows that overwriting `hostinger_reach_api_key` measurably rebinds later Reach API calls to an attacker-controlled tenant.
- Dynamic test plan: as an administrator, send `POST /wp-json/hostinger-reach/v1/generate-auth-url` with a valid `X-WP-Nonce`, capture the `auth_url`, and confirm the linking token only appears after the `manage_options`-gated action.
- Dynamic test plan: as an unauthenticated client, send `POST /wp-json/hostinger-reach/v1/token` with `{"csrf_field":"invalid","token":"attacker-reach-token"}` and verify the request fails and the stored option does not change.
- Dynamic test plan: only if one accepted secret is available out of band, replay `POST /wp-json/hostinger-reach/v1/token` with that exact `csrf_field` and then verify account rebinding by requesting `GET /wp-json/hostinger-reach/v1/overview` from an administrator session.
- Dynamic test plan: on the target deployment, print `ApiKeyManager::get_api_token_path()` once via shell or debug logging and confirm whether the resolved file sits outside the document root, because that environmental fact decides whether the fallback is remotely obtainable at all.

# Negative Findings

- `plugins/hostinger-reach/src/Api/Routes/ReachRoutes.php:104-110` and `plugins/hostinger-reach/frontend/vue/views/WelcomeView.vue:19-33` show the intended connect flow still starts from an administrator-only `generate-auth-url` request before redirecting the browser to Hostinger auth.
- `plugins/hostinger-reach/src/Setup/Assets.php:54-72` localizes only the normal `wp_rest` nonce and site metadata to the admin SPA; it does not expose `hostinger_reach_csrf_token` or the `/.api_token` contents.
- `plugins/hostinger-reach/src/Api/ApiKeyManager.php:18-21` proves the disputed sink exists at line 18, so the Phase 3a line mismatch was a correction issue rather than evidence of an additional arbitrary option-write primitive.

# Overall Assessment

The deterministic gate should remain authoritative, but the strongest skeptic reading supports `UNCERTAIN -> downgrade` rather than `keep`. The code proves a public callback that accepts server-held secrets, yet the repository still lacks the missing evidence that a real web attacker can obtain one of those secrets and turn the route into a practical account-rebinding exploit.
