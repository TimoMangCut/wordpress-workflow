#!/usr/bin/env php
<?php

declare(strict_types=1);

require __DIR__ . '/../vendor/autoload.php';

use PhpParser\NodeTraverser;
use PhpParser\ParserFactory;
use PsalmWordPress\HookNodeVisitor;
use PsalmWordPress\Plugin;

function fail(string $message): int
{
    fwrite(STDERR, "[FAIL] " . $message . PHP_EOL);
    return 1;
}

function parse_expr_node(string $exprCode): object
{
    $parser = (new ParserFactory())->createForHostVersion();
    $ast = $parser->parse("<?php " . $exprCode . ";");
    if (!is_array($ast) || !isset($ast[0]) || !isset($ast[0]->expr) || !is_object($ast[0]->expr)) {
        throw new RuntimeException("Cannot parse expression: " . $exprCode);
    }
    return $ast[0]->expr;
}

function parse_array_dim_null_node(): object
{
    $parser = (new ParserFactory())->createForHostVersion();
    $ast = $parser->parse("<?php \$arr[] = 'x';");
    if (!is_array($ast) || !isset($ast[0]) || !isset($ast[0]->expr) || !is_object($ast[0]->expr)) {
        throw new RuntimeException("Cannot parse array_dim_null fixture");
    }

    $assign = $ast[0]->expr;
    if (!isset($assign->var) || !is_object($assign->var)) {
        throw new RuntimeException("Cannot extract ArrayDimFetch(var) from array_dim_null fixture");
    }

    return $assign->var;
}

$cases = [
    ["name" => "ternary_dynamic", "expr" => "(true ? 'a' : 'b')"],
    ["name" => "coalesce_dynamic", "expr" => "(\$foo ?? 'fallback')"],
    ["name" => "string_cast_dynamic", "expr" => "(string) \$foo"],
    ["name" => "assign_dynamic", "expr" => "(\$hook = 'prefix_' . \$foo)"],
    ["name" => "match_dynamic", "expr" => "match (\$foo) { 1 => 'hook_a', default => 'hook_b' }"],
    ["name" => "array_dim_dynamic", "expr" => "\$arr[\$idx]"],
    ["name" => "magic_const_class", "expr" => "__CLASS__"],
];

foreach ($cases as $case) {
    try {
        $node = parse_expr_node($case["expr"]);
        $result = Plugin::safeGetDynamicHookName($node, "smoke:" . $case["name"]);
        if (!is_string($result) && !is_null($result)) {
            exit(fail("Unexpected return type for " . $case["name"]));
        }
    } catch (Throwable $e) {
        exit(fail("Dynamic hook case crashed (" . $case["name"] . "): " . $e->getMessage()));
    }
}

try {
    $arrayDimNullNode = parse_array_dim_null_node();
    $result = Plugin::safeGetDynamicHookName($arrayDimNullNode, "smoke:array_dim_null");
    if (!is_string($result) && !is_null($result)) {
        exit(fail("Unexpected return type for array_dim_null"));
    }
} catch (Throwable $e) {
    exit(fail("Dynamic hook case crashed (array_dim_null): " . $e->getMessage()));
}

try {
    $result = Plugin::safeGetDynamicHookName(null, "smoke:null_arg");
    if (!is_string($result) && !is_null($result)) {
        exit(fail("Unexpected return type for null_arg"));
    }
} catch (Throwable $e) {
    exit(fail("Dynamic hook case crashed (null_arg): " . $e->getMessage()));
}

try {
    $parser = (new ParserFactory())->createForHostVersion();
    $ast = $parser->parse("<?php namespace { use Foo\\Bar; }");
    $traverser = new NodeTraverser();
    $traverser->addVisitor(new HookNodeVisitor());
    $traverser->traverse($ast ?? []);
} catch (Throwable $e) {
    exit(fail("Namespace global-block traversal crashed: " . $e->getMessage()));
}

fwrite(STDOUT, "[OK] Psalm fork smoke tests passed." . PHP_EOL);
exit(0);
