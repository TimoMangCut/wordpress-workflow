<?php
declare(strict_types=1);

namespace WPAudit\Extractor\Visitors;

use PhpParser\Node;
use PhpParser\NodeVisitorAbstract;

/**
 * GuardVisitor: detect security guards (nonce, capability, ownership checks)
 * within callback function bodies. Run AFTER entry points are identified.
 *
 * Requires ParentConnectingVisitor to run in the same traversal pass so that
 * parent context is available for determineEffectiveness().
 */
class GuardVisitor extends NodeVisitorAbstract
{
    private string $currentFile;
    private string $entryPointId;

    /** @var array Collected guards */
    private array $guards = [];

    /** @var int Track first side-effect line to detect guard-after-action */
    private ?int $firstSideEffectLine = null;

    /** Side-effect functions (state-changing) */
    private const SIDE_EFFECTS = [
        'update_option', 'update_post_meta', 'update_user_meta', 'update_site_option',
        'add_option', 'add_post_meta', 'add_user_meta',
        'delete_option', 'delete_post_meta', 'delete_user_meta',
        'wp_insert_post', 'wp_update_post', 'wp_delete_post',
        'wp_insert_user', 'wp_update_user', 'wp_delete_user',
        'wp_set_password', 'wp_set_auth_cookie', 'wp_set_current_user',
        'unlink', 'rmdir', 'file_put_contents', 'fwrite',
        'wp_send_json_success', 'wp_send_json_error', 'wp_send_json',
        'wp_redirect', 'wp_safe_redirect',
    ];

    public function __construct(string $currentFile, string $entryPointId)
    {
        $this->currentFile = $currentFile;
        $this->entryPointId = $entryPointId;
    }

    public function enterNode(Node $node)
    {
        // Track side-effect from $wpdb method calls (query, insert, update, delete)
        if ($node instanceof Node\Expr\MethodCall) {
            $methodName = ($node->name instanceof Node\Identifier) ? $node->name->toString() : null;
            if (in_array($methodName, ['query', 'insert', 'update', 'delete', 'replace'], true)) {
                $this->firstSideEffectLine ??= $node->getStartLine();
            }
        }

        if (!($node instanceof Node\Expr\FuncCall)) return null;

        $funcName = $this->resolveFuncName($node);
        if ($funcName === null) return null;

        // Track side effects from function calls
        if (in_array($funcName, self::SIDE_EFFECTS, true)) {
            $this->firstSideEffectLine ??= $node->getStartLine();
        }

        // Detect nonce checks
        if (in_array($funcName, ['wp_verify_nonce', 'check_ajax_referer', 'check_admin_referer'], true)) {
            // IR-04: wp_verify_nonce() returns a value that must be checked — use AST context.
            // check_ajax_referer/check_admin_referer auto-die by default — start as true.
            $isEffective = ($funcName === 'wp_verify_nonce')
                ? $this->determineEffectiveness($node)
                : true;

            $guard = [
                'entry_point_id' => $this->entryPointId,
                'type' => 'nonce_check',
                'function_called' => $funcName,
                'file' => $this->currentFile,
                'line' => $node->getStartLine(),
                'is_effective' => $isEffective,
                'notes' => null,
            ];

            // check_ajax_referer with $die=false is ineffective regardless of context
            if ($funcName === 'check_ajax_referer') {
                if (isset($node->args[2])) {
                    $dieArg = $node->args[2]->value ?? null;
                    if ($dieArg instanceof Node\Expr\ConstFetch &&
                        strtolower($dieArg->name->toString()) === 'false') {
                        $guard['is_effective'] = false;
                        $guard['notes'] = 'check_ajax_referer with $die=false — code continues on failure';
                    }
                }
            }

            // Guard after side effect — override to false regardless of AST context
            if ($this->firstSideEffectLine !== null &&
                $node->getStartLine() > $this->firstSideEffectLine) {
                $guard['is_effective'] = false;
                $guard['notes'] = ($guard['notes'] ? $guard['notes'] . '; ' : '') .
                    "guard at line {$node->getStartLine()} after side-effect at line {$this->firstSideEffectLine}";
            }

            $this->guards[] = $guard;
        }

        // Detect capability checks
        if ($funcName === 'current_user_can') {
            $cap = isset($node->args[0]) ? $this->resolveStringArg($node->args[0]) : null;

            // IR-04: determine effectiveness from AST context
            $isEffective = $this->determineEffectiveness($node);

            $guard = [
                'entry_point_id' => $this->entryPointId,
                'type' => 'capability_check',
                'function_called' => "current_user_can('{$cap}')",
                'file' => $this->currentFile,
                'line' => $node->getStartLine(),
                'is_effective' => $isEffective,
                'notes' => ($isEffective === false)
                    ? 'return value assigned but not used in conditional'
                    : $cap,
            ];

            // Guard after side effect — override to false regardless of AST context
            if ($this->firstSideEffectLine !== null &&
                $node->getStartLine() > $this->firstSideEffectLine) {
                $guard['is_effective'] = false;
                $guard['notes'] = "guard after side-effect at line {$this->firstSideEffectLine}";
            }

            $this->guards[] = $guard;
        }

        // Detect is_admin() misuse
        if ($funcName === 'is_admin') {
            $this->guards[] = [
                'entry_point_id' => $this->entryPointId,
                'type' => 'is_admin_check',
                'function_called' => 'is_admin()',
                'file' => $this->currentFile,
                'line' => $node->getStartLine(),
                'is_effective' => false,
                'notes' => 'is_admin() checks URI prefix, NOT user role — any subscriber can access /wp-admin/',
            ];
        }

        return null;
    }

    /**
     * IR-04: Determine whether a security function call's return value is actually
     * used as a conditional guard.
     *
     * Returns:
     *   true  — call is in an if/elseif condition (directly or negated): effective guard
     *   false — call is the RHS of an assignment: return value captured but not used in branching
     *   null  — context could not be determined (ternary, function arg, other expression)
     *
     * Requires ParentConnectingVisitor to have run in the same traversal pass.
     */
    private function determineEffectiveness(Node $callNode): ?bool
    {
        $parent = $callNode->getAttribute('parent');

        if ($parent === null) {
            // No parent info available (ParentConnectingVisitor not in traversal)
            return null;
        }

        // Direct: if (current_user_can(...)) or if (wp_verify_nonce(...))
        if ($parent instanceof Node\Stmt\If_ ||
            $parent instanceof Node\Stmt\ElseIf_) {
            return true;
        }

        // Negated: if (!current_user_can(...))
        if ($parent instanceof Node\Expr\BooleanNot) {
            $grandparent = $parent->getAttribute('parent');
            if ($grandparent instanceof Node\Stmt\If_ ||
                $grandparent instanceof Node\Stmt\ElseIf_) {
                return true;
            }
        }

        // Assignment: $var = current_user_can(...)
        if ($parent instanceof Node\Expr\Assign) {
            return false;
        }

        // All other contexts (ternary, function arg, binary op wrapper, etc.) — unknown
        return null;
    }

    private function resolveFuncName(Node\Expr\FuncCall $node): ?string
    {
        if ($node->name instanceof Node\Name) return $node->name->toString();
        return null;
    }

    private function resolveStringArg(Node\Arg $arg): ?string
    {
        if ($arg->value instanceof Node\Scalar\String_) return $arg->value->value;
        return null;
    }

    public function getGuards(): array { return $this->guards; }

    public function reset(): void
    {
        $this->guards = [];
        $this->firstSideEffectLine = null;
    }
}
