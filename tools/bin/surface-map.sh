#!/bin/bash
# surface-map.sh — Quick grep-based surface map for WordPress plugin

set -e

PLUGIN_DIR="$1"
if [ -z "$PLUGIN_DIR" ]; then
    echo "Usage: $0 <plugin-directory>"
    exit 1
fi

SLUG=$(basename "$PLUGIN_DIR")
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/bin/report-paths.sh"
resolve_report_dirs "${ROOT_DIR}/reports"
ensure_report_dirs
OUTPUT="${PHASE1_DIR}/${SLUG}-surface.txt"

echo "=== SURFACE MAP: $SLUG ===" > "$OUTPUT"
echo "Generated: $(date -Iseconds)" >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo "--- ENTRY POINTS ---" >> "$OUTPUT"
echo "[REST routes]" >> "$OUTPUT"
grep -rn 'register_rest_route' "$PLUGIN_DIR" --include="*.php" >> "$OUTPUT" 2>/dev/null || true
echo "[AJAX handlers]" >> "$OUTPUT"
grep -rn 'wp_ajax_\|wp_ajax_nopriv_' "$PLUGIN_DIR" --include="*.php" >> "$OUTPUT" 2>/dev/null || true
echo "[Admin POST]" >> "$OUTPUT"
grep -rn 'admin_post_\|admin_post_nopriv_' "$PLUGIN_DIR" --include="*.php" >> "$OUTPUT" 2>/dev/null || true
echo "[Shortcodes + Blocks]" >> "$OUTPUT"
grep -rn 'add_shortcode\|register_block_type' "$PLUGIN_DIR" --include="*.php" >> "$OUTPUT" 2>/dev/null || true

echo "" >> "$OUTPUT"
echo "--- SECURITY GUARDS ---" >> "$OUTPUT"
grep -rn 'current_user_can\|check_ajax_referer\|wp_verify_nonce\|permission_callback' "$PLUGIN_DIR" --include="*.php" >> "$OUTPUT" 2>/dev/null || true

echo "" >> "$OUTPUT"
echo "--- SINKS ---" >> "$OUTPUT"
echo "[SQL]" >> "$OUTPUT"
grep -rn 'wpdb.*query\|->get_results\|->get_var\|->get_col\|->get_row' "$PLUGIN_DIR" --include="*.php" >> "$OUTPUT" 2>/dev/null || true
echo "[File ops]" >> "$OUTPUT"
grep -rn 'file_put_contents\|file_get_contents\|fopen\|unlink\|wp_handle_upload' "$PLUGIN_DIR" --include="*.php" >> "$OUTPUT" 2>/dev/null || true

echo "" >> "$OUTPUT"
echo "--- REST JSON (magic quote bypass) ---" >> "$OUTPUT"
grep -rn 'get_json_params\|get_param\|get_body' "$PLUGIN_DIR" --include="*.php" >> "$OUTPUT" 2>/dev/null || true

echo "[+] Surface map: $OUTPUT"
