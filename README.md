# WordPress Security Review Methodology

This workspace performs source-first WordPress plugin security reviews through a Kiro skill. The default workflow does not require local PHP, Composer, Semgrep, Psalm, or a pre-scan.

## Use in Kiro

Place or reference a plugin source directory, start a new Kiro session so workspace skills are discovered, then invoke:

```text
/wp-security-audit plugins/<slug>
```

You may also pass an absolute plugin path or add a bounded scope after the target. The main agent maps the source, delegates focused sequential tasks when useful, traces and refutes hypotheses, and returns one unified review. It does not use Worker/Reviewer rounds or a separate Phase 3.

The default IDE agentic session can run the skill when sub-agent delegation is available. If the session does not expose delegation, select the workspace agent `wp-security-audit` in Kiro and invoke the skill again. CLI users can start that profile with `kiro-cli chat --agent wp-security-audit`. Do not compensate for a missing delegate capability by running scanners or the legacy pipeline first.

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
