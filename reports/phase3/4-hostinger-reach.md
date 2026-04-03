# Phase 3 Gate Report - `hostinger-reach`

_Generated: 2026-04-01T19:26:59.762743+00:00_

## Plugin Overview
- Plugin slug: `hostinger-reach`
- Phase 1: EPs `25`, anomalies `3`, sources `55`, sinks `695`
- Phase 2: total `1`, TP `0`, FP `0`, REVIEW `1`
- Phase 3: confirmed `0`, plausible `0`, uncertain `1`, likely_hallucination `0`

## Tool Signals
- Semgrep: `ok (25 results)`
- Psalm: `error (exit=1)`

## Confirmed Findings
None.

## Needs Dynamic Verification
### HOSTINGER-REACH-P2-REV-001
- Type: `Improper Authentication on Public Reach Token Linking Route`
- Minimum Role/Capability: `none`
- Severity: `high` | Confidence: `0.61`
- Gate Verdict: `UNCERTAIN`
- Entry point: claimed `ep_rest__token`, resolved `ep_rest__token`
- Trace: source `plugins/hostinger-reach/src/Api/Handlers/ReachApiHandler.php:214` -> sink `plugins/hostinger-reach/src/Api/ApiKeyManager.php:21`
- Description (2 sentences): Finding `HOSTINGER-REACH-P2-REV-001` flags `Improper Authentication on Public Reach Token Linking Route` at `plugins/hostinger-reach/src/Api/ApiKeyManager.php:21` via entry point `ep_rest__token`. Gate validation currently keeps it as `UNCERTAIN` (confidence `0.61`), so dynamic verification is still required.
- Highest Impact: Potential unauthorized state change or data disclosure if runtime checks are bypassed. Minimum attacker context: `none`.
- Validation issues: `code_evidence_missing_or_mismatch, insufficient_evidence_to_confirm, path_reachability_weak`
- PoC (Setup -> Activate -> Attack -> Verify):
  - Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.
  - Step 2 (Activate): Install and activate plugin `hostinger-reach`, then create/login with minimum role `none` required by this path.
  - Step 3 (Attack): In a test environment where the contents of the server-root /.api_token file are known, send POST /wp-json/hostinger-reach/v1/token with csrf_field set to that file value and token set to an attacker-controlled Reach API token. Then verify that subsequent admin-only Reach operations use the new account. Without disclosure of /.api_token, exploitation remains unproven.
  - Step 4 (Verify): Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change).

## Likely Hallucinations
None.

## Rejected Findings (Accepted FP)
None.

## Why Not Confirmed
- `HOSTINGER-REACH-P2-REV-001`: code_evidence_missing_or_mismatch, insufficient_evidence_to_confirm, path_reachability_weak

## Stored/Second-order Notes
- `HOSTINGER-REACH-P2-REV-001`: vuln_type `Improper Authentication on Public Reach Token Linking Route`, storage_key `hostinger_reach_api_key`

## Overall Assessment
Deterministic gate output is authoritative for status classification. If LLM skeptic review exists, use it as supplemental counter-evidence only.
