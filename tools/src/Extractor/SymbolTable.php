<?php
declare(strict_types=1);

namespace WPAudit\Extractor;

use PhpParser\Node;
use PhpParser\NodeTraverser;
use PhpParser\NodeVisitor\NameResolver;
use PhpParser\NodeVisitorAbstract;
use PhpParser\ParserFactory;

class SymbolTable
{
    private array $functions = [];
    private array $classes = [];
    private string $pluginRoot;

    public function __construct(string $pluginRoot)
    {
        $this->pluginRoot = rtrim(realpath($pluginRoot) ?: $pluginRoot, '/');
    }

    public function build(): void
    {
        $parser = (new ParserFactory())->createForHostVersion();
        $files = $this->findPhpFiles($this->pluginRoot);

        foreach ($files as $file) {
            $code = file_get_contents($file);
            if ($code === false) continue;

            try {
                $ast = $parser->parse($code);
                if ($ast === null) continue;
            } catch (\Throwable $e) {
                continue;
            }

            // CRITICAL: Run NameResolver on AST BEFORE collectDeclarations.
            // Without this, Function_::$namespacedName and Class_::$namespacedName
            // remain uninitialized typed properties in php-parser v5.
            // Accessing an uninitialized typed property throws Error in PHP 8.3
            // even with nullsafe ?-> operator.
            $nameResolverTraverser = new NodeTraverser();
            $nameResolverTraverser->addVisitor(new NameResolver());
            $ast = $nameResolverTraverser->traverse($ast);

            $relPath = $this->relativePath($file);
            $this->collectDeclarations($ast, $relPath);
        }
    }

    private function collectDeclarations(array $stmts, string $file): void
    {
        $traverser = new NodeTraverser();
        $visitor = new class($file) extends NodeVisitorAbstract {
            public array $functions = [];
            public array $classes = [];
            private string $file;
            private ?string $currentClass = null;

            public function __construct(string $file)
            {
                $this->file = $file;
            }

            public function enterNode(Node $node)
            {
                if ($node instanceof Node\Stmt\Function_) {
                    // php-parser v5: namespacedName is typed `Name`, not `?Name`.
                    // isset() returns false for uninitialized typed props without throwing.
                    // Do NOT use $node->namespacedName?->toString() — it crashes.
                    $name = isset($node->namespacedName)
                        ? $node->namespacedName->toString()
                        : $node->name->toString();
                    $this->functions[$name] = [
                        'file' => $this->file,
                        'line_start' => $node->getStartLine(),
                        'line_end' => $node->getEndLine(),
                    ];
                }

                if ($node instanceof Node\Stmt\Class_) {
                    // Same pattern: isset() guard on namespacedName
                    $name = isset($node->namespacedName)
                        ? $node->namespacedName->toString()
                        : ($node->name !== null ? $node->name->toString() : '');
                    if ($name === '') return null;
                    $this->currentClass = $name;
                    $this->classes[$name] = [
                        'file' => $this->file,
                        'line_start' => $node->getStartLine(),
                        'line_end' => $node->getEndLine(),
                        'methods' => [],
                        'extends' => ($node->extends !== null) ? $node->extends->toString() : null,
                    ];
                }

                if ($node instanceof Node\Stmt\ClassMethod && $this->currentClass !== null) {
                    $this->classes[$this->currentClass]['methods'][$node->name->toString()] = [
                        'file' => $this->file,
                        'line_start' => $node->getStartLine(),
                        'line_end' => $node->getEndLine(),
                        'is_static' => $node->isStatic(),
                        'is_public' => $node->isPublic(),
                    ];
                }

                return null;
            }

            public function leaveNode(Node $node)
            {
                if ($node instanceof Node\Stmt\Class_) {
                    $this->currentClass = null;
                }
                return null;
            }
        };

        $traverser->addVisitor($visitor);
        $traverser->traverse($stmts);

        $this->functions = array_merge($this->functions, $visitor->functions);
        foreach ($visitor->classes as $name => $info) {
            $this->classes[$name] = $info;
        }
    }

    public function findFunction(string $name): ?array { return $this->functions[$name] ?? null; }
    public function findMethod(string $class, string $method): ?array { return $this->classes[$class]['methods'][$method] ?? null; }
    public function findClass(string $name): ?array { return $this->classes[$name] ?? null; }
    public function getAllFunctions(): array { return $this->functions; }
    public function getAllClasses(): array { return $this->classes; }

    /**
     * Search ALL classes for a method by name. Used when the class is unknown
     * (e.g., callback registered as [$variable, 'methodName'] where $variable
     * is not $this but an instantiated object stored in a variable).
     * This is the #1 callback pattern in real WordPress plugins.
     *
     * @return array<int, array{class: string, file: string, line_start: int, line_end: int}>
     */
    public function findMethodInAllClasses(string $method): array
    {
        $results = [];
        foreach ($this->classes as $className => $classInfo) {
            if (isset($classInfo['methods'][$method])) {
                $results[] = array_merge(
                    $classInfo['methods'][$method],
                    ['class' => $className]
                );
            }
        }
        return $results;
    }

    private function findPhpFiles(string $dir): array
    {
        $files = [];
        $it = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($dir, \RecursiveDirectoryIterator::SKIP_DOTS),
            \RecursiveIteratorIterator::LEAVES_ONLY
        );
        foreach ($it as $f) {
            if ($f->getExtension() === 'php') $files[] = $f->getPathname();
        }
        return $files;
    }

    private function relativePath(string $absolute): string
    {
        return str_starts_with($absolute, $this->pluginRoot)
            ? ltrim(substr($absolute, strlen($this->pluginRoot)), '/')
            : $absolute;
    }

    public function getPluginRoot(): string { return $this->pluginRoot; }
}
