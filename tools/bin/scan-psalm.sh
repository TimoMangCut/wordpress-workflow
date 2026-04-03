#!/bin/bash
# scan-psalm.sh - Run Psalm taint analysis on a single plugin
# Output: reports/phase1/<slug>-psalm.sarif (SARIF for machine consumption)
# Optional: reports/phase1/<slug>-psalm-taints.dot (taint graph for debugging)
#
# Usage: scan-psalm.sh <plugin-directory> [--debug-graph]
#
# Integration: called by scan-all.sh as Phase 1 step 3 (non-blocking).
# Psalm output is used as corroboration signal in Phase 3 gate.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$(cd "${SELF_DIR}/.." && pwd)"
source "${TOOLS_DIR}/bin/console-ui.sh"

PLUGIN_DIR="${1:-}"
DEBUG_GRAPH=false
if [ "${2:-}" = "--debug-graph" ]; then
    DEBUG_GRAPH=true
fi

if [ -z "$PLUGIN_DIR" ]; then
    echo "Usage: $0 <plugin-directory> [--debug-graph]"
    exit 1
fi

if [ ! -d "$PLUGIN_DIR" ]; then
    log_error_block "Psalm plugin directory not found" \
        "path" "$PLUGIN_DIR"
    exit 1
fi

PLUGIN_DIR="$(cd "$PLUGIN_DIR" && pwd)"

SLUG="$(basename "$PLUGIN_DIR")"
SCRIPT_DIR="${TOOLS_DIR}"      # tools/
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/bin/report-paths.sh"
resolve_report_dirs "${ROOT_DIR}/reports"
ensure_report_dirs
CONFIG_PRIMARY="${SCRIPT_DIR}/config/psalm-wp.xml"
CONFIG_PRIMARY_VENDOR="${SCRIPT_DIR}/config/psalm-wp-with-vendor.xml"
CONFIG_FALLBACK="${SCRIPT_DIR}/config/psalm-wp-fallback.xml"
CONFIG_FALLBACK_VENDOR="${SCRIPT_DIR}/config/psalm-wp-fallback-with-vendor.xml"

PSALM_TIMEOUT_SECONDS="${PSALM_TIMEOUT_SECONDS:-}"
PSALM_TIMEOUT_ADAPTIVE="${PSALM_TIMEOUT_ADAPTIVE:-true}"  # true|false (default true)
PSALM_FALLBACK="${PSALM_FALLBACK:-true}"  # true|false (default true)
PSALM_FALLBACK_POLICY="${PSALM_FALLBACK_POLICY:-all_non_timeout}"  # all_non_timeout|signature
PSALM_THREADS="${PSALM_THREADS:-1}"  # accuracy/stability first
PSALM_VENDOR_RETRY="${PSALM_VENDOR_RETRY:-true}"  # true|false (default true)
PSALM_SKIP_SLUGS="${PSALM_SKIP_SLUGS:-branda-white-labeling}"  # comma/space separated

OUTPUT="${PHASE1_DIR}/${SLUG}-psalm.sarif"
ERR_LOG="${LOGS_DIR}/${SLUG}-psalm.err"
PHP_RUNTIME=""
PSALM_CMD=()
TIMEOUT_CMD=()
TIMEOUT_BACKEND="none"

resolve_php_bin() {
    local candidate

    if [ -n "${PHP_BIN:-}" ]; then
        if [ -x "${PHP_BIN}" ]; then
            echo "${PHP_BIN}"
            return 0
        fi
        if command -v "${PHP_BIN}" >/dev/null 2>&1; then
            command -v "${PHP_BIN}"
            return 0
        fi
    fi

    for candidate in \
        php \
        php8.4 php84 \
        php8.3 php83 \
        php8.2 php82 \
        php8.1 php81 \
        /opt/homebrew/bin/php \
        /usr/local/bin/php \
        /usr/bin/php
    do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done

    return 1
}

resolve_timeout_backend() {
    if [ -n "${TIMEOUT_BIN:-}" ]; then
        if [ -x "${TIMEOUT_BIN}" ]; then
            TIMEOUT_CMD=("${TIMEOUT_BIN}")
            TIMEOUT_BACKEND="custom"
            return 0
        fi
        if command -v "${TIMEOUT_BIN}" >/dev/null 2>&1; then
            TIMEOUT_CMD=("$(command -v "${TIMEOUT_BIN}")")
            TIMEOUT_BACKEND="custom"
            return 0
        fi
    fi

    if command -v timeout >/dev/null 2>&1; then
        TIMEOUT_CMD=("$(command -v timeout)")
        TIMEOUT_BACKEND="timeout"
        return 0
    fi

    if command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_CMD=("$(command -v gtimeout)")
        TIMEOUT_BACKEND="gtimeout"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        TIMEOUT_BACKEND="python3"
        return 0
    fi

    TIMEOUT_BACKEND="none"
    return 1
}

timeout_run() {
    local seconds="$1"
    shift

    case "$TIMEOUT_BACKEND" in
        timeout|gtimeout|custom)
            "${TIMEOUT_CMD[@]}" "$seconds" "$@"
            ;;
        python3)
            python3 - "$seconds" "$@" <<'PY'
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
command = sys.argv[2:]

try:
    completed = subprocess.run(command, timeout=timeout_seconds, check=False)
    sys.exit(completed.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
except FileNotFoundError as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(127)
except PermissionError as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(126)
PY
            ;;
        *)
            log_warn "timeout command not found; running Psalm without timeout guard" >&2
            "$@"
            ;;
    esac
}

is_slug_skipped() {
    local slug="$1"
    local list="$2"
    local normalized item
    normalized="$(echo "$list" | tr ',\t' '  ' | tr -s ' ')"
    for item in $normalized; do
        if [ "$item" = "$slug" ]; then
            return 0
        fi
    done
    return 1
}

if is_slug_skipped "$SLUG" "$PSALM_SKIP_SLUGS"; then
    : > "$ERR_LOG"
    {
        echo "===== [WARN] PSALM SKIP ====="
        echo "skip_incompatible=true"
        echo "skip_reason=psalm_core_populator_crash"
        echo "skip_slug=$SLUG"
        echo "skip_list=$PSALM_SKIP_SLUGS"
    } >> "$ERR_LOG"
    log_warn_block "Psalm skip (known incompatible)" \
        "slug" "$SLUG" \
        "reason" "psalm_core_populator_crash" \
        "log" "$ERR_LOG"
    echo '{"status":"skip_incompatible","reason":"psalm_core_populator_crash","exit_code":0}' > "$OUTPUT"
    exit 0
fi

# Check psalm command
if [ -f "${SCRIPT_DIR}/vendor/bin/psalm" ]; then
    PHP_RUNTIME="$(resolve_php_bin || true)"
    if [ -z "$PHP_RUNTIME" ]; then
        log_error_block "Psalm PHP runtime not found" \
            "slug" "$SLUG" \
            "reason" "php_runtime_not_found" \
            "output" "$OUTPUT"
        echo '{"status":"php_missing","reason":"php_runtime_not_found","exit_code":127}' > "$OUTPUT"
        exit 0
    fi
    PSALM_CMD=("$PHP_RUNTIME" "${SCRIPT_DIR}/vendor/bin/psalm")
elif command -v psalm >/dev/null 2>&1; then
    PSALM_CMD=("$(command -v psalm)")
    PHP_RUNTIME="$(resolve_php_bin || true)"
else
    log_error_block "Psalm binary not installed" \
        "slug" "$SLUG" \
        "reason" "psalm_binary_not_found" \
        "output" "$OUTPUT"
    echo '{"status":"not_installed","reason":"psalm_binary_not_found","exit_code":127}' > "$OUTPUT"
    exit 0
fi

if [ ! -f "$CONFIG_PRIMARY" ]; then
    log_error_block "Psalm config not found" \
        "slug" "$SLUG" \
        "config" "$CONFIG_PRIMARY" \
        "output" "$OUTPUT"
    echo '{"status":"missing_config","reason":"psalm_config_missing","exit_code":1}' > "$OUTPUT"
    exit 0
fi

resolve_timeout_backend || true

log_info "Psalm taint analysis: $SLUG"

# Resolve plugin absolute path once
PLUGIN_ABS="$(cd "$PLUGIN_DIR" && pwd)"

# Preflight marker for SOAP class availability (helps debug SoapFault class-storage crashes).
SOAP_CLASS_AVAILABLE="unknown"
if [ -n "$PHP_RUNTIME" ]; then
    if "$PHP_RUNTIME" -r 'exit(class_exists("SoapFault") ? 0 : 1);' >/dev/null 2>&1; then
        SOAP_CLASS_AVAILABLE="true"
    else
        SOAP_CLASS_AVAILABLE="false"
        log_warn "SoapFault class unavailable in current PHP runtime (ext-soap missing?)"
    fi
else
    SOAP_CLASS_AVAILABLE="php_missing"
fi

# Compute plugin size (PHP LOC) for adaptive timeout.
PLUGIN_PHP_LOC=0
while IFS= read -r -d '' php_file; do
    file_lines="$(wc -l < "$php_file" 2>/dev/null | tr -d '[:space:]' || echo 0)"
    if [[ "$file_lines" =~ ^[0-9]+$ ]]; then
        PLUGIN_PHP_LOC=$((PLUGIN_PHP_LOC + file_lines))
    fi
done < <(find "$PLUGIN_ABS" -type f -name '*.php' -print0 2>/dev/null)

PSALM_TIMEOUT_MODE="default"
PSALM_TIMEOUT_EFFECTIVE="180"

if [ -n "$PSALM_TIMEOUT_SECONDS" ]; then
    if [[ "$PSALM_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] && [ "$PSALM_TIMEOUT_SECONDS" -gt 0 ]; then
        PSALM_TIMEOUT_EFFECTIVE="$PSALM_TIMEOUT_SECONDS"
        PSALM_TIMEOUT_MODE="explicit"
    else
        log_warn "Invalid PSALM_TIMEOUT_SECONDS=$PSALM_TIMEOUT_SECONDS. Falling back to default 180s."
    fi
else
    if [ "$PSALM_TIMEOUT_ADAPTIVE" = "true" ]; then
        PSALM_TIMEOUT_MODE="adaptive"
        if [ "$PLUGIN_PHP_LOC" -ge 20000 ]; then
            PSALM_TIMEOUT_EFFECTIVE="480"
        elif [ "$PLUGIN_PHP_LOC" -ge 8000 ]; then
            PSALM_TIMEOUT_EFFECTIVE="300"
        else
            PSALM_TIMEOUT_EFFECTIVE="180"
        fi
    elif [ "$PSALM_TIMEOUT_ADAPTIVE" = "false" ]; then
        PSALM_TIMEOUT_MODE="default"
    else
        log_warn "Invalid PSALM_TIMEOUT_ADAPTIVE=$PSALM_TIMEOUT_ADAPTIVE. Using default timeout mode."
        PSALM_TIMEOUT_MODE="default"
    fi
fi

mktemp_file() {
    mktemp "${TMPDIR:-/tmp}/$1.XXXXXX"
}

mktemp_report_file() {
    local base report
    base="$(mktemp_file "$1")" || return 1
    report="${base}.sarif"
    mv "$base" "$report"
    printf '%s\n' "$report"
}

TEMP_CONFIG_PRIMARY="$(mktemp_file psalm-wp-primary)"
TEMP_CONFIG_PRIMARY_VENDOR="$(mktemp_file psalm-wp-primary-vendor)"
TEMP_CONFIG_FALLBACK="$(mktemp_file psalm-wp-fallback)"
TEMP_CONFIG_FALLBACK_VENDOR="$(mktemp_file psalm-wp-fallback-vendor)"
PRIMARY_TMP="$(mktemp_report_file "${SLUG}-psalm-primary")"
PRIMARY_VENDOR_TMP="$(mktemp_report_file "${SLUG}-psalm-primary-vendor")"
FALLBACK_TMP="$(mktemp_report_file "${SLUG}-psalm-fallback")"
FALLBACK_VENDOR_TMP="$(mktemp_report_file "${SLUG}-psalm-fallback-vendor")"
PRIMARY_ERR="$(mktemp_file psalm-primary)"
PRIMARY_OUT="$(mktemp_file psalm-primary-out)"
PRIMARY_VENDOR_ERR="$(mktemp_file psalm-primary-vendor)"
PRIMARY_VENDOR_OUT="$(mktemp_file psalm-primary-vendor-out)"
FALLBACK_ERR="$(mktemp_file psalm-fallback)"
FALLBACK_OUT="$(mktemp_file psalm-fallback-out)"
FALLBACK_VENDOR_ERR="$(mktemp_file psalm-fallback-vendor)"
FALLBACK_VENDOR_OUT="$(mktemp_file psalm-fallback-vendor-out)"
USED_CONFIG=""

cleanup() {
    rm -f "$TEMP_CONFIG_PRIMARY" "$TEMP_CONFIG_PRIMARY_VENDOR" "$TEMP_CONFIG_FALLBACK" "$TEMP_CONFIG_FALLBACK_VENDOR" \
        "$PRIMARY_TMP" "$PRIMARY_VENDOR_TMP" "$FALLBACK_TMP" "$FALLBACK_VENDOR_TMP" \
        "$PRIMARY_ERR" "$PRIMARY_OUT" "$PRIMARY_VENDOR_ERR" "$PRIMARY_VENDOR_OUT" \
        "$FALLBACK_ERR" "$FALLBACK_OUT" "$FALLBACK_VENDOR_ERR" "$FALLBACK_VENDOR_OUT"
}
trap cleanup EXIT

sed "s|__PLUGIN_DIR__|${PLUGIN_ABS}|g" "$CONFIG_PRIMARY" > "$TEMP_CONFIG_PRIMARY"
if [ -f "$CONFIG_PRIMARY_VENDOR" ]; then
    sed "s|__PLUGIN_DIR__|${PLUGIN_ABS}|g" "$CONFIG_PRIMARY_VENDOR" > "$TEMP_CONFIG_PRIMARY_VENDOR"
fi
if [ -f "$CONFIG_FALLBACK" ]; then
    sed "s|__PLUGIN_DIR__|${PLUGIN_ABS}|g" "$CONFIG_FALLBACK" > "$TEMP_CONFIG_FALLBACK"
fi
if [ -f "$CONFIG_FALLBACK_VENDOR" ]; then
    sed "s|__PLUGIN_DIR__|${PLUGIN_ABS}|g" "$CONFIG_FALLBACK_VENDOR" > "$TEMP_CONFIG_FALLBACK_VENDOR"
fi

write_error_status() {
    local rc="$1"
    local reason="${2:-analysis_failed}"
    echo "{\"status\":\"error\",\"reason\":\"${reason}\",\"exit_code\":${rc}}" > "$OUTPUT"
}

write_timeout_status() {
    local reason="${1:-analysis_timeout}"
    echo "{\"status\":\"timeout\",\"reason\":\"${reason}\",\"timeout_seconds\":${PSALM_TIMEOUT_EFFECTIVE},\"exit_code\":124}" > "$OUTPUT"
}

write_no_output_status() {
    local rc="$1"
    local reason="${2:-missing_report_output}"
    echo "{\"status\":\"no_output\",\"reason\":\"${reason}\",\"exit_code\":${rc}}" > "$OUTPUT"
}

run_psalm() {
    local config_file="$1"
    local report_tmp="$2"
    local err_file="$3"
    local out_file="$4"
    (cd "$SCRIPT_DIR" && timeout_run "${PSALM_TIMEOUT_EFFECTIVE}" "${PSALM_CMD[@]}" \
        --taint-analysis \
        --config="$config_file" \
        --report="$report_tmp" \
        --threads="${PSALM_THREADS}" \
        --no-cache \
        --no-progress \
        >"$out_file" \
        2>"$err_file")
    local rc=$?
    return "$rc"
}

is_wp_plugin_crash_signature() {
    local err_file="$1"
    # Signature confirmed in user logs for humanmade/psalm-plugin-wordpress crash.
    grep -Eq "HookNodeVisitor->enterNode|toString\(\) on null|PsalmWordPress\\\\Plugin\.php|Unsupported dynamic hook name" "$err_file"
}

is_storage_crash_signature() {
    local err_file="$1"
    # Psalm core crash signatures where adding plugin vendor scope may recover analysis.
    grep -Eq "Could not get class storage for|ClassLikeStorageProvider|ClassLikeStorageCacheProvider|Populator\.php|DocComment\.php|Undefined array key 1" "$err_file"
}

extract_primary_error_class() {
    local err_file="$1"
    local klass=""
    if grep -q "Psalm has detected issues in your platform" "$err_file"; then
        echo "platform_requirements"
        return
    fi
    klass="$(grep -Eom1 '([A-Za-z_\\]+Exception|[A-Za-z_\\]+Error)' "$err_file" || true)"
    if [ -z "$klass" ]; then
        klass="unknown"
    fi
    echo "$klass"
}

finalize_success_from_tmp() {
    local report_tmp="$1"
    local mode="$2"

    if [ ! -f "$report_tmp" ]; then
        return 1
    fi
    mv "$report_tmp" "$OUTPUT"

    log_ok "Psalm output written: $OUTPUT"
    if [ "$mode" = "fallback" ] || [ "$mode" = "fallback_vendor" ]; then
        log_info "Psalm fallback mode used: wp-plugin-disabled"
    elif [ "$mode" = "primary_vendor" ]; then
        log_info "Psalm retry mode used: wp-plugin-enabled + vendor-scan"
    fi

    local finding_count
    finding_count=$(python3 -c "
import json
try:
    d = json.load(open('${OUTPUT}', encoding='utf-8'))
    runs = d.get('runs', []) or []
    if runs:
        print(len(runs[0].get('results', []) or []))
    else:
        print(0)
except Exception:
    print('?')
" 2>/dev/null || echo "?")
    log_info "Psalm findings: $finding_count"
    return 0
}

: > "$ERR_LOG"
{
    echo "===== [INFO] PSALM CONTEXT ====="
    echo "primary_config=$CONFIG_PRIMARY"
    echo "primary_vendor_config=$CONFIG_PRIMARY_VENDOR"
    echo "fallback_config=$CONFIG_FALLBACK"
    echo "fallback_vendor_config=$CONFIG_FALLBACK_VENDOR"
    echo "fallback_policy=$PSALM_FALLBACK_POLICY"
    echo "vendor_retry=$PSALM_VENDOR_RETRY"
    echo "psalm_skip_slugs=$PSALM_SKIP_SLUGS"
    echo "psalm_threads=$PSALM_THREADS"
    echo "soap_class_available=$SOAP_CLASS_AVAILABLE"
    echo "plugin_php_loc=$PLUGIN_PHP_LOC"
    echo "psalm_timeout_mode=$PSALM_TIMEOUT_MODE"
    echo "psalm_timeout_seconds_input=${PSALM_TIMEOUT_SECONDS:-[unset]}"
    echo "psalm_timeout_effective=$PSALM_TIMEOUT_EFFECTIVE"
    echo "psalm_timeout_backend=$TIMEOUT_BACKEND"
} >> "$ERR_LOG"

# 1) Primary run (WP Psalm plugin enabled)
set +e
run_psalm "$TEMP_CONFIG_PRIMARY" "$PRIMARY_TMP" "$PRIMARY_ERR" "$PRIMARY_OUT"
RC_PRIMARY=$?
set -e

{
    echo "===== [INFO] PRIMARY STDOUT ====="
    cat "$PRIMARY_OUT"
    echo "===== [INFO] PRIMARY STDERR ====="
    cat "$PRIMARY_ERR"
} >> "$ERR_LOG"
USED_CONFIG="$TEMP_CONFIG_PRIMARY"

if [ "$RC_PRIMARY" -eq 0 ] || [ "$RC_PRIMARY" -eq 2 ]; then
    if ! finalize_success_from_tmp "$PRIMARY_TMP" "primary"; then
        log_error_block "Psalm primary run produced no SARIF output" \
            "slug" "$SLUG" \
            "exit_code" "$RC_PRIMARY" \
            "log" "$ERR_LOG" \
            "output" "$OUTPUT"
        write_no_output_status "$RC_PRIMARY" "primary_missing_report_output"
        {
            echo "primary_status=no_output"
            echo "primary_exit_code=$RC_PRIMARY"
            echo "fallback_used=false"
            echo "fallback_status=not_attempted"
        } >> "$ERR_LOG"
    else
        {
            echo "primary_status=success"
            echo "primary_exit_code=$RC_PRIMARY"
            echo "fallback_used=false"
            echo "fallback_status=not_needed"
        } >> "$ERR_LOG"
    fi
elif [ "$RC_PRIMARY" -eq 124 ]; then
    log_error_block "Psalm primary run timed out" \
        "slug" "$SLUG" \
        "timeout_seconds" "$PSALM_TIMEOUT_EFFECTIVE" \
        "log" "$ERR_LOG" \
        "output" "$OUTPUT"
    write_timeout_status "primary_timeout"
    {
        echo "primary_status=timeout"
        echo "primary_exit_code=$RC_PRIMARY"
        echo "fallback_used=false"
        echo "fallback_status=disabled_for_timeout"
    } >> "$ERR_LOG"
else
    TRY_FALLBACK=false
    PRIMARY_ERROR_CLASS="$(extract_primary_error_class "$PRIMARY_ERR")"
    TRY_PRIMARY_VENDOR=false
    if [ "$PSALM_FALLBACK" = "true" ]; then
        if [ ! -f "$CONFIG_FALLBACK" ]; then
            log_warn_block "Psalm fallback config missing" \
                "slug" "$SLUG" \
                "config" "$CONFIG_FALLBACK" \
                "log" "$ERR_LOG" | tee -a "$ERR_LOG"
        else
            case "$PSALM_FALLBACK_POLICY" in
                all_non_timeout)
                    TRY_FALLBACK=true
                    ;;
                signature)
                    if is_wp_plugin_crash_signature "$PRIMARY_ERR"; then
                        TRY_FALLBACK=true
                    fi
                    ;;
                *)
                    log_warn_block "Unknown PSALM_FALLBACK_POLICY; defaulting to all_non_timeout" \
                        "slug" "$SLUG" \
                        "policy" "$PSALM_FALLBACK_POLICY" \
                        "log" "$ERR_LOG" | tee -a "$ERR_LOG"
                    TRY_FALLBACK=true
                    ;;
            esac
        fi
    fi

    if [ "$PSALM_VENDOR_RETRY" = "true" ] && [ -s "$TEMP_CONFIG_PRIMARY_VENDOR" ]; then
        if is_storage_crash_signature "$PRIMARY_ERR"; then
            TRY_PRIMARY_VENDOR=true
        fi
    fi

    if [ "$TRY_FALLBACK" = true ]; then
        DONE=false
        RC_PRIMARY_VENDOR=-1
        RC_FALLBACK=-1
        RC_FALLBACK_VENDOR=-1

        {
            echo ""
            echo "===== [ERROR] PRIMARY CRASH DETECTED ====="
            echo "primary_status=error"
            echo "primary_exit_code=$RC_PRIMARY"
            echo "primary_error_class=$PRIMARY_ERROR_CLASS"
            echo "fallback_candidate=true"
            echo "fallback_policy_used=$PSALM_FALLBACK_POLICY"
        } >> "$ERR_LOG"

        if [ "$TRY_PRIMARY_VENDOR" = true ]; then
            log_warn_block "Primary Psalm hit class-storage crash; retrying with WP integration + vendor scope" \
                "slug" "$SLUG" \
                "log" "$ERR_LOG"
            {
                echo "===== [INFO] PRIMARY+VENDOR RUN START ====="
            } >> "$ERR_LOG"

            set +e
            run_psalm "$TEMP_CONFIG_PRIMARY_VENDOR" "$PRIMARY_VENDOR_TMP" "$PRIMARY_VENDOR_ERR" "$PRIMARY_VENDOR_OUT"
            RC_PRIMARY_VENDOR=$?
            set -e
            {
                echo "===== [INFO] PRIMARY+VENDOR STDOUT ====="
                cat "$PRIMARY_VENDOR_OUT"
                echo "===== [INFO] PRIMARY+VENDOR STDERR ====="
                cat "$PRIMARY_VENDOR_ERR"
            } >> "$ERR_LOG"

            if [ "$RC_PRIMARY_VENDOR" -eq 0 ] || [ "$RC_PRIMARY_VENDOR" -eq 2 ]; then
                if finalize_success_from_tmp "$PRIMARY_VENDOR_TMP" "primary_vendor"; then
                    USED_CONFIG="$TEMP_CONFIG_PRIMARY_VENDOR"
                    {
                        echo "primary_vendor_used=true"
                        echo "primary_vendor_status=success"
                        echo "primary_vendor_exit_code=$RC_PRIMARY_VENDOR"
                        echo "fallback_used=false"
                        echo "fallback_status=not_needed_after_primary_vendor"
                    } >> "$ERR_LOG"
                    DONE=true
                else
                    {
                        echo "primary_vendor_used=true"
                        echo "primary_vendor_status=no_output"
                        echo "primary_vendor_exit_code=$RC_PRIMARY_VENDOR"
                    } >> "$ERR_LOG"
                fi
            elif [ "$RC_PRIMARY_VENDOR" -eq 124 ]; then
                log_error_block "Psalm primary+vendor run timed out" \
                    "slug" "$SLUG" \
                    "timeout_seconds" "$PSALM_TIMEOUT_EFFECTIVE" \
                    "log" "$ERR_LOG" \
                    "output" "$OUTPUT"
                write_timeout_status "primary_vendor_timeout"
                {
                    echo "primary_vendor_used=true"
                    echo "primary_vendor_status=timeout"
                    echo "primary_vendor_timeout_seconds=${PSALM_TIMEOUT_EFFECTIVE}"
                    echo "fallback_used=false"
                    echo "fallback_status=disabled_for_timeout"
                } >> "$ERR_LOG"
                DONE=true
            else
                {
                    echo "primary_vendor_used=true"
                    echo "primary_vendor_status=error"
                    echo "primary_vendor_exit_code=$RC_PRIMARY_VENDOR"
                } >> "$ERR_LOG"
            fi
        fi

        if [ "$DONE" = false ]; then
            log_warn_block "Primary Psalm failed; retrying fallback config (wp-plugin-disabled)" \
                "slug" "$SLUG" \
                "log" "$ERR_LOG"
            {
                echo "===== [INFO] FALLBACK RUN START ====="
            } >> "$ERR_LOG"

            set +e
            run_psalm "$TEMP_CONFIG_FALLBACK" "$FALLBACK_TMP" "$FALLBACK_ERR" "$FALLBACK_OUT"
            RC_FALLBACK=$?
            set -e
            {
                echo "===== [INFO] FALLBACK STDOUT ====="
                cat "$FALLBACK_OUT"
                echo "===== [INFO] FALLBACK STDERR ====="
                cat "$FALLBACK_ERR"
            } >> "$ERR_LOG"

            if [ "$RC_FALLBACK" -eq 0 ] || [ "$RC_FALLBACK" -eq 2 ]; then
                if finalize_success_from_tmp "$FALLBACK_TMP" "fallback"; then
                    USED_CONFIG="$TEMP_CONFIG_FALLBACK"
                    {
                        echo ""
                        echo "fallback_used=true"
                        echo "fallback_status=success"
                        echo "fallback_exit_code=$RC_FALLBACK"
                    } >> "$ERR_LOG"
                else
                    log_error_block "Psalm fallback produced no SARIF output" \
                        "slug" "$SLUG" \
                        "exit_code" "$RC_FALLBACK" \
                        "log" "$ERR_LOG" \
                        "output" "$OUTPUT"
                    write_no_output_status "$RC_FALLBACK" "fallback_missing_report_output"
                    {
                        echo ""
                        echo "fallback_used=true"
                        echo "fallback_status=no_output"
                        echo "fallback_exit_code=$RC_FALLBACK"
                    } >> "$ERR_LOG"
                fi
            elif [ "$RC_FALLBACK" -eq 124 ]; then
                log_error_block "Psalm fallback run timed out" \
                    "slug" "$SLUG" \
                    "timeout_seconds" "$PSALM_TIMEOUT_EFFECTIVE" \
                    "log" "$ERR_LOG" \
                    "output" "$OUTPUT"
                write_timeout_status "fallback_timeout"
                {
                    echo ""
                    echo "fallback_used=true"
                    echo "fallback_status=timeout"
                    echo "fallback_timeout_seconds=${PSALM_TIMEOUT_EFFECTIVE}"
                } >> "$ERR_LOG"
            else
                TRY_FALLBACK_VENDOR=false
                if [ "$PSALM_VENDOR_RETRY" = "true" ] && [ -s "$TEMP_CONFIG_FALLBACK_VENDOR" ]; then
                    if is_storage_crash_signature "$PRIMARY_ERR" || is_storage_crash_signature "$FALLBACK_ERR"; then
                        TRY_FALLBACK_VENDOR=true
                    fi
                fi

                if [ "$TRY_FALLBACK_VENDOR" = true ]; then
                    log_warn_block "Psalm fallback hit class-storage crash; retrying fallback+vendor" \
                        "slug" "$SLUG" \
                        "log" "$ERR_LOG"
                    {
                        echo "===== [INFO] FALLBACK+VENDOR RUN START ====="
                    } >> "$ERR_LOG"

                    set +e
                    run_psalm "$TEMP_CONFIG_FALLBACK_VENDOR" "$FALLBACK_VENDOR_TMP" "$FALLBACK_VENDOR_ERR" "$FALLBACK_VENDOR_OUT"
                    RC_FALLBACK_VENDOR=$?
                    set -e
                    {
                        echo "===== [INFO] FALLBACK+VENDOR STDOUT ====="
                        cat "$FALLBACK_VENDOR_OUT"
                        echo "===== [INFO] FALLBACK+VENDOR STDERR ====="
                        cat "$FALLBACK_VENDOR_ERR"
                    } >> "$ERR_LOG"

                    if [ "$RC_FALLBACK_VENDOR" -eq 0 ] || [ "$RC_FALLBACK_VENDOR" -eq 2 ]; then
                        if finalize_success_from_tmp "$FALLBACK_VENDOR_TMP" "fallback_vendor"; then
                            USED_CONFIG="$TEMP_CONFIG_FALLBACK_VENDOR"
                            {
                                echo ""
                                echo "fallback_used=true"
                                echo "fallback_status=success_vendor"
                                echo "fallback_exit_code=$RC_FALLBACK_VENDOR"
                            } >> "$ERR_LOG"
                        else
                            log_error_block "Psalm fallback+vendor produced no SARIF output" \
                                "slug" "$SLUG" \
                                "exit_code" "$RC_FALLBACK_VENDOR" \
                                "log" "$ERR_LOG" \
                                "output" "$OUTPUT"
                            write_no_output_status "$RC_FALLBACK_VENDOR" "fallback_vendor_missing_report_output"
                            {
                                echo ""
                                echo "fallback_used=true"
                                echo "fallback_status=no_output_vendor"
                                echo "fallback_exit_code=$RC_FALLBACK_VENDOR"
                            } >> "$ERR_LOG"
                        fi
                    elif [ "$RC_FALLBACK_VENDOR" -eq 124 ]; then
                        log_error_block "Psalm fallback+vendor run timed out" \
                            "slug" "$SLUG" \
                            "timeout_seconds" "$PSALM_TIMEOUT_EFFECTIVE" \
                            "log" "$ERR_LOG" \
                            "output" "$OUTPUT"
                        write_timeout_status "fallback_vendor_timeout"
                        {
                            echo ""
                            echo "fallback_used=true"
                            echo "fallback_status=timeout_vendor"
                            echo "fallback_timeout_seconds=${PSALM_TIMEOUT_EFFECTIVE}"
                        } >> "$ERR_LOG"
                    else
                        log_error_block "Psalm fallback+vendor failed" \
                            "slug" "$SLUG" \
                            "exit_code" "$RC_FALLBACK_VENDOR" \
                            "log" "$ERR_LOG" \
                            "output" "$OUTPUT"
                        write_error_status "$RC_FALLBACK_VENDOR" "fallback_vendor_failed"
                        {
                            echo ""
                            echo "fallback_used=true"
                            echo "fallback_status=error_vendor"
                            echo "fallback_exit_code=$RC_FALLBACK_VENDOR"
                        } >> "$ERR_LOG"
                    fi
                else
                    log_error_block "Psalm fallback failed" \
                        "slug" "$SLUG" \
                        "exit_code" "$RC_FALLBACK" \
                        "log" "$ERR_LOG" \
                        "output" "$OUTPUT"
                    write_error_status "$RC_FALLBACK" "fallback_failed"
                    {
                        echo ""
                        echo "fallback_used=true"
                        echo "fallback_status=error"
                        echo "fallback_exit_code=$RC_FALLBACK"
                    } >> "$ERR_LOG"
                fi
            fi
        fi
    else
        log_error_block "Psalm primary run failed" \
            "slug" "$SLUG" \
            "exit_code" "$RC_PRIMARY" \
            "log" "$ERR_LOG" \
            "output" "$OUTPUT"
        write_error_status "$RC_PRIMARY" "primary_failed"
        {
            echo "primary_status=error"
            echo "primary_exit_code=$RC_PRIMARY"
            echo "primary_error_class=$PRIMARY_ERROR_CLASS"
            echo "fallback_used=false"
            echo "fallback_status=not_triggered"
            echo "fallback_policy_used=$PSALM_FALLBACK_POLICY"
        } >> "$ERR_LOG"
    fi
fi

# Optional taint graph (best-effort; does not affect output status)
if [ "$DEBUG_GRAPH" = true ] && command -v dot >/dev/null 2>&1; then
    DOT_FILE="${PHASE1_DIR}/${SLUG}-psalm-taints.dot"
    SVG_FILE="${PHASE1_DIR}/${SLUG}-psalm-taints.svg"

    if [ -n "$USED_CONFIG" ] && [ -f "$USED_CONFIG" ]; then
        (cd "$SCRIPT_DIR" && timeout_run 120 "${PSALM_CMD[@]}" \
            --taint-analysis \
            --config="$USED_CONFIG" \
            --dump-taint-graph="$DOT_FILE" \
            --no-cache \
            --no-progress \
            2>/dev/null) || true
    fi

    if [ -f "$DOT_FILE" ]; then
        dot -Tsvg -o "$SVG_FILE" "$DOT_FILE" 2>/dev/null && log_info "Taint graph: $SVG_FILE"
    fi
fi
