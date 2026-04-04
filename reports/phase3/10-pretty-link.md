# Phase 3 Gate Report - `pretty-link`

_Generated: 2026-04-04T17:25:56.823129+00:00_

## Plugin Overview
- Plugin slug: `pretty-link`
- Phase 1: EPs `69`, anomalies `43`, sources `689`, sinks `779`
- Phase 2: total `20`, TP `0`, FP `20`, REVIEW `0`
- Phase 3: confirmed `0`, plausible `0`, uncertain `0`, likely_hallucination `0`

## Tool Signals
- Semgrep: `ok (402 results)`
- Psalm: `error (exit=1)`

## Confirmed Findings
None.

## Needs Dynamic Verification
None.

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

## Why Not Confirmed
No unresolved findings.

## Stored/Second-order Notes
No stored/second-order findings in this plugin.

## Overall Assessment
Deterministic gate output is authoritative for status classification. If LLM skeptic review exists, use it as supplemental counter-evidence only.
