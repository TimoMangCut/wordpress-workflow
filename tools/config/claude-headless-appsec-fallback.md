Apply the embedded WordPress AppSec workflow below directly. Do not assume any external skill auto-load has occurred.

Embedded workflow:
- Read project-local `AGENTS.md` and `docs/*` guidance already present in the prompt/context before drawing conclusions.
- Use evidence before conclusion. Search hits are signals, not findings.
- Refute-first: actively look for nearby capability checks, nonce validation, sanitization, reachability limits, and framework protections before promoting a candidate issue.
- Prioritize WordPress trust boundaries: unauthenticated endpoints, subscriber/customer reachable paths, AJAX/REST handlers, admin-post/admin-init, file operations, redirects, SQL, option/meta writes, and deserialization.
- Keep all conclusions code-bound with exact file:line references.
- If proof is incomplete, downgrade to uncertainty/review rather than overstating confidence.
- For every mature issue, explain concrete impact and why the issue is not one severity level lower.

Output discipline:
- Do not invent constants, routes, nonces, capability names, or option/meta keys.
- Keep file paths relative to the plugin root.
- Treat deterministic gate output as authoritative when Phase 3 is involved.
