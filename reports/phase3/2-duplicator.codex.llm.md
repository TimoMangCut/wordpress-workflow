# Phase 3b LLM Skeptic Review - `duplicator`

## Plugin Overview

Duplicator 1.5.16 is a WordPress backup and migration plugin that packages site files and database content for download and restore workflows (`plugins/duplicator/readme.txt:1-18`).
The authoritative Phase 3a gate for this run contains no `PLAUSIBLE` or `UNCERTAIN` findings to review (`reports/phase3/duplicator-phase3.json`).

## Validation Summary

- Reviewed: 0
- Downgraded: 0
- Kept: 0
- Upgraded: 0
- Missing evidence: no Phase 3a-eligible finding remained for skeptic review.
- Dynamic test plan: none generated for a live finding because the gate exposed no reviewable items.

## Detailed Reviews

No findings were eligible for Phase 3b review.
`reports/phase3/duplicator-phase3.json` records `plausible: 0`, `uncertain: 0`, `validated_findings: []`, and `actionable_findings: []`, so there is no finding with status transition data to assess.

## Negative Findings

- `duplicator_reset_all_settings` is not an exposed destructive BAC issue in the shipped code: the live handler rejects bad nonces at `plugins/duplicator/ctrls/class.web.services.php:41-44`, enforces `DUP_Util::hasCapability('export')` at `plugins/duplicator/ctrls/class.web.services.php:45`, and only then deletes in-progress packages and resets state at `plugins/duplicator/ctrls/class.web.services.php:55-64`.
- `duplicator_download_installer` is not an arbitrary file-read primitive on current evidence: it requires a nonce at `plugins/duplicator/ctrls/class.web.services.php:85`, `export` capability at `plugins/duplicator/ctrls/class.web.services.php:91`, a valid package id and strict hash match at `plugins/duplicator/ctrls/class.web.services.php:93-102`, and reaches `fopen`/`readfile` only after those checks at `plugins/duplicator/ctrls/class.web.services.php:133-144`.
- Admin notice dismissal does not show a cross-user or global low-privilege write path: the generic dismiss handler verifies a nonce at `plugins/duplicator/src/Core/Notifications/Notice.php:297`, requires `manage_options` for global dismissals at `plugins/duplicator/src/Core/Notifications/Notice.php:303-307`, and otherwise writes only the current user's meta at `plugins/duplicator/src/Core/Notifications/Notice.php:367-374`. The notice-bar handler also writes only `get_current_user_id()` after a nonce check at `plugins/duplicator/src/Core/Notifications/NoticeBar.php:67-69`.
- The support-toolkit download path remains sensitive but not proven exploitable for low-privilege users: the AJAX service registers only an authenticated route at `plugins/duplicator/src/Ajax/ServicesTools.php:22-25`, the wrapper enforces nonce verification before serving the file at `plugins/duplicator/src/Ajax/AjaxWrapper.php:98-130`, and the nonce-bearing download URL is emitted from a Tools page that calls `DUP_Util::hasCapability('manage_options')` at `plugins/duplicator/views/tools/controller.php:12-13` before rendering the diagnostic button at `plugins/duplicator/views/tools/diagnostics/inc.data.php:102-103`.
- The unauthenticated one-click-upgrade route is still gated by a server-side one-time token flow, not a standalone public install primitive: token generation uses `AjaxWrapper::json(..., 'export')` at `plugins/duplicator/src/Ajax/ServicesEducation.php:146-153`, stores the token with a 10-minute expiry at `plugins/duplicator/src/Ajax/ServicesEducation.php:167-176`, and the upgrade path refuses missing or expired token state before decrypting the package at `plugins/duplicator/src/Ajax/ServicesEducation.php:301-320`, then deletes the token after use at `plugins/duplicator/src/Ajax/ServicesEducation.php:332-338`.

Missing evidence to reopen any of the above areas is still the same: a bundled path that discloses the required nonce or one-time token to Subscriber or unauthenticated actors, or a demonstrable route to the same sink without first passing the existing `export` or `manage_options` guard.

Dynamic test plan if a finding is reopened:
1. Create an Administrator and a Subscriber account on a clean WordPress test site with Duplicator 1.5.16 active.
2. Capture the exact nonce or one-time token from the rendered Duplicator admin UI, then replay the corresponding `admin-ajax.php?action=...` request as both roles and compare responses.
3. Verify measurable impact directly in server state, such as option changes, user-meta changes, downloaded file contents, package deletion, or plugin installation.

## Overall Assessment

Phase 3b makes no status changes because the authoritative Phase 3a gate supplied zero `PLAUSIBLE` and zero `UNCERTAIN` findings for `duplicator`.
The remaining skeptic position is unchanged: without concrete evidence of nonce disclosure, token disclosure, or capability-bypass into the guarded sinks above, the current record is insufficient to reopen any rejected path.
