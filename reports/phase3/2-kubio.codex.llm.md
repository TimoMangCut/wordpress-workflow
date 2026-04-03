# Plugin Overview

Kubio is a site-builder plugin that exposes privileged REST and AJAX flows for snippet export, cloud synchronization, and starter-site imports. This Phase 3b skeptic pass only reviewed the two Phase 3a findings that remained `UNCERTAIN`, and focused on counter-evidence, file:line correction, and dynamic verification gaps.

# Validation Summary

- Reviewed: 2
- Downgraded: 0
- Kept: 2
- Upgraded: 0

# Detailed Reviews

Finding ID: `KUBIO-P2-REV-001`
Type: `Path Traversal to Arbitrary File Read with Second-Order Cloud Exfiltration`
Minimum Role/Capability: `authenticated user with edit_theme_options; most relevant on multisite site-admin contexts`
Status Transition: `UNCERTAIN -> keep`
Description: `kubio_save_block_snippet()` still passes attacker-controlled snippet JSON into `kubio_create_snippet_zip()`, and the ZIP builder still concatenates captured upload-path suffixes onto `wp_get_upload_dir()['basedir']` before `file_get_contents()` at `plugins/kubio/lib/api/colibri.php:278-282`. The claim remains uncertain because the repository only shows server-side upload to Kubio cloud, not attacker-visible retrieval of the resulting archive with an attacker-controlled API key.
Highest Impact: If the cloud handoff is attacker-retrievable, a user at this trust boundary could move sensitive local file contents such as `wp-config.php` into a remote snippet archive.
PoC: `setup -> install and activate Kubio, log in as a user who can pass edit_theme_options, and store an attacker-controlled cloud key through POST /wp-json/kubio/v1/kubio-api-key; attack -> replay a legitimate POST /wp-json/kubio/v1/snippet request after replacing one uploads URL inside snippet JSON with https://target.example/wp-content/uploads/../../wp-config.php; verify impact -> capture the outbound /api/snippets/save ZIP or download the created cloud snippet and inspect it for the target file contents.`
Counter-evidence + dynamic test plan:
- Counter-evidence: `plugins/kubio/lib/api/colibri.php:54` gates `/snippet` with `current_user_can('edit_theme_options')`, so the route is not public.
- Counter-evidence: `plugins/kubio/lib/api/kubio-cloud.php:29` gates `/kubio-api-key` writes behind the same `edit_theme_options` capability, keeping the API-key change in the same trust zone as the snippet export.
- Counter-evidence: `plugins/kubio/lib/api/colibri.php:139` sends the archive to `Utils::getSnippetsURL('/save')`, and `plugins/kubio/plugin.php:67-69` fixes `KUBIO_CLOUD_URL` to `https://cloud.kubiobuilder.com`, which refutes arbitrary-host SSRF.
- Missing evidence: show that a forged uploads URL containing `../` survives the normal client serialization path and reaches `kubio_create_snippet_zip()` unchanged.
- Missing evidence: show that a valid attacker-controlled Kubio cloud key can be set through `/wp-json/kubio/v1/kubio-api-key` and later used to retrieve the uploaded archive.
- Missing evidence: capture the outbound ZIP or a downloaded cloud artifact proving that a sensitive local file was actually embedded.
- Dynamic test plan: POST `/wp-json/kubio/v1/kubio-api-key` with `{"key":"<attacker-valid-cloud-key>"}` using the victim session's cookies and `X-WP-Nonce`, then POST `/wp-json/kubio/v1/snippet` with a legitimate captured body whose `snippet` JSON now contains `https://<target>/wp-content/uploads/../../wp-config.php`.
- Dynamic test plan: intercept `https://cloud.kubiobuilder.com/api/snippets/save` with a local proxy, `pre_http_request` hook, or hosts override so the ZIP body can be inspected without depending on undocumented cloud retrieval paths.

Finding ID: `KUBIO-P2-REV-002`
Type: `Insufficient Capability Check for Plugin Installation/Activation`
Minimum Role/Capability: `authenticated user who can satisfy current_user_can('import') and obtain the demo-site nonce`
Status Transition: `UNCERTAIN -> keep`
Description: `DemoSites::installPlugin()` and `DemoSites::activatePlugin()` still rely on `DemoSitesHelpers::verifyAjaxCall()` and then call `PluginsManager` without a Kubio-side `install_plugins` or `activate_plugins` check at `plugins/kubio/lib/src/DemoSites/DemoSites.php:327-357`. The claim remains uncertain because the repository does not yet prove a real web actor below the normal plugin-management boundary can both satisfy `current_user_can('import')` and obtain a live `kubio-ajax-demo-site-verification` nonce.
Highest Impact: If such an actor exists, the measurable change is installation and activation of a WordPress.org plugin they should not be able to manage.
PoC: `setup -> install and activate Kubio on a multisite lab and log in as a non-super-admin user whose capability map is under test; attack -> POST /wp-admin/admin-ajax.php with action=kubio-demo-site-install-plugin&slug=hello-dolly&nonce=<live-kubio-nonce>, then repeat with action=kubio-demo-site-activate-plugin; verify impact -> confirm the same user could not do the equivalent action through core plugin-management UI but the plugin becomes installed or active anyway.`
Counter-evidence + dynamic test plan:
- Counter-evidence: `plugins/kubio/lib/src/DemoSites/DemoSitesHelpers.php:16-19` requires both `check_ajax_referer( 'kubio-ajax-demo-site-verification', 'nonce' )` and `current_user_can( 'import' )`.
- Counter-evidence: `plugins/kubio/lib/admin-pages/main-page/demo-sites.php:7-17` blocks the starter-sites admin page for users without `edit_theme_options`, so one documented nonce emission surface is already privileged.
- Counter-evidence: `plugins/kubio/lib/editor-assets.php:378` localizes the same nonce into editor data, and `plugins/kubio/lib/kubio-editor.php:978-980` only registers the Kubio editor menu for users with `edit_theme_options`.
- Counter-evidence: `plugins/kubio/lib/src/PluginsManager.php:48-54` constrains installation to WordPress.org plugin slugs resolved by `plugins_api( 'plugin_information', ... )`, so this is not an arbitrary ZIP or arbitrary URL install path.
- Counter-evidence: `plugins/kubio/lib/src/PluginsManager.php:79-99` activates only installed plugin basenames resolved from `get_plugins()`, not arbitrary files.
- Missing evidence: prove a concrete web role on the target deployment that has `current_user_can( 'import' )` but lacks `install_plugins` and `activate_plugins`.
- Missing evidence: prove that the same role can obtain a live Kubio nonce from an interface it can really access, rather than from a surface already gated by `edit_theme_options`.
- Missing evidence: show an end-to-end run where the Kubio AJAX call succeeds while the equivalent core plugin-management action is denied to the same user.
- Dynamic test plan: in a multisite lab, record the result of `current_user_can( 'import' )`, `current_user_can( 'install_plugins' )`, `current_user_can( 'activate_plugins' )`, and `current_user_can( 'edit_theme_options' )` for the candidate actor before sending any AJAX.
- Dynamic test plan: with that same session, send `POST /wp-admin/admin-ajax.php` body `action=kubio-demo-site-install-plugin&slug=hello-dolly&nonce=<nonce>` and then `action=kubio-demo-site-activate-plugin&slug=hello-dolly&nonce=<nonce>`, and verify whether plugin state changes despite core plugin-management denial.

# Negative Findings

- `plugins/kubio/lib/api/colibri.php:139` and `plugins/kubio/plugin.php:67-69` fix the snippet upload host to Kubio cloud, so the reviewed snippet flow is not arbitrary-host SSRF.
- `plugins/kubio/lib/src/PluginsManager.php:48-54` only installs plugins obtained through the WordPress.org plugin-information API, and `plugins/kubio/lib/src/PluginsManager.php:79-99` only activates installed plugin basenames; the reviewed path does not support arbitrary plugin ZIP upload or arbitrary PHP path activation.
- `plugins/kubio/lib/src/DemoSites/DemoSitesHelpers.php:16-19` and `plugins/kubio/lib/api/colibri.php:54-56` show that the two reviewed entry points are protected by nonce or capability checks and are not internet-public attack surfaces.

# Overall Assessment

Both reviewed findings should stay `UNCERTAIN` rather than being upgraded or downgraded from the Phase 3a gate. The strongest next steps are a multisite role/capability lab for the demo-site AJAX flow and an outbound ZIP capture for the snippet export flow, because those two tests resolve the main missing-evidence gaps without relying on inference.
