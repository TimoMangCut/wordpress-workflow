# Phase 3 Gate Report - `cartflows`

_Generated: 2026-04-06T18:08:31.148577+00:00_

## Plugin Overview
- Plugin slug: `cartflows`
- Phase 1: EPs `119`, anomalies `41`, sources `844`, sinks `3397`
- Phase 2: total `77`, TP `3`, FP `71`, REVIEW `3`
- Phase 3: confirmed `1`, uncertain `5`, risk_note `0`, rejected `71`

## Tool Signals
- Semgrep: `ok (324 results)`
- Psalm: `error (exit=1)`

## Confirmed Findings
### cartflows-a1-002
- Type: `user_enumeration`
- Minimum Role/Capability: `none`
- Severity: `low` | Confidence: `0.84`
- Gate Verdict: `CONFIRMED`
- Entry point: claimed `ep_ajax_nopriv_wp_ajax_nopriv_wcf_check_email_exists`, resolved `ep_ajax_nopriv_wp_ajax_nopriv_wcf_check_email_exists`
- Trace: source `modules/checkout/classes/class-cartflows-checkout-ajax.php:209` -> sink `modules/checkout/classes/class-cartflows-checkout-ajax.php:219`
- Description (2 sentences): Finding `cartflows-a1-002` flags `user_enumeration` at `modules/checkout/classes/class-cartflows-checkout-ajax.php:219` via entry point `ep_ajax_nopriv_wp_ajax_nopriv_wcf_check_email_exists`. Gate validation currently marks it as confirmed with confidence `0.84` based on available static evidence.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `none`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): 1. Load a public CartFlows checkout page and extract `cartflows.check_email_exist_nonce`. 2. POST to `/wp-admin/admin-ajax.php` with `action=wcf_check_email_exists`, `security=<nonce>`, and `email_address=<target>`. 3. Compare the JSON response: existing addresses return `data.success=true` and `msg="Email Exist."`; non-existing addresses return `data.success=false` and `msg="Email not exist"`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

## Needs Dynamic Verification
### cartflows-a1-001
- Type: `arbitrary_file_upload`
- Minimum Role/Capability: `none`
- Severity: `medium` | Confidence: `0.72`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_ajax_nopriv_wp_ajax_nopriv_wcf_upload_checkout_file`, resolved `ep_ajax_nopriv_wp_ajax_nopriv_wcf_upload_checkout_file`
- Trace: source `modules/checkout/classes/class-cartflows-checkout-ajax.php:311` -> sink `modules/checkout/classes/class-cartflows-checkout-ajax.php:425`
- Description (2 sentences): Finding `cartflows-a1-001` flags `arbitrary_file_upload` at `modules/checkout/classes/class-cartflows-checkout-ajax.php:425` via entry point `ep_ajax_nopriv_wp_ajax_nopriv_wcf_upload_checkout_file`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.72`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized file/media creation or overwrite in WordPress uploads workflow. Minimum attacker context: `none`.
- Validation issues: `guard_contradiction`
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): 1. Request any public CartFlows checkout page and extract `cartflows.wcf_file_upload_nonce` from the localized checkout script. 2. Send a multipart POST to `/wp-admin/admin-ajax.php` with `action=wcf_upload_checkout_file`, `security=<nonce>`, and a file part named `wcf_checkout_file`; omit `field_key` and `checkout_id` or send invalid values. 3. Use an allowed extension such as `.pdf` or `.jpg`. 4. The server stores the file in the uploads directory and returns its URL in `data.url`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a2-f22-upload-checkout-file
- Type: `arbitrary_file_upload`
- Minimum Role/Capability: `none`
- Severity: `medium` | Confidence: `0.68`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file`, resolved `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file`
- Trace: source `modules/checkout/classes/class-cartflows-checkout-ajax.php:311` -> sink `modules/checkout/classes/class-cartflows-checkout-ajax.php:425`
- Description (2 sentences): Finding `agent-a2-f22-upload-checkout-file` flags `arbitrary_file_upload` at `modules/checkout/classes/class-cartflows-checkout-ajax.php:425` via entry point `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.68`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized file/media creation or overwrite in WordPress uploads workflow. Minimum attacker context: `none`.
- Validation issues: `guard_contradiction`
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): 1. Visit any public CartFlows checkout page and extract cartflows.wcf_file_upload_nonce from the localized checkout script. 2. Send a multipart POST to /wp-admin/admin-ajax.php with action=wcf_upload_checkout_file, security=<nonce>, and wcf_checkout_file=@test.pdf. 3. Omit field_key and checkout_id. 4. The endpoint stores the file under wp-content/uploads/.../wcf_<uuid>.pdf and returns the public URL in the JSON response.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a4-review-checkout-block-layout-include
- Type: `local_file_inclusion`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `0.67`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_block_wcfb_checkout_form`, resolved `ep_block_wcfb_checkout_form`
- Trace: source `modules/gutenberg/dist/blocks/checkout-form/class-wcfb-checkout-form.php:856` -> sink `modules/checkout/classes/class-cartflows-checkout-markup.php:533`
- Description (2 sentences): Finding `agent-a4-review-checkout-block-layout-include` flags `local_file_inclusion` at `modules/checkout/classes/class-cartflows-checkout-markup.php:533` via entry point `ep_block_wcfb_checkout_form`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.67`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- Validation issues: `guard_contradiction`
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Create or preview a checkout step containing a `wcfb/checkout-form` block with `layout` set to a known readable local file path, then request the rendered block output and inspect whether the file contents are returned.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### cf-c-anom_5
- Type: `missing_capability`
- Minimum Role/Capability: `none`
- Severity: `critical` | Confidence: `0.65`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file`, resolved `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file`
- Trace: source `modules/checkout/classes/class-cartflows-checkout-ajax.php:57` -> sink `modules/checkout/classes/class-cartflows-checkout-ajax.php:308`
- Description (2 sentences): Finding `cf-c-anom_5` flags `missing_capability` at `modules/checkout/classes/class-cartflows-checkout-ajax.php:308` via entry point `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.65`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `none`.
- Validation issues: `guard_contradiction`
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): 1) Visit any CartFlows checkout page as an unauthenticated user. 2) Extract wcf_file_upload_nonce from the page JS. 3) POST to wp-admin/admin-ajax.php with action=wcf_upload_checkout_file, security={nonce}, wcf_checkout_file={file}. 4) File is processed by wp_handle_upload and saved to uploads directory.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### cf-c-anom_35
- Type: `nopriv_sensitive_op_missing_capability`
- Minimum Role/Capability: `none`
- Severity: `critical` | Confidence: `0.62`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_ajax_nopriv_wp_ajax_nopriv_wcf_upload_checkout_file`, resolved `ep_ajax_nopriv_wp_ajax_nopriv_wcf_upload_checkout_file`
- Trace: source `modules/checkout/classes/class-cartflows-checkout-ajax.php:293` -> sink `modules/checkout/classes/class-cartflows-checkout-ajax.php:325`
- Description (2 sentences): Finding `cf-c-anom_35` flags `nopriv_sensitive_op_missing_capability` at `modules/checkout/classes/class-cartflows-checkout-ajax.php:325` via entry point `ep_ajax_nopriv_wp_ajax_nopriv_wcf_upload_checkout_file`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.62`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `none`.
- Validation issues: `code_evidence_missing_or_mismatch, guard_contradiction`
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): 1. Visit any CartFlows checkout page as unauthenticated user. 2. Extract wcf_file_upload_nonce from wcfCheckoutFields JS object in page source. 3. POST to /wp-admin/admin-ajax.php: action=wcf_upload_checkout_file, security=<nonce>, wcf_upload_file=<file attachment>. 4. Response returns uploaded file URL.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

## Risk Notes
None.

## Rejected Findings
### agent-a2-f01-rollback
- Type: `authorization`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_admin_post_admin_post_cartflows_rollback`, resolved `ep_admin_post_admin_post_cartflows_rollback`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f01-rollback` flags `authorization` at `N/A:N/A` via entry point `ep_admin_post_admin_post_cartflows_rollback`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_admin_post_admin_post_cartflows_rollback` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f02-ignore-gb-notice
- Type: `authorization`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_ignore_gutenberg_notice`, resolved `ep_ajax_priv_wp_ajax_cartflows_ignore_gutenberg_notice`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f02-ignore-gb-notice` flags `authorization` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_ignore_gutenberg_notice`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_ignore_gutenberg_notice` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f03-disable-weekly-report-notice
- Type: `authorization`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_disable_weekly_report_email_notice`, resolved `ep_ajax_priv_wp_ajax_cartflows_disable_weekly_report_email_notice`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f03-disable-weekly-report-notice` flags `authorization` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_disable_weekly_report_email_notice`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_disable_weekly_report_email_notice` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f04-snooze-script-migration
- Type: `csrf`
- Minimum Role/Capability: `admin`
- Severity: `low` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_snooze_script_migration`, resolved `ep_ajax_priv_wp_ajax_cartflows_snooze_script_migration`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f04-snooze-script-migration` flags `csrf` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_snooze_script_migration`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_snooze_script_migration` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f05-dismiss-script-migration-complete
- Type: `csrf`
- Minimum Role/Capability: `admin`
- Severity: `low` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_dismiss_script_migration_complete_notice`, resolved `ep_ajax_priv_wp_ajax_cartflows_dismiss_script_migration_complete_notice`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f05-dismiss-script-migration-complete` flags `csrf` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_dismiss_script_migration_complete_notice`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_dismiss_script_migration_complete_notice` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f06-save-tutor-course-template
- Type: `authorization`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_save_tutor_course_template`, resolved `ep_ajax_priv_wp_ajax_cartflows_save_tutor_course_template`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f06-save-tutor-course-template` flags `authorization` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_save_tutor_course_template`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_save_tutor_course_template` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f07-get-suretriggers-data
- Type: `authorization`
- Minimum Role/Capability: `unknown`
- Severity: `low` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_get_suretriggers_data`, resolved `ep_ajax_priv_wp_ajax_cartflows_get_suretriggers_data`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f07-get-suretriggers-data` flags `authorization` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_get_suretriggers_data`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_get_suretriggers_data` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f08-fetch-whats-new-data
- Type: `ssrf`
- Minimum Role/Capability: `unknown`
- Severity: `low` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_fetch_whats_new_data`, resolved `ep_ajax_priv_wp_ajax_cartflows_fetch_whats_new_data`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f08-fetch-whats-new-data` flags `ssrf` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_fetch_whats_new_data`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_fetch_whats_new_data` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f09-install-plugin
- Type: `authorization`
- Minimum Role/Capability: `admin`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_install_plugin`, resolved `ep_ajax_priv_wp_ajax_cartflows_install_plugin`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f09-install-plugin` flags `authorization` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_install_plugin`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- Validation issues: `fp_evidence_file_not_found: wp-admin/includes/ajax-actions.php`
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_install_plugin` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f10-pointer-should-show
- Type: `authorization`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_pointer_should_show`, resolved `ep_ajax_priv_wp_ajax_cartflows_pointer_should_show`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f10-pointer-should-show` flags `authorization` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_pointer_should_show`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_pointer_should_show` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f11-pointer-dismiss
- Type: `authorization`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_pointer_dismiss`, resolved `ep_ajax_priv_wp_ajax_cartflows_pointer_dismiss`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f11-pointer-dismiss` flags `authorization` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_pointer_dismiss`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_pointer_dismiss` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f12-pointer-accept
- Type: `authorization`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_pointer_accept`, resolved `ep_ajax_priv_wp_ajax_cartflows_pointer_accept`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f12-pointer-accept` flags `authorization` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_pointer_accept`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_pointer_accept` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f13-plugin-deactivate-feedback
- Type: `ssrf`
- Minimum Role/Capability: `admin`
- Severity: `low` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_uds_plugin_deactivate_feedback`, resolved `ep_ajax_priv_wp_ajax_uds_plugin_deactivate_feedback`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f13-plugin-deactivate-feedback` flags `ssrf` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_uds_plugin_deactivate_feedback`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_uds_plugin_deactivate_feedback` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f14-astra-notice-dismiss
- Type: `authorization`
- Minimum Role/Capability: `unknown`
- Severity: `low` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_astra_notice_dismiss`, resolved `ep_ajax_priv_wp_ajax_astra_notice_dismiss`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f14-astra-notice-dismiss` flags `authorization` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_astra_notice_dismiss`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_astra_notice_dismiss` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f15-json-search-flows
- Type: `sql_injection`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wcf_json_search_flows`, resolved `ep_ajax_priv_wp_ajax_wcf_json_search_flows`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f15-json-search-flows` flags `sql_injection` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_wcf_json_search_flows`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_wcf_json_search_flows` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f16-order-detail-preview
- Type: `cross_site_scripting`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wpcf_order_detail_form_shortcode`, resolved `ep_ajax_priv_wp_ajax_wpcf_order_detail_form_shortcode`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f16-order-detail-preview` flags `cross_site_scripting` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_wpcf_order_detail_form_shortcode`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_wpcf_order_detail_form_shortcode` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f17-order-checkout-preview
- Type: `cross_site_scripting`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wpcf_order_checkout_form_shortcode`, resolved `ep_ajax_priv_wp_ajax_wpcf_order_checkout_form_shortcode`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f17-order-checkout-preview` flags `cross_site_scripting` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_wpcf_order_checkout_form_shortcode`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_wpcf_order_checkout_form_shortcode` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f18-optin-preview
- Type: `cross_site_scripting`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wpcf_optin_form_shortcode`, resolved `ep_ajax_priv_wp_ajax_wpcf_optin_form_shortcode`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f18-optin-preview` flags `cross_site_scripting` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_wpcf_optin_form_shortcode`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_wpcf_optin_form_shortcode` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f19-apply-coupon
- Type: `authorization`
- Minimum Role/Capability: `none`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wcf_woo_apply_coupon`, resolved `ep_ajax_priv_wp_ajax_wcf_woo_apply_coupon`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f19-apply-coupon` flags `authorization` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_wcf_woo_apply_coupon`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_wcf_woo_apply_coupon` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f20-remove-coupon
- Type: `authorization`
- Minimum Role/Capability: `none`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wcf_woo_remove_coupon`, resolved `ep_ajax_priv_wp_ajax_wcf_woo_remove_coupon`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f20-remove-coupon` flags `authorization` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_wcf_woo_remove_coupon`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_wcf_woo_remove_coupon` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f21-remove-cart-product
- Type: `authorization`
- Minimum Role/Capability: `none`
- Severity: `low` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wcf_woo_remove_cart_product`, resolved `ep_ajax_priv_wp_ajax_wcf_woo_remove_cart_product`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f21-remove-cart-product` flags `authorization` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_wcf_woo_remove_cart_product`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_wcf_woo_remove_cart_product` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-homepage-get-home-page-settings
- Type: `arbitrary_option_read`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest___0`, resolved `ep_rest___0`
- Trace: source `admin-core/api/home-page.php:103` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-homepage-get-home-page-settings` flags `arbitrary_option_read` at `N/A:N/A` via entry point `ep_rest___0`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___0` and send crafted input from source `admin-core/api/home-page.php:103` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-homepage-get-setup-details
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest___0`, resolved `ep_rest___0`
- Trace: source `admin-core/api/home-page.php:127` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-homepage-get-setup-details` flags `broken_access_control` at `N/A:N/A` via entry point `ep_rest___0`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___0` and send crafted input from source `admin-core/api/home-page.php:127` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-step-data-get-item
- Type: `sensitive_information_disclosure`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest___0`, resolved `ep_rest___0`
- Trace: source `admin-core/api/step-data.php:89` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-step-data-get-item` flags `sensitive_information_disclosure` at `N/A:N/A` via entry point `ep_rest___0`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___0` and send crafted input from source `admin-core/api/step-data.php:89` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-webhooks-delete-webhook
- Type: `arbitrary_option_update`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest___1`, resolved `ep_rest___1`
- Trace: source `admin-core/api/webhooks.php:244` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-webhooks-delete-webhook` flags `arbitrary_option_update` at `N/A:N/A` via entry point `ep_rest___1`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___1` and send crafted input from source `admin-core/api/webhooks.php:244` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-webhooks-update-webhook
- Type: `arbitrary_option_update`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest___0`, resolved `ep_rest___0`
- Trace: source `admin-core/api/webhooks.php:198` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-webhooks-update-webhook` flags `arbitrary_option_update` at `N/A:N/A` via entry point `ep_rest___0`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___0` and send crafted input from source `admin-core/api/webhooks.php:198` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-webhooks-test-webhook
- Type: `ssrf`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest___0`, resolved `ep_rest___0`
- Trace: source `admin-core/api/webhooks.php:274` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-webhooks-test-webhook` flags `ssrf` at `N/A:N/A` via entry point `ep_rest___0`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___0` and send crafted input from source `admin-core/api/webhooks.php:274` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-nps-submit-rating
- Type: `arbitrary_option_update`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest___rating__0`, resolved `ep_rest___rating__0`
- Trace: source `libraries/nps-survey/classes/nps-survey-script.php:268` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-nps-submit-rating` flags `arbitrary_option_update` at `N/A:N/A` via entry point `ep_rest___rating__0`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___rating__0` and send crafted input from source `libraries/nps-survey/classes/nps-survey-script.php:268` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-nps-dismiss-survey
- Type: `arbitrary_option_update`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest___dismiss_nps_survey__0`, resolved `ep_rest___dismiss_nps_survey__0`
- Trace: source `libraries/nps-survey/classes/nps-survey-script.php:374` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-nps-dismiss-survey` flags `arbitrary_option_update` at `N/A:N/A` via entry point `ep_rest___dismiss_nps_survey__0`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___dismiss_nps_survey__0` and send crafted input from source `libraries/nps-survey/classes/nps-survey-script.php:374` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a4-fp-checkout-shortcode-demo-guard
- Type: `broken_access_control`
- Minimum Role/Capability: `contributor`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_shortcode_cartflows_checkout`, resolved `ep_shortcode_cartflows_checkout`
- Trace: source `modules/checkout/classes/class-cartflows-checkout-markup.php:492` -> sink `modules/checkout/classes/class-cartflows-checkout-markup.php:533`
- Description (2 sentences): Finding `agent-a4-fp-checkout-shortcode-demo-guard` flags `broken_access_control` at `modules/checkout/classes/class-cartflows-checkout-markup.php:533` via entry point `ep_shortcode_cartflows_checkout`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `contributor` required by this path.
  - Step 3 (Attack): Use entry point `ep_shortcode_cartflows_checkout` and send crafted input from source `modules/checkout/classes/class-cartflows-checkout-markup.php:492` toward sink `modules/checkout/classes/class-cartflows-checkout-markup.php:533`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a4-fp-optin-shortcode-demo-guard
- Type: `broken_access_control`
- Minimum Role/Capability: `contributor`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_shortcode_cartflows_optin`, resolved `ep_shortcode_cartflows_optin`
- Trace: source `modules/optin/classes/class-cartflows-optin-markup.php:245` -> sink `modules/optin/classes/class-cartflows-optin-markup.php:279`
- Description (2 sentences): Finding `agent-a4-fp-optin-shortcode-demo-guard` flags `broken_access_control` at `modules/optin/classes/class-cartflows-optin-markup.php:279` via entry point `ep_shortcode_cartflows_optin`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `contributor` required by this path.
  - Step 3 (Attack): Use entry point `ep_shortcode_cartflows_optin` and send crafted input from source `modules/optin/classes/class-cartflows-optin-markup.php:245` toward sink `modules/optin/classes/class-cartflows-optin-markup.php:279`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a5-fp-tutor-course-template-redirect
- Type: `broken_access_control`
- Minimum Role/Capability: `none`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_template_redirect_template_redirect`, resolved `ep_template_redirect_template_redirect`
- Trace: source `compatibilities/plugins/tutor-lms/class-cartflows-tutor-compatibility.php:313` -> sink `compatibilities/plugins/tutor-lms/class-cartflows-tutor-compatibility.php:345`
- Description (2 sentences): Finding `agent-a5-fp-tutor-course-template-redirect` flags `broken_access_control` at `compatibilities/plugins/tutor-lms/class-cartflows-tutor-compatibility.php:345` via entry point `ep_template_redirect_template_redirect`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_template_redirect_template_redirect` and send crafted input from source `compatibilities/plugins/tutor-lms/class-cartflows-tutor-compatibility.php:313` toward sink `compatibilities/plugins/tutor-lms/class-cartflows-tutor-compatibility.php:345`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a5-fp-learndash-course-template-redirect
- Type: `broken_access_control`
- Minimum Role/Capability: `none`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_template_redirect_template_redirect`, resolved `ep_template_redirect_template_redirect`
- Trace: source `compatibilities/plugins/class-cartflows-learndash-compatibility.php:257` -> sink `compatibilities/plugins/class-cartflows-learndash-compatibility.php:278`
- Description (2 sentences): Finding `agent-a5-fp-learndash-course-template-redirect` flags `broken_access_control` at `compatibilities/plugins/class-cartflows-learndash-compatibility.php:278` via entry point `ep_template_redirect_template_redirect`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_template_redirect_template_redirect` and send crafted input from source `compatibilities/plugins/class-cartflows-learndash-compatibility.php:257` toward sink `compatibilities/plugins/class-cartflows-learndash-compatibility.php:278`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a5-fp-analytics-loader-fixed-path-include
- Type: `local_file_inclusion`
- Minimum Role/Capability: `none`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_init_init`, resolved `ep_init_init`
- Trace: source `classes/class-cartflows-loader.php:379` -> sink `libraries/bsf-analytics/class-bsf-analytics-loader.php:113`
- Description (2 sentences): Finding `agent-a5-fp-analytics-loader-fixed-path-include` flags `local_file_inclusion` at `libraries/bsf-analytics/class-bsf-analytics-loader.php:113` via entry point `ep_init_init`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_init_init` and send crafted input from source `classes/class-cartflows-loader.php:379` toward sink `libraries/bsf-analytics/class-bsf-analytics-loader.php:113`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a5-fp-step-taxonomy-bootstrap
- Type: `broken_access_control`
- Minimum Role/Capability: `subscriber`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_init_init`, resolved `ep_init_init`
- Trace: source `modules/flow/classes/class-cartflows-step-post-type.php:168` -> sink `modules/flow/classes/class-cartflows-step-post-type.php:495`
- Description (2 sentences): Finding `agent-a5-fp-step-taxonomy-bootstrap` flags `broken_access_control` at `modules/flow/classes/class-cartflows-step-post-type.php:495` via entry point `ep_init_init`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `subscriber` required by this path.
  - Step 3 (Attack): Use entry point `ep_init_init` and send crafted input from source `modules/flow/classes/class-cartflows-step-post-type.php:168` toward sink `modules/flow/classes/class-cartflows-step-post-type.php:495`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a5-fp-version-migration-option-updates
- Type: `arbitrary_option_update`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_init_init`, resolved `ep_init_init`
- Trace: source `classes/class-cartflows-update.php:52` -> sink `classes/class-cartflows-update.php:61`
- Description (2 sentences): Finding `agent-a5-fp-version-migration-option-updates` flags `arbitrary_option_update` at `classes/class-cartflows-update.php:61` via entry point `ep_init_init`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_init_init` and send crafted input from source `classes/class-cartflows-update.php:52` toward sink `classes/class-cartflows-update.php:61`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_1
- Type: `missing_nonce`
- Minimum Role/Capability: `admin`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_dismiss_script_migration_complete_notice`, resolved `ep_ajax_priv_wp_ajax_cartflows_dismiss_script_migration_complete_notice`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_1` flags `missing_nonce` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_dismiss_script_migration_complete_notice`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_dismiss_script_migration_complete_notice` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_2
- Type: `missing_nonce`
- Minimum Role/Capability: `admin`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wcf_json_search_flows`, resolved `ep_ajax_priv_wp_ajax_wcf_json_search_flows`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_2` flags `missing_nonce` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_wcf_json_search_flows`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_wcf_json_search_flows` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_3
- Type: `missing_nonce`
- Minimum Role/Capability: `subscriber`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file`, resolved `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_3` flags `missing_nonce` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `subscriber` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_4
- Type: `missing_capability`
- Minimum Role/Capability: `subscriber`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_save_tutor_course_template`, resolved `ep_ajax_priv_wp_ajax_cartflows_save_tutor_course_template`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_4` flags `missing_capability` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_save_tutor_course_template`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `subscriber` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_save_tutor_course_template` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_6
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `admin`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_snooze_script_migration`, resolved `ep_ajax_priv_wp_ajax_cartflows_snooze_script_migration`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_6` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_snooze_script_migration`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_snooze_script_migration` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_7
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `admin`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_dismiss_script_migration_complete_notice`, resolved `ep_ajax_priv_wp_ajax_cartflows_dismiss_script_migration_complete_notice`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_7` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_dismiss_script_migration_complete_notice`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_dismiss_script_migration_complete_notice` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_8
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `admin`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_get_suretriggers_data`, resolved `ep_ajax_priv_wp_ajax_cartflows_get_suretriggers_data`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_8` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_get_suretriggers_data`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_get_suretriggers_data` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_9
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `subscriber`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_pointer_should_show`, resolved `ep_ajax_priv_wp_ajax_cartflows_pointer_should_show`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_9` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_pointer_should_show`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `subscriber` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_pointer_should_show` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_10
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `subscriber`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_pointer_dismiss`, resolved `ep_ajax_priv_wp_ajax_cartflows_pointer_dismiss`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_10` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_pointer_dismiss`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `subscriber` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_pointer_dismiss` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_11
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `subscriber`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_pointer_accept`, resolved `ep_ajax_priv_wp_ajax_cartflows_pointer_accept`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_11` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_pointer_accept`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `subscriber` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_pointer_accept` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_12
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `admin`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_uds_plugin_deactivate_feedback`, resolved `ep_ajax_priv_wp_ajax_uds_plugin_deactivate_feedback`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_12` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_uds_plugin_deactivate_feedback`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_uds_plugin_deactivate_feedback` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_13
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `admin`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wcf_json_search_flows`, resolved `ep_ajax_priv_wp_ajax_wcf_json_search_flows`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_13` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_wcf_json_search_flows`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_wcf_json_search_flows` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_14
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `subscriber`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wpcf_order_detail_form_shortcode`, resolved `ep_ajax_priv_wp_ajax_wpcf_order_detail_form_shortcode`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_14` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_wpcf_order_detail_form_shortcode`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `subscriber` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_wpcf_order_detail_form_shortcode` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_16
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `subscriber`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wcf_woo_apply_coupon`, resolved `ep_ajax_priv_wp_ajax_wcf_woo_apply_coupon`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_16` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_wcf_woo_apply_coupon`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `subscriber` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_wcf_woo_apply_coupon` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_17
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `none`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_nopriv_wp_ajax_nopriv_wcf_woo_apply_coupon`, resolved `ep_ajax_nopriv_wp_ajax_nopriv_wcf_woo_apply_coupon`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_17` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_nopriv_wp_ajax_nopriv_wcf_woo_apply_coupon`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_nopriv_wp_ajax_nopriv_wcf_woo_apply_coupon` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_18
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `subscriber`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file`, resolved `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_18` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `subscriber` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_19
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `none`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_nopriv_wp_ajax_nopriv_wcf_upload_checkout_file`, resolved `ep_ajax_nopriv_wp_ajax_nopriv_wcf_upload_checkout_file`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_19` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_nopriv_wp_ajax_nopriv_wcf_upload_checkout_file`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_nopriv_wp_ajax_nopriv_wcf_upload_checkout_file` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_20
- Type: `potential_xss`
- Minimum Role/Capability: `none`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_shortcode_cartflows_product_title`, resolved `ep_shortcode_cartflows_product_title`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_20` flags `potential_xss` at `N/A:N/A` via entry point `ep_shortcode_cartflows_product_title`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_shortcode_cartflows_product_title` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_21
- Type: `potential_xss`
- Minimum Role/Capability: `none`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_shortcode_cartflows_product_add_to_cart`, resolved `ep_shortcode_cartflows_product_add_to_cart`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_21` flags `potential_xss` at `N/A:N/A` via entry point `ep_shortcode_cartflows_product_add_to_cart`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_shortcode_cartflows_product_add_to_cart` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_22
- Type: `potential_xss`
- Minimum Role/Capability: `none`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_block_wcfb_optin_form`, resolved `ep_block_wcfb_optin_form`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_22` flags `potential_xss` at `N/A:N/A` via entry point `ep_block_wcfb_optin_form`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_block_wcfb_optin_form` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_23
- Type: `potential_xss`
- Minimum Role/Capability: `none`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_block_wcfb_order_detail_form`, resolved `ep_block_wcfb_order_detail_form`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_23` flags `potential_xss` at `N/A:N/A` via entry point `ep_block_wcfb_order_detail_form`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_block_wcfb_order_detail_form` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_24
- Type: `potential_xss`
- Minimum Role/Capability: `none`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_block_wcfb_checkout_form`, resolved `ep_block_wcfb_checkout_form`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_24` flags `potential_xss` at `N/A:N/A` via entry point `ep_block_wcfb_checkout_form`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_block_wcfb_checkout_form` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_25
- Type: `potential_xss`
- Minimum Role/Capability: `none`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_shortcode_cartflows_checkout`, resolved `ep_shortcode_cartflows_checkout`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_25` flags `potential_xss` at `N/A:N/A` via entry point `ep_shortcode_cartflows_checkout`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_shortcode_cartflows_checkout` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_26
- Type: `potential_xss`
- Minimum Role/Capability: `none`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_shortcode_cartflows_optin`, resolved `ep_shortcode_cartflows_optin`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_26` flags `potential_xss` at `N/A:N/A` via entry point `ep_shortcode_cartflows_optin`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_shortcode_cartflows_optin` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_27
- Type: `is_admin_as_auth`
- Minimum Role/Capability: `none`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_template_redirect_template_redirect`, resolved `ep_template_redirect_template_redirect`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_27` flags `is_admin_as_auth` at `N/A:N/A` via entry point `ep_template_redirect_template_redirect`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_template_redirect_template_redirect` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_29
- Type: `is_admin_as_auth`
- Minimum Role/Capability: `subscriber`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_admin_init_admin_init`, resolved `ep_admin_init_admin_init`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_29` flags `is_admin_as_auth` at `N/A:N/A` via entry point `ep_admin_init_admin_init`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `subscriber` required by this path.
  - Step 3 (Attack): Use entry point `ep_admin_init_admin_init` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_30
- Type: `is_admin_as_auth`
- Minimum Role/Capability: `none`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_shortcode_cartflows_checkout`, resolved `ep_shortcode_cartflows_checkout`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_30` flags `is_admin_as_auth` at `N/A:N/A` via entry point `ep_shortcode_cartflows_checkout`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_shortcode_cartflows_checkout` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_32
- Type: `is_admin_as_auth`
- Minimum Role/Capability: `none`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_shortcode_cartflows_optin`, resolved `ep_shortcode_cartflows_optin`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_32` flags `is_admin_as_auth` at `N/A:N/A` via entry point `ep_shortcode_cartflows_optin`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_shortcode_cartflows_optin` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_34
- Type: `is_admin_as_auth`
- Minimum Role/Capability: `none`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_init_init`, resolved `ep_init_init`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_34` flags `is_admin_as_auth` at `N/A:N/A` via entry point `ep_init_init`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_init_init` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_36
- Type: `inconsistency_missing_nonce_and_capability`
- Minimum Role/Capability: `subscriber`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_snooze_script_migration`, resolved `ep_ajax_priv_wp_ajax_cartflows_snooze_script_migration`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_36` flags `inconsistency_missing_nonce_and_capability` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_snooze_script_migration`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `subscriber` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_snooze_script_migration` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_37
- Type: `inconsistency_missing_nonce_and_capability`
- Minimum Role/Capability: `subscriber`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_cartflows_install_plugin`, resolved `ep_ajax_priv_wp_ajax_cartflows_install_plugin`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_37` flags `inconsistency_missing_nonce_and_capability` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_cartflows_install_plugin`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `subscriber` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_cartflows_install_plugin` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_38
- Type: `inconsistency_missing_capability`
- Minimum Role/Capability: `subscriber`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wcf_woo_apply_coupon`, resolved `ep_ajax_priv_wp_ajax_wcf_woo_apply_coupon`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_38` flags `inconsistency_missing_capability` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_wcf_woo_apply_coupon`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `subscriber` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_wcf_woo_apply_coupon` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_39
- Type: `inconsistency_missing_capability`
- Minimum Role/Capability: `subscriber`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file`, resolved `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_39` flags `inconsistency_missing_capability` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `subscriber` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_wcf_upload_checkout_file` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_40
- Type: `inconsistency_nopriv_missing_capability`
- Minimum Role/Capability: `none`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_nopriv_wp_ajax_nopriv_wcf_woo_apply_coupon`, resolved `ep_ajax_nopriv_wp_ajax_nopriv_wcf_woo_apply_coupon`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_40` flags `inconsistency_nopriv_missing_capability` at `N/A:N/A` via entry point `ep_ajax_nopriv_wp_ajax_nopriv_wcf_woo_apply_coupon`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_nopriv_wp_ajax_nopriv_wcf_woo_apply_coupon` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### cf-c-anom_41
- Type: `inconsistency_nopriv_missing_capability`
- Minimum Role/Capability: `none`
- Severity: `critical` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_nopriv_wp_ajax_nopriv_wcf_upload_checkout_file`, resolved `ep_ajax_nopriv_wp_ajax_nopriv_wcf_upload_checkout_file`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `cf-c-anom_41` flags `inconsistency_nopriv_missing_capability` at `N/A:N/A` via entry point `ep_ajax_nopriv_wp_ajax_nopriv_wcf_upload_checkout_file`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `cartflows`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_nopriv_wp_ajax_nopriv_wcf_upload_checkout_file` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

## Why Not Confirmed
- `cartflows-a1-001`: guard_contradiction
- `agent-a2-f22-upload-checkout-file`: guard_contradiction
- `agent-a4-review-checkout-block-layout-include`: guard_contradiction
- `cf-c-anom_5`: guard_contradiction
- `cf-c-anom_35`: code_evidence_missing_or_mismatch, guard_contradiction

## Stored/Second-order Notes
No stored/second-order findings in this plugin.

## Overall Assessment
Deterministic gate output is authoritative for status classification. If LLM skeptic review exists, use it as supplemental counter-evidence only.
