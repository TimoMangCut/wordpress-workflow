# WordPress Security Semantics

> Active context for source-first plugin review. This document defines stable WordPress semantics and reasoning constraints. It is not an exhaustive attack-surface list, vulnerability taxonomy, scanner rule set, or bounty policy.

## Context boundary

Derive threats from the selected plugin's behavior. The APIs and examples below are non-exhaustive. Do not assume that an unlisted source, sink, guard, hook, framework, or bug class is safe or irrelevant.

Observed plugin code controls current-state reasoning. WordPress documentation and runtime source control framework behavior. Historical CVEs are examples, not proof that similar-looking code is vulnerable.

## Identity, intent, and authority

- Authentication establishes an identity; it does not establish permission for every operation.
- Authorization must cover the concrete operation and, where relevant, the affected object, tenant, site, order, post, user, file, or option.
- A primitive capability is not automatically equivalent to an object-level meta capability.
- A nonce establishes request intent/freshness within WordPress's nonce model. It is neither authentication nor authorization and is not a one-time token.
- Guest nonces do not distinguish anonymous users unless the application supplies a separate guest identity mechanism.
- `is_admin()` describes the administrative request context. It does not prove an administrator role or capability.
- A guard is effective only when its failure terminates or excludes every path to the sensitive operation.

## Dispatch and reachability

- `wp_ajax_*` dispatches authenticated AJAX requests; `wp_ajax_nopriv_*` permits anonymous dispatch. Neither hook name alone proves that its callback is safe or vulnerable.
- `admin_post_*` and `admin_post_nopriv_*` follow the same authenticated/anonymous distinction for admin-post dispatch.
- REST route security depends on authentication resolution, route methods, `permission_callback`, callback behavior, and object-level checks. A deliberately public route may correctly use `__return_true`.
- Cookie-authenticated REST requests normally rely on the `wp_rest` nonce. Other authentication mechanisms can establish identity differently.
- Shortcode attributes, block attributes, webhook payloads, imports, stored options/meta, external API responses, cron state, and callback arguments cross different trust boundaries. Determine control from the actual write/read path.
- Hook registration is not enough: resolve the callback, loading conditions, request lifecycle, and alternate registrations before claiming reachability.
- Machine extraction is independent coverage evidence, not framework truth. A parser omission does not prove absence or safety.
- Dynamic hook names, callbacks, permission callbacks, method/property dispatch, and parse failures remain explicit coverage obligations until resolved or manually bounded from source.

## Data and defense semantics

- Sanitization, validation, normalization, authorization, and output encoding solve different problems. Do not substitute one for another.
- Output encoding must match the final context and occur after the last unsafe composition step.
- Database safety depends on the complete query construction. Prepared values do not make dynamic identifiers, clauses, or already-interpolated fragments safe.
- `$wpdb->insert()`, `update()`, `delete()`, and `replace()` parameterize values when used as intended; raw query methods require analysis of query construction.
- `sanitize_file_name()` does not establish path containment or trustworthy MIME/content. File safety also depends on canonical path, destination, extension/content validation, and execution context.
- `wp_safe_redirect()` validates allowed hosts but does not terminate execution. Whether missing termination matters depends on subsequent behavior.
- Stored values are not inherently trusted. Trace who can write them and how later consumers use them.
- Framework protection must be verified for the concrete WordPress/PHP/plugin version when the conclusion depends on version-specific behavior.

## Trace standard

For every mature hypothesis, establish or explicitly mark unresolved:

1. reachable registration and callback;
2. attacker identity, role, and control;
3. source or controllable state;
4. propagation and transformations;
5. guards and their control-flow effect;
6. sensitive operation;
7. concrete impact and prerequisites;
8. at least one attempted refutation.

Co-occurrence of a source, guard, and sink is not a data-flow proof. A familiar vulnerable pattern is not evidence for the current plugin.

## Verdict semantics

- `CONFIRMED`: complete reachable evidence supports exploitability and concrete refutations failed.
- `UNCERTAIN`: a material code, dependency, configuration, or runtime fact remains unresolved.
- `RISK_NOTE`: a security-relevant weakness or hardening concern exists without a demonstrated exploitable path.
- `REJECTED`: evidence refutes the hypothesis, shows adequate protection, or does not support the claim.

Severity describes impact under stated prerequisites. Confidence describes evidence quality. Reportability applies an external program policy after technical adjudication. Keep all three independent.

## Progressive disclosure

Always use this file and `review-methodology.md`. Do not load the optional pattern catalogue or reportability policy during initial discovery. Consult:

- `wordpress-pattern-catalogue.md` only after the source-led trace queue exists, or for a concrete unresolved question;
- `reportability-policy.md` only after technical verdicts are stable and the user requests submission triage;
- `archive/wp-context-full-legacy.md` only for historical research, never as the default review agenda.
