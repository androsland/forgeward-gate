# Decisions

Durable decisions for the forgeward gate, with the reasoning that produced them.
`RESOLVED` entries record a real bug, its repro, and the fix, so a future regression
is recognizable from the symptom alone.
Sections are **newest first**.

## DECISION — forgeward takes the deep-audit axis too, as a SKILL rather than a reviewer

**Date:** 2026-08-26 · **Version:** 0.19.0

**The decision, in one line.** gstack's `/cso` audit phases are **ported** into
`skills/audit/SKILL.md` as `/forgeward:audit`, a whole-repo read-only skill; the gate's
Step 1c stops deferring `deep-audit` to a tool that may not be installed. This closes the
last of the three delta-scoping holes this file records — `/cso` for dependency CVEs
(2026-08-05; that entry carries a date and no version field), `quality` (0.17.0), and now
`deep-audit`. **No axis on this gate is owned by a
tool that might not be installed.**

**It reverses a scoping decision this repo's own TODOS.md made the same day** (the 0.17.0
quality-port entry, 2026-08-26), which said `/cso` is "orchestration, and the delta-scoping hole is therefore real and
unfixed". That reasoning had one unexamined step: it treated *orchestration* and
*portable* as opposites. `/cso` is orchestration expressed **entirely in prose** — phase
order, exclusion rules, severity bars, a findings schema — and prose is exactly what
forgeward already ports. What is genuinely unportable is the parts of `cso/SKILL.md` that
are gstack plumbing (telemetry, config, its own UX), and those were not ported.

**Why a skill and not a seventh reviewer, which is the decision that actually matters.**
The quality port worked because a checklist *is* a reviewer — diff-scoped, fired from the
Step 1 table, binding the gate. An audit is none of those things:

1. **Scope.** The gate reviews `<base>...HEAD`. The audit reviews the repository, including
   files no diff has touched in a year — git history, CI config, IaC, the dependency tree.
   Running it per-gate would review the same 400 files on every three-line PR.
2. **Cost.** It is fifteen phases with parallel verification. That is a deliberate,
   occasional act — before a release, after an incident, on a schedule — not a per-push tax.
3. **Falsifiability.** A gate FAIL must be about the diff in front of the user. A finding
   in code the PR did not touch is a true finding and an unfair block, and the fastest way
   to get a gate switched off is to fail it for something the author did not do.

So `/forgeward:audit` carries `disable-model-invocation: true`, is not in the Step 1 table,
and **is not fired by Step 2**. That is a design decision, not an omission, and the skill
and `skills/gate/SKILL.md` both say so.

**Why it is NOT the `/review` situation, even though it looks identical.** The gate cannot
invoke `/review` because `/review` holds `Edit` and `Write`, and Step 2 proves the gate is
read-only by snapshotting the tree and diffing it afterwards. `/forgeward:audit` holds
neither, so it *could* run inside that envelope. It is excluded on scope and cost alone.
Recording the difference matters because the two exclusions look the same from outside and
have different futures: the `/review` one is structural and permanent, this one is a
judgement that could be revisited if the audit ever grew a diff mode cheap enough to fire.

**What the disclosure is keyed on, and why the obvious key is wrong.** Step 1c used to read
the environment probe's `gstack_cso` field and disclose when it was absent. After the port
that key is useless in the worst direction: the axis has an owner that ships *with
forgeward*, so a presence check reads `present` on every machine and would license the
sentence "deep-audit is covered" — which nothing checked. The line is keyed on **"not run
by this gate"** instead. That is a fact about this gate's scope, it is true on every
machine, and it cannot decay into a false claim. The probe still emits `gstack_cso`;
**nothing in Step 1c reads it any more.**

**Read-only is a discipline with a structural floor under it — not a structural property,
and the first draft of this entry overstated it.** The skill declares `allowed-tools`
without `Edit`, `Write`, `NotebookEdit` or `MultiEdit`, which removes every code-editing
tool. It does not remove `Bash`, which writes arbitrarily and has to stay because the
phases run git and scanners, nor `Agent`, whose subagents the list does not constrain.
Phase 14 settles it: the audit writes its own report, and Bash is the only thing it could
be writing it with. So what is enforced is that no *editing* tool was declared; the
no-write-inside-the-repo rule is prose, backed by `/forgeward:gate` Step 2's worktree
snapshot and by `forgeward-scan.sh`.

A30 pins the checkable half, with a floor. The naive assertion — `grep -q Write
skills/audit/SKILL.md` returns nothing — passes on the *worst* input, because a **missing**
`allowed-tools` key grants every tool, so A30 requires at least three tools enumerated
**and** no editing tool among them. Each item is normalized before it is judged: review
found A30 fail-OPEN on `- Write ` (trailing space), `- Write<TAB>`, `- Write  # note`,
`- "Write"` and `- Write(*)`, every one of them a legal spelling that declares the tool
while a whole-line `grep -x` for the bare word misses it. Mutation-verified in both
directions across twelve inputs, and against gawk, mawk and busybox awk.

**Two divergences from the source, both deliberate and both stated in the skill.**

- **It writes its report outside the repository.** `/cso` writes
  `.gstack/security-reports/{date}.json` into the tree, which is what makes its trend
  tracking work. forgeward will not write into a repo it is auditing, so it uses
  `forgeward-artifact-dir.sh` — and that costs the trend feature, because the path carries
  a per-process `$$` level. The skill says trend tracking is unreliable and names all four
  reasons rather than promising it.
- **It does not exempt forgeward from its own skill supply-chain phase.** `/cso` exempts
  gstack there. A phase that audits installed skills for prompt injection and credential
  access, and then skips the skill running it, is a check with a hole shaped like itself.

**Blind spots, stated so the port is not read as more than it is.**

1. **Nothing verifies it ran.** No marker, no state, no check. That is the same limit the
   gate discloses about `/review`, arrived at from the other side, and it is *better* than
   the deferral it replaces — the owner is always present — without being coverage. Filed.
2. **Its provenance is recorded and unchecked.** `forgeward-rubric-drift.sh` iterates
   `agents/*-reviewer.md` only, so `skills/audit/SKILL.md`'s `source-sha256` is compared to
   nothing. The fix is one glob plus a positive control, and it could not ride along because
   the control's fixture is the file this port creates. Filed as P2.
3. **Five of the fifteen phases are not hash-pinned.** Ten (Phases 2–11) come from
   `cso/sections/audit-phases.md` and are covered by the recorded `source-sha256`. Phases
   0, 1, 12, 13 and 14 come from `cso/SKILL.md`, which mixes the ported orchestration with
   gstack plumbing, so a whole-file hash would report drift for reasons unrelated to them;
   that is stated in the provenance block rather than papered over with a noisy hash. Phase
   14 is in the same unpinned set: an earlier draft of this entry called it forgeward's own
   because it writes through `forgeward-artifact-dir.sh`, but that is only the destination —
   the report *schema* it specifies (`fingerprint`, `exploit_scenario`, `playbook`,
   `filter_stats`, `trend`) is drawn from `cso/SKILL.md`, which is what
   THIRD-PARTY-LICENSES.md has said all along. The attribution document was right and this
   entry was wrong. The count and the enumeration at the head of this entry were corrected
   with it — an earlier draft fixed the tail and left "four of the fifteen" and "0, 1, 12
   and 13" standing eight lines above, which is the shape a universal quantifier fails in:
   the sentence asserting the fix was itself the only place the fix had landed. No count of
   the call sites is claimed here, deliberately; `grep -rn '0, 1, 12' --include='*.md'` is
   the check, and it is cheaper to re-run than to keep a list current.
4. **It reads the repository, not the running system.** No requests are made, and a webhook
   or an IAM policy is audited as it is written down, never as it is deployed.

**MIT attribution.** The port is adapted rather than verbatim, and gstack's notice is
reproduced anyway — conservatively, in `THIRD-PARTY-LICENSES.md`, with one notice covering
both port sections and a table naming which forgeward file came from which gstack file.

## DECISION — forgeward takes the quality axis, by porting gstack's five specialist checklists

**Date:** 2026-08-26 · **Version:** 0.17.0

**The decision, in one line.** The five Review Army specialist checklists that forgeward has
no equivalent of — `maintainability`, `testing`, `performance`, `api-contract`,
`data-migration` — are **ported** into `agents/` as ordinary read-only forgeward reviewers.
This **reverses** the 0.12.0 entry below it, which reversed only half of the original
delegation; the other half ("forgeward does not add a code-quality reviewer") is what goes
now.

**Why the rest of it had to go.** 0.12.0 stopped forgeward *asserting* coverage it could not
see, which was the honest fix and not a sufficient one. It left the axis genuinely unreviewed
in the configuration this repo itself runs: gate, then push and open the PR by hand, because
`/ship` would re-bump `VERSION`. The 0.12.0 entry names that as blind spot 2 — a user may read
"owner" as "covered" — and the real problem was worse than the wording, because the axis was
not covered by anybody. The measurement in `docs/axis-proposals.md` Q2 says why structurally:
`/review` is not a standalone habit, its content is embedded in `/ship` Step 9, and forgeward's
gate deliberately never reaches `/ship`.

**Why porting, and not reading gstack's copies at runtime.** Runtime reads keep the checklists
authoritative and auto-updating, which is the one real advantage, and it was rejected on three
findings:

1. **It puts the axis back behind "is gstack installed"** — the delta-scoping hole that this
   file has now recorded twice (`/cso`, then `quality`). Trading a maintenance cost for a
   coverage hole is the trade this repo keeps deciding not to make.
2. **Auto-update is not what it sounds like.** gstack's `auto_upgrade` config defaults to
   `false`, and the install on the machine this was decided on was **nine releases stale**
   (1.60.1.0 against origin/main's 1.69.0.0). A dependency that updates only when someone
   remembers is the same dependency as a port that is re-ported when someone remembers, minus
   the guarantee that it is there at all.
3. **The rubrics are not reachable by the detector.** `forgeward-detect-gstack-skill.sh`
   resolves `/review` to `~/.claude/skills/review`, which contains `SKILL.md` and nothing
   else. The specialist checklists live only inside gstack's own checkout, reached by an
   absolute path hardcoded in gstack's `SKILL.md`. So the fail-closed detector this repo
   requires for "is this gstack skill installed" would report the skill present and still not
   be able to find the files.

**Why these five are safe to fork.** They are the stable part of that tool. Each has two
commits and was last touched 2026-04-04; across v1.60.1.0 → v1.69.0.0, seven of nine releases
touched `review/` and `git diff --stat HEAD..origin/main -- review/specialists/` is **empty**.
`review/SKILL.md` itself has 111 commits, but that churn is orchestration — telemetry, plan
mode, first-run scaffolding, token reduction — not judgment. The judgment is what was taken.

**Why `security` and `red-team` were not ported.** `security` duplicates forgeward's own
384-line security reviewer, which is the axis this plugin exists for; two rubrics on one axis
is a worse review, not a longer one. `red-team` depends on orchestration that was not ported.

**Severity had to be re-based, not copied.** gstack's specialists emit
`CRITICAL|INFORMATIONAL` JSON lines into a review log. forgeward's reviewers emit
Critical/High/Medium/Low findings and one `<AXIS> VERDICT: PASS|FAIL`, where PASS means zero
Critical and zero High — and that verdict **blocks a push**. Copying the severity vocabulary
across would have made a maintainability observation a push-blocker. Per this repo's standing
rule that what a reviewer BLOCKS is the remit that matters, each ported reviewer got an
explicit per-axis floor for what reaches High, written into its prompt.

**Drift is reported, not prevented.** `scripts/forgeward-rubric-drift.sh` compares a recorded
sha256 per reviewer against the installed gstack copy, prints only on news, and always exits
0. D1–D7 in `test/gate-test.sh` pin it, including D2, which caught D1 passing vacuously
against a malformed fixture during development — silence is this script's success signal and
also its failure signal, so it needs a positive control the way E1 needs E2.

**Blind spots of the whole decision, so the entry is not read as more than it is.**

1. **A snapshot is not a subscription.** An improvement gstack ships reaches this gate only
   when a human re-ports it. The drift check reports that it happened; nothing makes anyone
   act, and nothing verifies that a re-port updated `source-sha256` honestly.
2. **The drift check is blind on the machine the port exists to serve.** No gstack means
   nothing to compare, and it prints nothing — which is byte-identical to "no drift". Its
   silence there is not a clean bill, and `--verbose` is the only thing that separates them.
3. **Nothing verifies the ported prompts.** `agents/` is out of scope for `npm test` by
   design; reviewer prompts are judged by the live-test suite, and the five new ones have not
   been run live. D6 asserts the provenance blocks are complete, which is a property of the
   file, not of the review.
4. **This does not make forgeward gstack-independent**, and the PR that shipped it says so.
   `deep-audit` still defers to `/cso`; `supply-chain-reviewer` still runtime-probes for it;
   the `/ship` handoff and its `UserPromptExpansion` enforcement hook still assume gstack; and
   the plugin's own identity text still describes it as a gate *for* gstack. **Four of five
   couplings remain open; this closed the fifth.** An earlier draft said "one coupling of
   four", which cannot be right on its own paragraph: it enumerates four that are still live,
   so four plus the one just closed is five. Four was the count identified *before* the port,
   and it was carried into a sentence that had to include the new one.
5. **The severity floors are judgment, measured against nothing.** They were written to stop
   the gate becoming annoying, not derived from a base rate the way the `error-path-reviewer`
   decision below was. If they turn out too loose or too tight, that is a re-tune, and there
   is no measurement here to re-tune against.

## RESOLVED — a security assertion was pinned by a hand-copied literal that nothing kept current

**Date:** 2026-08-19 · **Version:** 0.13.1

**Symptom.** None visible. That is the entire finding: E17 in `test/gate-test.sh` asserts that
the marker's environment shape match is anchored at **both** ends, and it does so by feeding
`forgeward-write-marker.sh` the probe's genuine output plus an appended forgery. For that to
test anything, the genuine part has to *be* genuine. It was a hand-typed copy of the probe's
`printf` line, and nothing compared the two. When the probe gained a field and the copy was not
updated, the payload stopped matching `_env_ok` on its **prefix** — so the marker was refused
for the wrong reason, `notforged` still passed, and E17 went green while no longer testing the
anchor at all. Dropping the trailing `$` from `_env_ok`, the exact regression E17 exists to
catch, then reddened nothing.

**Why it survived two field additions.** The copy had to move twice — `seo_posture` in 0.9.0
and `config_warnings` in 0.13.0 — and both times it was moved, correctly, by hand. The
obligation was written down in three places and honoured on both occasions, which is precisely
why it read as handled. It was not: the mechanism keeping E17 honest was a person remembering,
and the failure mode of forgetting was **silent**. Of the three files a new probe field
touched, the other two announce a mistake — omitting `_env_ok` reddens E10 and degrades every
marker to `{"probe":"unavailable"}` — and this one did not.

**Fix.** Delete the copy rather than warn about it harder. E17 derives its prefix from `$E1J`,
the live probe output captured at E1 with all three roots neutralised, so a new field appears
in the payload the same moment the probe emits it. A probe field is a **two**-file edit again
(the `printf` and `_env_ok`), and that is stated at the `printf` itself. The suite now holds no
literal copy of the probe's output line anywhere.

**Non-goals, so the derivation is not read as covering more than it does.**
- It **cannot see `_env_ok` falling behind the probe.** In that direction the derived prefix is
  refused, the marker degrades to `{"probe":"unavailable"}`, and E17 goes green for the wrong
  reason. **E10 is the assertion that reddens there** — it runs the real probe through the real
  writer and requires the marker's `environment` to carry probe keys. The two cover opposite
  directions and neither is sufficient alone; do not collapse either into the other.
- It does **not** decouple the probe from the marker writer. `_env_ok` is still a literal shape
  match that has to move when the probe's line moves. That coupling is a separate open P2, and
  0.13.1 only lowered its price from three files to two.
- The emptiness floor is a `case` guard, not a validator: it checks that `$E1J` looks like a
  probe line, so a broken probe reddens E17 instead of splicing a nonsense payload past it. It
  does not check that the line is *correct* — E1, E2 and E9 own that.

**Mutation evidence, both directions, and the decisive leg is the pair.** Each mutated leg
printed a verification line proving its mutation was actually present before the suite ran; a
green from a mutation that silently failed to apply proves nothing. Base 194/0 with E17 `ok`.
Dropping the `$` from `_env_ok` and changing nothing else: 193/1, the sole failure `env E17` —
so the assertion is not vacuous today. Adding an 8th probe field and updating `_env_ok` to
match, with no test edit at all: 194/0 — the derivation keeps up by itself. Then that field
addition **plus** the dropped `$`, run twice against byte-identical scripts and differing only
in which `test/gate-test.sh` executes: with this version's E17, 193/1 and E17 red; with the
hand-copied payload, **194/0 and E17 green**, printing its own unchanged claim that "the shape
match is anchored at BOTH ends" while the anchor was gone. Isolated outside the harness, the
mechanism is visible directly: under the dropped anchor the derived payload yields a marker
carrying `diff_hash=TAILFORGE` — the forgery lands and `notforged` fails — while the stale
7-field payload yields a marker carrying the real diff hash, refused on its prefix.

## RESOLVED — a typo'd config key was byte-identical to no config at all

**Date:** 2026-08-18 · **Version:** 0.13.0

**Symptom.** A repo writes `substitues:` for `substitutes:`, or `posture: private_shareable`
for `private-shareable`, or leaves a flow sequence unterminated at `[a, b`. Every one of those
produces *exactly* the output of a repo with no `.forgeward/config.yml` — same JSON, same
disclosures, same gate behaviour. The user believes an axis is silenced or a posture is pinned;
the gate has read the file, understood none of it, and said nothing. Filed as the P2 left open
by the 0.9.0 entry below, whose own "Not fixed" paragraph names all three shapes.

**The direction was never in question — the silence was.** Dropping an unrecognised shape is
correct here and stays: a refused shape costs a disclosure the user already answered, while
honouring a half-parsed one costs a skipped check. What was missing is any way to tell a config
that was *read and understood* from one that was *read and discarded*. So this is a visibility
change and deliberately not a parsing change — **every rule in the reader accepts and rejects
exactly what it did before**, and the counter is appended after all of them. Coupling the two
would have shipped a behaviour change under a visibility change's review.

**Decision 1 — a bare integer, not a message.** `config_warnings` counts; it names nothing. The
probe's output is interpolated into the pass marker as JSON by `printf`, so every field is an
injection surface, and an integer is the only shape with no representable `"`, `,`, `{` or `}`.
It is consequently matched *unquoted* in `_env_ok` as `[0-9][0-9]?[0-9]?`, which is the
narrowest arm in that whole expression — tighter than the quoted strings beside it, not looser.
Capped at 999 in the awk, because the 64KB size cap upstream still admits a file with thousands
of junk lines and the marker is read on every push. The cost is real and accepted: the user is
told there is a reason to look at their config, not which line to look at.

**Decision 2 — `seo.routes` is NOT counted, and this is the load-bearing call.** It is
documented as having no effect in `README.md`, `skills/gate/SKILL.md` and
`agents/seo-reviewer.md`, so a repo that pins it followed the docs. Warning on it would be
correct about the mechanism and wrong about the product, and a count that fires on a
conforming configuration teaches the reader to ignore the count — the same disclosure-fatigue
failure that "say it once, and only when it is news" already exists to prevent. Its subtree is
skipped by indent, which is the one and only place this reader treats indentation as structure.

**The obligation this exercised, for the second time.** A new probe field is a **three**-file
edit: the `printf`, `_env_ok` in `forgeward-write-marker.sh`, and E17's hardcoded payload in
`test/gate-test.sh`. Both halves re-verified by mutation rather than assumed: with `_env_ok`
left stale, E10 goes red and every marker degrades to `environment: {"probe":"unavailable"}`;
with the trailing `$` dropped from `_env_ok`, the *current* E17 payload reddens E17 while the
*stale* payload leaves the whole suite green — i.e. a forgotten payload retires a security
assertion and reddens nothing. The obligation is now written at the probe's own `printf`, not
only in `TODOS.md`, because that is the file someone editing it will have open.

**Vacuity, checked in both directions.** Nine of the ten new assertions want a non-zero count,
so a counter stuck on `1` would green all nine while being useless. E28 (a fully-honoured
config) and E34 (`seo.routes` plus its subtree) are the only two asserting `0`, and they are
the control. Mutating `warn()` to a no-op reddens exactly E29–E33 and E35–E37; flooring the
count at `1` reddens exactly E28 and E34. Neither mutation reddens anything outside the block.

**Stated so the limits are not mistaken for coverage.** `0` is **not** a clean bill — a config
the probe could not open reports `0` too, and only the separate `config` field distinguishes
them; the skill and README both say so, and the live-test's symlink step is written as that
exact trap. The reader is still not a YAML parser, so on a file using anchors, aliases,
multi-document streams or block scalars the number is counted over lines that were never keys
and **nothing detects that case**. It cannot see a duplicate key (YAML resolves last-wins;
both spellings look honoured and neither counts), and it cannot distinguish a key nested three
levels deep from a legitimate one, because the reader only ever tracked two levels. An empty
item (`substitutes: []`, a trailing comma) is deliberately not counted — nothing was named, so
nothing was discarded.

Suites: gate 194/194, pre-push 15/15, rules 39/39, version-check 51/51.

## DECISION — quality stays unowned by forgeward; "`/review` covers it" is withdrawn, and one measured sliver folds into `security-reviewer`

**Date:** 2026-08-16 · **Version:** 0.12.0 · **PARTLY SUPERSEDED by 0.17.0** — forgeward now
owns the quality axis outright (see the 0.17.0 entry at the top of this file). What that
reverses is this entry's first clause, "forgeward does not add a code-quality reviewer", and
its item 1. What still stands, and is now a general rule of this repo, is everything about
**deferral**: a deferral may name an owner and may never assert coverage. The
`error-path-reviewer` fold and its base-rate measurement are untouched.

**The decision, in one line.** forgeward does **not** add a code-quality reviewer — that part
of "delegate quality to `/review`" stands. What is **reversed** is the second half of the
sentence: forgeward no longer asserts that `/review` *covers* the axis. It names `/review` as
the axis owner and says plainly that it cannot see whether the owner did anything.

**Why the reversal.** The deferral ran both ways, and that was observed rather than reasoned
about. On commit `04a04fb` of another repo, gstack's `/review` log recorded `maintainability`
skipped with `reason: "covered-by-forgeward-and-coverage-audit"` and `security` with
`"covered-by-forgeward"` — while forgeward's README skipped code quality because `/review`
covers it. Both tools installed, both deferring, the axis running nowhere, and **no disclosure
firing on either side**, because each one's precondition ("the other is present") was satisfied.
Scope honestly: 2 of 22 review entries. That is an existence proof of the loop, not a measured
rate for it.

This is the same shape as the `/cso` reversal recorded further down this file, and it is the
second time delta-scoping produced a hole. The general rule it produces: **a deferral may name
an owner; it may never assert coverage.** A tool can detect that another tool is installed. No
tool in this design can detect that another tool did its job, so any sentence whose truth
depends on the other tool having *run* is a sentence forgeward is not entitled to write.

**What 0.12.0 actually changed.**

1. `skills/gate/SKILL.md` Step 1c — `quality` becomes the one axis where `present` is also a
   disclosure. When gstack `/review` is installed and `quality` is not in
   `standalone.substitutes`, the firing decision names it as an owner in one clause, never as
   coverage. Absent is unchanged: still the existing `NOT COVERED:` line.
2. `README.md` — the "gstack's `/review` covers it" claim is replaced by the loop, the evidence,
   and the statement that forgeward does not review quality.
3. `agents/security-reviewer.md` Step 3 — fail-open / fail-closed vocabulary and an explicit
   "every finding here needs a stated failure consequence to reach High", then the two folded
   error-path rules (below).

**What was deliberately NOT built, and the rule that decided it.** `error-path-reviewer` was
specified as a seventh, blocking reviewer with four rules, and gated on a base-rate measurement
fixed **in advance**: ≥1 true High per 5 PRs → build it; below that → fold rules 1 and 3 into
`security-reviewer` Step 3. Measured 2026-08-06: **0 true Highs per 5 PRs in both repos**, and
0.25/5 on an extended forgeward window. So: fold, no seventh reviewer.

- **Rule 1 (discarded failure signal)** — folded, as a new Step 3 bullet. It had no counterpart
  in Step 3 at all, which is why the fail-open/fail-closed vocabulary had to land first: without
  the distinction the bullet cannot say which *direction* a discarded status fails in, and that
  direction is the entire finding.
- **Rule 3 (unchecked conditional-write result)** — folded by widening the existing
  "check-then-act without a lock, and the silent no-op" bullet, which already owned the database
  half with the right discipline. The added half is the non-DB one: conditional file writes,
  in-place edits that matched nothing, a 404 folded into the 2xx branch, a failed
  compare-and-swap precondition.
- **Rules 2 (dead/unreachable error path) and 4 (resource leak on the error path)** — **NOT
  folded, on purpose.** They fired zero times anywhere in the measurement. Folding a rule that
  has never fired adds prompt weight to every security review in exchange for nothing, and a
  reviewer instruction nobody's diff ever matches is indistinguishable from one that does not
  work. Reversible: the measurement is in `docs/axis-proposals.md` Q2 and they can be folded the
  day a real instance shows up.

**The measurement's own known defect, kept attached to the result.** The base rate was a by-hand
pass over merged diffs, and a diff-reading pass structurally cannot see this class at its most
common: four known instances in this repo (`json_get` ×2, `strip_quoted`, `marker_get`) were each
visible only when two arms of one helper were read *together*, and one of them was silently
cancelling the #11 fix to the arm beside it. Three shipped. This does not overturn the fold — a
reviewer that also reads diffs would have scored the same 0 — but it forbids the conclusion "the
class is rare", which is the conclusion a bare 0/5 invites. Weigh it if the axis is rescored.

**Blind spots of the whole decision, so the entry is not read as more than it is.**

1. Nothing here fixes gstack's half of the loop. `/review` still defers to forgeward, and only
   gstack can stop it. This entry closes the half forgeward owns and no more.
2. Naming an owner is not coverage, and a user who reads the firing decision quickly may take it
   as one. The wording is chosen against that; nothing enforces it.
3. The fold is prompt text, judged by no automated assertion. `agents/` is out of scope for
   `CLAUDE.md` and for `npm test` by design — the reviewer prompts are exercised by the
   live-test suite, and a folded rule that never fires would look exactly like one that has
   nothing to report.

## RESOLVED — the repo under review could supply the `json` module the hook judged it with

**Date:** 2026-08-15 · **Version:** 0.11.0

**Symptom.** With `jq` off the PATH, a `json.py` committed to the branch being reviewed makes
`forgeward-gate-check.sh` **allow** a publish it should deny. The hook prints nothing and the
push proceeds. Nothing in the output distinguishes this from an ordinary ungated command that
was correctly let through, which is the property that makes it worth a record: a missed gate
does not announce itself.

**Mechanism.** `python3 -c` sets `sys.path[0]` to `''`, the process's current working
directory. The hook runs from the repo being pushed. `import json` therefore resolves against
that repo before the standard library, so a file named `json.py` at its root *is* the parser
deciding what the hook believes the command was — return `{"tool_input":{"command":"ls -la"}}`
and a `git push` reads as a benign command. `json_get`'s python arm is reached whenever `jq`
is absent or exits non-zero, both of which A20/A21 already exercise as supported states.

**Repro** (this is A26 in `test/gate-test.sh`, with both controls):

1. A repo on a feature branch, no PASS marker. Commit a `json.py` whose `load()` returns
   `{"cwd": "<repo>", "tool_input": {"command": "ls -la"}, "hook_event_name": "PreToolUse"}`.
2. Build a PATH with every `jq`-bearing directory mirrored minus `jq` (the A20 shim; a
   hand-written tool list is how the first attempt at this produced a vacuous green).
3. From inside that repo, feed the hook a real publish payload.
   - shipped `forgeward-gate-check.sh` → **deny**
   - the same file with `-I` stripped → **empty output, i.e. allow**
   - the `-I`-stripped file with the `json.py` removed → **deny** (so the ALLOW above is the
     shadow, not a script the edit broke)

**The fix** is one flag: `python3 -I -c`. `-I` drops the CWD from `sys.path` and implies
`-E`/`-s`, so neither the reviewed repo, nor `PYTHONPATH`, nor a user site-packages directory
can reach the interpreter. Applied at all four shipped sites (`forgeward-diff-hash.sh`,
`forgeward-gate-check.sh` ×2, `forgeward-pre-push.sh`); `ci/check-version-monotonic.sh`
already had it from round 6.

**What was wrong in the filing, and it is the reason this sat open.** `TODOS.md` had carried
this since round 6 as a **P2 hardening item, explicitly not a live bypass**, on the reasoning
that "reaching it at all requires write access to the user's checkout — which `TODOS.md`
already discloses as defeating the local gate outright via marker forgery or `--no-verify`",
and that the CI check was the real escalation "because a **fork** PR author has no other
access and needs none."

That inference is wrong, and it is wrong in a specific, reusable way: it slid from *a file at
the repo's root* to *write access to the repo*. Python imports a **file**, not an index. The
shadowing module arrives with the branch — it is committed by the same fork author whose lack
of other access was the argument for treating the CI check as the serious case. The reviewer
who filed it had the right mechanism and reasoned about the wrong actor.

**Two directional limits, stated so the fix is not read as broader than it is.** The bypass is
the **no-jq arm only** — with a working `jq`, `json_get` returns before `python3` is reached
and the shadow is inert; and it requires the user to push from that repo's directory, which is
the normal case but not a guarantee. Both were checked rather than assumed.

**Generalized in the same commit.** `export LC_ALL=C` moved from a per-script decision to a
repo-wide one (all 13 tracked `*.sh` outside `test/`), and the two inline `LC_ALL=C` command
prefixes were **removed** rather than left beside the new pin, on the same one-mechanism rule
that deleted `num_lt`'s `local LC_ALL=C` in round 3 — the two forms are not equivalent, and
leaving both live is how a reader comes to trust the weaker one. `test/` is out of scope
deliberately: the suite spawns these scripts, so a pin there would be inherited and make the
property untestable from inside the test that checks it.

**Pinned by A25–A29**, all five mutation-checked in both directions. A25 and A27 count the
**violating** form and enumerate from `git ls-files` rather than a fixed list — "five sites
carry `-I`" would go green the day a sixth arrived without it. A29 pins the executable bit,
and it is not hypothetical: inserting the locale pin with `awk > tmp && mv` rewrote all eleven
scripts at the umask default, dropping 755 → 644, and every invocation became `Permission
denied`. The suite caught it only as 28 unrelated assertions collapsing at once, with nothing
naming the cause.

## RESOLVED — the secrets scanner read untracked files and put them in a persisted transcript

**Date:** 2026-08-10

**Symptom.** `security-reviewer`'s documented Gitleaks invocation read a developer's
local, gitignored `.env` — a private key plus three service credentials — during a real
gate run. The reviewer noticed and kept the values out of its returned report, but by
then they had already been written to disk in the subagent's persisted transcript at
`~/.claude/projects/<project>/<session>/subagents/agent-*.jsonl`: outside the repo, outside every cleanup
this plugin performs, and outside the user's line of sight. An untracked file was never
committed, so it cannot be the leak a secrets scanner exists to catch; reading it is
pure downside.

**Two causes, and the first one hid the second.**

*Defect 1 — the documented invocation passed N paths to a 1-path command.*
`agents/security-reviewer.md` read
`forgeward-scan.sh gitleaks dir <changed-paths> --no-banner`. `<changed-paths>` is plural;
`gitleaks dir [flags] [path]` is singular. Mechanism, from the source rather than inferred
(`cmd/directory.go`, v8.30.1):

```go
source := "."
if len(args) == 1 { source = args[0]; if source == "" { source = "." } }
```

There is no cobra `Args` validator, so a second positional is **not** an error — `len(args)`
is simply != 1 and `source` STAYS `"."`, the current working directory. The extra argument
is neither rejected nor dropped-with-the-first-honoured; the whole target is silently
replaced by the cwd. Verified against the real binary: one path scanned 15 bytes, two paths
scanned 176 — byte-identical to `gitleaks dir .` — and run from a parent directory the
two-path form reported the leaks in a gitignored `.env` two levels down.

*Defect 2 — `dir` mode is a filesystem scan at all.* Fixing defect 1 alone does not fix
this: a correctly-scoped `gitleaks dir .` reads the same `.env`, and any changed-path list
containing a directory re-triggers it. Whether the value then reaches stdout is an
output-mode question with an unhelpful answer — `--no-banner` alone prints counts only, but
`-v` prints `Secret: <value>` and `-f json -r -` prints `"Secret": "<value>"`, and a
reviewer needs one of those to report `file:line` at all. The count-only mode is not a
mitigation, it is a mode in which the reviewer cannot do its job.

**Fix.** The scanner must only ever see paths that are actually in the reviewed diff.

1. **Primary shape is the commit range**, not the filesystem:
   `gitleaks git --log-opts="<base>...HEAD" --no-banner --redact -f json -r -`. `git` mode
   scans the patches in that range, so untracked files are structurally out of scope — not
   excluded by a rule that could be wrong, but unreachable. Where working-tree state is
   genuinely needed, `dir` runs **once per changed FILE**.
2. **`--redact` always.** It replaces every `Secret`/`Match` with `REDACTED` while keeping
   `RuleID`, `File`, `StartLine` and `Fingerprint` — everything needed to report and rotate.
   This closes the value half; (3) closes the read half. Neither is sufficient alone.
3. **`forgeward-scan.sh` layer 4** enforces it rather than asking: for the `dir`/`file`/
   `directory` family it requires **exactly one existing regular file that git tracks**.
   Zero paths, two paths, a directory, and an untracked file are all refused with exit 2.
   The argv parse skips flag values from an enumerated table, and an unlisted value-taking
   flag is the only way it can diverge from cobra's. After the subcommand that direction is
   already safe — the stray value looks like a positional, the count hits 2, refused. Before
   it, it is not: `gitleaks --unlisted V dir .` makes `V` look like the subcommand, and a
   "pos[0] isn't dir, nothing to guard" reading would wave the directory scan through. So
   the subcommand is checked against an enumerated set and anything unrecognized is refused,
   which also covers the pre-8.19 `detect --no-git` — the same filesystem walk under an
   older name. Caught while reviewing the first version of this guard, whose comment claimed
   "fails closed" when that held in only one of the two directions.
4. **Trivy loses `secret` from `--scanners`.** `trivy fs <dir>` is the same filesystem walk
   with the same exposure. Vuln and misconfig need the repo tree and do not emit secret
   values; gitleaks owns the secrets axis, diff-scoped. (Trivy has no analogue of defect 1:
   per its source, `filesystem`'s `PreRunE` calls `validateArgs`, which errors on a second
   positional rather than silently rescoping. Read from source — trivy is not installed
   here, so that half is unverified against a binary.)
5. **Short `-r` closed for gitleaks.** A bare `-r` is a stated blind spot in this wrapper
   because it means "recursive" in some tools — true in general, false for gitleaks, whose
   help reads `-r, --report-path string  report file`. Only the long form was enumerated,
   so `gitleaks dir x -r evil.json` reached the write the long form exists to refuse. Now
   per-tool, like the existing `-o` format/destination exemption; every other tool's `-r`
   is untouched.

**Why not a `.env` exclusion.** Because a **committed** `.env` is a genuine, valuable
finding and must keep firing. The line is tracked vs untracked, not the filename — and a
filename allowlist would both miss the real finding and fail to cover the next untracked
credential file that is not called `.env`.

**Known scope of the fix, stated so its absence is not read as coverage.** `tracked` is a
proxy for "in the reviewed diff": the wrapper gets an argv, not a base ref, so a tracked
file the diff never touched still passes. Diff scoping stays the reviewer's job. The guard
is gitleaks-only and deliberately does not fire on `trivy fs .`, `semgrep scan <many
files>`, or `gitleaks git <repo>` — a directory is the correct target for all three. A bare
`gitleaks git` with no `--log-opts` scans full history and is allowed on purpose: auditing
a repo's history for leaked secrets is legitimate, and everything it reads is committed.
A tracked symlink pointing outside the repo passes `-f` and, under `--follow-symlinks`,
gitleaks reads the target. Layer 1 matches flag tokens and cannot see inside a flag's
value, so `--log-opts="--output=x"` — using the very flag this change starts recommending
— forwards `--output` to `git log` and writes the file; layer 3 catches it and exits 3
naming the path, which is the containment layer 3 exists to provide. The check-then-exec
sequence is TOCTOU: a process with
concurrent write access to that exact path can swap the tracked file for a symlink in the
window. Accepted, not fixed — that attacker already has local write access to the repo,
which dwarfs the misaimed-scanner threat this guard addresses. Both are now in the
script's own NON-GOALS block, so their absence is not read as coverage.

**Considered and declined: a `PreToolUse` text deny for `gitleaks dir`.** The hook matches
command TEXT and therefore cannot tell whether a target is a directory, a file, or tracked
— the fact that decides the case. It would also over-deny this repo's own docs and tests,
which quote the defective shape. The wrapper sees the real argv and the real filesystem;
that is where the check belongs.

**Exposure already on disk.** Present from 0.2.0 (2026-07-13, the commit that added
`security-reviewer`) through 0.9.1, unchanged. Anyone who ran the gate in a repo with a
local `.env` may have those values in `~/.claude/projects/<project>/<session>/subagents/agent-*.jsonl`.
That path is outside the repo and no cleanup in this plugin touches it, so it is called out
in README under *Security scope* with a filenames-only grep and an instruction to rotate —
deleting the transcript is housekeeping, not remediation.

**Coverage.** `test/gate-test.sh` P8i (short `-r`, separated and cuddled, with `-r -` still
allowed), P8j (the argv rules: zero/two paths, a directory, `.`, and an untracked file all
refused; one tracked file in any argv position and every `git`-mode shape allowed;
`detect --no-git`, `detect --no-git --source .env`, `protect`,
`--baseline-path x frobnicate .` and a bare `frobnicate` all refused as unrecognized
subcommands — the first three are the exact argv a security review reproduced against the
real binary through the pre-fix wrapper), and P8k
(end-to-end against the real binary, on the observed fixture: a gitignored `.env` with a
fake AWS key and two clean tracked files). P8k carries a **control leg** that bypasses the
wrapper and asserts the raw two-path scan DOES leak — without it the other assertions could
pass with the guard ripped out, since `--no-banner` alone prints no values. Verified by
mutation: with layer 4 disabled, P8j and P8k both fail, P8k reporting
`[SECRET LEAKED by two-path scan]`; and separately, softening the unrecognized-subcommand
branch back to `return 0` fails P8j on all three of its legs. P8i's target changed from `.` to a tracked file so it
still exercises the dash-led-flag guard rather than passing on the new target guard.

**Postscript (0.9.3): the rotation notice pointed at a path that does not exist.** The
transcript location was written as `~/.claude/projects/<project>/subagents/*.jsonl`. The
real layout has a **session-uuid level** in between:
`~/.claude/projects/<project>/<session>/subagents/agent-*.jsonl`. The wrong path came in
verbatim from the defect report and was propagated to README, DECISIONS, TODOS,
`forgeward-scan.sh`, the agent file, the commit message and the PR body without once being
run. It was caught only because a reader tried the command and got
`No such file or directory`.

This is the failure mode a rotation notice can least afford. The glob does not error in a
way that says "your path is wrong" — it reads as *nothing matched*, i.e. clean, so a user
who follows the instructions exactly concludes they were unaffected and does not rotate. A
notice that silently converts "exposed" into "clean" is worse than no notice, because it
also retires the user's suspicion.

Two corrections, beyond the path itself. The published grep now searches recursively from
`projects/` so the depth cannot be got wrong again, and it matches credential **value**
shapes rather than the words `SECRET`/`TOKEN`/`PASSWORD`. On the machine where this was
found the value-shaped command returned 15 files, of which the genuinely actionable set was
smaller again — the rest being public-by-design Supabase anon keys, example keys and the
fix's own test fixture. The notice says so, because a number presented without that caveat
is read as a leak count.

The word-based net did not survive the same treatment. Case-*sensitive* it returned 660
files, but a transcript holding `const dbPassword = process.env.password` does not match
it while the shouty env-var form does — and transcripts capture source and JSON, where the
lowercase form is the common one. So the case-sensitive version misses the realistic case
and returns nothing: the original defect again, in a third costume. Adding `-i` fixes the
correctness and destroys the utility — it then matches **1751 of 1756** transcripts on this
machine, 99.7%, because those words appear in any conversation that discusses
authentication at all. It is published with `-i` and scoped to a single project directory
rather than the whole archive, described as a reading list for a project you already
suspect. The alternative — publishing it case-sensitive because the number looks more like
a result — is the failure this entry is about.

The pattern list itself then failed the same test at one remove. The first draft carried
six shapes, which meant a leaked Stripe, OpenAI, Google or npm credential returned empty —
"reads as clean" again, relocated from the path to the pattern list. Widening to ten fixed
that but produced its own version of it: the connection-URL pattern
(`://user:pass@`) matched **201** files on this machine against **15** for the nine
prefixed shapes combined, so a single command would have buried three private-key hits
under two hundred documentation URLs. Under-reaction from noise is the same defect as
under-reaction from a broken path. The notice therefore runs the prefixed shapes first and
the URL shape second, labelled as a skim, and states outright that the list is not
exhaustive and an empty result is not a clean bill.

The gate's privacy reviewer then found the same shape a third time, one step further out:
the notice invites the reader to judge whether a match is a real leak, but every published
command is `-l` and the triage step that follows had no guidance at all — so the safety
property stops exactly where the user starts opening files. Its recommended remedy was
`grep -ohE <pattern> <file>`, "prints only the matched substring rather than the whole
line". That is rejected, and the reason is worth recording because the suggestion is
superficially the safer option: the matched substring **is** the credential. `-o` is a
narrower way of printing the secret, not an alternative to printing it. The notice instead
tells the reader to narrow by **type** — re-run the block one `-e` pattern at a time, so
the filename carries the credential shape and the value is never rendered — and, where
that is not decisive, to rotate rather than look. Rotating a credential that turns out to
have been public costs minutes; confirming it by eye costs an exposure.

The re-review then caught that fix committing the same error one layer down: the narrowing
step was given in prose while the commands around it were given in full, and a
reader retyping it by hand is exactly as likely to drop the `-l` as the hand-rolled word
net that had just been published for that reason. Worse, dropping `-l` is *more* exposing
than the `-o` the same paragraph forbids — plain `grep` prints the entire matching line,
so the credential comes back wrapped in its context. It is now a complete command with the
flag-dropping hazard named. Three passes, three instances of one shape: guidance that
stops one step short of where the reader actually is.

The third pass found the fourth. Scoping the word net to one project introduced a
`<project-slug>` placeholder, and pasted literally that command prints nothing and exits 2
— under the `2>/dev/null` the notice itself prescribes, the error is swallowed and the
result is indistinguishable from a clean scan. The notice had hand-held carefully through
the `<session-uuid>` glob gotcha and then reproduced the identical failure one paragraph
later with a path segment it never explained how to construct. It now says how to find the
slug and states that no output from that one command means check the slug first. It is the
only command in the notice that can fail that way; the others point at
`~/.claude/projects/` itself, which exists as soon as Claude Code has run once.

And the fourth pass found the fifth, inside that fix. The guidance told the reader the slug
was "the repo's absolute path with the separators turned into `-`", which is close enough
to true to be dangerous and false in the case at hand: the slug is keyed to the directory
the **session was launched from**, not the repo. This repo sits one level below the
directory its own session was launched from, so its transcripts are keyed to the parent and
a reader following the stated formula would have scanned a directory that does not exist — silently,
exit 2, swallowed by the prescribed `2>/dev/null`. A wrong formula stated as fact is worse
than a placeholder, because the placeholder at least looks unfilled. The notice now says to
read the slug out of `ls` and not to derive it, names the launch-cwd keying as the reason,
and drops the claim that only a literal placeholder could fail that way.

Five passes, five instances, each in a different place: the path, the pattern list, the
triage step, the placeholder, the slug formula. Every individual fix was correct. The shape
is that a remediation notice grows a new edge every time it is extended, and the edge is
always the same one — an empty result that reads as clean. The general lesson is narrower
than "be careful": **any instruction in this section that names a path segment the reader
must supply is a candidate for it**, because a wrong path and a clean scan are the same
observation. Check the next one against a real filesystem before it ships.

The rule this violated is the ordinary one: a claim inherited from a report is a lead, not
a fact, and the check that settles a path is running it. That applies to a reviewer's
proposed fix as much as to a defect report's path — both arrive sounding authoritative.

## DECISION — env/config rules ship in the security-reviewer's pack but can never fail a gate

**Date:** 2026-08-14 · **Version:** 0.10.0

**The problem the placement had to solve.** `rules/env-config.yml` catches two JS/TS shapes —
`??` used as an env-var fallback, and an env-dependent SDK client constructed at module scope.
**Neither is a security finding.** Both are build-safety and config-correctness: a blank
environment variable failing an entire deploy rather than the one route that needed the
credential. Putting them in `security-reviewer` risks the thing forgeward should least want,
which is a security axis that quietly grows into a general code-quality axis until "security
FAIL" stops meaning anything specific.

**Two placements were genuinely defensible.** (a) Ship them in the security pack and report
them at Low, flagged defense-in-depth, so they can never fail a gate alone. (b) Route them to
a reviewer that actually owns build-and-config integrity, and — since no installed component
does — use the gate's Step 1c "say what this INSTALL cannot cover" mechanism to disclose
build-config as an unowned axis.

**Decision: (a).** Four reasons, in the order that decided it:

1. **The remit that matters is what a reviewer BLOCKS, not what it prints.** The file already
   establishes that Critical/High fail a gate and Medium/Low never do. Pinning this pack at Low
   means the verdict bar is bit-for-bit unchanged: the reviewer's *reporting* surface widens,
   its *blocking* surface does not. That is the whole of the "don't widen security's remit"
   concern, and it is addressed structurally rather than by intention.
2. **(b) is incoherent while the detection exists.** Step 1c discloses axes **no installed tool
   owns** so the user knows to cover them by hand. Announcing "no tool covers build-config" in
   the same run that just scanned for build-config problems and found two is a worse lie than
   the silence it replaces.
3. **security-reviewer is the only component with the plumbing.** It already has the
   `forgeward-scan.sh semgrep` invocation, the JS/TS extension scope, the changed-line
   discipline, and the artifact contract. A new reviewer would duplicate all of it.
4. **Standing up a build-integrity reviewer for two rules is over-building.** A reviewer is a
   spawned agent with a verdict, a firing table row, and a place in the parallel fan-out. Two
   advisory WARNINGs do not justify one. If this pack grows past a handful of rules, or grows a
   rule that should legitimately block, that is the trigger to revisit — and revisiting means
   moving the pack, not promoting its severity in place.

**Enforcement, so the choice is not just a comment.** Three places carry it, and they are
supposed to agree: the rules carry `metadata.forgeward-report-severity: low`; the pack header
states it in prose with a pointer to this entry; and `agents/security-reviewer.md` Step 2 says
to report every finding from this pack at Low **regardless of what the JSON says**, and not to
promote one because its consequence sounds severe. The invocation also omits `--error`, unlike
`wp-security.yml`, so an advisory finding cannot even present as a failed scan.

**What this decision deliberately does NOT do.** It does not vendor `env-config.yml` into
`ci-gate`'s security workflow. `ci-gate`'s first core rule is green-on-arrival — "a
green-looking workflow that's red on arrival is worse than no CI" — and advisory WARNINGs that
turn a required check red are precisely that failure. The pack runs in the local gate, where a
Low finding is information; it stays out of CI, where the only signal is pass/fail. Tracked in
`TODOS.md` as a deferral rather than left as a silent omission.

## RESOLVED — the fast reminder denied branch deletions the enforced hook already allows

**Date:** 2026-08-07 · **Version:** 0.9.1

**Repro.** After merging a PR on GitHub and pulling, cleaning up the merged branch:

```
git checkout main && git pull --ff-only
git branch -d fix/my-branch
git push origin --delete fix/my-branch     ->  DENIED
```

with `forgeward gate: the current branch (main @ 5f93b2a) has not passed /forgeward:gate.`
Fired on `main` immediately after a fast-forward pull, when `main` and `origin/main` are
identical and the gate's own Step 0 would say "nothing to gate".

**The advice was not merely annoying, it was unactionable.** Deleting a ref publishes no
code, so there is nothing for a reviewer to review and nothing a marker could attest to.
The only way through was to gate an *unrelated* branch first. Two shapes hit it: cleaning
up a branch you just merged, and dropping a stale branch that never had a PR — for which
no marker will ever exist.

**The finding is the ASYMMETRY, not the friction.** `forgeward-pre-push.sh` — the
ENFORCED layer — already handles this, at the top of its ref loop:

```
[ "$local_sha" = "$ZERO" ] && continue    # branch deletion -> publishes no code
```

It gets it right because git hands it resolved refs and SHAs, where a deletion is
unambiguous. Verified against real git rather than inferred: for **both**
`git push origin --delete x` and `git push origin :refs/heads/x`, git writes
`(delete) 0000000… refs/heads/x <remote-sha>` on the hook's stdin. So the layer whose own
header calls itself "a fast best-effort reminder; the enforced check is the pre-push
hook" was refusing a command the pre-push hook waves through. **A reminder stricter than
the thing it reminds you about is a bug in the reminder, not a policy.** The two layers
are allowed to differ in PRECISION — one reads text, one reads refs — but not in
DIRECTION.

**Decision — relax the matcher, not the message.** The alternative considered was to
leave the matcher alone and route the deny message to an escape hatch. Rejected: there is
no escape hatch to route to. `--no-verify` bypasses the *pre-push* hook, not a PreToolUse
`deny`, so the only recourse was the `gh api -X DELETE` workaround TODOS.md had been
carrying — i.e. telling the user to stop using git. Fixing the message would have
documented the disagreement rather than removed it.

**What settled the design was running real pushes at a real remote and diffing the ref
list, not reading git-push(1).** Three observations, and each one changed the code:

```
git push origin --delete y z    ->  y and z both deleted, nothing published
git push origin :q newcode      ->  q deleted AND newcode PUBLISHED
git push --tags origin :d2      ->  d2 deleted AND a tag on an unpublished commit PUBLISHED
```

- The first is why `--delete` alone settles it: the flag makes *every* listed ref a
  deletion, and git itself refuses `--delete` together with `--all`/`--mirror`/`--tags`.
- The second is why the `:<ref>` form additionally requires that **no plain refspec** is
  present — at most one non-option token (the remote) may sit beside the colon refspecs.
  A "contains a colon refspec" test would have allowed a real publish.
- The third is why unrecognised **options deny** instead of being skipped. The first
  draft skipped anything starting with `-` and would have allowed `--tags origin :d2`.
  An option can send refs the argument list never names, and it can consume a separate
  VALUE token that would otherwise be counted as a refspec. Only flags that do neither
  are whitelisted.

**Everything ambiguous denies, and the list is short enough to audit.** The exemption is
offered only on a TRUSTED residue (quoted spans already blanked, so a quoted or
`$`-built `--delete` cannot open it); the residue must be ONE SIMPLE COMMAND (any of
`;&|(){}<>$` a backtick or a newline refuses it outright, so
`git push origin --delete x && git push` and the two-line form keep denying); `git push`
must be the literal command word; and flags are matched as WHOLE argv tokens, so
`--delete-this-is-not-a-flag` opens nothing. The stacked-branch workflow that interleaves
deletions with real pushes therefore keeps being gated — that is the point, not a
casualty.

**The blind spot is unchanged and is stated in the code rather than implied.** A deletion
issued through indirection — `bash -c "$CMD"`, an alias, a function, a script file,
`git -C <path> push --delete x`, flags arriving in a variable — is invisible to this
layer and always will be. That is the same class the file header already defers to the
pre-push hook; this branch neither narrows it nor widens it.

**The gate's own security review caught a real bypass in the first draft, and it is the
most useful thing on this page.** `strip_quoted` BLANKS a quote or backslash to a space
rather than deleting it — the residue-length guard depends on that 1:1 mapping — so an
empty quote pair sitting inside one real argv token splits it into two tokens bash never
produced. `git push /pub/repo'':x.git` is ONE repository argument; the classifier saw
`… /pub/repo  :x.git`, counted plain=1 colon=1, and exempted it. Reproduced end to end:
the matcher returned ALLOW and the command really published `refs/heads/main` to a target
that had no refs.

Every other consumer of the residue is a boolean word match that extra spaces cannot fool
(`_pub_re` uses `[[:space:]]+`). `_is_delete_only` is the FIRST that depends on exact
token boundaries and counts, and blanking does not preserve those. That is the general
lesson, not the specific string: **a scanner built to answer "does this word appear?"
does not automatically answer "what are the arguments?"** — a new consumer of an old
sanitizer inherits its guarantees, not its intentions.

The fix refuses the exemption when the ORIGINAL text contains any `'`, `"` or `\`, and
that is a complete cover rather than a patch on the observed string: `strip_quoted` maps
every character to itself or to a space and never removes one, so a word boundary can only
ever be ADDED, and every path that adds one requires one of those three characters. The
cost is an over-denial on a quoted branch name, which is the direction this file always
fails in.

**Then the re-gate found the same shape a second time, through a different bash feature,
and THAT is what changed the design.** `read -ra` does not glob, so an unquoted
`git push [os]* :newcode` is ONE token to the classifier and however many files it matches
when bash runs it. Reproduced against a real remote: allowed, and it deleted `newcode`
while publishing `secretbranch` — a ref the command text never named.

The first fix had been a blocklist, and a blocklist is only ever as good as my memory of
every construct bash uses to synthesize a word: globbing, brace expansion, substitution,
process substitution, and whichever one is missing from that list. Being wrong twice in
one branch is the argument for inverting the test. Every token now has to match
`^[A-Za-z0-9_.:/@+=-]+$` — what a remote name, a URL, a path and a refspec are actually
made of — so the unknown construct fails CLOSED instead of sailing through. That set is
not a guess about git either: `git check-ref-format` rejects `*`, `?` and `[` in a ref
name, checked rather than assumed, so nothing nameable is lost. `~`, `^`, `%` and a `?`
in a URL query are excluded too and over-deny a few legal-but-exotic spellings.

**The generalisable lesson is one sentence: a scanner built to answer "does this word
appear?" does not answer "what are the arguments?".** Both Criticals were the same
mistake — a text layer's word boundaries are not the shell's — and neither was visible
from reading the function. Both were found by running the command.

The same review also found the colon form's invariant was stated as a COUNT when git
treats it as a POSITION: git takes the first bare positional as the repository wherever
the colon refspecs sit, so `git push :x origin` reads `origin` as a refspec. It fails in
git today for an unrelated reason — `:x` resolves as an empty-host ssh target — which is
exactly why it was tightened. An exemption must not rest on someone else's error path.

**Method note — the assertions were mutation-tested, and that changed the code twice.**
Every deny case in A23 was already green before the fix (the old matcher denied
everything), so the deny half proves nothing on its own; only the mutation run shows it
is load-bearing. Two findings came out of it. The command-word check was originally two
lines — `tk[0]` is `git`, `tk[1]` is `push` — and *neither could be killed alone*,
because `_pub_re` has already guaranteed the words appear adjacent, so any command where
they are not the first two tokens is caught by whichever check the other one missed. They
were collapsed into one regex so a deletion of it is actually caught. And the newline
refusal was genuinely unpinned: without it, `read -ra` reads only the FIRST line of the
residue, so a two-line command whose first line is a deletion and whose second is a real
push would have been allowed. That is a fail-OPEN, found by mutation and not by review.

## DECISION — version monotonicity is enforced in CI, because the gate structurally cannot see it

**Date:** 2026-08-06 · **Version:** unchanged (0.9.0 — this touches no shipped file)

**Hazard.** The plugin version lives in three manifests (`package.json`,
`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`) and nothing checked that a
merge moved it forward, so **merge ORDER was load-bearing** whenever two version-bumping PRs
were open at once. On 2026-08-06 #17 bumped to 0.7.5 and #18 to 0.7.6; merging #17 second
would have taken the marketplace manifest 0.7.6 → 0.7.5, and most plugin-manager update logic
reads a backward version as no-op-or-worse rather than as an upgrade. That instance was
avoided **by hand**, by merging #17 first. The hazard was never fixed, only dodged.

**Decision 1 — CI, not the gate, and this is structural rather than a preference.** V1–V3
deliberately neutralize a version-only bump in the substantive-diff hash so a release does not
force a spurious re-gate — and that neutralization is **direction-blind**. A backward bump is
exactly as invisible to the hash as a forward one, so nothing downstream of the hash can see
this class at all. Catching it needs a comparison of two refs, which is what CI has and a
local pre-push hook does not. `.github/workflows/version-check.yml` is the repo's first CI
workflow; `ci/check-version-monotonic.sh` is the check, runnable by hand with the same
arguments.

**Decision 2 — the rule is "never backward", not "always bump".** Equality passes. Most PRs
here are docs or fixes that leave the version alone (#21 is one, and so is this one), and a
check demanding a bump on every branch would be red on the common case — which is how a
required check gets switched off rather than fixed. Only a strict decrease is refused. Pinned
from both sides by R1/R2: a comparator that refuses everything is as broken as one that
refuses nothing, and only the paired assertions can tell them apart.

**Decision 3 — refuse what it cannot order; never guess.** A prerelease (`0.10.0-rc1`) has an
ordering this script does not implement, and a manifest carrying two `"version"` fields has no
unambiguous answer. Both exit 1 with the reason named. That is the opposite of the direction
the gate hook takes and deliberately so: this runs in CI, where a false red costs one human
glance, while the hook fires on every Bash tool call and a false red wedges the session.

**Decision 4 — zero comparisons is a refusal, not a pass.** If the base ref does not resolve
(a shallow checkout) or carries none of the manifests, the script exits 1 rather than printing
`ok`. Cost: the one-time bootstrap PR that first introduces the manifests goes red and needs a
human to wave it through. Accepted — it happens once per repo, and the alternative is a check
that is silently inert exactly where it has never run before.

**The comparator went wrong twice, and the second one is the entry worth keeping.**

Two obvious forms are wrong at the outset. `major*1000000 + minor*1000 + patch` silently
**ties** `1.0.1000` with `1.1.0`, so a backward merge across that boundary passes clean
(R6/R6b). A plain string comparison is wrong in a nearer way — it calls `0.10.0` *behind*
`0.9.0`, which this repo hits on its next minor (R5/R5b). The fix was component-wise
`$((10#$x))`, and the comment written above it said that form "has no such ceiling".

**That comment was false, and this branch's own security review falsified it in one command.**
Bash arithmetic is fixed-width signed 64-bit, so a component at or above 2^63 wraps
two's-complement — and nothing upstream bounded what reached it, because the validating regex
accepts a digit run of ANY length. Demonstrated end to end: base `18446744073709551617.0.0`
(2^64+1), head reverted to `1.0.0` — a drastic backward move, the exact hazard this file exists
to stop — printed `ok ... not behind` and exited 0. The ceiling had moved from 10^3 to 2^63; it
had not gone away.

Two things follow, and neither is "add a bounds check". First, the remedy is
`num_lt`: strip leading zeros, compare lengths, then compare bytes under `LC_ALL=C`. It uses no
arithmetic at all, so the claim the comment makes is now structurally true rather than true up
to a bound nobody had measured. Second, **R6 passed throughout**. It was written against the
comparator already chosen, so it pinned the ceiling that had been thought about and was blind to
the one that had not — the same shape as V5/V6 passing while the jq/python3 divergence shipped
underneath them. An assertion cannot find a ceiling nobody suspected; a reviewer running the
arithmetic on adversarial input can, and did.

**What else the gate's own review changed.** `actions/checkout` moved from the `v4` tag to
`11d5960a326750d5838078e36cf38b85af677262`. The tag pin had been recorded as a deliberate
trade-off — no SHA had been verified, and an unverified SHA from memory is worse than a
first-party tag — but the reviewer simply *resolved* it (`git ls-remote --tags`, re-run
independently here), which turns a defensible deferral into an unnecessary one. `TODOS.md`
carries the refresh obligation instead, since a SHA pin without one decays into a stale-action
problem. `persist-credentials: false` was added on the same step: the workflow holds only
`contents: read` and references no secrets, so this is depth rather than a live hole, but the
script that runs next is checked out from the PR head and on a fork PR that is contributor
content.

The version validator's first draft was `printf | grep -qx`, which is **the P1 defect this
repo already paid for once**: `grep -q` exits on match and can SIGPIPE the `printf` still
writing to it, and `set -o pipefail` then promotes 141 to the pipeline status, so the test
reports NO-MATCH on input it just matched. Replaced with a bash `[[ =~ ]]`, which forks
nothing. `grep -c` and `grep -o` in the same function drain to EOF and are unaffected — only
an early-exit reader can orphan its writer. The comment at that line says so, because the
tempting edit is to put `grep -q` back.

The ambiguity guard (Decision 3 / blind spot 3) was **right by accident** until round 2 of the
review found it. It counted version fields with a bare `grep -c`, which counts matching *lines*,
not matching *occurrences* — so two version keys colliding on one line (a minified manifest, a
one-line nested object) counted as **1** and walked straight past the guard. Verified directly:
`{"name":"x","version":"1.0.0","dep":{"version":"2.0.0"}}` → `grep -c` says 1, `grep -o | grep -c .`
says 2. The input still failed closed, but one check later and for the *wrong stated reason* —
`$v` came back holding both matches with an embedded newline and died on the X.Y.Z regex printing
`is not X.Y.Z` instead of `expected exactly 1 version field`. Fixed to `grep -o … | grep -c .`
(both drain to EOF, so neither can lose the SIGPIPE race described below).

The reason this is recorded rather than quietly patched: **R8 was green over the whole defect**,
because R8's fixture puts the two keys on separate lines — the one arrangement `grep -c` gets
right. This is the same shape as R6 staying green through the 2⁶³ wrap, and it generalizes: an
assertion written alongside the mechanism inherits the mechanism's blind spot. R8b now pins the
one-line arrangement, and it asserts on the *message* rather than the exit status, since the exit
status was never wrong.

**Round 3 then found a High in the guard the round-2 fix had just hardened — by a different
mechanism.** Under a UTF-8 locale (this machine and `ubuntu-latest` both default to one) GNU grep
will not match a negated bracket expression like `[^"]*` across a byte sequence that is not valid
UTF-8, and **silently drops the whole line** from `grep -o` output rather than erroring. A fork PR
author controls every byte of their own manifests, so: commit **two** `"version"` keys — a clean
forward decoy and a real one carrying invalid bytes. The poisoned key is invisible to the script;
`n` comes back 1, the ambiguity guard never fires, and the decoy validates as a normal forward
version. Every JSON parser takes the *poisoned* one, because duplicate keys are last-wins in V8,
Python and Go alike. Reproduced end to end before acting on it: base 0.9.0, head decoy 0.9.1 plus
poisoned 0.1.0 → `ok: version 0.9.1, not behind master`, exit 0, while `JSON.parse` read `0.1.0`.
A complete bypass of the one hazard this file exists to prevent, from a one-line hex edit.

Fixed with a script-wide `export LC_ALL=C`. Two things about that shape are deliberate:

- **`export`, not `local`.** A `local LC_ALL=C` is *not* passed to a spawned child unless the name
  was already exported — verified directly: `local` gives the child `<unset>`, a command prefix
  and `export` both give it `C`. So the `local` form works for a bash builtin like `[[ x < y ]]`
  and does nothing at all for `grep`. That is the worst available failure: it reads as the same
  pin and is not one.
- **One mechanism, not two.** `num_lt`'s own `local LC_ALL=C` was *removed* rather than left
  beside the export. Two mechanisms claiming one job is how the next reader trusts the wrong one,
  and here the redundant one is precisely the ineffective one.

**A correction worth recording, because it nearly inverted the fix.** The first attempt to verify
this finding appeared to *refute* it — `LC_ALL=C` changed nothing, suggesting the reviewer had
misattributed the cause and their fix was a non-fix. That measurement was wrong: `grep` at an
interactive prompt on this machine is a **shell function shimming to ugrep 7.5.0**, while a script
gets `/usr/bin/grep`, GNU grep 3.7. Shell functions are not inherited by a non-interactive child,
so the ad-hoc check and the script under test were running different programs with different
invalid-byte behaviour. Re-run against `/usr/bin/grep` the finding reproduced exactly. **Verifying
a claim about a tool means invoking the same binary the code invokes** — `type -a` and an explicit
absolute path, not whatever the prompt resolves.

**Round 4 found a High in the same guard again, by a third unrelated mechanism — and that is what
finally changed the approach rather than the code.** JSON `\uXXXX` escapes are legal in **key
names**, not only in values. A manifest carrying `"version":"0.9.1","version":"0.1.0"` has
exactly one literal `"version"` byte sequence in it, so the ambiguity guard counts 1 and passes,
while every JSON parser decodes two keys and takes the second by last-wins. Reproduced end to end
before acting on it: the check printed `ok: version 0.9.1, not behind master` and exited 0 while
`python3 -m json.tool` and `node` both read `0.1.0`. Same bypass as round 3, same one-line edit,
a mechanism the round-3 fix does not touch — `LC_ALL=C` is irrelevant to an escape sequence that
is pure ASCII.

**The fix is not a fourth patch. The textual reader was deleted and replaced with `python3`'s
stdlib `json`,** with `object_pairs_hook` refusing duplicate keys by name before they can collapse
last-wins, and a recursive walk that requires exactly one `version` field at any depth. Rounds 2,
3 and 4 each defeated the same reader by an unrelated route — line-counting, invalid UTF-8,
unicode escapes — and three independent evasions of one approach is not three bugs, it is the
approach being wrong. The class is **text tools do not parse JSON**; its members cannot be
enumerated, so enumerating them is not a strategy. The fourth patch would have been the third
demonstration that patching does not converge.

**Why a parser here, when this repo has twice declined "just use jq or python3".** Both declines
are still correct and neither one reaches this file:

- The **PyYAML** decline was `python3 -c 'import yaml'` — PyYAML is not in the standard library,
  so the better arm would have existed only on some machines. `json` *is* stdlib, on every
  python3 since 2.6.
- The **marker-splicing** decline was about `forgeward-write-marker.sh`, which runs on arbitrary
  user machines and whose supply-chain review had certified that it adds no external tool
  requirement. This script runs on `ubuntu-latest` in a workflow this branch also adds; it is
  never on the user's critical path, and nothing about it is certified tool-free.

The precedent's actual principle — *one arm everybody gets beats a better arm some people get* —
**argues for** a single python3 arm here, and it is why there is **no jq fallback and no second
reader**. Two readers of the same JSON that can disagree is not belt-and-braces; it is
`forgeward-diff-hash.sh`'s jq-vs-python3 divergence reproduced deliberately (see that entry
below). A box without python3 gets a named FAIL from an explicit preflight, never a quiet skip.

**A side effect worth stating, because the round-3 entry above is the warning for it.** The
parser is locale-independent, so `export LC_ALL=C` no longer defends anything it was added to
defend; the only surviving consumer is `num_lt`'s byte comparison, whose effect is unobservable
on this machine. The comment above it was **rewritten to say exactly that** rather than left
carrying its original justification. A line that reads as load-bearing for a reason that has
since expired is the precise failure round 3 recorded, one round after recording it.

**Verification.** `test/version-check-test.sh`, 51 assertions, wired into `npm test`. Of the
twenty-one mutations written through round 4, twenty
reddened exactly the assertions naming them and nothing else — including
every one added by the review rounds: reverting the counter to `grep -c` reddens R8b alone,
dropping the `export LC_ALL=C` reddened R15 alone while the textual reader still existed, and on
the parser, dropping duplicate-key detection reddens R16 alone, accepting any number of `version`
fields reddens R8 and R8b, dropping the python3 preflight reddens R18 alone, and letting an
unrecognized reader answer fall through as a pass reddens R18b alone. Ceasing to recurse into
nested objects reddens 13 — `marketplace.json`'s version is nested, so most of the suite depends
on the walk. The one that reddened *nothing* is the entry to carry forward, together with the
zero-comparison result:

- The zero-comparison floor (Decision 4) was unpinned until R12 was written for it. Mutation
  testing is what found that; reading did not.
- **The `LC_ALL=C` *collation* effect is still not pinned and cannot be**, on this machine: no
  locale here collates ASCII digits out of code-point order. What changed in round 3 is what
  that sentence is worth. The same variable also decided whether `grep` matched across invalid
  UTF-8 — an effect pinned hard by R15 for as long as the textual reader existed, and one the
  round-4 parser then made moot, since `json.load` is locale-independent and R15 now asserts the
  parser's own `not valid UTF-8` message. So collation is once again the *only* live effect of
  the pin, and it is once again unobservable. **The lesson is about the label, not the pin:**
  "unobservable, kept as hardening" was recorded at P4 and read as *this line barely matters*,
  when the line was in fact load-bearing for a reason nobody had enumerated. An unobservability
  disclosure is a statement about the effects that were *measured*, never about the guard — and
  round 4 is the proof that the statement expires: the same words are true again for a narrower
  reason, which is exactly how a stale justification survives a reading.

**Four mutations across this branch reported vacuous on their first pass and not one was a
coverage gap.** Three were **harness artifacts** — `M6` (dropping the base-ref resolve guard), the
`grep -c` revert, and `M19` (stopping the recursive walk) each failed to apply and reported a
clean suite; applied properly they redden R11, R8b and thirteen assertions respectively. Two of
those got through because the replacement silently matched nothing; `M19` was caught by an
`assert count == 1` added after the first two, which is now the harness's standing shape.

`M21` is the one worth keeping, because **it applied cleanly and was still a no-op**. It inserted
an `ok:*) v="0.0.1"` arm to make an unrecognized reader answer pass — but placed it *after* the
real `ok:*)` arm, and `case` takes the first match, so the mutant was unreachable code. An
anchor-count assert cannot see this: the edit is real, the semantics are not. Re-pointed at the
`*)` catch-all it reddens R18b exactly. So a vacuous mutation has two distinct causes — *did not
apply* and *applied but cannot execute* — and only the first is mechanically detectable. A
mutation reporting "nothing reddened" is a claim to verify, not a finding to accept; accepting
any of these four would have added a test for a guard that was already pinned.

The live direction was proven on this repo rather than only in fixtures: the three manifests
were edited 0.9.0 → 0.8.0 and the check named `package.json` and exited 1. The security
review's 2^64 repro was likewise re-run here after the fix, and now exits 1 naming the same
file.

**Round 5 is the mirror image of round 4, and the comment that should have prevented it was
already in the file.** Round 4 replaced the textual reader with a real parser and piped the
manifest in on **stdin** specifically so the bytes reached the parser unaltered — the comment
written at that line names both of the transforms a command substitution performs, and it is
correct. The **return** path was left as `out="$(python3 -c "$READ_VERSION_PY")"`, and it
performs both of them: `$(...)` **deletes NUL bytes** (a warning on stderr, exit status
untouched) and **strips trailing newlines**. Both are legal inside a JSON string. So the shape
check that ran on the bash side was validating a value the file did not contain.

Reproduced end to end: `{"name":"p","version":"1\u00009.0.0"}` committed on the head branch,
base `9.0.0`. `python3` and `node` both read `'1\x009.0.0'`; the check printed
`ok: version 19.0.0, not behind master (3 manifest(s) compared, all three agree)` and exited 0.
The NUL was deleted in transit and `19.0.0` sailed through `[[ =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]`
looking like a clean forward bump. A trailing newline does the same thing more quietly.

**The fix is round 4's fix applied to the other direction: close the channel, do not patch the
instance.** The `X.Y.Z` check now runs *inside* `READ_VERSION_PY`, so the only thing that ever
crosses the substitution is a string of digits and dots — which is by construction immune to
every transform `$(...)` performs. The bash-side regex is kept as belt-and-braces with a comment
saying it is not the authoritative check and why it cannot be, because the tempting edit is to
notice the duplication and delete the wrong one. The refusal message runs the offending value
through `json.dumps`, so it can *name* the value without shipping raw control bytes back through
the same channel that mangles them.

**`re.fullmatch`, not `re.match(...$)` — and this is the trap, not a style note.** In Python `$`
also matches just before a single trailing newline: `re.match(r'^[0-9]+\.[0-9]+\.[0-9]+$',
'1.0.0\n')` is a match, `re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', '1.0.0\n')` is not. Verified
directly. Writing the anchored form would have reimplemented one half of the exact bypass being
fixed, in the line fixing it.

The same round's Low was `RecursionError` escaping the `except ValueError` around `json.loads`
— it is not a `ValueError`. A deeply-nested manifest killed python with a bare traceback and
empty stdout, so the run refused via the generic catch-all arm: failed closed, wrong reason,
no usable message. Now caught by name.

**Knowing a hazard by name is not a guard against it.** That paragraph about `$(...)` was in the
file, accurate, one screen above the code doing the thing it warns about — and it read as
mitigation. It is now amended to say so explicitly, and blind spot 8 generalizes the rule: any
future field read out of a manifest crosses the same channel and needs the same treatment.

**Three self-inflicted errors from this round are worth more than the finding.**

- **The first probe harness had the bug it was measuring.** It built the fixture with
  `V="$(python3 -c ...)"`, which deleted the NUL and stripped the newlines before writing the
  file — and reported the bug absent. A measurement apparatus that shares the mechanism under
  test returns a clean result for the same reason the code does. The fixtures now pass a python
  *expression* through `argv` and never let a shell touch the value.
- **Raw NUL bytes then landed in the source while documenting the NUL bug**, repeatedly, in
  three separate files. GNU grep answers `binary file matches` instead of matching lines; this
  machine's interactive `grep` shims to **ugrep**, which returns *nothing at all*,
  indistinguishable from "no matches". That is why an earlier grep of the test file came back
  empty and produced a wrong conclusion about its contents. **R21 asserts the files are NUL-free
  and valid UTF-8**, because the failure is silent in both tools and git treats the file as
  binary from that point on.

  **R21 had to be widened twice before it was pointed at the right thing, and the two failures
  are the interesting part.** Version one listed the two code files this round touched; the next
  NUL landed in `DECISIONS.md` — in the paragraph above, explaining the hazard — while R21 sat
  green. Version two named five files; the one after *that* went into `TODOS.md`, in a sentence
  saying to never write the byte literally. Enumerating the files that have already been bitten
  is not a strategy when the trigger is *someone is writing about control bytes* and any file
  can be that file. R21 is now repo-wide over `git ls-files`, which costs nothing here: 41
  tracked files, no legitimately-binary member, no exceptions to maintain.

  It is **two** assertions, and the second one is the reason to copy this shape. A sweep that
  enumerates nothing reports "0 files checked, 0 problems" and passes — the exact green-for-no-
  reason failure this branch spent five rounds on — so the enumeration is asserted separately,
  with a count floor and a named-member check, before its result is trusted. Both directions
  were checked by hand: splicing a NUL into `README.md` (a file no version of R21 ever named)
  reddens the sweep and names the file; breaking the enumeration reddens the liveness assertion
  and leaves the sweep green, which is precisely the pair that tells the two apart.
- **`local name="$1" expr="$2" r="$TMP/$name"` does not do what it reads like.** Bash creates
  every name in the statement before assigning any, so the `$name` on the right resolves to the
  **global** — empty here (and `unbound variable` under `set -u`, which is how it surfaced), but
  silently the global's *value* when one exists, which is the worse of the two outcomes. Split
  into separate `local` statements with the reason recorded at the line.

**And two of the round-5 mutations reddened nothing because the assertions were genuinely
blind — the first instances on this branch of the third cause.** Rounds 1–4 produced four
vacuous mutations and none was a coverage gap; round 5's `M23` and `M25` both were. `M23`
(`fullmatch` → anchored `match`) survived because R19b used *three* trailing newlines, and
Python's `$` only matches before a **single** final one — the assertion could not discriminate
the two forms, and the comment claiming it did was false. `M25` (stop escaping the offending
value) survived because the assertion read only `is not X.Y.Z` and never looked at whether the
message named `19.0.0` for a file containing `1\u00009.0.0`. Both were written minutes after the
fix, by the person who wrote the fix, which is this file's own recorded principle — *an
assertion written alongside a mechanism inherits that mechanism's blind spot* — landing on the
round-5 work itself. R19b now uses one newline, R19b2 covers three, R19e pins the escaped value.

A fifth harness error is the reason to keep reading assertion *output*, not exit status: five new
assertions were written as `out="$(run "$R" master 2>&1)"; st=$?` when `run()` *sets* `$out`/`$st`
rather than printing. All five measured an empty string and a zero status. R19d — the positive
control, asserting a clean version still passes — would have been **vacuously green** under an
exit-status-only check, and it was the message assertion that caught it.

Round 5 verification: all four new mutations redden exactly the assertions naming them
(`M22`→R7/R19/R19b/R19b2/R19e/R19c, `M23`→R19b, `M24`→R20, `M25`→R19e), and every earlier
round's proof-of-concept still fails closed.

**Round 6 found a Critical, and it is the one that got closest to shipping: the repo under
test was configuring the interpreter judging it.** `python3 -c` sets `sys.path[0]` to `''`,
which resolves to the current working directory — and this script runs from the root of the
checkout it is auditing. So `import json` was resolved against **repo content**. A fork PR
author commits a five-line `json.py` at the repo root beside a genuine backward bump, and
`json.loads` returns whatever they like. Reproduced end to end: base `9.0.0`, head manifests
genuinely `1.0.0` — a drastic backward move, the exact hazard this file exists to stop — output
`ok: version 999.999.999, not behind master (3 manifest(s) compared, all three agree)`, exit 0.
Every guard added in rounds 1–5 was intact and irrelevant: the forged value is a well-formed
`X.Y.Z` string, so the bash-side regex, the duplicate-key hook, the `fullmatch` and the
NUL-proof channel all pass it through. Rounds 2–5 hardened *how the manifest is parsed*; this
one substituted *the parser*.

**The fix is `python3 -I`, and the choice of `-I` over a `sys.path` edit is the whole lesson of
the previous four rounds applied in advance.** The CWD entry is one of four channels by which
the audited repo configures the interpreter — `sys.path[0]`, `PYTHONPATH`, the other `PYTHON*`
variables, and user site-packages (which also carries `usercustomize`). Patching `sys.path[0]`
inside `READ_VERSION_PY` would have closed exactly one and left the neighbours, which is the
shape of every round from 2 to 5: fix the instance, get defeated by a sibling mechanism next
round. `-I` closes the set in one token — it drops the CWD/script-dir entry and implies `-E`
and `-s` — and it has been available since Python 3.4. All three reachable channels were
verified closed against the live fixture, and R22/R22b/R22c pin one each so that "the flag is
still there" is observable rather than assumed. A python too old for `-I` fails closed with the
interpreter's own error plus `returned no usable answer` — verified, not assumed.

**Blind spot 6 was not merely incomplete, it was false, and that is the more useful finding.**
It read "reads the manifests with the stdlib `json` module" — an assumption stated as a
property, when nothing in the code established it. It now says the claim has to be earned and
that `-I` is what earns it. A disclosed limit is fine; a disclosed limit that quietly asserts a
guarantee the code does not provide is worse than no comment, because it answers the question a
reader would otherwise go and check.

**Blind spot 9 is new and is the honest boundary.** Under `pull_request`, this script and its
workflow are both read from the PR head, so an author who wants the check gone can edit the
check. That is inherent to any repo-content-driven required check; the mitigations are branch
protection on workflow files and a human reading the diff. It does **not** make the round-6 fix
moot, which is the tempting conclusion: editing the checker is conspicuous in a diff and a
stray `json.py` at the repo root is not. The fix's value is that it forces the attack into the
reviewable direction.

Round 6 verification: 39 assertions. Reverting `-I` reddens R22, R22b, R22c and R22d — the
first three by channel, the fourth because with the flag gone the planted module forges the
*forward* case too, which is the positive control doing its job from the other side. The
preference for `-I` over the narrower fix is measured rather than argued: mutating `-I` into
`sys.path.pop(0)` and nothing else (`M27`) reddens **R22c alone** — the CWD channel closes and
`PYTHONPATH` stays open. That is the round-2-to-5 failure mode caught in advance, on a stopwatch.

**Round 7 found a High one layer out again, and it was visible in this file's own header the
whole time.** The head side read each manifest off the filesystem — `[ -f "$f" ]`, then
`read_version "$f" < "$f"` — while the base side read it out of the object store with
`git show`. A `<` redirect is a plain `open(2)`, and `open(2)` follows symlinks; git tracks
symlinks natively as mode `120000`. So a fork PR author commits `package.json` as a link to any
absolute path on the runner and the check parses a file that is not in the commit. Reproduced:
all three manifests committed as symlinks to a file outside the checkout, base at `9.0.0`, and
the check printed `ok: version 13.37.0, not behind master (3 manifest(s) compared, all three
agree)` and exited 0 — a **PASS asserted about a commit that contains no version field at all**,
on the strength of a file that is not in the repository and never will be. Pointed at any
JSON-shaped file that merely exists on the runner, it also reflects a fragment of it into a
world-readable job log.

The asymmetry was described in this file and in the script's header — "reads base-side manifests
via `git show`, head-side from the worktree" — as a neutral implementation detail. It was the
bug, written down. `git show` returns a symlink's **blob**, the literal target string, and never
dereferences it, so the base side was never exposed; only the filesystem answers questions about
things outside the repository. Both sides now go through one `require_blob` helper and one
object-store read, so "the file in the commit" and "the bytes we parsed" are the same object by
construction. The explicit mode check on top is not redundant: a symlink's target text fails the
JSON parse anyway, so without it the refusal arrives one step later as `could not read a version`
— blaming the parser for something the tree entry decided, which sends the next reader to the
wrong layer. That is also why R23's assertions read the **message**: pre-fix, the in-repo variant
exited non-zero too, and an exit-status assertion could not tell the fix from the accident.

**Reading HEAD is the more correct question, not merely the safer one.** What merges is the
commit, and the workflow checks out `pull_request.head.sha` precisely so HEAD *is* the thing under
review. The cost is real and is paid explicitly: a hand-run no longer sees uncommitted edits, so
the check now prints a stderr note naming the manifests it ignored. It is a note, never a verdict
— the answer about the commit is right either way — and R24b pins it, because six rounds of
comments describing behaviour the code did not have is the failure mode this repo actually has.
Blind spot 10 states it. A side effect worth keeping: with `--full-tree` and a `:/` pathspec the
whole check is repo-root-relative and now works from a subdirectory, which the cwd-relative
worktree read did not (R24c).

Round 7 verification: 47 assertions; gate 171/171 and pre-push 15/15 re-run green. Seven mutations
redden exactly what names them — restoring the worktree read reddens R23/R23b/R23c/R24/R24c,
deleting the symlink arm or folding `120000` into the accepted modes reddens all four R23 symlink
cases, reverting the base side to `cat-file -e` reddens R23d alone, inverting the dirty-note
condition reddens R24b (plus three assertions that then see a spurious note — an artifact of the
mutant printing when clean, not extra coverage), dropping `--full-tree` reddens R24c alone, and
round 6's `-I` regression check still reddens R22–R22d.

**Round 8 returned PASS, and the two things it produced are worth more than a seventh defect
would have been.** The reviewer tried five distinct ways to get past round 7's fix — a
non-canonical tree mode, a clean/smudge filter divergence, `core.symlinks=false`, replace-refs,
and ref-name injection through `github.base_ref` — and each failed closed for the reason the code
claims. That is the first round where the comments were checked against the machine and survived.

The Low it did find was a one-line channel slip: the base-side "manifest absent" note printed to
**stdout** while its sibling printed to stderr, so "read the last stdout line as the verdict" was
true by accident rather than by rule. Not exploitable — CI gates on the exit status — and it is
recorded here for the reason it was invisible: `run()` folds the streams, so all 47 assertions
stayed green either way. A one-line slip that no assertion can see is the same shape as the six
defects the suite missed, in miniature, which is why the fix came with **R25** rather than alone.

The second thing is a case the reviewer reported as *safe* and which turned out to be a second
bypass in the pre-round-7 code: `.claude-plugin` committed as a symlink to an external directory,
with ordinary manifests on the far side. The object-store read closes it for a **different**
reason than R23 does — once the parent is not a tree, no entry exists at that path at all — so a
future optimisation that stats the worktree to skip work would reopen it while every R23
assertion stayed green. Verified the worktree genuinely resolves the link before asserting, so
the fixture cannot pass by failing to set the case up. Pinned as **R23f**, and mutation `M37`
(exactly that optimisation) reddens it.

Round 8 verification: 51 assertions; gate 171/171 and pre-push 15/15 re-run green. Four more
mutations redden exactly what names them — either note moved to the wrong stream reddens the R25
pair that owns it, statting the worktree reddens R23/R23b/R23c/R23f/R24c, and letting
`require_blob` accept an absent path reddens R9/R12/R23f/R25/R25b.

**Round 9 re-fired because the round-8 PASS was on a tree that no longer existed.** Two commits
had landed since, and a marker written against an artifact the reviewer never saw is exactly the
false PASS this whole apparatus is for. It returned PASS with no findings, and it did two things
worth keeping. It traced every stdout-writing statement rather than sampling: on any exit-0 path
the only write to the script's real stdout is the final summary, everything else is stderr or is
captured inside a substitution. And it verified the invariant on a combination no assertion
covers — base missing *two* manifests plus a dirty worktree, three notes firing at once — with
`od -c` and `wc -l` rather than a pattern match.

Its one informational nit is filed rather than fixed, and the reasoning is recorded because the
instinct to fix it is strong: `run_split` reads its captured streams back with `$(cat …)`, the
same lossy channel rounds 5 and 6 hardened the production script against. The reviewer could not
construct a false pass and neither could I — the verdict payload is `^[0-9]+\.[0-9]+\.[0-9]+$`
by the time it is printed, and the note text is built from the hardcoded `$MANIFESTS` literals,
`$BASE` and an integer. So it is a posture inconsistency in a test harness, not a defect. The
reason to leave it is that changing it re-invalidates the PASS and buys nothing; the reason to
write it down is that "no live input can reach it" is a property of today's message strings, and
the next person to interpolate something richer into a note needs to find this paragraph rather
than rediscover rounds 5 and 6.

## RESOLVED — two documented config keys were parsed by nothing, and 0.8.0 made that worse

**Date:** 2026-08-06 · **Version:** 0.9.0

**Symptom.** A repo pins `seo.posture: private-shareable` in `.forgeward/config.yml`, exactly
as `skills/gate/SKILL.md` and `agents/seo-reviewer.md` describe. Nothing reads it. The gate
classifies by detection and never says the pin was ignored. Separately, a user who writes
`substitutes: [quality]` or `- "quality"` — both ordinary, valid YAML — keeps getting the
`NOT COVERED` disclosure they thought they had silenced, with nothing anywhere explaining why.

**Why this got worse before it got better.** The config file was pure prose until 0.8.0: three
keys documented, zero parsed, uniformly. 0.8.0 gave it its first reader — for
`standalone.substitutes` only — and a file where *one* key genuinely works is a stronger claim
that the others do than a file where none do. The gap was the same size and much better hidden.

**Decision 1 — extend the single awk reader; do NOT add a python3 YAML arm.** The obvious fix,
and the one this repo's own TODOS proposed, was `yaml` when python3 is present with awk as the
fallback, copying the jq/python3 two-arm pattern in the hooks. Declined on a fact that proposal
assumed away: **PyYAML is not in the standard library** (verified — no `yaml` in
`sys.stdlib_module_names`), so `python3` being installed says nothing about `import yaml`
succeeding. Arm selection would then turn on whether a third-party package happens to be
present, and the two arms would parse *different shapes* — which is precisely the divergence
0.7.5 shipped between `jq` and `python3` and V7 now exists to catch. One arm everybody gets
beats a better arm some people get. Flow sequences and simply-quoted scalars were added to the
awk instead: both funnel through the same charset, 64-char and 32-item validation, so the
security envelope is unchanged and the caps are shared rather than per-spelling (E25).

Verified across `gawk`, `mawk` and `busybox awk` rather than reasoned about, following A17.
The apostrophe is passed in as `awk -v sq="'"` — writing it inside the single-quoted program
would end the quote, and the usual workaround `"\047"` leans on octal string escapes not every
awk implements.

**Decision 2 — wire `seo.posture`, and state plainly that `seo.routes` is not honoured.** The
posture is a bare scalar from a six-value enum: cheap to read, and validated by whole-string
comparison rather than a charset so an unrecognised value reads as *not pinned* and returns the
reviewer to detection, instead of reaching a reviewer that has no ruleset for it. `seo.routes`
is a mapping with glob keys, documented in flow style; parsing it means the YAML parser
Decision 1 just declined. It is now called out as unread in all three places it appears —
README, skill, agent — because the failure mode of the alternative is the one this whole entry
is about: a pin that looks honoured and is not. A partially-honoured key is worse than an
openly unhonoured one.

**Decision 3 — the probe's two config values ride one line separated by `|`, and awk's exit
status is not trusted alone.** The END block always prints the separator, so output without one
means something other than this program produced it; that reads `unreadable` (disclose), never
present-with-an-empty-list. Same "it ran" vs "it worked" distinction that cost 0.7.3 and 0.7.6,
pinned by E27 with a shimmed awk that exits 0 and prints nothing usable. Neither value can carry
a `|` — the substitute charset excludes it, the posture is enum-compared — so config content
cannot shift the split (E24).

**Marker: schema 4.** `_env_ok` in `forgeward-write-marker.sh` gained the `seo_posture` field in
the same commit, which is the standing obligation that coupling creates. It is matched there as
a CHARSET (`[a-z-]*`), not as the six-value enum, and the asymmetry with the fields above it is
deliberate: the enum is enforced at the source, and a second copy here would drift while buying
no additional structural constraint, since `[a-z-]` already excludes every character a
duplicate-key splice needs.

**The trap this sprung, worth more than the feature.** E17 pins that the marker's shape match is
anchored at *both* ends, by feeding it the probe's genuine output plus an appendix. Adding a
field to the probe silently invalidates its hardcoded prefix — the payload then fails on the
prefix instead, and dropping the trailing `$` no longer turns it red. Verified in both
directions: with the field added to E17's string, dropping `$` reddens E17; with the stale
string, the whole suite stays green. That is what made a probe field a **three**-file edit
whose third leg reddened nothing at all. **Superseded at 0.13.1**, which deleted the hand-copy
rather than restating the warning: E17 derives its prefix from the live probe, so it cannot go
stale and the edit is two files again. See the RESOLVED entry at the top of this file.

**Not fixed, stated so the limit is not mistaken for coverage.** Nothing validates the config or
warns on unknown keys, so a typo'd `substitutes:` or an invalid posture is indistinguishable
from an absent one — both read as "not configured", which is the fail-open direction but still a
silent one. `seo.routes` remains unread. An unterminated flow sequence (`[a, b`) reads as nothing
configured rather than as an error. All three are in `TODOS.md`.
*(Superseded 0.13.0 — the silence is closed by `config_warnings`, which counts all three; the
dropping itself is unchanged and `seo.routes` is still unread by design. See the top entry.)*

Suites: gate 171/171, pre-push 15/15. Eight mutations run against the new assertions (flow rule
disabled, `unquote` neutered, posture rule disabled, enum → charset, `|` allowed into the
charset, `_env_ok` anchor dropped, CRLF-tolerant strip tightened, output shape check removed);
each reddens exactly the assertions that name it and nothing else.

## RESOLVED — the gate reported a handoff it never performed when gstack was absent

**Date:** 2026-08-06 · **Version:** 0.8.0

**Symptom.** On a machine with no gstack, a passing `/forgeward:gate` ended with
`forgeward gate: PASS (fired: …). Marker written. Handing off to /ship.` — and nothing shipped.
No error, no warning, no push. The user's work sat uncommitted behind a success message.

**What it was, and why the prediction about it was wrong.** `skills/gate/SKILL.md` Step 3
invoked gstack's `ship` skill unconditionally. `docs/axis-proposals.md` had flagged this as
"untested — likely-broken", guessing it would hard-fail without gstack. It did not, and the
reality is worse in the way that matters:

- The marker is written **before** the handoff. So the gate's actual product — the review and
  the receipt — was never at risk, and the user was never blocked. A hard failure would have
  been *visible*, and would have cost only a retry.
- What actually broke is the **report**. The gate asserted an action it had not taken. A gate
  that hard-fails tells you something is wrong; a gate that lies tells you everything is fine.
  This is the same class as the fail-open error paths of 0.7.4–0.7.6: the failure returns the
  same surface as success, so nothing distinguishes them from outside.

**Fix.** Step 3 branches on `gstack_ship` from the new environment probe. Present → hand off as
before. Absent → do not attempt the Skill call, and report that `/ship` is not installed and the
marker is already in place, so a manual push will be allowed. The handoff is stated as a
convenience rather than part of the gate, because it is: the review and the marker are both
complete before that branch is reached, so a missing `/ship` costs two commands, never a
re-review.

**The wider decision: DISCLOSE, do not refuse (Option B, `docs/axis-proposals.md` §3).**
forgeward's reviewer table is scoped as a *delta against gstack*, so every deferral becomes a
hole the moment the other side is absent. One had already shipped that way (`supply-chain-reviewer`
deferring CVEs to a `/cso` that need not exist, fixed earlier). Rather than keep patching
instances, 0.8.0 makes the environment a first-class input:

- `scripts/forgeward-detect-environment.sh` probes `ship`/`review`/`cso` and reads an optional
  `standalone.substitutes` list from `.forgeward/config.yml`.
- Gate Step 1c names any axis whose owner is absent (`quality`, `deep-audit`) in the firing
  decision, then **gates normally**. It never FAILs, never withholds the marker, and never
  re-fires a reviewer to compensate — a security reviewer asked to also judge quality does
  neither job well.
- The marker records the environment (schema 3), so a PASS is auditable after the fact.

**Three deliberate asymmetries, each the opposite of a neighbouring script's posture.**

- **The probe fails OPEN (noisy), while `forgeward-detect-gstack-skill.sh` fails CLOSED.** That
  script's answer drives a *skip*, so a false "installed" silently drops a check. This one's
  answer drives a *sentence*, so being wrong costs a redundant paragraph while the other
  direction hides a real gap. Unreadable config, missing config and parse trouble all resolve
  to "disclose".
- **The probe always exits 0.** It is informational. A gate run must never be blocked because
  an *optional* partner tool could not be probed.
- **A broken probe never costs a marker.** Any unexpected output degrades to
  `"environment": {"probe":"unavailable"}` and the marker is written anyway. Losing a marker
  forces a full re-review; losing provenance costs one unanswerable question later.

**Two limits, stated so they are not mistaken for coverage.**

- **Presence, not diligence.** The probe sees that a skill is *installed*. gstack installed and
  never run is indistinguishable from gstack actively covering the axis, so the disclosure says
  "the tool is here", never "the axis was reviewed".
- **`.forgeward/config.yml` gets a reader, not a YAML parser.** It handles exactly one shape —
  a two-space block sequence under `standalone.substitutes`. Flow sequences (`[a, b]`), quoted
  scalars, anchors, aliases and tabs all read as "no substitutes named", which disclose-by-default
  turns into a redundant paragraph rather than a hidden gap. The file was pure prose before this
  (documented in two agent files, parsed by nothing); this is its first parser, and it is
  deliberately narrow rather than the beginning of a YAML dependency.

  *Superseded by 0.9.0, which kept the reader-not-a-parser posture but widened the shapes
  (flow sequences and simply-quoted scalars now parse) and added `seo.posture`. The marker is
  schema 4 from that version. See the entry above; this paragraph records 0.8.0 as shipped.*

**Also corrected here — three places the repo already described behaviour it did not have,**
which is how the gap survived this long:
- `live-test/LIVE-TEST.md` told a tester the gate "tells you it would" hand off with no gstack.
  It did not. That branch now exists, and the line describes what actually happens.
- `docs/axis-proposals.md` said "forgeward refuses the `/ship` handoff", conflating **this repo's
  own dev workflow** (declined because `/ship` would re-bump a version living in three manifests)
  with **plugin behaviour** (which hands off, and now degrades). Disambiguated in place.
- `scripts/forgeward-gate-check.sh`'s `/ship` halt message promised the gate "ships in one
  motion" — true only on the gstack branch. Reworded to hold either way rather than probing,
  because that is the halt path and it must stay fast and dependency-free.

**Note the `schema` field is provenance, not enforcement.** It is written by
`forgeward-write-marker.sh` and read by nothing in the repo — no freshness check consults it, no
push is refused over it. Bumping 2 → 3 is therefore free, and must not be mistaken for a
compatibility mechanism. The same is true of the `environment` object beside it.

**Evidence.** E1–E18 in `test/gate-test.sh`, each mutation-tested. E2 exists specifically as
E1's positive control: gstack is installed on the author's machine, and
`forgeward-detect-environment.sh` is not a PATH lookup, so the suite's PATH-shim helpers do
nothing to it — an assertion that forgets any of its three roots (`$CLAUDE_CONFIG_DIR/skills`,
`<git toplevel>/.claude/skills`, `$CLAUDE_CONFIG_DIR/plugins/cache/*/*/skills`) finds the real
gstack and passes vacuously. E5 pins that a substitute name carrying JSON metacharacters is
*dropped* rather than escaped, since that value is the only marker field originating in a repo
file. Suites: gate 162/162, pre-push 15/15.

*Corrected at 0.18.0 — the third root above is quoted as it stood in 0.8.0, and as written it
matched **nothing**. The installed plugin layout carries a version level
(`plugins/cache/<marketplace>/<plugin>/<version>/skills`), so that glob was one directory short
and had never fired on any machine. E2's vacuity risk was therefore carried by the first two
roots alone, and this sentence claimed a third that could not have contributed to it. The glob
is fixed in `forgeward-detect-gstack-skill.sh` and pinned by D8b in `test/gate-test.sh`. The
sentence is annotated rather than rewritten because what it says about controls that pass
vacuously is precisely the defect that kept this one invisible for ten versions — the
enumeration was itself the thing it warns about.*

**Two findings from the 0.8.0 security review, both Medium, both fixed here.** Worth recording
because each is an instance of a rule this repo already had and each got past a green suite —
E1–E11 were all passing when both were found, so "the tests pass" was never evidence about them.

- **A committed symlink at `.forgeward/config.yml` was followed.** `[ -f ]` and `[ -r ]` both
  follow links, so a repo could commit the config as a git symlink (mode 120000) aimed at any
  file readable by whoever checks the branch out and runs the gate; the reviewer demonstrated
  end-to-end that its value was carried into the pass marker. Impact was bounded — the marker is
  local, never committed, and nothing transmits it — but the file-existence oracle was real, and
  awk would scan a file of any size. Fixed by **refusing** links rather than resolving them, plus
  a 64KB size cap and per-item caps of 64 characters and 32 entries. Refusal because this key only
  *silences a disclosure*, so declining to read a config costs one redundant paragraph — the same
  fail-open direction as the rest of the script — while containment would need `readlink -f`,
  which is not portable to the bash 3.2 environments this repo still targets. **This knowingly
  breaks the monorepo that legitimately symlinks its config to a shared file**; such a repo must
  use a regular file, and reads as `unreadable` rather than silently empty so the disclosure fires.
- **A character allowlist was mistaken for structural validation — including in my own comment.**
  `forgeward-write-marker.sh` accepted any probe output that began `{`, ended `}`, and drew only
  from the character set the probe uses, and the comment above it claimed the marker was validated
  for "two independent reasons". A charset constrains *bytes*, not *structure*:
  `{"a":"b"},"diff_hash":"FORGED","passed":false,"z":{}` satisfies every one of those conditions
  and splices **duplicate top-level keys** into a syntactically valid marker, where jq and python3
  alike resolve last-value-wins — so the forged pair is what `is_fresh()` reads. Replaced with a
  match against the probe's complete literal output shape, anchored at both ends, each field drawn
  from its own closed vocabulary. Duplicate-key splicing is now unrepresentable.

  **The reviewer's suggested fix — parse it with jq or python3 — was declined.** The
  supply-chain reviewer had just certified that this diff adds no external tool requirement, and
  the marker is the artifact that authorizes a push, so its write path should have the fewest
  possible ways to fail. An anchored shape match needs no parser and is strictly *stronger* than
  a generic "is this an object" test, which would still accept `{"passed":false}`. **The cost is
  real and is a maintenance obligation, recorded in `TODOS.md`:** the two scripts are now coupled,
  and any new field in the probe's output must be added to the marker's check in the same commit
  or provenance silently degrades to `probe: unavailable`. That failure is safe (provenance is
  lost, enforcement is not) and E10 turns red on it, which is what keeps it from being silent.

  E16 is the reviewer's proof-of-concept verbatim. E17 pins the same attack from the other end —
  a payload that *opens* with genuine, fully-conformant probe output and appends the forgery,
  which survives any check anchored only at the start. Confirmed by mutation: deleting the single
  trailing `$` from the regex reds E17 and nothing else, and is invisible to E16. E17's prefix
  was a hand-copied literal until 0.13.1 and is now derived from the live probe, which is what
  keeps that mutation detectable after a field is added; E10 remains the assertion that reddens
  in the opposite direction, when `_env_ok` is what fell behind.

## RESOLVED — the error-path class was fixed one branch at a time, so the fixes cancelled each other out

**Date:** 2026-08-06 · **Version:** 0.7.6

**Symptom.** Three separate defects, all the same shape, all still live after two rounds of
fixing that shape:

1. A `git push` on a branch with a valid, fresh PASS marker was refused on every attempt, on a
   box where `jq` is installed but broken. Not intermittent — permanent, and unfixable from the
   user's side short of repairing jq, because the python3 fallback sitting next to it was
   unreachable.
2. `pre-push.sh`'s `marker_get` still used `print()`, so on Windows the marker's `base` came back
   with a trailing CR, failed to resolve as a ref, and a fresh marker read as stale.
3. **A hook payload that is not valid JSON, carrying a real publish verb, was ALLOWED** — with
   jq present and with jq absent. Measured on both paths (`test/gate-test.sh` A20).

**Cause — one class, four instances, two of which were "already fixed".** The class is *an error
path that returns the same value as a legitimate empty result*, so the caller cannot tell
"the helper failed" from "there is nothing there". `json_get` (0.7.3) and `strip_quoted` (0.7.3)
were fixed for it. `marker_get` was not, in either copy.

The third symptom is the one worth remembering, because it shows how a fix can be *undone by the
code it delegates to*. 0.7.3 made `json_get`'s **jq** arm check its exit status and fall through
to python3 — correct, and pinned by A13/A14. But python3's arm wrapped `json.load` and the field
traversal in a single `except Exception: pass`, which returns empty with status 0. So on malformed
input the sequence was: jq exits non-zero → the new fall-through fires exactly as designed →
python3 swallows the parse error → empty command → pre-filter sees no verb → `exit 0`. The
fall-through delivered control to a branch with the same bug, and the tests that pinned the jq arm
could not see it, because with a broken jq **and** no marker the hook denies for an unrelated reason.

**Why it survived two rounds.** `marker_get` fails CLOSED (an unreadable marker reads as ungated),
so it was deliberately left alone at 0.7.3 rather than widen a security-relevant diff. That
reasoning was sound and the conclusion was still wrong twice over: fail-closed here means *every
push refused*, which is not "safe", it is a hook that has stopped enforcing anything and started
blocking everything; and the same reasoning did not transfer to `json_get`'s python arm, which
fails OPEN. "It errs safe" answers whether to hurry, not whether to fix.

**Decision.**
- `marker_get` captures jq's output, checks its status, and falls through to python3 on failure —
  in **both** `gate-check.sh` and `pre-push.sh`, byte-identical. It cannot open the gate: python3
  parses the same file, so a malformed marker fails both arms and still reads as ungated.
- `json_get`'s python arm splits the parse from the traversal. Parse failure exits 1; an absent
  field still exits 0 with empty stdout, because that is a legitimate answer.
- On unreadable input the PreToolUse hook decides from the **raw bytes**: if they contain a publish
  verb it denies, otherwise it allows. Scoped that way on purpose — this hook fires on every Bash
  tool call, so denying outright on an unreadable payload would wedge the whole session the moment
  the JSON tool broke. Same fallback A7 already uses when awk is missing.
- The **expansion** path halts unconditionally on unreadable input, with no raw-text narrowing. The
  asymmetry is deliberate: an empty `cwd` means no `cd` happened, so `is_fresh()` would answer for
  whatever directory the hook process inherited, and a fresh marker in an unrelated repo would let
  the `/ship` through. That path runs only on a typed `/ship`, so a false halt costs one retry —
  the reason the pretooluse path cannot afford the same rule. Raised as an informational note by
  the security review of this branch ("`_unreadable` is computed but unused in expansion mode");
  it is closed here rather than commented, because the unused flag was the visible half of a real
  fail-open.

**Accepted cost.** A mangled payload that merely MENTIONS a publish verb now costs a retry. It buys
back a silent fail-open, and it can only occur in a state where the hook's input is already corrupt.

**The structural fix, and the one that matters most.** A19 asserts the two `marker_get` bodies are
byte-identical. The scripts duplicate the helper deliberately — separate entry points, no shared
library, one less file a hook can fail to find — and the cost of that choice is drift. Drift is
what happened: the 0.7.3 byte-writing fix landed next door and `DECISIONS.md` recorded it as done,
so for three releases the repo's own record described the intent rather than the state. That
paragraph is now corrected in place. A test is the only thing that keeps a deliberate duplicate
honest; a note in a decisions file is not.

**Blind spot, stated so it is not mistaken for coverage.** The `print()` → `sys.stdout.buffer.write`
half of the `pre-push.sh` fix is **not observable on POSIX**: `print()` appends `\n` and `$( )`
strips it, so both forms produce identical bytes here. It only diverges on Windows, where Python
translates that `\n` to `\r\n` in text mode. Faking a CRLF stdout would test the fake. What catches
it instead is A19's byte-parity assertion — indirectly, and only for as long as the twin stays
correct.

## RESOLVED — the same manifest hashed differently under `jq` than under the `python3` fallback

**Date:** 2026-08-06

**Symptom.** A marker written on a machine with `jq` read as STALE on a machine without it,
and vice versa, forcing a spurious re-gate on a branch nobody had touched. Fail-safe — an
extra gate run, never a false PASS — which is why it survived: the cost was a slow gate, not
a wrong one, and it only reproduces when the same branch is gated from two machines.

**Cause.** `normalize_manifest` has two branches that must emit the same BYTES, because what
the marker records is a hash. `jq -S` pretty-prints with a 2-space indent; the python3 branch
used `json.dumps(..., separators=(",",":"))`, which is compact. Same semantics, different
bytes, for every manifest in every repo. A second divergence sat behind it: without `-a`, jq
emits raw UTF-8 where `json.dumps` defaults to `ensure_ascii=True`, so a single accented
character in a manifest diverged even after the whitespace was matched.

**Why the tests did not catch it.** V5 and V6 pin that the fallback has the same semantics —
invariant under a version bump, still sensitive to a substantive change — and both passed
throughout. Each compared a branch only against ITSELF. Nothing compared the two branches to
each other, which is the only shape that sees it. Confirmed by mutation: reverting the fix
turns V7 red while V5 and V6 stay green.

**Fix.** `jq -S -c -a` on both invocations. Verified by fuzzing the two branches against each
other over compact/pretty shapes, empty containers, nested sort order, escapes, and unicode
including an astral surrogate pair — not reasoned about from the flag documentation.

**Accepted cost, stated because it is the expensive half.** Aligning the two rewrites the
canonical bytes, so EVERY marker in EVERY repo reads stale exactly once at this version — not
only plugin repos, which is what the previous change cost. That is why this shipped alone.
V4 previously asserted "existing markers survive the upgrade"; that guarantee is deliberately
given up, and the test was reframed to pin the payload assembly and current canonicalization
rather than have its expected value quietly updated.

**Blind spot — number literals still diverge, and cannot be closed here.** `jq` preserves a
number's source text (`1.10` stays `1.10`, `1e10` prints `1E+10`); python normalizes through
float (`1.1`, `10000000000.0`, `1e-7` → `1e-07`). Python cannot be made to match:
`json.dumps` calls `float.__repr__` directly, so a float subclass carrying the raw text is
ignored, and `parse_int` would turn `5` into `5.0`. Reaching it needs a manifest with a float
in scientific notation or with a trailing zero; npm and plugin manifests carry versions as
strings. Pinned by V8 as a KNOWN divergence, so a future jq or python that closes it fails
the suite instead of quietly outdating this paragraph.

## RESOLVED — `supply-chain-reviewer` deferred dependency CVEs to a `/cso` that need not exist

**Date:** 2026-08-05

**Symptom.** On a machine with no gstack installed, `supply-chain-reviewer` returned
`SUPPLY-CHAIN VERDICT: PASS` on a diff adding dependencies without anything having checked those
dependencies for known vulnerabilities. Found by reading, not by a report — which matters, because
the failure is invisible from the outside: the reviewer fires, produces a clean report on the two
classes it does own, and passes. There is no error and nothing missing from the output.

**Cause.** The agent carried an unconditional instruction: *"gstack's `/cso` Phase 3 already covers
dependency CVEs, install-scripts, and lockfile integrity — do NOT re-do those. You own
typosquatting/hallucination and licensing only."* forgeward is scoped as a delta against gstack —
the README reviewer table's third column is literally "why it's here (not redundant with gstack)" —
and scoping by delta means **every deferral becomes a hole when the other side is absent.** The
instruction was correct on the maintainer's machine and on no machine without gstack, which is the
entire installed base this plugin does not see.

**Relationship to the 2026-07-13 entry below.** That one reversed "delegate security to `/cso`"
because `/cso` is opt-in and manual and *was not run*. This is the same family and a rung lower:
that deferral assumed the user would RUN `/cso`, this one assumed they would HAVE it. The earlier
fix did not generalize because it was framed as being about the security axis; it was actually
about the deferral pattern. Anything that defers an axis by naming a tool now has to establish the
tool exists — which is why the detector is a general script and not an inline check.

**Decision.** Make the deferral conditional. `scripts/forgeward-detect-gstack-skill.sh <skill>`
answers "is this gstack skill installed here" deterministically; the reviewer runs it first and
declares its mode. `/cso` present → DEFERRED, unchanged prior behaviour. `/cso` absent → FULL: it
also audits dependency CVEs, install scripts, and lockfile integrity, and a Critical/High CVE in a
dependency the diff adds or upgrades is a FAIL.

**Fail-closed, deliberately asymmetric.** Every ambiguous answer is "not installed". A false
negative costs a duplicated audit; a false positive is a silently skipped check — the bug itself.
Detection requires both a directory named for the skill (bare, or behind a `[A-Za-z0-9_]+-` prefix,
since gstack's `setup` defaults to `SKILL_PREFIX=1` and names the skills-dir entry `gstack-cso`) and
the `(gstack)` marker in that `SKILL.md`'s frontmatter. The two arms are independent:
`bin/gstack-patch-names` rewrites `name:` only and never touches `description:`, so prefixing does
not disturb the marker. Both arms are pinned by mutation test — removing either turns a specific
assertion red (D2, and D4/D9 respectively), as does making the check stop following symlinks (D6),
which matters because gstack installs its skills as symlinks.

**Stated limits, because an unstated limit reads as a claim of coverage.** (1) It detects
*presence*, never diligence: gstack installed and never once invoked is indistinguishable from
gstack actively covering the axis, so exit 0 means "the tool the deferral names is here", not "the
axis was audited". (2) It cannot see a substitute — a repo covering CVEs with Dependabot, Snyk, or
a CI SAST job looks identical to one covering them with nothing; deciding what to do about that
belongs to `.forgeward/config.yml` and is tracked in `TODOS.md`. (3) The marker is a convention, not
a contract: if gstack ever drops the `(gstack)` suffix, detection reports ABSENT and callers
duplicate work — the safe direction, and preferred to matching on the bare name.

**Accepted cost.** A PASS now means slightly different things on two machines: the same Critical CVE
FAILs the gate standalone and is `/cso`'s to find when gstack is present. That variance is real and
is the price of not shipping the unconditional deferral. It is mitigated here by the mandatory
`SUPPLY-CHAIN MODE:` line in the reviewer's report, and recording the detected environment in the
pass marker — so the variance is auditable from the artifact rather than from memory — is tracked
in `TODOS.md`.

**Scope of this fix vs the evidence behind it.** The evidence is about the *pattern*: any deferral
naming an absent tool is a hole. The fix closes exactly one instance of it — the CVE deferral,
which is the only one where an axis actually goes unchecked. `security-reviewer`'s two gstack
references are positioning prose that skips nothing, and the other four reviewers name gstack zero
times, so there is no third instance to close today. The remaining gstack coupling is the gate's
`/ship` handoff, which is a convenience rather than an axis and is untested standalone. Both are in
`TODOS.md` under "Standalone posture"; this entry does not claim to have resolved them.

## RESOLVED — the publish matcher denied any command CONTAINING a publish verb

**Date:** 2026-08-02

**Symptom.** `scripts/forgeward-gate-check.sh` tested the publish verbs as a bare
substring of the whole command, so a command that merely MENTIONED one was denied as
if it issued one. It fired six times in a single session on this repo, including on
the patch script that was fixing it. A repo whose subject matter IS these commands
trips it constantly; a commit message quoting one, a `grep` for one, and a JSON test
payload containing one were all refused.

**Cause.** The test asked "does this text contain the verb", which cannot distinguish
DATA from CODE. Both are text.

**Fix.** Decide by QUOTING, which is how the shell itself encodes that distinction:
blank the quoted spans, then run the plain substring test on what remains. This needs
no model of separators, reserved words, or command prefixes — a `time`-prefixed
publish matches for the same reason a bare one does. Word boundaries on both sides
keep `git pushx` and `npm run push-docs` clear.

**Three attempts failed before this one; the failures are the useful part.**

1. and 2. Anchored the verb to a "command position" (start of text, after a
   separator, after a reserved word). Both failed review, in OPPOSITE directions:
   too narrow (`time`, `env FOO=bar`, `sudo`, `nohup`, backticks, and a
   backslash-escaped verb all evaded, every one of which the old substring caught),
   then too wide (widening the anchor class to `!` and `)` denied ordinary prose such
   as `echo 'Careful! ... will trigger CI'`). Chasing both at once means enumerating
   shell grammar with a regex, which this file's own header already calls a dead end.
   **Position was the wrong signal.**
3. Blanked the quotes with bash extglob substitution — the right idea, wrong
   mechanism. It mishandled backslash state (outside quotes an escaped quote is
   LITERAL, so a scanner that only pairs quote characters mis-pairs and blanks a
   command that really executes), and it was superlinear in quote DENSITY: 2.3s on
   1KB and 55s on 3KB of quote-dense input. Its own code comment quoted 0.006s on
   20KB, measured on quote-SPARSE input — true, and useless, because density is what
   drives the cost. Preserved on local tag `item2-wip-quote-stripping`.

**The constraint that caused attempt 3 was self-imposed.** "No fork" was assumed, not
required: `json_get` already forks `jq` or `python3` on EVERY invocation of this hook,
so a single `awk` pass was available the whole time. The fix is one awk pass tracking
quote state, backslash state, and command-substitution scope, gated behind a
`push|create` prefilter so the common path stays fork-free. Measured on WSL/gawk 5.1.0:
~7ms for the fork; the scan itself is linear and density-independent (1ms at 3KB, 10ms
at 20KB, 17ms at 60KB).

**A fourth failure mode, found in security review after the fix was already written.**
The first version of the scanner tracked quote parity FLAT across the whole command.
bash does not: each `$( … )` and each backtick span gets its own quoting scope. So a
mismatched quote type inside a substitution flipped parity for everything after it and
swallowed a later, entirely separate, entirely unquoted publish command:

```
git commit -m "$(printf '%s' "it's done")" && git push    ->  ALLOWED, and really pushed
a="$(printf '"')" git push                                ->  ALLOWED, and really pushed
```

An apostrophe in a commit message is enough. This was a REGRESSION against the old bare
substring, which caught both because it ignored quoting entirely — the exact shape the
"kept honest" disclosure existed to prevent, missed by all three disclosed bullets and
by tests A1–A7.

**Then twice more, each time in the fix for the previous one.** A scope stack was added
so each `$( … )` got its own quote scope. Round 2 found that a scope opens only on `$(`,
so a plain `(` … `)` pair inside a substitution — a subshell, the second paren of
`$(( ))`, any literal parens — popped the real scope early. Per-scope paren depth fixed
that. Round 3 found that a `case` pattern clause produces a bare `)` with no opening
paren at all, which did the same thing:

```
git commit -m "$( (true) ; git push )"        ->  ALLOWED, and really pushed
echo "$(case y in y) git push;; esac)"        ->  ALLOWED, and really pushed
```

**So the approach was wrong, not the implementations.** Three consecutive reviews, three
different desyncs, every fix correct and every one leaving another. The next version
would have modelled `case`/`in`/`esac`, and this file's own header already says where
enumerating shell grammar ends.

**The fix is to stop parsing substitutions and start distrusting them.** If the command
contains `$(` or a backtick, the blanked residue is not trusted and the RAW text is
matched instead. That cannot hide anything, and it retires the entire desync class
rather than its current instance. The scope stack, the paren depth and the backtick
tracking were all deleted; the scanner went back to quote and backslash state only,
which is all it needs for the commands it still handles.

What this buys and what it costs, precisely: commands WITHOUT a substitution — a commit
message, a grep pattern, a JSON payload, which is exactly the shape of all six original
false denials — keep the precise treatment. Commands WITH one over-deny if they mention
a verb anywhere. Nothing can be hidden by a scanner bug in between, because there is no
longer a scanner on that path.

**The generalizable lesson, and it cost three rounds to learn.** All three bugs had the
same shape: a state desync whose damage lands AFTER the construct that causes it. Every
test that put the interesting token near the verb passed, because the verb was never
where the corruption was. When a scanner carries state across a line, the test that
matters puts the trigger EARLY and the verb LATE with unrelated text between. All three
were found by executing against stubbed binaries; reading the code said it was correct
every time. And when consecutive fixes to the same mechanism each reveal a new instance,
the signal is to delete the mechanism, not to add a case to it.

This is also the argument for running the gate on a change whose whole subject is the
gate: each disclosure was honest about what it had considered, and each was still wrong.

**Method note, which is why this one held.** The expected verdicts were not derived by
reading shell grammar. Every case was executed against stubbed `git`/`gh`/`glab`
binaries to observe whether a publish ACTUALLY ran. That oracle corrected two beliefs:
a case drafted as a deny turned out to execute nothing (`\"` inside double quotes is
literal, so the command stays one argument), and a documented "blind spot" turned out
not to be a gap at all (an unterminated quote makes the command unparseable, so
nothing runs and allowing it is correct). Both are now assertions.

**A fourth review round, and the premise itself was wrong.** The comment above says
quoting encodes data-vs-code. It does not. Quoting suppresses splitting and globbing;
the shell then concatenates adjacent fragments back into one word. So a quoted COMMAND
WORD executes exactly like an unquoted one, while the scanner blanks the span and the
regex stops seeing the verb:

```
'git' push        g'i't push        git 'push'        g""it push      ->  all really push
```

This one is NOT fixed, and the reason matters more than the gap. The only thing
separating `git 'push'` (runs) from `echo 'the command is git push'` (does not) is
whether the quoted word sits in COMMAND POSITION. Any rule that catches the first
catches the second, which is precisely the over-denial this change exists to remove, and
deciding position is the grammar-enumeration dead end the file header warns about. The
old bare substring missed these too — `'git' push` does not contain the characters
`git push` either — so nothing regressed; the gap was simply never disclosed. Pinned in
A4 so it stays disclosed.

The same round found one that WAS fixable. An unquoted backslash-newline is a splice:
bash deletes both characters and the lines join with nothing between them, so
`git pu\<newline>sh` really pushes. Two things went wrong — awk saw two records and put a
space and a boundary where bash puts nothing, and the raw text contains neither "push"
nor "create", so the pre-filter exited before any scanning happened. Continuations are
now joined ABOVE the pre-filter, and A11 fails if that line is moved back below it.

**And fixing that exposed an older one, in `json_get`.** The join worked on WSL and did
nothing on Git Bash. Cause: on Windows, python3's stdout is a TEXT stream and translates
every `\n` to `\r\n`, so a multi-line command arrived carrying a CR that the shell it
describes never sees — the join looked for `\` + LF and found `\` + CRLF. The python
branch now writes bytes (`sys.stdout.buffer.write`) instead of using `print()`. This was
pre-existing and silent: every multi-line command has been mildly corrupted on Windows
since the fallback was written, harmless for single-line matching, and invisible on any
machine with `jq` — jq does not translate newlines, so the bug only exists on the
python path. Neither machine here has jq, which is the only reason it surfaced.

Worth stating as a rule rather than an anecdote: **a difference between two platforms is
only findable by running both.** Nothing about reading this code suggests a CR, and no
amount of reasoning on WSL would have produced it.

**A fifth round, and the same overclaim a third time.** The comment introduced above said
raw-text matching "cannot hide anything". It cannot hide anything QUOTING would have
hidden, which is a much smaller claim. A separator supplied at RUNTIME defeats it, in the
raw text exactly as in the residue, because the regex wants literal whitespace between
the words:

```
git${IFS}push      git$IFS'push'      gh${IFS}pr${IFS}create    ->  all really publish
```

Not fixable here for the same reason as the quoted command word — catching it means
modelling word-splitting and expansion. Disclosed and pinned in A4. Pre-existing: the old
substring missed these too. The same class can split the VERB rather than the separator:
`git pu''sh` runs, carries no literal `push`, and therefore dies at the cheap pre-filter
— a full miss where even the raw-text fallback never runs.

The same round found one that WAS fixable, on the platform this file keeps getting caught
by. On an NTFS-backed checkout the PROGRAM name resolves case-insensitively, so `Git push`
really runs a push on Git Bash — while git's own subcommand parsing stays case-sensitive,
so `GIT PUSH` does not. The verb test is now case-insensitive (`nocasematch`, scoped to
that one test and restored, since it also changes `case` semantics and the artifact guard
above depends on those). The pre-filter deliberately stays case-sensitive: a real publish
always carries a lowercase `push`/`create`, so the cheap path stays exact. Pinned by A12.

`marker_get` got the same byte-writing treatment as `json_get`. **Correction, 2026-08-06:
this described the intent, not the state — it landed in `gate-check.sh` only, and the copy in
`pre-push.sh` kept `print()` for another three releases. See the 0.7.6 entry at the top.** Its values are
single-line so the continuation bug never applied, but `print()`'s trailing newline still
becomes CRLF on Windows and `$(...)` strips only the LF — the surviving CR rides along on
`base`, which is then passed to `forgeward-diff-hash.sh` as a ref, fails to resolve, and
makes a genuinely fresh marker read as stale. Fail-safe (an extra gate run, never a false
PASS), but it was the untouched twin of a bug fixed two functions above it.

**Accepted loss, stated because it is real.** A publish verb inside a quoted argument
to a shell wrapper (`bash -c`, `eval`, `ssh host`, `trap ... EXIT`) is no longer
denied. The old substring caught those. Blanking the quotes is what hides them, and
un-blanking is exactly the over-denial this change removes. It is not the accidental
"I forgot to gate" shape this layer targets, and the enforcement boundary is still the
pre-push hook, which binds to resolved refs and SHAs. Pinned in `test/gate-test.sh` A4
so the disclosure cannot silently go stale.

**On completeness, which this entry has now got wrong three times.** First it said 118
oracle-checked cases meant "no command outside the list went unnoticed"; the next review
produced two that were, both inside the categories that sentence named. Then the fix for
those introduced "that cannot hide anything"; the round after falsified it with
`git${IFS}push`. The pattern is not that the individual claims were careless — each was
written directly after testing the thing it described. It is that a claim about what
CANNOT happen is not something testing can establish, and every round of this file that
tried to state one was wrong within a review.

So: the disclosed list is what has been FOUND, on bash 5.1.16 (WSL) and 4.4.23 (Git
Bash), across 118 executed cases plus five review rounds. It is not a proof of
completeness, and no sentence here should read like one. A lexical matcher over shell
text cannot be complete in principle — that is exactly why this is a reminder and the
pre-push hook, which sees resolved refs and SHAs after the shell has finished expanding
everything, is the boundary that actually holds.

Bash 5.3's value substitutions `${ cmd; }` / `${| cmd; }` run a command with neither
`$(` nor a backtick in the text, so the guard also matches `${` followed by whitespace
or `|`. Matching a bare `${` was tried first and reverted — `${VAR}` is ordinary bash,
and routing every quoted-variable command to raw text gave back a large slice of the very
over-denial this change exists to remove.

**And that arm was documented as unreachable here, which was wrong — for an instructive
reason.** The comment said neither local shell supports the syntax, on the strength of a
probe that ran `bash -c '${ git push; }'` and got "bad substitution". The probe used
`/bin/bash` (5.1.16). This script's shebang is `#!/usr/bin/env bash`, which on this
machine resolves to a linuxbrew **5.3.15** that executes it for real. The measurement was
correct and answered a question about a different interpreter than the one the hook runs
under. Round 6 caught it because the reviewer's shell resolved the same way the script's
does. The mechanism was fine — the arm denies correctly on 5.3 — but "I tested it" is
only as good as testing the thing that actually runs.

Covered by `test/gate-test.sh` A1–A12. Each assertion was mutation-tested: five go red
against the old substring matcher, two against the extglob attempt, A7 against removing
the awk-absent fallback, A8 against removing the substitution guard, A11 against moving
the continuation join back below the pre-filter, and A12 against dropping `nocasematch`.

Two of those assertions exist because a test was found to be hollow rather than wrong,
which is the same failure twice and worth naming. A9 covers the harness: `pretool()`
assembles JSON with raw `printf`, so a case containing an unescaped double quote reached
the hook as an EMPTY command and was allowed by short-circuit while appearing to exercise
the matcher — one A2 case was silently hollow that way. And A8's `allow` controls were
originally three substitutions containing no `push`/`create` at all, so the pre-filter
short-circuited every one of them before the guard they were supposed to control was ever
consulted; they now carry `push-docs` so they reach it. A test that cannot fail is not a
test, and both of these looked green the whole time.

## RESOLVED — base detection returned a stale LOCAL branch, mis-scoping the review

**Date:** 2026-07-31 · supersedes *"base detection on a direct-to-base commit"* below,
whose step-4 special case is now one instance of the general rule.

**Symptom.** `scripts/forgeward-detect-base.sh` returned a bare branch NAME (`master`),
and `skills/gate/SKILL.md` fed it straight into `git diff "<base>...HEAD"`, where a bare
name resolves to the **local** branch — which may be arbitrarily out of date with its
remote.

**Repro (verified, over-scoping).** A repo whose local `master` had never been
fast-forwarded: local `de1bbf3`, `origin/master` `5b94aac` (14 commits ahead).
`git diff --name-only master...HEAD` → **267 files**; `origin/master...HEAD` → **0**.
The gate would have dispatched six reviewers over 267 files of already-merged code.

**Repro (verified here, under-scoping — the dangerous direction).** Base branch with
unpushed commits, feature branched off them: `main...HEAD` lists only the feature file
while `origin/main...HEAD` lists the feature file **plus** the unpushed base commits the
push will publish. The gate reviews less than ships and writes a PASS marker for a
surface it never saw — a **false PASS**. Covered by `test/gate-test.sh` B6.

**Cause.** All three name-resolution arms produced a bare name, and two of them proved a
remote ref existed and then discarded it: the `origin/HEAD` arm stripped
`refs/remotes/origin/` off a ref it had just read, and the `origin/main` arm verified
`origin/main` and set `base=main`. Guaranteeing a non-empty base — the reason the script
exists — was never sufficient: it also has to be **current**.

**Fix.** Two-stage resolution. Stage A picks the branch NAME (unchanged). Stage B
resolves that name to the **publish boundary** ref: the branch's configured upstream
(`<base>@{upstream}`, so a fork tracking `upstream` and a local branch tracking a
differently-named remote branch both work), else `<remote>/<name>` for the first remote
that actually has it, else the local branch. A remote ref is adopted only when
`git rev-parse` confirms it exists — nothing is blindly prefixed with `origin/`, so a
local-only repo, an unauthenticated `gh`, and a base branch with no remote counterpart
all correctly stay local. Detached HEAD is unaffected: resolution never depends on which
branch is checked out.

**Silent correction, loud report — argued, not assumed.** Blocking on drift was rejected:
a base branch behind its remote is the normal state of a working checkout, not an error,
and a gate that refuses to run on the common case gets bypassed — a bypassed gate reviews
nothing. Silence was also rejected: "your local master is 14 commits behind" is a fact the
user acts on, and a silent re-scope makes the reviewed surface differ from what the user
would compute by hand. So the re-scope is automatic (a mis-scoped diff is a correctness
bug, not a preference) and the drift goes to **stderr**, leaving stdout exactly one clean
ref for `$(...)` capture. `SKILL.md` Step 0 requires the orchestrator to repeat the note.

**Knock-on, and it is correct.** The marker now records a remote-tracking base
(`"base": "origin/main"`), which both `forgeward-gate-check.sh` and
`forgeward-pre-push.sh` replay through `forgeward-diff-hash.sh` at push time. If a fetch
moves `origin/main` between gate and push, the publish boundary genuinely moved, the hash
flips, and the gate re-fires. Slightly more re-gating, and the alternative — pinning to a
boundary that has since shifted — is the false PASS this entry exists to remove.

**Stated blind spots** (in the script header and `SKILL.md`): it never runs `git fetch`,
so `origin/<base>` is only as current as the last fetch — the same class of error one
level up, invisible from here; and it infers the base from repo defaults, so it cannot
know a PR targets a release branch or is stacked on another feature branch.

**Coverage.** `test/gate-test.sh` B5–B13: behind-remote, ahead-of-remote (with an
assertion that the naive base misses what the push publishes), no remote at all, detached
HEAD, fork with a non-`origin` upstream, base with no remote counterpart, local branch
tracking a differently-named remote branch, single-line stdout + non-empty stderr note,
and `--name`.

## RESOLVED — a read-only reviewer wrote scanner output into the repo it was auditing

**Date:** 2026-07-31

**Symptom.** Running `agents/security-reviewer.md` created a directory named `C` +
U+F03A (bytes `43 EF 80 BA` — the private-use colon substitute MSYS/Cygwin uses) at the
**root of the repo under review**, containing a nested path tree with `semgrep.json` at
the leaf.

**Cause (confirmed, not inferred).** A scanner was given an absolute *Windows* output
path from a POSIX shell. Reproduced directly: `semgrep scan --json -o
"C:/Users/…/scratchpad/semgrep.json" a.js` creates the entire `C:/Users/…` tree inside
the current directory — semgrep's writer creates the parents itself, so no separate
`mkdir` is involved. Under a POSIX runtime `C:/…` is a **relative** path; MSYS stores the
`:` as U+F03A on NTFS, which is the byte sequence observed. Confirmed on Git Bash
(`MINGW64_NT-10.0`) that a path whose `C:` is not the first component lands as a
directory tree in the CWD with exactly that on-disk encoding.

**Why it is not cosmetic.** (1) The tree is untracked and matched by no common
`.gitignore`, so any `git add -A` commits the reviewer's scratch into the user's
repository. (2) A read-only reviewer wrote into the repo it was auditing, breaking the
contract the gate's whole design rests on and advertises.

**Why the fix is not a prompt.** It happened **twice**, the second time with a spawn
prompt that explicitly instructed the agent to write all scanner artifacts outside the
repository. An instruction is not a control.

**Fix — four layers, narrowest first, none sufficient alone.**
1. `scripts/forgeward-scan.sh` — the invocation reviewers are now told to use. Refuses
   output-file flags and drive-letter arguments, puts the report on stdout, and diffs the
   repo's untracked set across the run, reporting anything the scan left behind and naming
   the drive-letter shape specifically.

   **It reports; it does not delete — and that is not timidity.** The first draft removed
   the tree it had just watched a scanner create, which looks obviously safe. It is not:
   on Git Bash the directory is named `C` + U+F03A, MSYS maps that back to `C:`, and
   `readlink -f "C:"` there resolves to `C:/` — **the drive root** (verified on
   `MINGW64_NT-10.0`). That `rm -rf` would have targeted the user's entire C: drive on
   precisely the platform this bug occurs on. Only the `./`-prefixed form
   (`rm -rf -- "./C:"`) stays relative, so the wrapper prints that for the user to run.
   The hazard is written into the script so nobody re-adds the automatic delete.
2. `PreToolUse` deny in `forgeward-gate-check.sh` — denies a scanner command whose output
   flag targets a drive-letter path, with a reason that teaches the stdout form.
   **Verified to reach subagents** (2026-08-01): the open question was whether the harness
   routes a *subagent's* Bash calls through `PreToolUse` at all. Probed directly — a
   throwaway repo with no marker, and a harmless `echo` whose text contains `git push`.
   The main agent's call was denied; the identical call issued from inside a subagent was
   denied too, with the same reason text delivered as a tool error the agent can read, and
   the hook resolved the branch from the `cd` target inside the compound command rather
   than the session cwd. So layer 2 does cover the reviewers.
   **The real dependency is deployment, not routing:** hooks run from the INSTALLED plugin
   cache (`~/.claude/plugins/cache/forgeward-gate/forgeward/<version>/`), not from a
   working tree. Layer 2 protects nothing until this version is actually installed — which
   is exactly how the first probe of this guard came back "not denied" while the code sat
   green in the branch. Layers 1, 3 and 4 need no install to work.
3. `scripts/forgeward-artifact-dir.sh` — hands out a path that is absolute *in this
   shell* (translating a Windows `TMPDIR` via `cygpath`) and outside the repo.
4. `scripts/forgeward-workspace-guard.sh` — the gate snapshots the tree before spawning
   reviewers and diffs it after; contamination halts the handoff to `/ship`, since /ship
   stages and commits. It reports and never deletes: untracked files are the user's.

**Non-goals, stated so the absence of a limit is not read as coverage.** The hook fires
only on drive-letter paths, so a deliberate `semgrep -o report.json`, an `-o /tmp/x.json`,
and `docker run -v C:/repo:/scan …` all stay allowed. Layers 1–2 read command *text*, so
an unlisted scanner, an unusual output flag, or a path built inside a shell variable pass
them; layer 4 sees the result regardless of cause. Layer 4 in turn cannot see a write to
an already-gitignored path, a write outside the repo, or which reviewer did it. The hook
also **over**-denies: a command that merely quotes the defective shape (grepping these
very docs) is refused. That fails safe and is recoverable, and it is written into the
script rather than papered over.

**Caught by the gate reviewing itself.** The first version of layers 1–2 anchored the
drive-letter pattern to the *start* of an argv token, so the cuddled short-flag form
`-oC:/Users/…` — one token, a standard getopt convention — evaded **both**, which
directly contradicted the comment claiming "layers 2 and 3 are the net" for a flag layer
1 misses. `looks_like_path()` was inverted for the same reason: it refused only values
containing a slash or a known extension, so a bare `-o myreport` created `./myreport` in
the repo. Both are now deny-by-default — a drive-letter path is refused anywhere in a
token, and an output flag's value is treated as a destination unless it is a recognized
format word (`json`, `sarif`, `table`, …), so `-o json` still works. Regression tests
P2b, P8b–P8d. A test that cleaned up with a bare `rm -rf 'C:'` was corrected to the
`./`-prefixed form for the drive-root reason above — the suite must not depend on `mkdir`
and `rm` translating a drive-letter argument identically.

**Then the FIXES were re-reviewed, and both had over-refused.** Worth recording, because
the failure mode is the interesting one: each correction overshot in the same direction.
(1) Closing the cuddled-flag hole with a fully unanchored `*[A-Za-z]:[\/]*` also matched
any token with a letter before `:/` — `--config https://semgrep.dev/p/ci` and syft/grype
source specifiers `dir:/repo`, `oci-dir:/img`. Legitimate scanner arguments, refused. The
match is now anchored to a real path boundary (token start, after `/`, after `=`) with a
separate flag-cuddled pattern. (2) `_FORMAT_WORDS` wraps across three source lines, so
the wrap points are literal newlines; a `*" $1 "*` test against the raw string silently
dropped `yml`, `cyclonedx`, `compact` and `full`, treating them as destination paths.
Normalized before matching. Neither was exploitable — both fail closed — but friction in
a guard is not free: it is what pushes a reviewer to bypass the wrapper, which costs more
than the shape being caught. Regression tests P8e, P8f.

**Third pass returned FAIL, and it was right.** Every check accepted `=` as the
flag/value separator and nothing else, so `--output:C:/x` — the MSBuild/dotnet/PowerShell
convention — matched none of them and passed through untouched. That is worse than an
unlisted flag (a stated non-goal): it is an *enumerated* flag reached through a side
door, so the guarantee was defeated rather than merely incomplete, and layer 3 would only
have reported the write after it landed. `:` is now accepted everywhere `=` is, in all
three checks. Verified it does not repeat the overshoot: a colon-joined URL and a
registry ref with a port and tag (`localhost:5000/img:latest`) both stay allowed.
Regression test P8g, both directions.

**Fourth pass returned FAIL on a demonstrated arbitrary file write.** `looks_like_path()`
short-circuited on `-*` — "that token starts with a dash, so it is another flag, not this
flag's value." That is simply false for getopt-family parsers: pflag/Cobra, which
**gitleaks and trivy use**, consume the next token as the value unconditionally. Verified
end to end against the real binary: `forgeward-scan.sh gitleaks dir . --report-path
-evil.json` was passed through with no objection, and gitleaks wrote `-evil.json` into the
repo under review — the exact class this wrapper exists to close, through one of the four
scanners it names. The exception is now narrowed to a bare `-` (stdout, the one dash-led
value that is not a file); everything else dash-led is checked. Cost: a malformed
`--output --json` is refused rather than ignored, which fails closed on a command that
was already broken. Regression tests P8h (shapes, plus a `--` decoy and the bare-`-`
allow) and P8i (the same invocation against real gitleaks, asserting the repo stays
clean).

**Fifth pass returned FAIL: the format allowlist was tool-agnostic and should never have
been.** grype and syft OVERLOAD `-o` — `-o json` prints to stdout, `-o json=file` writes.
trivy does not: its own help reads `-o, --output string   output file name`, with
`-f/--format` separate, so `trivy -f json -o json .` writes a file literally named
`json`. semgrep and gitleaks match trivy. So the allowlist turned every format word into
a writable filename for **three of the four scanners this wrapper names** — and P8b
asserted that as correct, which is the worse half: a test was pinning the bug in place.
The exception is now keyed on the tool (`grype`, `syft` only); everywhere else an output
flag's value is a destination, full stop. Regression tests assert both directions per
tool, and that grype's own write form `-o json=out.json` is still refused.

**Sixth pass PASSED, with one Medium accepted as a documented limit.** The per-tool `-o`
exemption trusts `basename "$tool"`, so an executable *named* `grype` that is not grype
inherits it and could write a file named after one of the ~30 format words. Not closed,
deliberately: this script runs `"$tool" "$@"`, so anyone able to place that executable
already has code execution here — the write is strictly weaker than what they already
hold — and probing `--version` would not close it either, since a spoofed binary can
print anything. Written into the script header as a blind spot rather than left implied.
The half of that finding that *was* worth acting on: contamination used to exit with the
tool's own code, so a scanner that found nothing (exit 0) left the repo written-to and
still read as success. A tool exiting 0 after leaving new untracked paths now yields
exit 3; a non-zero tool exit is preserved, since the caller already knows.

**The pattern across all five failing passes is the durable finding.** Every correction to this
guard erred along the SAME axis — which token shapes count as a flag/value boundary —
first anchoring too tightly, then too loosely, then handling one separator, then trusting
a leading dash. None of it surfaced from reading the code; each took an adversarial pass
with a concrete PoC, and the last one needed a real scanner binary rather than an
argument about string shapes. Two conclusions worth keeping: a guard whose correctness is
a claim about token shapes needs its counterexamples **enumerated in tests**, not argued
in comments; and layer 1 should be understood as removing an affordance, not as a
boundary — the reason layers 3 and 4 exist is that this kind of enumeration is never
finished.

**Coverage.** `test/gate-test.sh` P1–P12: the deny fires on both slash conventions, and
does **not** fire on relative `-o`, POSIX-absolute `-o`, or a drive path in a non-scanner
command; the wrapper refuses flags and drive paths and passes stdout through; the artifact
dir is POSIX-absolute, exists, and is outside the repo; the workspace guard flags a
staged `C:` tree and stays quiet on a clean one; and a live control asks the platform
whether an unguarded drive-letter write actually lands in the repo before asserting either
way — a POSIX-only assertion would pass while the bug remained, because the bug *is* the
path translation.

## DECISION — page posture is per route group, not per site; three postures became five plus `unknown`

**Date:** 2026-07-23

**Problem.** The seo-reviewer treated "public" and "indexable" as the same thing. A site
deliberately serving `User-agent: * / Disallow: /` while carrying Open Graph tags — so a
link renders a card in chat but never appears in search — was reported as Critical/High
("a public page that can't be indexed") and hard-failed the gate. That is a legitimate,
common design: share links, unlisted deliverables, client previews, invite-only pages.
No waiver mechanism existed, and `skills/gate/SKILL.md` correctly forbids the orchestrator
from rationalizing a FAIL into a pass, so the only escape was `git push --no-verify`,
which skips **every** axis to silence one.

**Why not a waiver.** A whitelist suppresses a finding; it does not teach the reviewer what
it is looking at. The reviewer would keep being wrong and the user would keep annotating
around it. Posture is the right primitive: declare (or detect) what the page IS, and the
ruleset follows. An expiring, committed waiver file remains a reasonable last resort for
genuine one-offs, but it is not the fix for this class.

**Decision.** The reviewer classifies posture **per route group** and switches ruleset:
`public-indexed`, `private-shareable`, `private-closed`, `staging-preview`,
`authenticated-shareable`, and `unknown`. Per-route matters more than the taxonomy itself —
the single most common real shape is indexed marketing pages plus an authenticated app on
one origin, and a site-wide verdict necessarily gets one of them wrong. `unknown` reports
only what holds under every candidate posture rather than guessing; a wrong posture yields
confident findings about the wrong thing, which is worse than an acknowledged gap.

Under `private-shareable` the checklist inverts: indexability findings are the intent and
must not appear at any severity (reporting them as Low still trains the reader to ignore
the reviewer), while a broken link preview becomes High — missing or partial OG tags,
client-rendered OG tags that preview bots never execute, a relative `og:image`, or a
blanket disallow with no per-agent allowlist group.

**Privacy consequence.** These sites have no authorization boundary — the URL *is* the
credential — and every rule in the privacy-reviewer presupposed one ("visible to users who
shouldn't see it" assumes accounts). Added an unauthenticated-PII-surface section, led by
two rules: bulk PII crossing to the client for a lookup UI (a search feature must match
server-side and return only the matching record), and two paths to one data store with
different auth postures, where the credentialed path creates false confidence about the
whole feature. The gate now fires the privacy-reviewer on `private-shareable` groups even
when the diff looks like markup or config, since on such a group any new route or
client-reachable data source is a personal-data change.

**Also recorded as a limit.** `skills/gate/SKILL.md` now requires the gate to state what the
diff cannot see — externally-resolved engines, submodules, gitignored paths that committed
tooling references — because a PASS on a thin customization layer must never read as a PASS
on the system. The privacy-reviewer carries a matching blind-spot list. An unstated limit is
indistinguishable from a claim of coverage.

**Deliberately excluded.** A `paywalled`/metered posture (its own specialist rulebook;
half-implementing it is worse than not claiming it) and an "indexed but no OG tags" posture
(on an indexed site missing OG is a defect, already Medium/Low — absence of OG only reads as
intent when the site has also opted out of search). Postures are capped deliberately: each
one added is another chance to misclassify.

## RESOLVED — gate false-blocks a push from a git worktree; enforcement moved to pre-push

**Date:** 2026-07-15 (resolved 2026-07-16)

**Symptom.** Work isolated in a linked `git worktree` passes `/forgeward:gate` (all
reviewers PASS, marker written), but the subsequent `git push` / `gh pr create` is denied
anyway: *"forgeward gate not passed for HEAD …"*. The branch is committed and genuinely
gated, yet the publish stays blocked. Re-running the gate does not help. Manifests only when
the Claude Code session's cwd is a **different checkout of the same repo** (typically the
main checkout) than the worktree holding the gated branch.

**Cause.** Both halves keyed the marker off `git rev-parse --git-dir`, and the check half
also recomputed the substantive-diff hash against **its own cwd's HEAD**:
- `forgeward-write-marker.sh` ran inside the worktree → `--git-dir` = the per-worktree git
  dir → marker written *there*, pinned to the worktree HEAD.
- `forgeward-gate-check.sh` (PreToolUse) `cd`s to the hook event's `.cwd` = the **session**
  cwd (the main checkout), so `--git-dir` = the main `.git`. It looked for the marker in the
  wrong git dir AND, via `is_fresh` → `forgeward-diff-hash.sh`, recomputed `base...HEAD`
  against the main checkout's HEAD (= `origin/main` → empty diff). Two independent
  fail-closed misses. It is a cwd/worktree mismatch, not a real gate failure — and the
  auto-mode classifier correctly refuses to let an agent route around a green-looking gate,
  so the push wedges.

**Fix — part 1: the marker is worktree-safe.** Two coordinated changes, needed by every
enforcement layer:
1. `forgeward-diff-hash.sh <base> [tip]` takes an explicit tip (defaults to `HEAD`, so
   existing single-checkout behavior is byte-for-byte unchanged), so freshness can be checked
   against a specific ref/SHA rather than whatever the caller has checked out.
2. `forgeward-write-marker.sh` stores the marker **branch-keyed under the common git dir**
   (`git rev-parse --git-common-dir`), shared across all linked worktrees, so a marker written
   from a worktree is found from any checkout of the repo. Keying by branch keeps concurrent
   worktrees on different branches from clobbering one another.

**Fix — part 2: enforcement moved OFF the PreToolUse hook and onto a git `pre-push` hook.**
The first attempt made the PreToolUse hook parse the push command to learn which ref it would
send. **Four** pre-merge security reviews each found the parser failing OPEN, and the pattern
was terminal: to know what a shell command pushes you must reimplement the shell's lexer, and
each round exposed another layer — word-splitting and `git -C` (R3), quote/backslash removal
`"git" push` (R4), then variable expansion. Closing expansion would require denying every
`git … $var`, which breaks ordinary git use. **Conclusion: a PreToolUse hook reads command
TEXT and cannot be both bypass-proof and usable.** (Most of these bypasses — `git -C`,
`git  push` — also exist in the pre-0.3.0 gate; this is architectural, not a regression.) So:

- **`forgeward-gate-check.sh` reverted to a simple best-effort REMINDER**: on a publish
  command, honor a leading `cd` and check the current checkout's branch marker; deny with a
  message that says the enforced check is pre-push. It is fast UX, explicitly NOT the lock.
- **`forgeward-pre-push.sh` is the enforcement.** A git pre-push hook runs INSIDE the push:
  git hands it the exact `<local-ref> <local-sha> <remote-ref> <remote-sha>` lines on stdin,
  after the shell has already resolved `git -C`, quoting, `$vars`, `xargs`, aliases — there is
  no text left to trick. It blocks the push if ANY branch ref being pushed lacks a fresh marker.
  It keys off the ref being UPDATED on the remote (`remote_ref`) and verifies the pushed COMMIT
  (`local_sha`, matched against any local branch's marker) — so `git push origin <sha>:refs/heads/x`
  or `HEAD:refs/heads/x`, where the local side isn't a `refs/heads/*` name, can't skip the check
  (a fail-open the final review caught before merge).
- **`forgeward-install-pre-push.sh`** installs it into the repo's EFFECTIVE hooks dir
  (honoring `core.hooksPath` — a global one is common and made per-repo `.git/hooks` installs
  dead) and sets a per-repo opt-in (`git config forgeward.gate enabled`). The enforcer no-ops
  unless that opt-in is present, so a hook living in a shared/global dir never blocks unrelated
  repos.

**Honest residual (this is strong, not indestructible).** `git push --no-verify` skips the
hook; the marker is a local file that can be forged; git hooks are not cloned (re-install in a
fresh clone, and after a plugin update, since the enforcer path is baked into the hook). Any
purely-local gate has these limits. For an **unbypassable** boundary, gate the MERGE
server-side — GitHub required checks + branch protection via `/forgeward:ci-gate` (which
already does this for the deterministic scanners). This hook stops the common/accidental
ungated push, robustly, on the developer's machine.

**Coverage.**
- `test/gate-test.sh` — the PreToolUse reminder: no-marker deny, non-publish untouched, PASS
  allow, version-bump-invariance, dependency-sensitivity, stale deny, fail-open outside a repo,
  the `/ship` expansion halt, and worktree honor-cd (a `cd <worktree> && git push`, gated →
  allow, ungated → deny, single-quoted spaced path → allow), plus base-detection and the
  manifest-hooks guard.
- `test/pre-push-test.sh` — the enforcer, driven exactly as git drives it (refs on stdin):
  gated allow; ungated block (names the ref); multi-ref one-ungated block / all-gated allow;
  branch deletion allow; post-marker commit stale block; version-only bump allow; tag (non-
  branch) allow; **a marker written inside a linked worktree honored from the main checkout**
  (the original bug, now handled with no cd and no parsing); and the opt-in no-op (a repo
  without `forgeward.gate` is not blocked — safe as a global hook).
- End-to-end (manual harness): real pushes through the installed hook against a bare remote
  confirm `git -C`, `git  push`, `"git" push`, and `g\it push` are all BLOCKED while ungated;
  `--no-verify` bypasses; and a gated ref pushes.

## DECISION — add a security reviewer + CI enforcement (reversed "delegate security to /cso")

**Date:** 2026-07-13

**Prior decision.** forgeward deliberately shipped no general security reviewer, delegating the
OWASP/STRIDE/CVE axis to gstack's `/cso`, and the README documented "no SAST, no CI merge-gating —
handle those in your project's CI." The rationale was avoiding duplication of `/cso`.

**What broke it.** On a real PR (a wp-admin SQL runner executing committed `.sql` against a live
DB), the gate fired only privacy + accessibility and returned PASS. `/cso` is opt-in and manual;
it wasn't run. A commercial SAST scanner (Wiz) independently flagged **1 critical + 13 high** on
the same diff — including a SQL-injection-class finding. The delegation assumed `/cso` would be
run; in the real workflow it wasn't, so the security axis was simply absent at the moment of ship.

**Decision.** (1) Add `security-reviewer` as a sixth gate reviewer — diff-scoped, read-only, runs
a bundled framework-aware SAST rulepack (`rules/wp-security.yml`) plus injection/authz reasoning,
returns `SECURITY VERDICT: PASS|FAIL`. (2) Add `/forgeward:ci-gate` (absorbing the former
`readiness` skill) to wire real scanners (Semgrep, PHPCS/WPCS, Trivy, Gitleaks) into CI and
optionally make them required checks via branch protection. `/cso` remains the deep whole-repo
audit; the reviewer does not replace it — it stops the gate greenlighting injection.

**Scope note.** `security-reviewer` is diff-scoped and one reviewer won't match a commercial SAST
engine's recall — the `ci-gate` CI scanners are the unskippable floor; the reviewer is fast local
feedback. Verified: the bundled rulepack flags 8 dynamic-SQL sinks on the PR above (6 unprepared
`$wpdb` queries + a value interpolated into a `prepare()` format string) and stays silent on
correctly-prepared and literal queries.

## RESOLVED — base detection on a direct-to-base commit (origin/<base> fallback)

**Date:** 2026-06-22

**Symptom.** A commit made directly on the base branch (e.g. a docs edit straight to
`master`, no feature branch) could not be gated. `scripts/forgeward-detect-base.sh`
resolved to the bare base branch, so the gate's diff scope `base...HEAD` was **empty**
— local `master` equals `HEAD`, so the three-dot diff has nothing in it. The
`/forgeward:gate` skill then hit its "you're on the base branch, nothing to gate" stop,
while the `PreToolUse` push hook still (correctly) blocked the push for lack of a PASS
marker. Net result: a deadlock — a real unpushed change about to publish, but no
non-empty surface to review, so no honest marker could be written.

**Repro.** On `master`, commit a change directly. `origin/master` is now behind `HEAD`
by that commit. `git diff master...HEAD` is empty; the push hook blocks; the gate reads
"nothing to gate." First observed live while shipping the README "Security scope" note
(worked around at the time by manually scoping the marker to `origin/master`).

**Fix (SUPERSEDED 2026-07-31 — see the stale-local-branch entry at the top).** Step 4 in
`scripts/forgeward-detect-base.sh`: when `HEAD` is ON the resolved base branch AND
`origin/<base>` exists AND differs from `HEAD`, return `origin/<base>` (the publish
boundary). The diff then scopes to the real unpushed change. Guarded two ways: a base
branch in sync with its remote keeps the bare base (genuinely nothing to gate), and a
feature branch (`HEAD != base`) skips step 4 entirely, so that resolution is
byte-for-byte unchanged.

**Why it was superseded — the lesson, not just the code.** The fix was right about the
*case* and wrong about the *rule*: it special-cased "HEAD is on the base branch" instead
of recognizing that the base should ALWAYS be the publish boundary. The guard that kept
it narrow ("a feature branch skips step 4 entirely, so that resolution is byte-for-byte
unchanged") is exactly what preserved the bug on every feature branch — which is the
common path. Step 4 is now deleted; stage B resolves the remote-tracking ref for every
branch, and this case falls out of it with no special-casing.

**Coverage.** `test/gate-test.sh` B4 (assertions 22–23): a direct-to-base commit with
`origin/main` behind → detect returns `origin/main`, and the test proves meaningfulness
(the new base scopes the real changed file; the old bare-`main` diff is empty). The three
prior base-detection tests (origin/HEAD unset, origin/HEAD set, master-only fallback)
still pass unchanged.

## RESOLVED — duplicate hooks load (manifest re-referenced the auto-loaded hooks.json)

**Date:** 2026-06-22

**Symptom.** Plugin load failed on reload/reinstall: *"Hook load failed: Duplicate hooks
file detected: ./hooks/hooks.json resolves to already-loaded file …/hooks/hooks.json. The
standard hooks/hooks.json is loaded automatically, so manifest.hooks should only reference
additional hook files."* With hooks failing to load, the enforcement gate is effectively
DOWN — pushes/PRs are no longer intercepted.

**Cause.** `.claude-plugin/plugin.json` set `"hooks": "./hooks/hooks.json"`. Claude Code
auto-loads the standard `hooks/hooks.json` by convention; the explicit manifest reference
then loads the same file a second time. (Not introduced by a code change — it surfaced when
the plugin reload began enforcing the auto-load convention.)

**Fix.** Remove the `"hooks"` key from `plugin.json`. The standard `hooks/hooks.json` still
loads automatically; `manifest.hooks` is reserved for ADDITIONAL hook files, of which this
plugin has none.

**Coverage.** `test/gate-test.sh` M1 (assertion 24): static guard that `plugin.json`'s
`hooks` value does not point at the auto-loaded `hooks.json` — a re-add fails the suite.
