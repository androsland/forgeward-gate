# TODOS

Deferred engineering work for forgeward-gate, grouped by component then priority
(P0 highest → P4). `DECISIONS.md` remains the source of truth for *why* a design
is the way it is; this file tracks what is still owed. Items carry the source
that raised them and the date.

Every item here was raised in a merged PR body or a review round. PR bodies are
write-once and effectively gone after merge, which is why they live here now.

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

- **The deletion exemption's whole defence against the quote class rests on ONE line.**
  `case "$raw" in *"'"*|*'"'*|*'\'*) return 1` in `_is_delete_only` is the only guard that
  sees a quoted token at all: `strip_quoted` blanks the span, so a quoted *publishing*
  refspec is not merely mis-split, it is ABSENT from the residue — `git push origin :x
  'main'` reaches the classifier as `origin :x`, a textbook delete-only push, while bash
  still passes `main` to git. `_inert_re` and the colon/plain counters never get a chance,
  because they only ever see tokens that survived blanking. Demonstrated against a mutant
  with the line removed: `git push origin :x secretbranch2` really created the branch.
  Not exploitable as shipped, and the line is mutation-pinned by the three A23 splitting
  cases plus `git push origin :x 'main'`. Its sibling `git push origin ':x' main` denies
  through a DIFFERENT guard — blanking removes the colon token outright, so `colon=0` and
  the aggregation check refuses it — which is worth recording rather than glossing:
  adjacent guards catch adjacent shapes, and only a mutation run says which one caught
  what. Accepted rather than fixed: the suggested
  backstop (compare a whitespace word-count of the residue against one of the raw text)
  is defeated by the same blanking it is meant to police, so it would add a mechanism
  harder to reason about than the one-line proof it backs up. Revisit if a second consumer
  of the residue ever needs token-exact boundaries. (0.9.1 security review round 3,
  2026-08-07) **Priority:** P3
- **`_head_re` accepts VT, FF and CR as the separator between `git` and `push`, where bash
  does not.** `[[:space:]]` is broader than bash's IFS-driven word splitting, so
  `git<VT>push origin :x` is considered for the exemption although bash would never run it
  as a `git push` (it fails as command-not-found, or the subcommand token is not `push`).
  Over-matches in the SAFE direction — it widens what is considered, not what executes —
  so no ref can move. Left alone because narrowing it to space/tab would diverge from the
  same `[[:space:]]` the verb matcher above it uses, and one consistent class is easier to
  reason about than two. (0.9.1 security review round 3, 2026-08-07) **Priority:** P4
- **The single permitted plain token may be an arbitrary scp-syntax host.**
  `git push attacker.example.com:evil/repo.git :y` satisfies the exemption, and git
  contacts that host. Confirmed to transmit no object data for any shape the exemption
  accepts, so nothing is exfiltrated — it is a network handshake, not a publish. Out of
  threat model besides: composing that text already requires the ability to run arbitrary
  commands, which this layer never claimed to stop. Closing it would mean resolving the
  token against configured remotes, which this layer deliberately does not do.
  (0.9.1 security review round 3, 2026-08-07) **Priority:** P4
- **`git push --no-verify` is denied by the fast reminder even though the pre-push hook
  documents it as a deliberate, visible opt-out.** The same direction of disagreement the
  deletion exemption just fixed: the enforced layer offers an escape hatch and the fast
  layer refuses to let you type it. Deliberately NOT fixed in 0.9.1 — exempting it in the
  text layer turns "bypass the gate" into four words with no reviewer and no marker, which
  is a strictly worse trade than the friction. Recorded so the asymmetry is disclosed
  rather than latent; the right fix, if any, is a first-class opt-out with its own audit
  trail, not a matcher hole. (0.9.1 deletion exemption, 2026-08-07) **Priority:** P3
- **The deletion exemption knowingly over-denies five shapes.** All fail CLOSED, all cost
  the user a `gh api -X DELETE` or a gate run, none let a publish through: ANY `'`, `"` or
  `\` anywhere in the command (the blanking scanner can synthesize a word boundary bash
  never had — this one was a real ALLOW on a real publish before the 0.9.1 security review
  caught it, so the refusal is deliberately blunt); a `$VAR`/`$(…)`/backtick anywhere in
  the command (the residue is untrusted, so the exemption is refused outright); bundled
  short flags (`-qd` is one token and matches neither `-q` nor `-d`); any option outside
  the whitelist, e.g. `-o ci.skip` or `--force-with-lease`; a `sudo`/`time`/`env` prefix;
  and any token outside `^[A-Za-z0-9_.:/@+=-]+$`, which over-denies `~`/`^` rev syntax, a
  `%` in a ref name, and a `?` query in a remote URL. That last one is an ALLOWLIST rather
  than a longer blocklist because the same class of bug was found twice in one branch — a
  blocklist is only as good as the author's memory of every construct bash uses to
  synthesize a word.
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

- **Semgrep 1.169 silently does not scan `.mts`/`.cts`.** Measured with byte-identical
  content across extensions: `.js .mjs .cjs .jsx .ts .tsx` all produce findings; `.mts`
  and `.cts` produce **zero findings and zero errors**, so the miss is indistinguishable
  from a clean file. This bounds every bundled JS/TS pack, not just `env-config.yml`, and
  nothing in a rulepack can fix it — `languages:` selects a language, not an extension
  map. Recorded in the pack header; `test/rules-test.sh` deliberately does *not* pin it as
  expected behaviour, since that would go red when a future semgrep fixes it. Re-measure
  on semgrep upgrade; if the hole persists, the fix belongs upstream or in an explicit
  `--lang` invocation, not in the rules. (env/config rulepack, 2026-08-14) **Priority:** P3
- **`env-config.yml`'s blind spots are structural, and two of them are the same bug the
  rules exist to catch.** Rule 1 cannot see a destructuring default
  (`const { FOO = 'd' } = process.env`), which has the identical empty-string flaw, nor a
  fallback split across statements, nor any wrapper hiding the `process.env` token. Rule 2
  cannot see a module-scope IIFE (a true positive that is structurally indistinguishable
  from a lazy getter, so suppressing lazy getters necessarily suppresses it), a value
  arriving through an imported config object, or a factory *call* rather than a `new`.
  Each is stated in the rule's own `message` so a reader who sees a finding also sees the
  limit. Closing the destructuring case is the highest-value one and looks tractable with
  a dedicated pattern; the rest need dataflow this pack does not have.
  (env/config rulepack, 2026-08-14) **Priority:** P3
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
- **`trivy fs`'s one-path arity is verified from SOURCE, not from a binary.** Per
  `pkg/commands/app.go`, `filesystem`'s `PreRunE` calls `validateArgs`, which errors when
  `len(args) > 1` — so trivy fails loudly where gitleaks silently rescoped to the cwd.
  trivy is not installed on the machine that fixed this, so that half is unconfirmed
  against a running binary, and the version read was `main` rather than a pinned tag.
  Re-verify where trivy is present. gitleaks 8.30.1 and semgrep were both confirmed
  empirically (semgrep genuinely takes many paths: two given, two in `paths.scanned`).
  (gitleaks untracked-.env fix, 2026-08-10) **Priority:** P3
- **The per-tool arities the reviewers document are unverified for `phpcs`,
  `osv-scanner`, `grype` and `syft`** — none of the four is installed here. The
  gitleaks defect was exactly this shape (a documented plural where the tool takes one),
  and it survived three releases because nobody ran the arity check. Do the same pass on
  each when a machine has them. (gitleaks untracked-.env fix, 2026-08-10) **Priority:** P3
- **`forgeward-scan.sh` layer 4 uses TRACKED as a proxy for "in the reviewed diff".**
  It gets an argv, not a base ref, so a tracked file the diff never touched still passes.
  That is the whole gap between what the wrapper enforces and what the constraint
  actually asks for. Closing it means handing the wrapper the base (an env var set by the
  gate, say `FORGEWARD_BASE`) and checking membership in `git diff --name-only
  "$BASE...HEAD"` — cheap, but it couples the wrapper to the gate's notion of a base and
  needs a defined behaviour when the var is absent. Deliberately deferred, not forgotten.
  (gitleaks untracked-.env fix, 2026-08-10) **Priority:** P3
- **Nothing in forgeward can scrub a subagent transcript.** `~/.claude/projects/<project>/
  <session>/subagents/agent-*.jsonl` is outside the repo and outside every cleanup this plugin performs,
  which is why the untracked-`.env` read was durable rather than transient. The gate can
  prevent a write; it has no remediation path for one that already happened, and the
  README notice can only tell users to rotate. Worth deciding whether forgeward should
  ship a `forgeward-transcript-audit.sh` that greps its own project's transcripts for
  credential-shaped strings by NAME and reports filenames only — never values, since
  printing them is the exposure. Note two things settled in 0.10.1 that such a script would
  inherit: the audit surface is **two** channels, not one (`subagents/*.jsonl` plus
  `tool-results/*.txt`), and Claude Code expires session directories on its own schedule, so
  an audit that finds nothing has established *unverifiable*, not *clean*. Both are in
  `## Completed`. (gitleaks untracked-.env fix, 2026-08-10) **Priority:** P2
- **Layer 1 cannot see inside a flag's VALUE, and `--log-opts` is now a recommended flag.**
  Verified against gitleaks 8.30.1: `gitleaks git --log-opts="--output=x"` forwards
  `--output` to `git log` and writes `x`, because layer 1 matches whole tokens and this one
  begins `--log-opts`. Layer 3 contains it — the run exits 3 naming the new path — so it is
  loud rather than silent, which is why this is a P3 and not a blocker. Deliberately not
  fixed by pattern-matching inside the value: `--output` is the one git-log write flag I
  verified, and encoding that single sample as the rule is how a guard ends up looking
  complete while missing the next one. If it is fixed, the shape should be an allowlist on
  the value (a commit range only), not a denylist of flags. (security review follow-up,
  2026-08-10) **Priority:** P3
- **Layer 4's target check is TOCTOU and is documented as an accepted gap, not fixed.**
  `_gl_target_guard` validates the path, then `forgeward-scan.sh` execs the tool, which
  opens it — anything with concurrent write access to that exact path can swap a tracked
  file for a symlink to an untracked one in the window. Accepted because that attacker
  already has local write access to the repo, which dwarfs the misaimed-scanner threat
  the guard addresses. Revisit only if forgeward ever runs scanners against a tree a
  less-trusted process can write. (security review, 2026-08-10) **Priority:** P3

## Standalone posture (no gstack installed)

Full analysis in `docs/axis-proposals.md` → "Later findings" §3. **Option B shipped in
0.8.0** — entry archived to [`TODOS-DONE.md`](TODOS-DONE.md). What follows is what it
did *not* close.

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
  an existence proof, not a measured rate. (2026-08-05) **Priority:** P3 — downgraded at
  0.12.0; forgeward's half is closed and the remaining half is another repo's code.

  **Half-narrowed by 0.8.0, and forgeward's half closed at 0.12.0.** Option B made the
  *gstack-absent* half explicit — the gate discloses `quality` as unowned. 0.12.0 closed
  the other side of forgeward's contribution: the README no longer says `/review` covers
  quality, and `skills/gate/SKILL.md` now prints a PRESENT-case clause naming what the
  probe can and cannot see (`quality: owned by gstack /review (installed; forgeward has
  no quality reviewer and does not check that /review ran)`). So a user with both tools
  installed is no longer told the axis is handled.
  **What is left is not fixable from here.** `/review`'s skip reasons are written by
  gstack, and nothing in forgeward can read them, change them, or detect that a review
  ran — the loop only truly breaks when gstack stops deferring to forgeward for
  `maintainability`. Filed against the other repo, not this one; the entry stays because
  the *measurement* lives here and would otherwise be lost.
  (0.8.0, 2026-08-06; forgeward half closed 0.12.0, 2026-08-16)
- **The base-rate measurement structurally under-counts this class, and the 0.7.6 work is
  the proof.** The method was a by-hand pass over merged diffs, and it scored 0 — while the
  same session found two live instances (`json_get`'s python arm, `marker_get` ×2) that a
  diff-reading pass cannot see, because each is only visible when two arms of one helper
  are read *together*, and one of them was silently cancelling the #11 fix to the arm
  beside it. Four known instances in ~40 files — `json_get` ×2, `strip_quoted`,
  `marker_get` — three shipped, two surviving a round (#11) explicitly aimed at them.
  Both 0.7.6 fixes are in [`TODOS-DONE.md`](TODOS-DONE.md). This does not overturn the fold
  decision — a reviewer that also reads diffs would have scored the same 0 — but it is the
  reason the fold should not be treated as "the class is rare." Weigh it if the axis is ever
  rescored. Carried into `DECISIONS.md` at 0.12.0 as the fold decision's own stated defect,
  so it is no longer only in this file. (2026-08-06) **Priority:** —
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

- **`rules/env-config.yml` is deliberately NOT vendored into the CI security workflow.**
  Step 4 of `skills/ci-gate/SKILL.md` copies `rules/wp-security.yml` into `.forgeward/rules/`
  and runs it with `--error`; the env/config pack is advisory (WARNING, reported at Low) and
  doing the same would turn a required check red on advice, which is exactly the
  green-on-arrival failure ci-gate's first core rule forbids. Revisit only if CI grows a
  non-blocking advisory lane whose result is visible without gating the merge — an
  `if: always()` step with `continue-on-error`, surfaced as an annotation rather than a
  status. Until then this is a decision, not an oversight; see `DECISIONS.md`, "env/config
  rules ship in the security-reviewer's pack but can never fail a gate".
  (env/config rulepack, 2026-08-14) **Priority:** P3

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
- **Dependabot is configured but has never been observed to run, and an unverified
  automation reads as coverage.** 0.12.0 settled the open half of the SHA-pin question —
  `.github/dependabot.yml` takes the `github-actions` ecosystem, monthly, grouped, over the
  manual `git ls-remote` alternative — but a config file in the tree is not evidence the
  service is enabled for this repo, and the first proof either way is a PR that does or does
  not arrive. Check after the first monthly window; if nothing comes, the setting lives in
  the repo's Settings → Code security, not in the file. Two limits are stated in the config
  header rather than here so they travel with it: it sees `uses:` in workflow files only (a
  version pinned inside a script or a composite action is invisible to it), and a bump PR is
  pushed server-side, so no forgeward gate and no local hook runs on it. That second one is
  bounded rather than open: `test.yml` and `shellcheck.yml` are `pull_request`-triggered and
  do run on a Dependabot PR server-side, and `version-check.yml` passes correctly (a
  workflow-only bump touches no version field) — what is absent is the *local* gate and its
  reviewers, not all checking.
  **The single `*` group is safe today and will not stay that way.** `actions/checkout` is
  the only third-party action in the repo and all four `uses:` sites carry a byte-identical
  pin, so one group cannot conflate unrelated bumps. The day a second, unrelated action is
  added, one PR starts carrying two independent supply-chain changes under one review —
  revisit the grouping at that point, not before. (Raised by the 0.12.0 gate's own
  supply-chain reviewer, which verified the pin resolves to the claimed tag by
  `git ls-remote` rather than trusting the trailing comment.)
  **The pin is already three majors behind, so expect the first bump PR to be a major.**
  Measured 2026-08-16: `11d5960a…` resolves to `v4`/`v4.4.0`, while `actions/checkout`
  publishes `v3 v4 v5 v6 v7`. So this is not a hypothetical about future drift — the drift
  has happened and nothing noticed for as long as the pin has been in the tree, which is
  the concrete form of the "unverified automation reads as coverage" point above. Two
  consequences for the check after the first monthly window: an *absent* PR is a stronger
  signal that the service is off than it would be against a current pin, and an arriving
  PR is a **major** bump carrying real behaviour change, so it needs reading rather than
  merging on the strength of the green tick.
  (CI version check, 2026-08-06; decided and configured 0.12.0, 2026-08-16) **Priority:** P3
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
- **`shellcheck`: raised because nothing statically analysed this repo's bash; the open
  question left is whether the *reviewer* should run it, not whether this repo does.**
  Read the three paragraphs in order — the finding, the measurement that undercut it, and
  what 0.12.0 settled. One priority, at the end.

  **As raised (security review round 2, 2026-08-07, at P2).** The
  security reviewer runs semgrep, gitleaks and trivy; on a diff of three `.sh` files semgrep's
  rulepacks matched **zero** of them (they target PHP/JS/secrets), so the one deterministic tool
  that would actually parse the language this repo is written in was the one that was absent.
  The reviewer's finding this round was found by hand, not by a scanner. This repo is ~all bash
  — quoting, `[ ]` vs `[[ ]]`, unset-variable and subshell-scope bugs are its native failure
  modes, and it has already shipped two of them (the `grep -q`/pipefail P1, and the `grep -c`
  line-vs-occurrence miscount below). Adding `shellcheck` to the reviewer's scanner set is
  cheap; the open question is whether it belongs in `forgeward-scan.sh` for every repo or only
  where bash is a primary language.

  **Installed 2026-08-15 (shellcheck v0.11.0, homebrew) and run across the repo. The measured yield does
  not support the argument this entry was making, and the argument should not survive the
  measurement.** Findings: `scripts/*.sh` and `ci/*.sh` are clean apart from SC2016 ×5, SC1003
  and SC2034 ×2, all deliberate — SC2016 fires on every single-quoted `awk`/`python3` program in
  the repo, and SC2034 on the git pre-push stdin protocol's intentionally-unread positional
  variables. (Re-measured 2026-08-16 against `HEAD` before 0.12.0's directives landed:
  identical — SC2016 ×3 in `forgeward-gate-check.sh`, ×1 each in `forgeward-scan.sh` and
  `forgeward-workspace-guard.sh`, SC1003 ×1, SC2034 ×2, and `ci/`/`live-test/` at zero. Each
  is now suppressed by a `# shellcheck disable=` naming the reason at the site, so CI runs
  with no exclusion flags and a future genuinely-wrong SC2016 still fires.) `live-test/setup.sh` had SC2010 ×2 and SC2143 ×1 (`ls | grep` in the hook-listing
  block), fixed in this commit — style, not defects; the `set -e` abort those lines *look* like
  they should cause was tested and does **not** occur, because bash exempts a failing non-final
  member of an AND-OR list. `test/*.sh` carries 241 findings — SC2015 ×201, SC2164 ×30,
  SC2181 ×6, SC2016 ×3, SC2012 ×1 (the SC2016 count was omitted when this was first written;
  re-measured 2026-08-16 and the other four are unchanged) — and
  the SC2015 mass was checked against the shipped `grep -q`/pipefail P1 and is not that bug in
  new clothing (attempted repro: bash's default SIGPIPE disposition kills the suite outright at
  141 rather than letting `printf` return non-zero into the `||`).

  **The decisive measurement is the negative one: shellcheck catches NEITHER of the two bugs
  this entry cites as its evidence.** Both were reconstructed as minimal scripts and run through
  v0.11.0 — the `printf | grep -q`-under-`pipefail` P1 and the `grep -c` line-vs-occurrence
  miscount — and it reported nothing on either. So the case for `forgeward-scan.sh` for every
  repo is weaker than this entry assumed, not stronger: the tool's value here is regression
  prevention against the classes it *does* know (quoting, unset vars, subshell scope), and this
  repo's actual failure history sits outside them. That is still worth having, but it is a
  different claim and should be argued on its own terms.

  **Settled at 0.12.0 (2026-08-16), and only for this repo.** `.github/workflows/shellcheck.yml`
  runs `shellcheck scripts/*.sh ci/*.sh live-test/*.sh` on every PR, **with no exclusion
  flags** — the five deliberate findings carry inline `disable=` directives naming their
  reason instead, so the baseline is zero and a new finding is a real one. A workflow rather
  than `npm test`, deliberately: `npm test` runs on a developer machine where shellcheck may
  be absent, and a suite that skips when its tool is missing is the failure mode this entry
  was raised about in the first place; CI installs it. `test/*.sh` stays **out of scope** —
  241 findings, dominated by an SC2015 mass already shown not to be the shipped P1 — so a
  green shellcheck tick says nothing about the suite's own bash, and that is stated in the
  workflow header rather than left to be inferred.
  **Still open, and it is the part that matters to other people:** whether `shellcheck`
  belongs in `forgeward-scan.sh` — i.e. whether the *reviewer* runs it on every repo it
  gates, or only where bash is a primary language. Nothing above answers that; this repo
  gating its own bash is a local decision, and the negative measurement (shellcheck catches
  neither bug this entry cited) is the argument that has to be beaten first.
  (2026-08-15; CI half closed 2026-08-16) **Priority:** P3 — downgraded from P2 by the above.
- **The suites now run in CI, and are deliberately NOT a required check — that second half
  is the part still open.** As raised (2026-08-06, P2): `npm test` ran by hand before every
  release, so "the suite passed" rested on the author remembering, and
  `.github/workflows/version-check.yml` deliberately did not fold them in because the gate
  suite is documented as **load-sensitive** (`test/s7-flake-loop.sh` and `FORGEWARD_S7_LOAD`
  exist because that sensitivity was measured, not guessed) and a flaky *required* check is
  worse than no check — the first red teaches everyone to re-run rather than to read.
  0.12.0 added `.github/workflows/test.yml`, which runs all four suites on every PR and on
  `master`. The roster this entry carried was also wrong and is corrected here: **four**
  suites, not three — gate **182** (not 171), pre-push 15, version-check 51, rules 39,
  re-counted 2026-08-16 from a live `npm test`.
  **What is not closed:** a green tick from `test.yml` is evidence the suites pass *once* on
  a shared runner, and nothing more — it is explicitly not evidence of non-flakiness, which
  is why the workflow header says not to make it a required check yet. That question belongs
  to `.github/workflows/flake-sweep.yml` (dispatch- or `flake-sweep`-label-triggered, default
  25 runs at load 4), **which has not been run yet** — so as of 0.12.0 the load-sensitivity
  claim is still unmeasured *in CI*, exactly as it was before, and only the measuring
  instrument is new. Run the sweep, record the numbers here, then decide about required-check
  status. (CI version check, 2026-08-06; suites wired in 0.12.0, 2026-08-16) **Priority:** P3
- **The three merged PR bodies #1, #2 and #3 carry a `🤖 Generated with Claude Code`
  byline.** Cosmetic and historical; noted only so it is a deliberate choice to
  leave them rather than an oversight. Newer PRs do not carry it.
  (observed 2026-08-03) **Priority:** P4

## Docs hygiene

- **Nothing expires an entry, so the open half needs a periodic triage or it silently
  becomes a mix of live work and history.** Raised 2026-08-14 when the open half was ~70KB
  and untriaged; the first triage ran at 0.12.0 (2026-08-16), closing seven entries that
  later work had already resolved and re-dating the rest. **What the triage found is the
  reason to keep doing it:** two `see ## Completed` pointers had gone stale when their
  targets were archived, one entry carried two contradicting `**Priority:**` markers, and
  one carried a suite roster that had been wrong since 2026-08-06 — none of which any
  automated check in this repo can see, because none of them is a code property.
  The structural problem is unchanged and is not fixable by triaging harder: an entry
  closed by a later change stays in the swept read path until a human notices, and nothing
  signals that a triage is overdue. **Size is not that signal, measured:** the open half went
  from 48.1KB/56 entries to **50.5KB/52 entries** across this pass — four fewer entries and
  2.4KB *more* text, because closing an entry properly means writing down what closed it.
  A triage makes the file more accurate, not smaller, so anyone waiting for the byte count
  to fall as proof it worked will conclude it did not. Next pass on the same trigger as this
  one — a batch of merged work large enough that several entries are plausibly stale — not
  on a number. (todos archive, 2026-08-14; first triage 0.12.0, 2026-08-16) **Priority:** P3
- **Nothing verifies the rule-extraction step that `CLAUDE.md` depends on.** The archive
  convention says a constraint is lifted into `CLAUDE.md` as its entry moves to
  `TODOS-DONE.md`, but that is judgment at archive time with no check behind it. A pass
  that archives without extracting is a silent regression on precedent retrieval — the
  entry is preserved and simultaneously removed from the swept read path. At least four
  archived entries carry reasoning that did not become a rule (the `sys.path` channels
  enumerated in round 6, the TOCTOU acceptance on the scan target, the stdin-mode gap
  held only by prose, and the layer-1 flag-VALUE blind spot). Decide per entry whether
  those are constraints or history.

  **Second pass, 0.12.0 (2026-08-16): four entries archived, six rules lifted**, and three
  of the four named gaps above are now rules — the `sys.path` channels ride along with the
  `-I` bullet, and the stdin-mode and flag-VALUE blind spots became a whole
  `## Running other people's tools` section. Verified by grepping `CLAUDE.md`, not recalled.
  The fourth, the scan-target TOCTOU, is deliberately still not a rule and the original
  framing was imprecise about why: its entry is **open**, not archived, so the reasoning
  has never left the swept read path and there is nothing to rescue. Lift it if that entry
  is ever closed.
  **The verification gap itself is untouched.** This pass extracted because a human
  remembered to; nothing would have failed if it had not, and that is still true for the
  next one. (todos archive, 2026-08-14; second pass 2026-08-16) **Priority:** P3
- **`CLAUDE.md` at the repo root ships to anyone who installs the plugin from this
  marketplace.** The plugin cache copies the repo, so the file lands beside
  `.claude-plugin/`. It is inert there — Claude Code loads `CLAUDE.md` from the cwd and
  its parents, not from a plugin cache — but keep it free of anything machine-specific
  or private, on the assumption that it is readable by every installer.
  (todos archive, 2026-08-14) **Priority:** P4

## Completed

Only the five most recent are kept here — a sweep consults them to answer "did I
already do this?". Everything older is in [`TODOS-DONE.md`](TODOS-DONE.md), including
the non-goals and reversed decisions; the rules those produced are in
[`CLAUDE.md`](CLAUDE.md).

- **P2 ×4 + P3 ×3: the suites reached CI, the quality axis stopped being claimed, and the
  open half was triaged for the first time.** 0.11.0 → 0.12.0, 2026-08-16. Three batches of
  deferred work that shared no code but shared a failure mode: **each was a place where this
  repo asserted more coverage than it had.**

  **CI — three workflows, one question each, because a green tick is read as an answer to
  whatever question the reader had.** `test.yml` runs all four suites (gate 182, pre-push 15,
  version-check 51, rules 39) on every PR and on `master`; its header says in capitals not to
  make it a required check yet, because passing once is not evidence of non-flakiness.
  `shellcheck.yml` runs `scripts/ ci/ live-test/` with **no exclusion flags** — the five
  deliberate findings (SC2016 ×5, SC1003, SC2034 ×2, all verified against `HEAD` rather than
  recalled) now carry inline `disable=` directives naming their reason at the site, so the
  baseline is zero and a genuinely-wrong SC2016 still fires. `test/*.sh` is out of scope, 241
  findings, stated in the workflow header so the tick is not over-read. `flake-sweep.yml`
  owns the load-sensitivity question `test.yml` deliberately does not: `workflow_dispatch`
  or the `flake-sweep` label, 25 runs at load 4 by default, driving the existing
  `test/s7-flake-loop.sh`.

  **The sweep workflow would have swallowed its own evidence, and that is the part worth
  keeping.** The default runner shell is `bash -eo pipefail`, so a non-zero harness aborts
  the step *before* the summary prints — losing exactly the output the workflow exists to
  collect. The status is captured (`|| rc=$?`) and folded into the verdict instead. Second
  fix in the same shape: an **unparseable** tally now fails rather than passing, because
  defaulting an absent `done:` line to zero is how "died on run 1" reports as "ran 25 times
  and found nothing".

  **`.github/dependabot.yml`** settles the SHA-pin refresh question at the standard answer
  (`github-actions`, monthly, grouped, limit 3) rather than the manual `ls-remote`. Three
  non-goals are in its header: it does not judge the new code (a pin buys immutability, not
  trust); **no npm entry deliberately**, since `package.json` is `private: true` with zero
  dependencies and no lockfile, and the day a real dependency lands, forgeward's own
  `supply-chain-reviewer` starts firing on it; and it sees `uses:` in workflow files only.

  **The error-path fold: measured, then folded, and the losing half of the rule recorded.**
  The pre-committed decision rule was ≥1 true High per 5 PRs → build a seventh reviewer,
  below that → fold. It measured 0, so rules 1 (discarded failure signal) and 3 (unchecked
  conditional-write result) went into `security-reviewer` Step 3 and no reviewer was built.
  Rules 2 and 4 fired zero times anywhere and were **not** folded — adding prompt weight to
  every security review in exchange for a rule that has never fired is a cost with no
  measured return. The precondition this needed first is also done: Step 3 now defines
  fail-open and fail-closed, requires a finding to **name the direction and what a caller
  then believes that is not true**, and requires a stated failure consequence to reach High —
  an unnarratable High is unfalsifiable, and a gate that FAILs on findings nobody can check
  gets switched off.

  **The quality axis: forgeward stopped asserting another tool's coverage.** The measured
  finding was reciprocal deferral — on `04a04fb`, gstack's `/review` skipped `maintainability`
  as `covered-by-forgeward-and-coverage-audit` while forgeward's README skipped quality
  because `/review` covers it, so both installed still meant nobody reviewed it. Scope stated
  as 2 of 22 entries, an existence proof rather than a rate. `README.md` now says forgeward
  does not review code quality and no longer claims gstack does it for you;
  `skills/gate/SKILL.md` prints a PRESENT-case clause naming what the probe can and cannot
  see; `DECISIONS.md` carries the entry either way, generalised to **a deferral may name an
  owner; it may never assert coverage**. `docs/axis-proposals.md` Q2 is marked SUPERSEDED
  rather than edited into agreement. The gstack half is another repo's code and stays open.

  **Docs: the archive convention was applied to itself.** `## Completed` was stale by three
  merged PRs, so #26 and #28 were reconstructed into it and #27 into `TODOS-DONE.md` from
  their commit bodies **before** any cut — and the cut order was resolved with
  `git log --first-parent`, which changed the answer: **#26 merged 39 minutes after #27
  despite the lower number**, so both a date sort and a number sort would have archived the
  wrong entry. 275 lines moved out, six rules lifted into `CLAUDE.md` on the way (parsing
  structured documents, an option that sends refs the argument list never names, a new
  `## Running other people's tools` section, five test rules, three docs rules). Then the
  first-ever triage of the open half, counted rather than described: **four entries deleted
  outright** (the fold decision and its precondition, the `DECISIONS.md`-entry-either-way,
  and the stale-`## Completed` finding), **two replaced by narrower successors** (the SHA-pin
  refresh policy → Dependabot-configured-but-unobserved; open-half-untriaged → nothing
  expires an entry), **three narrowed in place** (quality axis, shellcheck, suites-in-CI),
  and one empty section heading removed. Also repaired: two `see ## Completed` pointers that
  went stale when their targets were archived, one entry carrying **two contradicting
  `**Priority:**` markers** (headline P2, appended paragraph P3), and a suite roster wrong
  since 2026-08-06 (three suites and gate 171; it is four and 182).

  **Not done, deliberately:** the sweep has **not been run**, so the load-sensitivity claim
  is still unmeasured in CI and only the instrument is new; `test.yml` is not a required
  check; Dependabot is configured but unobserved, and a config file is not evidence the
  service is enabled. All three are filed above rather than implied by the workflows'
  existence.

- **P2 ×2 + P3: the two repo-wide interpreter/locale conventions were written down but only
  partially applied, and neither was pinned by anything.** Fixed 2026-08-15. Closes the
  four-`python3 -c`-sites item, the "locale pinning should be repo-wide" item, and the
  `awk`/`wc -c` asymmetry P3 in one lane.

  `python3 -I` now sits at all five shipped sites (`forgeward-diff-hash.sh`,
  `forgeward-gate-check.sh` ×2, `forgeward-pre-push.sh`, and the CI check that already had
  it), and `export LC_ALL=C` at the top of all **13** tracked `*.sh` outside `test/` — the
  11 in `scripts/`, `ci/check-version-monotonic.sh`, and `live-test/setup.sh`. Both inline
  `LC_ALL=C` command prefixes were **removed** rather than kept beside the pin, on the
  standing one-mechanism-per-invariant rule; the sites carry a comment saying so, because a
  reader who finds the prefix gone needs to know it was replaced and not simply dropped.

  **The `-I` entry's threat model was wrong and the correction is the substantive part of
  this commit.** It read: "reaching it at all requires write access to the user's checkout —
  which `TODOS.md` already discloses as defeating the local gate outright", concluding "a
  hardening item, not a live bypass". It is a live bypass. Python imports a *file*, not an
  index, so the shadowing `json.py` arrives with the branch you cloned in order to review it
  — no local write access, and the fork-author escalation the entry reserved for the CI check
  applies here too. Demonstrated end to end, not argued: with `jq` off the PATH and a
  `json.py` committed to the branch, an `-I`-stripped `forgeward-gate-check.sh` **ALLOWS** a
  publish that the shipped one denies. That is A26, and it carries both controls — the
  bypass leg must ALLOW or the assertion is measuring nothing, and the same mutant without
  the `json.py` must still DENY or it is merely broken.

  **Scope limit, stated because the demonstration is narrower than the flag:** the bypass is
  the no-jq arm only. With a working `jq` installed, `json_get` never reaches `python3` and
  the shadow is inert. The exposure is real and conditional, and A26 says nothing about a
  machine with jq.

  Pinned by A25–A29 in `test/gate-test.sh` (177 → 182 assertions), each mutation-checked:
  strip `-I` from any shipped site → A25 red; strip it from the hook → A25 and A26 red;
  delete one script's pin → A27 red; put an inline `LC_ALL=` back → A28 red; `chmod -x` a
  tracked-755 script → A29 red. A25 and A27 are deliberately counted as the **violating**
  form and enumerated from `git ls-files`, so a *new* site added without the flag fails —
  "five sites carry `-I`" would go green the day a sixth arrived without it.

  A29 exists because this commit nearly shipped without it. Inserting the pin across eleven
  files with `awk > tmp && mv` replaced each at the umask default, dropping all eleven from
  755 to 644; every invocation became `Permission denied` and the plugin was completely
  broken. The suite caught it only as 28 unrelated assertions collapsing at once — nothing
  named the cause. A29 names it.

  `test/` is excluded from A27 **deliberately**: the suite spawns these scripts as children,
  so a pin there would be inherited by every one of them and the property A27 checks would
  become untestable from inside the test that checks it. Note also what the pin bought the
  E-series for free — E18 previously asserted "the config reader works under the *test
  runner's* locale", because it could not pin what the script did not pin; the script now
  pins itself, so E18 asserts behaviour under `LC_ALL=C`.

  **Two stale line references were corrected on the way out, and the correction is to stop
  citing lines at all.** The locale entry cited `forgeward-detect-environment.sh:103` for the
  `LC_ALL=C wc -c` and `:112` for the bare `awk`; by the time it was read they were at `:131`
  and `:150`, and inserting the pin moved them again to `:140` and `:159` — drifting twice,
  the second time inside the very commit that was fixing the citation. Both now read as "the
  `config_state` block", per `CLAUDE.md`'s cite-by-symbol rule, which is the only form that
  survives its own fix.

  **The predicted rotation collision landed and was resolved by rebase, and the prediction
  named the wrong entry to cut.** This branch and #29 were cut from the same `master` and each
  archived the 0.8.0 `/ship`-handoff entry while adding its own, so the second to merge
  conflicted. `TODOS-DONE.md` needed no decision — both sides made the byte-identical
  insertion, so git took one copy and the file came out equal to master's. `TODOS.md` kept
  both new entries, leaving six. The filed plan said to cut "the version-monotonicity entry,
  2026-08-06"; the entry actually cut is the config-keys one, because **both carry the same
  `Fixed 2026-08-06` line and only the merge order separates them** — config-keys is #20
  (`246a715`, 2026-08-06) and monotonicity is #22 (`c057dc9`, 2026-08-07), which the prose
  dates cannot show. An oldest-out cut decided from the date printed in the entry would have
  archived the newer of the two. Checked with `git log`, not read off the page.

- **P1 + P2: the 0.9.2 rotation notice searched one persistence channel of two, and read
  its own empty result as clean.** Fixed 2026-08-15, shipped in 0.10.1. Both halves were
  filed 2026-08-14 as follow-ups to the notice itself; both are wording and flags, no code.

  **The missed channel.** A large tool result is truncated in the JSONL at 30 000
  characters and written in full to `tool-results/<id>.txt`, the transcript keeping only a
  `persistedOutputPath` pointer. Every command in the notice carried `--include='*.jsonl'`,
  so none of them could match a `.txt`. Measured on one machine: 277 such files, two
  matching the notice's own pattern set, and one holding a private key the truncated JSONL
  did not contain. So the copy the notice could not see was simultaneously the copy with the
  weaker permissions and the copy with more in it.

  **The permissions claim was tightened after the gate reviewer re-measured it**, and the
  correction is the entry's own lesson applied to itself. The first draft said the `.txt`
  files are 0644 "where the transcripts are 0600" — a universal read off a sample. The
  reviewer's independent count was 279 of 279 at 0644 against **1878 of 1879** at 0600, the
  exception being a transcript that was itself 0644. The direction of the finding is
  unchanged and the outlier makes the exposure marginally worse rather than better, but
  "all transcripts are 0600" was not a thing either of us had established. The README now
  carries the counts instead of the quantifier.

  `--include` was **dropped** rather than widened to two extensions. Widening is the
  smaller diff and the worse fix: an extension list is the same shape of narrowing that
  caused the defect, and it would miss a third channel exactly as silently. The path does
  the scoping now.

  **The false-clean read.** Claude Code expires its own transcripts — `cleanupPeriodDays`
  defaults to 30 — and the unit it reaps is the **session directory**, aged by the parent's
  recency rather than per file. Measured: 0 of 247 top-level session transcripts survive
  past 30 days, while **20 of 1574** subagent transcripts do, alive only because their
  parent session stayed in use. So the leak channel this notice is about is precisely the
  one that outlives the window, and a short-lived session's evidence is gone inside the
  month. Both directions mislead, and this was hit for real: a transcript identified as
  holding an AKIA-shaped value on 2026-08-13 was gone on 2026-08-14 at age 31, before it
  could be re-examined, so that finding is now permanently unresolvable. The notice now
  says an empty result means **unverifiable**, not **safe**, and tells anyone who ran
  0.2.0–0.9.1 in a repo with an untracked credential file to rotate regardless.

  This is the same false-clean shape as the 0.9.3 path bug, arriving by two further routes
  — which is the reason the notice now states its own limits at every command rather than
  once at the top. **Blind spots, stated rather than papered over:** one machine, one Claude
  Code version (2.1.232); `cleanupPeriodDays` is user-configurable, so 30 is a default and
  not a guarantee; whether the 30 000-character threshold or the 0644 mode is stable across
  versions was not checked; and none of it was checked on Windows.

  Untested by construction: this is prose in `README.md`, and no suite in this repo asserts
  anything about it. The surviving P2 above — a possible `forgeward-transcript-audit.sh` —
  is where these two facts would become executable rather than documentary.

- **P1 + P2 FILED, not fixed (the fix is the entry above): the rotation notice's two
  unstated assumptions, measured.** #28 (`ce69eb5`), 2026-08-14 — one file, `TODOS.md`, no
  code and no version bump. Recorded here because a filing-only PR leaves nothing behind in
  the tree, and this one is the entire evidence base 0.10.1 was written from.

  Both entries were filed *beneath* "Nothing in forgeward can scrub a subagent transcript",
  which is correctly scoped — no cleanup this plugin performs touches one — and that correct
  scoping is exactly what hid the two assumptions sitting behind it: that the evidence is
  still on disk, and that the transcript is where it lives.

  **Expiry (P2).** `cleanupPeriodDays` defaults to 30, and the unit reaped is the SESSION
  DIRECTORY, aged by the parent's recency rather than per file. One machine, 2026-08-14,
  Claude Code 2.1.232, setting unset: **0 of 247** top-level session transcripts older than
  30 days, **0 of 207** orphaned `subagents/` directories, and **20 of 1574** subagent
  transcripts older than 30 days — alive only because their parent session stayed in use. So
  the leak channel the notice is about is the one that outlives the window, while a
  short-lived session's evidence is gone inside the month. Both directions break the notice.

  **`tool-results/` (P1).** A tool result over 30 000 characters is truncated in the JSONL
  and written in full to `tool-results/<id>.txt`, the transcript keeping a
  `persistedOutputPath` pointer; every command in the notice carried `--include='*.jsonl'`.
  Same machine, same day: **277** such files, all `.txt`, all mode 0644 beside 0600
  transcripts. Two matched the notice's own pattern set, and in one a private key was
  present in the persisted file and **absent from the truncated JSONL copy**.

  **What those two files actually held is the part worth keeping, and it is not what the
  headline suggests.** Both were local Supabase CLI Docker output, carrying two different
  classes of key that were harmless for two different reasons:

  - the PEM private key is **baked into the `supabase/kong:2.8.1` image** — byte-identical
    across two unrelated projects captured three weeks apart and the live container. Public
    by construction.
  - the `pgsodium_root.key` value is **not** public: absent from the `supabase/postgres`
    image layer, different between two local projects, and unchanged in the affected project
    from the Aug 4 capture to that day. It is inert for an unrelated reason — `pgsodium` is
    not an installed extension in that database (`pgcrypto` only) and it carries zero
    `pgsodium` security labels, so no column is encrypted under it, and a local container's
    key has no bearing on the hosted project.

  A notice written off the first reason alone under-reports the second class entirely. That
  is why 0.10.1's wording says an empty result means **unverifiable**, not **safe**.

  **Blind spots, carried forward unchanged:** one machine, one Claude Code version;
  `cleanupPeriodDays` is user-configurable, so 30 is a default and not a guarantee; whether
  the 30 000-character threshold or the 0644 mode is stable across versions, or on Windows,
  was not checked. The gate fired **no reviewers** on this diff — one prose file, every
  surface absent — which is correct, and is also why nothing above was independently
  re-measured until the 0.10.1 branch, where the reviewer's own count corrected the
  permissions claim from a quantifier to a ratio.

- **P2 + P3: three rules that lived as prose in a personal `CLAUDE.md` became gate checks.**
  Shipped 2026-08-14 as #26 (`41324b0`), 0.9.3 → 0.10.0. Full reasoning in `DECISIONS.md`.
  Prose only fires if the model happens to recall it, it rots silently, and it does nothing
  at all for anyone else who installs the plugin.

  **The SQL vault-secret bullet** (`agents/security-reviewer.md` Step 3) covers three shapes
  that the generic Secrets bullet and Semgrep `p/secrets` both miss, because **none of them
  looks like a high-entropy literal**: a credential in a plaintext config table; a secret
  leaking into **derived storage at execution time** (`cron.schedule(..., format(...))`
  baking a token into `cron.job.command`, structurally invisible to any diff scanner because
  the migration text may hold only a *reference* that gets resolved); and a generic
  `get_secret(name text)` `GRANT`ed to `authenticated`/`anon`, which turns the vault into a
  lookup API so one broken-authz path reaches *every* secret.
  **Must NOT fire on** non-secret configuration in exactly such a table — URLs, feature
  flags, publishable/anon keys designed to be public — nor on a row holding a secret's
  *name*, which is the pattern being recommended. **Cannot see** the live database, so a
  credential inserted by hand in `psql` or by a seed outside the diff is invisible; and it
  cannot tell whether the platform *has* a vault, so on a plain Postgres the remedy is
  "encrypt at rest / move it out of SQL", not "use the vault".

  **`rules/env-config.yml`**, a second bundled Semgrep pack, wired into Step 2 the way
  `wp-security.yml` already was but deliberately **without `--error`**: (1) `??` as an
  env-var fallback, which only falls back on `null`/`undefined`, so a blank-but-present
  variable — the routine output of a secrets sync and of most CI secret injection — reaches
  the consumer as `''` and the default is silently discarded (observed in production:
  `process.env.POLAR_SERVER ?? 'sandbox'` produced `new URL('')` and took down a Vercel
  build at page-data collection); and (2) an env-dependent SDK client at module scope, which
  evaluates at import time and so fails the whole build rather than the one route that
  needed the credential. **Noise-checked against a 237-file production codebase before
  shipping**, which is what surfaced the real false-positive class: `?? ""` is behaviourally
  identical to `|| ""` for a string-or-undefined value and was 8 of 16 hits. Excluded.

  **The placement decision is the substantive part, and it was a real choice rather than a
  formality** — neither rule is a security finding; both are build safety. Chosen: ship in
  the security pack and report **every** finding at Low, tagged defense-in-depth. The reason
  generalizes and is worth keeping: **what a reviewer BLOCKS is the remit that matters, not
  what it prints.** Critical/High is the only bar that fails a gate, so pinning the pack at
  Low widens the reporting surface and leaves the blocking surface bit-for-bit unchanged —
  which answers "don't widen security's remit" structurally rather than by intention. The
  rejected alternative — disclose `build-config` as an axis no installed tool owns — is
  incoherent while the detection exists: announcing "nothing covers build-config" in the
  same run that just scanned for it and found two is a worse lie than the silence it
  replaces. Enforced in three places that are supposed to agree: the rule's
  `metadata.forgeward-report-severity: low`, the pack header prose, and the Step 2
  instruction to report at Low *regardless of what the JSON says*, with an explicit "do not
  promote one because the consequence sounds severe".

  **`test/rules-test.sh` — 39 assertions**, house style, wired into `npm test`, in three
  classes: positives, negatives (every legitimate configuration the rules must not fire on),
  and **blind spots pinned as silent**, so a future semgrep that closes one fails the suite
  and forces the doc to be corrected rather than quietly becoming a lie. Fixtures are
  generated into a scratch dir and **never committed** — a `.ts` fixture under `test/` would
  itself be scanned by forgeward's gate on every later PR. A **trust check runs first**: a
  fixture semgrep cannot parse turns every silence-assertion green, so a non-empty `errors`
  array is a hard failure, not a warning. Not hypothetical — a fixture syntax error masked
  results during development, and later a botched mutation truncated a file by 141 lines and
  the check caught it. Skips loudly when semgrep is absent (`1..0 # SKIP`).

  **The gate found a real bug in this branch's own tests, and it was fixed rather than
  deferred.** Under `set -uo pipefail` without `-e`, a failing `mktemp -d` yields an empty
  `$TMP`, so `$TMP/fixtures` becomes the **absolute** path `/fixtures` and the heredocs write
  outside the sandbox the file's own header promises they stay inside. Unprivileged that
  fails with `EACCES`; a root-run CI container has a writable `/` and it succeeds silently.
  Medium never fails a gate — fixed anyway, because it was two lines and it contradicted the
  file's own stated invariant. Verified by pointing `TMPDIR` at a nonexistent directory.

  **Measured, not assumed.** Mutation testing (exact single-line deletions from the pack)
  caught **5 of 6**; the sixth is genuinely redundant under semgrep 1.169, which normalises
  function forms — that redundancy is now *recorded in the pack* rather than hidden by
  deleting a line the engine might stop covering. It also caught a **wrong causal claim in a
  shipped artifact**: rule 2's message attributed an IIFE blind spot to the arrow-function
  exclusion specifically, when the function-scope exclusions cause it collectively.
  Extension coverage, measured with byte-identical content: `.js .mjs .cjs .jsx .ts .tsx`
  scan; **`.mts` and `.cts` do not** — zero findings *and* zero errors, so the miss looks
  exactly like a clean file. Recorded in the pack header, and deliberately **not** pinned as
  expected behaviour in the suite, since that assertion would go red the day a future
  semgrep fixes it. Step 1's extension list gained `.mjs`/`.cjs`, previously dropped before
  the pack could see them.

  **Deliberately not done, both with revisit conditions rather than left silent:** not
  vendored into `ci-gate` — advisory WARNINGs turning a required check red is exactly the
  green-on-arrival failure `ci-gate`'s first core rule forbids; and **no AI-attribution /
  `Co-Authored-By` check**, considered and rejected. `/gate` handing off to `/ship` is
  structurally a perfect chokepoint, but forgeward is a plugin other people install and
  plenty of them legitimately want a co-author trailer. If it is ever added it is an opt-in
  config key defaulting to off — a separate decision.
