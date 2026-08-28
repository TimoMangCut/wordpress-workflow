#!/usr/bin/env php
<?php
/**
 * extract.php — WordPress Plugin IR Extractor
 * Usage: php bin/extract.php <plugin-directory> [--db=path] [--json] [--quiet]
 */
declare(strict_types=1);

// Ensure enough memory for large plugins. Respects PHP_MEMORY_LIMIT env var;
// falls back to 1024M so direct invocations work the same as scan-all.sh.
$_memLimit = getenv('PHP_MEMORY_LIMIT') ?: '1024M';
ini_set('memory_limit', $_memLimit);
unset($_memLimit);

require_once __DIR__ . '/../vendor/autoload.php';

use WPAudit\Extractor\IRBuilder;
use WPAudit\Rules\AnomalyRules;
use WPAudit\Store\SQLiteStore;

// --- Parse arguments ---
$args = parseArgs($argv);
$pluginDir = $args['plugin_dir'] ?? null;
$dbPath = $args['db'] ?? dirname(__DIR__) . '/../data/audit.db';
$outputJson = $args['json'] ?? false;
$quiet = $args['quiet'] ?? false;
$reportsDir = dirname(__DIR__) . '/../reports/phase1';

if (!$pluginDir || !is_dir($pluginDir)) {
    fwrite(STDERR, "Usage: php bin/extract.php <plugin-directory> [--db=path] [--json] [--quiet]\n");
    exit(1);
}

$slug = basename(realpath($pluginDir));
if (!$quiet) fwrite(STDERR, "[*] Extracting IR: {$slug}\n");

$startTime = microtime(true);

// --- Phase 1: Extract IR ---
try {
    $builder = new IRBuilder($pluginDir);
    $ir = $builder->build();
} catch (\Throwable $e) {
    fwrite(STDERR, "[!] Parse error: {$e->getMessage()}\n");
    exit(2);
}

$extractMs = (int)((microtime(true) - $startTime) * 1000);
if (!$quiet) {
    fwrite(STDERR, "    Entry points: " . count($ir['entry_points']) . "\n");
    fwrite(STDERR, "    Guards: " . count($ir['guards']) . "\n");
    fwrite(STDERR, "    Sources: " . count($ir['sources']) . "\n");
    fwrite(STDERR, "    Sinks: " . count($ir['sinks']) . "\n");
    fwrite(STDERR, "    Time: {$extractMs}ms\n");
}

// --- Phase 2: Run deterministic anomaly rules ---
$rules = new AnomalyRules();
$anomalies = $rules->run($ir);
$ir['anomalies'] = $anomalies;

if (!$quiet) {
    fwrite(STDERR, "    Anomalies: " . count($anomalies) . "\n");
    foreach ($anomalies as $a) {
        fwrite(STDERR, "      [{$a['severity']}] {$a['rule_id']}: {$a['description']}\n");
    }
}

// --- Phase 3: Store in SQLite ---
try {
    $store = new SQLiteStore($dbPath);

    // Compute file hash for cache
    // Cache key must cover the extractor too. Hashing only plugin source meant a fix to
    // EntryPointVisitor (e.g. the ep_rest___0 id collapse) left every existing IR stale while
    // the pipeline reported "Cache hit (hash unchanged), skipping".
    $fileHash = computePluginHash($pluginDir) . '-' . computeExtractorHash();

    // Check cache: skip if hash unchanged
    $existingHash = $store->getPluginHash($slug);
    if ($existingHash === $fileHash && !isset($args['force'])) {
        if (!$quiet) fwrite(STDERR, "[=] Cache hit (hash unchanged), skipping\n");
        if ($outputJson) echo json_encode($ir, JSON_PRETTY_PRINT) . "\n";
        exit(0);
    }

    $pluginId = $store->upsertPlugin($slug, $ir['metadata']['plugin_name'],
        $ir['metadata']['version'], $fileHash);

    // Store IR
    $irJson = json_encode($ir, JSON_UNESCAPED_SLASHES);
    $store->storeIR($pluginId, $irJson);

    // Start task
    $taskId = $store->startTask($pluginId, 'extract');

    // Insert anomaly findings
    $anomalyCount = $store->insertAnomalies($pluginId, $anomalies);

    // Import Semgrep findings if report exists
    $semgrepPath = "{$reportsDir}/{$slug}-semgrep.json";
    $semgrepCount = $store->importSemgrepFindings($pluginId, $semgrepPath);

    // Import Progpilot findings if report exists
    $progpilotPath = "{$reportsDir}/{$slug}-progpilot.json";
    $progpilotCount = $store->importProgpilotFindings($pluginId, $progpilotPath);

    // Complete task
    $totalMs = (int)((microtime(true) - $startTime) * 1000);
    $store->completeTask($taskId, $totalMs);
    $store->updatePluginStatus($pluginId, 'extracted');

    // Record metrics
    $store->recordMetric($pluginId, 'extract', 'time_ms', $extractMs);
    $store->recordMetric($pluginId, 'extract', 'entry_points', count($ir['entry_points']));
    $store->recordMetric($pluginId, 'extract', 'anomalies', count($anomalies));
    $store->recordMetric($pluginId, 'extract', 'semgrep_findings', $semgrepCount);
    $store->recordMetric($pluginId, 'extract', 'progpilot_findings', $progpilotCount);
    $store->recordMetric($pluginId, 'extract', 'files_analyzed', $ir['metadata']['files_analyzed']);
    $store->recordMetric($pluginId, 'extract', 'ram_peak_mb', memory_get_peak_usage(true) / 1024 / 1024);

    if (!$quiet) {
        fwrite(STDERR, "    Stored: {$anomalyCount} anomalies + {$semgrepCount} semgrep + {$progpilotCount} progpilot\n");
        fwrite(STDERR, "    Total: {$totalMs}ms | RAM: " . round(memory_get_peak_usage(true) / 1024 / 1024, 1) . "MB\n");
        fwrite(STDERR, "[+] Done: {$slug}\n");
    }

} catch (\Throwable $e) {
    fwrite(STDERR, "[!] Store error: {$e->getMessage()}\n");
    // Still output IR even if store fails
}

// --- Output ---
if ($outputJson) {
    echo json_encode($ir, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
}

// Save IR to reports dir
if (!is_dir($reportsDir)) mkdir($reportsDir, 0755, true);
file_put_contents("{$reportsDir}/{$slug}-ir.json",
    json_encode($ir, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));

exit(0);

// --- Helper functions ---

function computeExtractorHash(): string
{
    $root = dirname(__DIR__) . '/src/Extractor';
    if (!is_dir($root)) return 'noextractor';
    $parts = [];
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $file) {
        if ($file->isFile() && str_ends_with($file->getFilename(), '.php')) {
            $parts[] = $file->getPathname() . ':' . md5_file($file->getPathname());
        }
    }
    sort($parts);
    return substr(md5(implode('|', $parts)), 0, 12);
}

function parseArgs(array $argv): array
{
    $result = [];
    $positional = 0;
    for ($i = 1; $i < count($argv); $i++) {
        $arg = $argv[$i];
        if (str_starts_with($arg, '--db=')) {
            $result['db'] = substr($arg, 5);
        } elseif ($arg === '--json') {
            $result['json'] = true;
        } elseif ($arg === '--quiet' || $arg === '-q') {
            $result['quiet'] = true;
        } elseif ($arg === '--force') {
            $result['force'] = true;
        } elseif (!str_starts_with($arg, '-')) {
            if ($positional === 0) $result['plugin_dir'] = $arg;
            $positional++;
        }
    }
    return $result;
}

function computePluginHash(string $dir): string
{
    $ctx = hash_init('sha256');
    $iterator = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($dir, RecursiveDirectoryIterator::SKIP_DOTS),
        RecursiveIteratorIterator::LEAVES_ONLY
    );
    $files = [];
    foreach ($iterator as $file) {
        if ($file->getExtension() === 'php') {
            $files[] = $file->getPathname();
        }
    }
    sort($files); // Deterministic order
    foreach ($files as $f) {
        hash_update($ctx, $f . ':' . filesize($f) . ':' . filemtime($f));
    }
    return hash_final($ctx);
}
