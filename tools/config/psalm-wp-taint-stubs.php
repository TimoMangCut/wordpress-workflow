<?php

namespace Monolog {
    /**
     * Minimal stub for prefixed/unprefixed Monolog references.
     * This only exists to unblock class-storage resolution in Psalm.
     */
    class Logger {
        public function __construct(string $name, array $handlers = [], array $processors = []) {}
        public function debug(string $message, array $context = []): void {}
        public function info(string $message, array $context = []): void {}
        public function warning(string $message, array $context = []): void {}
        public function error(string $message, array $context = []): void {}
        public function critical(string $message, array $context = []): void {}
    }
}

namespace {
/**
 * WP-AUDIT-SYSTEM — Psalm Taint Stubs for WordPress Security Functions
 *
 * These stubs teach Psalm's taint engine about WordPress-specific:
 * - Taint sources (user input entry points)
 * - Taint sinks (dangerous operations)
 * - Taint escapes/sanitizers (safe transformations)
 *
 * @psalm-file-stub
 */

// =============================================================================
// TAINT SOURCES — User input entry points
// =============================================================================

// WP_REST_Request methods — REST data bypasses wp_magic_quotes()
// These are the #1 WordPress SQLi/XSS vector
//
// NOTE on class naming:
// We use the ACTUAL WordPress class names (WP_REST_Request, wpdb) here.
// wordpress-stubs defines these classes without taint annotations.
// Psalm merges stub definitions — the LAST loaded stub file wins for annotations.
// psalm-wp.xml loads this file AFTER wordpress-stubs, so our @psalm-taint-source
// annotations will be applied to the actual classes.
//
// If Psalm complains about duplicate definitions, try:
//   1) Remove the class from this file and rely on plugin annotations instead
//   2) Or use @psalm-taint-source on the calling code via inline annotations

/**
 * WordPress REST Request — all data methods are taint sources.
 * REST data is UNSLASHED and bypasses wp_magic_quotes().
 */
class WP_REST_Request {
    /**
     * @psalm-taint-source input
     * @return string
     */
    public function get_param(string $key): string { return ''; }

    /**
     * @psalm-taint-source input
     * @return array
     */
    public function get_params(): array { return []; }

    /**
     * @psalm-taint-source input
     * @return array
     */
    public function get_json_params(): array { return []; }

    /**
     * @psalm-taint-source input
     * @return string
     */
    public function get_body(): string { return ''; }

    /**
     * @psalm-taint-source input
     * @return array
     */
    public function get_body_params(): array { return []; }

    /**
     * @psalm-taint-source input
     * @return array
     */
    public function get_query_params(): array { return []; }

    /**
     * @psalm-taint-source input
     * @return array
     */
    public function get_url_params(): array { return []; }

    /**
     * @psalm-taint-source input
     * @return string|null
     */
    public function get_header(string $key): ?string { return ''; }

    /**
     * @psalm-taint-source input
     * @return array
     */
    public function get_file_params(): array { return []; }
}

/**
 * WordPress database abstraction — query methods are SQL taint sinks,
 * prepare() is a taint escape.
 */
class wpdb {
    /**
     * @psalm-taint-sink sql $query
     */
    public function query(string $query) {}

    /**
     * @psalm-taint-sink sql $query
     */
    public function get_var(string $query = null, int $x = 0, int $y = 0) {}

    /**
     * @psalm-taint-sink sql $query
     */
    public function get_row(string $query = null, string $output = 'OBJECT', int $y = 0) {}

    /**
     * @psalm-taint-sink sql $query
     */
    public function get_col(string $query = null, int $x = 0) {}

    /**
     * @psalm-taint-sink sql $query
     */
    public function get_results(string $query = null, string $output = 'OBJECT') {}

    /**
     * @psalm-taint-escape sql
     * @psalm-flow ($query, ...$args) -> return
     */
    public function prepare(string $query, ...$args): string { return ''; }
}


// =============================================================================
// TAINT SINKS — defined in class stubs above (wpdb_TaintStub)
// Additional standalone sinks for built-in PHP functions:
// =============================================================================

/**
 * @psalm-taint-sink html $string
 */
function _wp_echo_sink(string $string): void {}

/**
 * @psalm-taint-sink header $location
 */
function wp_redirect(string $location, int $status = 302, string $x_redirect_by = 'WordPress'): bool { return true; }

/**
 * @psalm-taint-sink header $location
 */
function wp_safe_redirect(string $location, int $status = 302, string $x_redirect_by = 'WordPress'): bool { return true; }

/**
 * @psalm-taint-sink shell $command
 */
function _wp_shell_sink(string $command): void {}

/**
 * @psalm-taint-sink sql $data
 */
function _wp_unserialize_sink(string $data): void {}


// =============================================================================
// TAINT ESCAPES — Sanitizers that remove taint
// =============================================================================

// --- SQL escapes ---

/**
 * @psalm-taint-escape sql
 * @psalm-flow ($value) -> return
 */
function esc_sql(string $value): string { return $value; }

// $wpdb->prepare() is the primary SQL sanitizer.
// Stubs should already handle it, but explicit annotation as backup:

// --- HTML/XSS escapes ---

/**
 * @psalm-taint-escape html
 * @psalm-flow ($text) -> return
 */
function esc_html(string $text): string { return $text; }

/**
 * @psalm-taint-escape html
 * @psalm-flow ($text) -> return
 */
function esc_attr(string $text): string { return $text; }

/**
 * @psalm-taint-escape html
 * @psalm-flow ($url) -> return
 */
function esc_url(string $url): string { return $url; }

/**
 * @psalm-taint-escape html
 * @psalm-flow ($text) -> return
 */
function esc_js(string $text): string { return $text; }

/**
 * @psalm-taint-escape html
 * @psalm-flow ($text) -> return
 */
function esc_textarea(string $text): string { return $text; }

/**
 * @psalm-taint-escape html
 * @psalm-flow ($string, $allowed_html, $allowed_protocols) -> return
 */
function wp_kses(string $string, $allowed_html = [], $allowed_protocols = []): string { return $string; }

/**
 * @psalm-taint-escape html
 * @psalm-flow ($data) -> return
 */
function wp_kses_post(string $data): string { return $data; }

// --- Input sanitizers (escape input for storage) ---

/**
 * @psalm-taint-escape html
 * @psalm-taint-escape sql
 * @psalm-flow ($str) -> return
 */
function sanitize_text_field(string $str): string { return $str; }

/**
 * @psalm-taint-escape html
 * @psalm-taint-escape sql
 * @psalm-flow ($str) -> return
 */
function sanitize_textarea_field(string $str): string { return $str; }

/**
 * @psalm-taint-escape html
 * @psalm-flow ($email) -> return
 */
function sanitize_email(string $email): string { return $email; }

/**
 * @psalm-taint-escape file
 * @psalm-flow ($filename) -> return
 */
function sanitize_file_name(string $filename): string { return $filename; }

/**
 * @psalm-taint-escape sql
 * @psalm-taint-escape html
 * @psalm-flow ($key) -> return
 */
function sanitize_key(string $key): string { return $key; }

/**
 * @psalm-taint-escape html
 * @psalm-flow ($url) -> return
 */
function sanitize_url(string $url): string { return $url; }

/**
 * @psalm-taint-escape html
 * @psalm-flow ($url) -> return
 */
function esc_url_raw(string $url): string { return $url; }

// --- Numeric casts (always safe) ---

/**
 * @psalm-taint-escape sql
 * @psalm-taint-escape html
 */
function absint($maybeint): int { return 0; }

/**
 * @psalm-taint-escape sql
 * @psalm-taint-escape html
 */
function intval($value, int $base = 10): int { return 0; }

// --- Path sanitizers ---

/**
 * @psalm-taint-escape file
 * @psalm-flow ($path) -> return
 */
function wp_normalize_path(string $path): string { return $path; }

// --- Shell escapes ---

/**
 * @psalm-taint-escape shell
 * @psalm-flow ($arg) -> return
 */
function escapeshellarg(string $arg): string { return $arg; }

/**
 * @psalm-taint-escape shell
 * @psalm-flow ($command) -> return
 */
function escapeshellcmd(string $command): string { return $command; }

// --- URL validation for redirects ---

/**
 * @psalm-taint-escape header
 * @psalm-flow ($url) -> return
 */
function wp_validate_redirect(string $url, string $default = ''): string { return $url; }

/**
 * @psalm-taint-escape header
 * @psalm-flow ($url) -> return
 */
function wp_http_validate_url(string $url): string { return $url; }
}
