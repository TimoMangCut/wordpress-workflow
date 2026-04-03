# Plugin Overview

BackWPup 5.6.7 is a WordPress backup plugin that manages backup jobs, storage destinations, and backup history through admin pages plus multiple REST endpoints under the `backwpup` namespace. This Phase 3b skeptic pass reviewed only the two Phase 3a findings that remained `UNCERTAIN` and focused on line correction, counter-evidence, missing evidence, and dynamic verification.

# Validation Summary

- Reviewed: 2
- Downgraded: 0
- Kept: 2
- Upgraded: 0

# Detailed Reviews

Finding ID: `BWPUP-P2-001`
Type: `Broken Access Control`
Minimum Role/Capability: `plugin-defined read-only role backwpup_check`
Status Transition: `UNCERTAIN -> keep`
Description: The reported chain maps to real REST write routes that all accept the broad `backwpup` capability, while the shipped `backwpup_check` role explicitly lacks `backwpup_jobs_edit`, `backwpup_jobs_start`, and `backwpup_settings`. I recommend keeping the finding `UNCERTAIN` rather than upgrading it because the legacy S3 editor itself is still edit-gated and the repository still lacks runtime proof that a low-privileged user can complete the full REST chain and land a real archive in attacker-controlled S3.
Highest Impact: If the chain works end to end, a read-only BackWPup operator can rewrite bounded S3 job settings in `backwpup_jobs`, trigger a file-producing job, and copy the resulting backup archive to attacker-controlled cloud storage.
PoC: `setup -> activate BackWPup, create at least one file-producing backup job, prepare a tester-controlled S3 bucket, and assign a second user the shipped backwpup_check role; attack -> as that user, capture backwpupApi.nonce from a BackWPup admin page, send form-encoded POST requests to /wp-json/backwpup/v1/cloudsaveandtest, /wp-json/backwpup/v1/updatejob, and /wp-json/backwpup/v1/startbackup with the target job ID and attacker S3 settings; verify impact -> confirm the job log records "Backup transferred to ..." or observe the new archive appear in the attacker bucket.`
Counter-evidence + dynamic test plan:
- Counter-evidence: `inc/class-destination-s3.php:57-60` shows the legacy S3 AJAX editor aborts unless the caller has `backwpup_jobs_edit` and a valid `backwpup_ajax_nonce`, so the old UI path itself is not directly available to `backwpup_check`.
- Counter-evidence: `src/Backups/API/Rest.php:229-249` and `inc/class-destination-s3.php:741-747` show the backup start path still expects at least one destination to pass `can_run()`, which means the capability mismatch alone does not prove a successful upload.
- Counter-evidence: `src/StorageProviders/API/Rest.php:292-295` and `inc/class-destination-s3.php:741-747` mean the `"Connection successful"` response is only keyed off stored credentials for S3, not a verified bucket write.
- Missing evidence: no captured low-privilege run yet shows the same `backwpup_check` session can successfully execute the full `/cloudsaveandtest -> /updatejob -> /startbackup` chain against an existing job.
- Missing evidence: no runtime artifact yet proves the chosen job actually produces an archive and that the archive reaches attacker-controlled S3, rather than only mutating `backwpup_jobs`.
- Missing evidence: no test result yet confirms the exploit request must be form-encoded to satisfy the `$_POST` reads in `inc/class-destination-s3.php:163-243`.
- Dynamic test plan: as the `backwpup_check` user, open a BackWPup admin page, capture `backwpupApi.nonce`, and obtain a real job ID from the job-card markup exposed under the broad `backwpup` permission, for example the `data-job-id` attributes rendered in `components/job-item.php:86-92` and `components/job-item.php:150-154`.
- Dynamic test plan: send a form-encoded `POST /wp-json/backwpup/v1/cloudsaveandtest` with `X-WP-Nonce: <nonce>` and fields such as `cloud_name=s3`, `job_id=<jobid>`, `s3accesskey=<key>`, `s3secretkey=<secret>`, `s3bucket=<bucket>`, `s3region=<region>`, and `s3dir=loot/`, then verify that the target job's S3 settings changed inside site option `backwpup_jobs`.
- Dynamic test plan: send `POST /wp-json/backwpup/v1/updatejob` with `job_id=<jobid>` and `storage_destinations[]` containing the existing destinations plus `S3`, then send `POST /wp-json/backwpup/v1/startbackup` with the same job ID and the captured nonce.
- Dynamic test plan: verify measurable impact by confirming a new object appears in the attacker bucket and, if needed, by checking the BackWPup log for the transfer message emitted from `inc/class-destination-s3.php:679-685`.

Finding ID: `BWPUP-P2-002`
Type: `Broken Access Control`
Minimum Role/Capability: `plugin-defined read-only role backwpup_check`
Status Transition: `UNCERTAIN -> keep`
Description: The REST bulk-delete path is real, and the sink location should be corrected to `BackWPup_Destination_Folder::file_delete()` at `inc/class-destination-folder.php:62` because the handler only checks the broad `backwpup` capability before dispatching to the destination class. I recommend keeping the finding `UNCERTAIN` rather than upgrading it because the normal backups UI withholds a ready-made delete payload from users without `backwpup_backups_delete`, so exploitation still needs a crafted REST request or DOM-derived parameters instead of a pure point-and-click flow.
Highest Impact: If the crafted request succeeds, a read-only BackWPup operator can delete existing backup archives from configured storage and reduce site recovery availability.
PoC: `setup -> activate BackWPup, generate at least one local FOLDER backup archive, and assign a second user the shipped backwpup_check role; attack -> as that user, capture backwpupApi.nonce, harvest job/destination/file metadata from POST /wp-json/backwpup/v1/backups, and then POST /wp-json/backwpup/v1/process_bulk_actions with a crafted backups[0][dataset][data-url] query string; verify impact -> confirm the chosen archive disappears from the backups list and from the configured backup directory on disk.`
Counter-evidence + dynamic test plan:
- Counter-evidence: `inc/Utils/BackWPupHelpers.php:197-214` only attaches `dataset-delete` when the current user already has `backwpup_backups_delete`, so the new UI does not directly expose a delete URL to `backwpup_check`.
- Counter-evidence: `components/table-row-backups.php:54-60`, `assets/js/backwpup-admin.js:2072-2080`, and `src/Backups/API/Rest.php:396-406` show the stock bulk-delete flow simply replays the checkbox's `data-delete`; without delete capability that value is `null`, so the default UI path should fail with invalid backup data.
- Counter-evidence: `src/Backups/API/Rest.php:405-420` and `inc/class-destination-folder.php:69-75` constrain the sink to a registered destination and a basename-resolved real path under the configured backup directory, which refutes any arbitrary file deletion interpretation.
- Missing evidence: no captured `backwpup_check` response from `POST /wp-json/backwpup/v1/backups` yet proves the running product really leaks enough metadata to reconstruct `jobdest-top` and `backupfiles[]` after `dataset-delete` is stripped.
- Missing evidence: no side-by-side test yet shows the stock UI delete attempt fails for `backwpup_check` while a manually crafted `process_bulk_actions` request succeeds.
- Missing evidence: no runtime proof yet confirms the selected archive is actually removed from storage after the crafted REST request.
- Dynamic test plan: as the `backwpup_check` user, send `POST /wp-json/backwpup/v1/backups` with `page=1&length=10` and inspect the returned HTML for the always-generated download dataset from `inc/Utils/BackWPupHelpers.php:163-172`, especially `data-jobid`, `data-destination`, and `data-file`.
- Dynamic test plan: try the standard bulk-delete UI once and confirm it fails or returns per-item errors, documenting the counter-evidence that `dataset-delete` is missing.
- Dynamic test plan: manually send `POST /wp-json/backwpup/v1/process_bulk_actions` with `X-WP-Nonce: <nonce>` and a body like `action=delete&backups[0][dataset][data-url]=/wp-admin/admin.php?page=backwpupbackups&action=delete&jobdest-top=<jobid>_<DEST>&backupfiles[]=<filename>`; the REST handler only parses this query string at `src/Backups/API/Rest.php:401-410` and does not verify the legacy `_wpnonce` embedded in that URL.
- Dynamic test plan: verify impact by confirming the archive disappears from the backups list and from the configured backup directory on disk.

# Negative Findings

- `src/Jobs/API/Rest.php:331-340` shows the `save_site_option` REST route already uses the narrower `backwpup_jobs_edit || backwpup_settings` permission callback, so this skeptic pass did not find evidence of a generic arbitrary site-option write.
- `inc/class-destination-s3.php:57-60` confirms the legacy S3 AJAX configuration surface still enforces `backwpup_jobs_edit` plus nonce validation; the suspected weakness is the newer REST surface, not the older AJAX handler.
- `src/Backups/API/Rest.php:405-420` and `inc/class-destination-folder.php:69-75` keep the reviewed delete path scoped to registered backup destinations and basename-resolved files inside the configured backup directory, not arbitrary filesystem targets.

# Overall Assessment

The deterministic Phase 3a gate should remain authoritative, but this skeptic pass does not find enough counter-evidence to downgrade either reviewed item today. Both findings still fit `UNCERTAIN -> keep`: the code strongly supports a plugin-internal capability mismatch, yet the remaining gaps are end-to-end proof of exploit execution, especially around request shape, UI exposure, and measurable runtime impact.
