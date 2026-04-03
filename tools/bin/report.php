#!/usr/bin/env php
<?php
/**
 * report.php — Query and display findings from SQLite
 * Usage:
 *   php bin/report.php summary              — All plugins with findings
 *   php bin/report.php findings <slug>      — Findings for a plugin
 *   php bin/report.php metrics              — Pipeline performance metrics
 *   php bin/report.php contribution         — Unique findings per engine
 */
declare(strict_types=1);

require_once __DIR__ . '/../vendor/autoload.php';

use WPAudit\Store\SQLiteStore;

$dbPath = dirname(__DIR__) . '/../data/audit.db';
if (!file_exists($dbPath)) {
    fwrite(STDERR, "Database not found: {$dbPath}\n");
    exit(1);
}

$store = new SQLiteStore($dbPath);
$command = $argv[1] ?? 'summary';

match ($command) {
    'summary' => showSummary($store),
    'findings' => showFindings($store, $argv[2] ?? null),
    'metrics' => showMetrics($store),
    'contribution' => showContribution($store),
    default => fwrite(STDERR, "Unknown command: {$command}\nUsage: report.php [summary|findings <slug>|metrics|contribution]\n"),
};

function showSummary(SQLiteStore $store): void
{
    $rows = $store->getSummary();
    echo str_pad('Plugin', 40) . str_pad('Status', 12) . str_pad('Findings', 10) .
         str_pad('Critical', 10) . str_pad('High', 8) . "\n";
    echo str_repeat('-', 80) . "\n";
    foreach ($rows as $r) {
        echo str_pad($r['slug'], 40) .
             str_pad($r['status'] ?? '?', 12) .
             str_pad((string)$r['finding_count'], 10) .
             str_pad((string)$r['critical_count'], 10) .
             str_pad((string)$r['high_count'], 8) . "\n";
    }
    echo "\nTotal plugins: " . count($rows) . "\n";
}

function showFindings(SQLiteStore $store, ?string $slug): void
{
    if (!$slug) { fwrite(STDERR, "Usage: report.php findings <slug>\n"); exit(1); }
    $pluginId = $store->getPluginId($slug);
    if (!$pluginId) { fwrite(STDERR, "Plugin not found: {$slug}\n"); exit(1); }

    $findings = $store->getFindings($pluginId);
    echo "=== Findings: {$slug} ===\n\n";
    foreach ($findings as $f) {
        echo "[{$f['severity']}] {$f['type']} ({$f['phase']}";
        if ($f['rule_id']) echo " / {$f['rule_id']}";
        echo ")\n";
        echo "  {$f['description']}\n";
        if ($f['evidence_json']) {
            $ev = json_decode($f['evidence_json'], true);
            if ($ev) echo "  → {$ev['file']}:{$ev['line']}\n";
        }
        echo "\n";
    }
    echo "Total: " . count($findings) . " findings\n";
}

function showMetrics(SQLiteStore $store): void
{
    $rows = $store->getMetricsSummary();
    echo str_pad('Phase', 15) . str_pad('Metric', 25) . str_pad('Avg', 10) .
         str_pad('Max', 10) . str_pad('Plugins', 8) . "\n";
    echo str_repeat('-', 68) . "\n";
    foreach ($rows as $r) {
        echo str_pad($r['phase'], 15) .
             str_pad($r['metric_name'], 25) .
             str_pad(number_format($r['avg_val'], 1), 10) .
             str_pad(number_format($r['max_val'], 1), 10) .
             str_pad((string)$r['count'], 8) . "\n";
    }
}

function showContribution(SQLiteStore $store): void
{
    $db = $store->getPDO();
    $rows = $db->query("
        SELECT phase, COUNT(*) as count,
               SUM(CASE WHEN severity='critical' THEN 1 ELSE 0 END) as critical,
               SUM(CASE WHEN severity='high' THEN 1 ELSE 0 END) as high
        FROM findings
        GROUP BY phase
        ORDER BY count DESC
    ")->fetchAll();

    echo "=== Engine Contribution ===\n\n";
    echo str_pad('Engine', 20) . str_pad('Findings', 10) . str_pad('Critical', 10) . str_pad('High', 8) . "\n";
    echo str_repeat('-', 48) . "\n";
    foreach ($rows as $r) {
        echo str_pad($r['phase'], 20) .
             str_pad((string)$r['count'], 10) .
             str_pad((string)$r['critical'], 10) .
             str_pad((string)$r['high'], 8) . "\n";
    }
}
