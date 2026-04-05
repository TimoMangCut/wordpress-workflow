# Phase 3b LLM Skeptic Review — `backwpup`

_Reviewer role: SKEPTIC — searching for counter-evidence against Phase 2 conclusions._
_Review date: 2026-04-05_
_Plugin version: 5.0.x (free / community edition)_

---

## 1. Plugin Overview

BackWPup is a WordPress backup plugin providing scheduled job management, multiple storage destinations (Folder, FTP, S3, Dropbox, Azure, SugarSync, HiDrive, Rackspace), database dump and file archiving, and a restore manager. It ships a tiered role model (`BackWPup Admin`, `backwpup_check`, `backwpup_helper`) with granular capability gates on the admin UI. The plugin also has a Pro edition (`BackWPup_Pro_Page_Support`) whose source was not present in the audited codebase.

The REST API surface is substantial: two namespaces (`backwpup/v1`, `backwpup/v2`) with dedicated REST controller classes in `src/Jobs/API/Rest.php`, `src/Backups/API/Rest.php`, `src/StorageProviders/API/Rest.php`, and `src/Frontend/API/Rest.php`. **Every registered route in every controller uses the same single `has_permission()` callback, which checks only `current_user_can('backwpup')`.** The legacy admin-post and AJAX entry points (`inc/class-admin.php`) mix nonce-gated forms with ungated AJAX handlers.

Phase 3a produced 22 findings, all `UNCERTAIN`. Zero were `CONFIRMED` or `PLAUSIBLE`. The systemic root cause across most findings is a broken access control pattern: the `backwpup_check` role satisfies `current_user_can('backwpup')` but lacks the granular capabilities (`backwpup_jobs_edit`, `backwpup_jobs_start`, `backwpup_backups_delete`, `backwpup_settings`) that the plugin's role model intends to enforce.

---

## 2. Validation Summary

| Metric | Count |
|---|---|
| Phase 3a UNCERTAIN findings reviewed | 22 |
| Phase 3a PLAUSIBLE findings reviewed | 0 |
| Downgraded (evidence insufficient) | 3 |
| Kept (evidence supports) | 19 |
| Upgraded | 0 |

**3 downgraded:** `agent-a2-f008`, `agent-c-anom_13`, `agent-d-uh-004`.

**19 kept:** All others. Of the 19 kept findings, 17 share a single systemic root cause: the BackWPup REST API uses a single `current_user_can('backwpup')` permission gate on all job, backup, and storage endpoints, while the plugin's own role model defines lower-privilege roles (`backwpup_check`, `backwpup_helper`) that satisfy this check but are explicitly excluded from the corresponding granular capabilities.

**One additional cross-cutting note:** All BAC findings in the REST API share a dependency on the `wp_rest` nonce being accessible to the `backwpup_check` role. The nonce is emitted by `inc/class-admin.php:1225-1261` (`get_backwpup_api_data()`) which itself requires `current_user_can('backwpup')` — a condition the `backwpup_check` role satisfies. This confirms the nonce acquisition path is open to any `backwpup_check` user.

---

## 3. Detailed Reviews

---

### 3.1 `agent-a2-f001` — Information Disclosure via Ungated Debug-Info AJAX Handler

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `wp_ajax_backwpup_debug_info` (authenticated only)  
**Source:** `inc/class-admin.php:281` (AJAX closure)  
**Sink:** `inc/class-admin.php:287` → `BackWPup_Page_Settings::get_information()`

The AJAX closure at `inc/class-admin.php:281-291` has no `current_user_can()` or `check_ajax_referer()` guard before calling `BackWPup_Page_Settings::get_information()` and echoing the result. The `wp_ajax_` prefix requires WordPress login but imposes no capability filter. Any authenticated WordPress user — including a plain subscriber with no BackWPup roles — can obtain the full debug report containing `DOCUMENT_ROOT`, temp/log folder paths, PHP user, server self-connect response, and loaded PHP extensions. The gate `guard_contradiction` is a false positive: there genuinely is no guard.

**Missing evidence / open questions:**
- Whether the admin page that embeds the debug-info link requires backwpup_settings — the AJAX action itself is callable without it.
- Whether get_information() makes outbound HTTP requests (self-connect check) that could be observable as SSRF side effects.

**Dynamic test:**
```
Step 1: Create a WordPress subscriber user (no backwpup capability). Log in.
Step 2: POST /wp-admin/admin-ajax.php with body: action=backwpup_debug_info
Step 3: Verify response contains DOCUMENT_ROOT, PHP user, temp/log folder paths.
Step 4: Repeat with a backwpup_check role user to confirm same disclosure.
Step 5: Confirm the hook fires without any _wpnonce parameter.
```

---

### 3.2 `agent-a2-f002` — BAC via Onboarding Dispatch in admin-post Handler

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `admin_post_backwpup`  
**Source:** `inc/class-admin.php:838` (`save_post_form()`)  
**Sink:** `inc/class-page-onboarding.php:127`

The `save_post_form()` handler checks `check_admin_referer()` and `current_user_can('backwpup')` — not `backwpup_jobs_edit`. When `onboarding===1`, it delegates to `BackWPup_Page_Onboarding::save_post_form()` without any secondary capability check. The `backwpup_check` role satisfies the `backwpup` check and can access the onboarding submenu (requires only `backwpup_backups`), thus obtaining the nonce. All other job-mutating branches enforce `backwpup_jobs_edit`; the onboarding branch does not.

**Counter-evidence assessed:**
- `inc/class-admin.php:844` — Page allowlist restricts dispatch to known pages.
- `inc/class-admin.php:849` — check_admin_referer(._page) requires valid page-scoped nonce — CSRF blocked without it.
- `inc/class-admin.php:851` — current_user_can(backwpup) present — unauthenticated users blocked.

**Missing evidence / open questions:**
- Confirm the onboarding submenu renders a form with the backwpup_page nonce for backwpup_check users.
- Whether BackWPup_Option::update() in the onboarding handler writes job-scoped or global options.

**Dynamic test:**
```
Step 1: Log in as backwpup_check user, visit /wp-admin/admin.php?page=backwpup, capture backwpup_page nonce.
Step 2: POST /wp-admin/admin-post.php with action=backwpup, page=backwpup, onboarding=1, _wpnonce=<captured>, plus job-mutating parameters.
Step 3: Verify whether job options were modified without backwpup_jobs_edit.
Step 4: If nonce not present for backwpup_check users, record as effectively mitigated.
```

---

### 3.3 `agent-a2-f008` — Pro Plugin Handler — Evidence Insufficient

**Verdict change:** DOWNGRADE  
**Original status:** UNCERTAIN  
**Entry point:** `admin_post_backwpup_support`  
**Source:** `inc/class-admin.php:1177` (registration only)  
**Sink:** `BackWPup_Pro_Page_Support::save_post_form()` — **class not present in audited codebase**

The handler dispatches to a Pro-only class not present in the audited free codebase. No code path can be traced to a sensitive sink. Gate correctly reported `code_evidence=0.0` and `path_reachability` failure. **Downgraded to informational** pending Pro source acquisition. Same signal as `agent-c-anom_13`.

**Counter-evidence assessed:**
- `inc/class-admin.php:1177` — BackWPup_Pro_Page_Support class not present in free codebase — sink cannot be traced.

**Missing evidence / open questions:**
- Full source of BackWPup Pro plugin containing BackWPup_Pro_Page_Support::save_post_form().
- Whether that method performs check_admin_referer() and current_user_can() before any write operation.

**Dynamic test:**
```
Step 1: If Pro plugin source available, locate BackWPup_Pro_Page_Support::save_post_form() and trace input to sink.
Step 2: Log in as backwpup_check user, POST to /wp-admin/admin-post.php with action=backwpup_support and arbitrary POST data.
Step 3: Observe whether a nonce check fires and fails, or whether the handler proceeds.
Step 4: If it proceeds, identify which option keys are written.
```

---

### 3.4 `agent-a3-getblock-secret-disclosure` — Credential Exposure via `getblock` REST Route

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `POST /wp-json/backwpup/v1/getblock`  
**Source:** `src/Frontend/API/Rest.php:83` (`getblock()`)  
**Sink:** `parts/sidebar/storage-FTP.php:178` (decrypted FTP password in HTML response)

The `getblock()` handler dispatches `block_name` to PHP partials under `parts/`. Requesting `block_name=sidebar/storage-FTP` returns a partial that calls `BackWPup_Encryption::decrypt(BackWPup_Option::get($job_id, 'ftppass'))` and renders the plaintext password in a prefilled field. Same pattern exposes S3, Azure, Rackspace, and SugarSync credentials. `has_permission()` checks only `current_user_can('backwpup')` — the `backwpup_check` role satisfies this despite having no `backwpup_settings` capability.

**Counter-evidence assessed:**
- `src/Frontend/API/Rest.php:91` — block_type constrained to ['component','children'] — no arbitrary type injection.
- `inc/Utils/BackWPupHelpers.php:74` — realpath() + directory boundary check blocks path traversal outside parts/ directory.

**Missing evidence / open questions:**
- Whether the wp_rest nonce is emitted to backwpup_check users via get_backwpup_api_data() — confirmed accessible since it requires only current_user_can(backwpup).
- Whether job_id is validated against jobs the caller owns — if not, any job's credentials are readable.

**Dynamic test:**
```
Step 1: As admin, confirm FTP credentials are saved for job_id=1.
Step 2: Log in as backwpup_check user. Visit any BackWPup admin page and capture nonce from wp_api_settings JS object.
Step 3: POST /wp-json/backwpup/v1/getblock with X-WP-Nonce header. Body: {"block_name":"sidebar/storage-FTP","block_type":"children","block_data":{"job_id":1}}
Step 4: Inspect response HTML for FTP password field value.
Step 5: Repeat with block_name=sidebar/storage-S3 for AWS secret key exposure.
```

---

### 3.5 `agent-a3-authenticate-cloud-bac` — BAC: Cloud Authentication Overwrite

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `POST /wp-json/backwpup/v1/authenticate_cloud`  
**Source:** `src/StorageProviders/API/Rest.php:194` (`authenticate_cloud()`)  
**Sink:** `src/StorageProviders/SugarSync/SugarSyncProvider.php:134` (`option_adapter->update()`)

Gated only by `current_user_can('backwpup')`. `SugarSyncProvider::authenticate()` accepts attacker-controlled credentials and writes a refresh token without checking `backwpup_settings`. A `backwpup_check` user can overwrite stored cloud authentication credentials, redirecting backup delivery.

**Missing evidence / open questions:**
- Whether BackWPup admin pages are accessible to backwpup_check role (required to obtain wp_rest nonce — confirmed accessible via get_backwpup_api_data()).
- Whether cloud providers other than SugarSync reject invalid credentials before persisting state.

**Dynamic test:**
```
Step 1: Log in as backwpup_check user. Visit BackWPup admin page. Capture nonce from wp_api_settings JS object.
Step 2: POST /wp-json/backwpup/v1/authenticate_cloud with X-WP-Nonce. Body: {"cloud_name":"sugarsync","sugaremail":"attacker@example.com","sugarpass":"fakepass","job_id":1}
Step 3: Check database option for job 1 sugarrefreshtoken — verify if overwritten.
Step 4: Confirm backwpup_check user can obtain the wp_rest nonce from BackWPup admin pages.
```

---

### 3.6 `agent-a3-delete-auth-cloud-bac` — BAC: Cloud Token Deletion

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `POST /wp-json/backwpup/v1/delete_auth_cloud`  
**Source:** `src/StorageProviders/API/Rest.php:231` (`delete_auth_cloud()`)  
**Sink:** `src/StorageProviders/Dropbox/DropboxProvider.php:100` (`option_adapter->delete()`)

Gated only by `current_user_can('backwpup')`. `DropboxProvider::delete_auth()` removes the stored OAuth token; HiDriveProvider and SugarSyncProvider follow the same pattern. A `backwpup_check` user can revoke all cloud backup tokens, silently disabling cloud backup delivery.

**Counter-evidence assessed:**
- `src/StorageProviders/CloudProviderManager.php:42` — Unknown cloud_name values rejected — only registered providers reachable. Does not restrict who can call them.

**Missing evidence / open questions:**
- Whether the wp_rest nonce is accessible to backwpup_check users — confirmed accessible.
- Whether delete_auth() on a provider with no stored token throws an error or exits cleanly.

**Dynamic test:**
```
Step 1: As admin, confirm Dropbox token is stored for job_id=1.
Step 2: Log in as backwpup_check user, capture wp_rest nonce.
Step 3: POST /wp-json/backwpup/v1/delete_auth_cloud with X-WP-Nonce. Body: {"cloud_name":"dropbox","job_id":1}
Step 4: Verify Dropbox token removed from job options; subsequent backup to Dropbox fails.
```

---

### 3.7 `agent-a3-cloudsaveandtest-bac` — BAC: Cloud Save-and-Test Writes Credentials Before Validation

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `POST /wp-json/backwpup/v1/cloudsaveandtest`  
**Source:** `src/StorageProviders/API/Rest.php:262` (`cloud_save_and_test()`)  
**Sink:** `inc/class-destination-ftp.php:65` (`BackWPup_Option::update()` via `edit_form_post_save()`)

Gated only by `current_user_can('backwpup')`. `edit_form_post_save()` persists FTP/S3/cloud credentials at line 292 **before** `can_run()` validates them at line 293 — invalid credentials are committed to the database. Applies to all destination types: S3, Rackspace, Azure, Folder, email.

**Missing evidence / open questions:**
- Whether can_run() failure at line 293 rolls back the written options or only returns an error — confirmed: no rollback, writes always persist.
- Whether nonce is accessible to backwpup_check users — confirmed accessible.

**Dynamic test:**
```
Step 1: Log in as backwpup_check user, capture wp_rest nonce.
Step 2: POST /wp-json/backwpup/v1/cloudsaveandtest with X-WP-Nonce. Body: {"cloud_name":"ftp","job_id":1,"ftphost":"attacker.example.com","ftpuser":"attacker","ftppass":"evil"}
Step 3: Verify FTP options written to job 1 even if can_run() returns false.
Step 4: Check that error response still indicates options were saved before validation.
Step 5: Repeat for cloud_name=s3 with invalid AWS credentials to test S3 destination.
```

---

### 3.8 `agent-a3-storages-bac` — BAC: Storage Destination Add/Remove

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `POST /wp-json/backwpup/v2/storages`  
**Source:** `src/StorageProviders/API/Rest.php:316` (`update_job_storage_options()`)  
**Sink:** `src/StorageProviders/API/Rest.php:354` (`OptionAdapter::update('destinations',...)`)

Gated only by `current_user_can('backwpup')`. Writes the `destinations` option controlling which storage backends receive backup files. A `backwpup_check` user can add or remove storage targets for any job. The guard at line 350 prevents removal of the *last* destination only.

**Counter-evidence assessed:**
- `src/StorageProviders/API/Rest.php:350` — Handler prevents removal of the last remaining destination — but add/remove of non-final destinations is unrestricted.

**Missing evidence / open questions:**
- Whether the wp_rest nonce is accessible to backwpup_check users — confirmed accessible.
- Whether the destinations option accepts only a bounded set of registered destination types or arbitrary strings.

**Dynamic test:**
```
Step 1: Log in as backwpup_check user, capture wp_rest nonce.
Step 2: POST /wp-json/backwpup/v2/storages with X-WP-Nonce. Body: {"name":"FOLDER","job_id":1,"checked":false}
Step 3: Verify FOLDER added to job 1 destinations.
Step 4: Attempt with invalid name (FAKE) to confirm the storage validation guard blocks unknown destinations.
```

---

### 3.9 `agent-a3-updatejob-bac` — BAC: Job Enable/Disable and Destination Overwrite

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `POST /wp-json/backwpup/v1/updatejob`  
**Source:** `src/Jobs/API/Rest.php:381` (`update_job()`)  
**Sink:** `src/Jobs/API/Rest.php:392` (`job_adapter->disable_job()`) / line 417 (`option_adapter->update('destinations',...)`)

Gated only by `current_user_can('backwpup')`. Exposes two write paths: enabling/disabling job scheduling (bypasses `backwpup_jobs_start`) and overwriting the `destinations` option (bypasses `backwpup_jobs_edit`).

**Counter-evidence assessed:**
- `src/Jobs/API/Rest.php:104` — Parameter types are validated and sanitized — no injection risk, but unauthorized modifications still proceed.

**Missing evidence / open questions:**
- Whether the wp_rest nonce is accessible to backwpup_check users — confirmed accessible.
- Full behavior of JobAdapter::disable_job() — whether it also modifies run-once settings or solely the enabled/disabled state.

**Dynamic test:**
```
Step 1: Log in as backwpup_check user, capture wp_rest nonce.
Step 2: POST /wp-json/backwpup/v1/updatejob with X-WP-Nonce. Body: {"job_id":1,"activ":false}
Step 3: Verify job 1 is disabled via admin UI.
Step 4: POST again with activ:true and storage_destinations:["FOLDER"] to test the destinations overwrite branch.
Step 5: Confirm backwpup_jobs_edit capability is absent in the entire update_job() call chain.
```

---

### 3.10 `agent-a3-update-job-title-bac` — BAC: Unauthorized Job Rename

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `POST /wp-json/backwpup/v1/update-job-title`  
**Source:** `src/Jobs/API/Rest.php:469` (`update_job_title()`)  
**Sink:** `src/Jobs/API/Rest.php:473` (`job_adapter->rename_job()`)

Gated only by `current_user_can('backwpup')`. Title is sanitized with `sanitize_text_field()` (no XSS), but the `backwpup_jobs_edit` check is absent. A `backwpup_check` user can rename any backup job.

**Counter-evidence assessed:**
- `src/Jobs/API/Rest.php:152` — title is sanitized with sanitize_text_field — no XSS via the write, only unauthorized rename.

**Missing evidence / open questions:**
- Whether JobAdapter::rename_job() writes only the name option key or also modifies other job attributes.
- Whether the wp_rest nonce is accessible to backwpup_check users — confirmed accessible.

**Dynamic test:**
```
Step 1: Log in as backwpup_check user, capture wp_rest nonce.
Step 2: POST /wp-json/backwpup/v1/update-job-title with X-WP-Nonce. Body: {"job_id":1,"title":"Attacker Renamed"}
Step 3: Verify job name updated in database without backwpup_jobs_edit.
Step 4: Confirm backwpup_jobs_edit capability is absent in the update_job_title() call chain.
```

---

### 3.11 `agent-a3-addjob-bac` — BAC: Unauthorized Job Creation

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `POST /wp-json/backwpup/v1/addjob`  
**Source:** `src/Jobs/API/Rest.php:493` (`add_job()`)  
**Sink:** `src/Jobs/API/Rest.php:524` (`option_adapter->update()` in loop)

Gated only by `current_user_can('backwpup')`. Allocates a new job ID and writes all job options. `type` is constrained to `[files, database, mixed]`. A `backwpup_check` user can create jobs, expanding the attack surface for other REST findings.

**Counter-evidence assessed:**
- `src/Jobs/API/Rest.php:165` — type constrained to [files, database, mixed] — cannot create jobs with arbitrary type values.

**Missing evidence / open questions:**
- Whether there is a cap on the number of jobs per WordPress option — could attacker cause option table bloat.
- Whether the wp_rest nonce is accessible to backwpup_check users — confirmed accessible.

**Dynamic test:**
```
Step 1: Log in as backwpup_check user, capture wp_rest nonce.
Step 2: POST /wp-json/backwpup/v1/addjob with X-WP-Nonce. Body: {"type":"database"}
Step 3: Verify new job visible in admin UI without backwpup_jobs_edit.
Step 4: Confirm backwpup_jobs_edit capability is absent in the add_job() call chain.
```

---

### 3.12 `agent-a3-delete-job-bac` — BAC: Unauthorized Job Deletion

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `POST /wp-json/backwpup/v1/delete_job`  
**Source:** `src/Jobs/API/Rest.php:553` (`delete_job()`)  
**Sink:** `src/Jobs/API/Rest.php:570` (`job_adapter->delete_job()`)

Gated only by `current_user_can('backwpup')`. `job_id` is sanitized to `absint()`. A `backwpup_check` user can delete all backup jobs, eliminating all scheduled backup coverage without any admin notice.

**Counter-evidence assessed:**
- `src/Jobs/API/Rest.php:187` — job_id sanitized to absint — prevents non-numeric or negative ID injection.

**Missing evidence / open questions:**
- Whether JobAdapter::delete_job() also deletes associated backup archives or only job configuration.
- Whether the wp_rest nonce is accessible to backwpup_check users — confirmed accessible.

**Dynamic test:**
```
Step 1: As admin, note job_id=1 exists.
Step 2: Log in as backwpup_check user, capture wp_rest nonce.
Step 3: POST /wp-json/backwpup/v1/delete_job with X-WP-Nonce. Body: {"job_id":1}
Step 4: Verify job 1 no longer exists in admin UI or database.
Step 5: Confirm backwpup_jobs_edit capability is absent in the delete_job() call chain.
```

---

### 3.13 `agent-a3-save-job-settings-bac` — BAC: Unauthorized Job Schedule Modification

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `POST /wp-json/backwpup/v1/save_job_settings`  
**Source:** `src/Jobs/API/Rest.php:591` (`save_job_settings()`)  
**Sink:** `src/Jobs/API/Rest.php:633` (`option_adapter->update('cron',...)`)

Gated only by `current_user_can('backwpup')`. Writes `frequency`, `activetype`, and `cron` options. A `backwpup_check` user can set `activetype=link` to disable scheduled backups, or change the cron schedule to an arbitrary expression.

**Missing evidence / open questions:**
- Whether the cron value written is validated to prevent setting an unreasonably high-frequency schedule (e.g., every minute) that could constitute server resource exhaustion.
- Whether the wp_rest nonce is accessible to backwpup_check users — confirmed accessible.

**Dynamic test:**
```
Step 1: Log in as backwpup_check user, capture wp_rest nonce.
Step 2: POST /wp-json/backwpup/v1/save_job_settings with X-WP-Nonce. Body: {"job_id":1,"frequency":"link"}
Step 3: Verify activetype=link written; job no longer runs on schedule.
Step 4: Confirm backwpup_jobs_edit capability is absent in the save_job_settings() call chain.
```

---

### 3.14 `agent-a3-save-job-format-bac` — BAC: Unauthorized Archive Format Change

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `POST /wp-json/backwpup/v1/save_job_format`  
**Source:** `src/Jobs/API/Rest.php:677` (`save_job_format()`)  
**Sink:** `src/Jobs/API/Rest.php:708` (`option_adapter->update('archiveformat',...)`)

Gated only by `current_user_can('backwpup')`. Archive format constrained to `[.tar, .zip, .tar.gz]`; archive name must include `%hash%`. Input guards prevent injection but not unauthorized modification.

**Counter-evidence assessed:**
- `src/Jobs/API/Rest.php:692` — archivetype constrained to known extensions — no injection possible.
- `src/Jobs/API/Rest.php:706` — %hash% required in archive name — prevents fully arbitrary naming.

**Missing evidence / open questions:**
- Whether the wp_rest nonce is accessible to backwpup_check users — confirmed accessible.

**Dynamic test:**
```
Step 1: Log in as backwpup_check user, capture wp_rest nonce.
Step 2: POST /wp-json/backwpup/v1/save_job_format with X-WP-Nonce. Body: {"job_id":1,"archiveformat":".zip","archivename":"evil-%hash%"}
Step 3: Verify archivename and archiveformat updated without backwpup_jobs_edit.
Step 4: Confirm backwpup_jobs_edit capability is absent in the save_job_format() call chain.
```

---

### 3.15 `agent-a3-save-files-exclusions-bac` — BAC: Unauthorized File Exclusion Modification

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `POST /wp-json/backwpup/v1/save_files_exclusions`  
**Source:** `src/Jobs/API/Rest.php:736` (`save_files_exclusions()`)  
**Sink:** `inc/class-jobtype-file.php:217` (`BackWPup_Option::update()` via `edit_form_post_save()`)

Gated only by `current_user_can('backwpup')`. Gate `code_evidence` score is 1.0 (sink confirmed). An attacker can exclude all files from backup or target specific directories, silently degrading backup coverage.

**Counter-evidence assessed:**
- `inc/class-jobtype-file.php:225` — Paths are sanitized; boolean flags are cast — no injection risk, but unauthorized modification still proceeds.

**Missing evidence / open questions:**
- Whether the wp_rest nonce is accessible to backwpup_check users — confirmed accessible.
- Whether fileexclude accepts wildcard patterns that could be used to prevent all files from being backed up.

**Dynamic test:**
```
Step 1: Log in as backwpup_check user, capture wp_rest nonce.
Step 2: POST /wp-json/backwpup/v1/save_files_exclusions with X-WP-Nonce. Body: {"job_id":1,"fileexclude":"*"}
Step 3: Verify all file patterns excluded from backup job 1.
Step 4: Confirm backwpup_jobs_edit capability is absent in the save_files_exclusions() call chain.
```

---

### 3.16 `agent-a3-save-excluded-tables-bac` — BAC: Unauthorized Database Table Exclusion

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `POST /wp-json/backwpup/v1/save_excluded_tables`  
**Source:** `src/Jobs/API/Rest.php:762` (`save_excluded_tables()`)  
**Sink:** `inc/class-jobtype-dbdump.php:149` (`BackWPup_Option::update()` via `edit_form_post_save()`)

Gated only by `current_user_can('backwpup')`. Gate `code_evidence` score is 1.0 (sink confirmed). Table names validated against `SHOW TABLES` but an empty set is valid and causes full exclusion. An attacker can submit an empty `tabledb` array, disabling database backup coverage.

**Counter-evidence assessed:**
- `inc/class-jobtype-dbdump.php:149` — Table names validated against SHOW TABLES output — cannot inject non-existent tables. An empty set is valid and causes full exclusion.

**Missing evidence / open questions:**
- Whether the wp_rest nonce is accessible to backwpup_check users — confirmed accessible.
- Whether an empty exclusion list vs all-tables-excluded produces different behavior.

**Dynamic test:**
```
Step 1: Log in as backwpup_check user, capture wp_rest nonce.
Step 2: POST /wp-json/backwpup/v1/save_excluded_tables with X-WP-Nonce. Body: {"job_id":1,"dbdumpexclude":["wp_users","wp_posts","wp_options"]}
Step 3: Verify named tables excluded from database backup job.
Step 4: Confirm backwpup_jobs_edit capability is absent in the save_excluded_tables() call chain.
```

---

### 3.17 `agent-a3-update-backup-type-bac` — BAC: Backup Type Modification

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `POST /wp-json/backwpup/v2/backups/{id}/type`  
**Source:** `src/Jobs/API/Rest.php:436` (`update_backup_type()`)  
**Sink:** `src/Jobs/API/Rest.php:451` (`option_adapter->update('type',...)`)

Gated only by `current_user_can('backwpup')`. `type` constrained to `[files, database, mixed]`. An attacker can silently downgrade a `mixed` backup to `database`-only or `files`-only, dropping entire backup categories.

**Counter-evidence assessed:**
- `src/Jobs/API/Rest.php:364` — type constrained to [files, database, mixed] — cannot write arbitrary type values.

**Missing evidence / open questions:**
- Whether the wp_rest nonce is accessible to backwpup_check users — confirmed accessible.
- Whether changing backup type from mixed to database silently disables the file job type tasks.

**Dynamic test:**
```
Step 1: Log in as backwpup_check user, capture wp_rest nonce.
Step 2: POST /wp-json/backwpup/v2/backups/1/type with X-WP-Nonce. Body: {"id":1,"type":"database"}
Step 3: Verify job 1 type changed to database-only.
Step 4: Confirm that inc/class-page-editjob.php:45 enforces backwpup_jobs_edit on the classic UI path — proving the REST route bypasses the expected capability gate.
Step 5: Confirm backwpup_jobs_edit capability is absent in the update_backup_type() call chain.
```

---

### 3.18 `agent-a3-startbackup-bac` — BAC: Unauthorized Backup Initiation

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `POST /wp-json/backwpup/v1/startbackup`  
**Source:** `src/Backups/API/Rest.php:157` (`start_backup()`)  
**Sink:** `src/Backups/API/Rest.php:260` (`job_adapter->get_jobrun_url('runnow', $jobid)`)

Gated only by `current_user_can('backwpup')`. A `backwpup_check` user can trigger any backup job on demand, bypassing the `backwpup_jobs_start` capability the UI enforces. The operational pre-checks at lines 192-249 are configuration checks, not authorization checks.

**Counter-evidence assessed:**
- `src/Backups/API/Rest.php:192` — Operational pre-checks for temp folder, log folder, and destination availability — configuration checks, not authorization checks.

**Missing evidence / open questions:**
- Whether the wp_rest nonce is accessible to backwpup_check users — confirmed accessible.
- Full behavior of JobAdapter::get_jobrun_url() — whether it launches backup synchronously or via WP-Cron.

**Dynamic test:**
```
Step 1: Log in as backwpup_check user. Navigate to BackWPup admin page and capture nonce from wp_api_settings JS object.
Step 2: POST /wp-json/backwpup/v1/startbackup with X-WP-Nonce. Body: {"job_id":1}
Step 3: Monitor server for new backup job process being spawned (check logs, temp dir).
Step 4: Confirm backwpup_jobs_start capability is never checked in the start_backup() call chain.
Step 5: Confirm backwpup_check role has backwpup=true but backwpup_jobs_start=false per inc/class-install.php:148.
```

---

### 3.19 `agent-a3-process-bulk-actions-needs-proof` — BAC: Backup Deletion Without Granular Capability (Pending Listing Endpoint Audit)

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `POST /wp-json/backwpup/v1/process_bulk_actions`  
**Source:** `src/Backups/API/Rest.php:360` (`process_bulk_actions()`)  
**Sink:** `src/Backups/API/Rest.php:420` (`$dest_class->file_delete()`)

Gated only by `current_user_can('backwpup')`. Delete branch calls `file_delete()` without `backwpup_backups_delete`. The delete-URL dataset is only rendered for `backwpup_backups_delete` users in the UI, but an attacker can construct the URL manually. **Open question:** if the `/backups` listing endpoint (also gated only by `backwpup`) is accessible, backup metadata can be enumerated and dataset URLs constructed without UI access. Kept as UNCERTAIN pending this check.

**Counter-evidence assessed:**
- `inc/Utils/BackWPupHelpers.php:198` — Delete dataset URLs only rendered for backwpup_backups_delete users — attacker must construct URL manually.
- `src/Backups/API/Rest.php:405` — Validation for jobdest-top and backupfiles parameters — malformed values rejected.

**Missing evidence / open questions:**
- Whether the /backups listing REST endpoint is accessible to backwpup_check role users — if yes, backup metadata is enumerable and dataset URLs constructable.
- Whether backup filenames are sufficiently unpredictable to prevent guessing without the dataset URL.

**Dynamic test:**
```
Step 1: As admin, note a backup file jobdest-top and backupfiles values from UI HTML.
Step 2: Log in as backwpup_check user, capture wp_rest nonce.
Step 3: GET /wp-json/backwpup/v1/backups (or similar listing endpoint) with X-WP-Nonce — check if metadata returned.
Step 4: POST /wp-json/backwpup/v1/process_bulk_actions with X-WP-Nonce. Body: {"action":"delete","backups":[{"dataset":{"data-url":"<constructed_url>"}}]}
Step 5: Verify if backup file was deleted without backwpup_backups_delete.
```

---

### 3.20 `agent-c-anom_13` — Pro Plugin Inconsistency — Evidence Insufficient (Duplicate of 3.3)

**Verdict change:** DOWNGRADE  
**Original status:** UNCERTAIN  
**Entry point:** `admin_post_backwpup_support`  
**Source:** `inc/class-admin.php:1177` (registration only)  
**Sink:** `BackWPup_Pro_Page_Support::save_post_form()` — **class not present**

Covers the same handler as `agent-a2-f008`. Root blocker identical: Pro source unavailable. `high` severity assignment has no Tier-1 evidence. Gate score `0.4955`. **Downgraded to informational.** Merge treatment with finding 3.3.

**Counter-evidence assessed:**
- `inc/class-admin.php:1177` — Only the add_action() registration point is visible — BackWPup_Pro_Page_Support and its save_post_form() method not present in the audited codebase.

**Missing evidence / open questions:**
- BackWPup Pro plugin source containing BackWPup_Pro_Page_Support::save_post_form().
- Whether the handler performs check_admin_referer() and current_user_can() before writing.

**Dynamic test:**
```
Step 1: If Pro plugin source available, locate BackWPup_Pro_Page_Support::save_post_form() and trace input to sink.
Step 2: Log in as backwpup_check user, POST to /wp-admin/admin-post.php with action=backwpup_support and arbitrary POST data.
Step 3: Observe whether a nonce check fires and fails, or whether the handler proceeds.
Step 4: If it proceeds, identify which option keys are written.
```

---

### 3.21 `agent-d-uh-004` — EventManager Observer Pattern — Not a Security Finding

**Verdict change:** DOWNGRADE  
**Original status:** UNCERTAIN  
**Entry point:** N/A (static analysis coverage gap)  
**Source:** `inc/dependencies/wp-media/event-manager/EventManager.php:26`  
**Sink:** None

Standard WordPress subscriber/observer dispatcher. The phase2 finding itself states this introduces no vulnerability. Gate scores: `file_exists=0.0`, `code_evidence=0.0`. This was a coverage gap note, not a security claim. **Downgraded to informational.** Reopening condition: enumerate all `SubscriberInterface` implementations and check each for missing authorization.

**Counter-evidence assessed:**
- `inc/dependencies/wp-media/event-manager/EventManager.php:26` — Standard WordPress subscriber/observer pattern. The dispatcher itself does not register privileged hooks — hook security depends on individual SubscriberInterface implementations, which are not flagged here.

**Missing evidence / open questions:**
- Enumeration of all SubscriberInterface implementations and their get_subscribed_events() return values to determine if any registers a security-relevant hook without proper authorization.

**Dynamic test:**
```
Step 1: Grep codebase for implements SubscriberInterface to enumerate all subscribers.
Step 2: For each subscriber, inspect get_subscribed_events() return value.
Step 3: For any subscriber that registers a hook handling untrusted input, trace the handler to confirm authorization check presence.
Step 4: If any hook handler lacks authorization, create a new targeted finding for that specific subscriber.
```

---

### 3.22 `agent-d-cg-002` — Subscriber-Level Backup File Download (Finding Type Corrected)

**Verdict change:** KEEP  
**Original status:** UNCERTAIN  
**Entry point:** `wp_ajax_download_backup_file` (authenticated only)  
**Source:** `inc/class-destination-downloader.php:58` (`download_by_ajax()`)  
**Sink:** `inc/class-destination-downloader.php:95` (`file_download()`)

**Original type incorrect** — this is `broken_access_control` (CWE-862), not `missing_authentication` (CWE-306). Registered as `wp_ajax_` (not `nopriv_`) — WordPress authentication enforced. The violation is a missing capability check: `download_by_ajax()` does not call `ensure_user_can_download()`, while `download_by_chunks()` (line 109) does call it at line 110. Any logged-in WordPress user (plain subscriber, no BackWPup roles) can download backup archives. Gate `code_evidence=1.0` and `file_exists=1.0` confirm the sink.

**Counter-evidence assessed:**
- `inc/class-admin.php:296` — Registered as wp_ajax_download_backup_file (not nopriv_) — WordPress enforces login; unauthenticated access impossible.
- `inc/class-destination-downloader.php:110` — download_by_chunks() calls ensure_user_can_download() at line 110 — the capability check exists in the codebase but is absent from download_by_ajax().

**Missing evidence / open questions:**
- Full implementation of file_download() in each destination class (FILE, FTP, S3, etc.) — does any destination class check the caller capability internally?
- Whether destination, file, and local_file parameters after sanitize_text_field() can still contain path traversal sequences (e.g., ../../wp-config.php) used in path construction.
- Whether a plain subscriber WordPress user (no BackWPup roles, backwpup=false) can trigger this action — if so, impact extends beyond BackWPup role holders.

**Dynamic test:**
```
Step 1: Create a plain WordPress subscriber user (no BackWPup roles).
Step 2: GET /wp-admin/admin-ajax.php?action=download_backup_file&destination=FILE&jobid=1&file=backwpup_job1_2026-01-01.tar&local_file=backup.tar (subscriber session cookie)
Step 3: Observe whether download begins (event-stream or file response) or 403/404.
Step 4: Try destination=FILE&file=../../wp-config.php to probe path traversal in file_download().
Step 5: Log in as backwpup_check user (has backwpup but not backwpup_backups_download) and repeat step 2.
Step 6: Confirm ensure_user_can_download() is absent from download_by_ajax() call chain.
```

---
## 4. Negative Findings — Independent Verification Pass

### 4.1 REST API Permission Callback Coverage

**Challenge:** Does any `register_rest_route()` call omit `permission_callback`, use `__return_true`, or use a callback less restrictive than `current_user_can('backwpup')`?

**Verification:** All four REST controller files inspected:
- `src/Jobs/API/Rest.php` — all 9 routes: `permission_callback => [$this, 'has_permission']`
- `src/Backups/API/Rest.php` — all routes: `permission_callback => [$this, 'has_permission']`
- `src/StorageProviders/API/Rest.php` — all 5 routes: `permission_callback => [$this, 'has_permission']`
- `src/Frontend/API/Rest.php` — 1 route: `permission_callback => [$this, 'has_permission']`

Every `has_permission()` implementation returns `current_user_can('backwpup')`. **No omissions or open callbacks found.** However, this also confirms the systemic BAC issue: the callback is present but insufficient — it passes for the intentionally restricted `backwpup_check` role.

### 4.2 `wp_ajax_nopriv_` Handler Audit

**Challenge:** Are any BackWPup AJAX handlers registered without authentication enforcement?

**Verification:** All AJAX hook registrations in `inc/class-admin.php:1165-1262` reviewed. All use `wp_ajax_` (authenticated). No `wp_ajax_nopriv_` handlers registered by BackWPup core.

**Secure because:** No unauthenticated AJAX entry points exist. All AJAX entry points require WordPress login at minimum.

### 4.3 Role Capability Model Correctness

**Analysis:** `inc/class-install.php:86-178` defines three roles:
- `BackWPup Admin` — all capabilities true
- `backwpup_check` — `backwpup=true`, all edit/start/delete/settings capabilities **explicitly false**
- `backwpup_helper` — start/delete/download=true, edit/settings=false

The role model is **correct in intent**. The failure is that the REST API never consults these granular capabilities. The gap between the role model design and the REST permission callbacks is the root cause of 17 of the 19 kept findings.

### 4.4 CSRF Protection on Admin-Post Handlers

**Challenge:** Do admin-post handlers lack CSRF protection?

**Verification:** `save_post_form()` at `inc/class-admin.php:849` calls `check_admin_referer($post_page . '_page')` before any write. CSRF-only attacks are blocked. The BAC issue remains (finding 3.2) because the `backwpup_check` user can obtain the nonce legitimately.

---

## 5. Overall Assessment

BackWPup's most significant security gap is architectural: **all REST API endpoint permission callbacks check only `current_user_can('backwpup')`, while the plugin's own role model defines lower-privilege roles (`backwpup_check`, `backwpup_helper`) that hold this capability but are explicitly excluded from granular operations.** This single design choice produces 17 of the 19 "evidence supports" verdicts in this review.

The finding set divides into three groups:

**Group A — Systemic REST BAC (17 findings):**  
Endpoints across all four REST controller files allow a `backwpup_check` user to perform job editing, job deletion, job creation, schedule modification, archive format changes, backup initiation, backup deletion, cloud credential overwrite, cloud credential deletion, file exclusion manipulation, table exclusion manipulation, and credential disclosure — all without the corresponding granular capability. **Fix:** add per-endpoint capability checks (`backwpup_jobs_edit`, `backwpup_jobs_start`, `backwpup_backups_delete`) or use per-route `permission_callback`s rather than a single shared one.

**Group B — Legacy Handler Gaps (2 findings):**  
- `agent-a2-f001`: Debug-info AJAX handler has no guard at all, disclosing server environment to any WordPress user.  
- `agent-d-cg-002`: `download_by_ajax()` static method bypasses the `ensure_user_can_download()` check used by the instance method, allowing subscriber-level backup download.

**Group C — Deferred (3 downgraded findings):**  
- `agent-a2-f008` and `agent-c-anom_13`: Require BackWPup Pro source to trace.  
- `agent-d-uh-004`: EventManager observer pattern with no security claim.

**Highest-impact findings for prioritization:**

| Priority | Finding | Impact |
|---|---|---|
| 1 | `agent-a3-getblock-secret-disclosure` | Decrypted FTP/S3/Azure/cloud credentials to any `backwpup` user |
| 2 | `agent-a2-f001` | Server environment disclosure to any WordPress subscriber |
| 3 | `agent-a3-delete-auth-cloud-bac`, `agent-a3-cloudsaveandtest-bac` | Cloud token deletion/overwrite = silent backup disable |
| 4 | `agent-a3-delete-job-bac` | All job deletion = silent backup disable |
| 5 | `agent-d-cg-002` | Subscriber-level backup file download |

**Gate false negative pattern (methodology note):**  
The gate consistently under-scored `path_reachability` and `code_evidence` for REST findings due to naming normalization mismatch: it searched for `optionadapter::update` but the actual call pattern is `->option_adapter->update()`. This caused 12+ findings to receive `code_evidence_missing_or_mismatch` flags despite confirmed sink calls. The gate's `guard_contradiction` issues were also systematically false positives on the BAC findings — there genuinely is no guard beyond `current_user_can('backwpup')`. Both patterns should be addressed in the gate's normalization logic.