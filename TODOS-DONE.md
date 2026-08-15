# TODOS — completed

Completed work archived out of [`TODOS.md`](TODOS.md), newest first. It lives here
because `TODOS.md` is read in full on every pre-commit sweep, and finished work can
never be acted on by a sweep — it was 22% of that file's bytes and bought nothing.

Nothing was pruned. These entries carry the reversed decisions, the deliberate
non-goals and the "we shipped the narrow fix on purpose, here is what it does not
cover" that a later change needs before it re-opens the same ground. The rules worth
obeying were lifted into [`CLAUDE.md`](CLAUDE.md) on the way out, and this file is
their provenance — grep here before overriding one of them.

`DECISIONS.md` remains the source of truth for *why* a design is the way it is. This
file records what was done and what it deliberately left undone.

- **P2 ×2: two documented config keys were parsed by nothing, and the reader refused the
  shapes real users write.** Fixed 2026-08-06, shipped in 0.9.0. Full reasoning in
  `DECISIONS.md`.

  0.8.0 gave `.forgeward/config.yml` its first reader, for `standalone.substitutes` alone —
  which made the gap *harder* to see, not smaller: a file where one key genuinely works is a
  stronger claim that the others do than a file where none do.

  Shipped: flow sequences (`[a, b]`) and simply-quoted scalars now parse in both list forms;
  `seo.posture` is read and validated against the six postures by whole-string comparison, so
  an unrecognised value returns the reviewer to detection rather than reaching it; marker
  schema 4 carries `seo_posture`; README gained a `.forgeward/config.yml` section naming the
  honoured keys and the limits.

  **The python3-YAML arm this file previously recommended was declined, and the reason
  overturns the recommendation rather than deferring it:** PyYAML is not in the standard
  library (verified — no `yaml` in `sys.stdlib_module_names`), so `python3` present says
  nothing about `import yaml` working. That arm would be selected by what happens to be
  installed and would parse *different shapes* from the fallback — the 0.7.5 divergence, which
  V7 exists to catch. Extended the single awk instead, verified identical under gawk, mawk and
  busybox awk.

  E19–E27, all eight mutation-tested. E27 is the one worth remembering: it pins that an awk
  which *exits 0* while printing nothing usable reads `unreadable` rather than
  present-with-an-empty-list, and its second clause is a positive control, because
  `unreadable` is also what a genuinely broken fixture produces. E17 had to be updated in the
  same commit or it would have silently become vacuous — see the coupling item above, which
  that discovery extended.

- **P2: the gate reported a `/ship` handoff it never performed when gstack was absent.**
  Fixed 2026-08-06, shipped in 0.8.0. Closes the Option B decision, the README quality
  claim, the marker-environment item, and the "untested handoff" item in one lane.

  The handoff had been flagged as "untested — likely-broken", guessing a hard failure. It
  was not a hard failure, and the reality was worse: the marker is written *before* the
  handoff, so the PASS was never at risk and the user was never blocked — the gate simply
  announced "Handing off to /ship" on a machine where nothing shipped. Same class as the
  0.7.4–0.7.6 error-path work: the failure surface is identical to the success surface.

  Shipped: `scripts/forgeward-detect-environment.sh` (probes `ship`/`review`/`cso`, reads
  `standalone.substitutes`, always exits 0, fails toward disclosure); gate Step 1c naming
  any axis whose owner is absent and then gating normally; Step 3 branching on
  `gstack_ship`; marker schema 3 carrying the environment. README line **57** (not 45 —
  the number in this file and in `docs/axis-proposals.md` was wrong, and is corrected in
  both) now qualifies the quality claim.

  Three documents were also describing behaviour the code did not have, which is how the
  gap survived: `live-test/LIVE-TEST.md` told testers the gate "tells you it would" hand
  off standalone; `docs/axis-proposals.md` said "forgeward refuses the `/ship` handoff",
  conflating this repo's own dev workflow with plugin behaviour; and
  `forgeward-gate-check.sh`'s halt message promised it "ships in one motion". All three
  corrected in place. Full reasoning in `DECISIONS.md`.

  E1–E18, each mutation-tested in both directions where a direction exists. E2 is E1's
  positive control and is load-bearing: gstack is installed on the author's machine and
  the probe is not a PATH lookup, so an assertion that forgets any of its three roots
  finds the real gstack and greens vacuously. E12–E17 were added *after* E1–E11 were
  green, for the two Medium findings of the 0.8.0 security review (a followed config
  symlink; a character allowlist mistaken for structural validation) — a reminder that
  a passing suite is evidence about the assertions in it and nothing else. E18 pins that
  a CRLF config parses identically to an LF one — not a security case, a regression guard
  for the trailing-CR class that already shipped once in 0.7.6. Suites: gate 162/162,
  pre-push 15/15.

- **P1: unparseable hook input was ALLOWED through the PreToolUse gate — and the #11 fix
  that was supposed to prevent it had been silently cancelled by the branch it fell
  through to.** Fixed 2026-08-06, shipped in 0.7.6.

  `json_get`'s python3 arm wrapped `json.load` and the field traversal in one
  `except Exception: pass`, so "this is not JSON" and "that field is absent" both came back
  empty with status 0. #11 had made the **jq** arm check its status and fall through to
  python3; on malformed input that fall-through fired exactly as designed and handed control
  to a branch carrying the same defect. Net effect, measured on both paths: a truncated
  payload containing a real publish verb was allowed, with jq present *and* with jq absent.
  A13/A14 could not see it — with a broken jq and no marker the hook denies for an unrelated
  reason, so the arm looked covered.

  Fix: split the parse from the traversal (parse failure → exit 1, absent field → exit 0 with
  empty stdout), and on unreadable input decide from the **raw bytes** — deny if they contain
  a publish verb, allow otherwise. Narrow on purpose: this hook fires on every Bash tool call,
  so denying on any unreadable payload would wedge the session the moment the JSON tool broke.
  Pinned by A20 (denies on both arms) and A21 (does not over-deny ordinary Bash). Both
  mutation-tested.

  Surfaced by the quality-axis base-rate measurement, as a lead — verified here before it was
  acted on, and it turned out broader than reported: the agent described it as reachable only
  via the python arm, and it is reachable with jq present too.

  Two things this took with it. `test/gate-test.sh`'s A4 case `g""it push` had been passing for
  the wrong reason since it was written — `pretool()` assembles JSON with raw `printf`, so the
  unescaped quotes made the payload invalid and the verdict came from the empty-command
  short-circuit rather than from the matcher. It is now `g\"\"it push`, decodes correctly, and
  still allows, so the disclosure stands and is finally earned. And the first draft of A20's
  jq-less PATH shim was a hand-written tool list that omitted `dirname`; the script died on its
  second line, emitted nothing, and "no output" reads as ALLOW — a green assertion proving
  nothing. The shim now mirrors the real PATH minus jq, and both shims carry a positive control.

  The gate's own security review of this branch then found the **expansion** path still carried
  the fail-open: it computed `_unreadable` and never read it. Rated Low as an unused variable; it
  is not. On that path an empty `cwd` means no `cd` happened, so `is_fresh()` answers for whatever
  directory the hook process inherited — a fresh marker in an unrelated repo lets the `/ship`
  through. Closed by halting unconditionally there, with no raw-text narrowing, because that path
  fires only on a typed `/ship` and a false halt costs one retry. Pinned by A22, whose **first
  draft was vacuous and was caught by mutation testing**: it ran the probe from the harness's own
  cwd, which has no marker, so removing the guard entirely still produced exit 2. It now runs the
  hook process from inside the gated repo, which is the only arrangement where the inherited-marker
  fail-open is reachable at all.

- **P3: `marker_get` discarded jq's exit status, in both copies, and one of them still used
  `print()`.** Fixed 2026-08-06, shipped in 0.7.6.

  The third instance of the error-path class (after `json_get` and `strip_quoted`, #11). It
  fails CLOSED, which is why it was deliberately left alone at 0.7.3 — and that reasoning was
  wrong twice: fail-closed here means *every* push on a box with a broken-but-installed jq is
  refused permanently, with the python3 fallback beside it unreachable, which is not a hook
  erring safe but a hook that has stopped enforcing and started blocking. `command -v jq`
  succeeding means jq is INSTALLED, not that it RUNS.

  `pre-push.sh`'s copy carried a second defect: it still used `print()`, whose trailing newline
  becomes CRLF on Windows while `$( )` strips only the LF — the surviving CR rides on `base`,
  fails to resolve as a ref, and a fresh marker reads as stale. `DECISIONS.md` had recorded that
  fix as landed since 2026-08-02; it had only ever landed in `gate-check.sh`. That paragraph is
  now corrected in place.

  Fix: both copies capture jq's output, check its status, and fall through to python3 — and
  **A19 asserts the two function bodies are byte-identical**, which is the part that matters.
  The duplication is deliberate (separate entry points, no shared library), so drift is its
  standing cost, and a note in a decisions file demonstrably does not contain it. Pinned by A18
  (gate-check) and P14 (pre-push), both with an ungated-branch control so an early-exiting hook
  cannot read as a pass. All mutation-tested: reverting either copy reddens exactly the
  assertions that name it, and nothing else.

  Known blind spot, disclosed rather than papered over: the `print()` half is **not observable on
  POSIX** — `$( )` strips the LF, so both forms produce identical bytes on Linux and macOS. It is
  covered only indirectly, by A19's byte-parity check.

- **P2: `forgeward-diff-hash.sh` produced a DIFFERENT hash under `jq` than under the
  `python3` fallback.** Fixed 2026-08-06, shipped in 0.7.5. Full entry in `DECISIONS.md`.

  `jq -S` pretty-prints while `json.dumps` used compact separators, so the canonical
  snapshot of the same manifest was different bytes on a machine with jq and one without,
  and a marker written on either read as stale on the other. A second divergence sat behind
  it: without `-a`, jq emits raw UTF-8 where `json.dumps` defaults to `ensure_ascii=True`.
  Fix is `jq -S -c -a` on both invocations, verified by fuzzing the two branches against
  each other rather than reading the flag docs.

  Two things worth carrying forward. First, V5/V6 pinned that the fallback has the same
  *semantics* and passed throughout, because each compared a branch only against itself —
  the new V7 compares them to EACH OTHER, and mutation-testing confirms V5/V6 stay green
  under the reverted fix while V7 goes red. Second, the accepted cost: every marker in every
  repo re-gates once at this version, not just plugin repos, which is why it shipped alone
  and why V4 was reframed from a back-compat assertion to a payload-assembly one rather than
  having its expected value quietly updated.

  Not fixed, disclosed instead: number literals still diverge (`jq` preserves source text,
  python normalizes through float) and cannot be aligned, because `json.dumps` calls
  `float.__repr__` directly and ignores a subclass. Unreachable for manifests that carry
  versions as strings. Pinned by V8 as a known divergence.

- **P1: `supply-chain-reviewer` returned PASS without ever checking dependency CVEs when
  gstack was absent.** Fixed 2026-08-05, shipped in 0.7.4.

  The agent deferred by name — *"gstack's `/cso` Phase 3 already covers dependency CVEs,
  install-scripts, and lockfile integrity — do NOT re-do those"* — unconditionally, so on
  a machine with no `/cso` nobody checked them and the reviewer returned clean. Live
  coverage hole in shipped code, not a proposal.

  Fix: `scripts/forgeward-detect-gstack-skill.sh <skill>` answers "is this gstack skill
  installed here?" deterministically and fails closed — exit 0 only for a directory named
  `<skill>` or `<prefix>-<skill>` holding a `SKILL.md` whose *frontmatter* carries the
  `(gstack)` marker. `supply-chain-reviewer` now runs it before reading the diff and
  declares `SUPPLY-CHAIN MODE: DEFERRED` or `FULL` on its first output line; FULL adds
  CVEs, install/lifecycle scripts, and lockfile integrity, scoped to dependencies the
  diff adds or version-changes. A script rather than a prompt instruction because an LLM
  judging "is gstack installed?" per run fails silently in the permissive direction —
  the exact fail-open shape `json_get`, `strip_quoted` and `marker_get` were each burned
  by. Pinned by D1–D12 in `test/gate-test.sh` (137 pass), and the three arms were
  mutation-tested: dropping the marker check reddens D4/D9, dropping the prefix arm
  reddens D2, refusing symlinks reddens D6.

  What this did NOT fix, stated because the evidence is broader than the remedy: the
  evidence is about the *deferral pattern*, the fix closes exactly one instance of it.
  The Option B posture statement and the untested standalone `/ship` handoff are still
  open above. Detection sees presence, never diligence — gstack installed and never
  invoked is indistinguishable from gstack covering the axis — and it cannot see a
  substitute such as Dependabot or a CI SAST job. Accepted cost: the same diff can FAIL
  standalone and PASS with gstack present.

- **P1: the intermittent "fail-open" reproduces from a false negative in the test
  harness's own `denies()` helper, not from the gate.** Fixed 2026-08-03.

  Scope of the claim, stated precisely because the whole item was a lesson in this:
  the harness defect is PROVEN and it produces exactly the observed symptom. The two
  original 0.7.2 sightings were not instrumented, so they cannot be retroactively
  attributed with certainty — what can be said is that every detail recorded about
  them fits this mechanism, and no evidence now points at the gate. The S7 forensics
  block stays in the suite precisely so a genuine gate fail-open, if one ever occurs,
  is identified in one run instead of costing another investigation.

  `denies()` was `printf '%s' "$1" | grep -q '...'` under this suite's `set -o
  pipefail`. `grep -q` exits the instant it matches, closing the read end while printf
  may still be writing; printf takes SIGPIPE and exits 141; pipefail promotes that to
  the pipeline's status. The helper reports NO-DENY on output it just matched. Every
  deny assertion in the file ran through it, so a scheduling hiccup surfaced as an
  intermittent GATE fail-open — which is why staring at the gate never explained it.

  Observed, not inferred: `PIPESTATUS=(141 0)` (printf killed, grep MATCHED) 7 times in
  20000 under fork pressure and 0 times on a quiet box — `test/denies-race-probe.sh`.
  A 3000-iteration run of `test/matcher-flake-probe.sh --load 16` reproduced 4 "fail
  opens" whose captured hook output was a perfectly well-formed DENY; that captured
  output is what redirected the investigation away from the gate.

  It fits every recorded data point: the fail direction; two sightings inside one
  ~5-minute window (a load spike); the isolated S5→S7 replay clean 15/15 on a quiet
  box; 17/17 and 22+ clean runs likewise; and the companion `dependency added -> hash
  CHANGED` assertion passing both times, because that one is a pure bash string
  comparison with no pipe in it. The earlier estimate of a "~8% rate" was measuring
  machine load, not the gate.

  Fix: `case` glob, which forks nothing and so can neither lose the race nor fail to
  exec. Applied to `denies()` in `test/gate-test.sh`, the same shape in the P2
  assertion of `test/pre-push-test.sh`, and both new probes. (References here are by
  symbol, not by line: the `test/gate-test.sh:398` in the original entry was stale
  before it was ever acted on.) A repo-wide sweep found no other
  instance; product code's one `grep -q` reads a FILE, not a pipe. The general rule:
  only an EARLY-EXIT reader (`grep -q`, `head`) can orphan its writer — `jq` and
  `python3` drain to EOF, so those pipelines are unaffected.

  Verification: the replacement measured 0 misses in 20000 under the same load that
  produced 7 with the old form. The full suite then ran 40 times under 12 fork-pressure
  workers (sustained loadavg ~20, ~4900 assertions) with zero failures — a harsher
  condition than the one that produced the single pre-fix failure, which landed on a
  comparatively quiet box. Record the load, not just the run count: a clean sweep on an
  idle machine is the weak version of this experiment, which is why
  `test/s7-flake-loop.sh` now takes `FORGEWARD_S7_LOAD`. (2026-08-03)

- **The gate DID have a real fail-open, found while chasing the above, and it is not
  the one that was being chased.** Two silent `exit 0` paths in
  `forgeward-gate-check.sh`, both deterministic under a helper that FAILS AT RUNTIME:

  1. `json_get` ran `jq -r ... 2>/dev/null` with stderr AND exit status discarded, so
     "jq failed to run" and "the field is absent" were the same observation. The empty
     command died at the pre-filter and the hook exited 0 without ever reading a
     marker. `command -v jq` still succeeded, so the python3 branch was never reached:
     being INSTALLED was treated as being FUNCTIONAL. Now the status is checked and a
     failed jq falls through to python3.
  2. The `strip_quoted` residue guard rescued only a COMPLETELY EMPTY result, so a
     TRUNCATED one was scanned as though whole and the verb could fall off the end of
     it. A7 pins awk MISSING (exit 127 → empty → rescued); nothing pinned awk
     truncating. Now the residue is trusted only if it is at least as long as the
     input, which the one-for-one substitution in `strip_quoted` guarantees.

  Never observed in the wild — found by reading, then demonstrated deterministically
  with `test/helper-failure-probe.sh` (three shapes, all ALLOW before, all DENY after).
  Pinned by A13/A14/A15.

  The length guard in (2) carries its own risk in the opposite direction: if
  `strip_quoted` ever stops substituting one-for-one, the fallback fires on ordinary
  commands and merely-MENTIONED verbs start denying. A16 pins that, covering the
  multi-line and trailing-newline shapes most likely to break the assumption and not
  covered anywhere else. A trailing newline survives the round trip only because the
  command substitution that EXTRACTS the command strips it too, so both sides shorten
  together — asserted rather than reasoned about, since that symmetry could quietly
  change.

  A16 was mutation-tested rather than merely observed passing: relaxing the guard to
  `-le` (always fall back to raw text) turns it red along with A2/A4/A5/A10/A11/A12,
  so the invariant is pinned from several directions and the new test is not vacuous.

  The guard's comment originally claimed `strip_quoted` "substitutes one-for-one,
  nothing is ever dropped". The 0.7.3 security review fuzzed that (600k+ trials,
  gawk/mawk/busybox) and FALSIFIED it: two shapes return a LONGER residue — a dangling
  backslash ending an unterminated double-quote, and multi-byte UTF-8 inside quotes
  under a byte-oriented awk (17 out of 15). Nothing returns a SHORTER one except real
  awk failure. The guard only ever needed NEVER-SHORTER, so it stands; the comment now
  states that property instead of the false stronger one, and A17 pins the
  byte-oriented-awk behaviour (skipped when neither mawk nor busybox is installed, so
  the suite's "no extra test runtime" footprint is unchanged).
  Suite 125/125, pre-push 14/14. (2026-08-03)

- **`forgeward-detect-base.sh` paid a `gh repo view` network call on every run.**
  Fixed in 0.7.2: step 1 is guarded on a remote carrying a network URL, so scratch
  repos with no remote or a filesystem-path remote skip it. A short-circuit, not a
  reorder — with a real remote the call still fires first and still wins. Suite time
  on the same 104 assertions, three runs each: unguarded 114s / 201s / 93s, guarded
  29s / 33s / 37s. B14's five assertions pin both directions, including the positive
  control that a networked remote still reaches `gh`, and the suite makes no real
  network call at all now (a stub `gh` answers). (2026-08-03)
- **`forgeward-diff-hash.sh` neutralized the version field in root `package.json`
  only, so every plugin release forced a spurious re-gate.** Fixed in 0.7.2: the
  canonical-snapshot treatment now covers `.claude-plugin/plugin.json` (top-level
  `.version`) and `.claude-plugin/marketplace.json` (nested `.plugins[].version`),
  in both the `jq` and `python3` branches. Neutralization is targeted, never
  recursive, so an npm `overrides` entry nesting a `{"version": ...}` object cannot
  hide a dependency pin change. The extra payload sections are appended only when
  the files exist, so a repo with no `.claude-plugin/` hashes byte-identically to
  before and its markers survive the upgrade (pinned by V4). (2026-08-03)
- **Publish matcher over-denied on merely-mentioned commands.** Deferred explicitly
  in PR #6, PR #7 and PR #8 before landing. Fixed in PR #9 (0.7.1) by deciding
  MENTIONED vs ISSUED by quoting rather than substring: quoted spans are blanked
  and the plain test runs on the remainder. Four earlier attempts failed; the
  fourth's three consecutive command-substitution desyncs are why substitutions are
  now distrusted rather than parsed. 94 gate + 14 pre-push green on WSL and Windows
  Git Bash. (2026-08-02)
- **Gate markers accumulated forever, one per branch ever gated.** Fixed in PR #8
  (0.7.0): pruned on marker write, checked against `refs/heads` under the common git
  dir so a branch live in another worktree keeps its marker. 11s → 238ms on 1000
  dead markers. (2026-08-01)
- **Orphaned marker `fix/publish-matcher-quoting.json` pruned by hand.** `gc_markers`
  runs only on the marker-*write* path, so an orphan on a clean `master` never
  self-clears — there is no gate run to trigger it. (2026-08-03)

  What was completed here was the *instance*, not the condition, and the condition
  recurred on 2026-08-05 with `fix/supply-chain-cve-deferral.json` — costing a second
  investigation that ended at the same diagnosis. The behaviour is intended and stays:
  the orphan is harmless, self-clears on the next gate of any branch, and the
  alternative (sweeping from `gate-check` or `pre-push`) means deleting files during a
  push on a path that must fail open. What was missing was a statement of it where a
  reader would hit it, so it is now the fifth entry in the `BLIND SPOTS` list above
  `gc_markers()` in `scripts/forgeward-write-marker.sh`. Expect orphans; do not debug
  the sweep. (2026-08-05)
- **Two stale remote branches deleted** — `feat/route-posture-classification` and
  `feat/security-reviewer-redefinition-toctou`. Both squash-merged (as #5 and #4),
  patch-ids identical to their master twins, zero unique content. Deleted via
  `gh api`; SHAs `6cfdea6` and `31ca190` recorded in case either is ever needed.
  (2026-08-03)
