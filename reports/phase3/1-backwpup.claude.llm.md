# BackWPup — Phase 3b LLM Skeptic Review

## 1. Plugin Overview

**Plugin:** BackWPup (Free + Pro)  
**Function:** WordPress backup plugin. Creates scheduled or on-demand backups of files, databases, and mixed content; stores archives at local folders or cloud destinations (FTP, S3, Azure, Rackspace, Dropbox, SugarSync). Implements a custom role model (`backwpup_admin`, `backwpup_check`, `backwpup_helper`) with fine-grained capabilities such as `backwpup_jobs_edit`, `backwpup_jobs_start`, `backwpup_settings`, and `backwpup_backups_delete`.

**Authentication model:** Relies on WordPress capability checks. Most REST API routes share a single `has_permission()` function that checks only `current_user_can('backwpup')` — the broadest plugin capability present on all three custom roles. A subset of destructive operations in the classic admin UI are gated on finer capabilities (`backwpup_jobs_edit`, `backwpup_settings`, `backwpup_jobs_start`). The REST API surface, introduced for the new UI, does not consistently enforce those finer gates.

**Review scope:** 19 UNCERTAIN findings from Phase 3a. No PLAUSIBLE findings in scope. Zero CONFIRMED or REJECTED findings were re-reviewed.

---

## 2. Validation Summary

| Metric | Count |
|---|---|
| Total reviewed | 19 |
| Downgraded | 0 |
| Kept (UNCERTAIN) | 5 |
| Upgraded (evidence supports) | 14 |

*"Upgraded" means source-code evidence fully supports the claimed exploit path. Only Phase 3a deterministic gate can emit CONFIRMED.*

---

## 3. Detailed Reviews

---

### Finding ID: `agent-a2-f001`
- **Type:** sensitive_information_disclosure (CWE-200)
- **Minimum Role/Capability:** Any authenticated WordPress user (subscriber)
- **Status Transition:** UNCERTAIN → **keep**
- **Description:** The `wp_ajax_backwpup_debug_info` closure registered at `inc/class-admin.php:281` has no `check_ajax_referer()` or `current_user_can()` call. Any authenticated user (not just BackWPup users) can call `admin-ajax.php?action=backwpup_debug_info` and receive the full debug report including document root, temp/log folder paths, WP-Cron URL, and PHP user.
- **Highest Impact:** Server filesystem layout (absolute paths, PHP runtime user, loaded extensions) disclosed to any logged-in user, enabling targeted reconnaissance for follow-on attacks.

**PoC:**
1. Setup: WordPress installation with BackWPup active.
2. Activate plugin: BackWPup installed and active.
3. Attack: Authenticate as any subscriber-level account and POST to `/wp-admin/admin-ajax.php` with body `action=backwpup_debug_info`.
4. Verify: Response body contains absolute paths (document root, temp folder, log folder), the PHP user, WP-Cron URL, and loaded PHP extensions.

**Counter-evidence:** None found. No capability or nonce check exists before the echo at line 287.

**Dynamic test plan:**
1. Create a WordPress subscriber account (no BackWPup role).
2. Authenticate and POST to `/wp-admin/admin-ajax.php` with `action=backwpup_debug_info`.
3. Confirm 200 response with debug output present.
4. Repeat unauthenticated — expect `-1` or `0` to confirm the `wp_ajax_nopriv_` hook is not registered.

---

### Finding ID: `agent-a2-f002`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role)
- **Status Transition:** UNCERTAIN → **keep**
- **Description:** `BackWPup_Admin::save_post_form()` at `inc/class-admin.php:849-894` checks nonce and `current_user_can('backwpup')`, but when `$_POST['onboarding'] === '1'` it dispatches to `BackWPup_Page_Onboarding::save_post_form()` without a second capability check. That method updates job options, schedules cron events, and marks onboarding complete — operations that should require `backwpup_jobs_edit` or `backwpup_settings`.
- **Highest Impact:** While onboarding is active, a `backwpup_check` user can modify backup job scheduling, storage destinations, and deactivate the onboarding state, bypassing the `backwpup_jobs_edit` boundary.

**PoC:**
1. Setup: Set `backwpup_onboarding=true` in site options; assign a user the `backwpup_check` role.
2. Activate plugin: BackWPup installed with default roles.
3. Attack: Log in as `backwpup_check` user, visit onboarding page to obtain `backwpup_page` nonce, then POST to `/wp-admin/admin-post.php` with `action=backwpup`, `page=backwpup`, `onboarding=1`, desired frequency, and `onboarding_storage[]`.
4. Verify: Job options are updated and `backwpup_onboarding` site option flips to `false`, confirming capability bypass.

**Counter-evidence:**  
- `inc/class-admin.php:849` — nonce check present (`check_admin_referer`) but only validates page origin, not edit capability.  
- `inc/class-admin.php:851` — `current_user_can('backwpup')` — broad capability only.

**Dynamic test plan:**
1. Enable onboarding, assign `backwpup_check` role.
2. Obtain nonce from onboarding page.
3. Submit the `admin-post.php` payload as described above.
4. Confirm job option changes in the database.
5. Attempt same POST without nonce to verify nonce is enforced.

---

### Finding ID: `agent-a2-f008`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** Unknown (Pro-only callback — not verifiable)
- **Status Transition:** UNCERTAIN → **keep**
- **Description:** At `inc/class-admin.php:1177`, `admin_post_backwpup_support` is registered to dispatch to `BackWPup_Pro_Page_Support::save_post_form()`. That Pro class is absent from the audited free source tree, so no data flow can be traced. The finding remains uncertain because neither exploit nor safe-discharge can be established.
- **Highest Impact:** Cannot be quantified without the Pro implementation — potentially any state change the Pro support form can perform.

**PoC:**  
1. Setup: Install BackWPup Pro.
2. Activate plugin.
3. Attack: Submit `POST /wp-admin/admin-post.php?action=backwpup_support` without appropriate capability (if supported).
4. Verify: Observe any state-changing effect produced by the support form handler.

**Counter-evidence:**  
- `inc/class-admin.php:1177` — only registration exists; callback body not in audited tree.

**Dynamic test plan:**
1. Obtain BackWPup Pro source and locate `BackWPup_Pro_Page_Support::save_post_form()`.
2. Trace any internal capability or nonce checks.
3. If no internal checks: submit the form as a subscriber and observe response.
4. Document any state changes.

---

### Finding ID: `agent-a3-getblock-secret-disclosure`
- **Type:** sensitive_data_exposure (CWE-200)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role)
- **Status Transition:** UNCERTAIN → **upgrade**
- **Description:** The `/getblock` REST route at `src/Frontend/API/Rest.php:66-68` checks only `current_user_can('backwpup')`. When `block_type=children` and `block_name=sidebar/storage-FTP`, the `children()` helper at `inc/Utils/BackWPupHelpers.php:71-116` includes `parts/sidebar/storage-FTP.php`, which calls `BackWPup_Encryption::decrypt(BackWPup_Option::get($job_id,'ftppass'))` at line 178 and outputs the decrypted password into the HTML response.
- **Highest Impact:** Decrypted FTP, S3, Azure, Rackspace, and SugarSync credentials for all backup jobs are exposed to any `backwpup_check` user who knows (or guesses) a valid `job_id`.

**PoC:**
1. Setup: Configure a backup job with FTP destination; assign a user the `backwpup_check` role.
2. Activate plugin: BackWPup active with an FTP-configured job.
3. Attack: Obtain `wp_rest` nonce from localized admin data (`inc/class-admin.php:1234,1246`). POST to `/wp-json/backwpup/v1/getblock` with `{"block_type":"children","block_name":"sidebar/storage-FTP","block_data":{"job_id":<N>}}`.
4. Verify: Response HTML contains the decrypted FTP password in the `ftppass` input value.

**Counter-evidence:**  
- `inc/Utils/BackWPupHelpers.php:74` — path traversal blocked; `inc/Utils/BackWPupHelpers.php:94` — file confined to `parts/` directory. These guards prevent directory escape but are not an allowlist for sensitive partials.

**Dynamic test plan:**
1. Assign `backwpup_check` role; ensure FTP job with stored password exists.
2. Obtain `wp_rest` nonce.
3. POST `getblock` request with `block_name=sidebar/storage-FTP` and valid `job_id`.
4. Confirm decrypted FTP password appears in response.
5. Repeat with `sidebar/storage-S3`, `sidebar/storage-MSAZURE`, `sidebar/storage-RSC` to enumerate all secret-bearing partials.

---

### Finding ID: `agent-a3-authenticate-cloud-bac`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role)
- **Status Transition:** UNCERTAIN → **upgrade**
- **Description:** The `/authenticate_cloud` route at `src/StorageProviders/API/Rest.php:138-140` checks only `current_user_can('backwpup')`. `SugarSyncProvider::authenticate()` at line 117 accepts caller-supplied `sugaremail`/`sugarpass`, contacts the SugarSync API, and persists the resulting refresh token via `$this->option_adapter->update()` at line 134 — directly confirmed in source.
- **Highest Impact:** A `backwpup_check` user can bind backup jobs to attacker-controlled cloud credentials, redirecting all future backups to an attacker-owned storage account and breaking backup integrity.

**PoC:**
1. Setup: A job using SugarSync or another implemented cloud provider; assign `backwpup_check` role.
2. Attack: POST to `/wp-json/backwpup/v1/authenticate_cloud` with `cloud_name=sugarsync`, attacker-controlled `sugaremail` and `sugarpass`.
3. Verify: The job's `sugarrefreshtoken` option is updated with the new credential.

**Counter-evidence:** None found.

**Dynamic test plan:**
1. Assign `backwpup_check` role; obtain `wp_rest` nonce.
2. POST to `authenticate_cloud` with valid SugarSync credentials.
3. Confirm `sugarrefreshtoken` option updated in database.
4. Verify `backwpup_check` user cannot reach the credential update form via the classic edit-job UI.

---

### Finding ID: `agent-a3-delete-auth-cloud-bac`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role)
- **Status Transition:** UNCERTAIN → **keep**
- **Description:** The `/delete_auth_cloud` route shares the same `has_permission()` (backwpup only) as `authenticate_cloud`. The authorization gap is structurally identical, but the sink function (`OptionAdapter::delete` or per-provider equivalent) was not confirmed in source — each provider's `delete_auth()` implementation needs to be located to verify the delete path.
- **Highest Impact:** If confirmed: a `backwpup_check` user can revoke cloud authentication tokens, disrupting backup continuity for all affected jobs.

**PoC:**
1. Setup: Configure a job with Dropbox authentication.
2. Attack: POST to `/wp-json/backwpup/v1/delete_auth_cloud` with `cloud_name=dropbox` as `backwpup_check` user.
3. Verify: Dropbox auth token cleared from job options.

**Counter-evidence:** None found at route level. Sink implementation unverified.

**Dynamic test plan:**
1. Locate `DropboxProvider::delete_auth()` in source tree and confirm sink.
2. Assign `backwpup_check` role; POST `delete_auth_cloud` with `cloud_name=dropbox`.
3. Inspect the backup job's option table before and after.
4. Verify the same action requires `backwpup_jobs_edit` via the classic UI.

---

### Finding ID: `agent-a3-cloudsaveandtest-bac`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role)
- **Status Transition:** UNCERTAIN → **upgrade**
- **Description:** `cloud_save_and_test()` at `src/StorageProviders/API/Rest.php:262` calls `edit_form_post_save($jobs)` on the attacker-chosen destination **before** calling `can_run()` — the credential overwrite completes before any connection validation. `BackWPup_Destination_FTP::edit_form_post_save()` at `inc/class-destination-ftp.php:43-86` persists `ftphost`, `ftpuser`, and encrypted `ftppass`. The route at line 138 checks only `current_user_can('backwpup')`.
- **Highest Impact:** A `backwpup_check` user can overwrite storage credentials (FTP, S3, Azure, Rackspace, Dropbox, email) for any job, redirecting backups to attacker-controlled infrastructure even if the connection test ultimately fails.

**PoC:**
1. Setup: A job with FTP destination; assign `backwpup_check` role.
2. Attack: POST to `/wp-json/backwpup/v1/cloudsaveandtest` with `cloud_name=FTP`, `job_id=<N>`, `ftphost=attacker.host`, `ftpuser=a`, `ftppass=pw`.
3. Verify: Job's `ftphost` option changed to `attacker.host` even if the connection test fails.

**Counter-evidence:**  
- `src/StorageProviders/API/Rest.php:293` — `can_run()` check after `edit_form_post_save()` — write-then-check ordering means the unauthorized write is already committed.

**Dynamic test plan:**
1. Assign `backwpup_check` role; note existing FTP configuration.
2. POST `cloudsaveandtest` with attacker-controlled FTP credentials.
3. Verify credentials changed in database even if `can_run()` returns false.
4. Repeat with S3 and Azure destinations.

---

### Finding ID: `agent-a3-storages-bac`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role)
- **Status Transition:** UNCERTAIN → **upgrade**
- **Description:** `update_job_storage_options()` at `src/StorageProviders/API/Rest.php:316` calls `$this->option_adapter->update($job_id,'destinations',$destinations)` at line 354 — confirmed in source. The route checks only `current_user_can('backwpup')`. The only constraint is that at least one destination must remain (line 350-352), which does not prevent unauthorized add/remove operations.
- **Highest Impact:** A `backwpup_check` user can add or remove storage destinations for any backup job, potentially disabling cloud offsite backups or redirecting them to a different destination type.

**PoC:**
1. Setup: A job with cloud storage destination; assign `backwpup_check` role.
2. Attack: POST to `/wp-json/backwpup/v2/storages` with `name=FOLDER`, `job_id=<N>`, `checked=false`.
3. Verify: Job's `destinations` option now includes `FOLDER`.

**Counter-evidence:**  
- `src/StorageProviders/API/Rest.php:350` — minimum one-destination guard (prevents full removal, not unauthorized modification).

**Dynamic test plan:**
1. Assign `backwpup_check` role; note current destinations.
2. POST `storages` to add FOLDER destination.
3. Confirm `destinations` option updated.
4. POST to remove an existing destination (keep one), verify removal succeeds.

---

### Finding ID: `agent-a3-updatejob-bac`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role)
- **Status Transition:** UNCERTAIN → **upgrade**
- **Description:** `update_job()` at `src/Jobs/API/Rest.php:381` calls `$this->job_adapter->disable_job($job_id)` at line 392 and `enable_job()` at line 395 — confirmed in source. The route's `has_permission()` checks only `current_user_can('backwpup')`. The `backwpup_check` role has `backwpup_jobs_start=false` and `backwpup_jobs_edit=false`. The Phase 3a gate false-negative on code_evidence was due to method-name case mismatch in the gate logic.
- **Highest Impact:** A `backwpup_check` user can enable, disable, or reschedule backup jobs, and can also overwrite job storage destinations via the second code branch at line 417.

**PoC:**
1. Setup: An active backup job; assign `backwpup_check` role.
2. Attack: POST to `/wp-json/backwpup/v1/updatejob` with `job_id=<N>`, `activ=false`.
3. Verify: Job's cron hook is cleared and `activetype` is set to empty/disabled.

**Counter-evidence:**  
- `src/Jobs/API/Rest.php:104` — `job_id` validated as positive integer (input validation, not authorization).

**Dynamic test plan:**
1. Assign `backwpup_check` role; note job active state.
2. POST `updatejob` with `activ=false`.
3. Confirm cron is cleared for the job.
4. POST `updatejob` with `storage_destinations=['FOLDER']` to test the destination override path.

---

### Finding ID: `agent-a3-update-job-title-bac`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role)
- **Status Transition:** UNCERTAIN → **upgrade**
- **Description:** `update_job_title()` at `src/Jobs/API/Rest.php:469` calls `$this->job_adapter->rename_job($params['job_id'],$title)` at line 473 — confirmed in source. The route checks only `current_user_can('backwpup')`. The Phase 3a gate false-negative on code_evidence was a method-name matching issue; the call exists at the claimed line.
- **Highest Impact:** Low-impact in isolation, but unauthorized job renaming can corrupt admin visibility and audit trails for backup jobs.

**PoC:**
1. Setup: An existing backup job; assign `backwpup_check` role.
2. Attack: POST to `/wp-json/backwpup/v1/update-job-title` with `job_id=<N>`, `title=Attacker Title`.
3. Verify: Job name changes in the database.

**Counter-evidence:**  
- `src/Jobs/API/Rest.php:147` — title sanitized via `sanitize_text_field` (prevents markup injection, not unauthorized rename).

**Dynamic test plan:**
1. Assign `backwpup_check` role.
2. POST `update-job-title` with attacker title.
3. Verify job name updated in site options.
4. Confirm `backwpup_check` blocked on legacy edit-job UI.

---

### Finding ID: `agent-a3-addjob-bac`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role)
- **Status Transition:** UNCERTAIN → **upgrade**
- **Description:** `add_job()` at `src/Jobs/API/Rest.php:493` calls `$this->option_adapter->update($job_id,$key,$value)` at line 524 for each default job field, then schedules a cron event — confirmed in source. The route checks only `current_user_can('backwpup')`. The `backwpup_check` role lacks `backwpup_jobs_edit`.
- **Highest Impact:** A `backwpup_check` user can create unlimited new backup jobs, wasting server resources, filling storage destinations, and polluting the backup schedule.

**PoC:**
1. Setup: Assign `backwpup_check` role.
2. Attack: POST to `/wp-json/backwpup/v1/addjob` with `type=files`.
3. Verify: New job entry appears in `backwpup_jobs` option and a cron event is scheduled.

**Counter-evidence:**  
- `src/Jobs/API/Rest.php:165` — type constrained to `files/database/mixed` (template restriction, not access control).

**Dynamic test plan:**
1. Assign `backwpup_check` role.
2. POST `addjob` multiple times with different `type` values.
3. Confirm new job entries and cron events created.
4. Verify `backwpup_check` blocked on legacy job creation UI.

---

### Finding ID: `agent-a3-delete-job-bac`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role)
- **Status Transition:** UNCERTAIN → **upgrade**
- **Description:** `delete_job()` at `src/Jobs/API/Rest.php:553` calls `$this->job_adapter->delete_job($job_id)` at line 570 — confirmed in source. The route checks only `current_user_can('backwpup')`. The `backwpup_check` role lacks `backwpup_jobs_edit`. The Phase 3a gate false-negative was a method-name matching issue.
- **Highest Impact:** A `backwpup_check` user can delete all backup jobs, completely disabling the backup system for the WordPress site.

**PoC:**
1. Setup: An existing backup job; assign `backwpup_check` role.
2. Attack: Send DELETE to `/wp-json/backwpup/v1/delete_job?job_id=<N>` with `wp_rest` nonce.
3. Verify: Job no longer exists in `backwpup_jobs` option.

**Counter-evidence:**  
- `src/Jobs/API/Rest.php:184` — `job_id` validated as positive integer (input validation, not authorization).

**Dynamic test plan:**
1. Assign `backwpup_check` role; note existing job IDs.
2. Send DELETE `delete_job` for each job.
3. Verify all jobs deleted from database.
4. Confirm `backwpup_check` blocked on classic jobs UI deletion action.

---

### Finding ID: `agent-a3-save-job-settings-bac`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role)
- **Status Transition:** UNCERTAIN → **upgrade**
- **Description:** `save_job_settings()` at `src/Jobs/API/Rest.php:591` calls `$this->option_adapter->update($job_id,'frequency',$frequency)` at line 615, then updates `cron` and `activetype` options and reschedules the job — confirmed in source. The route checks only `current_user_can('backwpup')`. The `backwpup_check` role lacks `backwpup_jobs_edit`.
- **Highest Impact:** A `backwpup_check` user can change backup frequency to an infrequent schedule or set `activetype=link` (external-link trigger) to disable automatic scheduling, effectively sabotaging backup continuity.

**PoC:**
1. Setup: An active backup job with daily frequency; assign `backwpup_check` role.
2. Attack: POST to `/wp-json/backwpup/v1/save_job_settings` with `job_id=<N>`, `frequency=link`.
3. Verify: Job's `activetype` set to `link`, cron event cleared.

**Counter-evidence:** None found.

**Dynamic test plan:**
1. Assign `backwpup_check` role.
2. POST `save_job_settings` with `frequency=link`.
3. Verify `activetype=link` and cron cleared.
4. Reset frequency via the same endpoint.

---

### Finding ID: `agent-a3-save-job-format-bac`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role)
- **Status Transition:** UNCERTAIN → **upgrade**
- **Description:** `save_job_format()` at `src/Jobs/API/Rest.php:677` calls `$this->option_adapter->update($job_id,'archiveformat',$archive_format)` and `update(...,'archivename',...)` at lines 708-709 — confirmed in source. Input constraints (extension allowlist, `%hash%` requirement) are present but restrict input shape, not caller privilege.
- **Highest Impact:** A `backwpup_check` user can change archive format to `.zip` (potentially larger files) or rename the archive pattern, disrupting monitoring and retention scripts that rely on predictable naming.

**PoC:**
1. Setup: A backup job; assign `backwpup_check` role.
2. Attack: POST to `/wp-json/backwpup/v2/save_job_format` with `job_id=<N>`, `archiveformat=.zip`, `archivename=modified-%hash%`.
3. Verify: Job's `archiveformat` changed to `.zip`.

**Counter-evidence:**  
- `src/Jobs/API/Rest.php:696` — extension allowlist (shape constraint, not authorization).  
- `src/Jobs/API/Rest.php:700` — requires `%hash%` (shape constraint, not authorization).

**Dynamic test plan:**
1. Assign `backwpup_check` role.
2. POST `save_job_format` with format change.
3. Verify `archiveformat` updated.
4. Verify `backwpup_check` blocked on legacy archive-format setting in edit-job UI.

---

### Finding ID: `agent-a3-save-files-exclusions-bac`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role)
- **Status Transition:** UNCERTAIN → **upgrade**
- **Description:** `save_files_exclusions()` at `src/Jobs/API/Rest.php:736` forwards attacker-controlled data to `BackWPup_JobType_File::edit_form_post_save()` at line 742, which calls `BackWPup_Option::update()` to persist `fileexclude`, `dirinclude`, and boolean inclusion flags at `inc/class-jobtype-file.php:217-260`. The route checks only `current_user_can('backwpup')`.
- **Highest Impact:** A `backwpup_check` user can set `fileexclude=*` to exclude all files from the backup, rendering file backups empty while the backup process still completes without error.

**PoC:**
1. Setup: A file-backup job; assign `backwpup_check` role.
2. Attack: POST to `/wp-json/backwpup/v1/save_files_exclusions` with `job_id=<N>`, `fileexclude=*`, `backuproot=0`.
3. Verify: Job's `fileexclude` set to `*` and `backuproot=0`.
4. Trigger a backup and confirm resulting archive is empty.

**Counter-evidence:**  
- `inc/class-jobtype-file.php:225` — path sanitization (prevents injection, not unauthorized modification).

**Dynamic test plan:**
1. Assign `backwpup_check` role.
2. POST `save_files_exclusions` with `fileexclude=*`.
3. Verify option updated.
4. Trigger backup and confirm no files included.

---

### Finding ID: `agent-a3-save-excluded-tables-bac`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role)
- **Status Transition:** UNCERTAIN → **upgrade**
- **Description:** `save_excluded_tables()` at `src/Jobs/API/Rest.php:762` passes attacker-controlled `tabledb` values into `BackWPup_JobType_DBDump::edit_form_post_save()` at line 769, which writes the `dbdumpexclude` array via `BackWPup_Option::update()` at `inc/class-jobtype-dbdump.php:172`. Submitting an empty `tabledb` selection causes all tables to be excluded, producing an empty database backup.
- **Highest Impact:** A `backwpup_check` user can silently disable database backups by excluding all tables, creating a false sense of backup security while the database backup file is empty.

**PoC:**
1. Setup: A database-backup job; assign `backwpup_check` role.
2. Attack: POST to `/wp-json/backwpup/v1/save_excluded_tables` with `job_id=<N>`, `tabledb=[]`.
3. Verify: Job's `dbdumpexclude` contains all database tables.
4. Trigger a backup and confirm the resulting SQL dump is empty.

**Counter-evidence:**  
- `inc/class-jobtype-dbdump.php:149` — table name sanitization (injection prevention, not authorization).

**Dynamic test plan:**
1. Assign `backwpup_check` role.
2. POST `save_excluded_tables` with empty `tabledb`.
3. Verify `dbdumpexclude` updated.
4. Trigger database backup and confirm empty dump.

---

### Finding ID: `agent-a3-update-backup-type-bac`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role)
- **Status Transition:** UNCERTAIN → **upgrade**
- **Description:** `update_backup_type()` at `src/Jobs/API/Rest.php:436` calls `$this->option_adapter->update($job_id,'type',$mapped_type)` and `update($job_id,'name',...)` at lines 450-452 — confirmed in source. The route checks only `current_user_can('backwpup')`. The Phase 3a gate false-negative was a method-name matching issue.
- **Highest Impact:** A `backwpup_check` user can change a database-only backup job to files-only, causing the database to be excluded from future backups without any visible error.

**PoC:**
1. Setup: A database-backup job; assign `backwpup_check` role.
2. Attack: POST to `/wp-json/backwpup/v2/backups/<job_id>/type` with `type=files`.
3. Verify: Job's `type` option changes from DBDUMP to FILE+WPPLUGIN.

**Counter-evidence:**  
- `src/Jobs/API/Rest.php:361` — type constrained to `files/database/mixed` (shape constraint, not authorization).

**Dynamic test plan:**
1. Assign `backwpup_check` role.
2. POST to `/wp-json/backwpup/v2/backups/<N>/type` with `type=files`.
3. Verify `type` option changed.
4. Confirm `backwpup_check` blocked on classic edit-job type change.

---

### Finding ID: `agent-a3-startbackup-bac`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role)
- **Status Transition:** UNCERTAIN → **upgrade**
- **Description:** `start_backup()` at `src/Backups/API/Rest.php:157` calls `$this->job_adapter->get_jobrun_url('runnow',$jobid)` at line 260 — confirmed in source. The route at lines 93-120 checks only `current_user_can('backwpup')`. The `backwpup_check` role has `backwpup_jobs_start=false`. Operational checks (temp/log folder, destination availability) are not authorization checks. Phase 3a gate's code_evidence false-negative was a method-name matching issue.
- **Highest Impact:** A `backwpup_check` user can trigger immediate backup execution, potentially causing resource exhaustion, overwriting recent backups, or abusing a misconfigured backup destination.

**PoC:**
1. Setup: An active backup job; assign `backwpup_check` role.
2. Attack: POST to `/wp-json/backwpup/v1/startbackup` with `job_id=<N>`.
3. Verify: Backup process starts (running file appears); job log records an execution triggered by the low-privilege user.

**Counter-evidence:**  
- `src/Backups/API/Rest.php:192,207,229` — temp/log folder and destination checks are operational prerequisites, not authorization gates.

**Dynamic test plan:**
1. Assign `backwpup_check` role.
2. POST `startbackup` with a valid `job_id`.
3. Observe the `running_file` at `BackWPup::get_plugin_data('running_file')`.
4. Confirm job log records the unauthorized trigger.
5. Verify `backwpup_check` user sees no 'Run Now' button in the classic dashboard.

---

### Finding ID: `agent-a3-process-bulk-actions-needs-proof`
- **Type:** Broken Access Control (CWE-862)
- **Minimum Role/Capability:** `backwpup` (e.g., `backwpup_check` role) for the route; `backwpup_backups_delete` needed to obtain dataset URLs
- **Status Transition:** UNCERTAIN → **keep**
- **Description:** `process_bulk_actions()` at `src/Backups/API/Rest.php:360` checks only `current_user_can('backwpup')` and reaches `$dest_class->file_delete()` via `delete_backup()` — confirmed in source. However, the backup listing helper at `inc/Utils/BackWPupHelpers.php:198-214` only emits `dataset-delete` URLs to users with `current_user_can('backwpup_backups_delete')`, which `backwpup_check` does not have. End-to-end exploitation requires obtaining valid `jobdest-top` and `backupfiles[]` values through a low-privilege path, which has not been demonstrated statically.
- **Highest Impact:** If valid identifiers can be obtained or derived: a `backwpup_check` user could delete backup archives from remote storage, destroying backup data.

**PoC:**
1. Setup: Backup archives on remote storage; assign `backwpup_check` role.
2. Attack: Obtain valid `jobdest-top` and `backupfiles[]` identifiers. POST to `/wp-json/backwpup/v1/process_bulk_actions` with `action=delete` and crafted `backups` array.
3. Verify: Archive deleted from remote storage.

**Counter-evidence:**  
- `inc/Utils/BackWPupHelpers.php:198` — `current_user_can('backwpup_backups_delete')` gate on dataset-delete URL emission; `backwpup_check` does not receive these URLs through normal listing.

**Dynamic test plan:**
1. Assign `backwpup_check` role.
2. Request `/wp-json/backwpup/v1/backups` — verify no `dataset-delete` URLs in response.
3. Attempt POST to `process_bulk_actions` with manually constructed or guessed backup identifiers.
4. Check whether any other REST endpoint leaks backup file identifiers to `backwpup_check` users.
5. If identifiers are obtainable: confirm deletion succeeds and the finding is exploitable end-to-end.

---

## 4. Negative Findings

**`save_site_option` route — correctly guarded:**  
`src/Jobs/API/Rest.php:337-341` registers `/save_site_option` with a custom `permission_callback` that checks `current_user_can('backwpup_jobs_edit') || current_user_can('backwpup_settings')` — not the generic `has_permission()`. Neither the `backwpup_check` nor `backwpup_helper` role has either of these capabilities (`inc/class-install.php:149,156`). Additionally, the handler at line 798 blocks writes to keys not prefixed with `backwpup` and to internal plugin keys. This route is correctly protected and is explicitly marked FP in Phase 2 output.

**Input sanitization on REST args:**  
For routes that do have authorization gaps, the argument sanitization (integer validation for `job_id`, enum constraints for `type` and `archiveformat`, `sanitize_text_field` for string inputs) is consistently applied. These controls are effective at preventing injection and type-confusion attacks within the unauthorized calls, but they do not mitigate the access control failure.

**Path traversal in `getblock`:**  
`inc/Utils/BackWPupHelpers.php:74` blocks `..` sequences and `inc/Utils/BackWPupHelpers.php:94` confines includes to the `parts/` directory. This prevents arbitrary file inclusion but does not restrict which legitimate secret-bearing partials can be loaded by a low-privilege caller.

---

## 5. Overall Assessment

BackWPup's new REST API surface (`backwpup/v1` and `backwpup/v2`) shares a single `has_permission()` function across virtually all routes. That function checks only `current_user_can('backwpup')` — the broadest plugin capability, present on the read-only `backwpup_check` role. The classic admin UI enforces fine-grained capabilities (`backwpup_jobs_edit`, `backwpup_jobs_start`, `backwpup_settings`, `backwpup_backups_delete`) for the same operations, but the REST equivalents bypass that privilege model entirely.

**Evidence supports 14 of 19 findings** as genuine access control violations. The core pattern is consistent and simple: the REST layer does not inherit the capability model of the admin UI it replaces.

**Three findings remain UNCERTAIN:**
- `agent-a2-f008` — Pro-only callback not auditable from free source.
- `agent-a3-delete-auth-cloud-bac` — Sink implementation per provider not confirmed.
- `agent-a3-process-bulk-actions-needs-proof` — Authorization gap real but attacker data acquisition path unproven statically.

**Notable finding:** `agent-a3-getblock-secret-disclosure` is the highest-severity issue in this batch. It allows any `backwpup_check` user to extract decrypted FTP, S3, Azure, Rackspace, and SugarSync credentials for any job by requesting secret-bearing admin partials through the `/getblock` endpoint. This bypasses the intended privilege split where settings and job-edit pages are gated on stronger capabilities.

**Remediation pattern:** Every affected route needs a route-specific `permission_callback` that checks the appropriate fine-grained capability: `backwpup_jobs_edit` for job create/delete/modify, `backwpup_jobs_start` for backup execution, `backwpup_settings` for plugin configuration, and `backwpup_backups_delete` for archive deletion. The `/getblock` endpoint additionally requires a hardcoded allowlist of safe partials before any file inclusion, regardless of the caller's capability.
