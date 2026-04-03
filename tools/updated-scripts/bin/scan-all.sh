#!/bin/bash
# scan-all.sh — Full Phase 1 pipeline for a single plugin
# Pipeline: surface-map → semgrep → progpilot (gated) → IR extract + rules → SQLite

set -euo pipefail

PLUGIN_DIR="$1"
if [ -z "${PLUGIN_DIR:-}" ]; then
    echo "Usage: $0 <plugin-directory>"
    exit 1
fi

SLUG=$(basename "$PLUGIN_DIR")
BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "${BIN_DIR}/.." && pwd)"          # updated-scripts/
TOOLS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"         # tools/
ROOT_DIR="$(cd "${TOOLS_DIR}/.." && pwd)"           # project root
REPORTS="${ROOT_DIR}/reports"
DB="${ROOT_DIR}/data/audit.db"

mkdir -p "$REPORTS" "$REPORTS/logs"

# Activate venv for semgrep (deactivates automatically when script ends)
VENV_PATH="${ROOT_DIR}/tmmc/bin/activate"
[ -f "$VENV_PATH" ] && source "$VENV_PATH"

echo "==== PHASE 1: $SLUG ===="

# Step 1: Surface Map
if [ -x "${SCRIPT_DIR}/bin/surface-map.sh" ]; then
    echo "--- [1/4] Surface Map ---"
    bash "${SCRIPT_DIR}/bin/surface-map.sh" "$PLUGIN_DIR" || echo "  [!] surface-map failed"
else
    echo "--- [1/4] Surface Map --- SKIPPED"
fi

# Step 2: Semgrep
if [ -x "${SCRIPT_DIR}/bin/scan-semgrep.sh" ]; then
    echo "--- [2/4] Semgrep ---"
    bash "${SCRIPT_DIR}/bin/scan-semgrep.sh" "$PLUGIN_DIR" || echo "  [!] semgrep failed"
else
    echo "--- [2/4] Semgrep --- MISSING"
fi

# Step 3: Progpilot (gated)
echo "--- [3/4] Progpilot ---"
PHP_COUNT=$(find "$PLUGIN_DIR" -name "*.php" -not -path "*/vendor/*" | wc -l)
TOTAL_BYTES=$(find "$PLUGIN_DIR" -name "*.php" -not -path "*/vendor/*" -exec cat {} + 2>/dev/null | wc -c)
MAX_BYTES=5000000

if [ "$PHP_COUNT" -eq 0 ]; then
    echo "  SKIPPED: no PHP files"
elif [ "$TOTAL_BYTES" -gt "$MAX_BYTES" ]; then
    echo "  SKIPPED: too large (${TOTAL_BYTES} bytes)"
elif [ -x "${SCRIPT_DIR}/bin/scan-progpilot.sh" ]; then
    timeout 120 bash "${SCRIPT_DIR}/bin/scan-progpilot.sh" "$PLUGIN_DIR" 2>/dev/null || echo "  [!] progpilot failed/timeout"
else
    echo "  SKIPPED: script not found"
fi

# Step 4: IR Extraction + Deterministic Rules + SQLite
echo "--- [4/4] IR Extract + Rules ---"
if [ -f "${TOOLS_DIR}/vendor/autoload.php" ] && [ -f "${TOOLS_DIR}/bin/extract.php" ]; then
    php "${TOOLS_DIR}/bin/extract.php" "$PLUGIN_DIR" --db="$DB" || echo "  [!] extract failed"
else
    echo "  SKIPPED: run composer install first"
fi

echo "==== DONE: $SLUG ===="
