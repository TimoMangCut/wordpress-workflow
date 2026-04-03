<?php
declare(strict_types=1);

namespace WPAudit\Rules;

/**
 * AnomalyRules: 10 deterministic rules that detect structural security defects
 * from the IR without any LLM involvement.
 */
class AnomalyRules
{
    /**
     * Run all rules against IR. Returns array of anomalies.
     */
    public function run(array $ir): array
    {
        $anomalies = [];
        $anomalies = array_merge($anomalies, $this->rule01_missingNonce($ir));
        $anomalies = array_merge($anomalies, $this->rule02_missingCapability($ir));
        $anomalies = array_merge($anomalies, $this->rule03_flawedNoncePattern($ir));
        $anomalies = array_merge($anomalies, $this->rule04_sqlWithoutPrepare($ir));
        $anomalies = array_merge($anomalies, $this->rule05_unescapedOutput($ir));
        $anomalies = array_merge($anomalies, $this->rule06_isAdminAsAuth($ir));
        $anomalies = array_merge($anomalies, $this->rule07_returnTruePermission($ir));
        $anomalies = array_merge($anomalies, $this->rule08_noprivSensitiveOp($ir));
        $anomalies = array_merge($anomalies, $this->rule09_unsafeRedirect($ir));
        $anomalies = array_merge($anomalies, $this->rule10_crossHandlerInconsistency($ir));
        return $anomalies;
    }

    /**
     * Rule 1: State-changing AJAX/admin_post entry point without nonce check.
     */
    private function rule01_missingNonce(array $ir): array
    {
        $anomalies = [];
        $needsNonce = ['ajax_priv', 'admin_post', 'admin_init'];

        foreach ($ir['entry_points'] as $ep) {
            if (!in_array($ep['type'], $needsNonce, true)) continue;

            // Check if entry point has state-changing sinks
            $hasSideEffect = $this->entryHasSinks($ir, $ep['id'],
                ['sql', 'file_write', 'file_delete', 'option_update', 'meta_update', 'eval']);
            if (!$hasSideEffect) continue;

            // Check if nonce guard exists for this entry point
            $hasNonce = $this->hasGuardType($ir, $ep['id'], 'nonce_check');
            if (!$hasNonce) {
                $anomalies[] = $this->makeAnomaly('rule_01', 'missing_nonce', 'high', 'CWE-352',
                    $ep['id'], "Missing nonce check in {$ep['type']} handler '{$ep['hook_name']}'",
                    $ep['file'], $ep['line']);
            }
        }
        return $anomalies;
    }

    /**
     * Rule 2: Entry point performing admin operations without current_user_can().
     */
    private function rule02_missingCapability(array $ir): array
    {
        $anomalies = [];
        $needsCap = ['ajax_priv', 'admin_post', 'admin_init'];
        $adminSinks = ['option_update', 'meta_update', 'file_write', 'file_delete'];

        foreach ($ir['entry_points'] as $ep) {
            if (!in_array($ep['type'], $needsCap, true)) continue;
            if (!$this->entryHasSinks($ir, $ep['id'], $adminSinks)) continue;

            $hasCap = $this->hasGuardType($ir, $ep['id'], 'capability_check');
            if (!$hasCap) {
                $anomalies[] = $this->makeAnomaly('rule_02', 'missing_capability', 'high', 'CWE-862',
                    $ep['id'], "Missing current_user_can() in {$ep['type']} handler '{$ep['hook_name']}' with admin-level operations",
                    $ep['file'], $ep['line']);
            }
        }
        return $anomalies;
    }

    /**
     * Rule 3: Flawed nonce pattern — check_ajax_referer($die=false) or guard after side-effect.
     */
    private function rule03_flawedNoncePattern(array $ir): array
    {
        $anomalies = [];
        foreach ($ir['guards'] as $guard) {
            if ($guard['type'] === 'nonce_check' && $guard['is_effective'] === false) {
                $anomalies[] = $this->makeAnomaly('rule_03', 'flawed_nonce_pattern', 'medium', 'CWE-352',
                    $guard['entry_point_id'], "Flawed nonce check: {$guard['notes']}",
                    $guard['file'], $guard['line']);
            }
        }
        return $anomalies;
    }

    /**
     * Rule 4: SQL sink without $wpdb->prepare().
     * ONLY fires when:
     *   1. Sink is scoped to an entry point (not file-level helpers)
     *   2. Entry point has user input sources (superglobals, REST, shortcode attrs)
     *   3. uses_prepared_statement is false or null (true = skip)
     * Severity is per-sink, not per-EP:
     *   - uses_prepared_statement === false, EP has no prepare() elsewhere → 'critical'
     *   - uses_prepared_statement === false, EP has prepare() elsewhere    → 'high'
     *   - uses_prepared_statement === null (unknown)                        → 'high'
     */
    private function rule04_sqlWithoutPrepare(array $ir): array
    {
        $anomalies = [];

        // Pre-compute: which entry points have ANY prepare() sink?
        // Used only for severity differentiation on confirmed-unprepared sinks.
        $epHasPrepare = [];
        foreach ($ir['sinks'] as $sink) {
            if ($sink['category'] === 'sql' && $sink['uses_prepared_statement'] === true
                && $sink['entry_point_id'] !== null) {
                $epHasPrepare[$sink['entry_point_id']] = true;
            }
        }

        // Pre-compute: which entry points have user input sources?
        $userSourceTypes = [
            'superglobal_get', 'superglobal_post', 'superglobal_request',
            'superglobal_cookie', 'superglobal_server',
            'rest_param', 'rest_params', 'rest_json', 'rest_body',
            'rest_body_params', 'rest_query_params', 'rest_url_params',
            'rest_header', 'rest_headers', 'rest_array_access',
            'shortcode_attr', 'block_attr',
        ];
        $epHasUserSource = [];
        foreach ($ir['sources'] as $source) {
            if ($source['entry_point_id'] !== null &&
                in_array($source['type'], $userSourceTypes, true)) {
                $epHasUserSource[$source['entry_point_id']] = true;
            }
        }

        foreach ($ir['sinks'] as $sink) {
            // Skip file-level sinks (not scoped to entry point)
            if ($sink['entry_point_id'] === null) continue;
            if ($sink['category'] !== 'sql') continue;

            // Per-sink: skip only when prepare() confirmed on this sink
            if ($sink['uses_prepared_statement'] === true) continue;

            // CRITICAL FP PREVENTION: Skip if entry point has NO user input sources.
            // Static SQL like "$wpdb->get_results('SELECT ... FROM wp_posts')" is not exploitable.
            if (!isset($epHasUserSource[$sink['entry_point_id']])) continue;

            // Per-sink severity:
            //   null  → 'high'  (prepare status unknown — cannot confirm safe)
            //   false → 'critical' if EP has no other prepare(); 'high' if mixed
            if ($sink['uses_prepared_statement'] === null) {
                $severity = 'high';
                $note = ' (prepare() status unknown — verify manually)';
            } else {
                // === false
                $hasPrepareElsewhere = isset($epHasPrepare[$sink['entry_point_id']]);
                $severity = $hasPrepareElsewhere ? 'high' : 'critical';
                $note = $hasPrepareElsewhere
                    ? ' (prepare() found on other sinks in callback — verify all paths)'
                    : '';
            }

            $anomalies[] = $this->makeAnomaly('rule_04', 'unsanitized_sql', $severity, 'CWE-89',
                $sink['entry_point_id'],
                "SQL query via \$wpdb->{$sink['function_called']}() without prepare() — user input present in callback"
                . $note,
                $sink['file'], $sink['line']);
        }
        return $anomalies;
    }

    /**
     * Rule 5: Output sink (echo/print) with source data but no escaping detected.
     * Note: simplified — full taint tracking in Semgrep/Progpilot.
     */
    private function rule05_unescapedOutput(array $ir): array
    {
        // This rule is a signal, not definitive — Semgrep handles taint tracking
        // We flag entry points that have BOTH output sinks AND shortcode/REST sources
        $anomalies = [];
        foreach ($ir['entry_points'] as $ep) {
            if (!in_array($ep['type'], ['shortcode', 'block'], true)) continue;

            $hasOutputSink = $this->entryHasSinks($ir, $ep['id'], ['output', 'output_return']);
            $hasAttrSource = $this->entryHasSources($ir, $ep['id'], ['shortcode_attr', 'block_attr']);

            if ($hasOutputSink && $hasAttrSource) {
                $anomalies[] = $this->makeAnomaly('rule_05', 'potential_xss', 'medium', 'CWE-79',
                    $ep['id'], "Shortcode/block '{$ep['hook_name']}' has attribute sources + output sinks — verify escaping",
                    $ep['file'], $ep['line']);
            }
        }
        return $anomalies;
    }

    /**
     * Rule 6: is_admin() used as authorization check.
     */
    private function rule06_isAdminAsAuth(array $ir): array
    {
        $anomalies = [];
        foreach ($ir['guards'] as $guard) {
            if ($guard['type'] === 'is_admin_check') {
                $anomalies[] = $this->makeAnomaly('rule_06', 'is_admin_as_auth', 'high', 'CWE-862',
                    $guard['entry_point_id'],
                    "is_admin() checks URI prefix, NOT user role — any subscriber can access /wp-admin/admin-ajax.php",
                    $guard['file'], $guard['line']);
            }
        }
        return $anomalies;
    }

    /**
     * Rule 7: REST route with permission_callback = __return_true.
     */
    private function rule07_returnTruePermission(array $ir): array
    {
        $anomalies = [];
        foreach ($ir['entry_points'] as $ep) {
            if ($ep['type'] !== 'rest_route') continue;

            $pc = $ep['permission_callback'] ?? null;
            if ($pc === '__return_true' || $pc === null) {
                $hasSensitiveSink = $this->entryHasSinks($ir, $ep['id'],
                    ['sql', 'file_write', 'file_delete', 'option_update', 'meta_update', 'eval']);
                if ($hasSensitiveSink || $pc === '__return_true') {
                    $anomalies[] = $this->makeAnomaly('rule_07', 'rest_return_true', 'high', 'CWE-862',
                        $ep['id'],
                        "REST route '{$ep['hook_name']}' " .
                            ($pc === null ? "missing permission_callback" : "has permission_callback = __return_true") .
                            " — publicly accessible",
                        $ep['file'], $ep['line']);
                }
            }
        }
        return $anomalies;
    }

    /**
     * Rule 8: wp_ajax_nopriv_* with sensitive operations.
     */
    private function rule08_noprivSensitiveOp(array $ir): array
    {
        $anomalies = [];
        $noprivTypes = ['ajax_nopriv', 'admin_post_nopriv'];

        foreach ($ir['entry_points'] as $ep) {
            if (!in_array($ep['type'], $noprivTypes, true)) continue;

            $sensitive = ['sql', 'file_write', 'file_delete', 'option_update', 'meta_update',
                'eval', 'deserialization'];
            if ($this->entryHasSinks($ir, $ep['id'], $sensitive)) {
                $anomalies[] = $this->makeAnomaly('rule_08', 'nopriv_sensitive_op', 'critical', 'CWE-862',
                    $ep['id'],
                    "Unauthenticated handler '{$ep['hook_name']}' performs sensitive operations",
                    $ep['file'], $ep['line']);
            }
        }
        return $anomalies;
    }

    /**
     * Rule 9: wp_redirect() with user-controlled URL (vs wp_safe_redirect).
     */
    private function rule09_unsafeRedirect(array $ir): array
    {
        $anomalies = [];
        foreach ($ir['sinks'] as $sink) {
            if ($sink['category'] === 'redirect' && $sink['function_called'] === 'wp_redirect') {
                // Check if entry point has user-controlled sources
                $ep = $sink['entry_point_id'];
                if ($ep && $this->entryHasSources($ir, $ep, ['superglobal_get', 'superglobal_post',
                    'superglobal_request', 'rest_param', 'rest_json', 'rest_query_params'])) {
                    $anomalies[] = $this->makeAnomaly('rule_09', 'unsafe_redirect', 'medium', 'CWE-601',
                        $ep, "wp_redirect() used instead of wp_safe_redirect() with user input present",
                        $sink['file'], $sink['line']);
                }
            }
        }
        return $anomalies;
    }

    /**
     * Rule 10: Cross-handler inconsistency — the core anomaly detection rule.
     * Groups entry points by type, computes guard profiles, flags outliers.
     */
    private function rule10_crossHandlerInconsistency(array $ir): array
    {
        $anomalies = [];

        // Group entry points by type
        $groups = [];
        foreach ($ir['entry_points'] as $ep) {
            $groups[$ep['type']][] = $ep;
        }

        foreach ($groups as $type => $endpoints) {
            if (count($endpoints) < 2) continue; // Need ≥2 to compare

            // Compute guard profile for each endpoint
            $profiles = [];
            foreach ($endpoints as $ep) {
                $hasNonce = $this->hasGuardType($ir, $ep['id'], 'nonce_check');
                $hasCap = $this->hasGuardType($ir, $ep['id'], 'capability_check');
                $profiles[] = [
                    'ep' => $ep,
                    'has_nonce' => $hasNonce,
                    'has_cap' => $hasCap,
                    'score' => ($hasNonce ? 1 : 0) + ($hasCap ? 1 : 0),
                ];
            }

            // Find majority guard level
            $scores = array_column($profiles, 'score');
            $majorityScore = $this->mode($scores);

            // Flag endpoints below majority
            foreach ($profiles as $p) {
                if ($p['score'] < $majorityScore && $majorityScore > 0) {
                    $missing = [];
                    if (!$p['has_nonce']) $missing[] = 'nonce';
                    if (!$p['has_cap']) $missing[] = 'capability';
                    $missingStr = implode(' + ', $missing);

                    $anomalies[] = $this->makeAnomaly('rule_10', 'inconsistency', 'high', 'CWE-862',
                        $p['ep']['id'],
                        "Handler '{$p['ep']['hook_name']}' missing {$missingStr} — " .
                            (count($endpoints) - 1) . " other {$type} handlers have them",
                        $p['ep']['file'], $p['ep']['line']);
                }
            }
        }

        return $anomalies;
    }

    // --- Helpers ---

    private function entryHasSinks(array $ir, string $epId, array $categories): bool
    {
        foreach ($ir['sinks'] as $sink) {
            if ($sink['entry_point_id'] === $epId && in_array($sink['category'], $categories, true)) {
                return true;
            }
        }
        return false;
    }

    private function entryHasSources(array $ir, string $epId, array $types): bool
    {
        foreach ($ir['sources'] as $source) {
            if ($source['entry_point_id'] === $epId && in_array($source['type'], $types, true)) {
                return true;
            }
        }
        return false;
    }

    private function hasGuardType(array $ir, string $epId, string $guardType): bool
    {
        foreach ($ir['guards'] as $guard) {
            if ($guard['entry_point_id'] === $epId &&
                $guard['type'] === $guardType &&
                $guard['is_effective']) {
                return true;
            }
        }
        return false;
    }

    private function makeAnomaly(string $ruleId, string $type, string $severity,
                                  string $cwe, ?string $epId, string $description,
                                  string $file, int $line): array
    {
        static $counter = 0;
        return [
            'id' => 'anom_' . (++$counter),
            'rule_id' => $ruleId,
            'type' => $type,
            'severity' => $severity,
            'cwe_id' => $cwe,
            'entry_point_id' => $epId,
            'description' => $description,
            'evidence' => ['file' => $file, 'line' => $line],
        ];
    }

    /** Statistical mode (most frequent value) */
    private function mode(array $values): int
    {
        $counts = array_count_values($values);
        arsort($counts);
        return (int)array_key_first($counts);
    }
}
