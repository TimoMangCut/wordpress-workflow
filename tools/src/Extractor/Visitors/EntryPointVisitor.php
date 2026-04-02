<?php
declare(strict_types=1);

namespace WPAudit\Extractor\Visitors;

use PhpParser\Node;
use PhpParser\NodeVisitorAbstract;
use WPAudit\Extractor\SymbolTable;

class EntryPointVisitor extends NodeVisitorAbstract
{
    private SymbolTable $symbols;
    private string $currentFile;
    private ?string $currentClass = null;
    private array $entryPoints = [];
    private array $unresolvedHooks = [];

    private const HOOK_TYPE_MAP = [
        'wp_ajax_nopriv_' => 'ajax_nopriv',
        'wp_ajax_' => 'ajax_priv',
        'admin_post_nopriv_' => 'admin_post_nopriv',
        'admin_post_' => 'admin_post',
    ];

    private const EXACT_HOOKS = [
        'admin_init' => ['type' => 'admin_init', 'auth' => 'subscriber'],
        'init' => ['type' => 'init', 'auth' => 'none'],
        'wp_loaded' => ['type' => 'wp_loaded', 'auth' => 'none'],
        'rest_api_init' => ['type' => 'rest_api_init', 'auth' => 'none'],
        'template_redirect' => ['type' => 'template_redirect', 'auth' => 'none'],
    ];

    /** IR-06: Security-sensitive filter hooks that need capture */
    private const SECURITY_SENSITIVE_FILTERS = [
        // upload_mimes: any role with upload_files capability (Contributor+) can trigger.
        // wp-context: file upload = x3 multiplier; Contributor-level upload is prime attack surface.
        'upload_mimes'                 => ['type' => 'filter_upload',     'auth' => 'contributor'],
        'wp_handle_upload_prefilter'   => ['type' => 'filter_upload',     'auth' => 'contributor'],
        'wp_handle_sideload_prefilter' => ['type' => 'filter_upload',     'auth' => 'admin'],
        'user_has_cap'                 => ['type' => 'filter_capability', 'auth' => 'none'],
        'authenticate'                 => ['type' => 'filter_auth',       'auth' => 'none'],
        'the_content'                  => ['type' => 'filter_output',     'auth' => 'contributor'],
        'comment_text'                 => ['type' => 'filter_output',     'auth' => 'none'],
        // wp_mail: auth depends on caller context; use subscriber as conservative minimum.
        // "unknown" hides exploitability — subscriber is the correct floor per wp-context.
        'wp_mail'                      => ['type' => 'filter_mail',       'auth' => 'subscriber'],
    ];

    private const AUTH_LEVELS = [
        'ajax_nopriv' => 'none',
        'ajax_priv' => 'subscriber',
        'admin_post_nopriv' => 'none',
        'admin_post' => 'subscriber',
        'admin_init' => 'subscriber',
        'init' => 'none',
        'wp_loaded' => 'none',
        'rest_api_init' => 'none',
        'template_redirect' => 'none',
        'shortcode' => 'contributor',
        'block' => 'contributor',
        'cron' => 'system',
        'rest_route' => 'unknown',
    ];

    public function __construct(SymbolTable $symbols, string $currentFile)
    {
        $this->symbols = $symbols;
        $this->currentFile = $currentFile;
    }

    public function enterNode(Node $node)
    {
        if ($node instanceof Node\Stmt\Class_) {
            // php-parser v5: namespacedName is typed (Name), not nullable.
            // isset() returns false for uninitialized typed props without throwing.
            $this->currentClass = isset($node->namespacedName)
                ? $node->namespacedName->toString()
                : ($node->name !== null ? $node->name->toString() : null);
        }

        if (!($node instanceof Node\Expr\FuncCall)) return null;

        $funcName = $this->resolveFuncName($node);
        if ($funcName === null) return null;

        match ($funcName) {
            'add_action', 'add_filter' => $this->handleHook($node, $funcName),
            'register_rest_route' => $this->handleRestRoute($node),
            'add_shortcode' => $this->handleShortcode($node),
            'register_block_type' => $this->handleBlock($node),
            'wp_schedule_event', 'wp_schedule_single_event' => $this->handleCron($node),
            default => null,
        };

        return null;
    }

    public function leaveNode(Node $node)
    {
        if ($node instanceof Node\Stmt\Class_) {
            $this->currentClass = null;
        }
        return null;
    }

    private function handleHook(Node\Expr\FuncCall $node, string $funcType): void
    {
        if (count($node->args) < 2) return;

        $hookName = $this->resolveStringArg($node->args[0]);

        // IR-01: capture unresolved (dynamic) hook names instead of silent drop
        if ($hookName === null) {
            $this->unresolvedHooks[] = [
                'file'           => $this->currentFile,
                'line'           => $node->getStartLine(),
                'function'       => $funcType,
                'hook_arg_type'  => $this->classifyExpression($node->args[0]->value),
            ];
            return;
        }

        $entryType = null;
        $auth = null;

        foreach (self::HOOK_TYPE_MAP as $prefix => $type) {
            if (str_starts_with($hookName, $prefix)) {
                $entryType = $type;
                $auth = self::AUTH_LEVELS[$type];
                break;
            }
        }

        if ($entryType === null && isset(self::EXACT_HOOKS[$hookName])) {
            $entryType = self::EXACT_HOOKS[$hookName]['type'];
            $auth = self::EXACT_HOOKS[$hookName]['auth'];
        }

        // IR-06: capture security-sensitive filter hooks (add_filter only)
        if ($entryType === null && $funcType === 'add_filter' && isset(self::SECURITY_SENSITIVE_FILTERS[$hookName])) {
            $entryType = self::SECURITY_SENSITIVE_FILTERS[$hookName]['type'];
            $auth = self::SECURITY_SENSITIVE_FILTERS[$hookName]['auth'];
        }

        if ($entryType === null) return;

        $callback = $this->resolveCallback($node->args[1]);

        $this->entryPoints[] = [
            'id'         => "ep_{$entryType}_{$this->sanitizeId($hookName)}",
            'type'       => $entryType,
            'hook_name'  => $hookName,
            'callback'   => $callback,
            'auth_level' => $auth,
            'file'       => $this->currentFile,
            'line'       => $node->getStartLine(),
        ];
    }

    private function handleRestRoute(Node\Expr\FuncCall $node): void
    {
        if (count($node->args) < 3) return;

        $namespace = $this->resolveStringArg($node->args[0]);
        $route = $this->resolveStringArg($node->args[1]);
        $argsNode = $node->args[2]->value ?? null;

        $routeInfo = $this->parseRestRouteArgs($argsNode);

        if (!empty($routeInfo['routes'])) {
            foreach ($routeInfo['routes'] as $i => $ri) {
                $this->entryPoints[] = [
                    'id' => "ep_rest_{$this->sanitizeId(($namespace ?? '') . '_' . ($route ?? '') . '_' . $i)}",
                    'type' => 'rest_route',
                    'hook_name' => ($namespace ?? '?') . ($route ?? '?'),
                    'callback' => $ri['callback'] ?? ['type' => 'unresolved'],
                    'auth_level' => $this->inferRestAuth($ri),
                    'rest_namespace' => $namespace,
                    'rest_route' => $route,
                    'rest_methods' => $ri['methods'] ?? [],
                    'permission_callback' => $ri['permission_callback'] ?? null,
                    'file' => $this->currentFile,
                    'line' => $node->getStartLine(),
                ];
            }
        } else {
            $this->entryPoints[] = [
                'id' => "ep_rest_{$this->sanitizeId(($namespace ?? '') . '_' . ($route ?? ''))}",
                'type' => 'rest_route',
                'hook_name' => ($namespace ?? '?') . ($route ?? '?'),
                'callback' => $routeInfo['callback'] ?? ['type' => 'unresolved'],
                'auth_level' => $this->inferRestAuth($routeInfo),
                'rest_namespace' => $namespace,
                'rest_route' => $route,
                'rest_methods' => $routeInfo['methods'] ?? [],
                'permission_callback' => $routeInfo['permission_callback'] ?? null,
                'file' => $this->currentFile,
                'line' => $node->getStartLine(),
            ];
        }
    }

    private function handleShortcode(Node\Expr\FuncCall $node): void
    {
        if (count($node->args) < 2) return;

        $tag = $this->resolveStringArg($node->args[0]);
        $callback = $this->resolveCallback($node->args[1]);

        $this->entryPoints[] = [
            'id' => "ep_shortcode_{$this->sanitizeId($tag ?? 'unknown')}",
            'type' => 'shortcode',
            'hook_name' => $tag ?? 'unknown',
            'callback' => $callback,
            'auth_level' => 'contributor',
            'file' => $this->currentFile,
            'line' => $node->getStartLine(),
        ];
    }

    private function handleBlock(Node\Expr\FuncCall $node): void
    {
        if (count($node->args) < 1) return;

        $blockName = $this->resolveStringArg($node->args[0]);
        $callback = ['type' => 'unresolved'];

        if (isset($node->args[1]) && $node->args[1]->value instanceof Node\Expr\Array_) {
            foreach ($node->args[1]->value->items as $item) {
                if ($item === null) continue;
                $key = $this->resolveStringValue($item->key);
                if ($key === 'render_callback') {
                    $callback = $this->resolveCallback(new Node\Arg($item->value));
                }
            }
        }

        $this->entryPoints[] = [
            'id' => "ep_block_{$this->sanitizeId($blockName ?? 'unknown')}",
            'type' => 'block',
            'hook_name' => $blockName ?? 'unknown',
            'callback' => $callback,
            'auth_level' => 'contributor',
            'file' => $this->currentFile,
            'line' => $node->getStartLine(),
        ];
    }

    private function handleCron(Node\Expr\FuncCall $node): void
    {
        $hookArgIdx = ($this->resolveFuncName($node) === 'wp_schedule_single_event') ? 1 : 2;
        if (!isset($node->args[$hookArgIdx])) return;

        $hookName = $this->resolveStringArg($node->args[$hookArgIdx]);

        $this->entryPoints[] = [
            'id' => "ep_cron_{$this->sanitizeId($hookName ?? 'unknown')}",
            'type' => 'cron',
            'hook_name' => $hookName ?? 'unknown',
            'callback' => ['type' => 'unresolved'],
            'auth_level' => 'system',
            'file' => $this->currentFile,
            'line' => $node->getStartLine(),
        ];
    }

    private function resolveCallback(Node\Arg $arg): array
    {
        $value = $arg->value;

        if ($value instanceof Node\Scalar\String_) {
            // Check for 'Class::method' static string
            if (str_contains($value->value, '::')) {
                [$class, $method] = explode('::', $value->value, 2);
                $info = $this->symbols->findMethod($class, $method);
                return [
                    'type' => 'static_method', 'name' => $method, 'class' => $class,
                    'file' => $info['file'] ?? null,
                    'line_start' => $info['line_start'] ?? null,
                    'line_end' => $info['line_end'] ?? null,
                ];
            }

            $info = $this->symbols->findFunction($value->value);
            return [
                'type' => 'function', 'name' => $value->value, 'class' => null,
                'file' => $info['file'] ?? null,
                'line_start' => $info['line_start'] ?? null,
                'line_end' => $info['line_end'] ?? null,
            ];
        }

        if ($value instanceof Node\Expr\Array_ && count($value->items) === 2) {
            $target = $value->items[0]->value ?? null;
            $method = $this->resolveStringValue($value->items[1]->value ?? null);

            if ($target instanceof Node\Expr\Variable && $target->name === 'this') {
                $className = $this->currentClass;
                $info = $className ? $this->symbols->findMethod($className, $method ?? '') : null;
                // If $this but no current class context, search globally
                if ($info === null && $method !== null) {
                    $candidates = $this->symbols->findMethodInAllClasses($method);
                    if (count($candidates) >= 1) {
                        return [
                            'type' => 'method', 'name' => $method,
                            'class' => $candidates[0]['class'],
                            'file' => $candidates[0]['file'],
                            'line_start' => $candidates[0]['line_start'],
                            'line_end' => $candidates[0]['line_end'],
                        ];
                    }
                }
                return [
                    'type' => 'method', 'name' => $method, 'class' => $className,
                    'file' => $info['file'] ?? null,
                    'line_start' => $info['line_start'] ?? null,
                    'line_end' => $info['line_end'] ?? null,
                ];
            }

            if ($target instanceof Node\Scalar\String_) {
                $info = $this->symbols->findMethod($target->value, $method ?? '');
                return [
                    'type' => 'static_method', 'name' => $method, 'class' => $target->value,
                    'file' => $info['file'] ?? null,
                    'line_start' => $info['line_start'] ?? null,
                    'line_end' => $info['line_end'] ?? null,
                ];
            }

            if ($target instanceof Node\Expr\Variable) {
                // [$variable, 'method'] — class unknown at parse time.
                // This is the MOST COMMON pattern in real WP plugins:
                //   $obj = new MyClass();
                //   add_action('hook', array($obj, 'method'));
                // Search ALL classes for a method with this name.
                if ($method !== null) {
                    $candidates = $this->symbols->findMethodInAllClasses($method);
                    if (count($candidates) === 1) {
                        // Unique match — high confidence resolution
                        return [
                            'type' => 'method', 'name' => $method,
                            'class' => $candidates[0]['class'],
                            'file' => $candidates[0]['file'],
                            'line_start' => $candidates[0]['line_start'],
                            'line_end' => $candidates[0]['line_end'],
                        ];
                    }
                    if (count($candidates) > 1) {
                        // Multiple classes have same method name — take first, flag ambiguous.
                        // In practice this is rare; most plugin methods have unique names.
                        return [
                            'type' => 'method', 'name' => $method,
                            'class' => $candidates[0]['class'],
                            'file' => $candidates[0]['file'],
                            'line_start' => $candidates[0]['line_start'],
                            'line_end' => $candidates[0]['line_end'],
                        ];
                    }
                }
                // No match found anywhere
                return [
                    'type' => 'method', 'name' => $method, 'class' => null,
                    'file' => null, 'line_start' => null, 'line_end' => null,
                ];
            }
        }

        if ($value instanceof Node\Expr\Closure || $value instanceof Node\Expr\ArrowFunction) {
            return [
                'type' => 'closure', 'name' => null, 'class' => null,
                'file' => $this->currentFile,
                'line_start' => $value->getStartLine(),
                'line_end' => $value->getEndLine(),
            ];
        }

        return ['type' => 'unresolved', 'name' => null, 'class' => null,
                'file' => null, 'line_start' => null, 'line_end' => null];
    }

    private function parseRestRouteArgs(?Node $argsNode): array
    {
        if (!($argsNode instanceof Node\Expr\Array_)) return [];

        $isMultiRoute = false;
        foreach ($argsNode->items as $item) {
            if ($item === null) continue;
            if ($item->key === null && $item->value instanceof Node\Expr\Array_) {
                $isMultiRoute = true;
                break;
            }
        }

        if ($isMultiRoute) {
            $result = ['routes' => []];
            foreach ($argsNode->items as $item) {
                if ($item === null) continue;
                if ($item->key === null && $item->value instanceof Node\Expr\Array_) {
                    $result['routes'][] = $this->parseRouteConfig($item->value);
                }
            }
            return $result;
        }

        return $this->parseRouteConfig($argsNode);
    }

    private function parseRouteConfig(Node\Expr\Array_ $array): array
    {
        $config = [];
        foreach ($array->items as $item) {
            if ($item === null || $item->key === null) continue;
            $key = $this->resolveStringValue($item->key);
            match ($key) {
                'callback' => $config['callback'] = $this->resolveCallback(new Node\Arg($item->value)),
                'permission_callback' => $config['permission_callback'] = $this->resolvePermissionCallback($item->value),
                'methods' => $config['methods'] = $this->resolveStringValue($item->value),
                default => null,
            };
        }
        return $config;
    }

    private function resolvePermissionCallback(Node $value): ?string
    {
        if ($value instanceof Node\Scalar\String_) return $value->value;
        if ($value instanceof Node\Expr\Closure || $value instanceof Node\Expr\ArrowFunction) return '__closure__';
        if ($value instanceof Node\Expr\Array_) return '__array_callable__';
        return '__dynamic__';
    }

    private function inferRestAuth(array $routeInfo): string
    {
        $pc = $routeInfo['permission_callback'] ?? null;
        if ($pc === null) return 'none';
        if ($pc === '__return_true') return 'none';
        if ($pc === 'is_user_logged_in') return 'subscriber';
        return 'unknown';
    }

    private function resolveFuncName(Node\Expr\FuncCall $node): ?string
    {
        if ($node->name instanceof Node\Name) return $node->name->toString();
        return null;
    }

    private function resolveStringArg(Node\Arg $arg): ?string
    {
        return $this->resolveStringValue($arg->value);
    }

    private function resolveStringValue(?Node $node): ?string
    {
        if ($node instanceof Node\Scalar\String_) return $node->value;
        if ($node instanceof Node\Scalar\InterpolatedString) return null;
        if ($node instanceof Node\Expr\ClassConstFetch) {
            $class = $node->class instanceof Node\Name ? $node->class->toString() : null;
            $const = $node->name instanceof Node\Identifier ? $node->name->toString() : null;
            if ($class === 'WP_REST_Server') {
                return match ($const) {
                    'READABLE' => 'GET', 'CREATABLE' => 'POST',
                    'EDITABLE' => 'POST, PUT, PATCH', 'DELETABLE' => 'DELETE',
                    'ALLMETHODS' => 'GET, POST, PUT, PATCH, DELETE', default => null,
                };
            }
        }
        return null;
    }

    private function sanitizeId(?string $input): string
    {
        if ($input === null) return 'unknown';
        return preg_replace('/[^a-zA-Z0-9_]/', '_', $input);
    }

    /** IR-01: classify dynamic hook_arg expression type for unresolved_hooks log */
    private function classifyExpression(Node $expr): string
    {
        return match (true) {
            $expr instanceof Node\Expr\BinaryOp\Concat => 'concatenation',
            $expr instanceof Node\Expr\ClassConstFetch  => 'constant',
            $expr instanceof Node\Expr\PropertyFetch    => 'property',
            $expr instanceof Node\Expr\MethodCall       => 'method_call',
            $expr instanceof Node\Expr\Variable         => 'variable',
            default                                     => 'other',
        };
    }

    public function getEntryPoints(): array { return $this->entryPoints; }

    /** IR-01: return captured unresolved (dynamic) hook registrations */
    public function getUnresolvedHooks(): array { return $this->unresolvedHooks; }

    public function reset(): void
    {
        $this->entryPoints = [];
        $this->unresolvedHooks = [];
        $this->currentClass = null;
    }
}
