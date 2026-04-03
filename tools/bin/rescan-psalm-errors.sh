#!/bin/bash
# rescan-psalm-errors.sh - Re-run Psalm only for plugins currently in error/timeout state.
#
# Usage:
#   bash tools/bin/rescan-psalm-errors.sh [threads] [mode]
#
# Args:
#   threads : parallel jobs, default 2
#   mode    : error|error_timeout, default error

set -euo pipefail

THREADS="${1:-2}"
MODE="${2:-error}"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/bin/report-paths.sh"
resolve_report_dirs "${ROOT_DIR}/reports"
ensure_report_dirs
PLUGINS="${ROOT_DIR}/plugins"

if [ ! -d "$REPORTS_DIR" ] || [ ! -d "$PLUGINS" ]; then
    echo "[!] Missing reports/ or plugins/ directory under workspace root"
    exit 1
fi

if ! [[ "$THREADS" =~ ^[0-9]+$ ]] || [ "$THREADS" -lt 1 ]; then
    echo "[!] Invalid threads: $THREADS"
    exit 1
fi

if [ "$MODE" != "error" ] && [ "$MODE" != "error_timeout" ]; then
    echo "[!] Invalid mode: $MODE (expected: error | error_timeout)"
    exit 1
fi

TARGETS_FILE="$(mktemp /tmp/psalm-rescan-targets-XXXXX.txt)"
trap 'rm -f "$TARGETS_FILE"' EXIT

python3 - "$PHASE1_DIR" "$MODE" > "$TARGETS_FILE" <<'PY'
import glob, json, os, sys
phase1_dir = sys.argv[1]
mode = sys.argv[2]

for path in sorted(glob.glob(os.path.join(phase1_dir, "*-psalm.sarif"))):
    slug = os.path.basename(path)[:-len("-psalm.sarif")]
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            head = f.read(4096).strip()
        if not head.startswith("{"):
            continue
        data = json.loads(head)
        status = data.get("status")
        if status == "error" or (mode == "error_timeout" and status == "timeout"):
            print(slug)
    except Exception:
        # Non-JSON SARIF or malformed state -> ignore.
        pass
PY

COUNT="$(wc -l < "$TARGETS_FILE" | tr -d ' ')"
if [ "$COUNT" = "0" ]; then
    echo "[=] No Psalm targets for mode=$MODE"
    exit 0
fi

echo "=== Psalm Rescan Targets ==="
echo "  mode: $MODE"
echo "  count: $COUNT"
echo "  threads: $THREADS"
echo ""

cat "$TARGETS_FILE" | xargs -P "$THREADS" -I{} bash -lc '
  slug="{}"
  plugin_dir="'"$PLUGINS"'/${slug}"
  if [ ! -d "$plugin_dir" ]; then
    echo "[!] missing plugin dir: $plugin_dir"
    exit 0
  fi
  echo "[*] rescan: $slug"
  bash "'"$SCRIPT_DIR"'/bin/scan-psalm.sh" "$plugin_dir" || true
'

echo ""
echo "=== Psalm Rescan Done ==="
