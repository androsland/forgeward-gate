# TODOS

Deferred engineering work for forgeward-gate, grouped by component then priority
(P0 highest → P4). `DECISIONS.md` remains the source of truth for *why* a design
is the way it is; this file tracks what is still owed. Items carry the source
that raised them and the date.

Every item here was raised in a merged PR body or a review round. PR bodies are
write-once and effectively gone after merge, which is why they live here now.

## Gate — test suite

- **`marker_get` discards jq's exit status the same way `json_get` used to.** A failed
  jq yields an empty `base`/`diff_hash`, `is_fresh()` returns 1, and the branch reads as
  ungated. That direction is fail-CLOSED — a spurious re-gate, never a missed one — so
  it is not the bug `json_get` was, and it is deliberately left alone rather than
  widening a security-relevant diff. Worth aligning for consistency: same three-line
  fallback to python3. (found while fixing the P1 fail-open, 2026-08-03) **Priority:** P3

## Gate — publish matcher

- **`strip_quoted`'s `st==2` backslash branch does `i += 2` with no bounds check**, so a
  dangling backslash at the true end of an unterminated double-quoted string emits two
  characters for one (`echo "\` → 8 out of 7). Found by fuzzing the awk during the 0.7.3
  security review (600k+ trials across gawk/mawk/busybox). NOT fixed, deliberately, and
  the reasons are worth keeping: the deviation is only ever in the LONGER direction so
  the residue-length guard is not defeated by it; the only input that reaches it is
  already a bash syntax error that executes nothing, a shape the matcher's own header
  already classifies as "NOT a gap"; and `DECISIONS.md` records three separate desyncs
  caused by editing this scanner, so a cosmetic correctness fix here is a poor trade
  against that history. Revisit only if the length arithmetic ever needs to be exact
  rather than one-sided. (0.7.3 security review, 2026-08-03) **Priority:** P3

- **`git push origin --delete <branch>` is denied when the current branch has no
  marker.** Deleting a ref is still a push, and the matcher deliberately does not
  parse command structure, so it cannot tell a ref deletion from a code publish.
  Hit for real on 2026-08-03 cleaning up two merged branches. Workaround needing
  no code change: `gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/<branch>`,
  which carries none of the matcher's verbs, then `git fetch origin --prune`.
  A fix means distinguishing `--delete` and `:refspec` from a code push — i.e.
  parsing flags and refspecs, the structural modeling `DECISIONS.md` calls a dead
  end after three failed rounds. Undecided whether the friction is worth it.
  (checkpoint item 3, 2026-08-02; confirmed live 2026-08-03) **Priority:** P3
- **Five disclosed under-matches remain by design**, pinned in test A4 so a
  behavior change fails the suite rather than quietly outdating the comment:
  the shell-wrapper family (`bash -c 'git push'`, eval/ssh/trap — the one genuine
  coverage reduction vs the old substring), the quoted command word (`'git' push`,
  `git pu''sh` — the latter defeats even the pre-filter), the synthesized separator
  (`git${IFS}push`), `git -C <path> push`, and indirection through a variable,
  alias, function or script. All pre-existing; the old bare substring missed every
  one. Not fixable without command-position analysis, which the file header calls
  a dead end. Kept here to record the decision, not as work. (PR #9, 2026-08-02)
  **Priority:** —

## Gate — base detection and freshness

- **`forgeward-diff-hash.sh` produces a DIFFERENT hash under `jq` than under the
  `python3` fallback**, because `jq -S` pretty-prints while `json.dumps` uses
  compact separators, so the two canonical snapshots are different bytes. A marker
  written on a machine with `jq` reads as stale on one without it (and vice versa),
  forcing a spurious re-gate. Pre-existing and fail-safe — it can only cause an
  extra gate run, never a false PASS — and confirmed present in the pre-0.7.2
  script too, so 0.7.2 neither introduced nor worsened it. Not folded into 0.7.2:
  aligning the two would change the hash for every repo, which is a one-time global
  re-gate and deserves its own PR. (surfaced while building 0.7.2, 2026-08-03)
  **Priority:** P2
- **The drive-letter arm in `remote_is_networked()` approximates git's third
  locality clause and diverges on DOS reserved device names.** git's real predicate is
  `!colon || (slash && slash < colon) || (has_dos_drive_prefix() && is_valid_path())`.
  The first two clauses are encoded exactly; the third is approximated by
  `[A-Za-z]:[/\\]*` gated on `uname -s`. On a native Windows build with the default
  `core.protectNTFS=true`, `is_valid_win32_path()` rejects a segment named for a DOS
  device (`aux`, `con`, `nul`, `com1`-`9`, `lpt1`-`9`) or ending in a space or period,
  so git dials SSH to a one-letter host while the pattern here says local — the
  dangerous direction. Needs native-Windows git plus a remote path with a literal
  device segment, which no GitHub/GHE/gitolite/gitea host produces and an attacker
  could only arrange by already owning `.git/config`. Not closed because the true
  clause depends on `core.protectNTFS` and the NTFS reserved-name table, neither
  reachable from bash without the Win32 API. Untested for the same reason: the B14
  table has no row for `X:/<dos-device>/…` because its correct answer depends on a
  config value the suite cannot read. (security review round 4, 2026-08-03)
  **Priority:** P3
- **The Windows half of B14's drive-letter assertion only runs on Windows.** The
  `uname -s` branch at `test/gate-test.sh` means a machine that is not MINGW/MSYS/CYGWIN
  silently takes the other expectation, so "a drive path is local on Windows" has no
  coverage unless someone actually runs the suite under Git Bash. That is done by hand
  before each release here and both legs were run for 0.7.2, but nothing enforces it.
  (security review round 4, 2026-08-03) **Priority:** P3
- **`forgeward-detect-base.sh` never runs `git fetch`**, so `origin/<base>` is only
  as current as your last fetch — the same class of error one level up, and
  structurally invisible from inside the script. It also infers the base from repo
  defaults, so it cannot know a PR targets a release branch or is stacked on
  another feature branch. Stated as a blind spot in the script header and
  `skills/gate/SKILL.md`; recorded here so the limit is not mistaken for coverage.
  (PR #6, 2026-08-01) **Priority:** —

## Reviewers

- **PR #4's two security rules were verified one run per fixture**, which shows the
  rules *can* fire reliably, not that they always will. Five fixtures, each a real
  git repo reviewed end to end, all passed — but repeated-run reliability is
  unestablished. (PR #4 "Not verified", 2026-07-21) **Priority:** P3
- **Route postures are capped on purpose.** A `paywalled`/metered posture (it needs
  its own specialist rulebook, and half-implementing it is worse than not claiming
  it) and an "indexed but no OG tags" posture (on an indexed site missing OG is a
  defect, already Medium/Low) were both excluded deliberately — each posture added
  is another chance to misclassify. Recorded as a decision, not work.
  (PR #5 "Deliberately excluded", 2026-07-23) **Priority:** —
- **The per-tool exemption in `forgeward-scan.sh` trusts `basename "$tool"`**, so an
  executable *named* `grype` that isn't grype inherits grype's `-o` overloading.
  Accepted as a documented limit rather than fixed: the wrapper runs `"$tool" "$@"`,
  so anyone able to plant that executable already has code execution here, making
  the file-write strictly weaker than what they already hold. Probing `--version`
  would not close it — a spoofed binary can print anything. In the script header as
  a blind spot. (PR #6, sixth security pass, 2026-08-01) **Priority:** —

## Standalone posture (no gstack installed)

Full analysis in `docs/axis-proposals.md` → "Later findings" §3.

- **`supply-chain-reviewer` returns PASS without ever checking dependency CVEs when
  gstack is absent.** The agent defers by name — *"gstack's `/cso` Phase 3 already covers
  dependency CVEs, install-scripts, and lockfile integrity — do NOT re-do those"* — so
  with no `/cso` present nobody checks them and the reviewer passes clean. This is a live
  coverage hole in shipped code affecting installs on machines we never see, not a
  proposal. Fix: make the deferral conditional on `/cso` being detected. **Priority:** P1
- **forgeward is scoped as a delta against gstack, so every deferral is a hole when
  gstack is absent.** README line 7 defines it as "a gate for gstack" and the reviewer
  table's third column is "why it's here (not redundant with gstack)". Decide Option A
  (declare gstack a hard dependency) or Option B (conditional deferral — recommended,
  because the six reviewers do work standalone). What is not acceptable is leaving it
  implicit. Gate mechanics themselves are verified gstack-free: `hooks/` and `scripts/`
  reference it only in comments and in `forgeward-diff-hash.sh`'s cosmetic-file
  exclusions, which stay inert standalone. (2026-08-05) **Priority:** P2
- **README makes two coverage claims that are false without gstack.** Line 45 ("a
  code-quality reviewer — gstack's `/review` covers it") and line 336 ("run gstack's
  `/cso` for a deep whole-repo audit"). An unstated limit reads as a claim of coverage,
  and this audience is exactly the people who are not us. **Priority:** P2
- **Under Option B, detect gstack at gate time and disclose — do not fail.** Name the
  unowned axes in the firing decision. Detection must handle custom `--prefix` install
  variants (README line 57), must stay silent when `.forgeward/config.yml` names a
  substitute (Dependabot/Snyk/CI SAST), and structurally cannot tell a configured tool
  from an installed-but-never-run one. **Priority:** P2
- **Record the detected environment in the pass marker.** Option B makes coverage
  environment-dependent, so the same plugin version means different things on two
  machines. The marker already carries `fired`; recording what the gate could and could
  not see makes that variance auditable from the artifact rather than invisible.
  **Priority:** P3
- **Untested: does the gate's Step 3 `/ship` handoff degrade or hard-fail with no
  gstack?** Flagged as likely-broken, not confirmed. **Priority:** P2

## Quality axis

Full analysis and decision rules in `docs/axis-proposals.md`.

- **gstack's `/review` and forgeward defer the quality axis to each other, and it runs
  nowhere.** On commit `04a04fb` the review log records `maintainability` skipped with
  `reason: "covered-by-forgeward-and-coverage-audit"` and `security` with
  `"covered-by-forgeward"`, while forgeward's README skips code-quality because
  `/review` covers it. Same shape as the `/cso` reversal. Scope: 2 of 22 review entries —
  an existence proof, not a measured rate. (2026-08-05) **Priority:** P2
- **`error-path-reviewer` — build blocking, pending a base-rate measurement.** Owns one
  question: *when this code fails, does anything notice?* Four rules (discarded failure
  signal, dead/unreachable error path, unchecked conditional-write result, resource leak
  on the error path), each needing a stated consequence to reach High. Decision rule:
  **≥1 true High per 5 PRs → build it blocking; below that → fold rules 1 and 3 into
  `security-reviewer` Step 3 instead.** Measure by applying the checklist by hand to the
  last 5 gated diffs across two repos. Must not fire on deliberate best-effort cleanup;
  structurally cannot see a *wrong* handler, only a missing one. **Priority:** P2
- **`marker_get` discarding jq's exit status is the third instance of the error-path
  class** (after `json_get` and `strip_quoted`, both fixed in #11) and is the reviewer's
  first fixture. Tracked separately below. (2026-08-05) **Priority:** —
- **The review-ran check — warn-only, never blocking on a first version.** Gate on
  whether a quality pass ran rather than reimplementing quality. Match `skill:"review"` +
  `commit` + specialists dispatched, and **treat a missing `via` as standalone** — a
  standalone `/review` logs from `review/SKILL.md:1805` with no `via` key, while `/ship`
  logs from `ship/sections/review-army.md:395` with `"via":"ship"`. Keying on
  `via:"ship"` would fail exactly the people who ran `/review` correctly. Cannot block,
  because both call sites are model-executed prompt steps: a review that happened can
  leave no entry, which under-counts a measurement but manufactures false FAILs in an
  enforcement. **Priority:** P3
- **`/review` never writes `VERSION`, which reopens a cheaper handoff than `/ship`.**
  Every occurrence in `review/SKILL.md` is a read or a display string, and
  `bin/gstack-next-version` writes only to stdout. Version bumping is the sole reason
  this repo refuses the `/ship` handoff, and it does not apply to `/review`. Constraint:
  `/review` holds Edit/Write and auto-fixes, so it cannot run inside the read-only gate —
  correct order is `/review` first, then gate. (2026-08-05) **Priority:** P3
- **Gate-run logging.** Append the fired reviewer set plus verdict rather than
  overwriting/pruning, so "gate ran, `/ship` didn't" becomes measured instead of inferred
  from marker file counts. **Priority:** P3
- **A `DECISIONS.md` entry either way on the quality axis.** "Delegate quality to
  `/review`" is a recorded decision; the work above either reverses it or re-affirms it
  on a **new** basis (embedded-in-`/ship`, not standalone). The `/cso` reversal set that
  precedent. **Priority:** P3

## Property-based testing

- **Build `/forgeward:properties` as an on-demand skill, never a 7th reviewer.** Shaped
  like `ci-gate` (`disable-model-invocation: true`, writes files, outside the enforced
  gate). A "no property test" finding is a claim about test style with no stated
  consequence — it would be the first forgeward FAIL that is not falsifiable — and its
  remediation is a dependency change that trips `supply-chain-reviewer`. Durable output
  is each shrunk counterexample committed as a deterministic regression test; measure
  success in those, and delete the skill if there are none after a month. Must not fire
  on orchestration/glue diffs. Structurally cannot see that a stated invariant is itself
  wrong. (`docs/axis-proposals.md` → Q1, 2026-08-05) **Priority:** P3

## ci-gate

- **The end-to-end gated-e2e chain is not proven in one continuous run.** All three
  legs are individually verified — gate pattern proven in real CI, the skill
  generates that exact pattern (equivalence-verified byte-for-byte), and
  activate-and-run-green confirmed on a real Actions run. What remains is
  "skill emits the job on a never-touched case-2 repo and it goes green" in a
  single chain, which awaits a fresh case-2 repo; none exists in the fleet
  (nutriloop, the only hosted-public repo, was hand-tuned). Already disclosed in
  `README.md:186`. Blocked externally, not by code. (PR #1, 2026-06-25; inherited
  by `ci-gate` via `5d676ba`) **Priority:** P3

## Enforcement boundary

- **The local gate is strong, not indestructible, and this is by design.**
  `git push --no-verify` skips the pre-push hook; the marker is a local file that
  can be forged; git hooks are not cloned, so the hook needs re-installing per
  clone and after a plugin update. No purely-local gate escapes these. The
  unbypassable boundary is the server-side `/forgeward:ci-gate` (required checks +
  branch protection), which ships. Recorded so the residual is not rediscovered as
  a bug. (PR #2, 2026-07-16) **Priority:** —
- **The PreToolUse artifact deny only protects once installed.** Hooks run from the
  installed plugin cache, not a working tree, so a guard in an unreleased version
  does nothing until that version is installed — verified the hard way when the
  first probe of a new guard came back "not denied" because the live hook was the
  previous build. Layers 1, 3 and 4 need no install. (PR #6, 2026-08-01)
  **Priority:** —

## Housekeeping

- **Local tag `item2-wip-quote-stripping`** preserves the third failed attempt at
  the publish matcher (quote-stripping via bash extglob — correct but superlinear
  in quote density, 63s on 3KB of quote-dense input). Superseded by the 0.7.1
  awk-based design. Decide whether to keep it as an archaeological record or drop
  it. (PR #8, 2026-08-01) **Priority:** P4
- **The three merged PR bodies #1, #2 and #3 carry a `🤖 Generated with Claude Code`
  byline.** Cosmetic and historical; noted only so it is a deliberate choice to
  leave them rather than an oversight. Newer PRs do not carry it.
  (observed 2026-08-03) **Priority:** P4

## Completed

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
- **Two stale remote branches deleted** — `feat/route-posture-classification` and
  `feat/security-reviewer-redefinition-toctou`. Both squash-merged (as #5 and #4),
  patch-ids identical to their master twins, zero unique content. Deleted via
  `gh api`; SHAs `6cfdea6` and `31ca190` recorded in case either is ever needed.
  (2026-08-03)
