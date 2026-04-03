#!/bin/bash
# reimport-semgrep.sh - Re-import Semgrep findings into SQLite via extract --force.
# Usage: reimport-semgrep.sh [plugins-dir] [start-index] [end-index]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/bin/report-paths.sh"
resolve_report_dirs "${ROOT_DIR}/reports"
ensure_report_dirs
PLUGINS_DIR="${1:-${ROOT_DIR}/plugins}"
START_INDEX="${2:-1}"
END_INDEX="${3:-1000000}"

DB="${ROOT_DIR}/data/audit.db"
EXTRACT="${SCRIPT_DIR}/bin/extract.php"

if [ ! -d "$PLUGINS_DIR" ]; then
    echo "Usage: $0 [plugins-directory] [start-index] [end-index]"
    exit 1
fi

if [ ! -f "$EXTRACT" ] || [ ! -f "${SCRIPT_DIR}/vendor/autoload.php" ]; then
    echo "[-] Missing extractor dependencies. Run: cd tools && composer install"
    exit 1
fi

TOTAL=0
DONE=0
SKIPPED=0
FAILED=0
INDEX=0

echo "=== REIMPORT SEMGREP TO DB ==="
echo "  Plugins dir: $PLUGINS_DIR"
echo "  Reports dir: $REPORTS_DIR"
echo "  Database:    $DB"
echo "  Range:       $START_INDEX..$END_INDEX"
echo ""

for dir in "$PLUGINS_DIR"/*/; do
    [ ! -d "$dir" ] && continue
    slug=$(basename "$dir")

    case "$slug" in .*|node_modules|vendor|__*|.github) continue ;; esac

    INDEX=$((INDEX + 1))
    if [ "$INDEX" -lt "$START_INDEX" ] || [ "$INDEX" -gt "$END_INDEX" ]; then
        continue
    fi

    TOTAL=$((TOTAL + 1))
    semgrep_json="${PHASE1_DIR}/${slug}-semgrep.json"

    if [ ! -s "$semgrep_json" ]; then
        echo "[SKIP] $slug (missing/empty semgrep report)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Avoid duplicate findings/metrics/tasks when re-running extract --force.
    php -r '
        $dbPath = $argv[1];
        $slug = $argv[2];
        $db = new PDO("sqlite:$dbPath", null, null, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION
        ]);
        $stmt = $db->prepare("SELECT id FROM plugins WHERE slug = ?");
        $stmt->execute([$slug]);
        $pluginId = $stmt->fetchColumn();
        if ($pluginId) {
            $db->prepare("DELETE FROM findings WHERE plugin_id = ? AND phase IN (\"static_rule\", \"semgrep\", \"progpilot\")")->execute([$pluginId]);
            $db->prepare("DELETE FROM tasks WHERE plugin_id = ? AND phase = \"extract\"")->execute([$pluginId]);
            $db->prepare("DELETE FROM metrics WHERE plugin_id = ? AND phase = \"extract\"")->execute([$pluginId]);
        }
    ' "$DB" "$slug"

    if php "$EXTRACT" "$dir" --db="$DB" --force --quiet; then
        echo "[DONE] $slug"
        DONE=$((DONE + 1))
    else
        echo "[FAIL] $slug"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "=== REIMPORT COMPLETE ==="
echo "  Considered: $TOTAL"
echo "  Imported:   $DONE"
echo "  Skipped:    $SKIPPED"
echo "  Failed:     $FAILED"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi

exit 0
