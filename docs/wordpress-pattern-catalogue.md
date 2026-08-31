# Optional WordPress Pattern Catalogue

> Recall aid only. Do not load during initial source-led discovery. This catalogue is non-exhaustive, does not establish priority for every plugin, and never converts a code pattern into a finding.

Use this document after a plugin-specific trace queue exists, or when a concrete question requires WordPress-specific recall. Every catalogue match must be traced and refuted against current source.

## Surface prompts

Consider whether the plugin exposes behavior through AJAX, REST, admin-post/admin-init, shortcodes, dynamic blocks, template redirects, custom rewrites, XML-RPC, WP-CLI, cron, webhooks, imports/exports, bulk actions, direct-access PHP files, frontend forms, or integrations supplied by another plugin.

The absence of a surface from this list does not remove it from scope.

## Trust-boundary prompts

- public → authenticated identity;
- subscriber/customer/contributor → privileged operation;
- user → another user's object;
- site administrator → network/super-admin or another site;
- browser intent → state-changing action;
- external webhook/provider → trusted internal state;
- stored option/meta/cache → later sensitive consumer;
- uploaded/archive content → filesystem/parser/execution context;
- plugin → vendor or arbitrary network destination.

## Sensitive-effect prompts

- authentication, password reset, session or token handling;
- role/capability/account creation or modification;
- object ownership and state transitions;
- option/meta/content/order/payment mutation;
- SQL query construction;
- HTML, attribute, URL, JavaScript, CSS, XML, CSV, or header output;
- file upload, extraction, read, write, delete, include, or path construction;
- deserialization, callback invocation, template evaluation, or command execution;
- outbound HTTP, redirect, email, cache, or log operations;
- secrets, PII, financial state, backups, configuration, and cross-site data.

## Common refutation prompts

- public endpoint intentionally exposes non-sensitive behavior;
- capability or object ownership is enforced in a wrapper/callee;
- nonce is irrelevant to a non-cookie/non-browser trust boundary;
- input is constrained by a domain allowlist or type before the sink;
- query values are parameterized and identifiers are allowlisted;
- path is canonicalized and contained beneath a non-executable destination;
- output is encoded after final composition for the exact context;
- framework/core behavior blocks the claimed path in the target version;
- action affects only the attacker's authorized state;
- registration is conditional, dead, or unreachable;
- impact depends on another component or non-default configuration not in evidence.

## Historical material

The former comprehensive context—including CVE examples, statistics, advanced techniques, anti-patterns, and a time-sensitive Patchstack snapshot—is preserved at `archive/wp-context-full-legacy.md`. It is research material, not active methodology or current policy authority.
