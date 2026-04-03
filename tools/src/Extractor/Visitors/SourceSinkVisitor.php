<?php
declare(strict_types=1);

namespace WPAudit\Extractor\Visitors;

use PhpParser\Node;
use PhpParser\NodeVisitorAbstract;

/**
 * SourceSinkVisitor: map input sources and dangerous sinks within function bodies.
 */
class SourceSinkVisitor extends NodeVisitorAbstract
{
    private string $currentFile;
    private ?string $entryPointId;
    /** IR-09: when true, skip output_return sink detection (Phase4 file-level scan) */
    private bool $isFileLevel;

    private array $sources = [];
    private array $sinks = [];
    private array $prepareLines = []; // Track $wpdb->prepare() line numbers for proximity check
    private int $sourceCounter = 0;
    private int $sinkCounter = 0;

    /** Source: superglobal name → type */
    private const SUPERGLOBAL_TYPES = [
        '_GET' => 'superglobal_get',
        '_POST' => 'superglobal_post',
        '_REQUEST' => 'superglobal_request',
        '_COOKIE' => 'superglobal_cookie',
        '_FILES' => 'superglobal_files',
        '_SERVER' => 'superglobal_server',
    ];

    /** Sink categories by function/method name */
    private const SINK_MAP = [
        // SQL sinks ($wpdb methods)
        'query' => 'sql', 'get_var' => 'sql', 'get_row' => 'sql',
        'get_col' => 'sql', 'get_results' => 'sql',
        // Output sinks
        'echo' => 'output', 'print' => 'output', 'printf' => 'output',
        // File sinks
        'file_put_contents' => 'file_write', 'fwrite' => 'file_write',
        'move_uploaded_file' => 'file_write', 'copy' => 'file_write',
        'file_get_contents' => 'file_read', 'readfile' => 'file_read',
        'fopen' => 'file_read', 'fread' => 'file_read',
        'unlink' => 'file_delete', 'rmdir' => 'file_delete',
        'wp_delete_file' => 'file_delete',
        // Remote sinks
        'wp_remote_get' => 'remote_request', 'wp_remote_post' => 'remote_request',
        'wp_remote_head' => 'remote_request', 'wp_remote_request' => 'remote_request',
        'curl_init' => 'remote_request',
        // Deserialization
        'unserialize' => 'deserialization', 'maybe_unserialize' => 'deserialization',
        // Code execution
        'eval' => 'eval', 'assert' => 'eval', 'create_function' => 'eval',
        'call_user_func' => 'eval', 'call_user_func_array' => 'eval',
        // Include
        'include' => 'include', 'require' => 'include',
        'include_once' => 'include', 'require_once' => 'include',
        // Redirect
        'wp_redirect' => 'redirect', 'wp_safe_redirect' => 'redirect',
        // Storage
        'update_option' => 'option_update', 'update_post_meta' => 'meta_update',
        'update_user_meta' => 'meta_update', 'update_site_option' => 'option_update',
        'add_option' => 'option_update', 'add_post_meta' => 'meta_update',
    ];

    /** IR-07: Storage reads → go into SOURCES array (gate builds storage_reads_by_key from sources) */
    private const STORAGE_READ_MAP = [
        'get_option'       => ['source_type' => 'option_read', 'key_arg_index' => 0],
        'get_site_option'  => ['source_type' => 'option_read', 'key_arg_index' => 0],
        'get_post_meta'    => ['source_type' => 'meta_read',   'key_arg_index' => 1],
        'get_user_meta'    => ['source_type' => 'meta_read',   'key_arg_index' => 1],
        'get_term_meta'    => ['source_type' => 'meta_read',   'key_arg_index' => 1],
        'get_comment_meta' => ['source_type' => 'meta_read',   'key_arg_index' => 1],
    ];

    /** IR-07: Key argument index for storage write functions */
    private const STORAGE_WRITE_KEY_ARG = [
        'update_option'      => 0,
        'add_option'         => 0,
        'update_site_option' => 0,
        'update_post_meta'   => 1,
        'update_user_meta'   => 1,
        'add_post_meta'      => 1,
        'update_term_meta'   => 1,
        'update_comment_meta' => 1,
    ];

    /** Known sanitizer functions */
    private const SANITIZERS = [
        // SQL
        'prepare', 'esc_sql', 'esc_like',
        // XSS
        'esc_html', 'esc_attr', 'esc_url', 'esc_js', 'esc_textarea', 'esc_xml',
        'wp_kses', 'wp_kses_post', 'wp_kses_data',
        'sanitize_text_field', 'sanitize_textarea_field', 'sanitize_email',
        'sanitize_file_name', 'sanitize_key', 'sanitize_title', 'sanitize_url',
        'sanitize_html_class', 'sanitize_user', 'sanitize_hex_color',
        // Numeric
        'absint', 'intval', 'floatval',
        // Path
        'basename', 'realpath', 'wp_normalize_path', 'validate_file',
        // Shell
        'escapeshellarg', 'escapeshellcmd',
        // URL
        'wp_http_validate_url', 'esc_url_raw', 'wp_validate_redirect',
        // WooCommerce
        'wc_clean', 'wc_sanitize_textarea',
        // Give
        'give_clean',
    ];

    public function __construct(string $currentFile, ?string $entryPointId = null, bool $isFileLevel = false)
    {
        $this->currentFile = $currentFile;
        $this->entryPointId = $entryPointId;
        $this->isFileLevel = $isFileLevel;
    }

    public function enterNode(Node $node)
    {
        // Detect superglobal access: $_GET['key'], $_POST, etc.
        if ($node instanceof Node\Expr\ArrayDimFetch) {
            $this->detectSuperglobalAccess($node);
        }
        if ($node instanceof Node\Expr\Variable && is_string($node->name)) {
            if (isset(self::SUPERGLOBAL_TYPES[$node->name])) {
                $this->addSource(self::SUPERGLOBAL_TYPES[$node->name], '$' . $node->name, null, $node->getStartLine());
            }
        }

        // Detect REST API sources: $request->get_param(), $request['key']
        if ($node instanceof Node\Expr\MethodCall) {
            $this->detectRestSource($node);
            $this->detectMethodSink($node);
        }

        // Detect function call sinks + IR-07 storage reads
        if ($node instanceof Node\Expr\FuncCall) {
            $this->detectStorageRead($node);
            $this->detectFuncSink($node);
        }

        // Detect echo (language construct, NOT a function call)
        if ($node instanceof Node\Stmt\Echo_) {
            $this->addSink('output', 'echo', $node->getStartLine(), null);
        }

        // Detect print (expression, NOT a function call)
        if ($node instanceof Node\Expr\Print_) {
            $this->addSink('output', 'print', $node->getStartLine(), null);
        }

        // Detect return (output sink for shortcode/block callbacks)
        // IR-09: skip when $isFileLevel=true (Phase4 file-level scan produces false positives)
        if (!$this->isFileLevel && $node instanceof Node\Stmt\Return_ && $node->expr !== null) {
            $this->addSink('output_return', 'return', $node->getStartLine(), null);
        }

        // Detect include/require (language construct)
        if ($node instanceof Node\Expr\Include_) {
            $this->addSink('include', match ($node->type) {
                Node\Expr\Include_::TYPE_INCLUDE => 'include',
                Node\Expr\Include_::TYPE_INCLUDE_ONCE => 'include_once',
                Node\Expr\Include_::TYPE_REQUIRE => 'require',
                Node\Expr\Include_::TYPE_REQUIRE_ONCE => 'require_once',
                default => 'include',
            }, $node->getStartLine(), null);
        }

        // Detect REST ArrayAccess: $request['key'] (WP_REST_Request implements ArrayAccess)
        if ($node instanceof Node\Expr\ArrayDimFetch &&
            $node->var instanceof Node\Expr\Variable &&
            is_string($node->var->name) &&
            in_array($node->var->name, ['request', 'req', 'wp_rest_request'], true)) {
            $key = ($node->dim instanceof Node\Scalar\String_) ? $node->dim->value : null;
            $this->addSource('rest_array_access', '$' . $node->var->name, $key, $node->getStartLine());
        }

        // Detect shortcode attribute access: $atts['key']
        if ($node instanceof Node\Expr\ArrayDimFetch &&
            $node->var instanceof Node\Expr\Variable &&
            is_string($node->var->name) &&
            in_array($node->var->name, ['atts', 'attributes'], true)) {
            $type = $node->var->name === 'atts' ? 'shortcode_attr' : 'block_attr';
            $key = ($node->dim instanceof Node\Scalar\String_) ? $node->dim->value : null;
            $this->addSource($type, "\${$node->var->name}", $key, $node->getStartLine());
        }

        return null;
    }

    private function detectSuperglobalAccess(Node\Expr\ArrayDimFetch $node): void
    {
        if (!($node->var instanceof Node\Expr\Variable) || !is_string($node->var->name)) return;
        $varName = $node->var->name;

        if (!isset(self::SUPERGLOBAL_TYPES[$varName])) return;

        $key = null;
        if ($node->dim instanceof Node\Scalar\String_) {
            $key = $node->dim->value;
        }

        $this->addSource(self::SUPERGLOBAL_TYPES[$varName], '$' . $varName, $key, $node->getStartLine());
    }

    private function detectRestSource(Node\Expr\MethodCall $node): void
    {
        $methodName = ($node->name instanceof Node\Identifier) ? $node->name->toString() : null;
        if ($methodName === null) return;

        $restMethods = [
            'get_param' => 'rest_param',
            'get_params' => 'rest_params',
            'get_json_params' => 'rest_json',
            'get_body' => 'rest_body',
            'get_body_params' => 'rest_body_params',
            'get_query_params' => 'rest_query_params',
            'get_url_params' => 'rest_url_params',
            'get_header' => 'rest_header',
            'get_headers' => 'rest_headers',
            'get_file_params' => 'rest_file_params',
        ];

        if (isset($restMethods[$methodName])) {
            $key = null;
            if ($methodName === 'get_param' && isset($node->args[0])) {
                if ($node->args[0]->value instanceof Node\Scalar\String_) {
                    $key = $node->args[0]->value->value;
                }
            }
            $this->addSource($restMethods[$methodName], "\$request->{$methodName}()", $key, $node->getStartLine());
        }
    }

    private function detectMethodSink(Node\Expr\MethodCall $node): void
    {
        $methodName = ($node->name instanceof Node\Identifier) ? $node->name->toString() : null;
        if ($methodName === null) return;

        // Track $wpdb->prepare() calls (used by checkPrepareUsage)
        if ($methodName === 'prepare') {
            $this->prepareLines[] = $node->getStartLine();
        }

        if (isset(self::SINK_MAP[$methodName])) {
            $category = self::SINK_MAP[$methodName];

            $usesPrepare = null;
            if ($category === 'sql' && isset($node->args[0])) {
                $usesPrepare = $this->checkPrepareUsage($node->args[0]->value, $node->getStartLine());
            }

            $this->addSink($category, $methodName, $node->getStartLine(), $usesPrepare);
        }
    }

    /** IR-07: Detect storage read calls → add to sources[] (NOT sinks) */
    private function detectStorageRead(Node\Expr\FuncCall $node): void
    {
        $funcName = ($node->name instanceof Node\Name) ? $node->name->toString() : null;
        if ($funcName === null) return;

        if (!isset(self::STORAGE_READ_MAP[$funcName])) return;

        $def = self::STORAGE_READ_MAP[$funcName];
        $keyArgIndex = $def['key_arg_index'];
        $key = null;

        if (isset($node->args[$keyArgIndex]) && $node->args[$keyArgIndex]->value instanceof Node\Scalar\String_) {
            $key = $node->args[$keyArgIndex]->value->value;
        }

        $this->addSource($def['source_type'], $funcName . '()', $key, $node->getStartLine());
    }

    private function detectFuncSink(Node\Expr\FuncCall $node): void
    {
        $funcName = ($node->name instanceof Node\Name) ? $node->name->toString() : null;
        if ($funcName === null) return;

        if (isset(self::SINK_MAP[$funcName])) {
            // IR-07: extract key argument for storage write sinks
            $key = null;
            if (isset(self::STORAGE_WRITE_KEY_ARG[$funcName])) {
                $keyArgIndex = self::STORAGE_WRITE_KEY_ARG[$funcName];
                if (isset($node->args[$keyArgIndex]) && $node->args[$keyArgIndex]->value instanceof Node\Scalar\String_) {
                    $key = $node->args[$keyArgIndex]->value->value;
                }
            }
            $this->addSink(self::SINK_MAP[$funcName], $funcName, $node->getStartLine(), null, $key);
        }
    }

    private function checkPrepareUsage(Node $argValue, int $sinkLine): bool
    {
        // Pattern 1: Direct — $wpdb->get_results($wpdb->prepare(...))
        if ($argValue instanceof Node\Expr\MethodCall) {
            $name = ($argValue->name instanceof Node\Identifier) ? $argValue->name->toString() : null;
            if ($name === 'prepare') return true;
        }

        // Pattern 2: Variable — $sql = $wpdb->prepare(...); $wpdb->get_results($sql);
        // IR-08: Check if prepare() was called within 30 lines before this sink (was 10)
        foreach ($this->prepareLines as $prepareLine) {
            if ($prepareLine < $sinkLine && ($sinkLine - $prepareLine) <= 30) {
                return true;
            }
        }

        return false;
    }

    private function addSource(string $type, string $variable, ?string $key, int $line): void
    {
        $this->sources[] = [
            'id' => 'src_' . (++$this->sourceCounter),
            'entry_point_id' => $this->entryPointId,
            'type' => $type,
            'variable' => $variable,
            'key' => $key,
            'file' => $this->currentFile,
            'line' => $line,
        ];
    }

    private function addSink(string $category, string $functionCalled, int $line, ?bool $usesPrepare, ?string $key = null): void
    {
        $this->sinks[] = [
            'id' => 'sink_' . (++$this->sinkCounter),
            'entry_point_id' => $this->entryPointId,
            'category' => $category,
            'function_called' => $functionCalled,
            'uses_prepared_statement' => $usesPrepare,
            'key' => $key,
            'file' => $this->currentFile,
            'line' => $line,
        ];
    }

    public function getSources(): array { return $this->sources; }
    public function getSinks(): array { return $this->sinks; }

    public function reset(): void
    {
        $this->sources = [];
        $this->sinks = [];
        $this->prepareLines = [];
    }
}
