<?php
declare(strict_types=1);

namespace WPAudit\Extractor;

use PhpParser\ParserFactory;
use PhpParser\NodeTraverser;
use PhpParser\NodeVisitor\NameResolver;
use PhpParser\NodeVisitor\ParentConnectingVisitor;
use WPAudit\Extractor\Visitors\EntryPointVisitor;
use WPAudit\Extractor\Visitors\GuardVisitor;
use WPAudit\Extractor\Visitors\SourceSinkVisitor;

/**
 * IRBuilder: orchestrate all visitors, assemble final IR JSON.
 */
class IRBuilder
{
    private string $pluginDir;
    private SymbolTable $symbols;
    private array $ir;
    private float $startTime;

    public function __construct(string $pluginDir)
    {
        $this->pluginDir = rtrim(realpath($pluginDir) ?: $pluginDir, '/');
        $this->symbols = new SymbolTable($this->pluginDir);
        $this->startTime = microtime(true);
    }

    /**
     * Run full extraction pipeline. Returns IR array.
     */
    public function build(): array
    {
        // Phase 1: Build symbol table (function/class declarations)
        $this->symbols->build();

        // Phase 2: Find entry points across all files
        $parser = (new ParserFactory())->createForHostVersion();
        $files = $this->findPhpFiles($this->pluginDir);
        $allEntryPoints = [];
        $allGuards = [];
        $allSources = [];
        $allSinks = [];
        $allUnresolvedHooks = [];
        $totalLoc = 0;

        // Cache parsed ASTs per file (avoid re-parsing)
        $astCache = [];

        foreach ($files as $file) {
            $code = file_get_contents($file);
            if ($code === false) continue;
            $totalLoc += substr_count($code, "\n") + 1;

            try {
                $ast = $parser->parse($code);
                if ($ast === null) continue;
            } catch (\Throwable $e) {
                continue;
            }

            // Run NameResolver
            $nrTraverser = new NodeTraverser();
            $nrTraverser->addVisitor(new NameResolver());
            $ast = $nrTraverser->traverse($ast);

            $relPath = $this->relativePath($file);
            $astCache[$relPath] = $ast;

            // Pass 2a: Find entry points
            $epVisitor = new EntryPointVisitor($this->symbols, $relPath);
            $traverser = new NodeTraverser();
            $traverser->addVisitor($epVisitor);
            $traverser->traverse($ast);
            $allEntryPoints = array_merge($allEntryPoints, $epVisitor->getEntryPoints());
            $allUnresolvedHooks = array_merge($allUnresolvedHooks, $epVisitor->getUnresolvedHooks());
        }

        // Phase 3: For each entry point, analyze its CALLBACK BODY specifically
        // — not the entire file. This prevents guard/source/sink leaking between handlers.
        foreach ($allEntryPoints as $ep) {
            $cbFile = $ep['callback']['file'] ?? null;
            $cbLineStart = $ep['callback']['line_start'] ?? null;
            $cbLineEnd = $ep['callback']['line_end'] ?? null;

            if ($cbFile === null || $cbLineStart === null) continue;

            $ast = $astCache[$cbFile] ?? null;
            if ($ast === null) {
                // File not in cache — try to parse it
                $absPath = $this->pluginDir . '/' . $cbFile;
                if (!file_exists($absPath)) continue;
                $code = file_get_contents($absPath);
                if ($code === false) continue;
                try {
                    $ast = $parser->parse($code);
                    if ($ast === null) continue;
                    $nrt = new NodeTraverser();
                    $nrt->addVisitor(new NameResolver());
                    $ast = $nrt->traverse($ast);
                } catch (\Throwable $e) {
                    continue;
                }
            }

            // Extract ONLY the callback function/method body from AST
            $callbackBody = $this->extractCallbackBody(
                $ast, $ep['callback'], $cbLineStart, $cbLineEnd
            );

            if ($callbackBody === null || $callbackBody === []) {
                // Fallback: if we can't isolate the body, use the full AST
                // but this is less accurate (guard leaking possible)
                $callbackBody = $ast;
            }

            // Run GuardVisitor on callback body ONLY
            // ParentConnectingVisitor must run first so GuardVisitor::determineEffectiveness()
            // can access $node->getAttribute('parent') for IR-04 effectiveness checks.
            $guardVisitor = new GuardVisitor($cbFile, $ep['id']);
            $gt = new NodeTraverser();
            $gt->addVisitor(new ParentConnectingVisitor());
            $gt->addVisitor($guardVisitor);
            $gt->traverse($callbackBody);
            $allGuards = array_merge($allGuards, $guardVisitor->getGuards());

            // DI-26-01: Also run GuardVisitor on the permission_callback method body.
            // REST EPs with array callable permission_callbacks ([$this, 'method']) now store
            // a resolved callback reference in 'permission_callback_ref'. Guards found in the
            // permission_callback method body are authoritative access-control guards for the EP.
            $pcRef = $ep['permission_callback_ref'] ?? null;
            if ($pcRef !== null && is_array($pcRef)) {
                $pcFile      = $pcRef['file'] ?? null;
                $pcLineStart = $pcRef['line_start'] ?? null;
                $pcLineEnd   = $pcRef['line_end'] ?? null;

                if ($pcFile !== null && $pcLineStart !== null) {
                    $pcAst = $astCache[$pcFile] ?? null;
                    if ($pcAst === null) {
                        $pcAbsPath = $this->pluginDir . '/' . $pcFile;
                        if (file_exists($pcAbsPath)) {
                            $pcCode = file_get_contents($pcAbsPath);
                            if ($pcCode !== false) {
                                try {
                                    $pcAst = $parser->parse($pcCode);
                                    if ($pcAst !== null) {
                                        $pcNrt = new NodeTraverser();
                                        $pcNrt->addVisitor(new NameResolver());
                                        $pcAst = $pcNrt->traverse($pcAst);
                                        $astCache[$pcFile] = $pcAst;
                                    }
                                } catch (\Throwable $e) {
                                    // Parse failure — skip permission_callback guard scan
                                }
                            }
                        }
                    }

                    if ($pcAst !== null) {
                        $pcBody = $this->extractCallbackBody($pcAst, $pcRef, $pcLineStart, $pcLineEnd);
                        if ($pcBody !== null && $pcBody !== []) {
                            // Guards in permission_callback body are attributed to the same EP id.
                            $pcGuardVisitor = new GuardVisitor($pcFile, $ep['id']);
                            $pcGt = new NodeTraverser();
                            $pcGt->addVisitor(new ParentConnectingVisitor());
                            $pcGt->addVisitor($pcGuardVisitor);
                            $pcGt->traverse($pcBody);
                            $allGuards = array_merge($allGuards, $pcGuardVisitor->getGuards());
                        }
                    }
                }
            }

            // Run SourceSinkVisitor on callback body ONLY, with entry_point_id
            $ssVisitor = new SourceSinkVisitor($cbFile, $ep['id']);
            $st = new NodeTraverser();
            $st->addVisitor($ssVisitor);
            $st->traverse($callbackBody);
            $allSources = array_merge($allSources, $ssVisitor->getSources());
            $allSinks = array_merge($allSinks, $ssVisitor->getSinks());

            // IR-02: Shallow call chain resolution (depth=2).
            // When callback delegates to $this->method(), resolve that method body
            // and run SourceSinkVisitor on it, inheriting the same entry_point_id.
            $cbClass = $ep['callback']['class'] ?? null;
            if ($cbClass !== null) {
                $callNodes = $this->extractMethodCalls($callbackBody);
                $visited = [];
                [$chainSources, $chainSinks] = $this->resolveCallChain(
                    $callNodes, $this->symbols, $cbClass, $ep['id'],
                    $parser, $astCache, 0, 2, $visited
                );
                $allSources = array_merge($allSources, $chainSources);
                $allSinks   = array_merge($allSinks, $chainSinks);
            }
        }

        // Phase 4: Also collect file-level sources/sinks for files with NO entry points
        // (e.g., init hooks with inline code not in a callback).
        // A-01: Also detect coverage gaps — files with WP security signals but no entry point.
        $securitySignals = [
            'wp_verify_nonce', 'check_ajax_referer', 'current_user_can',
            'wp_die', '$wpdb', 'sanitize_',
        ];
        $coverageGaps = [];
        foreach ($astCache as $relPath => $ast) {
            // IR-09: pass isFileLevel=true to suppress output_return false positives
            $ssVisitor = new SourceSinkVisitor($relPath, null, true);
            $st = new NodeTraverser();
            $st->addVisitor($ssVisitor);
            $st->traverse($ast);
            // Only add sinks NOT already associated with an entry point
            foreach ($ssVisitor->getSinks() as $sink) {
                // Check if this line+file is already captured by an entry-point-scoped sink
                $duplicate = false;
                foreach ($allSinks as $existing) {
                    if ($existing['file'] === $sink['file'] && $existing['line'] === $sink['line']) {
                        $duplicate = true;
                        break;
                    }
                }
                if (!$duplicate) {
                    $allSinks[] = $sink;
                }
            }
            foreach ($ssVisitor->getSources() as $source) {
                $duplicate = false;
                foreach ($allSources as $existing) {
                    if ($existing['file'] === $source['file'] && $existing['line'] === $source['line']) {
                        $duplicate = true;
                        break;
                    }
                }
                if (!$duplicate) {
                    $allSources[] = $source;
                }
            }

            // A-01: Coverage gap detection.
            // A file is a gap if it has WP security signals but NO discovered entry point.
            // String-level scan (intentionally shallow — not AST).
            if (!$this->hasEntryPoints($relPath, $allEntryPoints)) {
                $absPath = $this->pluginDir . '/' . $relPath;
                $rawSource = file_get_contents($absPath);
                if ($rawSource !== false) {
                    $signals = [];
                    foreach ($securitySignals as $sig) {
                        if (str_contains($rawSource, $sig)) {
                            $signals[] = $sig;
                        }
                    }
                    if (!empty($signals)) {
                        $coverageGaps[] = [
                            'file'    => $relPath,
                            'signals' => $signals,
                            'reason'  => 'has_security_functions_but_no_entry_point',
                        ];
                    }
                }
            }
        }

        // Phase 5: Extract plugin metadata
        $metadata = $this->extractMetadata($files, $totalLoc);

        // Assemble IR
        $this->ir = [
            'metadata'         => $metadata,
            'entry_points'     => $allEntryPoints,
            'unresolved_hooks' => $allUnresolvedHooks,
            'guards'           => $allGuards,
            'sources'          => $allSources,
            'sinks'            => $allSinks,
            'coverage_gaps'    => $coverageGaps,
            'anomalies'        => [], // Populated by AnomalyRules
        ];

        return $this->ir;
    }

    /**
     * IR-02: Shallow call chain resolution.
     *
     * For each MethodCall node in $callExprNodes that targets $this->method(),
     * look up the method body in the SymbolTable, run SourceSinkVisitor on it
     * (inheriting $entryPointId), and recurse up to $maxDepth.
     *
     * Cycle detection uses $visited keyed by "ClassName::methodName".
     *
     * @param \PhpParser\Node[] $callExprNodes  Statement/expression nodes from callback body
     * @param SymbolTable       $symbols
     * @param string            $currentClass   Class context of the callback
     * @param string            $entryPointId   Inherited from parent callback
     * @param \PhpParser\Parser $parser         Re-use the parser instance
     * @param array             $astCache       Map relPath → AST (populated by Phase 2)
     * @param int               $depth          Current recursion depth (starts at 0)
     * @param int               $maxDepth       Maximum depth before stopping (default 2)
     * @param array             $visited        Passed by reference for cycle detection
     * @return array{0: array, 1: array}        [sources[], sinks[]]
     */
    private function resolveCallChain(
        array $callExprNodes,
        SymbolTable $symbols,
        string $currentClass,
        string $entryPointId,
        \PhpParser\Parser $parser,
        array &$astCache,
        int $depth = 0,
        int $maxDepth = 2,
        array &$visited = []
    ): array {
        if ($depth >= $maxDepth) return [[], []];

        $additionalSources = [];
        $additionalSinks   = [];

        foreach ($callExprNodes as $callNode) {
            if (!($callNode instanceof \PhpParser\Node\Expr\MethodCall)) continue;

            // Only resolve $this->method() calls (Variable name === 'this')
            if (!($callNode->var instanceof \PhpParser\Node\Expr\Variable)) continue;
            if ($callNode->var->name !== 'this') continue;
            if (!($callNode->name instanceof \PhpParser\Node\Identifier)) continue;

            $methodName = $callNode->name->toString();
            $key = "{$currentClass}::{$methodName}";
            if (isset($visited[$key])) continue; // cycle detection
            $visited[$key] = true;

            $methodInfo = $symbols->findMethod($currentClass, $methodName);
            if ($methodInfo === null) continue; // not resolvable → skip

            // Get AST for the file containing this method
            $relPath = $methodInfo['file'];
            $methodAst = $astCache[$relPath] ?? null;
            if ($methodAst === null) {
                // File not yet parsed — load and cache it
                $absPath = $this->pluginDir . '/' . $relPath;
                if (!file_exists($absPath)) continue;
                $code = file_get_contents($absPath);
                if ($code === false) continue;
                try {
                    $methodAst = $parser->parse($code);
                    if ($methodAst === null) continue;
                    $nrt = new NodeTraverser();
                    $nrt->addVisitor(new \PhpParser\NodeVisitor\NameResolver());
                    $methodAst = $nrt->traverse($methodAst);
                    $astCache[$relPath] = $methodAst;
                } catch (\Throwable $e) {
                    continue;
                }
            }

            // Extract method body
            $methodBody = $this->extractCallbackBody(
                $methodAst,
                ['type' => 'method', 'name' => $methodName, 'class' => $currentClass],
                $methodInfo['line_start'],
                $methodInfo['line_end']
            );
            if ($methodBody === null || $methodBody === []) continue;

            // Run SourceSinkVisitor on resolved method body, inherit entry_point_id
            $ssv = new SourceSinkVisitor($relPath, $entryPointId);
            $ssvT = new NodeTraverser();
            $ssvT->addVisitor($ssv);
            $ssvT->traverse($methodBody);
            $additionalSources = array_merge($additionalSources, $ssv->getSources());
            $additionalSinks   = array_merge($additionalSinks,   $ssv->getSinks());

            // Recurse into method body calls (depth+1)
            $nestedCalls = $this->extractMethodCalls($methodBody);
            [$nestedSrc, $nestedSink] = $this->resolveCallChain(
                $nestedCalls, $symbols, $currentClass, $entryPointId,
                $parser, $astCache, $depth + 1, $maxDepth, $visited
            );
            $additionalSources = array_merge($additionalSources, $nestedSrc);
            $additionalSinks   = array_merge($additionalSinks,   $nestedSink);
        }

        return [$additionalSources, $additionalSinks];
    }

    /**
     * IR-02: Walk a list of statement nodes and collect all MethodCall expression
     * nodes at any nesting depth. Used to feed resolveCallChain() with the call
     * sites present inside a callback or resolved method body.
     *
     * @param \PhpParser\Node[] $stmts
     * @return \PhpParser\Node\Expr\MethodCall[]
     */
    private function extractMethodCalls(array $stmts): array
    {
        $calls = [];
        $collector = new class extends \PhpParser\NodeVisitorAbstract {
            public array $calls = [];
            public function enterNode(\PhpParser\Node $node)
            {
                if ($node instanceof \PhpParser\Node\Expr\MethodCall) {
                    $this->calls[] = $node;
                }
                return null;
            }
        };
        $t = new NodeTraverser();
        $t->addVisitor($collector);
        $t->traverse($stmts);
        return $collector->calls;
    }

    /**
     * Extract the callback function/method body from the full file AST.
     * Returns array of statement nodes (the function body), or null if not found.
     */
    private function extractCallbackBody(array $ast, array $callback, int $lineStart, int $lineEnd): ?array
    {
        $type = $callback['type'] ?? null;
        $name = $callback['name'] ?? null;
        $class = $callback['class'] ?? null;
        $found = null;

        $finder = new class($type, $name, $class, $lineStart, $lineEnd) extends \PhpParser\NodeVisitorAbstract {
            public ?array $body = null;
            private ?string $type;
            private ?string $name;
            private ?string $class;
            private int $lineStart;
            private int $lineEnd;
            /** Short class name of the Class_ node currently being traversed, or null if at file level. */
            private ?string $currentClass = null;

            public function __construct(?string $type, ?string $name, ?string $class, int $lineStart, int $lineEnd)
            {
                $this->type = $type;
                $this->name = $name;
                $this->class = $class;
                $this->lineStart = $lineStart;
                $this->lineEnd = $lineEnd;
            }

            public function enterNode(\PhpParser\Node $node)
            {
                if ($this->body !== null) return null; // Already found

                // Track which class we are currently traversing so method matches
                // can be scoped correctly (prevents wrong-class-same-name false match).
                // Use namespacedName when available — same pattern as SymbolTable and
                // EntryPointVisitor — so the key is always a FQCN (e.g. "A\\Worker").
                if ($node instanceof \PhpParser\Node\Stmt\Class_) {
                    $this->currentClass = isset($node->namespacedName)
                        ? $node->namespacedName->toString()
                        : ($node->name !== null ? $node->name->toString() : null);
                }

                // Match by type
                if ($this->type === 'function' && $node instanceof \PhpParser\Node\Stmt\Function_) {
                    if ($node->name->toString() === $this->name ||
                        $node->getStartLine() === $this->lineStart) {
                        $this->body = $node->stmts ?? [];
                        return \PhpParser\NodeVisitor::DONT_TRAVERSE_CHILDREN;
                    }
                }

                if (($this->type === 'method' || $this->type === 'static_method')
                    && $node instanceof \PhpParser\Node\Stmt\ClassMethod) {
                    // When a target class is known, require that the method belongs to that class.
                    // Both $this->class (from resolveCallChain) and $this->currentClass (tracked above)
                    // are fully-qualified names produced by the same namespacedName pattern used in
                    // SymbolTable and EntryPointVisitor. Exact equality is the correct check.
                    $classMatches = ($this->class === null)
                        || ($this->currentClass !== null && $this->currentClass === $this->class);

                    if ($classMatches && (
                        $node->name->toString() === $this->name ||
                        $node->getStartLine() === $this->lineStart
                    )) {
                        $this->body = $node->stmts ?? [];
                        return \PhpParser\NodeVisitor::DONT_TRAVERSE_CHILDREN;
                    }
                }

                if ($this->type === 'closure') {
                    if (($node instanceof \PhpParser\Node\Expr\Closure ||
                         $node instanceof \PhpParser\Node\Expr\ArrowFunction)
                        && $node->getStartLine() === $this->lineStart) {
                        if ($node instanceof \PhpParser\Node\Expr\Closure) {
                            $this->body = $node->stmts ?? [];
                        } else {
                            // ArrowFunction: body is a single expression
                            $this->body = [$node->expr];
                        }
                        return \PhpParser\NodeVisitor::DONT_TRAVERSE_CHILDREN;
                    }
                }

                // Fallback: match by line range
                if ($this->body === null) {
                    if (($node instanceof \PhpParser\Node\Stmt\Function_ ||
                         $node instanceof \PhpParser\Node\Stmt\ClassMethod)
                        && $node->getStartLine() === $this->lineStart
                        && $node->getEndLine() === $this->lineEnd) {
                        $this->body = $node->stmts ?? [];
                        return \PhpParser\NodeVisitor::DONT_TRAVERSE_CHILDREN;
                    }
                }

                return null;
            }

            public function leaveNode(\PhpParser\Node $node)
            {
                if ($node instanceof \PhpParser\Node\Stmt\Class_) {
                    $this->currentClass = null;
                }
                return null;
            }
        };

        $traverser = new NodeTraverser();
        $traverser->addVisitor($finder);
        $traverser->traverse($ast);

        return $finder->body;
    }

    /**
     * A-01: Returns true if any discovered entry point has its callback in $relPath.
     * Used during Phase 4 to skip coverage gap detection for files that already have EPs.
     */
    private function hasEntryPoints(string $relPath, array $allEntryPoints): bool
    {
        foreach ($allEntryPoints as $ep) {
            if (($ep['callback']['file'] ?? null) === $relPath) {
                return true;
            }
        }
        return false;
    }

    /**
     * Extract plugin metadata from main file header + readme.txt
     */
    private function extractMetadata(array $files, int $totalLoc): array
    {
        $slug = basename($this->pluginDir);
        $name = $slug;
        $version = null;
        $activeInstalls = null;

        // Parse main plugin file header
        $mainFile = $this->findMainPluginFile();
        if ($mainFile !== null) {
            $content = file_get_contents($mainFile);
            if ($content !== false) {
                if (preg_match('/Plugin Name:\s*(.+)/i', $content, $m)) {
                    $name = trim($m[1]);
                }
                if (preg_match('/Version:\s*(.+)/i', $content, $m)) {
                    $version = trim($m[1]);
                }
            }
        }

        // Parse readme.txt for install count
        $readme = $this->pluginDir . '/readme.txt';
        if (file_exists($readme)) {
            $content = file_get_contents($readme);
            if ($content !== false && preg_match('/Tested up to:\s*(.+)/i', $content, $m)) {
                // readme.txt doesn't contain installs, but we capture what we can
            }
        }

        $elapsedMs = (int)((microtime(true) - $this->startTime) * 1000);

        return [
            'plugin_slug' => $slug,
            'plugin_name' => $name,
            'version' => $version,
            'active_installs' => $activeInstalls,
            'files_analyzed' => count($files),
            'total_loc' => $totalLoc,
            'extraction_time_ms' => $elapsedMs,
            'extractor_version' => '1.0.0',
        ];
    }

    /**
     * Find the main plugin PHP file (contains "Plugin Name:" header).
     */
    private function findMainPluginFile(): ?string
    {
        $slug = basename($this->pluginDir);

        // Try slug.php first
        $candidate = $this->pluginDir . '/' . $slug . '.php';
        if (file_exists($candidate) && $this->hasPluginHeader($candidate)) {
            return $candidate;
        }

        // Scan root-level PHP files
        $rootFiles = glob($this->pluginDir . '/*.php');
        foreach ($rootFiles ?: [] as $file) {
            if ($this->hasPluginHeader($file)) {
                return $file;
            }
        }

        return null;
    }

    private function hasPluginHeader(string $file): bool
    {
        $content = file_get_contents($file);
        if ($content === false) return false;
        // Check first 8KB only
        $header = substr($content, 0, 8192);
        return stripos($header, 'Plugin Name:') !== false;
    }

    // --- Utilities ---

    private function findPhpFiles(string $dir): array
    {
        $files = [];
        $iterator = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($dir, \RecursiveDirectoryIterator::SKIP_DOTS),
            \RecursiveIteratorIterator::LEAVES_ONLY
        );
        foreach ($iterator as $fileInfo) {
            if ($fileInfo->getExtension() === 'php') {
                $path = $fileInfo->getPathname();
                // Skip vendor/node_modules/.git WITHIN the plugin directory.
                // Use path relative to $dir so we don't accidentally filter
                // files based on the path TO the plugin (e.g. tests/fixtures/...).
                $relPath = substr($path, strlen(rtrim($dir, '/')));
                if (preg_match('#/(vendor|node_modules|\.git)/#', $relPath)) continue;
                $files[] = $path;
            }
        }
        return $files;
    }

    private function relativePath(string $absolute): string
    {
        if (str_starts_with($absolute, $this->pluginDir)) {
            return ltrim(substr($absolute, strlen($this->pluginDir)), '/');
        }
        return $absolute;
    }

    public function getIR(): array { return $this->ir; }
    public function getSymbolTable(): SymbolTable { return $this->symbols; }
}
