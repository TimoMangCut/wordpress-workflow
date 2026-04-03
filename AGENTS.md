# AGENTS.md - WordPress Audit Workspace

> This file contains project-local routing for this workspace.
> Reusable AppSec identity and workflow belong in the home configuration and skills.
> Project docs in `./docs` are shared with both Codex and Claude and should be treated as ground truth.

## Read First

- `docs/wp-context.md`
- `docs/bug-bounty-rules-summary.md`

If project docs conflict with generic assumptions, project docs win.

## Workspace Purpose

- This workspace is used for WordPress security review and audit work.
- The main subjects are plugins and adjacent WordPress components inside this repository.
- Reviews may be full-source audits or targeted component reviews.

## Local Review Focus

Prioritize:

- unauthenticated entry points
- AJAX and REST routes
- nonce and capability enforcement
- privilege escalation and authorization gaps
- file upload, download, delete, and path construction
- SQL, option/meta updates, and deserialization paths
- SSRF, RCE, arbitrary write, arbitrary delete, and account takeover impact

## Local Rules

- Ground all exploitability judgments in WordPress behavior and the docs in this repo.
- Separate exploitability from reportability; bounty rules may narrow what is actionable.
- When reviewing a plugin or component, identify the relevant trust boundary before rating severity.
- Note secure areas reviewed so coverage is visible.

## Output Expectations

- Use exactly one of `CONFIRMED`, `UNCERTAIN`, `RISK_NOTE`, or `REJECTED` for each issue.
- Every mature conclusion must include code references and at least one refutation attempt.
- If context is missing and cannot be inferred safely, state assumptions explicitly.

## Keep This File Local

This file should stay focused on project-specific context.
Do not duplicate the global identity, reusable AppSec workflow, or long generic methodology here.
