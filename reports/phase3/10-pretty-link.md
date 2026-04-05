# Phase 3 Gate Report - `pretty-link`

_Generated: 2026-04-05T13:55:58.168606+00:00_

## Plugin Overview
- Plugin slug: `pretty-link`
- Phase 1: EPs `69`, anomalies `43`, sources `689`, sinks `779`
- Phase 2: total `64`, TP `0`, FP `63`, REVIEW `1`
- Phase 3: confirmed `0`, plausible `0`, uncertain `1`, likely_hallucination `0`

## Tool Signals
- Semgrep: `ok (402 results)`
- Psalm: `error (exit=1)`

## Confirmed Findings
None.

## Needs Dynamic Verification
### agent-d-unresolved-001
- Type: `unresolved_dynamic_hook`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `0.67`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `unresolved:app/lib/PrliAddonUpdates.php:17`, resolved `None`
- Trace: source `app/lib/PrliAddonUpdates.php:17` -> sink `app/lib/PrliAddonUpdates.php:214`
- Description (2 sentences): Finding `agent-d-unresolved-001` flags `unresolved_dynamic_hook` at `app/lib/PrliAddonUpdates.php:214` via entry point `unresolved:app/lib/PrliAddonUpdates.php:17`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.67`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- Validation issues: `insufficient_evidence_to_confirm, path_reachability_weak, reasoning_quality_low`
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `unresolved:app/lib/PrliAddonUpdates.php:17` and send crafted input from source `app/lib/PrliAddonUpdates.php:17` toward sink `app/lib/PrliAddonUpdates.php:214`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

## Likely Hallucinations
None.

## Rejected Findings (Accepted FP)
### agent-a2-f001
- Type: `sensitive_information_disclosure`
- Minimum Role/Capability: `editor`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_search_for_links`, resolved `ep_ajax_priv_wp_ajax_prli_search_for_links`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f001` flags `sensitive_information_disclosure` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_search_for_links`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `editor` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_search_for_links` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f002
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_stripe_connect_refresh`, resolved `ep_ajax_priv_wp_ajax_prli_stripe_connect_refresh`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f002` flags `broken_access_control` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_stripe_connect_refresh`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_stripe_connect_refresh` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f003
- Type: `broken_access_control`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_search_stripe_prices`, resolved `ep_ajax_priv_wp_ajax_prli_search_stripe_prices`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f003` flags `broken_access_control` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_search_stripe_prices`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_search_stripe_prices` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f004
- Type: `cross_site_request_forgery`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_dismiss_customer_portal_notice`, resolved `ep_ajax_priv_wp_ajax_prli_dismiss_customer_portal_notice`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f004` flags `cross_site_request_forgery` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_dismiss_customer_portal_notice`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_dismiss_customer_portal_notice` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f005
- Type: `cross_site_request_forgery`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_pl_dismiss_review_prompt`, resolved `ep_ajax_priv_wp_ajax_pl_dismiss_review_prompt`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f005` flags `cross_site_request_forgery` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_pl_dismiss_review_prompt`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_pl_dismiss_review_prompt` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f006
- Type: `cross_site_request_forgery`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_pl_dismiss_upgrade_header`, resolved `ep_ajax_priv_wp_ajax_pl_dismiss_upgrade_header`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f006` flags `cross_site_request_forgery` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_pl_dismiss_upgrade_header`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_pl_dismiss_upgrade_header` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f007
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_create_pretty_link`, resolved `ep_ajax_priv_wp_ajax_prli_create_pretty_link`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f007` flags `broken_access_control` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_create_pretty_link`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_create_pretty_link` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f008
- Type: `cross_site_request_forgery`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_quick_create`, resolved `ep_ajax_priv_wp_ajax_prli_quick_create`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f008` flags `cross_site_request_forgery` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_quick_create`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_quick_create` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f009
- Type: `arbitrary_plugin_install`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_addon_install`, resolved `ep_ajax_priv_wp_ajax_prli_addon_install`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f009` flags `arbitrary_plugin_install` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_addon_install`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_addon_install` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f010
- Type: `cross_site_request_forgery`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_dismiss_notice`, resolved `ep_ajax_priv_wp_ajax_prli_dismiss_notice`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f010` flags `cross_site_request_forgery` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_dismiss_notice`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_dismiss_notice` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f011
- Type: `broken_access_control`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_onboarding_finish`, resolved `ep_ajax_priv_wp_ajax_prli_onboarding_finish`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f011` flags `broken_access_control` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_onboarding_finish`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_onboarding_finish` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f012
- Type: `arbitrary_plugin_install`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_install_license_edition`, resolved `ep_ajax_priv_wp_ajax_prli_install_license_edition`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f012` flags `arbitrary_plugin_install` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_install_license_edition`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_install_license_edition` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f013
- Type: `broken_access_control`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_plp_edge_updates`, resolved `ep_ajax_priv_wp_ajax_plp_edge_updates`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f013` flags `broken_access_control` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_plp_edge_updates`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_plp_edge_updates` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f014
- Type: `arbitrary_plugin_install`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_mosh_addon_install`, resolved `ep_ajax_priv_wp_ajax_mosh_addon_install`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f014` flags `arbitrary_plugin_install` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_mosh_addon_install`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_mosh_addon_install` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a5-fp-001
- Type: `ssrf`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_init_init`, resolved `ep_init_init`
- Trace: source `app/controllers/PrliAuthenticatorController.php:92` -> sink `app/controllers/PrliAuthenticatorController.php:96`
- Description (2 sentences): Finding `agent-a5-fp-001` flags `ssrf` at `app/controllers/PrliAuthenticatorController.php:96` via entry point `ep_init_init`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_init_init` and send crafted input from source `app/controllers/PrliAuthenticatorController.php:92` toward sink `app/controllers/PrliAuthenticatorController.php:96`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a5-fp-004
- Type: `ssrf`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_init_init`, resolved `ep_init_init`
- Trace: source `app/controllers/PrliAuthenticatorController.php:160` -> sink `app/controllers/PrliAuthenticatorController.php:189`
- Description (2 sentences): Finding `agent-a5-fp-004` flags `ssrf` at `app/controllers/PrliAuthenticatorController.php:189` via entry point `ep_init_init`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_init_init` and send crafted input from source `app/controllers/PrliAuthenticatorController.php:160` toward sink `app/controllers/PrliAuthenticatorController.php:189`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a5-fp-002
- Type: `arbitrary_option_update`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_init_init`, resolved `ep_init_init`
- Trace: source `app/controllers/PrliAuthenticatorController.php:92` -> sink `app/controllers/PrliAuthenticatorController.php:109`
- Description (2 sentences): Finding `agent-a5-fp-002` flags `arbitrary_option_update` at `app/controllers/PrliAuthenticatorController.php:109` via entry point `ep_init_init`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_init_init` and send crafted input from source `app/controllers/PrliAuthenticatorController.php:92` toward sink `app/controllers/PrliAuthenticatorController.php:109`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a5-fp-003
- Type: `open_redirect`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_init_init`, resolved `ep_init_init`
- Trace: source `app/controllers/PrliAuthenticatorController.php:124` -> sink `app/controllers/PrliAuthenticatorController.php:125`
- Description (2 sentences): Finding `agent-a5-fp-003` flags `open_redirect` at `app/controllers/PrliAuthenticatorController.php:125` via entry point `ep_init_init`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_init_init` and send crafted input from source `app/controllers/PrliAuthenticatorController.php:124` toward sink `app/controllers/PrliAuthenticatorController.php:125`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a5-fp-005
- Type: `open_redirect`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_init_init`, resolved `ep_init_init`
- Trace: source `app/controllers/PrliAuthenticatorController.php:160` -> sink `app/controllers/PrliAuthenticatorController.php:204`
- Description (2 sentences): Finding `agent-a5-fp-005` flags `open_redirect` at `app/controllers/PrliAuthenticatorController.php:204` via entry point `ep_init_init`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_init_init` and send crafted input from source `app/controllers/PrliAuthenticatorController.php:160` toward sink `app/controllers/PrliAuthenticatorController.php:204`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a5-fp-006
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_init_init`, resolved `ep_init_init`
- Trace: source `app/controllers/PrliClicksController.php:25` -> sink `app/controllers/PrliClicksController.php:30`
- Description (2 sentences): Finding `agent-a5-fp-006` flags `broken_access_control` at `app/controllers/PrliClicksController.php:30` via entry point `ep_init_init`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_init_init` and send crafted input from source `app/controllers/PrliClicksController.php:25` toward sink `app/controllers/PrliClicksController.php:30`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_1
- Type: `missing_nonce`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_admin_init_admin_init`, resolved `ep_admin_init_admin_init`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_1` flags `missing_nonce` at `N/A:N/A` via entry point `ep_admin_init_admin_init`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_admin_init_admin_init` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_2
- Type: `missing_nonce`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_stripe_connect_refresh`, resolved `ep_ajax_priv_wp_ajax_prli_stripe_connect_refresh`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_2` flags `missing_nonce` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_stripe_connect_refresh`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_stripe_connect_refresh` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_3
- Type: `missing_nonce`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_stripe_connect_disconnect`, resolved `ep_ajax_priv_wp_ajax_prli_stripe_connect_disconnect`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_3` flags `missing_nonce` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_stripe_connect_disconnect`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_stripe_connect_disconnect` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_4
- Type: `missing_nonce`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_dismiss_customer_portal_notice`, resolved `ep_ajax_priv_wp_ajax_prli_dismiss_customer_portal_notice`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_4` flags `missing_nonce` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_dismiss_customer_portal_notice`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_dismiss_customer_portal_notice` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_5
- Type: `missing_nonce`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_pl_dismiss_review_prompt`, resolved `ep_ajax_priv_wp_ajax_pl_dismiss_review_prompt`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_5` flags `missing_nonce` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_pl_dismiss_review_prompt`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_pl_dismiss_review_prompt` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_7
- Type: `missing_nonce`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_search_for_links`, resolved `ep_ajax_priv_wp_ajax_prli_search_for_links`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_7` flags `missing_nonce` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_search_for_links`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_search_for_links` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_10
- Type: `missing_nonce`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_pl_dismiss_upgrade_header`, resolved `ep_ajax_priv_wp_ajax_pl_dismiss_upgrade_header`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_10` flags `missing_nonce` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_pl_dismiss_upgrade_header`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_pl_dismiss_upgrade_header` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_11
- Type: `missing_nonce`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_dismiss_notice`, resolved `ep_ajax_priv_wp_ajax_prli_dismiss_notice`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_11` flags `missing_nonce` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_dismiss_notice`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_dismiss_notice` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_12
- Type: `missing_nonce`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_onboarding_finish`, resolved `ep_ajax_priv_wp_ajax_prli_onboarding_finish`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_12` flags `missing_nonce` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_onboarding_finish`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_onboarding_finish` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_15
- Type: `missing_capability`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_stripe_connect_refresh`, resolved `ep_ajax_priv_wp_ajax_prli_stripe_connect_refresh`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_15` flags `missing_capability` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_stripe_connect_refresh`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_stripe_connect_refresh` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_16
- Type: `missing_capability`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_stripe_connect_disconnect`, resolved `ep_ajax_priv_wp_ajax_prli_stripe_connect_disconnect`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_16` flags `missing_capability` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_stripe_connect_disconnect`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_stripe_connect_disconnect` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_17
- Type: `missing_capability`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_dismiss_customer_portal_notice`, resolved `ep_ajax_priv_wp_ajax_prli_dismiss_customer_portal_notice`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_17` flags `missing_capability` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_dismiss_customer_portal_notice`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_dismiss_customer_portal_notice` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_18
- Type: `missing_capability`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_pl_dismiss_review_prompt`, resolved `ep_ajax_priv_wp_ajax_pl_dismiss_review_prompt`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_18` flags `missing_capability` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_pl_dismiss_review_prompt`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_pl_dismiss_review_prompt` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_19
- Type: `missing_capability`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_pl_dismiss_upgrade_header`, resolved `ep_ajax_priv_wp_ajax_pl_dismiss_upgrade_header`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_19` flags `missing_capability` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_pl_dismiss_upgrade_header`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_pl_dismiss_upgrade_header` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_20
- Type: `missing_capability`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_dismiss_notice`, resolved `ep_ajax_priv_wp_ajax_prli_dismiss_notice`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_20` flags `missing_capability` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_dismiss_notice`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_dismiss_notice` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_21
- Type: `missing_capability`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_onboarding_finish`, resolved `ep_ajax_priv_wp_ajax_prli_onboarding_finish`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_21` flags `missing_capability` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_onboarding_finish`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_onboarding_finish` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_22
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_search_stripe_prices`, resolved `ep_ajax_priv_wp_ajax_prli_search_stripe_prices`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_22` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_search_stripe_prices`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_search_stripe_prices` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_23
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_stripe_add_product`, resolved `ep_ajax_priv_wp_ajax_prli_stripe_add_product`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_23` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_stripe_add_product`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_stripe_add_product` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_24
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_dismiss_customer_portal_notice`, resolved `ep_ajax_priv_wp_ajax_prli_dismiss_customer_portal_notice`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_24` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_dismiss_customer_portal_notice`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_dismiss_customer_portal_notice` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_25
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_tinymce_validate_slug`, resolved `ep_ajax_priv_wp_ajax_prli_tinymce_validate_slug`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_25` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_tinymce_validate_slug`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_tinymce_validate_slug` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_26
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_tinymce_create_link`, resolved `None`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_26` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_tinymce_create_link`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_tinymce_create_link` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_27
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_bulk_edit_links`, resolved `None`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_27` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_bulk_edit_links`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_bulk_edit_links` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_28
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_quick_create`, resolved `ep_ajax_priv_wp_ajax_prli_quick_create`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_28` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_quick_create`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_quick_create` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_29
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_addon_activate`, resolved `ep_ajax_priv_wp_ajax_prli_addon_activate`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_29` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_addon_activate`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_addon_activate` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_30
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_addon_deactivate`, resolved `ep_ajax_priv_wp_ajax_prli_addon_deactivate`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_30` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_addon_deactivate`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_addon_deactivate` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_31
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_addon_install`, resolved `ep_ajax_priv_wp_ajax_prli_addon_install`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_31` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_addon_install`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_addon_install` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_32
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_dismiss_notice`, resolved `ep_ajax_priv_wp_ajax_prli_dismiss_notice`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_32` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_dismiss_notice`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_dismiss_notice` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_33
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_dismiss_daily_notice`, resolved `ep_ajax_priv_wp_ajax_prli_dismiss_daily_notice`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_33` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_dismiss_daily_notice`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_dismiss_daily_notice` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_34
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_dismiss_monthly_notice`, resolved `ep_ajax_priv_wp_ajax_prli_dismiss_monthly_notice`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_34` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_dismiss_monthly_notice`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_dismiss_monthly_notice` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_35
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_activate_license`, resolved `ep_ajax_priv_wp_ajax_prli_activate_license`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_35` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_activate_license`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_activate_license` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_36
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_deactivate_license`, resolved `ep_ajax_priv_wp_ajax_prli_deactivate_license`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_36` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_deactivate_license`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_deactivate_license` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_37
- Type: `flawed_nonce_pattern`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_install_license_edition`, resolved `ep_ajax_priv_wp_ajax_prli_install_license_edition`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_37` flags `flawed_nonce_pattern` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_install_license_edition`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_install_license_edition` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_38
- Type: `unsafe_redirect`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_stripe_connect_update_creds`, resolved `ep_ajax_priv_wp_ajax_prli_stripe_connect_update_creds`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_38` flags `unsafe_redirect` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_stripe_connect_update_creds`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_stripe_connect_update_creds` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_39
- Type: `unsafe_redirect`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_stripe_connect_refresh`, resolved `ep_ajax_priv_wp_ajax_prli_stripe_connect_refresh`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_39` flags `unsafe_redirect` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_stripe_connect_refresh`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_stripe_connect_refresh` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_40
- Type: `unsafe_redirect`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_ajax_priv_wp_ajax_prli_stripe_connect_disconnect`, resolved `ep_ajax_priv_wp_ajax_prli_stripe_connect_disconnect`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_40` flags `unsafe_redirect` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_prli_stripe_connect_disconnect`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_prli_stripe_connect_disconnect` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### anom_41
- Type: `unsafe_redirect`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `ep_init_init`, resolved `ep_init_init`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `anom_41` flags `unsafe_redirect` at `N/A:N/A` via entry point `ep_init_init`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_init_init` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-d-fp-002
- Type: `resolved_dynamic_hook_admin_display`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `resolved_dynamic:ba175a7ef01df93a1b1c51a9ed9a28a69d63b592`, resolved `resolved_dynamic:ba175a7ef01df93a1b1c51a9ed9a28a69d63b592`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-d-fp-002` flags `resolved_dynamic_hook_admin_display` at `N/A:N/A` via entry point `resolved_dynamic:ba175a7ef01df93a1b1c51a9ed9a28a69d63b592`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `resolved_dynamic:ba175a7ef01df93a1b1c51a9ed9a28a69d63b592` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-d-fp-003
- Type: `resolved_dynamic_hook_admin_display`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `resolved_dynamic:7a6c3356d249c53a5800d04c9105eb4df950dcc7`, resolved `resolved_dynamic:7a6c3356d249c53a5800d04c9105eb4df950dcc7`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-d-fp-003` flags `resolved_dynamic_hook_admin_display` at `N/A:N/A` via entry point `resolved_dynamic:7a6c3356d249c53a5800d04c9105eb4df950dcc7`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `resolved_dynamic:7a6c3356d249c53a5800d04c9105eb4df950dcc7` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-d-fp-004
- Type: `resolved_dynamic_hook_admin_display`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `resolved_dynamic:c3ea7794c1b9cc4378f2e9b4b9438a9988e98467`, resolved `resolved_dynamic:c3ea7794c1b9cc4378f2e9b4b9438a9988e98467`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-d-fp-004` flags `resolved_dynamic_hook_admin_display` at `N/A:N/A` via entry point `resolved_dynamic:c3ea7794c1b9cc4378f2e9b4b9438a9988e98467`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `resolved_dynamic:c3ea7794c1b9cc4378f2e9b4b9438a9988e98467` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-d-fp-005
- Type: `resolved_dynamic_hook_admin_display`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `resolved_dynamic:46b5df1b5a5a01dfd0b09f02576b28a53c2f0959`, resolved `resolved_dynamic:46b5df1b5a5a01dfd0b09f02576b28a53c2f0959`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-d-fp-005` flags `resolved_dynamic_hook_admin_display` at `N/A:N/A` via entry point `resolved_dynamic:46b5df1b5a5a01dfd0b09f02576b28a53c2f0959`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `resolved_dynamic:46b5df1b5a5a01dfd0b09f02576b28a53c2f0959` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-d-fp-006
- Type: `resolved_dynamic_hook_admin_display`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `resolved_dynamic:e191a1c9a87053c796ec39fba5b2a217d2c18671`, resolved `resolved_dynamic:e191a1c9a87053c796ec39fba5b2a217d2c18671`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-d-fp-006` flags `resolved_dynamic_hook_admin_display` at `N/A:N/A` via entry point `resolved_dynamic:e191a1c9a87053c796ec39fba5b2a217d2c18671`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `resolved_dynamic:e191a1c9a87053c796ec39fba5b2a217d2c18671` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-d-fp-007
- Type: `resolved_dynamic_hook_cron`
- Minimum Role/Capability: `system`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `resolved_dynamic:ff47a18053962bd4a6dad0483d9a7c818ea3506e`, resolved `resolved_dynamic:ff47a18053962bd4a6dad0483d9a7c818ea3506e`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-d-fp-007` flags `resolved_dynamic_hook_cron` at `N/A:N/A` via entry point `resolved_dynamic:ff47a18053962bd4a6dad0483d9a7c818ea3506e`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `system` required by this path.
  - Step 3 (Attack): Use entry point `resolved_dynamic:ff47a18053962bd4a6dad0483d9a7c818ea3506e` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-d-fp-008
- Type: `resolved_dynamic_hook_ajax`
- Minimum Role/Capability: `admin`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `ACCEPTED_FP`
- Entry point: claimed `resolved_dynamic:b236fdd07ca2f86085170ae978dc2f6d376a2d5d`, resolved `resolved_dynamic:b236fdd07ca2f86085170ae978dc2f6d376a2d5d`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-d-fp-008` flags `resolved_dynamic_hook_ajax` at `N/A:N/A` via entry point `resolved_dynamic:b236fdd07ca2f86085170ae978dc2f6d376a2d5d`. Gate validation currently treats it as non-actionable (`ACCEPTED_FP`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `pretty-link`, then create/login with minimum role `admin` required by this path.
  - Step 3 (Attack): Use entry point `resolved_dynamic:b236fdd07ca2f86085170ae978dc2f6d376a2d5d` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

## Why Not Confirmed
- `agent-d-unresolved-001`: insufficient_evidence_to_confirm, path_reachability_weak, reasoning_quality_low

## Stored/Second-order Notes
No stored/second-order findings in this plugin.

## Overall Assessment
Deterministic gate output is authoritative for status classification. If LLM skeptic review exists, use it as supplemental counter-evidence only.
