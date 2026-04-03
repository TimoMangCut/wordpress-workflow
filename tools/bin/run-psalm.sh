#!/bin/bash
# run-psalm.sh - Batch runner for Psalm scan with index range + parallel threads.
#
# Default behavior: run all plugins (full range) from plugins_sorted_numbered.txt
# Features:
#   - List already-generated Psalm outputs
#   - Run by index range
#   - Parallel execution by threads
#
# Usage examples:
#   bash tools/bin/run-psalm.sh
#   bash tools/bin/run-psalm.sh --mode custom
#   bash tools/bin/run-psalm.sh --start-index 100 --end-index 160 --threads 4
#   bash tools/bin/run-psalm.sh --list-done

set -euo pipefail

BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$(cd "${BIN_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${TOOLS_DIR}/.." && pwd)"
source "${TOOLS_DIR}/bin/report-paths.sh"
resolve_report_dirs "${ROOT_DIR}/reports"
ensure_report_dirs

PLUGINS_DIR="${ROOT_DIR}/plugins"
PLUGINS_FILE="${ROOT_DIR}/plugins_sorted_numbered.txt"
SCAN_SCRIPT="${BIN_DIR}/scan-psalm.sh"

START_INDEX=""
END_INDEX=""
THREADS=1
LIST_DONE=false
MODE="auto"  # auto|custom

usage() {
    cat <<'EOF'
Usage:
  run-psalm.sh [--mode auto|custom] [--start-index N] [--end-index M] [--threads K] [--list-done]

Flags:
  --mode M          Run mode: auto|custom (default: auto)
                    auto: run full range by default (or range if provided)
                    custom: list indexes then ask Start/End/Threads interactively
  --start-index N   Start plugin index (from plugins_sorted_numbered.txt)
  --end-index M     End plugin index (from plugins_sorted_numbered.txt)
  --threads K       Parallel workers, default 1
  --list-done       Show existing Psalm outputs and exit
  --interactive     Alias of --mode custom
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --start-index)
            START_INDEX="${2:-}"
            shift 2
            ;;
        --end-index)
            END_INDEX="${2:-}"
            shift 2
            ;;
        --threads)
            THREADS="${2:-}"
            shift 2
            ;;
        --mode)
            MODE="${2:-}"
            shift 2
            ;;
        --interactive)
            MODE="custom"
            shift
            ;;
        --list-done)
            LIST_DONE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[!] Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [ ! -f "$PLUGINS_FILE" ]; then
    echo "[!] Missing plugins list: $PLUGINS_FILE"
    exit 1
fi

if [ ! -f "$SCAN_SCRIPT" ]; then
    echo "[!] Missing scan script: $SCAN_SCRIPT"
    exit 1
fi

if ! [[ "$THREADS" =~ ^[0-9]+$ ]] || [ "$THREADS" -lt 1 ]; then
    echo "[!] Invalid --threads value: $THREADS"
    exit 1
fi

if [[ "$MODE" != "auto" && "$MODE" != "custom" ]]; then
    echo "[!] Invalid --mode value: $MODE (expected: auto|custom)"
    exit 1
fi

if [ -n "$START_INDEX" ] && { ! [[ "$START_INDEX" =~ ^[0-9]+$ ]] || [ "$START_INDEX" -lt 1 ]; }; then
    echo "[!] Invalid --start-index: $START_INDEX"
    exit 1
fi

if [ -n "$END_INDEX" ] && { ! [[ "$END_INDEX" =~ ^[0-9]+$ ]] || [ "$END_INDEX" -lt 1 ]; }; then
    echo "[!] Invalid --end-index: $END_INDEX"
    exit 1
fi

INDEXED_FILE="$(mktemp /tmp/psalm-indexed-XXXXX.txt)"
SELECTED_FILE="$(mktemp /tmp/psalm-selected-XXXXX.txt)"
STATUS_FILE="$(mktemp /tmp/psalm-status-XXXXX.txt)"
trap 'rm -f "$INDEXED_FILE" "$SELECTED_FILE" "$STATUS_FILE"' EXIT

# Parse plugins_sorted_numbered.txt via Python for robust UTF-8 BOM + CRLF handling.
python3 - "$PLUGINS_FILE" "$PLUGINS_DIR" > "$INDEXED_FILE" <<'PY'
import os
import re
import sys

plugins_file = sys.argv[1]
plugins_dir = sys.argv[2]

with open(plugins_file, "r", encoding="utf-8-sig", errors="replace") as f:
    for raw in f:
        line = raw.strip()
        m = re.match(r"^(\d+)\.\s*(.+)$", line)
        if not m:
            continue
        idx = int(m.group(1))
        slug = m.group(2).split(" -- ", 1)[0].strip()
        if not slug:
            continue
        if os.path.isdir(os.path.join(plugins_dir, slug)):
            print(f"{idx}|{slug}")
PY

if [ ! -s "$INDEXED_FILE" ]; then
    echo "[!] No valid plugins parsed from: $PLUGINS_FILE"
    exit 1
fi

sort -t'|' -k1,1n -o "$INDEXED_FILE" "$INDEXED_FILE"

TOTAL_PLUGINS="$(wc -l < "$INDEXED_FILE" | tr -d '[:space:]')"
MIN_INDEX="$(cut -d'|' -f1 "$INDEXED_FILE" | sort -n | head -1)"
MAX_INDEX="$(cut -d'|' -f1 "$INDEXED_FILE" | sort -n | tail -1)"

DONE_INDEXES=()
while IFS='|' read -r idx slug; do
    if [ -f "${PHASE1_DIR}/${slug}-psalm.sarif" ]; then
        DONE_INDEXES+=("$idx")
    fi
done < "$INDEXED_FILE"

done_joined="[none]"
if [ "${#DONE_INDEXES[@]}" -gt 0 ]; then
    done_joined="[${DONE_INDEXES[*]}]"
    done_joined="${done_joined// /,}"
fi

echo "=== Psalm Batch ==="
echo "  Plugins file: $PLUGINS_FILE"
echo "  Available plugins: $TOTAL_PLUGINS"
echo "  Index range: ${MIN_INDEX}..${MAX_INDEX}"
echo "  Existing Psalm outputs: ${#DONE_INDEXES[@]}"
echo "  Done indexes: ${done_joined}"
echo "  Mode: ${MODE}"

if [ "$LIST_DONE" = true ]; then
    exit 0
fi

if [ "$MODE" = "custom" ]; then
    AVAILABLE_INDEX_CSV="$(cut -d'|' -f1 "$INDEXED_FILE" | paste -sd, -)"
    echo "  Indexes: [${AVAILABLE_INDEX_CSV}]"
    while true; do
        read -r -p "Start index: " START_INDEX
        read -r -p "End index: " END_INDEX
        if ! [[ "$START_INDEX" =~ ^[0-9]+$ ]] || ! [[ "$END_INDEX" =~ ^[0-9]+$ ]]; then
            echo "[!] Start/end must be positive integers. Try again."
            continue
        fi
        if [ "$START_INDEX" -gt "$END_INDEX" ]; then
            echo "[!] Start index must be <= end index. Try again."
            continue
        fi
        break
    done
    while true; do
        read -r -p "Threads: " THREADS
        if ! [[ "$THREADS" =~ ^[0-9]+$ ]] || [ "$THREADS" -lt 1 ]; then
            echo "[!] Threads must be a positive integer. Try again."
            continue
        fi
        break
    done
else
    if [ -z "$START_INDEX" ]; then
        START_INDEX="$MIN_INDEX"
    fi
    if [ -z "$END_INDEX" ]; then
        END_INDEX="$MAX_INDEX"
    fi
fi

if [ "$START_INDEX" -gt "$END_INDEX" ]; then
    echo "[!] Invalid range: start-index ($START_INDEX) > end-index ($END_INDEX)"
    exit 1
fi

awk -F'|' -v s="$START_INDEX" -v e="$END_INDEX" '($1 >= s && $1 <= e) {print $0}' "$INDEXED_FILE" > "$SELECTED_FILE"

SELECTED_COUNT="$(wc -l < "$SELECTED_FILE" | tr -d '[:space:]')"
if [ "$SELECTED_COUNT" = "0" ]; then
    echo "[!] No plugins selected in range ${START_INDEX}..${END_INDEX}"
    exit 1
fi

SELECTED_INDEXES="[$(cut -d'|' -f1 "$SELECTED_FILE" | tr '\n' ',' | sed 's/,$//')]"

echo "  Selected range: ${START_INDEX}..${END_INDEX}"
echo "  Selected count: ${SELECTED_COUNT}"
echo "  Selected indexes: ${SELECTED_INDEXES}"
echo "  Threads: ${THREADS}"
echo ""

cut -d'|' -f2 "$SELECTED_FILE" | xargs -P "$THREADS" -I{} bash -lc '
  slug="$1"
  plugins_dir="$2"
  scan_script="$3"
  phase1_dir="$4"
  status_file="$5"
  plugin_dir="${plugins_dir}/${slug}"
  output_file="${phase1_dir}/${slug}-psalm.sarif"
  if [ ! -d "$plugin_dir" ]; then
      echo "[!] missing plugin dir: $plugin_dir"
      echo "error|${slug}|missing_plugin_dir" >> "$status_file"
      exit 0
  fi
  echo "=== Psalm: ${slug} ==="
  if bash "$scan_script" "$plugin_dir"; then
      class="$(python3 - "$output_file" <<'PY'
import json
import os
import sys

path = sys.argv[1]
if not os.path.exists(path):
    print("error|missing_output")
    raise SystemExit(0)

try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        data = json.load(f)
except Exception:
    print("error|invalid_json")
    raise SystemExit(0)

if isinstance(data, dict) and "status" in data:
    status = str(data.get("status", "")).strip()
    if status == "skip_incompatible":
        print("skip|skip_incompatible")
    elif status in {"timeout"}:
        print("timeout|timeout")
    elif status in {"not_installed"}:
        print("skip|not_installed")
    else:
        print(f"error|{status or 'unknown_status'}")
else:
    runs = data.get("runs", []) if isinstance(data, dict) else []
    if isinstance(runs, list):
        print("ok|sarif")
    else:
        print("error|unexpected_shape")
PY
)"
      kind="${class%%|*}"
      reason="${class#*|}"
      echo "${kind}|${slug}|${reason}" >> "$status_file"
  else
      echo "error|${slug}|scan_script_nonzero" >> "$status_file"
  fi
' _ {} "$PLUGINS_DIR" "$SCAN_SCRIPT" "$PHASE1_DIR" "$STATUS_FILE"

OK_COUNT="$(grep -c '^ok|' "$STATUS_FILE" 2>/dev/null || true)"
SKIP_COUNT="$(grep -c '^skip|' "$STATUS_FILE" 2>/dev/null || true)"
TIMEOUT_COUNT="$(grep -c '^timeout|' "$STATUS_FILE" 2>/dev/null || true)"
ERROR_COUNT="$(grep -c '^error|' "$STATUS_FILE" 2>/dev/null || true)"

echo ""
echo "=== Psalm Batch Complete ==="
echo "  Considered: ${SELECTED_COUNT}"
echo "  SARIF OK:  ${OK_COUNT}"
echo "  Skipped:   ${SKIP_COUNT}"
echo "  Timeout:   ${TIMEOUT_COUNT}"
echo "  Error:     ${ERROR_COUNT}"
