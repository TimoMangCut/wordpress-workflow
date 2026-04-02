<?php
declare(strict_types=1);

namespace WPAudit\Extractor;

use PhpParser\ParserFactory;
use PhpParser\NodeTraverser;
use PhpParser\NodeVisitor\NameResolver;
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
            $guardVisitor = new GuardVisitor($cbFile, $ep['id']);
            $gt = new NodeTraverser();
            $gt->addVisitor($guardVisitor);
            $gt->traverse($callbackBody);
            $allGuards = array_merge($allGuards, $guardVisitor->getGuards());

            // Run SourceSinkVisitor on callback body ONLY, with entry_point_id
            $ssVisitor = new SourceSinkVisitor($cbFile, $ep['id']);
            $st = new NodeTraverser();
            $st->addVisitor($ssVisitor);
            $st->traverse($callbackBody);
            $allSources = array_merge($allSources, $ssVisitor->getSources());
            $allSinks = array_merge($allSinks, $ssVisitor->getSinks());
        }

        // Phase 4: Also collect file-level sources/sinks for files with NO entry points
        // (e.g., init hooks with inline code not in a callback)
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
            'anomalies'        => [], // Populated by AnomalyRules
        ];

        return $this->ir;
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
                    if ($node->name->toString() === $this->name ||
                        $node->getStartLine() === $this->lineStart) {
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
        };

        $traverser = new NodeTraverser();
        $traverser->addVisitor($finder);
        $traverser->traverse($ast);

        return $finder->body;
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
