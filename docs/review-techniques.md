# Single-Agent WordPress Review Techniques

Concrete detection and adjudication techniques for the one-model, source-first review
defined in `review-methodology.md`. This is an **on-demand reference**: consult it during
the analysis passes or for a late recall/precision audit. It is not loaded during initial
discovery, and it introduces no pipeline, sub-agent, or worker/reviewer concept — every
technique here is something the single reviewing model does itself.

Provenance: distilled from the retired multi-agent pipeline design (`7-workflow-wp/*`). The
orchestration is discarded; each former "agent role" is folded into a sequential pass the one
model runs over the same source.

---

## Pass 0 — Trust boundaries & intended flow (do this FIRST, before any vuln-class hunt)

The passes below are organized around where input enters and where it sinks. That framing
finds injection and access-control bugs but **systematically misses the highest-value class:
a broken trust boundary or a corrupted execution flow.** Do this pass first, and do not let it
collapse into "look for IDOR/BOLA/BAC" — **breaking a trust boundary is not necessarily an
access-control bug.**

### Step A — Map the trust boundaries
List every boundary the plugin's data crosses, not just user↔user:

- **client ↔ store** (browser/shopper to WordPress)
- **store ↔ external platform** (payment processor, SaaS, webhook sender)
- **role ↔ role** (unauth → customer → shop-manager → admin)
- **step ↔ step within one flow** (the order of operations in checkout, payment, onboarding,
  session establishment — a boundary in *time*, not identity)

### Step B — For each crossing, ask the only two questions that matter
1. **What proves this crossing is legitimate?** (a signature, a nonce, a capability, a secret
   token, a server-authoritative fetch, a required prior step)
2. **Can that proof be forged, replayed, confused, or skipped?** — regardless of vuln class.

### Step C — The break is any of these, not just access control
A trust-boundary break / flow corruption can be:

- **Data-authenticity trust** — acting on data whose origin/integrity was never verified
  (a webhook/event body processed without a signature check; trusting a value because it
  "arrived", not because it was proven).
- **Origin trust** — treating a client-controllable signal as proof of origin
  (`User-Agent`, a header, an IP, a referrer as "this came from the trusted platform").
- **Value trust** — trusting a client-supplied value that must be server-authoritative
  (amount, price, currency, payment status, quantity, discount, "already paid").
- **Control-disabling** — turning off a security control for a request
  (nonce/CSRF check disabled, email/identity verification skipped, validation bypassed).
- **Invariant / flow-sequencing violation** — reaching a state out of order, skipping a
  required step, replaying a step, or a race that breaks an atomicity assumption
  (mark an order paid without the payment step; reuse a one-time token; TOCTOU).
- **Second-order trust** — a lower-privileged actor *writes* data in one step (order/user
  meta, session, an option, a stored field) that is *trusted* in a security decision in a
  later step or request.

### Step D — Name the invariant each core flow assumes, then hunt its violation
For every core flow, write the security invariant in one line, then look for the path that
violates it:

- **Payment:** an order becomes "paid" *only* when a real payment for the correct amount
  succeeded, proven server-side.
- **Checkout:** the charged amount equals the server-computed cart total; the payer owns the
  payment instrument.
- **Session / identity:** the current user is established *only* from a credential the requester
  provably holds.
- **Onboarding / config:** account/security settings change *only* on an authorized,
  authenticated action.

A finding here does not need a sink. "The store believes X because the client said X, and X
drives a security-relevant decision" is already the finding.

### Do NOT anchor on known CVEs or model priors
Check the plugin **version** and reason from the current source. A remembered CVE or "this
looks like CVE-XXXX" is Tier-5 evidence — a SIGNAL to investigate, never a conclusion, and often
already patched in the version in front of you. Chasing old vulnerabilities is how you miss the
new one.

---

## The five analysis passes

Run these after Pass 0, in order, over the sealed self-parse ledger. Discovery depth and
synthesis breadth are deliberately separated: trace deep on small slices first, then reason
across the whole plugin from what you already collected — never one giant sweep that is broad and
deep and therefore shallow everywhere.

### Pass 1 — Per-surface entry-point trace
Group surfaces by **entry-point type** and work them in privilege-risk order, not in file order
and not grouped by function:

1. Unauthenticated AJAX (`wp_ajax_nopriv_*`, `admin_post_nopriv_*`) — highest priority.
2. Authenticated AJAX (`wp_ajax_*`, `admin_post_*`) — subscriber+.
3. REST routes — classified by `permission_callback`.
4. Shortcodes and blocks — contributor+.
5. Cron, `init`/`template_redirect`, security-sensitive filters.

**IR labels are navigation, not verdicts.** The IR `auth_level` is set at registration and does
not see a `current_user_can()` enforced *inside* the callback, nor can it resolve
`[$this,'check_permission']` to its (possibly inherited) definition. So `auth_level: unknown`
means **UNAUDITED, read it** — never "probably fine, low priority". Every entry point in the
class must be read: resolve the real permission (follow the method, including inheritance) and
read the callback body for internal capability checks, before it is dispositioned. Do not skip a
surface class because the tool could not label it.

For each entry point, hold its IR slice + the referenced source + relevant tool hits + threat
context together, then trace `registration → callback → attacker control → transformations →
guards → sink → impact`. **Refute before confirming.** Finish one trace to a verdict before
opening the next, so context stays bounded. If you cannot prove exploitation, the verdict is
`UNCERTAIN`, never `CONFIRMED`.

### Pass 2 — Stored / cross-entry-point two-hop sweep
A per-surface trace structurally misses stored XSS and second-order SQLi, whose data flow
spans two entry points. Run one explicit sweep over the whole inventory:

```
STORE leg:  user input → sanitize? → update_option('K',$in)   [auth? nonce? sanitize at write?]
LOAD  leg:  get_option('K') → dangerous sink                   [escape at read? sink type?]
```

1. Map every storage **write** (`update_option`/`update_*_meta`/`add_*`) and record its **key**
   (arg[0] for options; arg[1] for post/user/term/comment meta).
2. Map every storage **read** (`get_option`/`get_*_meta`) and record its key.
3. **Match write-key ↔ read-key.** Literal key = exact match; dynamic key = flag `UNCERTAIN`.
4. Verify attacker reachability via the **write leg's** auth level (an unauth writer is far worse
   than an admin-only writer, even with an identical sink).
5. Check sanitization at **both** write time and read time — a defense at either end neutralizes.

Missing either leg means you cannot confirm — but the gap is in your extraction, not evidence
the flow is safe. Hunt the missing leg.

### Pass 3 — Signal / anomaly triage
Structural rules, Semgrep, Psalm, and grep produce **signals, not findings**. For each flagged
`file:line`: read the source, ask "exploitable in production?", look for defenses the matcher
could not see (custom guards, framework protection, type constraints), and assign a verdict.
Two hard constraints:

- **Do not invent new findings from this pass** — only adjudicate what was flagged. Discovery
  is Pass 1/2; keep it separate so neither contaminates the other.
- A rejection must **name the defense at `file:line`**, not dismiss by vibe.

Anomaly checklist to sweep: `missing_nonce`, `missing_capability`, `flawed_nonce_pattern`,
`unsanitized_sql`, `potential_xss`, `is_admin()`-as-auth, `__return_true` permission callback,
`nopriv` + sensitive op, unsafe redirect, cross-rule inconsistency.

### Pass 4 — Unresolved-hook & coverage-gap backstop (recall)
The highest-value recall pass — where a silent parser failure hides real bugs.

- **Dynamic hook resolution.** For every hook whose name is a non-literal — concatenation
  (`'wp_ajax_'.$this->action`), class constant (`self::HOOK`), variable, or method return —
  resolve the expression by hand (find the property assignment, the constant, the prefix) and
  recover the real hook and its `nopriv` status, then analyze it as a normal surface. State
  resolution confidence: high (literal assignment found), medium (inferred from naming), low
  (guessed). If unresolved, record an explicit "unresolved surface" — never treat it as absence.
- **Coverage gaps.** For any file that calls WP security functions (`wp_verify_nonce`, `$wpdb`,
  `current_user_can`) yet exposes no mapped entry point, ask why: dead code, template include,
  `admin_init` form handler (the recurring blind spot), or non-standard AJAX registration.
  Default verdict `UNCERTAIN` with the reason stated.

### Pass 5 — Self-verify / spot-check
Before finalizing, audit your own highest-severity findings:

- Re-read the chain: hypothesis → trace → refutation → verdict is coherent.
- Open the file and confirm each cited `file:line` actually lands on the claimed source/sink
  (within a few lines). A token that merely exists is not evidence; a mismatch lowers confidence.
- Confirm the verdict is supported by the stated evidence.

Calibrate effort: deep-check only high-severity/suspicious findings; do not re-derive everything.

---

## Recall-preservation techniques

Silent recall loss (missing a real vulnerability because the reasoning never saw the surface) is
the most damaging failure class. Guard against each known blind spot:

- **Trace across call boundaries (~depth 2).** A source captured in a callback whose sink lives
  in a helper (`$this->save($data)`) is the single most common false-negative. Do not stop at
  the callback body; follow delegated calls into helpers.
- **Resolve trait methods.** When a class `use`s a trait, its methods (including `use T { m as
  alias }`) belong to the class. A callback/guard resolving to a trait method exists — find it.
- **Treat security-sensitive filters as entry points.** `upload_mimes`,
  `wp_handle_upload_prefilter` (upload), `user_has_cap` (privesc), `authenticate` (auth bypass),
  `the_content` (stored XSS), `wp_mail` (injection) carry direct impact — not "just data
  transformation."
- **Read permission callbacks before saying "auth unknown."** Open every closure/arrow/named/
  array `permission_callback` and classify: unconditional `true`/`__return_true` → unauth;
  `current_user_can('manage_options')` → admin; `is_user_logged_in()` → subscriber.
- **Pair persistence writes with reads** (Pass 2). Build both halves of every stored flow.
- **Keep a running coverage ledger** of unresolved hooks, coverage-gap files, and untraced
  suspicious patterns; revisit each before declaring the review complete. Record every reviewed-
  and-secure area — negative findings prove coverage and prevent rework.
- **Tool absence ≠ safety.** Your self-parse and the Docker tools share documented blind spots
  (dynamic hooks, cross-function flow, trait methods, filter hooks, storage reads, closure
  permission callbacks). A missing sink in the IR often means the extractor stopped at a call
  boundary, not that the flow is safe. Never cap a finding at `UNCERTAIN` merely because the tool
  lacked data — resolve it in source.
- **A low signal can be a blind spot, not safety.** Before down-scoping a target because you
  found zero anomalies / zero unauth entry points, check whether that emptiness comes from
  unresolved surfaces. Zero-from-blindness is not zero-from-safety.

---

## Precision & refutation techniques

False positives destroy trust in every future report. Refute with these:

- **Guard effectiveness is three-state: effective / ineffective / unknown — and unknown is not
  safe.** Model it as `true` / `false` / `null`; `null` routes to manual verification and must
  never satisfy an "is there a guard here?" test. Collapsing unknown into "protected" is FP
  passthrough at scale.
- **Detect guards by structure, not by name.** A custom wrapper (`$this->verify_request()`,
  `SecurityHelper::validate_nonce()`) counts only if it structurally blocks — the call sits in an
  `if` whose body has an early exit (`wp_die`/`wp_send_json_error`/`exit`/`return`). A
  `verify_*`/`check_*` name is a Tier-5 signal, not proof; a false guard detection is worse than
  none.
- **A capability/nonce check counts only if its result gates the operation.** `$ok =
  current_user_can(...); update_option(...)` with the option write unconditional is **not** a
  guard. Neither is a check that runs after the side effect. Trace the return value to a
  branching condition that stops the sink.
- **`is_admin()` is not authorization** — it only reports admin-area context.
- **Don't over-trust proximity for `$wpdb->prepare()`.** Real code separates `prepare()` from the
  sink by 15–25 lines; read the actual data path. Conversely, verify a `prepare()` in one
  function actually covers the sink in another — same statement, same scope.
- **Per-sink severity.** Rate each SQL/output sink on its own facts; one parameterized query in a
  handler says nothing about a second, unparameterized one.
- **When you tighten one guard judgment, re-check every rule reading the same fact.** These are
  interlocked: forcing guard-effectiveness strict without also making the "flawed nonce" test
  strict (`=== false`) turns every "unknown" into a false "flawed" — a recall fix becomes a
  precision regression.

---

## Evidence & anchoring discipline

- **Rejections carry the same evidentiary bar as confirmations.** Every FP/`REJECTED` records the
  defense (`file:line`), the reason, and a **reopening condition** (what new evidence flips it). A
  bare "not a vuln" refuted nothing.
- **Surface every dismissed signal.** A tool hit you chose not to report gets an explicit
  disposition. Cross-check final findings against all tool hits; each unmatched hit must be
  accounted for — an internally dismissed signal is a candidate silent drop.
- **`file:line` must match the claim, not merely exist.** Anchored reasoning means the cited lines
  land on the actual source/sink. Hedging words ("however", "but") are not refutation; a real
  refutation names what you tried and why it failed.
- **Structured refutation over prose.** Prefer `{claim, result, file, line}` records to free
  text — this is exactly what the active contract's required `refutations[]` with `locations[]`
  already enforces.

---

## Severity in application context

- **Score by least-privilege reachability, and answer "does it grant a capability the actor
  doesn't already have?"** — before presenting any finding. Determine the *lowest* privilege that
  can reach it, then ask whether that actor gains something they couldn't already do. A control
  break reachable only by a role that already holds the impacted power (e.g. a shop-manager
  forging an event a shop-manager could already trigger) has **no concrete impact** — say so and
  downgrade. Real impact means a *lower* trust level crosses into a *higher* one, or an outsider
  corrupts a flow.
- **Score stored findings on the write leg.** Two surfaces, two auth levels: exploitability is
  driven by who can plant the payload, not only where it detonates.
- **Weight by plugin purpose.** Read the readme/keywords, pick the category, and front-load its
  vuln classes:

  | Plugin category | Front-loaded classes | Where to look first |
  |---|---|---|
  | WooCommerce / payment | SQLi, IDOR, priv-esc | checkout hooks, payment callbacks, refund processing |
  | Form builder | stored XSS, file upload | submission handlers, CSV/PDF export |
  | Membership / user mgmt | priv-esc, IDOR, auth bypass | registration, role assignment |
  | Backup / migration | arbitrary file read/write, path traversal, RCE, deserialization | download/restore/extract endpoints |
  | SEO / content | stored XSS, SSRF | meta output, remote fetch |

  The same bug class carries different weight in a payment plugin than an SEO plugin. Ground
  severity in the app's data and audience, not abstract CVSS.

---

## Large-target handling (single agent, no fan-out)

One session cannot hold hundreds of entry points and tens of thousands of LOC while tracing
every path. Scale without spawning agents:

1. **Slice the inventory, batch sequentially.** Partition entry points by type; for each batch
   load only the sources/sinks/guards/anomalies whose `entry_point_id` is in that set, and only
   the files they reference. Process in priority order. After the IR baseline exists, do this
   deterministically with `python3 tools/bin/slice_ir.py <ir.json> --out <dir> --batch-size N`:
   it emits priority-ordered slices (unauth first) each conforming to `contracts/ir-slice.schema.json`,
   plus a `slice-plan.json` manifest you work batch by batch — the coverage record that proves no
   surface was skipped. `unresolved_hooks`/`coverage_gaps` stay with the full IR for the Pass-4
   backstop.
2. **Batch by work budget, not just by surface type.** Turn raw signals into explicitly-scoped
   trace hypotheses classified by bug family / sink family / trust boundary / complexity, and
   size batches to a budget so none overloads context.
3. **Reason from evidence packs, not repeated whole-file search.** For any cross-cutting or
   late-stage reasoning, first assemble a compact pack — anchors, primary/optional files, and
   **extracted snippets around each source/sink/guard** — then reason from the pack. Broad search
   belongs to initial discovery only. If reasoning must exceed the pack, do it deliberately and
   record it; if it blows the budget, mark the conclusion `needs_followup` rather than trusting it.
4. **Coverage accounting across batches.** An empty slice (no entry points of that type) is a
   recorded "nothing here," not a silent skip. Run the leftover passes (unresolved hooks,
   coverage gaps, un-absorbed anomalies) as explicit end-of-review sweeps so nothing falls
   between batches.

---

## Self-monitoring invariants

- **Never allow a silent failure.** Anything the parse/tool could not resolve (a dynamic hook, an
  unfollowed call chain) is logged and surfaced. A silent drop is a hidden false-negative.
- **A signal is not a finding, and a finding is not done until its chain is wired end-to-end** —
  trace reaches impact, refutation attempted, verdict supported by the stated evidence.
- **Propagate new facts mid-review.** When you learn a guard is actually ineffective or find a new
  taint source, immediately reconcile every finding it touches; do not defer.
- **Resolve structure before adjudicating exploitability.** Settle guard effectiveness, call-chain
  resolution, and trait/method resolution first; ruling on unresolved structure produces FPs.
- **Watch the hedging trap.** Pushing everything uncertain into `UNCERTAIN` inflates apparent
  accuracy while resolving nothing. If your `UNCERTAIN` rate climbs while `CONFIRMED`/`REJECTED`
  stay flat, you are hedging. `UNCERTAIN` is a backlog with a resolution path, not a wastebasket.
- **Separate exploitability from reportability.** Decide the security truth first; filter for
  bounty/program eligibility second.
</content>
