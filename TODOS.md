# TODOS

Deferred engineering work for forgeward-gate, grouped by component then priority
(P0 highest → P4). `DECISIONS.md` remains the source of truth for *why* a design
is the way it is; this file tracks what is still owed. Items carry the source
that raised them and the date.

Every item here was raised in a merged PR body or a review round. PR bodies are
write-once and effectively gone after merge, which is why they live here now.

## Gate — test suite

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

- **`git push --no-verify` is denied by the fast reminder even though the pre-push hook
  documents it as a deliberate, visible opt-out.** The same direction of disagreement the
  deletion exemption just fixed: the enforced layer offers an escape hatch and the fast
  layer refuses to let you type it. Deliberately NOT fixed in 0.9.1 — exempting it in the
  text layer turns "bypass the gate" into four words with no reviewer and no marker, which
  is a strictly worse trade than the friction. Recorded so the asymmetry is disclosed
  rather than latent; the right fix, if any, is a first-class opt-out with its own audit
  trail, not a matcher hole. (0.9.1 deletion exemption, 2026-08-07) **Priority:** P3
- **The deletion exemption knowingly over-denies five shapes.** All fail CLOSED, all cost
  the user a `gh api -X DELETE` or a gate run, none let a publish through: a quoted flag
  (`git push origin '--delete' x` — `strip_quoted` blanks the span, so by the time the
  exemption looks there is nothing there); a `$VAR`/`$(…)`/backtick anywhere in the
  command (the residue is untrusted, so the exemption is refused outright); bundled short
  flags (`-qd` is one token and matches neither `-q` nor `-d`); any option outside the
  whitelist, e.g. `-o ci.skip` or `--force-with-lease`; and a `sudo`/`time`/`env` prefix.
  Widening any of them means either parsing quoting the layer has deliberately refused to
  parse, or enumerating git's full option table with its value-taking arity — both are the
  structural modeling `DECISIONS.md` calls a dead end. Kept as a record of the boundary,
  not as work. (0.9.1 deletion exemption, 2026-08-07) **Priority:** P4
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

Full analysis in `docs/axis-proposals.md` → "Later findings" §3. **Option B shipped in
0.8.0** — see `## Completed`. What follows is what it did *not* close.

- **Nothing validates `.forgeward/config.yml` or warns on an unknown key, so a typo is
  indistinguishable from an absent key.** `substitues:`, `postures:`, an invalid posture
  value, an unterminated flow sequence (`[a, b`) — every one reads as "not configured" and
  produces exactly the output of a repo with no config at all. The direction is right (a
  refused shape costs a disclosure you already answered, never a skipped check) but the
  silence is not: the user has no way to tell a config that was read and understood from one
  that was read and discarded. The cheap version is a `config_warnings` count in the probe's
  JSON that the gate renders as one line; the expensive version is a real schema. Note the
  probe emits JSON with no channel for prose, so this is a shape change, not a `printf`.
  (0.9.0, 2026-08-06) **Priority:** P2
- **`seo.routes` is documented and unread, now deliberately and in writing.** 0.9.0 wired
  `seo.posture` and declined the per-route mapping: glob keys in a flow mapping need the YAML
  parser the reader exists to avoid. All three mentions (README, `skills/gate/SKILL.md`,
  `agents/seo-reviewer.md`) now say it has no effect, so this is a disclosed gap rather than
  a broken promise — but a repo with a marketing site and an app on one origin genuinely
  wants it, which is the case the whole posture-per-route-group design is built around.
  Reopening it means taking a YAML dependency outright, not growing the awk.
  (0.9.0, 2026-08-06) **Priority:** P3
- **The marker's `schema` field is written by nothing-reads-it, and so is `environment`.**
  Grepped: outside its own write site and its comment, the only reader of `schema` anywhere
  is E10 — a test asserting it equals the current number. No freshness check consults it,
  no hook refuses a push over it, and before 0.8.0 nothing read it at all. So the 2 → 3 → 4
  bumps are provenance, not a compatibility mechanism,
  and they cannot protect a future reader from an old marker. If a marker format change ever
  *does* need to be enforced, the version field has to start being read first — and the
  fail-safe direction is already available for free (an unrecognised schema should read as
  stale, which costs one re-gate). (0.8.0, restated 0.9.0 2026-08-06) **Priority:** P3
- **The probe and the marker writer are now coupled, and the coupling is a standing
  maintenance obligation.** `forgeward-write-marker.sh` validates the probe's output against
  its *complete literal shape*, anchored at both ends — chosen over a jq/python3 structural
  parse so the push-authorizing write path keeps needing no external tool (and because a
  generic "is this an object" test would still accept `{"passed":false}`). The cost: **any new
  field added to `forgeward-detect-environment.sh` must be added to that regex in the same
  commit**, or every marker silently records `environment: {"probe":"unavailable"}`. The
  failure is safe — provenance is lost, enforcement is not — and E10 goes red on it, which is
  the only reason it is not silent. Anyone touching the probe's output should read the comment
  above `_env_ok` first. Revisit if the probe grows past a handful of fields: at that point the
  regex stops being readable and taking the parser dependency becomes the better trade.
  (security review, 2026-08-06) **Priority:** P2

  **A second obligation was found the first time this was exercised** (0.9.0 added
  `seo_posture`): **E17's hardcoded payload must be updated in the same commit too.** That
  assertion pins the shape match's *trailing* anchor by feeding it the probe's genuine output
  plus an appendix — which only tests the anchor while the opening bytes are a shape `_env_ok`
  would otherwise accept. A stale payload is rejected on its prefix instead, and dropping the
  `$` stops turning it red. Verified in both directions by mutation. So a new probe field is
  now a **three**-file edit, and the third is the one whose omission is silent: `_env_ok`
  failing loses provenance and reddens E10, while a stale E17 reddens nothing at all and
  quietly retires a security assertion. (0.9.0, 2026-08-06)
- **The `awk` call is not locale-pinned, while the `wc -c` three lines above it is.**
  `forgeward-detect-environment.sh:103` runs `LC_ALL=C wc -c`; line 112 runs a bare `awk`.
  Nothing explains the asymmetry, in a file where every other asymmetry is documented. It
  matters because both the CRLF handling and the charset filter depend on character-class
  semantics: `\r ∈ [[:space:]]` is what makes a Windows config parse at all, and
  `[A-Za-z0-9_-]` is a *range*, whose members are collation-dependent outside the C locale.
  `LC_ALL=C` would make both byte-exact and is strictly the safer direction. Verified clean
  on gawk 5.1.0 under `C.UTF-8` and forced `LC_ALL=C`; no locale was found where it breaks,
  which is why this is P3 rather than a fix. Note what it means for the tests: **E18 asserts
  "works under the test runner's locale", not "works everywhere"** — it cannot pin what the
  script does not pin. Deliberately NOT fixed in 0.8.0: the change is one token, but the
  script had just been cleared by a security pass and editing it afterwards to chase a
  non-finding trades a reviewed artifact for an unreviewed one. Fix it and re-fire together.
  (security review, 2026-08-06) **Priority:** P3
- **The config check is TOCTOU by construction, and that is accepted, not overlooked.**
  `[ -L ]`/`[ -f ]`/`[ -r ]` run at `forgeward-detect-environment.sh:97-99`, but `wc -c` and
  `awk` read the file afterwards, so a process with concurrent write access to the checked-out
  tree could swap a regular file for a symlink inside that window. Raised by the 0.8.0 security
  review as informational and explicitly *not* filed as a finding: the attacker must already
  have local write access to the same checkout while the gate runs, which implies code
  execution, and the outcome is still bounded by the 64-byte/32-item/ASCII-only sanitizer and
  the marker's own `_env_ok` gate downstream. Recorded here only so a future reader finds the
  decision instead of rediscovering the gap and assuming it was missed. Closing it properly
  means opening the file once and working from that handle — not worth the portability cost
  today. (security review, 2026-08-06) **Priority:** P4
- **The symlink refusal knowingly breaks a legitimate configuration.** A monorepo that
  symlinks `.forgeward/config.yml` to a shared config elsewhere in the tree is ignored (reads
  `unreadable`, so the disclosure still fires) and must use a regular file. The containment
  alternative was declined on portability (`readlink -f` is absent from the bash 3.2/macOS
  environments this repo targets), not on principle; a portable resolver would reopen it.
  **The documentation half is closed** — 0.9.0 added a `.forgeward/config.yml` section to the
  README stating the refusal, the honoured keys, and the shape limits, so this is no longer
  discovered from behaviour. The broken configuration itself stands.
  (security review, 2026-08-06; documented 0.9.0) **Priority:** P4
- **Disclosure is specified in a skill, so nothing tests that it actually happens.** E1–E18
  pin the *probe*; the decision to print `NOT COVERED: quality` lives in
  `skills/gate/SKILL.md` Step 1c and is executed by a model. The same is true of every
  other instruction in that file, so this is not a new class of gap — but it is the reason
  the probe was built as a script with its own exit contract rather than as prose, and the
  remaining half is untested by construction. The live-test in `live-test/` is where this
  would be caught, and it is manual. (0.8.0, 2026-08-06) **Priority:** P3
  **Partly closed 2026-08-06:** `live-test/LIVE-TEST.md` §5b was executed against installed
  0.9.0 and the model half held — posture reported as pinned, `seo.routes` called out
  unprompted, privacy fired on a markup-only diff. The `NOT COVERED` half is the piece still
  owed a real run; see the item below.
- **§5b's `substitutes` assertion cannot be tested on a machine that has gstack.** It asserts
  that `NOT COVERED: quality` is *absent* because the substitute answered it — but on a
  gstack-present box that line is absent regardless, so the assertion passes vacuously. The
  2026-08-06 run worked around this by pointing `CLAUDE_CONFIG_DIR` at an empty directory,
  which exercises the probe's detection correctly but is a simulation, not the real
  condition. Re-run §5b on a genuinely gstack-free machine when one is to hand. This is the
  general shape of every standalone-posture assertion, not a quirk of this one.
  (live-test run, 2026-08-06) **Priority:** P3

## Quality axis

Full analysis and decision rules in `docs/axis-proposals.md`.

- **gstack's `/review` and forgeward defer the quality axis to each other, and it runs
  nowhere.** On commit `04a04fb` the review log records `maintainability` skipped with
  `reason: "covered-by-forgeward-and-coverage-audit"` and `security` with
  `"covered-by-forgeward"`, while forgeward's README skips code-quality because
  `/review` covers it. Same shape as the `/cso` reversal. Scope: 2 of 22 review entries —
  an existence proof, not a measured rate. (2026-08-05) **Priority:** P2

  **Still open after 0.8.0, and only half-narrowed.** Option B made the *gstack-absent*
  half explicit — the gate now discloses `quality` as unowned. It does nothing about this
  entry's actual finding, which is the **gstack-present** case: `/review` defers to
  forgeward while forgeward defers to `/review`, so both installed still means nobody
  reviews quality, and no disclosure fires because `gstack_review` reads `present`. The
  probe sees presence, not diligence, and this is exactly the blind spot that phrase
  names. (0.8.0, 2026-08-06)
- **`error-path-reviewer` — MEASURED 2026-08-06, and the decision rule says fold, not
  build.** Owns one question: *when this code fails, does anything notice?* Four rules
  (discarded failure signal, dead/unreachable error path, unchecked conditional-write
  result, resource leak on the error path), each needing a stated consequence to reach
  High. Decision rule was **≥1 true High per 5 PRs → build it blocking; below that → fold
  rules 1 and 3 into `security-reviewer` Step 3 instead.** Result: **0 true Highs per 5
  PRs in both repos**, and 0.25/5 even on an extended forgeward window. Rules 2 and 4
  fired zero times anywhere — they are not carrying weight and should not be folded.
  So: fold rules 1 and 3, do not build a seventh reviewer. **Priority:** P2
- **The fold needs `security-reviewer` Step 3 to learn fail-open/fail-closed first.**
  Checked directly: Step 3 contains **no** occurrence of fail-open, fail-closed, or a
  consequence-statement requirement. It already carries a near-equivalent of rule 3
  ("Check-then-act without a lock, and the silent no-op"), complete with the right
  discipline — High only if you can state the interleaving — so rule 3 folds cleanly by
  analogy. Rule 1 has no counterpart at all, and dropping it in without the distinction
  would produce a bullet that cannot say which direction a discarded status fails in,
  which is the entire question. Add the vocabulary, then fold. (2026-08-06) **Priority:** P2
- **The base-rate measurement structurally under-counts this class, and the 0.7.6 work is
  the proof.** The method was a by-hand pass over merged diffs, and it scored 0 — while the
  same session found two live instances (`json_get`'s python arm, `marker_get` ×2) that a
  diff-reading pass cannot see, because each is only visible when two arms of one helper
  are read *together*, and one of them was silently cancelling the #11 fix to the arm
  beside it. Four known instances in ~40 files — `json_get` ×2, `strip_quoted`,
  `marker_get` — three shipped, two surviving a round (#11) explicitly aimed at them.
  See Completed for both 0.7.6 fixes. This does not overturn the fold decision — a reviewer
  that also reads diffs would have scored the same 0 — but it is the reason the fold should
  not be treated as "the class is rare." Weigh it if the axis is ever rescored.
  (2026-08-06) **Priority:** —
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
- **The `actions/checkout` SHA pin has no refresh policy, which is the other half of pinning.**
  `.github/workflows/version-check.yml` pins `11d5960a326750d5838078e36cf38b85af677262` (`v4`,
  resolved by `git ls-remote --tags` on 2026-08-06, not recalled). A SHA cannot be repointed
  under us — and equally cannot pick up a security fix, so an unrefreshed pin decays into a
  stale-action problem, which is the failure mode a tag does not have. Nothing currently
  notices when GitHub cuts a new `v4.x`. Dependabot's `github-actions` ecosystem is the
  standard answer and would be this repo's second CI-adjacent config; the cheap manual version
  is re-running that `ls-remote` at release time. Undecided which. (CI version check,
  2026-08-06) **Priority:** P3
- **Locale pinning should be a repo-wide convention, not a per-script decision — this file now
  has four entries about it and one of them was a High.** The `num_lt` bullet that used to sit
  here said `LC_ALL=C` was hardening whose effect was unobservable, at P4. That framing was
  wrong, and round 3 of the security review showed how: the *collation* effect really was
  unobservable, but the same variable also governs whether `grep` will match `[^"]*` across
  invalid UTF-8, and under the ambient locale it will not — which was a complete bypass of the
  ambiguity guard (fixed, see `DECISIONS.md`). An "unobservable" label on a locale pin is
  therefore only ever a statement about the *one* effect that was measured. Still unpinned:
  `forgeward-detect-environment.sh:112`'s bare `awk`. The convention to settle on is probably
  `export LC_ALL=C` at the top of every non-interactive script in this repo, since none of them
  produce human-language output; `ci/check-version-monotonic.sh` is the first to do it.
  **Round 4 sharpened this rather than settling it:** replacing that script's `grep` reader with
  a JSON parser removed the invalid-UTF-8 effect entirely (parsers are locale-independent), so
  the pin there is back to guarding only the unobservable collation case. Read the wrong way
  that is an argument to drop it; read correctly it is the argument *for* the convention — the
  pin's value was never in any one measured effect, it is that a non-interactive script should
  not have its behaviour depend on the invoker's environment at all. The next script to be
  bitten will be bitten by a third effect nobody has enumerated either.
  (security review round 3, 2026-08-07; updated round 4, 2026-08-07) **Priority:** P2
- **Manifest *validity* is now covered as a side effect, and nothing covers manifest
  *meaning*.** This entry was opened at P3 when the reader was textual; round 4 replaced it with
  `python3`'s stdlib `json`, so a manifest that is not well-formed JSON or not valid UTF-8 is
  now refused by name for all three files — that half is **done**, and the previous framing
  ("no jq dependency, so this can't be cheap") no longer describes the code. What remains is
  narrower and worth keeping separate: the check validates the version *field*, not the
  document. A manifest can parse cleanly, carry a perfectly ordered version, and be semantically
  nonsense — `plugin.json` missing `name`, `marketplace.json` with an empty `plugins` array,
  a `source` pointing somewhere that does not exist. Nothing in this repo would notice. Schema
  validation is a different job from direction checking and should be a separate CI step if it
  is wanted at all; the argument against is that these three files change perhaps twice a
  release and a bad one is caught the first time the plugin is installed.
  (security review round 3, 2026-08-07; re-scoped after round 4, 2026-08-07) **Priority:** P3
- **`ci/check-version-monotonic.sh` now requires `python3`, and that obligation is documented
  in exactly one place — its own header.** It is the only external tool any script in this repo
  needs, and it is deliberate (see `DECISIONS.md`: stdlib `json` only, one arm, no `jq`
  fallback, because two readers of the same JSON that can disagree is the diff-hash divergence
  bug rebuilt on purpose). The check fails closed with a named message when it is absent, so
  nothing silently skips. What is *not* settled: `README.md` and `CONTRIBUTING`-equivalent docs
  do not mention it, so a contributor running `npm test` on a python-less box gets a clear
  failure from the check and no prior warning. Also worth deciding once rather than per-script:
  whether python3 is now an accepted repo-wide dependency for **CI-only** code while
  user-machine scripts stay tool-free — that split is the actual rule being followed, and it is
  currently implicit. Round 6 narrowed the dependency slightly: the call is now `python3 -I`, so
  the floor is Python 3.4 (2014). An interpreter too old to accept the flag fails closed with
  its own error plus `returned no usable answer` — verified against a PATH shim that rejects
  `-I`, not assumed. (CI version check rounds 4 and 6, 2026-08-07) **Priority:** P3
- **`grep` in this repo can return nothing for two unrelated reasons, and both have now cost an
  investigation.** (1) At an interactive prompt `grep` here is a **shell function shimming to
  ugrep 7.5.0**; a script gets `/usr/bin/grep`, GNU grep 3.7 — different programs with different
  invalid-byte behaviour, which nearly inverted the round-3 fix (`DECISIONS.md`). (2) A **single
  NUL byte** anywhere in a file makes GNU grep answer `binary file matches` instead of the
  matching lines, and makes the ugrep shim return **nothing at all** — indistinguishable from
  "no matches", which is exactly how a grep of `test/version-check-test.sh` came back empty and
  produced a wrong conclusion about its own contents.
  **Half of this is closed and half is not, and the split matters.** The NUL half is pinned:
  R21 sweeps **every tracked file** via `git ls-files` (41 files, no binary member) and asserts
  the enumeration is live before trusting the sweep. It was scoped to two files first, then
  five, and a new NUL landed outside the list *both* times -- the trigger is "someone is writing
  about control bytes", not "someone is editing the check", so any narrower scope is the wrong
  shape. A repo that later adds a real binary asset needs an allowlist there.
  **What is still open:** R21 runs only inside `test/version-check-test.sh`, which runs only
  when someone runs `npm test` by hand -- see the CI item below, which is the real dependency.
  And nothing pins the *shim* half at all: a script and a prompt resolving `grep` to different
  binaries is a property of this machine that no assertion in this repo can see. The habits that
  prevent both are spelling a control byte as `\u0000` and never as itself, and reaching for
  `/usr/bin/grep` explicitly when the answer matters. (security review rounds 3 and 5,
  2026-08-07) **Priority:** P3
- **Nothing else in this repo that reads a repo-relative path has been audited for symlink
  following, and round 7 says that is the wrong state to leave it in.** The CI check now reads
  manifests out of the object store; `scripts/forgeward-gate-check.sh`,
  `scripts/forgeward-pre-push.sh`, `scripts/forgeward-diff-hash.sh` and the marker machinery all
  still open paths off the filesystem. **The threat model is genuinely different and that is the
  reason this is P3 and not P2:** those run on the user's own machine against the user's own
  checkout, where an attacker who can plant a symlink can also edit the file directly, forge a
  marker, or pass `--no-verify` — all of which this file already documents as defeating the local
  gate. The CI check was the escalation because a *fork* author can commit a symlink and has no
  other access. So this is a sweep for consistency and for the day one of those scripts moves
  into CI, not a live bypass. Whoever does it should check the marker path too: a marker file
  replaced by a symlink is the shape most likely to matter. (security review round 7, 2026-08-07)
  **Priority:** P3
- **Four shipped `python3 -c` sites outside this branch have the same CWD-on-`sys.path`
  exposure that round 6 closed in the CI check, and none of them carries `-I`.**
  `scripts/forgeward-diff-hash.sh:100`, `scripts/forgeward-gate-check.sh:75` and `:119`, and
  `scripts/forgeward-pre-push.sh:72` all run `python3 -c` with an `import json` from whatever
  directory the user's repo happens to be. A `json.py` at that repo's root is then the module
  parsing forgeward's own state. **Their exposure is genuinely smaller than the CI check's, and
  the difference is worth stating rather than assuming:** the python arm in each is only reached
  when `jq` is absent or broken (verified by reading `json_get`'s arm ordering, not inferred),
  and reaching it at all requires write access to the user's checkout — which `TODOS.md` already
  discloses as defeating the local gate outright via marker forgery or `--no-verify`. The CI
  check was the real escalation because a **fork** PR author has no other access and needs none.
  So this is a hardening item, not a live bypass. The fix is one flag per site and is trivial;
  it is filed rather than done because the round-6 branch is scoped to the CI check and a
  drive-by edit to four hook scripts would ship untested under a version-monotonicity PR. Do it
  as its own change with its own gate run, and add an assertion per site — the precedent from
  rounds 2–6 is that an unpinned fix is a fix that quietly comes back out.
  (security review round 6, 2026-08-07) **Priority:** P2
- **`run_split` in `test/version-check-test.sh` reads its captured streams back with `$(cat …)`,
  the same lossy channel rounds 5 and 6 hardened the production script against.** Command
  substitution deletes NUL bytes and strips trailing newlines. It cannot mask a defect *today*:
  the verdict payload is constrained to `^[0-9]+\.[0-9]+\.[0-9]+$` before it is printed, and the
  note text is assembled from the hardcoded `$MANIFESTS` literals plus `$BASE` and an integer, so
  there is no live input that could differ before and after the transform — verified in round 9,
  not assumed. It is filed because that safety is a property of **today's message strings**, and
  the next person who interpolates a manifest-derived value into a note inherits a harness that
  cannot see what it did. Two ways to close it: compare stdout byte-for-byte against an expected
  file with `cmp` instead of pattern-matching a shell string, or read the streams with `mapfile`.
  The first is better and would also pin a combination nothing currently asserts — base missing
  two manifests *and* a dirty worktree, three notes at once, which round 9 verified by hand with
  `od -c`. Deliberately not done on this branch: it would re-invalidate a PASS for a test-harness
  tidy-up. (security review round 9, 2026-08-07) **Priority:** P3
- **`shellcheck` is not installed, so nothing statically analyses this repo's bash.** The
  security reviewer runs semgrep, gitleaks and trivy; on a diff of three `.sh` files semgrep's
  rulepacks matched **zero** of them (they target PHP/JS/secrets), so the one deterministic tool
  that would actually parse the language this repo is written in was the one that was absent.
  The reviewer's finding this round was found by hand, not by a scanner. This repo is ~all bash
  — quoting, `[ ]` vs `[[ ]]`, unset-variable and subshell-scope bugs are its native failure
  modes, and it has already shipped two of them (the `grep -q`/pipefail P1, and the `grep -c`
  line-vs-occurrence miscount below). Adding `shellcheck` to the reviewer's scanner set is
  cheap; the open question is whether it belongs in `forgeward-scan.sh` for every repo or only
  where bash is a primary language. (security review round 2, 2026-08-07) **Priority:** P2
- **The test suites do not run in CI.** `npm test` runs three suites (gate 171, pre-push 15,
  version-check 51) and every one of them is run by hand before a release. The new
  `.github/workflows/version-check.yml` deliberately does not fold them in: the gate suite is
  documented as **load-sensitive** — `test/s7-flake-loop.sh` and `FORGEWARD_S7_LOAD` exist
  because that sensitivity was measured, not guessed — and a flaky *required* check is worse
  than no check, because the first red teaches everyone to re-run rather than to read. Wiring
  them in means first establishing they are green on a shared runner under CI's own load, not
  just on this machine. Until then "the suite passed" rests on the author remembering.
  (CI version check, 2026-08-06) **Priority:** P2
- **The three merged PR bodies #1, #2 and #3 carry a `🤖 Generated with Claude Code`
  byline.** Cosmetic and historical; noted only so it is a deliberate choice to
  leave them rather than an oversight. Newer PRs do not carry it.
  (observed 2026-08-03) **Priority:** P4

## Completed

- **P3: `git push origin --delete <branch>` was denied when the current branch had no
  marker, even though the enforced pre-push hook already allows it.** Fixed 2026-08-07.
  Full reasoning in `DECISIONS.md`.

  The finding was the asymmetry, not the friction. `forgeward-pre-push.sh` skips any ref
  whose local SHA is all-zero — verified against real git, which writes
  `(delete) 0000000… refs/heads/x <remote-sha>` on the hook's stdin for BOTH the
  `--delete` and `:refspec` forms — while the PreToolUse matcher went straight to `deny`
  without asking what was being pushed. The layer whose own header calls itself "a fast
  best-effort reminder" was stricter than the thing it reminds you about, and its advice
  ("run the gate") was unactionable: a deletion publishes no code, so no reviewer could
  review it and no marker could ever attest to it.

  Shipped: `_is_delete_only()` in `scripts/forgeward-gate-check.sh`, taken only on a
  TRUSTED residue (quoted spans already blanked), only on ONE simple command, only when
  `git push` is the literal command word, matching flags as whole argv tokens. Plus
  `_residue_trusted`, which records which scan path answered — the verb test is fail-safe
  either way, but this is the one decision here that can turn a deny into an allow. Tests
  A23 (31 cases) and A24 (degrades closed when `awk` is unavailable) in `test/gate-test.sh`.

  **Three real pushes at a real remote wrote the design; reading git-push(1) would not
  have.** `--delete y z` deletes both (so `--delete` alone settles it); `:q newcode`
  deletes `q` and PUBLISHES `newcode` (so the colon form additionally caps plain tokens at
  one — the remote); and `--tags origin :d2` deletes `d2` and PUBLISHES a tag on an
  unpublished commit (so unrecognised options DENY instead of being skipped, which the
  first draft got wrong). An option can send refs the argument list never names.

  **Mutation testing changed the code twice, and one of the two was a fail-OPEN.** Every
  deny case was already green before the fix — the old matcher denied everything — so the
  deny half proves nothing on its own. The command-word check was two lines and *neither
  could be killed alone*, because `_pub_re` already guarantees `git push` adjacent; they
  were collapsed into one regex. And the newline refusal was unpinned: without it
  `read -ra` sees only the first line, so `--delete x\ngit push origin main` would have
  been ALLOWED. Found by mutation, not by review.

- **P2: nothing checked that a merge moved the version FORWARD, so merge order was
  load-bearing whenever two version-bumping PRs were open.** Fixed 2026-08-06. Full
  reasoning in `DECISIONS.md`.

  The live instance — #17 to 0.7.5 and #18 to 0.7.6, where merging #17 second walks the
  marketplace manifest backward — was avoided by merging #17 first, by hand. Nothing was
  keeping three manifests monotonic except whoever was paying attention at merge time.

  Shipped: `ci/check-version-monotonic.sh` (never-backward across all three manifests, plus
  a head-side agreement check, runnable by hand), `.github/workflows/version-check.yml` (the
  repo's first CI workflow, PR-only — on a push to master the base ref *is* the commit being
  checked, so the comparison would be against itself and green vacuously), and
  `test/version-check-test.sh` (R1–R25c, 51 assertions, wired into `npm test`).

  Three comparator traps are pinned rather than merely avoided. `major*1000000 +
  minor*1000 + patch` ties `1.0.1000` with `1.1.0` (R6/R6b); a string comparison calls
  `0.10.0` behind `0.9.0`, which this repo hits on its next minor (R5/R5b); and the
  component-wise `$((10#$x))` that replaced both **wrapped at 2^63**, which this branch's own
  security review demonstrated end to end — base `18446744073709551617.0.0`, head reverted to
  `1.0.0`, `ok ... not behind`, exit 0 (R13/R13b). The comparator now uses no arithmetic at
  all. And the version validator's first draft was `printf | grep -qx` — the P1
  SIGPIPE/pipefail defect already paid for once here — now a fork-free `[[ =~ ]]` with a
  comment at the line saying why the tempting edit is wrong.

  **The 2^63 wrap is the entry to re-read before writing the next comparator.** R6 pinned the
  10^3 ceiling and stayed green throughout, because it was written against the comparator
  already chosen — it could only see the ceiling that had been thought about. Same shape as
  V5/V6 passing while the jq/python3 divergence shipped underneath them. The comment above the
  fix asserted "no such ceiling" and was simply false; the assertion beside it could not tell.

  **It happened a second time in the same file, which is what makes it a pattern rather than an
  anecdote.** Round 2 of the security review found the ambiguity guard counting with a bare
  `grep -c` — matching *lines*, not *occurrences* — so two version keys on one line counted as
  1 and skipped the guard entirely. R8 was green throughout, because R8's fixture puts the two
  keys on separate lines: the one arrangement `grep -c` gets right. The input still failed
  closed, one check later and citing the wrong reason, so an assertion reading only the exit
  status would also have stayed green. R8b pins the one-line arrangement and asserts on the
  *message*. Generalized: an assertion written alongside a mechanism inherits that mechanism's
  blind spot, and only an outside reader — or a mutation — sees past it.

  **And a third time, as a High.** Round 3 found that under a UTF-8 locale GNU grep will not
  match `[^"]*` across invalid UTF-8 and silently drops the line, so a fork PR author could
  commit a clean forward *decoy* `"version"` key plus a poisoned real one and the poisoned key
  became invisible to the script while every JSON parser took it (duplicate keys are last-wins).
  Base 0.9.0, decoy 0.9.1, poisoned 0.1.0 → `ok: version 0.9.1, not behind master`, exit 0. A
  complete bypass of the file's whole purpose from a one-line hex edit. Fixed at the time with a
  script-wide `export LC_ALL=C`.

  **A fourth round, and it is the one that changed the design.** JSON `\uXXXX` escapes are legal
  in **key names**: `{"version":"0.9.1","version":"0.1.0"}` contains exactly one literal
  `"version"` byte sequence, so the guard counted 1 and passed while every parser decoded two
  keys and took the second. Same bypass, same one-line edit, and `LC_ALL=C` is irrelevant to an
  escape that is pure ASCII — verified end to end: `ok: version 0.9.1, not behind master`, exit
  0, while `node` and `python3` both read `0.1.0`.

  **Rounds 2, 3 and 4 defeated the same textual reader by three unrelated mechanisms, so the
  reader was deleted rather than patched a third time.** Versions are now read by `python3`'s
  stdlib `json` with `object_pairs_hook` refusing duplicate keys by name. Three independent
  evasions of one approach is not three bugs — the class is *text tools do not parse JSON*, its
  members cannot be enumerated, and a fourth patch would only have been the third demonstration
  that patching does not converge. The repo's two earlier declines of "just use jq or python3"
  both stand and neither reaches here: PyYAML is not stdlib (`json` is), and the marker writer
  runs on arbitrary user machines (this runs on `ubuntu-latest`). Their shared principle — one
  arm everybody gets beats a better arm some people get — is why there is a **single** python3
  arm and no `jq` fallback: two readers that can disagree is the diff-hash divergence rebuilt on
  purpose. Absent python3 is a named FAIL, never a skip (R18/R18b).

  **A fifth round, and it is the round-4 fix looked at from the other end.** Round 4 piped the
  manifest to the parser on **stdin** so the bytes arrived unaltered, and wrote a comment there
  naming both transforms a command substitution performs. The parser's *answer* still came back
  through `out="$(python3 …)"`, which performs both: `$(...)` **deletes NUL bytes** (warning on
  stderr, exit status untouched) and **strips trailing newlines**, and both are legal inside a
  JSON string. So the `X.Y.Z` check validated a value the file did not contain. Committed
  `"version":"1\u00009.0.0"`; python3 and node both read a version with an embedded NUL; the check printed
  `ok: version 19.0.0, not behind master` and exited 0. Fixed the way round 4 was fixed — close
  the channel, not the instance: the shape check moved *inside* the parser, so only digits and
  dots ever cross. `re.fullmatch`, not `re.match(…$)`, because Python's `$` also matches before a
  single trailing newline and the anchored form would have rebuilt half the bypass inside its own
  fix. A `RecursionError` escaping `except ValueError` was the same round's Low.

  Round 6 went one layer below all of that: `python3 -c` puts the **current working directory**
  on `sys.path`, and this script runs from the root of the checkout it is judging — so
  `import json` resolved against repo content, and a fork author's five-line `json.py` at the
  repo root made `json.loads` return whatever they liked. Reproduced with base `9.0.0` and head
  manifests genuinely `1.0.0`: `ok: version 999.999.999, not behind master`, exit 0. Rounds 2–5
  hardened how the manifest is *parsed*; this replaced the *parser*, so every earlier guard was
  intact and irrelevant. Fixed with `python3 -I`, chosen over a `sys.path` edit because the CWD
  entry is one of four channels the audited repo has into the interpreter — `-I` also implies
  `-E` (PYTHONPATH and friends) and `-s` (user site-packages, hence `usercustomize`) — and
  patching one channel at a time is exactly how rounds 2 through 5 went. R22/R22b/R22c pin one
  channel each; R22d is the positive control.

  Round 7 went out one layer instead of down: the head side read each manifest off the
  **filesystem** (`read_version "$f" < "$f"` — a plain `open(2)`, which follows symlinks) while
  the base side read it out of the **object store** via `git show`, which returns a symlink's
  target text and never dereferences it. Git tracks symlinks as mode `120000`, so a fork PR
  author commits the three manifests as links to a file outside the checkout and gets
  `ok: version 13.37.0, not behind master (3 manifest(s) compared, all three agree)`, exit 0 —
  a pass asserted about a commit containing no version field at all. The asymmetry was written
  down in the script's own header as a neutral implementation detail. Both sides now go through
  one `require_blob` and one object-store read, so the bytes parsed are the blob in the commit
  by construction; reading HEAD rather than the worktree also means a hand-run ignores
  uncommitted edits, which is stated as blind spot 10 and mitigated by a stderr note naming the
  files (R24b).

  Round 8 was the first PASS: five distinct attempts on round 7's fix (non-canonical tree modes,
  clean/smudge filter divergence, `core.symlinks=false`, replace-refs, ref-name injection through
  `github.base_ref`) all failed closed for the reason the code claims, so that round checked the
  comments against the machine rather than against themselves. Its one Low was a channel slip —
  the base-side "manifest absent" note went to stdout while its sibling went to stderr — invisible
  to all 47 assertions because `run()` folds the streams, which is the suite's blind spot in
  miniature and is now pinned by R25. It also surfaced, as a *safe* case, a second pre-round-7
  bypass worth an assertion: `.claude-plugin` itself committed as a symlink to an external
  directory (R23f).

  Seven rounds produced seven defects, each in the layer the previous round had just hardened —
  the operative lesson is that **an adversarial reader found all seven and the test suite found
  none of them**, which is an argument about how much review a comparator is worth, not about the
  tests being bad. Every new assertion from round 3 on reads the **message** rather than the exit
  status, because two of them failed closed for an unrelated reason and would have passed an
  exit-status check.

  **`export`, not `local`, and this is the part most likely to be got wrong later.** A `local
  LC_ALL=C` is not passed to a spawned child unless the name was already exported — verified
  directly: `local` gives the child `<unset>`, a command prefix and `export` both give `C`. It
  works for a bash builtin like `[[ x < y ]]` and does nothing for `grep`. `num_lt`'s own `local`
  was removed rather than kept beside the export, because the redundant mechanism was precisely
  the ineffective one.

  **Verifying a claim about a tool means invoking the binary the code invokes.** The first attempt
  to check round 3's finding appeared to refute it. That was wrong: `grep` at an interactive
  prompt here is a shell function shimming to **ugrep 7.5.0**, while a script gets `/usr/bin/grep`
  = **GNU grep 3.7**, and shell functions are not inherited by a non-interactive child. The ad-hoc
  check and the code under test were different programs with different invalid-byte behaviour.
  Use `type -a` and an absolute path.

  **Mutation testing earned its place and should not be skipped on the next one like it:** the
  zero-comparison floor reddened *nothing* until R12 was written for it, so a guard that read
  as covered was in fact unpinned. Twenty of twenty-one mutations reddened exactly the
  assertions naming them; the exception is the `LC_ALL=C` *collation* effect, filed above as
  unobservable — though round 3 showed that label covers only the effect that was measured, not
  the pin, and round 4 then made the measured effect moot, which is the same trap twice.

  **Four "vacuous" results, none of them a coverage gap, and they split into two causes.** Three
  were harness artifacts that never applied — `M6`, the `grep -c` revert, and the walk-recursion
  mutation — reddening R11, R8b and thirteen assertions respectively once applied properly. The
  fourth, `M21`, **applied cleanly and was still a no-op**: it added an `ok:*)` arm after the
  real one, and `case` takes the first match, so the mutant was unreachable. An `assert count ==
  1` on the anchor (now the harness's standing shape) catches the first cause and structurally
  cannot catch the second. A mutation reporting nothing is a claim to verify, not a finding to
  accept — accepting any of the four would have added a test for a guard that was already pinned.

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
