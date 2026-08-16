# Axis proposals — research findings

Status: **research complete, nothing built.** Recorded 2026-08-05.

Two questions were put to this repo: should forgeward gain a property-based-testing
axis, and should it reverse its recorded decision to delegate code quality to gstack's
`/review`? This file is the evidence and the reasoning behind both answers, kept so the
numbers survive a context clear. The decisions themselves belong in `DECISIONS.md` and
the follow-up work in `TODOS.md` — see [What lands where](#what-lands-where) at the end.

---

## Q1 — Property-based testing

### Decision: separate skill only. No 7th reviewer.

Kiro ships PBT as a first-class spec step and the capability is worth having. The
authoring half (generate properties, run them, shrink counterexamples) writes and
executes, so it cannot be a gate reviewer — reviewers are read-only by construction and
the gate diffs the working tree before and after to prove it. That half becomes a skill.

The coverage half ("this diff changed an invariant-shaped function and nothing asserts
it") *is* read-only and could technically be a reviewer. It should not be, for two
reasons — and the second is the load-bearing one.

**1. Most of it is already owned upstream.** Verified, not assumed:

- `/ship` Step 7 traces every changed code path, diagrams branches and error paths,
  checks each against existing tests, generates missing ones, and applies a coverage
  gate (default min 60% / target 80%).
- The always-on `testing` specialist (`gstack/review/specialists/testing.md`) covers
  missing negative-path tests, missing edge cases, boundary values, test isolation,
  flaky patterns, coverage gaps.

What is genuinely left uncovered is thin: *round-trip / idempotence / commutativity /
ordering-independence / conservation invariants where example tests over-fit.* A thin
sliver does not justify a gate axis.

**2. The finding cannot produce a defensible FAIL.** Every existing forgeward reviewer
fails only on a stated consequence — security must "state the interleaving," supply-chain
must show the package does not exist, a11y cites a WCAG criterion, ai-output points at
unvalidated model output reaching a user. "This function is invariant-shaped and its
tests are example-shaped" has no consequence attached: the code may be entirely correct.
It would be the first forgeward reviewer whose FAIL is a claim about *test style* rather
than about behaviour, on an axis with exactly one lever. That is what trains `--no-verify`.

Corollary worth recording: the usual remediation — install `fast-check` / `hypothesis` /
`gopter` — is a dependency manifest change, which would itself fire the supply-chain
reviewer. A gate axis whose fix trips another gate axis is a bad citizen twice over.

("Fires on nearly every code diff, and remediation is build-a-test-harness" is also true,
but it is an argument about cost, and cost arguments lose to "but it caught a bug." The
undefensible-FAIL argument is the one that holds.)

### What to build: `/forgeward:properties`

Shaped exactly like `ci-gate` — the existing precedent for a forgeward skill that writes
files and is not part of the enforced gate:

- `disable-model-invocation: true`, explicitly invoked, `argument-hint`, `allowed-tools`
  including Write/Edit/AskUserQuestion.
- Detect or offer to install the stack's PBT library. Installing is a dependency change,
  so it is a confirmed step, never silent.
- Find invariant-shaped functions, generate properties, run, shrink.
- **The durable output is each shrunk counterexample committed as a deterministic
  regression test.** That is the artifact that outlives the run and that existing
  reviewers and CI can subsequently see. Properties generated is a vanity metric;
  regression tests committed is not.
- Later: `ci-gate` can emit the property suite as a CI job. A seed sweep over time is
  where this axis actually earns its keep, not a one-shot local run.

### Two unrelated repo shapes it must serve

1. A parser/serializer, or a money-and-dates module, in a typed library repo.
2. A pure decision function buried inside an application repo — `canAccess(user,
   resource, action)`, `computeTotal(cart, promos)`. It must find case 2 *inside* an app;
   it must not require the repo to be a library.

### Non-goal — what it must NOT fire on

Diffs that are orchestration and glue: route handlers, components, migrations, IaC,
shell that sequences side effects. There is no property to state about "call A, call B,
render," and generating one produces a tautological test and an unearned green.
**"No invariant-shaped surface in this diff" must be a normal, silent, clean exit** — it
will be the majority outcome.

### Structural blind spot — must be stated in the skill's own report

A property can only falsify the invariant you *state*; it cannot tell you the invariant
is wrong. Assert half-up rounding when the spec wants banker's and 10,000 passing cases
certify the bug. The same applies to stateful properties: they cover the state machine
you encoded, so an unmodelled transition is invisible at any case count. Shrinking yields
a *minimal* counterexample, not a *representative* one.

---

## Q2 — A code-quality reviewer

> **SUPERSEDED at 0.12.0 by the measurement this proposal itself asked for — read this
> box before the recommendation below.** The decision was conditional from the start
> (see *Sub-question 2*, "Fallback if the base rate comes back thin"), and the base rate
> came back at **0 true Highs per 5 PRs in both repos**, 0.25/5 on an extended window.
> The pre-committed rule made that a fold, not a build: **no `error-path-reviewer`
> exists and none will be built on this evidence.** Rules 1 and 3 are folded into
> `agents/security-reviewer.md` Step 3; rules 2 and 4 fired zero times and were
> deliberately NOT folded. The measurement's own defect — a by-hand diff pass cannot see
> the two-arms-of-one-helper shape that produced four real instances here — is recorded
> with the result, so the 0/5 does not get read as "the class is rare".
> Everything below is kept as the reasoning that framed the measurement; where it says
> "build it", read "the condition under which it would have been built".
> Full entry: `DECISIONS.md` → *quality stays unowned by forgeward*.

### Decision (conditional, and the condition failed): build it — narrow and blocking — and name it `error-path-reviewer`.

Not "code-quality." It owns one question, symmetric to the security reviewer's:
**when this code fails, does anything notice?**

### Sub-question 1: is there real evidence, or a hunch?

**The analogy to the `/cso` reversal half-breaks, and that matters.** `/cso` was a
standalone skill that nothing invoked. `/review` is not only that — its content is
*embedded in `/ship`*: Step 9 pre-landing review, Step 9.1 review army (always-on
`testing` + `maintainability` specialists at 50+ changed lines), conditional red team.
And forgeward's gate invokes `/ship` on all-PASS. On the designed happy path the quality
axis is **not** absent at ship time. On paper, "an opt-in check is not a gate" does not
apply here.

**What the artifacts actually say.** Fleet-wide gstack review log
(`~/.gstack/projects/*/*reviews.jsonl`), 116 entries, 2026-06-22 → 2026-08-05:

| Measurement | Value |
| --- | --- |
| `skill:"review"` entries | 22 |
| …of those, `via:"ship"` | 21 |
| …standalone `/review` runs | **0** |
| `skill:"ship"` entries | 54 |
| Ships carrying a logged review | ~39% |
| finrecruits: branch markers in `.git/forgeward-gate-markers/` | **49** |
| finrecruits: logged ships / logged reviews | 3 / 2 |
| forgeward-gate: merged PRs | 11 |
| …carrying gate/PASS evidence in the body | 5 |
| …mentioning a pre-landing review, review army, or quality score | **0** |

The instrumentation predates the window — `gstack-review-log` exists since 2026-03-19,
`"via":"ship"` since 2026-03-26 — so a missing entry is not a missing feature. The marker
count is not a logging artifact and needs no such caveat.

**How the two shapes are distinguished** (verified, because the standalone count depends
entirely on it — an earlier draft asserted it without checking):

- `review/SKILL.md:1805` — Step 5.8, unconditional. This is what a **standalone**
  `/review` emits. Its payload has **no `via` key**; the string `via` appears nowhere in
  that file.
- `ship/sections/review-army.md:395` — `/ship`'s embedded review. Payload carries
  `"via":"ship"`, with that file's own comment: *"The `via:"ship"` distinguishes from
  standalone `/review` runs."*

So a standalone run does log, distinguishably, and "0 entries lacking `via`" is a sound
reading of "0 standalone runs."

**The limit that survives, and it constrains the enforcement design.** Both call sites
are model-executed prompt instructions, not enforced code. A review that completes and
skips its final step leaves no entry at all. For the *measurement* this under-counts —
review looks rarer than it was, so treat the ship/review ratio as a floor. For any
*enforcement* built on the log it inverts, producing a **false FAIL against someone who
did review**. Same root cause, opposite consequence.

Two consequences for the proposed review-ran check: it must match on `skill:"review"` +
`commit` + specialists-dispatched and treat a **missing `via` as standalone** (keying on
`via:"ship"` would fail exactly the people who ran `/review` correctly); and because its
input can be absent for a run that happened, it cannot block on a first version.

**The finding is therefore not "/review is being skipped."** It is:

> The gate's handoff to `/ship` is the only thing that runs the quality axis, and the
> handoff is routinely not taken — including by forgeward itself.

forgeward's own recorded workflow is gate → push and PR by hand, deliberately: `/ship`
would re-bump the version. So this repo reaches the same end state as the `/cso`
incident through forgeward's *most common usage pattern*, not through user
forgetfulness. That is a different and more durable failure than the one the security
reversal fixed.

**And there is a concrete incident, in this repo.** `json_get` in
`scripts/forgeward-gate-check.sh` ran `jq -r … 2>/dev/null` with stderr *and exit status*
discarded, so "jq failed" and "field absent" were the same observation and the hook
`exit 0`'d — **a fail-open in the enforcement path.**

- Present from the initial commit.
- Alive through PRs #2–#10, of which **#5, #7, #8 and #9 carry gate-PASS evidence**.
- Fixed only in #11 (`5fe8282`, 0.7.3) on 2026-08-03.
- Found by reading. No reviewer, on either side, flagged it.
- Companion instance: `strip_quoted`'s residue guard rescued an *empty* result but not a
  *truncated* one — same shape.
- **Third instance still open:** `marker_get` discards `jq`'s exit status the same way
  (TODOS, P3). That direction is fail-*closed*, which is why it survived triage.

**Why nothing caught it — verified against every candidate owner:**

| Owner | Coverage of this class |
| --- | --- |
| forgeward `security-reviewer` | None. Its ten Step 3 categories are injection, broken authz/IDOR, SSRF, path traversal, unsafe deserialization, secrets, dangerous output/XSS, sensitive error exposure, redefinition posture drift, check-then-act-without-a-lock. No unchecked-return or swallowed-error item. |
| gstack `maintainability` specialist | None. Dead code & unused imports, magic numbers, stale comments, DRY, conditional side effects, module boundaries. |
| gstack `testing` specialist | Tests *about* error paths, not error paths themselves. |
| gstack `/review` checklist | Two adjacent lines only — "wrong column names silently return empty results or throw swallowed errors" (Pass 1, SQL safety) and "incomplete error paths" (Pass 2, Completeness Gaps, INFORMATIONAL). Adjacent, not owned as a category, and heavily Rails/Django-flavoured — nothing addresses shell. |
| gstack itself | Recognises the class — it is the entire premise of the slop-scan section, `safeUnlink`, "a swallowed EPERM in cleanup means silent data loss" — but slop-scan is a contributor tool in gstack's own repo, not a specialist and not in any gate. |

**Honest limits on this evidence, which must not be papered over:** one incident, in our
own repo, found by reading rather than by an independent instrument the way Wiz was in
the `/cso` case. And its severity is unrepresentative — a fail-open in an enforcement
hook is far more consequential than the median finding of this class. The severity of
this instance must not stand in for the value of the axis.

### Sub-question 2: blocking or advisory?

**Blocking, on a narrow Critical/High list.**

The reason is not severity — your disanalogy is right, a missed injection ships an
exploit and a missed quality issue ships slightly worse code. The reason is that
forgeward has exactly one output channel and one rule: *never lower the bar; do not
rationalize a FAIL into a pass.* An advisory reviewer inside the gate would be the first
whose findings carry no consequence, which trains precisely the scroll-past habit that
makes gates worthless — at cost on every push.

**The advisory tier already exists, inside each reviewer.** Medium and Low are reported
and never fail on their own. That is where taste-shaped quality findings belong: under an
axis that can also block, not as a whole reviewer that cannot.

**Fallback if the base rate comes back thin:** not an advisory 7th reviewer — fold rules
1 and 3 below into `security-reviewer` Step 3, which already fires on every code diff and
where "a discarded failure signal on an enforcing path" arguably already belongs.
Smaller, cheaper, trivially reversible.

### Sub-question 3: the narrowest useful scope

Four rules. Each requires a **stated failure consequence** to reach High — the same
discipline `security-reviewer` applies to races ("High only if you can state the
interleaving").

1. **Discarded failure signal.** `2>/dev/null` with `$?` unchecked; `|| true` on a
   status-bearing command; empty `catch` / `except: pass`; Go `err` dropped to `_`; an
   un-awaited promise with no `.catch`; a subprocess return code never read.
   **High only when the discarded signal gates a control decision** — auth, an
   enforcement path, a write the caller believes succeeded, a cleanup that prevents data
   loss. Otherwise Medium.
2. **Dead or unreachable error path.** A handler that cannot be entered, or that swallows
   and returns the success value. The shape that makes tests pass and production fail.
3. **Unchecked conditional-write result.** The non-DB half of the rule security already
   owns: a write/delete/rename whose row count, boolean, or byte count is never inspected
   while its predicate can legitimately match nothing.
4. **Resource leak on the error path.** Handle, lock, transaction or subscription
   released only on the success branch — no `finally` / `defer` / context manager.
   High only when the leak is unbounded per request.

**Explicitly out of scope** — this is what stops it becoming a linter with opinions:
naming, formatting, function length, complexity metrics, DRY, comments, magic numbers,
dead code that is not an error path, module boundaries, "could be simpler," anything a
repo's configured linter already reports, and **any finding without a stated failure
consequence.** It may not FAIL on a finding it cannot narrate.

### Sub-question 4: what does it do that security-reviewer and `/review` don't?

In honest order:

1. **It owns a class nobody owns.** Verified above against `security-reviewer`'s
   checklist, `/review`'s checklist, and both always-on specialists. This is the real
   answer, and it is stronger than "runs automatically."
2. **It runs automatically and it blocks.** `/ship`'s embedded review does not block — it
   is fix-first plus `AskUserQuestion`, and `/ship` never refuses to ship. Standalone
   `/review` has 0 logged runs. Both are true, and neither is the primary justification.
3. **It runs before the marker.** `/ship`'s review runs *after* the gate writes the
   marker, and its auto-fix commits change the reviewed code — which flips the pinned
   `diff_hash` and forces a re-gate before push. Checking before the marker is strictly
   cheaper than checking after it.

### Two unrelated repo shapes it must serve

1. A shell / infra repo — installers, git hooks, CI glue, Terraform wrappers — where
   discarded exit statuses are endemic and this repo's own `json_get` is the type
   specimen.
2. A payments or webhook backend in a typed language, where a swallowed error tells the
   caller "ok" while the row never moved.

### Non-goal — what it must NOT fire on

**Deliberate best-effort paths.** Shutdown and teardown, `rm -f`-shaped cleanup,
telemetry sends, cache warms, fire-and-forget whose failure genuinely changes nothing.
gstack's own slop-scan guidance is the reference statement of both sides:

> Fix: empty catches around file ops — a swallowed EPERM in cleanup means silent data
> loss. **Do not fix:** tightening best-effort cleanup paths — shutdown, emergency
> cleanup and disconnect code should swallow *all* errors, because a cleanup path that
> throws on EPERM means the rest of cleanup doesn't run. That's worse.

In a teardown or best-effort path the correct output is **no finding at any severity.** A
Low here trains the reader to ignore the axis — the same mistake the per-route posture
decision fixed for the seo-reviewer.

Equally: no finding where the repo's configured linter already reports the rule
(`errcheck`, `@typescript-eslint/no-floating-promises`, `shellcheck SC2181`), and no
finding where the idiom *is* the guard (Rust `?`, a framework error boundary,
`except Exception: logger.exception(...)` that degrades on purpose).

### Structural blind spot — must be written into the agent and the README

**It sees a missing check, never a wrong one.** It cannot tell you an error is handled
*incorrectly* — retried when it should fail fast, degraded to a default that silently
corrupts downstream, rolled back at the wrong scope. Every one of those has a visible,
non-empty handler and passes clean.

Plus the gate-wide blind spot: it is diff-scoped, so a caller that stopped checking three
commits ago is invisible.

---

## Later findings (same session, after the Q1/Q2 answer above)

These came out of pushing on the Q2 recommendation and are recorded here rather than
folded into the sections above, because they arrived later and one of them is a live
coverage gap in shipped code rather than a proposal.

### 1. Mutual deferral — the axis each side believes the other owns

Grepping specialist skip reasons across the fleet log turned up this, on commit `04a04fb`:

```
"maintainability": { "dispatched": false, "reason": "covered-by-forgeward-and-coverage-audit" }
"security":        { "dispatched": false, "reason": "covered-by-forgeward" }
"data-migration":  { "dispatched": false, "reason": "covered-by-forgeward-security" }
```

gstack's review skipped maintainability **because it believed forgeward covered it**.
forgeward's README skips code-quality **because it believes `/review` covers it**. Both
sides deferred to the other by name, in writing, on a real diff — and the axis ran
nowhere. That is the `/cso` shape exactly: not "the tool lacks the axis" but "each side
assumed the other owned it," ending in a green result.

**Scope this honestly: 2 of 22 review entries.** It is an existence proof of the failure
mode, not a measured rate. Full reason tally across the fleet: `scope` ×18,
`small-diff` ×2, `covered-by-forgeward*` ×3, `covered-by-coverage-audit` ×1.

### 2. `/review` does not bump VERSION — a cheaper handoff than `/ship` exists

Verified by full grep of `review/SKILL.md`: every `VERSION` occurrence is a read or a
display string — install detection at 121, unrelated `gbrain --version` at 482, and the
advisory queue check at 1130–1146 reading via `git show HEAD:VERSION` and
`git show origin/$BASE:VERSION`. The one helper the grep could not see,
`bin/gstack-next-version`, writes only to `process.stdout` (line 506). **No write path.**

This matters because version bumping is the whole reason **this repo's own dev workflow**
declines the `/ship` handoff (see [[forgeward-no-ship-handoff]] — `/ship` would re-bump a
version that lives in three manifests here). That objection does **not** apply to `/review`.
The handoff this repo rejected is available in a cheaper form.

Read that as scoped to developing forgeward itself, not as plugin behavior — the two were
conflated in this paragraph until 0.8.0. The *plugin* does hand off: `skills/gate/SKILL.md`
Step 3 invokes `/ship` when gstack is installed, and as of 0.8.0 reports the marker and hands
back when it is not. A repo that does not want the handoff declines it the way this one does,
by convention, not because forgeward withholds it.

Constraint on using it: `/review` holds `Edit`/`Write` and runs Fix-First auto-fix, so it
cannot run *inside* the read-only gate — the workspace guard would flag it, correctly.
Correct order is **`/review` first, then gate**, so the marker pins the post-fix state and
nothing goes stale.

### 3. forgeward's standalone posture (no gstack installed)

The plugin is *defined* as a delta against gstack — README line 7 ("a conformance gate
for gstack"), and the reviewer table's third column is literally "Why it's here (not
redundant with gstack)". **Scoping by delta means every deferral becomes a hole when the
other side is absent.** Shipped today:

- **`supply-chain-reviewer` explicitly declines CVE coverage.** Verbatim: *"gstack's
  `/cso` Phase 3 already covers dependency CVEs, install-scripts, and lockfile integrity
  — do NOT re-do those."* No gstack → **nobody checks dependency CVEs**, and the reviewer
  returns PASS. Most severe of these: CVE scanning is table stakes and the user has been
  told the axis is handled.
- **README line 45** claims code quality is covered by `/review`. It is not.
  *(Resolved in 0.8.0. The line is 57, not 45 — the number here was wrong and TODOS.md
  inherited the error. It now qualifies the claim with "when gstack is installed" and
  points at the disclosure.)*
- **README line 336** advises running `/cso` for the deep audit — a no-op.
  *(Already corrected in 0.7.4, which qualified it with "if you have gstack". Listed here
  only because this section is the historical finding list; it is not outstanding.)*
- **The gate's Step 3 hands off to `/ship`.** Whether that degrades gracefully or
  hard-fails without gstack is **untested** — flagged as likely-broken, not confirmed.
  *(Resolved in 0.8.0, and the guess above was wrong in an instructive way. It did not
  hard-fail: the marker is written BEFORE the handoff, so the PASS was never at risk and
  the user was never blocked. The actual failure was a **false success report** — the gate
  announcing "Handing off to /ship" on a machine where nothing shipped. Worse than the
  predicted breakage, because a hard failure is visible and this is not. Step 3 now
  branches on `gstack_ship`.)*

Gate mechanics themselves carry **no** gstack dependency (verified): `hooks/` and
`scripts/` reference gstack only in comments and accommodations —
`forgeward-diff-hash.sh` excludes `VERSION`/`CHANGELOG`/`TODOS.md` so gstack's post-gate
bookkeeping cannot invalidate a marker, and the expansion-mode message names `/ship`.
Nothing invokes gstack; nothing fails without it. Those exclusions stay inert standalone.

**The fork:**

- **Option A — declare gstack a hard dependency.** Honest, zero new branches, matches the
  README's existing framing. Cost: forecloses adoption by anyone who wants only the six
  reviewers, which do work standalone.
- **Option B — conditional deferral.** Every "gstack covers this" becomes "gstack covers
  this *when present*." One extra branch per deferral. **Recommended**, because the
  gate's value genuinely does not require gstack. A is legitimate if the branches are
  unattractive to maintain; what is not acceptable is leaving it implicit.

**Tiers after B:**

| Tier | What | Standalone? |
| --- | --- | --- |
| Core | 6 reviewers, conditional firing, posture classification, workspace guard, marker, pre-push enforcement | Unconditional — zero gstack dependency |
| Falls back | dependency CVEs / install scripts / lockfile integrity — deferred to `/cso` when present, done by `supply-chain-reviewer` when not | Yes — the point of B |
| Needs a partner tool | code quality; deep whole-repo audit | **No** — forgeward does not own these |
| Needs gstack specifically | the one-motion `/ship` handoff on all-PASS | No — push and PR by hand |

So after B the honest statement is **not** "not fully operational." It is: *the gate is
fully operational standalone; one axis (quality) and one convenience (the handoff) come
from a partner tool.* Note the bottom row is already how this repo runs — the standalone
experience and the maintainer's own path are the same.

**Two shapes detection must serve:** (a) a plain Claude Code user with no gstack who
installed forgeward on its own; (b) gstack present but skills renamed — README line 57
notes custom `--prefix` install variants, so detection must handle prefixed names, not a
literal `/cso`.

**Non-goal — must NOT fire on:** a repo covering the axis another way (Dependabot/Snyk
for CVEs, a CI SAST job, a different review tool). If config names a substitute, stay
silent. A disclosure that repeats after being answered is nagging, and nagging gets gates
disabled.

**Structural blind spot:** it detects the *tool*, never whether the tool is *configured
to run*. gstack installed with Codex reviews disabled, or `/cso` never once invoked,
looks identical to gstack actively covering the axis. Presence, not diligence — the same
limit as the review-ran check, and it must be stated in both.

### 4. Option B's cost: make the marker self-describing

B makes coverage **environment-dependent** — the same plugin at the same version checks
different things on two machines. For most gates that is tolerable; here it is sharper,
because the marker *is* the product, and under B a PASS means something slightly
different depending on what was installed when it was written.

Fix, and it belongs inside B rather than after it: **record the detected environment in
the marker.** It already carries `fired`; adding what the gate could and could not see
makes "why did this PASS when that one FAILed" answerable from the artifact instead of
from memory, and turns the coverage variance from invisible into auditable. Same
principle as the rest of this document, moved from the README into the thing that
outlives the run.

### 5. The review-ran check (design, if built)

Rather than reimplementing quality, gate on whether the existing pass ran. The log makes
it mechanically possible: entries carry `commit`, per-specialist `dispatched` + `reason`,
`quality_score`, and per-finding `fingerprint`/`severity`/`action`.

- Match on `skill:"review"` + `commit` + quality specialists dispatched. **Treat a
  missing `via` as standalone**, never as malformed.
- **Warn, do not block, on a first version** — its input is a skippable prompt step, so
  blocking manufactures false FAILs against people who did review.
- Key off a *configured* artifact in `.forgeward/config.yml`, not gstack specifically.
  Absent config: disclose once, then stay silent.

Why it beats a quality reviewer: remediation is bounded and always achievable ("run
`/review`") rather than "refactor this module"; the finding is binary, so no taste; it
duplicates nothing; and it breaks the circular deferral in finding 1, because forgeward
stops claiming coverage it does not have.

## Scope of the evidence vs scope of the fix

Stated explicitly, because a fix that undershoots its own evidence reads as full coverage.

**What the evidence supports:** across 22 logged review runs, the broad quality pass ran
only inside `/ship`, never standalone, and in 2 entries its specialists were skipped by
explicit deferral to forgeward.

**What the proposed fixes cover:**

- `error-path-reviewer` — one correctness sliver of one specialist's territory.
  **Undershoots the proposition substantially.** It is a correctness axis, not the
  quality axis, and must never be described as covering quality.
- The review-ran check — matches the proposition, but requires a partner tool to be
  present, so for a repo without one it covers **nothing**.

Neither fix, nor both together, restores the quality axis for a standalone user. That
population is left uncovered on this axis by design; see the standalone-posture work in
`TODOS.md`.

## Re-proving the rejected option

The general code-quality reviewer was rejected above because quality has no external
anchor, so its verdict is not reproducible, which breaks the marker's meaning. Tested
against the options that survived:

- **The review-ran check** is binary, but its input is a log entry written by a skippable
  prompt step — the same diff can yield different verdicts. **The reason applies.**
- **`error-path-reviewer`** is syntactically anchored for "discarded failure signal," but
  "was this deliberate?" is a judgment about intent with no external anchor.
  **Partially applies.**

The reason does not cleanly acquit either survivor, so it was carrying less weight than
claimed. **The rejection stands on narrower ground: bounded remediation plus a stated
consequence.** "Run `/review`" and "this swallowed error means the caller believes a write
succeeded" have both; "this module is too complex" has neither.

## Strongest argument against each

**Against Q1 (the PBT skill):** it will be the least-used thing in the plugin. `ci-gate`
at least terminates in enforcement; a PBT skill is something you must remember to run, on
exactly the code that needs it — the same opt-in failure this project has now documented
twice (`/cso`, and now the `/ship` handoff). If it ships, success is measured in
*committed regression tests*, and it gets deleted if there are none after a month.

**Against Q2 (the error-path reviewer):** one incident, in our own repo, found by
reading. The base rate is unmeasured. This class has the highest false-positive potential
of any forgeward axis, because "was this catch deliberate?" is a question about *intent*
that the diff frequently does not contain. If it fires on the average PR, the credibility
of all six existing axes pays for it. That risk is real enough that folding two or three
rules into `security-reviewer` Step 3 remains a legitimate answer.

---

## What lands where

### Ready to build

- **`/forgeward:properties`** — fully specified above. No gate interaction, reversible,
  no dependency on the base-rate measurement.
- **The README correction.** Line 45 currently reads: *"Still not included on purpose: a
  code-quality reviewer — gstack's /review covers it."* That is not defensible as
  written — `/review` has 0 standalone runs in the log, runs only inside `/ship`, and
  this repo's own workflow deliberately skips `/ship`. Restate as: code quality broadly
  is delegated to `/review`, which runs inside `/ship`; forgeward owns only the
  failure-handling sliver. If the reviewer is not built, at minimum say the delegation is
  conditional on taking the `/ship` handoff.

### Urgent — a live gap in shipped code, not a proposal

- **`supply-chain-reviewer` returns PASS without checking CVEs when gstack is absent.**
  Make the deferral conditional. This is the one item here that is a coverage hole in
  something already installed on other people's machines, and it should move ahead of
  both proposed axes.

### TODOS.md

- **Standalone posture (Option B).** Detect gstack at gate time; when absent, disclose in
  the firing decision exactly which axes are unowned as a consequence. Correct README
  lines 45 and 336. Test whether Step 3's `/ship` handoff degrades or hard-fails without
  gstack — currently unknown.
- **Record the detected environment in the pass marker**, so coverage variance under B is
  auditable from the artifact.
- **The review-ran check**, warn-only, keyed off a configured artifact — design in
  [Later findings §5](#5-the-review-ran-check-design-if-built).
- **`error-path-reviewer` — MEASURED, and the answer was FOLD. Not built, not pending.**
  0 true Highs per 5 PRs in both repos; rules 1 and 3 folded into `security-reviewer`
  Step 3 at 0.12.0, rules 2 and 4 not folded (zero fires anywhere). See the SUPERSEDED
  box at the head of Q2 and the `DECISIONS.md` entry. The original item is kept below
  verbatim because the decision rule was pre-committed, and a rule is only worth having
  if the losing outcome is still legible afterwards. Carry the incident
  (`json_get`, fixed in #11, live across PRs #2–#10 on green markers), the four rules,
  and the decision rule: **≥1 true High per 5 PRs → build it blocking; below that → fold
  rules 1 and 3 into `security-reviewer` Step 3 instead.** Measure by applying the
  four-rule checklist by hand to the last 5 gated diffs across two repos, and by grepping
  the fleet for the pattern's raw base rate.
- **Re-tag the existing `marker_get` P3 item** as the third instance of this class and
  the reviewer's first fixture.
- **Gate-run logging** — append the fired reviewer set plus verdict rather than
  overwriting/pruning, so "gate ran, `/ship` didn't" becomes measured instead of inferred
  from marker file counts.

### DECISIONS.md

An entry either way. "Delegate quality to `/review`" is a *recorded* decision; this
either reverses it or re-affirms it on a **new** basis (embedded-in-`/ship`, not
standalone). The `/cso` reversal set that precedent, and the difference between those two
rationales is the whole question.

---

## Evidence provenance

Everything above was read, not recalled:

- `README.md`, `DECISIONS.md` (the `/cso` reversal at ~line 612; per-route posture at
  ~line 473), `TODOS.md`, `skills/gate/SKILL.md`, `skills/ci-gate/SKILL.md`
- `agents/security-reviewer.md`, `agents/ai-output-reviewer.md`,
  `agents/supply-chain-reviewer.md`
- `gstack/ship/sections/review-army.md`, `gstack/ship/sections/test-coverage.md`,
  `gstack/review/specialists/testing.md`, `gstack/review/specialists/maintainability.md`,
  `gstack/review/checklist.md`, `gstack/CLAUDE.md`
- `~/.gstack/projects/*/*reviews.jsonl` (116 entries), `.git/forgeward-gate-markers/`
  across the fleet, and this repo's merged PR bodies
