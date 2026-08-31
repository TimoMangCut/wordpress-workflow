<?php
/**
 * Extractor regression harness — locks the WPAudit IR extractor behaviour that plugin-review
 * recall depends on. Self-contained: uses only php-parser + WPAudit\Extractor already present
 * in the Docker image. No phpunit, no new dependency.
 *
 * Run it inside the audit image via tools/bin/run-extractor-tests.sh (mounts the live extractor
 * source over the baked image so it tests the current code). Exit 0 = all green, 1 = a
 * regression. Each check asserts a behaviour tied to a documented IR gap fix (IR-01/04/07 …);
 * a failure here means a silent recall/precision regression in the independent IR source.
 */
declare(strict_types=1);

foreach ([
    '/opt/wp-audit/tools/vendor/autoload.php',
    __DIR__ . '/../vendor/autoload.php',
] as $autoload) {
    if (is_file($autoload)) { require $autoload; break; }
}

use WPAudit\Extractor\IRBuilder;

$FIX = $argv[1] ?? __DIR__ . '/fixtures';
$fail = 0;

function build(string $dir): array
{
    return (new IRBuilder($dir))->build();
}

function check(string $name, bool $ok, string $detail = ''): void
{
    global $fail;
    if ($ok) {
        fwrite(STDOUT, "PASS  $name\n");
    } else {
        $fail++;
        fwrite(STDOUT, "FAIL  $name" . ($detail ? " — $detail" : '') . "\n");
    }
}

/** find first item matching a predicate */
function first(array $items, callable $pred): ?array
{
    foreach ($items as $it) {
        if ($pred($it)) { return $it; }
    }
    return null;
}

// IR-01 / wc_ajax blind spot: dynamic hook names with a known action prefix become entry
// points (low confidence); only prefix-less dynamic names stay in unresolved_hooks.
$ir = build("$FIX/dynamic-hook");
$dynAjax = first($ir['entry_points'],
    fn($e) => ($e['type'] ?? '') === 'ajax_priv' && ($e['dynamic_hook'] ?? false) === true);
check('IR-01 dynamic wp_ajax_ hook -> entry point (low confidence)',
    $dynAjax !== null && ($dynAjax['resolution_confidence'] ?? '') === 'low',
    'expected a dynamic ajax_priv entry point with resolution_confidence=low');
$dynWc = first($ir['entry_points'],
    fn($e) => ($e['type'] ?? '') === 'wc_ajax' && ($e['dynamic_hook'] ?? false) === true);
check('wc_ajax dynamic hook -> entry point with auth_level=none',
    $dynWc !== null && ($dynWc['auth_level'] ?? '') === 'none',
    "expected 'wc_ajax_' . CONST to resolve to a wc_ajax entry point, auth none");
$litWc = first($ir['entry_points'],
    fn($e) => ($e['hook_name'] ?? '') === 'wc_ajax_literal_thing');
check('wc_ajax literal hook -> entry point with auth_level=none',
    $litWc !== null && ($litWc['type'] ?? '') === 'wc_ajax' && ($litWc['auth_level'] ?? '') === 'none',
    'expected literal wc_ajax_ hook as a wc_ajax entry point with auth none');
check('IR-01 prefix-less dynamic hook still -> unresolved_hooks (no silent drop)',
    (bool) first($ir['unresolved_hooks'], fn($h) => ($h['hook_arg_type'] ?? '') === 'concatenation'),
    'expected an unresolved hook with hook_arg_type=concatenation for an unknown prefix');

// nopriv AJAX surface + unsanitized SQL sink detection.
$ir = build("$FIX/nopriv-ajax");
$ep = first($ir['entry_points'], fn($e) => ($e['hook_name'] ?? '') === 'wp_ajax_nopriv_do_thing');
check('nopriv AJAX detected as auth_level=none',
    $ep !== null && ($ep['auth_level'] ?? '') === 'none',
    'expected entry point wp_ajax_nopriv_do_thing with auth_level none');
check('unsanitized SQL sink (uses_prepared_statement=false)',
    (bool) first($ir['sinks'], fn($s) => ($s['category'] ?? '') === 'sql' && ($s['uses_prepared_statement'] ?? null) === false),
    'expected a sql sink with uses_prepared_statement=false');
check('POST source key extracted',
    (bool) first($ir['sources'], fn($s) => ($s['key'] ?? null) === 'q'),
    'expected a source with key q');

// IR-07: storage read is emitted as a source, and the write key matches the read key.
$ir = build("$FIX/storage");
check('IR-07 option_read emitted as source with key',
    (bool) first($ir['sources'], fn($s) => ($s['type'] ?? '') === 'option_read' && ($s['key'] ?? null) === 'my_key'),
    'expected an option_read source with key my_key');
check('IR-07 option write key extracted',
    (bool) first($ir['sinks'], fn($s) => ($s['category'] ?? '') === 'option_update' && ($s['key'] ?? null) === 'my_key'),
    'expected an option_update sink with key my_key (write/read key match)');

// IR-04: guard effectiveness is three-state and driven by whether the check gates the effect.
$ir = build("$FIX/guard-effectiveness");
$effEp = first($ir['entry_points'], fn($e) => ($e['hook_name'] ?? '') === 'wp_ajax_effective');
$ineffEp = first($ir['entry_points'], fn($e) => ($e['hook_name'] ?? '') === 'wp_ajax_ineffective');
$effGuard = $effEp ? first($ir['guards'], fn($g) => ($g['entry_point_id'] ?? '') === ($effEp['id'] ?? '')) : null;
$ineffGuard = $ineffEp ? first($ir['guards'], fn($g) => ($g['entry_point_id'] ?? '') === ($ineffEp['id'] ?? '')) : null;
check('IR-04 gating capability check is_effective=true',
    $effGuard !== null && ($effGuard['is_effective'] ?? null) === true,
    'expected the wp_die-gated current_user_can to be is_effective=true');
check('IR-04 non-gating capability check is_effective=false',
    $ineffGuard !== null && ($ineffGuard['is_effective'] ?? null) === false,
    'expected the assigned-but-unused current_user_can to be is_effective=false');

fwrite(STDOUT, "\n" . ($fail ? "EXTRACTOR TESTS FAILED: $fail check(s)\n" : "EXTRACTOR TESTS PASSED\n"));
exit($fail ? 1 : 0);
