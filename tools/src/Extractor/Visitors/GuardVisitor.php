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

        // IR-03: detect custom guard methods/static calls via structural heuristic
        if ($node instanceof Node\Expr\MethodCall || $node instanceof Node\Expr\StaticCall) {
            if ($this->detectCustomGuard($node)) {
                $this->guards[] = [
                    'entry_point_id' => $this->entryPointId,
                    'type' => 'custom_guard',
                    'function_called' => $this->resolveCallDescription($node),
                    'file' => $this->currentFile,
                    'line' => $node->getStartLine(),
                    'is_effective' => null,
                    'notes' => 'custom guard heuristic: method/static call in if-condition with wp_die/exit/return in body',
                ];
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

    /**
     * IR-03: Structural detection of custom guard method/static calls.
     *
     * Returns true ONLY when ALL of the following hold:
     *   1. The call is the direct condition of an if/elseif statement (or negated with !)
     *   2. The if-body contains at least one hard exit: wp_die(), wp_send_json_error(),
     *      exit(), die(), or a bare return statement
     *
     * Naming is NEVER used as a signal — this prevents FPs from data-validation methods
     * that happen to contain 'verify', 'check', 'validate' in their name.
     *
     * @param Node\Expr\MethodCall|Node\Expr\StaticCall $callNode
     */
    private function detectCustomGuard(Node\Expr $callNode): bool
    {
        $parent = $callNode->getAttribute('parent');
        if ($parent === null) return false;

        // Find the If_ node that directly contains this call as its condition
        $ifNode = null;

        // Direct: if ($this->checkSomething()) { ... }
        if ($parent instanceof Node\Stmt\If_ || $parent instanceof Node\Stmt\ElseIf_) {
            $ifNode = $parent;
        }

        // Negated: if (!$this->checkSomething()) { ... }
        if ($parent instanceof Node\Expr\BooleanNot) {
            $grandparent = $parent->getAttribute('parent');
            if ($grandparent instanceof Node\Stmt\If_ || $grandparent instanceof Node\Stmt\ElseIf_) {
                $ifNode = $grandparent;
            }
        }

        if ($ifNode === null) return false;

        // The call must be the condition of the if (not nested deep inside it)
        // $ifNode->cond is the condition expression
        $cond = $ifNode->cond;
        $callIsCondition = ($cond === $callNode) ||
            ($cond instanceof Node\Expr\BooleanNot && $cond->expr === $callNode);

        if (!$callIsCondition) return false;

        return $this->ifBodyHasExitOrReturn($ifNode->stmts ?? []);
    }

    /**
     * Check whether a list of statements contains a hard-exit pattern:
     * wp_die(), wp_send_json_error(), exit(), die(), or bare return.
     * Checks only the top-level statements of the block (not nested ifs).
     *
     * @param Node\Stmt[] $stmts
     */
    private function ifBodyHasExitOrReturn(array $stmts): bool
    {
        foreach ($stmts as $stmt) {
            // return statement
            if ($stmt instanceof Node\Stmt\Return_) return true;

            // exit() / die() as a statement
            if ($stmt instanceof Node\Stmt\Expression &&
                $stmt->expr instanceof Node\Expr\Exit_) {
                return true;
            }

            // Function call statement: wp_die(), wp_send_json_error()
            if ($stmt instanceof Node\Stmt\Expression &&
                $stmt->expr instanceof Node\Expr\FuncCall) {
                $funcName = $this->resolveFuncName($stmt->expr);
                if (in_array($funcName, ['wp_die', 'wp_send_json_error', 'exit', 'die'], true)) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * Build a human-readable description of a method or static call for the guard record.
     *
     * @param Node\Expr\MethodCall|Node\Expr\StaticCall $callNode
     */
    private function resolveCallDescription(Node\Expr $callNode): string
    {
        $method = ($callNode->name instanceof Node\Identifier)
            ? $callNode->name->toString()
            : '?';

        if ($callNode instanceof Node\Expr\StaticCall) {
            $class = ($callNode->class instanceof Node\Name)
                ? $callNode->class->toString()
                : '?';
            return "{$class}::{$method}()";
        }

        // MethodCall
        if ($callNode instanceof Node\Expr\MethodCall) {
            $varName = ($callNode->var instanceof Node\Expr\Variable &&
                        is_string($callNode->var->name))
                ? '$' . $callNode->var->name
                : '?';
            return "{$varName}->{$method}()";
        }

        return "{$method}()";
    }

    public function getGuards(): array { return $this->guards; }

    public function reset(): void
    {
        $this->guards = [];
        $this->firstSideEffectLine = null;
    }
}
