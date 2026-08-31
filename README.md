# WordPress Security Review Methodology

This workspace performs source-first WordPress plugin security reviews as a single-agent skill. It runs identically across Kiro, Claude Code, Codex, and Antigravity: one model does the whole review in one session.

## How it runs

Invoke the skill with a plugin target:

```text
/wp-security-audit plugins/<slug>
```

You may also pass an absolute plugin path or add a bounded scope after the target. One model performs the entire review:

1. **Self-parse (no tools):** the model reads the source and builds its own IR/AST/SAST-style understanding by reasoning alone, then seals that source ledger.
2. **Required tools:** it runs the packaged Docker analyzers (inventory + AST/IR, and corroborating Semgrep/Psalm) and reconciles its own parse against the machine parse — the difference is coverage signal.
3. **Adjudicate:** using both, the same model traces, refutes, and returns one unified verdict.

This project **never** spawns Worker/Reviewer sub-agents, mappers, investigators, or validators, never runs the legacy Phase 1/2/3 pipeline, and never fans out parallel sessions — that only wastes quota. The tools are mandatory support for the model's own parse, not a pipeline.

Per-IDE entry points:

- **Kiro:** start a new session so `.kiro/skills/` is discovered, then invoke the skill; CLI `kiro-cli chat --agent wp-security-audit`.
- **Claude Code:** the skill lives in `.claude/skills/wp-security-audit/`; invoke `/wp-security-audit <plugin>` in the main session.
- **Codex / Antigravity:** the same skill is mirrored under `.codex/` and `.agents/`.

Active methodology:

- `docs/wp-context.md`
- `docs/review-methodology.md`
- `.kiro/skills/wp-security-audit/SKILL.md`

## Structural Docker baseline and optional diagnostics

Build the versioned helper image once (Semgrep and Composer dependencies are pinned; base OS/PHP/Composer tags and Debian packages remain mutable unless you pin them by digest/snapshot):

```bash
bash tools/bin/wp-audit-tools.sh build
```

After source-led mapping is sealed, every canonical review runs the read-only structural baseline:

```bash
bash tools/bin/wp-audit-tools.sh inventory plugins/<slug>
bash tools/bin/wp-audit-tools.sh ast plugins/<slug>
```

The agent reconciles parser-only/source-only surfaces, parse gaps, and unresolved dynamic edges before `COMPLETE`. AST/IR is coverage evidence, not a verdict source.

Optional diagnostics answer bounded questions and do not block completion:

```bash
bash tools/bin/wp-audit-tools.sh search plugins/<slug> 'register_rest_route'
bash tools/bin/wp-audit-tools.sh semgrep plugins/<slug>
bash tools/bin/wp-audit-tools.sh psalm plugins/<slug>
```

Semgrep Community may be used without authentication; Pro engine access is optional. The plugin is mounted read-only. Default artifacts go to `reports/tooling/<slug>/`. There is intentionally no command that runs all analyzers.

## Knowledge boundaries

- Stable WordPress semantics are active context.
- The pattern catalogue is consulted only after source-led discovery or on demand.
- Bug-bounty policy is consulted only after technical verdicts and only when requested.
- The former all-in-one context is preserved under `docs/archive/` for research, not default prompting.

## Legacy pipeline

The previous Phase 1/2/3 pipeline remains under `tools/bin/` for historical reproduction or explicit corroboration. It requires host dependencies unless adapted to the helper image and is not the default review path. See `WORKFLOW-GUIDE.md`.
