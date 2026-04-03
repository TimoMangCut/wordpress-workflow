# Phase 3 Gate Report - `backwpup`

_Generated: 2026-04-02T19:05:37.404116+00:00_

## Plugin Overview
- Plugin slug: `backwpup`
- Phase 1: EPs `60`, anomalies `7`, sources `286`, sinks `2466`
- Phase 2: total `2`, TP `2`, FP `0`, REVIEW `0`
- Phase 3: confirmed `0`, plausible `0`, uncertain `2`, likely_hallucination `0`

## Tool Signals
- Semgrep: `ok (47 results)`
- Psalm: `ok (844 results)`

## Confirmed Findings
None.

## Needs Dynamic Verification
### BWPUP-P2-001
- Type: `Broken Access Control`
- Minimum Role/Capability: `plugin-defined read-only role backwpup_check`
- Severity: `high` | Confidence: `0.60`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest___cloudsaveandtest`, resolved `ep_rest___cloudsaveandtest`
- Trace: source `src/StorageProviders/API/Rest.php:262` -> sink `inc/class-destination-s3.php:551`
- Description (2 sentences): Finding `BWPUP-P2-001` flags `Broken Access Control` at `inc/class-destination-s3.php:551` via entry point `ep_rest___cloudsaveandtest`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.60`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized read/write actions beyond intended role boundary. Minimum attacker context: `plugin-defined read-only role backwpup_check`.
- Validation issues: `code_evidence_missing_or_mismatch, insufficient_evidence_to_confirm, path_reachability_weak`
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `plugin-defined read-only role backwpup_check` required by this path.
  - Step 3 (Attack): Assign a test account the shipped `backwpup_check` role. Log in and open any BackWPup page to obtain `backwpupApi.nonce`. Use that nonce to POST attacker-controlled S3 parameters to `/wp-json/backwpup/v1/cloudsaveandtest`, then enable S3 for an existing job via `/wp-json/backwpup/v1/updatejob` or `/wp-json/backwpup/v2/storages`, and finally POST `/wp-json/backwpup/v1/startbackup` for that job. The generated archive is uploaded to the attacker-controlled S3 bucket.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

### BWPUP-P2-002
- Type: `Broken Access Control`
- Minimum Role/Capability: `plugin-defined read-only role backwpup_check`
- Severity: `medium` | Confidence: `0.60`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest_backwpup_v1__process_bulk_actions`, resolved `ep_rest_backwpup_v1__process_bulk_actions`
- Trace: source `src/Backups/API/Rest.php:360` -> sink `inc/class-destination-folder.php:75`
- Description (2 sentences): Finding `BWPUP-P2-002` flags `Broken Access Control` at `inc/class-destination-folder.php:75` via entry point `ep_rest_backwpup_v1__process_bulk_actions`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.60`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized read/write actions beyond intended role boundary. Minimum attacker context: `plugin-defined read-only role backwpup_check`.
- Validation issues: `code_evidence_missing_or_mismatch, insufficient_evidence_to_confirm, path_reachability_weak`
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `backwpup`, then create/login with minimum role `plugin-defined read-only role backwpup_check` required by this path.
  - Step 3 (Attack): Assign `backwpup_check` to a test user, log in, load a BackWPup page to obtain `backwpupApi.nonce`, then POST to `/wp-json/backwpup/v1/process_bulk_actions` with `action=delete` and a `backups[0][dataset][data-url]` value copied from a backup row. The selected local backup archive is deleted although the role lacks `backwpup_backups_delete`.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

## Likely Hallucinations
None.

## Rejected Findings (Accepted FP)
None.

## Why Not Confirmed
- `BWPUP-P2-001`: code_evidence_missing_or_mismatch, insufficient_evidence_to_confirm, path_reachability_weak
- `BWPUP-P2-002`: code_evidence_missing_or_mismatch, insufficient_evidence_to_confirm, path_reachability_weak

## Stored/Second-order Notes
- `BWPUP-P2-001`: vuln_type `Broken Access Control`, storage_key `backwpup_jobs`

## Overall Assessment
Deterministic gate output is authoritative for status classification. If LLM skeptic review exists, use it as supplemental counter-evidence only.
