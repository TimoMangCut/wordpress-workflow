# Phase 3b LLM Skeptic Review — `duplicator`

_Reviewer: claude-llm-skeptic | Plugin version: 1.5.16 | Review date: 2026-04-02_

---

## 1. Plugin Overview

**Duplicator** (1.5.16) is a site-migration and backup plugin with 632 analyzed PHP
files and 104 784 lines of code. Its attack surface consists of 28 registered entry
points (primarily `wp_ajax_*` AJAX hooks), 9 Phase 1 anomalies, 181 taint sources,
and 4 919 sink calls. The plugin exposes file-creation, file-read/stream, package
build/delete/download, plugin-installer, and option-write sinks — all high-value
targets if access controls were absent.

The plugin maps a custom `export` capability to `current_user_can()` and enforces it
through `DUP_Util::hasCapability()`, which hard-fails on denial. The sensitive
one-click-upgrade path uses an additional export-gated one-time token handshake with a
10-minute TTL and single-use deletion.

---

## 2. Validation Summary

| Metric | Count |
|---|---|
| Phase 3a PLAUSIBLE findings reviewed | 0 |
| Phase 3a UNCERTAIN findings reviewed | 0 |
| Findings downgraded | 0 |
| Findings kept | 0 |
| Findings upgraded | 0 |

**No findings were in scope for LLM skeptic review.** The Phase 3a deterministic gate
returned `plausible=0` and `uncertain=0`. Phase 2 produced zero true positives after
exhaustive source-level validation of all 28 entry points and all 9 anomalies.

Per the task protocol, this reviewer is constrained to PLAUSIBLE and UNCERTAIN
findings only. Because none exist, the Detailed Reviews section is empty and the
review effort is redirected to verifying Phase 2 negative-finding coverage.

---

## 3. Detailed Reviews

_No findings to review. Phase 3a produced no PLAUSIBLE or UNCERTAIN entries._

---

## 4. Negative Findings — Independent Spot-Check

This reviewer independently verified a representative cross-section of the Phase 2
negative finding set by reading the live source. The following areas were confirmed
secure.

---

### 4.1 `addQuickFilters` / `getActivePackageStatus` (ctrls/ctrl.package.php)

Both AJAX callbacks begin with `check_ajax_referer(...)` (lines 349, 399) and then
call `DUP_Util::hasCapability('export', DUP_Util::SECURE_ISSUE_THROW)` (lines 356,
402) before touching any package data or archive-filter sink. No lower-privilege path
to these sinks exists in the shipped code.

**Secure because:** nonce + export capability enforced before any state change.

---

### 4.2 `SaveViewState` — arbitrary key-value write to `duplicator_ui_view_state`
(ctrls/ctrl.ui.php:45-118 → classes/ui/class.ui.viewstate.php)

This handler accepts attacker-supplied `key` and `value` fields and ultimately calls
`update_option('duplicator_ui_view_state', $view_state)` — an option write whose
key is bounded to the `duplicator_ui_view_state` array but whose inner keys and
values are caller-controlled. The sink looks superficially like an Arbitrary Option
Update primitive.

**Counter-evidence:**
- Line 48: `check_ajax_referer('DUP_CTRL_UI_SaveViewState', 'nonce')` — nonce is
  verified and fails closed.
- Line 49: `DUP_Util::hasCapability('export')` — requires administrator-equivalent
  `export` capability; fails closed via the default `SECURE_ISSUE_DIE` mode.
- The `update_option()` target is fixed (`duplicator_ui_view_state`) and is a
  plugin-internal UI-state key with no security-relevant behavior. An attacker who
  already holds `export` capability is by definition an administrator and is already
  trusted to modify plugin state.

**Secure because:** nonce + export capability gate. The option key is fixed; the
option value is a scoped plugin-internal array with no security impact.

**Assumption to watch:** If a future code path reads `duplicator_ui_view_state`
sub-keys and passes them unsanitized into a sensitive sink (e.g., `eval`, `include`,
`wp_redirect`), re-review `SaveViewState` for second-order injection.

---

### 4.3 `duplicator_package_scan` / `duplicator_package_build` / `duplicator_package_delete`
(ctrls/ctrl.package.php:39-269)

All three functions are gated: nonce verified first (`check_ajax_referer`), then
`DUP_Util::hasCapability('export', ...)`. The delete path additionally validates each
`package_id` through `FILTER_VALIDATE_INT` and resolves to an object via
`DUP_Package::getByID()` before calling `$package->delete()`.

**Secure because:** nonce + export capability enforced; package-id input is
integer-validated and must resolve to a known package record.

---

### 4.4 Support-toolkit download (src/Ajax/ServicesTools.php)

As documented in Phase 2 NEG-009, the AJAX wrapper verifies only the nonce and
performs no explicit `current_user_can()` check. The sink (`SupportToolkit::getToolkit()`)
produces a sensitive ZIP containing trace logs, `phpinfo()` output, server settings,
and recent package logs.

**Skeptic position:** This is the most interesting surface in the codebase because
the capability check is missing from the AJAX wrapper itself. Phase 2 correctly
concluded that the nonce-bearing URL is emitted only from the Tools diagnostics page,
which requires `manage_options` before rendering.

**Counter-evidence:**
- `plugins/duplicator/views/tools/controller.php:13` — Tools page gated by
  `DUP_Util::hasCapability('manage_options')`.
- `plugins/duplicator/views/tools/diagnostics/inc.data.php:103` — nonce-bearing
  URL embedded only in that page's template.
- No other bundled template, localization call, or REST route was found that
  exposes `duplicator_download_support_toolkit` nonce to lower-privileged users.

**Secure in current shipping code** because no lower-privilege nonce-disclosure path
exists. This is a defense-in-depth gap, not a standalone exploitable finding.

**Reopen if:** a secondary nonce-exposure path is found (e.g., a globally localized
script, a separate AJAX endpoint, or a world-readable log file containing the nonce
string), OR if a CSRF vulnerability on the Tools page is discovered that allows
forging the nonce-bearing request.

---

### 4.5 One-click upgrade nopriv route (src/Ajax/ServicesEducation.php)

As documented in Phase 2 NEG-010, `wp_ajax_nopriv_duplicator_lite_run_one_click_upgrade`
reaches `Plugin_Upgrader->install()`, `deactivate_plugins()`, and an activation
redirect. The route is unauthenticated.

**Skeptic position:** This is the highest-consequence sink in the plugin. The
unauthenticated registration deserves the most scrutiny.

**Counter-evidence:**
- Line 301: `oneClickUpgrade()` requires the `duplicator_one_click_upgrade_oth`
  option to be present and unexpired.
- Line 316: The request-supplied package blob must decrypt under the stored token.
- Line 168: The token is generated only by `generateConnectOTH()`.
- Line 152: `generateConnectOTH()` enforces `export` capability.
- Line 333: The OTH is deleted after use.

**No alternate read of the stored OTH** was found in the bundled code. The token
generation is strictly gated by `export`; the installer sink is therefore
unreachable by any attacker who cannot first obtain that token.

**Secure because:** the installer sink is behind a two-step export-gated token
handshake with 10-minute TTL and single-use deletion.

**Reopen if:** a read path for `duplicator_one_click_upgrade_oth` is discovered
accessible below `export`, or if a timing or token-guessing attack is demonstrated.

---

## 5. Overall Assessment

Duplicator 1.5.16 presents **no actionable findings** for Phase 3b. All 28 entry
points evaluated in Phase 2 are correctly guarded. The plugin applies a consistent
defense pattern: (1) nonce validation via `check_ajax_referer` or `wp_verify_nonce`,
then (2) capability enforcement via `DUP_Util::hasCapability()`. That function wraps
`current_user_can()` and fails closed.

Two surfaces warrant monitoring in future versions:

1. **Support-toolkit download** (`duplicator_download_support_toolkit`) lacks an
   in-handler capability check. It is safe today because the nonce is only emitted
   from an admin-gated page; any future nonce-disclosure path would make this
   immediately exploitable. A direct `current_user_can('manage_options')` call
   inside the AJAX wrapper would harden this defensively.

2. **`SaveViewState`** accepts arbitrary key-value pairs into the
   `duplicator_ui_view_state` option array. This is safe today because the write is
   export-gated and the data is only ever read back as UI state. Any future path that
   passes array values into a sensitive sink (include, eval, redirect, shell_exec)
   would elevate this to a second-order injection finding.

Neither surface rises to reportable status in the current codebase. The overall risk
posture for Duplicator 1.5.16 is **none**.
