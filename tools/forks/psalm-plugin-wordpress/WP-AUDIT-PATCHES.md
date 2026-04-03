# WP Audit Local Fork Patches

This local fork is used by `tools/composer.json` via a path repository.

Version: `3.1.2.1`

## Applied hardening patches

1. Namespace null guard (issue #58 / PR #59 pattern)
- In `HookNodeVisitor::enterNode`, namespace handling now checks:
  - `if ($node instanceof Namespace_ && $node->name instanceof Name)`.

2. Safe dynamic hook resolver wrapper
- Added `Plugin::safeGetDynamicHookName(...)` with `try/catch`.
- Unsupported dynamic hook AST no longer crashes Psalm run.
- Errors are recorded into `Plugin::$parseErrors` for diagnostics.

3. Return-type guard for missing call args
- In `Plugin::getFunctionReturnType(...)`, access to `call_args[1]` is now guarded.
- Missing args now downgrade to `Type::getMixed()` instead of runtime warnings/exceptions.

4. Traversal hardening
- `beforeAnalyzeFile(...)` now catches `\Throwable` and records parse error instead of crashing the entire scan.
