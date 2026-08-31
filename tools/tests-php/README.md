# PHP extractor regression harness

Locks the behaviour of the WPAudit IR extractor (`tools/src/Extractor/`). The extractor is the
**independent corroboration source** the single-agent review reconciles its self-parse against
(`docs/review-methodology.md`). A silent regression here degrades recall with no signal, so this
harness is a correctness net, not a nicety.

## Run

```bash
bash tools/bin/run-extractor-tests.sh
```

It runs entirely inside the audit Docker image (no local PHP/composer), mounting the live
`tools/src` and `tools/tests-php` over the baked image so it tests the **current** extractor
without a rebuild. Exit 0 = green, 1 = a regression, 2 = image missing (build it first with
`bash tools/bin/wp-audit-tools.sh build`).

## What it covers

Self-contained (php-parser + `WPAudit\Extractor` only — no phpunit). Each fixture under
`fixtures/` is a tiny plugin that exercises one recall-critical behaviour; assertions in
`extract_regression.php` lock the observed IR:

- **IR-01** dynamic hook name (`'wp_ajax_'.$x`) → surfaced in `unresolved_hooks` (`hook_arg_type`),
  never silently dropped, never a false concrete entry point.
- **nopriv AJAX** → entry point with `auth_level: none`; unsanitized `$wpdb->query` → `sql` sink
  with `uses_prepared_statement: false`; `$_POST` key extracted.
- **IR-07** storage read → `option_read` source carrying its `key`; write → `option_update` sink
  carrying its `key` (so write/read key matching works).
- **IR-04** guard effectiveness is three-state: a `wp_die`-gated `current_user_can` is
  `is_effective: true`; an assigned-but-unused one is `is_effective: false`.

## Adding a case

Add a fixture dir under `fixtures/<name>/` with a minimal `plugin.php`, then add assertions in
`extract_regression.php` using `build("$FIX/<name>")` and the `first()`/`check()` helpers. Assert
the exact IR values the current extractor produces (run the harness once to observe them), so any
future behavioural drift fails.
