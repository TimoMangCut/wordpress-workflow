# Phase 3 Gate Report - `backwpup`

_Generated: 2026-04-05T15:33:01.846368+00:00_

## Plugin Overview
- Plugin slug: `backwpup`
- Phase 1: EPs `61`, anomalies `13`, sources `604`, sinks `1088`
- Phase 2: total `44`, TP `17`, FP `22`, REVIEW `5`
- Phase 3: confirmed `0`, uncertain `21`, risk_note `0`, rejected `23`

## Tool Signals
- Semgrep: `ok (47 results)`
- Psalm: `ok (844 results)`

## Confirmed Findings
None.

## Needs Dynamic Verification
### agent-a2-f001
- Type: `sensitive_information_disclosure`
- Minimum Role/Capability: `subscriber`
- Severity: `low` | Confidence: `0.73`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_ajax_priv_wp_ajax_backwpup_debug_info`, resolved `ep_ajax_priv_wp_ajax_backwpup_debug_info`
- Trace: source `inc/class-admin.php:281` -> sink `inc/class-admin.php:287`
- Description (2 sentences): Finding `agent-a2-f001` flags `sensitive_information_disclosure` at `inc/class-admin.php:287` via entry point `ep_ajax_priv_wp_ajax_backwpup_debug_info`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.73`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `subscriber`.
- Validation issues: `guard_contradiction`
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `subscriber` required by this path.
  - Step 3 (Attack): Log in as a low-privileged user and request `/wp-admin/admin-ajax.php?action=backwpup_debug_info`. The response contains the full debug-information page, including absolute paths and server/environment details.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a2-f002
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `low` | Confidence: `0.58`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_admin_post_admin_post_backwpup`, resolved `ep_admin_post_admin_post_backwpup`
- Trace: source `inc/class-admin.php:838` -> sink `inc/class-page-onboarding.php:127`
- Description (2 sentences): Finding `agent-a2-f002` flags `broken_access_control` at `inc/class-page-onboarding.php:127` via entry point `ep_admin_post_admin_post_backwpup`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.58`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- Validation issues: `guard_contradiction, path_reachability_weak`
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Assign a user the `backwpup_check` role while `backwpup_onboarding` is still enabled. Visit the onboarding page to obtain the `backwpup_page` nonce, then submit `POST /wp-admin/admin-post.php` with `action=backwpup`, `page=backwpup`, `onboarding=1`, chosen frequency fields, and `onboarding_storage[]`. The request updates onboarding job options and marks onboarding complete even though the role lacks `backwpup_jobs_edit` and `backwpup_settings`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a2-f008
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `0.50`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_admin_post_admin_post_backwpup_support`, resolved `ep_admin_post_admin_post_backwpup_support`
- Trace: source `inc/class-admin.php:1177` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f008` flags `broken_access_control` at `N/A:N/A` via entry point `ep_admin_post_admin_post_backwpup_support`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.50`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- Validation issues: `code_evidence_missing_or_mismatch, guard_contradiction, missing_sink_file_path, missing_sink_line_number`
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_admin_post_admin_post_backwpup_support` and send crafted input from source `inc/class-admin.php:1177` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a3-getblock-secret-disclosure
- Type: `sensitive_data_exposure`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `0.76`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest___getblock`, resolved `ep_rest___getblock`
- Trace: source `src/Frontend/API/Rest.php:83` -> sink `parts/sidebar/storage-FTP.php:178`
- Description (2 sentences): Finding `agent-a3-getblock-secret-disclosure` flags `sensitive_data_exposure` at `parts/sidebar/storage-FTP.php:178` via entry point `ep_rest___getblock`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.76`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___getblock` and send crafted input from source `src/Frontend/API/Rest.php:83` toward sink `parts/sidebar/storage-FTP.php:178`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a3-authenticate-cloud-bac
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `0.78`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest___authenticate_cloud`, resolved `ep_rest___authenticate_cloud`
- Trace: source `src/StorageProviders/API/Rest.php:194` -> sink `src/StorageProviders/SugarSync/SugarSyncProvider.php:134`
- Description (2 sentences): Finding `agent-a3-authenticate-cloud-bac` flags `broken_access_control` at `src/StorageProviders/SugarSync/SugarSyncProvider.php:134` via entry point `ep_rest___authenticate_cloud`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.78`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___authenticate_cloud` and send crafted input from source `src/StorageProviders/API/Rest.php:194` toward sink `src/StorageProviders/SugarSync/SugarSyncProvider.php:134`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a3-delete-auth-cloud-bac
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `0.78`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest___delete_auth_cloud`, resolved `ep_rest___delete_auth_cloud`
- Trace: source `src/StorageProviders/API/Rest.php:231` -> sink `src/StorageProviders/Dropbox/DropboxProvider.php:100`
- Description (2 sentences): Finding `agent-a3-delete-auth-cloud-bac` flags `broken_access_control` at `src/StorageProviders/Dropbox/DropboxProvider.php:100` via entry point `ep_rest___delete_auth_cloud`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.78`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___delete_auth_cloud` and send crafted input from source `src/StorageProviders/API/Rest.php:231` toward sink `src/StorageProviders/Dropbox/DropboxProvider.php:100`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a3-cloudsaveandtest-bac
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `0.76`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest___cloudsaveandtest`, resolved `ep_rest___cloudsaveandtest`
- Trace: source `src/StorageProviders/API/Rest.php:262` -> sink `inc/class-destination-ftp.php:65`
- Description (2 sentences): Finding `agent-a3-cloudsaveandtest-bac` flags `broken_access_control` at `inc/class-destination-ftp.php:65` via entry point `ep_rest___cloudsaveandtest`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.76`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___cloudsaveandtest` and send crafted input from source `src/StorageProviders/API/Rest.php:262` toward sink `inc/class-destination-ftp.php:65`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a3-storages-bac
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `0.86`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest___storages`, resolved `ep_rest___storages`
- Trace: source `src/StorageProviders/API/Rest.php:316` -> sink `src/StorageProviders/API/Rest.php:354`
- Description (2 sentences): Finding `agent-a3-storages-bac` flags `broken_access_control` at `src/StorageProviders/API/Rest.php:354` via entry point `ep_rest___storages`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.86`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___storages` and send crafted input from source `src/StorageProviders/API/Rest.php:316` toward sink `src/StorageProviders/API/Rest.php:354`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a3-updatejob-bac
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `0.84`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest___updatejob`, resolved `ep_rest___updatejob`
- Trace: source `src/Jobs/API/Rest.php:381` -> sink `src/Jobs/API/Rest.php:392`
- Description (2 sentences): Finding `agent-a3-updatejob-bac` flags `broken_access_control` at `src/Jobs/API/Rest.php:392` via entry point `ep_rest___updatejob`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.84`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___updatejob` and send crafted input from source `src/Jobs/API/Rest.php:381` toward sink `src/Jobs/API/Rest.php:392`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a3-update-job-title-bac
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `0.86`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest___update_job_title`, resolved `ep_rest___update_job_title`
- Trace: source `src/Jobs/API/Rest.php:469` -> sink `src/Jobs/API/Rest.php:473`
- Description (2 sentences): Finding `agent-a3-update-job-title-bac` flags `broken_access_control` at `src/Jobs/API/Rest.php:473` via entry point `ep_rest___update_job_title`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.86`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___update_job_title` and send crafted input from source `src/Jobs/API/Rest.php:469` toward sink `src/Jobs/API/Rest.php:473`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a3-addjob-bac
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `0.84`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest___addjob`, resolved `ep_rest___addjob`
- Trace: source `src/Jobs/API/Rest.php:493` -> sink `src/Jobs/API/Rest.php:524`
- Description (2 sentences): Finding `agent-a3-addjob-bac` flags `broken_access_control` at `src/Jobs/API/Rest.php:524` via entry point `ep_rest___addjob`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.84`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___addjob` and send crafted input from source `src/Jobs/API/Rest.php:493` toward sink `src/Jobs/API/Rest.php:524`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a3-delete-job-bac
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `0.84`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest___delete_job`, resolved `ep_rest___delete_job`
- Trace: source `src/Jobs/API/Rest.php:553` -> sink `src/Jobs/API/Rest.php:570`
- Description (2 sentences): Finding `agent-a3-delete-job-bac` flags `broken_access_control` at `src/Jobs/API/Rest.php:570` via entry point `ep_rest___delete_job`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.84`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___delete_job` and send crafted input from source `src/Jobs/API/Rest.php:553` toward sink `src/Jobs/API/Rest.php:570`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a3-save-job-settings-bac
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `0.81`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest___save_job_settings`, resolved `ep_rest___save_job_settings`
- Trace: source `src/Jobs/API/Rest.php:591` -> sink `src/Jobs/API/Rest.php:633`
- Description (2 sentences): Finding `agent-a3-save-job-settings-bac` flags `broken_access_control` at `src/Jobs/API/Rest.php:633` via entry point `ep_rest___save_job_settings`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.81`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___save_job_settings` and send crafted input from source `src/Jobs/API/Rest.php:591` toward sink `src/Jobs/API/Rest.php:633`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a3-save-job-format-bac
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `0.84`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest___save_job_format`, resolved `ep_rest___save_job_format`
- Trace: source `src/Jobs/API/Rest.php:677` -> sink `src/Jobs/API/Rest.php:708`
- Description (2 sentences): Finding `agent-a3-save-job-format-bac` flags `broken_access_control` at `src/Jobs/API/Rest.php:708` via entry point `ep_rest___save_job_format`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.84`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___save_job_format` and send crafted input from source `src/Jobs/API/Rest.php:677` toward sink `src/Jobs/API/Rest.php:708`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a3-save-files-exclusions-bac
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `0.76`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest___save_files_exclusions`, resolved `ep_rest___save_files_exclusions`
- Trace: source `src/Jobs/API/Rest.php:736` -> sink `inc/class-jobtype-file.php:217`
- Description (2 sentences): Finding `agent-a3-save-files-exclusions-bac` flags `broken_access_control` at `inc/class-jobtype-file.php:217` via entry point `ep_rest___save_files_exclusions`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.76`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___save_files_exclusions` and send crafted input from source `src/Jobs/API/Rest.php:736` toward sink `inc/class-jobtype-file.php:217`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a3-save-excluded-tables-bac
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `0.76`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest___save_excluded_tables`, resolved `ep_rest___save_excluded_tables`
- Trace: source `src/Jobs/API/Rest.php:762` -> sink `inc/class-jobtype-dbdump.php:149`
- Description (2 sentences): Finding `agent-a3-save-excluded-tables-bac` flags `broken_access_control` at `inc/class-jobtype-dbdump.php:149` via entry point `ep_rest___save_excluded_tables`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.76`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___save_excluded_tables` and send crafted input from source `src/Jobs/API/Rest.php:762` toward sink `inc/class-jobtype-dbdump.php:149`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a3-update-backup-type-bac
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `0.84`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest___backups___P_id__d___type`, resolved `ep_rest___backups___P_id__d___type`
- Trace: source `src/Jobs/API/Rest.php:436` -> sink `src/Jobs/API/Rest.php:451`
- Description (2 sentences): Finding `agent-a3-update-backup-type-bac` flags `broken_access_control` at `src/Jobs/API/Rest.php:451` via entry point `ep_rest___backups___P_id__d___type`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.84`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___backups___P_id__d___type` and send crafted input from source `src/Jobs/API/Rest.php:436` toward sink `src/Jobs/API/Rest.php:451`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a3-startbackup-bac
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `0.81`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest_backwpup_v1__startbackup`, resolved `ep_rest_backwpup_v1__startbackup`
- Trace: source `src/Backups/API/Rest.php:157` -> sink `src/Backups/API/Rest.php:260`
- Description (2 sentences): Finding `agent-a3-startbackup-bac` flags `broken_access_control` at `src/Backups/API/Rest.php:260` via entry point `ep_rest_backwpup_v1__startbackup`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.81`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest_backwpup_v1__startbackup` and send crafted input from source `src/Backups/API/Rest.php:157` toward sink `src/Backups/API/Rest.php:260`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-a3-process-bulk-actions-needs-proof
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `medium` | Confidence: `0.76`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest_backwpup_v1__process_bulk_actions`, resolved `ep_rest_backwpup_v1__process_bulk_actions`
- Trace: source `src/Backups/API/Rest.php:360` -> sink `src/Backups/API/Rest.php:420`
- Description (2 sentences): Finding `agent-a3-process-bulk-actions-needs-proof` flags `broken_access_control` at `src/Backups/API/Rest.php:420` via entry point `ep_rest_backwpup_v1__process_bulk_actions`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.76`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest_backwpup_v1__process_bulk_actions` and send crafted input from source `src/Backups/API/Rest.php:360` toward sink `src/Backups/API/Rest.php:420`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-c-anom_13
- Type: `inconsistency`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `0.59`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_admin_post_admin_post_backwpup_support`, resolved `ep_admin_post_admin_post_backwpup_support`
- Trace: source `inc/class-admin.php:1177` -> sink `inc/class-admin.php:1177`
- Description (2 sentences): Finding `agent-c-anom_13` flags `inconsistency` at `inc/class-admin.php:1177` via entry point `ep_admin_post_admin_post_backwpup_support`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.59`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- Validation issues: `guard_contradiction, path_reachability_weak`
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_admin_post_admin_post_backwpup_support` and send crafted input from source `inc/class-admin.php:1177` toward sink `inc/class-admin.php:1177`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### agent-d-cg-002
- Type: `missing_authentication_ajax_handler`
- Minimum Role/Capability: `unknown`
- Severity: `high` | Confidence: `0.56`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_ajax_priv_wp_ajax_download_backup_file`, resolved `ep_ajax_priv_wp_ajax_download_backup_file`
- Trace: source `inc/class-destination-downloader.php:58` -> sink `inc/class-destination-downloader.php:95`
- Description (2 sentences): Finding `agent-d-cg-002` flags `missing_authentication_ajax_handler` at `inc/class-destination-downloader.php:95` via entry point `ep_ajax_priv_wp_ajax_download_backup_file`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.56`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `unknown`.
- Validation issues: `guard_contradiction, path_reachability_weak, reasoning_quality_low`
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Logged-in user (subscriber+) sends: POST /wp-admin/admin-ajax.php?action=download_backup_file&destination=FOLDER&jobid=1&file=../wp-config.php&local_file=../wp-config.php. If file_download() follows these paths without further restriction, sensitive files may be disclosed.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

## Risk Notes
None.

## Rejected Findings
### agent-a2-f003
- Type: `path_traversal`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_backwpup_working`, resolved `ep_ajax_priv_wp_ajax_backwpup_working`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f003` flags `path_traversal` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_backwpup_working`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_backwpup_working` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f004
- Type: `cross_site_scripting`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_backwpup_cron_text`, resolved `ep_ajax_priv_wp_ajax_backwpup_cron_text`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f004` flags `cross_site_scripting` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_backwpup_cron_text`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_backwpup_cron_text` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f005
- Type: `path_traversal`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_backwpup_view_log`, resolved `ep_ajax_priv_wp_ajax_backwpup_view_log`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f005` flags `path_traversal` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_backwpup_view_log`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_backwpup_view_log` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f006
- Type: `arbitrary_file_read`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_download_backup_file`, resolved `ep_ajax_priv_wp_ajax_download_backup_file`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f006` flags `arbitrary_file_read` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_download_backup_file`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_download_backup_file` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a2-f007
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_ajax_priv_wp_ajax_encrypt_key_handler`, resolved `ep_ajax_priv_wp_ajax_encrypt_key_handler`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a2-f007` flags `broken_access_control` at `N/A:N/A` via entry point `ep_ajax_priv_wp_ajax_encrypt_key_handler`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_ajax_priv_wp_ajax_encrypt_key_handler` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-storagelistcompact-readonly
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest_backwpup_v1__storagelistcompact`, resolved `ep_rest_backwpup_v1__storagelistcompact`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-storagelistcompact-readonly` flags `broken_access_control` at `N/A:N/A` via entry point `ep_rest_backwpup_v1__storagelistcompact`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest_backwpup_v1__storagelistcompact` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-cloud-is-authenticated-readonly
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest___cloud_is_authenticated`, resolved `ep_rest___cloud_is_authenticated`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-cloud-is-authenticated-readonly` flags `broken_access_control` at `N/A:N/A` via entry point `ep_rest___cloud_is_authenticated`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___cloud_is_authenticated` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-messages-queue-readonly
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest___messages`, resolved `ep_rest___messages`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-messages-queue-readonly` flags `broken_access_control` at `N/A:N/A` via entry point `ep_rest___messages`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___messages` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-chatbot-create-context-safe
- Type: `information_disclosure`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest___0`, resolved `ep_rest___0`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-chatbot-create-context-safe` flags `information_disclosure` at `N/A:N/A` via entry point `ep_rest___0`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___0` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-chatbot-get-context-token-gated
- Type: `information_disclosure`
- Minimum Role/Capability: `none`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest___1`, resolved `ep_rest___1`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-chatbot-get-context-token-gated` flags `information_disclosure` at `N/A:N/A` via entry point `ep_rest___1`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___1` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-getjobslist-readonly
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest_backwpup_v1__getjobslist`, resolved `ep_rest_backwpup_v1__getjobslist`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-getjobslist-readonly` flags `broken_access_control` at `N/A:N/A` via entry point `ep_rest_backwpup_v1__getjobslist`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest_backwpup_v1__getjobslist` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-save-site-option-default-roles-safe
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest___save_site_option`, resolved `ep_rest___save_site_option`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-save-site-option-default-roles-safe` flags `broken_access_control` at `N/A:N/A` via entry point `ep_rest___save_site_option`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___save_site_option` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-backups-list-readonly
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest___backups`, resolved `ep_rest___backups`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-backups-list-readonly` flags `broken_access_control` at `N/A:N/A` via entry point `ep_rest___backups`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___backups` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-a3-pagination-readonly
- Type: `broken_access_control`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_rest___pagination`, resolved `ep_rest___pagination`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-a3-pagination-readonly` flags `broken_access_control` at `N/A:N/A` via entry point `ep_rest___pagination`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_rest___pagination` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-c-anom_2
- Type: `missing_nonce`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_admin_init_admin_init`, resolved `ep_admin_init_admin_init`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-c-anom_2` flags `missing_nonce` at `N/A:N/A` via entry point `ep_admin_init_admin_init`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_admin_init_admin_init` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-c-anom_8
- Type: `missing_capability`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_admin_init_admin_init`, resolved `ep_admin_init_admin_init`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-c-anom_8` flags `missing_capability` at `N/A:N/A` via entry point `ep_admin_init_admin_init`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_admin_init_admin_init` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-c-anom_11
- Type: `unsanitized_sql`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_admin_init_admin_init`, resolved `ep_admin_init_admin_init`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-c-anom_11` flags `unsanitized_sql` at `N/A:N/A` via entry point `ep_admin_init_admin_init`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_admin_init_admin_init` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-c-anom_12
- Type: `is_admin_as_auth`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `ep_admin_init_admin_init`, resolved `ep_admin_init_admin_init`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-c-anom_12` flags `is_admin_as_auth` at `N/A:N/A` via entry point `ep_admin_init_admin_init`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `ep_admin_init_admin_init` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-d-uh-001
- Type: `unresolved_hook_resolution`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `resolved_dynamic:3e529ca494c3acb7748c6ac45a509f1e5eac8dd2`, resolved `resolved_dynamic:3e529ca494c3acb7748c6ac45a509f1e5eac8dd2`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-d-uh-001` flags `unresolved_hook_resolution` at `N/A:N/A` via entry point `resolved_dynamic:3e529ca494c3acb7748c6ac45a509f1e5eac8dd2`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `resolved_dynamic:3e529ca494c3acb7748c6ac45a509f1e5eac8dd2` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-d-uh-002
- Type: `unresolved_hook_resolution`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `resolved_dynamic:95ff1bb5bf495e2d04a8d96b88dc0b537ef53b65`, resolved `resolved_dynamic:95ff1bb5bf495e2d04a8d96b88dc0b537ef53b65`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-d-uh-002` flags `unresolved_hook_resolution` at `N/A:N/A` via entry point `resolved_dynamic:95ff1bb5bf495e2d04a8d96b88dc0b537ef53b65`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `resolved_dynamic:95ff1bb5bf495e2d04a8d96b88dc0b537ef53b65` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-d-uh-003
- Type: `unresolved_hook_resolution`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `resolved_dynamic:8f42e21fb1d9d1cf4cb0b537c1046bfe61a7711e`, resolved `resolved_dynamic:8f42e21fb1d9d1cf4cb0b537c1046bfe61a7711e`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-d-uh-003` flags `unresolved_hook_resolution` at `N/A:N/A` via entry point `resolved_dynamic:8f42e21fb1d9d1cf4cb0b537c1046bfe61a7711e`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `resolved_dynamic:8f42e21fb1d9d1cf4cb0b537c1046bfe61a7711e` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-d-uh-004
- Type: `unresolved_hook_resolution`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `0.38`
- Gate Verdict: `REJECTED`
- Entry point: claimed `unresolved:inc/dependencies/wp-media/event-manager/EventManager.php:26`, resolved `None`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-d-uh-004` flags `unresolved_hook_resolution` at `N/A:N/A` via entry point `unresolved:inc/dependencies/wp-media/event-manager/EventManager.php:26`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- Validation issues: `code_evidence_missing_or_mismatch, deterministic_refutation, file_not_found_or_unresolvable, missing_sink_file_path, missing_sink_line_number, path_reachability_weak, reasoning_quality_low`
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `unresolved:inc/dependencies/wp-media/event-manager/EventManager.php:26` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

### agent-d-cg-001
- Type: `coverage_gap_analysis`
- Minimum Role/Capability: `unknown`
- Severity: `informational` | Confidence: `1.00`
- Gate Verdict: `REJECTED`
- Entry point: claimed `None`, resolved `None`
- Trace: source `N/A:N/A` -> sink `N/A:N/A`
- Description (2 sentences): Finding `agent-d-cg-001` flags `coverage_gap_analysis` at `N/A:N/A` via entry point `N/A`. Gate validation currently treats it as non-actionable (`REJECTED`) with no confirmed exploit path.
- Highest Impact: No confirmed measurable security impact in current plugin-local evidence.
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `unknown` required by this path.
  - Step 3 (Attack): Use entry point `N/A` and send crafted input from source `N/A:N/A` toward sink `N/A:N/A`.
  - Step 4 (Verify): Confirm the action is rejected or results in no unauthorized read/write/privilege change.

## Why Not Confirmed
- `agent-a2-f001`: guard_contradiction
- `agent-a2-f002`: guard_contradiction, path_reachability_weak
- `agent-a2-f008`: code_evidence_missing_or_mismatch, guard_contradiction, missing_sink_file_path, missing_sink_line_number
- `agent-c-anom_13`: guard_contradiction, path_reachability_weak
- `agent-d-cg-002`: guard_contradiction, path_reachability_weak, reasoning_quality_low

## Stored/Second-order Notes
No stored/second-order findings in this plugin.

## Overall Assessment
Deterministic gate output is authoritative for status classification. If LLM skeptic review exists, use it as supplemental counter-evidence only.
