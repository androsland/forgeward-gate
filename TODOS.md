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
- **The `actions/checkout` SHA pin has no refresh policy, which is the other half of pinning.**
  `.github/workflows/version-check.yml` pins `11d5960a326750d5838078e36cf38b85af677262` (`v4`,
  resolved by `git ls-remote --tags` on 2026-08-06, not recalled). A SHA cannot be repointed
  under us — and equally cannot pick up a security fix, so an unrefreshed pin decays into a
  stale-action problem, which is the failure mode a tag does not have. Nothing currently
  notices when GitHub cuts a new `v4.x`. Dependabot's `github-actions` ecosystem is the
  standard answer and would be this repo's second CI-adjacent config; the cheap manual version
  is re-running that `ls-remote` at release time. Undecided which. (CI version check,
  2026-08-06) **Priority:** P3
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

  **Installed 2026-08-15 (v0.11.0, homebrew) and run across the repo. The measured yield does
  not support the argument this entry was making, and the argument should not survive the
  measurement.** Findings: `scripts/*.sh` and `ci/*.sh` are clean apart from SC2016 ×5, SC1003
  and SC2034 ×2, all deliberate — SC2016 fires on every single-quoted `awk`/`python3` program in
  the repo, and SC2034 on the git pre-push stdin protocol's intentionally-unread positional
  variables. `live-test/setup.sh` had SC2010 ×2 and SC2143 ×1 (`ls | grep` in the hook-listing
  block), fixed in this commit — style, not defects; the `set -e` abort those lines *look* like
  they should cause was tested and does **not** occur, because bash exempts a failing non-final
  member of an AND-OR list. `test/*.sh` carries SC2015 ×201, SC2164 ×30, SC2181 ×6, SC2012 ×1 —
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
  different claim and should be argued on its own terms. What is NOT yet decided: whether to
  wire it into `npm test` as a gate on `scripts/` + `ci/` (the two dirs that are clean today,
  so a baseline is free), and whether `test/*.sh` is worth an exclusion list or should simply
  stay out of scope. (2026-08-15) **Priority:** P3 — downgraded from P2 by the above.
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

## Docs hygiene

- **`## Completed` is missing entries for three merged PRs, so "the five most recent" is
  false — it is the five most recent *that were written down*.** Measured 2026-08-15 by
  diffing the section against `gh pr list --state merged`, when the newest entry present was
  #24/#25 (2026-08-12). **#26** (`feat(security-reviewer)`: SQL vault-secret audit +
  advisory env/config rulepack), **#27** (`docs`: archive completed TODOS, lift the rules
  into `CLAUDE.md`) and **#28** (`docs(todos)`: two blind spots in the rotation notice) all
  merged 2026-08-14 and are absent. This is the second time the section has read stale by
  two releases; the first is recorded inside the #24 entry itself.
  **Why the 2026-08-15 rotation went ahead regardless, since the standing rule says to
  reconstruct first:** the rule exists to stop a cut archiving *recent* work while keeping
  five older ones, and that requires the gaps to fall inside the kept date range. These
  gaps do not — all three are NEWER than every entry present, so the oldest-out rotation
  could not touch them. Checked, not assumed. The reconstruction is still owed, and it is
  its own pass: three PR bodies and their diffs read properly, not paraphrased mid-batch.
  (todos sweep, 2026-08-15) **Priority:** P3
- **The open half of `TODOS.md` is still ~70KB after the completed split, and it is
  untriaged.** Archiving the 12 oldest completed entries bought 19KB of a file that is
  read in full on every pre-commit sweep; the remaining bytes are open work, and some of
  it is stale rather than live. Nothing here expires an entry, so an item closed by a
  later change stays in the read path indefinitely. A triage pass should close what
  shipped and re-date what did not. (todos archive, 2026-08-14) **Priority:** P3
- **Nothing verifies the rule-extraction step that `CLAUDE.md` depends on.** The archive
  convention says a constraint is lifted into `CLAUDE.md` as its entry moves to
  `TODOS-DONE.md`, but that is judgment at archive time with no check behind it. A pass
  that archives without extracting is a silent regression on precedent retrieval — the
  entry is preserved and simultaneously removed from the swept read path. At least four
  archived entries carry reasoning that did not become a rule (the `sys.path` channels
  enumerated in round 6, the TOCTOU acceptance on the scan target, the stdin-mode gap
  held only by prose, and the layer-1 flag-VALUE blind spot). Decide per entry whether
  those are constraints or history. (todos archive, 2026-08-14) **Priority:** P3
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

- **P0: the secrets scanner read a developer's untracked, gitignored dotenv file
  during a real gate run, and the values landed in a persisted subagent
  transcript.** Authored 2026-08-10 and merged 2026-08-12 as #24
  (`60a067a`, 0.9.2); the rotation notice's path was corrected 2026-08-12 as #25
  (`acbdc12`, 0.9.3). Full reasoning in
  `DECISIONS.md`. *(This entry was missing from this list until 2026-08-14 — the
  deferrals it produced were filed in the open half at the time, but the
  completion itself never was, which made `## Completed` read as stale by two
  releases.)*

  Two defects, and the first hid the second. The documented Gitleaks invocation
  passed the whole changed-path list to a command that takes ONE path; read from
  `cmd/directory.go` (v8.30.1) rather than inferred, there is no cobra `Args`
  validator, so a second positional is not an error — `len(args) != 1` leaves
  `source = "."`, the cwd. The extra path is neither rejected nor
  dropped-with-the-first-honoured: the whole target is silently replaced.
  Verified against the binary — one path scanned 15 bytes, two scanned 176,
  identical to `dir .`. And `dir` mode is a filesystem walk regardless, so
  fixing the first alone leaves any directory in the changed-path list
  re-triggering it.

  The fix makes the scanner structurally unable to see anything outside the
  reviewed diff. The primary shape is the commit range
  (`gitleaks git --log-opts="<base>...HEAD" --redact -f json -r -`), with
  per-file `dir` only where working-tree state is genuinely needed.
  `forgeward-scan.sh` gained layer 4: for the `dir`/`file`/`directory` family the
  target must be exactly one existing regular file that git tracks — zero paths,
  two paths, a directory, and an untracked file are all refused. The subcommand
  is matched against an enumerated set and anything else refused, so an unlisted
  value-taking flag placed BEFORE it (`gitleaks --unlisted V dir .`, where `V`
  looks like the subcommand) cannot slip a directory scan past the guard. That
  also covers `detect --no-git` and `protect`, HIDDEN in 8.30.1 — absent from
  `gitleaks --help` but still live, the same walk under older names, and verified
  to read the untracked file before the guard refused all three shapes.
  `--redact` is now unconditional, which closes the value half while layer 4
  closes the read half; neither is sufficient alone. Trivy lost `secret` from
  `--scanners` for the same reason, short `-r` was closed for gitleaks (only the
  long form had been enumerated, so `-r evil.json` reached the write the long
  form exists to refuse), and supply-chain-reviewer's `trivy fs <paths>` was
  corrected to one path.

  Deliberately **not** a filename exclusion: a committed credential file is a
  genuine finding and must keep being reported.

  Four gaps were found while verifying this and **disclosed rather than fixed**,
  so their absence is not read as coverage — each is in the script's NON-GOALS
  block, in `DECISIONS.md`, and as a P3 above. Layer 1 matches flag TOKENS and
  cannot see inside a flag's VALUE, so `--log-opts="--output=x"` forwards
  `--output` to `git log` and writes the file, using the very flag this change
  starts recommending; layer 3 contains it (the run exits 3 with the path named)
  and P8l pins it as accepted-and-contained, asserting it stays LOUD rather than
  asserting a refusal that was not built. The target check is TOCTOU, accepted
  because that attacker already has local write access. The tracked check needs a
  work tree, not live since the reviewer always runs inside the repo under
  review. And `stdin` mode has no path token to check, so piping untracked
  content in by hand is held only by prose — an argv wrapper cannot see a pipe.

  Coverage: `gate-test.sh` P8i/P8j/P8k/P8l, including an end-to-end fixture on
  the observed shape with a **control leg** that bypasses the wrapper and asserts
  the raw scan DOES leak — without it the assertions pass with the guard removed,
  since `--no-banner` alone prints no values. Mutation-verified twice: layer 4
  disabled → P8j and P8k fail; the unrecognized-subcommand branch softened to
  `return 0` → P8j fails. 177/15/51 assertions green.

  The 0.9.3 follow-up: the rotation notice told users to look in
  `~/.claude/projects/<project>/subagents/*.jsonl`, a path that does not exist —
  the real layout has a session-uuid level in between. The published grep
  therefore exits `No such file or directory`, which reads as "nothing matched",
  i.e. clean. A user following the notice exactly concludes they were unaffected
  and does not rotate, and the notice has then retired their suspicion as well.
  For a rotation notice that is the worst available failure mode.

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

  **The branch's own security review found a real bypass in the first draft.** `strip_quoted`
  BLANKS a quote or backslash to a space instead of deleting it, so an empty quote pair inside
  one real argv token splits it into two tokens bash never produced: `git push /pub/repo'':x.git`
  is ONE repository argument, the classifier saw plain=1 colon=1, exempted it, and it really
  published `refs/heads/main`. `_is_delete_only` was the first consumer of that residue to depend
  on exact token boundaries rather than on "does this word appear". Closed by refusing the
  exemption on any `'`, `"` or `\` — a complete cover, since blanking can only ever ADD a
  boundary and every path that adds one needs one of those three characters.

  **The re-gate then found the same shape again through globbing, which is what turned the
  token test into an allowlist.** `read -ra` does not glob, so `git push [os]* :newcode` is
  one token to the classifier and several words to bash — reproduced against a real remote,
  where it deleted `newcode` and PUBLISHED `secretbranch`. Two misses of the same kind in
  one branch is the argument for inverting the test: every token must now match
  `^[A-Za-z0-9_.:/@+=-]+$`, so the construct nobody thought of fails closed.

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
