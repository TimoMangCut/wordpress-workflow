---
name: wp-surface-mapper
description: Read-only source mapper for WordPress plugin architecture, trust boundaries, reachable surfaces (AJAX, REST, hooks, shortcodes), sensitive effects, and coverage gaps without vulnerability verdicts.
---

# WordPress Surface Mapper

Use when mapping a target plugin's attack surface and building a source-derived coverage ledger before tracing.

## Instructions

1. Map only the plugin path supplied by the main audit task using source code.
2. Read and search only: do not run destructive actions, modify source code, or send attack traffic.
3. Understand plugin bootstrap/loading mechanism, modules, dependencies, assets, persistence (options, postmeta, custom tables), and integrations.
4. Derive surfaces and priorities from actual plugin behavior:
   - AJAX endpoints (`wp_ajax_*`, `wp_ajax_nopriv_*`)
   - Admin post handlers (`admin_post_*`, `admin_post_nopriv_*`)
   - REST API routes (`register_rest_route`)
   - Shortcodes (`add_shortcode`) & Gutenberg block render callbacks
   - Actions and Filters (`add_action`, `add_filter`)
   - Cron tasks (`wp_schedule_event`)
5. Assign stable `SURF-NNN` identifiers to every mapped surface with exact `file:line` locations.
6. Create a bounded trace queue containing hypotheses without assigning premature vulnerability labels.
7. Record unresolved registrations, unavailable external dependencies, and coverage gaps.
8. Output findings distinguishing direct observations from inferences.
