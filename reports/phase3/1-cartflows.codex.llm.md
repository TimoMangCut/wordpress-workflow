# Plugin Overview

CartFlows 2.2.4 is a WooCommerce funnel builder and checkout plugin that adds custom checkout flows, upsells, and related admin tooling (`plugins/cartflows/cartflows.php:3-10`, `plugins/cartflows/readme.txt:1-24`). This Phase 3b skeptic pass has no finding-level scope because the canonical Phase 2 artifact contains `findings: []` and the Phase 3a gate reports `plausible: 0`, `uncertain: 0`, with both `validated_findings` and `actionable_findings` empty (`reports/phase2/cartflows-phase2.json:13-25`, `reports/phase3/cartflows-phase3.json:15-22`).

# Validation Summary

- Reviewed: 0
- Downgraded: 0
- Kept: 0
- Upgraded: 0

# Detailed Reviews

None. `reports/phase3/cartflows-phase3.json:15-22` contains no `PLAUSIBLE` or `UNCERTAIN` findings, so there is no finding-level `Type`, `Minimum Role/Capability`, `Status Transition`, `missing evidence`, or `dynamic test plan` entry to add without inventing scope.

# Negative Findings

- `plugins/cartflows/modules/checkout/classes/class-cartflows-checkout-ajax.php:295`, `plugins/cartflows/modules/checkout/classes/class-cartflows-checkout-ajax.php:315`, `plugins/cartflows/modules/checkout/classes/class-cartflows-checkout-ajax.php:331`, and `plugins/cartflows/classes/class-cartflows-helper.php:1933` show the public checkout upload path still enforces a nonce, intersects field restrictions with a fixed media allowlist, and validates MIME/extension agreement before any file is moved. Current code therefore does not support an evidence-backed `Arbitrary File Upload` style escalation claim from the guest checkout surface.
- `plugins/cartflows/compatibilities/plugins/tutor-lms/class-cartflows-tutor-compatibility.php:200`, `plugins/cartflows/compatibilities/plugins/tutor-lms/class-cartflows-tutor-compatibility.php:217`, and `plugins/cartflows/compatibilities/plugins/tutor-lms/class-cartflows-tutor-compatibility.php:228` show the Tutor LMS template-save AJAX path verifies a nonce, enforces `current_user_can( 'edit_post', $course_id )`, and only then updates the fixed plugin meta key. That is counter-evidence against a low-privilege `Broken Access Control` or `Privilege Escalation` narrative on this path.
- `plugins/cartflows/admin-core/ajax/common-settings.php:101`, `plugins/cartflows/admin-core/ajax/common-settings.php:113`, `plugins/cartflows/admin-core/api/flows.php:69`, and `plugins/cartflows/admin-core/api/flows.php:299` show the admin AJAX and REST mutation surfaces remain capability-gated and protected by explicit permission callbacks. This matches the Phase 2 conclusion that any lower-role access here would require administrator-delegated CartFlows capabilities rather than ambient exposure (`reports/phase2/cartflows-phase2.json:13-17`).

# Overall Assessment

The deterministic gate remains authoritative for `cartflows`: there are no Phase 3a findings for the skeptic reviewer to downgrade, keep, or upgrade. Missing evidence and dynamic verification are therefore not applicable at finding granularity, and Phase 3b should only be reopened if a later canonical artifact introduces a concrete `PLAUSIBLE` or `UNCERTAIN` finding or if new source evidence shows one of the cited guards is bypassable.
