<?php
declare(strict_types=1);

namespace WPAudit\Store;

/**
 * SQLiteStore: persistent storage for plugins, findings, tasks, metrics.
 */
class SQLiteStore
{
    private \PDO $db;

    public function __construct(string $dbPath)
    {
        $dir = dirname($dbPath);
        if (!is_dir($dir)) mkdir($dir, 0755, true);

        $this->db = new \PDO("sqlite:{$dbPath}", null, null, [
            \PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION,
            \PDO::ATTR_DEFAULT_FETCH_MODE => \PDO::FETCH_ASSOC,
        ]);
        $this->db->exec('PRAGMA journal_mode=WAL');
        $this->db->exec('PRAGMA foreign_keys=ON');
        $this->initSchema();
    }

    private function initSchema(): void
    {
        $this->db->exec('
            CREATE TABLE IF NOT EXISTS plugins (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                slug TEXT UNIQUE NOT NULL,
                name TEXT,
                version TEXT,
                active_installs TEXT,
                ir_json TEXT,
                file_hash TEXT,
                status TEXT DEFAULT "pending",
                extracted_at DATETIME,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            );

            CREATE TABLE IF NOT EXISTS findings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                plugin_id INTEGER NOT NULL,
                phase TEXT NOT NULL,
                rule_id TEXT,
                type TEXT NOT NULL,
                severity TEXT,
                cwe_id TEXT,
                description TEXT NOT NULL,
                entry_point_id TEXT,
                evidence_json TEXT,
                status TEXT DEFAULT "open",
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY(plugin_id) REFERENCES plugins(id)
            );

            CREATE TABLE IF NOT EXISTS tasks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                plugin_id INTEGER NOT NULL,
                phase TEXT NOT NULL,
                status TEXT DEFAULT "pending",
                started_at DATETIME,
                completed_at DATETIME,
                duration_ms INTEGER,
                error_message TEXT,
                FOREIGN KEY(plugin_id) REFERENCES plugins(id)
            );

            CREATE TABLE IF NOT EXISTS metrics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                plugin_id INTEGER,
                phase TEXT,
                metric_name TEXT NOT NULL,
                metric_value REAL NOT NULL,
                recorded_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY(plugin_id) REFERENCES plugins(id)
            );

            CREATE INDEX IF NOT EXISTS idx_findings_plugin ON findings(plugin_id);
            CREATE INDEX IF NOT EXISTS idx_findings_phase ON findings(phase);
            CREATE INDEX IF NOT EXISTS idx_findings_severity ON findings(severity);
            CREATE INDEX IF NOT EXISTS idx_plugins_slug ON plugins(slug);
            CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
        ');

        // Migration: add file_hash column if old database doesn't have it
        try {
            $this->db->exec('ALTER TABLE plugins ADD COLUMN file_hash TEXT');
        } catch (\PDOException $e) {
            // Column already exists — ignore "duplicate column name" error
        }
    }

    // --- Plugin operations ---

    public function upsertPlugin(string $slug, ?string $name, ?string $version, ?string $fileHash): int
    {
        $stmt = $this->db->prepare('
            INSERT INTO plugins (slug, name, version, file_hash, status) VALUES (?, ?, ?, ?, "pending")
            ON CONFLICT(slug) DO UPDATE SET name=?, version=?, file_hash=?, status="pending"
        ');
        $stmt->execute([$slug, $name, $version, $fileHash, $name, $version, $fileHash]);
        return (int)$this->db->lastInsertId() ?: $this->getPluginId($slug);
    }

    public function getPluginId(string $slug): ?int
    {
        $stmt = $this->db->prepare('SELECT id FROM plugins WHERE slug = ?');
        $stmt->execute([$slug]);
        $row = $stmt->fetch();
        return $row ? (int)$row['id'] : null;
    }

    public function updatePluginStatus(int $pluginId, string $status): void
    {
        $stmt = $this->db->prepare('UPDATE plugins SET status = ?, extracted_at = CURRENT_TIMESTAMP WHERE id = ?');
        $stmt->execute([$status, $pluginId]);
    }

    public function storeIR(int $pluginId, string $irJson): void
    {
        $stmt = $this->db->prepare('UPDATE plugins SET ir_json = ? WHERE id = ?');
        $stmt->execute([$irJson, $pluginId]);
    }

    public function getPluginHash(string $slug): ?string
    {
        $stmt = $this->db->prepare('SELECT file_hash FROM plugins WHERE slug = ?');
        $stmt->execute([$slug]);
        $row = $stmt->fetch();
        return $row['file_hash'] ?? null;
    }

    // --- Finding operations ---

    public function insertFinding(int $pluginId, string $phase, ?string $ruleId,
                                   string $type, string $severity, ?string $cwe,
                                   string $description, ?string $epId, ?array $evidence): int
    {
        $stmt = $this->db->prepare('
            INSERT INTO findings (plugin_id, phase, rule_id, type, severity, cwe_id, description, entry_point_id, evidence_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ');
        $stmt->execute([
            $pluginId, $phase, $ruleId, $type, $severity, $cwe,
            $description, $epId, $evidence ? json_encode($evidence) : null,
        ]);
        return (int)$this->db->lastInsertId();
    }

    public function insertAnomalies(int $pluginId, array $anomalies): int
    {
        $count = 0;
        foreach ($anomalies as $a) {
            $this->insertFinding($pluginId, 'static_rule', $a['rule_id'],
                $a['type'], $a['severity'], $a['cwe_id'],
                $a['description'], $a['entry_point_id'],
                $a['evidence'] ?? null);
            $count++;
        }
        return $count;
    }

    /**
     * Import Semgrep JSON findings into SQLite.
     */
    public function importSemgrepFindings(int $pluginId, string $jsonPath): int
    {
        if (!file_exists($jsonPath)) return 0;
        $data = json_decode(file_get_contents($jsonPath), true);
        if (!$data || !isset($data['results'])) return 0;

        $count = 0;
        foreach ($data['results'] as $r) {
            $ruleId = $r['check_id'] ?? 'unknown';
            $severity = strtolower($r['extra']['severity'] ?? 'warning');
            $cwe = $r['extra']['metadata']['cwe'][0] ?? null;
            $message = $r['extra']['message'] ?? '';
            $file = $r['path'] ?? '';
            $line = $r['start']['line'] ?? 0;

            $this->insertFinding($pluginId, 'semgrep', $ruleId,
                'semgrep_finding', $severity, $cwe, $message, null,
                ['file' => $file, 'line' => $line]);
            $count++;
        }
        return $count;
    }

    /**
     * Import Progpilot JSON findings into SQLite.
     */
    public function importProgpilotFindings(int $pluginId, string $jsonPath): int
    {
        if (!file_exists($jsonPath)) return 0;
        $data = json_decode(file_get_contents($jsonPath), true);
        if (!$data || !is_array($data)) return 0;

        $count = 0;
        foreach ($data as $r) {
            $vulnName = $r['vuln_name'] ?? 'unknown';
            $source = $r['source_name'] ?? '?';
            $sink = $r['sink_name'] ?? '?';
            $file = $r['source_file'] ?? '';
            $line = $r['source_line'] ?? 0;

            $this->insertFinding($pluginId, 'progpilot', null,
                $vulnName, 'warning', null,
                "{$vulnName}: {$source} → {$sink}", null,
                ['file' => $file, 'line' => $line]);
            $count++;
        }
        return $count;
    }

    // --- Task operations ---

    public function startTask(int $pluginId, string $phase): int
    {
        $stmt = $this->db->prepare('
            INSERT INTO tasks (plugin_id, phase, status, started_at) VALUES (?, ?, "running", CURRENT_TIMESTAMP)
        ');
        $stmt->execute([$pluginId, $phase]);
        return (int)$this->db->lastInsertId();
    }

    public function completeTask(int $taskId, int $durationMs, ?string $error = null): void
    {
        $status = $error ? 'error' : 'done';
        $stmt = $this->db->prepare('
            UPDATE tasks SET status = ?, completed_at = CURRENT_TIMESTAMP, duration_ms = ?, error_message = ? WHERE id = ?
        ');
        $stmt->execute([$status, $durationMs, $error, $taskId]);
    }

    // --- Metrics ---

    public function recordMetric(int $pluginId, string $phase, string $name, float $value): void
    {
        $stmt = $this->db->prepare('
            INSERT INTO metrics (plugin_id, phase, metric_name, metric_value) VALUES (?, ?, ?, ?)
        ');
        $stmt->execute([$pluginId, $phase, $name, $value]);
    }

    // --- Query helpers ---

    public function getFindings(int $pluginId, ?string $phase = null): array
    {
        $sql = 'SELECT * FROM findings WHERE plugin_id = ?';
        $params = [$pluginId];
        if ($phase) {
            $sql .= ' AND phase = ?';
            $params[] = $phase;
        }
        $sql .= ' ORDER BY CASE severity WHEN "critical" THEN 1 WHEN "high" THEN 2 WHEN "medium" THEN 3 WHEN "warning" THEN 4 ELSE 5 END';
        $stmt = $this->db->prepare($sql);
        $stmt->execute($params);
        return $stmt->fetchAll();
    }

    public function getSummary(): array
    {
        $stmt = $this->db->query('
            SELECT p.slug, p.status, p.version,
                   COUNT(f.id) as finding_count,
                   SUM(CASE WHEN f.severity = "critical" THEN 1 ELSE 0 END) as critical_count,
                   SUM(CASE WHEN f.severity = "high" THEN 1 ELSE 0 END) as high_count
            FROM plugins p
            LEFT JOIN findings f ON f.plugin_id = p.id
            GROUP BY p.id
            ORDER BY critical_count DESC, high_count DESC
        ');
        return $stmt->fetchAll();
    }

    public function getMetricsSummary(): array
    {
        $stmt = $this->db->query('
            SELECT phase, metric_name, 
                   COUNT(*) as count,
                   AVG(metric_value) as avg_val,
                   MAX(metric_value) as max_val,
                   MIN(metric_value) as min_val
            FROM metrics
            GROUP BY phase, metric_name
            ORDER BY phase, metric_name
        ');
        return $stmt->fetchAll();
    }

    public function getPDO(): \PDO { return $this->db; }
}
