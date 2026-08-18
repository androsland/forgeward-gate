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
- **The fix for the two-arm divergence is unreachable from any call site, so nothing but
  V9/V10 can tell if it rots.** `normalize_manifest`'s unknown-mode guard and
  `snapshot_manifest`'s mode guard both sit on paths that no production call reaches —
  every call site passes a string literal. They are structural, not behavioural, which
  means the ordinary signal that a guard broke (something visibly stops working) will
  never fire here. The two assertions added with the fix are the entire detection
  surface, and both are text-coupled to the script: V9 extracts `normalize_manifest`
  with a `sed` range anchored on `^normalize_manifest()`, V10 rewrites the literal
  `snapshot_manifest .claude-plugin/marketplace.json plugins` with `awk`. Renaming
  either would make the extraction silently match nothing — so both were given explicit
  `nok` arms that FAIL when the pattern misses rather than skipping, which is the
  difference between a test that notices its own irrelevance and one that goes green on
  an empty set. Recorded because that is a mitigation, not a solution: the coupling is
  still there, and a rename plus a mechanical fix to the `nok` arm would restore the
  green without restoring the coverage. (self-review, 2026-08-17) **Priority:** P4
- **The marker is HEAD-pinned, so choosing to fix a Low finding costs a full re-review —
  and the cost is real enough to be measured, not estimated.** The docs-only PR #34 took
  **five** gate rounds, converging 3 → 2 → 2 → 0 findings. Every finding across all five
  rounds was **Low**, so by the severity contract in [`CLAUDE.md`](CLAUDE.md) not one of
  them could have failed the gate; every round after the first was voluntary. The
  mechanism is not a bug: the marker stores a hash of HEAD's reviewed state, so any commit
  after a PASS unpins it, and that is exactly what stops a fix from riding in unreviewed
  behind a green marker. But it makes the *marginal* cost of acting on advisory output
  equal to the *total* cost of the review, which inverts the incentive the Low tier exists
  to create: the cheapest response to a Low finding is to ignore it. **Not proposing a
  partial-re-review escape hatch** — "re-review only the files that changed" is how a
  cross-file regression ships, and the hash covers the whole reviewed surface for that
  reason. The tractable direction is to stop paying for rounds nobody asked for: batch
  Low fixes to one round, or let the operator say up front that Lows will not be actioned
  this pass. **n=1, and the shape of the 1 matters** — a docs PR is where advisory findings
  are densest and where fixing them is cheapest, so it is the *most* favourable case for
  re-rounds, not a typical one. Do not generalize the 5 to code PRs without measuring one.
  (operational note, 2026-08-17) **Priority:** P3

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

- **The warning is a COUNT, so a user with five of them still has to find their own typo.**
  Closed the silence in 0.13.0, not the diagnosis: `config_warnings: 3` says look at the file,
  never which three lines. The constraint that forced it is structural rather than lazy — the
  probe's output is interpolated into the pass marker as JSON by `printf`, and an integer is
  the only shape with no representable `"`, `,`, `{` or `}`, which is also what lets `_env_ok`
  match it more tightly than the quoted fields beside it. Naming the keys means either
  escaping repo-controlled strings on the path that authorizes a push (the thing every other
  decision in that file exists to avoid), or giving the probe a second output channel the
  marker does not read — which is the shape worth pricing if this is ever reopened, since the
  gate already runs the probe directly and does not learn the count from the marker.
  (0.13.0, 2026-08-18) **Priority:** P3
- **Nothing detects the case where `config_warnings` is meaningless.** The reader is not a
  YAML parser, so on a file using anchors, aliases, multi-document streams or block scalars
  it counts over lines that were never keys — a number that looks like a diagnosis and is
  noise. The count is honest about *shapes the reader knows*; it has no way to notice it is
  out of its depth, and there is no cheap test for "this file is YAML I do not implement"
  short of implementing it. Written into the probe header, the skill and README as an
  explicit non-goal rather than left implied. Reopen only alongside a real parser.
  (0.13.0, 2026-08-18) **Priority:** P4
- **`config_warnings` cannot see a duplicate key, which is the one malformed shape that is
  also silently *honoured*.** YAML resolves duplicates last-wins; this reader has no notion
  of a key it has already seen, so `posture:` twice under `seo:` sets the posture twice and
  counts nothing — both spellings look honoured and one of them silently lost. Distinct from
  every other case the counter covers, all of which are *discards*. Cheap to add for the two
  tracked paths specifically (a seen-flag per key, not a general mechanism); left out of
  0.13.0 to keep that change purely additive over the existing rules.
  (0.13.0, 2026-08-18) **Priority:** P4
- **A column-0 comment inside the `seo.routes` subtree releases the skip, and the rest of the
  subtree then gets counted.** Raised by the security reviewer on the 0.13.0 gate run and
  reproduced before filing: the subtree exemption is indent-based, and a `#` line at column 0
  has indent 0, which is never `> skip`, so the skip clears one line early and every remaining
  `routes:` child is matched by the generic indented-key rule instead. (The column-0 section
  reset does not fire on it — that rule excludes `#` — so `in_seo` is still set.) Measured on a
  two-route fixture: column-0 comment → `config_warnings:1`; the same file without it → `0`;
  the same file with the comment *indented* → `0`. `seo_posture` was honoured in all three. So
  it over-counts only: it cannot suppress a warning that should fire, and it cannot swallow
  `posture:` or `substitutes:`, both matched by rules that run before the skip-continuation
  rule and at any indent. That direction — disclose more, never less — is why it did not block
  the gate. The fix is one clause (do not release the skip on a comment line), but it changes
  the reader's rule ordering, which is exactly the property 0.13.0 was careful to leave alone,
  so it wants its own commit and its own assertion rather than riding on the release that
  introduced it. (security review, 2026-08-18) **Priority:** P3
- **The gate's one-line config note is model-rendered and has not been live-tested.** 0.13.0
  pins the probe's numbers in E28–E37 and verified them by hand against the live-test
  fixtures, but the half only a model can satisfy — that `/forgeward:gate` actually prints
  the `N setting(s) were read and discarded` line, and still writes the marker on all-PASS —
  is unverified. `live-test/LIVE-TEST.md` §5 carries the steps and is explicitly marked as
  NOT covered by its own 2026-08-06 / 0.9.0 stamp. Same class as every other model-behaviour
  claim in that file: the script side is testable and tested, the rendering side is not.
  (0.13.0, 2026-08-18) **Priority:** P3
- **`seo.routes` is documented and unread, now deliberately and in writing.** 0.9.0 wired
  `seo.posture` and declined the per-route mapping: glob keys in a flow mapping need the YAML
  parser the reader exists to avoid. All three mentions (README, `skills/gate/SKILL.md`,
  `agents/seo-reviewer.md`) now say it has no effect, so this is a disclosed gap rather than
  a broken promise — but a repo with a marketing site and an app on one origin genuinely
  wants it, which is the case the whole posture-per-route-group design is built around.
  Reopening it means taking a YAML dependency outright, not growing the awk.
  **0.13.0 hardened the disclosure rather than closing the gap**: `config_warnings`
  deliberately does not count `routes:` or anything indented under it, because a repo that
  pins it followed three shipped documents and a count that fires on a conforming
  configuration teaches the reader to ignore the count. That makes "documented as unread" a
  load-bearing contract now, not just a note — if `routes:` is ever honoured, or ever
  un-documented, the counter's skip has to move with it.
  (0.9.0, 2026-08-06; amended 0.13.0, 2026-08-18) **Priority:** P3
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

  **The revisit condition is MET and the named remedy is still refused — recorded so the
  trigger is not re-evaluated from scratch every pass.** The probe emits seven fields and
  `_env_ok` is a single 247-byte line, which is past "a handful". But this entry's own
  suggested trade — "taking the parser dependency" — is refused by `CLAUDE.md`'s **one reader
  per shape, never a second parser arm**, and by the reason `forgeward-write-marker.sh`
  avoids an interpreter in the first place: it sits on the **push-authorizing** path, where a
  dependency that is present on the author's box and absent on an installer's decides whether
  a marker is written. So the trade this entry proposed is not available at the price it
  assumed. What 0.13.1 did instead is lower the cost the coupling was being judged on: the
  edit is two files, not three, and the silent leg is gone. **The coupling itself is
  unchanged and this entry stays open** — a literal shape match still has to move whenever
  the probe's line does. Reopening should argue about the two-file cost that actually exists
  now, not the three-file one that no longer does. (re-evaluated 0.13.1, 2026-08-19)

  **A second obligation was found the first time this was exercised** (0.9.0 added
  `seo_posture`): **E17's hardcoded payload must be updated in the same commit too.** That
  assertion pins the shape match's *trailing* anchor by feeding it the probe's genuine output
  plus an appendix — which only tests the anchor while the opening bytes are a shape `_env_ok`
  would otherwise accept. A stale payload is rejected on its prefix instead, and dropping the
  `$` stops turning it red. Verified in both directions by mutation. So a new probe field is
  now a **three**-file edit, and the third is the one whose omission is silent: `_env_ok`
  failing loses provenance and reddens E10, while a stale E17 reddens nothing at all and
  quietly retires a security assertion.
  **Exercised a second time in 0.13.0** (`config_warnings`), and both halves re-verified by
  mutation rather than taken from this entry: a stale `_env_ok` reddens E10 and degrades
  every marker to `{"probe":"unavailable"}`; a dropped trailing `$` reddens E17 with the
  current payload and leaves the suite fully green with the stale one. Two-for-two means
  this is the normal cost of a probe field, not a one-off. The obligation is now stated at
  the probe's own `printf` — the file someone editing the output actually has open — with
  this entry as the provenance rather than the only record.
  (0.9.0, 2026-08-06; re-confirmed 0.13.0, 2026-08-18)

  **CLOSED in 0.13.1 — the third leg is gone, and the fix was to delete the copy rather than
  to warn harder about it.** E17 now derives its prefix from `$E1J`, the live probe captured
  at E1 with every root neutralised, so there is no hand-copied literal left to fall behind:
  a new field appears in the payload the moment the probe emits it. A new probe field is a
  **two**-file edit again — the `printf` and `_env_ok` — and that is now stated at the
  `printf` itself. **What it does not do:** it cannot see `_env_ok` falling behind the probe.
  In that direction the derived prefix is refused, the marker degrades to
  `{"probe":"unavailable"}`, and E17 goes green for the wrong reason; **E10 is what reddens
  there**, so the two cover opposite directions and neither is sufficient alone. E17 also
  carries an emptiness floor, because an assertion built on a derived value that can be empty
  otherwise asserts a property of nothing.
- **The config check is TOCTOU by construction, and that is accepted, not overlooked.**
  The `[ -L ]` refusal and the `[ -f ]`/`[ -r ]` arm beside it run in
  `forgeward-detect-environment.sh`'s config-reading block, but `wc -c` and
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
  standalone `/review` reaches the `gstack-review-log` call in `review/SKILL.md` with no
  `via` key, while `/ship` reaches the one in `ship/sections/review-army.md` with
  `"via":"ship"`. Both re-verified 2026-08-16. These are **cross-repo** references into
  gstack, which this repo neither controls nor can keep current, so grep for the
  `gstack-review-log` invocation before acting on either. Keying on
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
  the *Gated e2e* row of `README.md`'s Validation table, with a pointer to it from the
  ci-gate feature list. Blocked externally, not by code. (PR #1, 2026-06-25; inherited
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

- **Local tag `item2-wip-quote-stripping` is not an archive, and that is the fact the
  decision turns on.** It preserves the third failed attempt at the publish matcher
  (quote-stripping via bash extglob — correct but superlinear in quote density, 63s on 3KB
  of quote-dense input), superseded by the 0.7.1 awk-based design. Measured 2026-08-16:
  the tag is **local-only** (`git ls-remote --tags origin` returns nothing for it) and its
  commit `c7e56d0b` is **not an ancestor of `origin/master`**, so it exists on exactly one
  machine and a fresh clone has never had it. "Keep it as an archaeological record" is
  therefore not the status quo — the status quo is *ephemeral*, and leaving it alone is
  choosing that without saying so. Two real options: push the tag, which makes the record
  durable and public, or drop it and accept that the prose above is the record. The
  measurement (63s on 3KB) and the reason it lost are already written down here and in
  `DECISIONS.md`; the tag adds the code, not the lesson. Deliberately not decided by an
  agent — deleting the tag makes the commit unreachable and eventually collectable.
  (PR #8, 2026-08-01; measured local-only 2026-08-16) **Priority:** P4
- **Dependabot is observed running as of 2026-08-16, and the grouping is the one residual
  left.** The "configured but never observed" half of this entry closed the same day it was
  written: PR #32 opened at 20:14 UTC — `actions/checkout` 4.4.0 → 7.0.1, branch
  `dependabot/github_actions/actions-7a5a078ad4` — roughly four hours after
  `.github/dependabot.yml` merged. So the service is enabled for this repo, the schedule
  fires without anything being switched on in Settings → Code security, and the `actions`
  group name resolves. **The prediction this entry recorded held exactly**: it said to
  expect "a **major** bump carrying real behaviour change, so it needs reading rather than
  merging on the strength of the green tick", and a three-major jump is what arrived. It
  was reviewed on the merits rather than on the tick, which is the only reason writing the
  prediction down was worth anything.
  **The bounded-not-open claim was also confirmed rather than assumed.** #32's own check
  rollup: `suites`, `shell` and `monotonic` all SUCCESS, four `sweep` entries SKIPPED
  (correct — `flake-sweep.yml` is dispatch/label-gated and must not fire per-PR). So a
  Dependabot PR does get the three server-side workflows; what it does not get is the
  *local* gate and its reviewers, which is what the config header says and now what the
  evidence says.
  **What is still open is the single `*` group.** `actions/checkout` is the only
  third-party action in the repo and all four `uses:` sites carry a byte-identical pin, so
  one group cannot conflate unrelated bumps *today*. The day a second, unrelated action is
  added, one PR starts carrying two independent supply-chain changes under one review —
  revisit the grouping at that point, not before. (Raised by the 0.12.0 gate's own
  supply-chain reviewer, which verified the pin resolves to the claimed tag by
  `git ls-remote` rather than trusting the trailing comment.)
  **The staleness measurement stands and explains the size of the bump.** Measured
  2026-08-16 before #32 arrived: `11d5960a…` resolves to `v4`/`v4.4.0` while
  `actions/checkout` publishes `v3 v4 v5 v6 v7` — the drift had already happened and
  nothing noticed for as long as the pin had been in the tree. That is the concrete form
  of the "unverified automation reads as coverage" point this entry opened with, and it is
  now retired by measurement rather than by assertion.
  **The lesson that outlives the entry: an automation nobody has watched run is a claim,
  not a control.** The check that settles it is cheap — one glance at the PR list — and it
  is the same shape as the shellcheck pin's "an accepted cost that has never been paid is
  a prediction, not a measurement", arrived at independently in the same release. Two
  measurements of one idea in one release is a pattern worth keeping.
  **#32 merged 2026-08-17** (`11af421`), so the first Dependabot bump this repo has ever
  received is in `master` and the three server-side workflows passed on it. The loop is
  closed end to end: configured → fired → reviewed on the merits → merged.
  (CI version check, 2026-08-06; decided and configured 0.12.0, 2026-08-16; observed
  running via PR #32, 2026-08-16; merged 2026-08-17) **Priority:** P4
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
- **The `python3` obligation is in README now; what is still unwritten is the rule behind
  it.** `ci/check-version-monotonic.sh` reads the three manifests with the stdlib `json`
  module and has no `jq` fallback, deliberately (see `DECISIONS.md`: one arm, because two
  readers of the same JSON that can disagree is the diff-hash divergence bug rebuilt on
  purpose). It fails closed with a named message when python3 is absent, so nothing silently
  skips.
  **The docs half is done** (2026-08-16). README's Validation section states the requirement,
  and states it against the thing most likely to be confused with it: the *hooks* read JSON
  with `jq` **or** `python3` and fail open when neither exists, so README previously mentioned
  python3 only in its optional role — which for a reader working out whether they need it is
  worse than saying nothing.
  **A second overreach was corrected on the way out.** This entry used to claim python3 was
  "the only external tool any script in this repo needs". `test/rules-test.sh` needs
  `semgrep`; it degrades to a loud `1..0 # SKIP` rather than failing, which is precisely why
  it read as "not a dependency". A tool whose absence turns a suite green is still a
  dependency, and README now names it as one.
  **The rule is now written down too (2026-08-17) — and enumerating the call sites to write
  it showed the framing in this entry was wrong in two ways.** It said the split is *posture,
  not location*: user-machine optional/fail-open, CI-only required/fail-closed. That is a
  two-way split, and there are **three** postures.
  1. **CI-only, required, fail-CLOSED** — `ci/check-version-monotonic.sh` dies by name.
  2. **User-machine hook, optional, fail-OPEN** — `forgeward-gate-check.sh` and
     `forgeward-pre-push.sh` both `exit 0` when neither `jq` nor `python3` is present.
  3. **Helper on the gating path, optional, fails toward RE-GATING** —
     `forgeward-diff-hash.sh`'s `normalize_manifest` falls through to `cat`, so the version
     field is never neutralized, the hash differs, and the marker reads stale. The missing
     one from the old framing, and the one that matters most, because it is the arm sitting
     on the authorization path rather than beside it.

  **And the surface is smaller than a grep says.** `git grep -l python3` returns **six**
  tracked scripts; only **four** call it. `forgeward-detect-environment.sh` and
  `forgeward-write-marker.sh` mention it purely in comments explaining why they deliberately
  do *not* take the dependency — so the text match overcounts by 50%, which is the same
  *text tools do not parse structure* class already in `CLAUDE.md`, arrived at from the
  outside this time. Posture 3 also has a narrower reach than it first appears: `cat` is
  reached only when `jq` **and** `python3` are both absent, which is exactly the condition
  under which the two hooks have already exited 0. Both limits are written into the rule as
  stated non-goals rather than left for the next reader to rediscover.
  Round 6 narrowed the dependency: the call is `python3 -I`, so the floor is Python 3.4
  (2014). An interpreter too old to accept the flag fails closed with its own error plus
  `returned no usable answer` — verified against a PATH shim that rejects `-I`, not assumed.
  (CI version check rounds 4 and 6, 2026-08-07; README half done 2026-08-16; rule written
  down and the split corrected 2026-08-17) **Priority:** — done
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
  **The version is pinned, and the first CI run is why.** The workflow shipped unpinned,
  with a header arguing that runner drift was a real cost accepted on purpose. The cost was
  paid on that same PR: `ubuntu-latest` carries shellcheck **0.9.0**, which reports three
  SC2015 findings that **0.11.0** does not, so the job went red on shell that was already
  clean under the author's linter. All three were false positives — two `A && cd … || true`
  sites where the `|| true` is best-effort by construction, and one
  `[ -n "$f" ] && [ -f "$f" ] || { usage; exit 64; }` where both A and B are pure tests, so C
  runs exactly when `NOT(A && B)`, which is if-then-else. Suppressing them would have blinded
  three sites permanently to satisfy a linter older than the code, so the workflow now
  downloads and checksum-verifies v0.11.0 and asserts the pin took. The lesson is the
  general one: **an "accepted cost" that has never been paid is a prediction, not a
  measurement** — this one was falsified by its own first run.
  **Two residuals the pin creates, neither of them covered by anything:** the digest is
  **trust-on-first-use**, because koalaman/shellcheck publishes no checksum and no signature
  with its releases (13 assets on v0.11.0, none a `.sha256` or `.asc`) — it pins the artifact
  to bytes verified once, and proves nothing about upstream intent; and **nothing refreshes
  the pin**, since Dependabot's `github-actions` ecosystem sees `uses:` lines, not a version
  string in a `run:` block, so this goes stale silently the way `actions/checkout` already
  did. Both are stated in the workflow header as non-goals so the green tick is not read as
  covering them.
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
  **The sweep has now been run** — `workflow_dispatch` run `31970233140` on `master`,
  2026-08-16: **25 runs, clean=25, `s7_fail_open=0`, `other_failures=0`, `harness_rc=0`**, at
  `FORGEWARD_S7_LOAD=4` on a runner reporting a 1-minute load average of 0.24 at start, ~24s
  per run, ~10 minutes wall clock. Separately `test.yml` has 4 runs of its own, all success.
  So the load-sensitivity claim is measured *in CI* for the first time, and nothing flaked.
  **That is still not enough to make it required, and the arithmetic is why.** Zero failures
  in 25 runs puts the 95% one-sided upper bound on the per-run flake rate at **11.3%**; the
  harness says the same thing from the other end, that an 8% flake survives 25 clean runs
  with probability 0.92²⁵ ≈ **12%**. An 11% flake on a required check is exactly the failure
  this entry was opened to avoid — so a clean sweep at n=25 is *consistent with* the outcome
  it was meant to rule out. 25 is the harness's default, not the number that answers this
  question, and it would have been easy to read the green as the answer.
  **What would settle it, costed.** The bound tightens as 1 − 0.05^(1/n): n=50 → 5.8%,
  n=100 → 3.0%, **n≈300 → 1.0%**. At ~24s a run that is about two hours of runner time, and
  this repo is public, so Actions minutes are free — a decisive answer is purchasable, not
  merely desirable. The cheaper route is passive: `test.yml` already runs on every PR and
  every push to `master`, so its own history accrues the same evidence for nothing. Revisit
  when that history reaches **n≥100 with zero flakes**, or dispatch `flake-sweep.yml` with a
  larger run count if the answer is wanted sooner. Until then `test.yml` stays advisory and
  its header keeps saying why. (CI version check, 2026-08-06; suites wired in 0.12.0,
  2026-08-16; swept clean at n=25, 2026-08-16) **Priority:** P3
- **The three PR bodies are stripped; the git history is not, and it was never counted.**
  PR bodies #1, #2 and #3 carried a `🤖 Generated with Claude Code` byline; all three were
  edited on 2026-08-16 and re-read back from GitHub to confirm zero matches. The diffs were
  checked first and removed exactly the byline plus its preceding blank line, nothing else.
  **The entry's own scope was wrong, and sweeping is what showed it.** It said "the three
  merged PR bodies", which read as the complete set. Sweeping every PR, every issue and
  every commit instead found: no issues affected, no other PR body affected — and **14
  commits on `master` carrying `Co-Authored-By: Claude` plus 1 carrying a `Claude-Session:`
  permalink, out of 47**. Those were invisible to an entry that only ever looked at PR
  bodies. (One apparent hit, PR #26, is a false positive: the match is prose *about* an
  AI-attribution check that was considered and rejected, not a byline. A grep for this
  cannot tell the two apart, which is worth knowing before anyone automates it — and this
  is not hypothetical. The global pre-PR attribution hook **blocked this very PR**, because
  the body quoted the byline while describing having removed it. A substring match cannot
  distinguish the check from the thing checked for, so the body had to be reworded to
  describe the byline without reproducing it. The prediction in the sentence above was paid
  within the hour of being written, which is the same lesson the shellcheck pin taught.)
  **The history half is deliberately not actioned, and it is not a P4.** Removing those
  trailers means rewriting 15 commits and force-pushing `master` on a **public** repo:
  every SHA downstream of the first rewritten commit changes, existing clones diverge, and
  merged PRs' commit links rot. That is a destructive, outward-facing, one-way operation and
  it is the repo owner's call, not something to fold into a docs PR. The alternatives are to
  accept the history as-is (it is already published) or to rewrite deliberately with the
  cost understood. Recorded rather than decided.
  (observed 2026-08-03; PR bodies stripped and history measured 2026-08-16) **Priority:** P3

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
  on a number.
  **Trigger evaluated 2026-08-17 and deliberately NOT met.** Two PRs have merged since the
  first triage: #33, which *was* the triage's own follow-through, and #32, a dependency bump
  that touches no entry but its own. Re-triaging a file one day after it was triaged would
  measure the triage, not the file. Recorded so the next pass can tell "not due" from
  "forgotten" — the failure mode this entry exists to name is silence, and a trigger that is
  checked and not met is only visible if the check is written down.
  (todos archive, 2026-08-14; first triage 0.12.0, 2026-08-16; trigger re-checked 2026-08-17)
  **Priority:** P3
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
  next one.

  **Third pass, 2026-08-17: one entry archived (#26), six rules lifted** — a whole
  `## Reviewer scope and severity` section (what a reviewer BLOCKS is the remit that
  matters; do not disclose an axis as unowned in the same run that scanned for it; the
  rejected attribution check and why it stays rejected for a plugin other people install)
  and three test rules (fixtures generated never committed; a silence-asserting suite needs
  a trust check that runs first; `mktemp -d` failing under `set -uo pipefail` without `-e`
  writes to an absolute `/fixtures` and succeeds silently as root). The sixth carries its own
  exception, per the rule below it: **pin a blind spot as expected-silent only when this repo
  owns the rule, never when the engine does** — `.mts`/`.cts` is deliberately unasserted
  because a future semgrep fix would turn the suite red.
  **What this pass adds to the finding: the extraction is not the only unverified half —
  the CUT is too.** Nothing checks that `## Completed` is current before entries are moved,
  and the check has now caught something **both times it has been run**: pass 2 found the
  section stale by three merged PRs, pass 3 found it stale by two (#33 and #32, merged
  2026-08-17 within 19 seconds of each other). Two for two is not a coincidence — the
  section goes stale by construction, because the entry describing a PR can only be written
  after that PR merges, and by then the branch that would have carried it is gone.
  **And this pass finally put a verifier on the extraction — the result was the opposite
  of the one the entry predicts.** The gate fired `security-reviewer` on the docs-only diff
  with a docs-accuracy remit: check the new `CLAUDE.md` claims against the code rather than
  reading them. It returned PASS with three Low findings, and **all three were in the
  freshly-authored python3 bullet; zero were in the six extracted rules** — of which it
  verified **five**, against `rules/env-config.yml`, `agents/security-reviewer.md`,
  `test/rules-test.sh` and `skills/gate/SKILL.md`, and found correct. The sixth, the
  disclosure rule, it did not check at all: that one is a policy rationale with no code
  that settles it, so zero findings against it is absence of evidence, not evidence of
  absence. (The first draft of this paragraph said all six were verified and named three
  files; the reviewer, asked explicitly whether it had been misquoted, said yes. Worth
  keeping in the record — the entry is about unverified extraction, and its own write-up
  needed a verifier.) With that correction the distinction is n=1 and rests on a set with
  one unchecked member, but it still points somewhere:
  extraction *copies prose that was already checked when the entry was written*, so it
  inherits that verification; writing a rule fresh from a live enumeration does not, and
  fresh authorship is where the defects entered. The three: a printed `git grep -l python3`
  that returns **19** unscoped where the claim needs the `-- 'scripts/*.sh' 'ci/*.sh'`
  pathspec to return six (in the bullet whose whole point is that text matches overcount);
  a stated non-goal that named only the toolless-box reach of the raw-passthrough posture
  and missed `snapshot_manifest`'s parse-failure fallback, which fires with `jq` live and
  both hooks un-bailed; and "four call sites" four lines under "five shipped sites", where
  one counts scripts and the other invocations. All three fixed before the marker was
  written. **The load-bearing claim held** — the reviewer independently traced
  `normalize_manifest` → `snapshot_manifest` → `is_fresh` and confirmed the degraded arm
  cannot produce a false PASS, for a stronger reason than the prose gave: `cat` is the
  identity on the manifest bytes, so it partitions manifest states more finely than the
  `jq` arm and cannot conflate two the canonical path would separate.
  (todos archive, 2026-08-14; second pass 2026-08-16; third pass 2026-08-17) **Priority:** P3
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

Back to five as of archive pass 4 (2026-08-18), which cleared the deferral the 0.13.0
entry recorded: the split was held back deliberately so a four-figure prose diff would not
bury a script change, and it shipped on its own branch instead.

At **six** since 0.13.1 (2026-08-19) — the section drifts above five between archive
passes and is cut back at the next one; it is not trimmed entry-by-entry.

- **A security assertion was pinned by a hand-copied literal, and forgetting to update it
  was the one failure in this repo with no red anywhere.** Shipped on
  `fix/e17-derive-payload` as **PR #TBD, merged `TBD`, 2026-08-19** (0.13.1). Written in the same commit as the
  work, so the PR was current the moment it opened and the number was not knowable then —
  *next sweep: stamp the PR number and merge SHA here.*

  **The defect is the absence of a signal, not a wrong answer.** E17 asserts that
  `_env_ok` is anchored at *both* ends by handing `forgeward-write-marker.sh` the probe's
  genuine output with a forgery appended. For that to test the trailing anchor, the opening
  bytes must be a shape `_env_ok` accepts — and they were typed by hand, with nothing
  comparing them to the probe. Add a field to the probe, leave the copy alone, and the
  payload is refused on its **prefix** instead: `notforged` still returns true, E17 still
  prints `ok`, and dropping the trailing `$` — the exact one-character regression E17 exists
  to catch — reddens nothing at all.

  **It read as handled precisely because it had always been handled.** The copy moved twice
  and both times correctly (`seo_posture` 0.9.0, `config_warnings` 0.13.0). The obligation
  was written in three places and honoured on both occasions. What kept E17 honest was a
  person remembering; the failure mode of forgetting was silent, while the other two legs of
  the same obligation are loud (a stale `_env_ok` reddens E10 and degrades every marker to
  `{"probe":"unavailable"}`).

  **The fix deletes the copy rather than warning about it harder.** E17 derives its prefix
  from `$E1J` — the live probe captured at E1 with all three roots neutralised — so a new
  field is in the payload the moment the probe emits it. `grep` confirms no literal copy of
  the probe's output line remains anywhere in the suite. A probe field is a **two**-file
  edit again, stated at the `printf` itself.

  **Non-goals, in the test and in `DECISIONS.md` rather than left implied.** It cannot see
  `_env_ok` falling behind the probe — that direction refuses the derived prefix, degrades
  the marker, and greens E17 for the wrong reason; **E10 reddens there**, and neither
  assertion is sufficient alone. It does not decouple the probe from the marker writer; that
  coupling is a separate open P2 whose price this dropped from three files to two. The
  emptiness floor checks that `$E1J` *looks like* a probe line, not that it is correct — E1,
  E2 and E9 own that.

  **The P2's revisit trigger was re-evaluated, not actioned.** The probe is past "a handful
  of fields", so the trigger is met — but the remedy the entry named ("take the parser
  dependency") is refused by `CLAUDE.md`'s one-reader-per-shape rule and by
  `forgeward-write-marker.sh` sitting on the **push-authorizing** path, where an interpreter
  present on the author's box and absent on an installer's decides whether a marker is
  written. Recorded in the entry so the trigger is not re-derived every pass; the entry
  stays open.

  **MUTATION — both directions, and the decisive leg is the last pair.**
  Every mutated leg printed a verification line confirming its mutation was actually present
  before the suite ran — a green from a mutation that silently failed to apply proves nothing.

  | mutation | gate suite | E17 |
  |---|---|---|
  | base (unmutated) | 194/0 | `ok` |
  | drop the `$` from `_env_ok`, nothing else | 193/1 | **RED, and only E17** |
  | 8th probe field + `_env_ok` updated (the correct two-file edit) | 194/0 | `ok` — no test edit needed |
  | …that field addition **plus** the dropped `$`, with this commit's E17 | 193/1 | **RED** |
  | …the same, with **master's** E17 | 194/0 | **GREEN** |

  The last two legs are byte-identical apart from which `test/gate-test.sh` runs. Master's
  leg prints *"a valid-prefix-plus-appendix splice is rejected (the shape match is anchored
  at BOTH ends)"* — its own unchanged wording — while the anchor it names is gone.

  Isolated outside the harness, same scripts, anchor dropped: the derived payload writes a
  marker carrying `diff_hash=TAILFORGE` — the forgery lands, `notforged` fails, E17 reddens.
  Master's stale 7-field payload writes a marker carrying the **real** diff hash: refused on
  its prefix, `notforged` returns true, E17 greens.

- **Archive pass 4: the currency check came back CLEAN for the first time, and the cut
  arithmetic was wrong until it was written down.** Shipped 2026-08-18, docs only — no code,
  no version bump. Clears the deferral the 0.13.0 entry recorded, which held this split back
  on purpose so a four-figure prose diff would not bury a script change.

  **CURRENCY — clean, and that is news.** Passes 2 and 3 both caught `## Completed` stale,
  and pass 3's entry called two-of-two "a pattern, not an accident". This pass enumerated
  every merged PR with `gh pr list` and mapped it against the section rather than eyeballing
  the newest date: 8 entries covering **#28–#36**, with **#32** (the `actions/checkout`
  bump) folded into #33's entry rather than carrying one of its own, and nothing merged
  after #36. No gap. The check still had to run to establish that — a clean result and an
  unrun check are indistinguishable from the page.

  **MERGE ORDER — the trap did not fire this time, and the check still ran.** `git log` on
  all eight merge commits put #28 < #29 < #30 < #31 < #33 < #34 < #35 < #36, so PR-number
  order and merge order agreed and any sort would have produced the same cut. Pass 3 hit the
  inversion (#26 merged 39 minutes *after* #27) and `CLAUDE.md` now carries the rule; this is
  what it looks like when a rule costs one command and buys nothing on a given day.

  **CUT — four entries, not three, and the first plan said three.** Landing at "the 5 most
  recent" means cutting **four** when the pass writes its own entry back, and the first
  boundary drawn here was three, which would have left six. Caught by re-deriving the
  arithmetic before the cut rather than after. Archived #31 (`9cddc11`, 0.12.0), #30
  (`5144a37`, 0.11.0), #29 (`2844886`, 0.10.1) and #28 (`ce69eb5`) to `TODOS-DONE.md`,
  newest-first at the top: **18,863 bytes**, in the same commit that removed them.

  **EXTRACTION — three rules lifted, and the thinness is the evidence the ratchet works.**
  Most of what these four entries produced was already in `CLAUDE.md`: the `python3 -I` rule
  with its no-jq scope limit, the `export LC_ALL=C` pin with its deliberate `test/`
  exception, "pin the VIOLATING form and guard the enumeration against emptiness", the
  merge-order cut rule, and "a filing-only PR still gets a `## Completed` entry" all landed
  in pass 3. What was *not* yet written down, and is now:

  - **Rewriting a tracked script in place must preserve its mode.** `awk … > tmp && mv`
    recreates at the umask default and silently de-executed eleven scripts when the
    `LC_ALL` pin landed. A29 pins it; the rule was only ever in the archived entry.
  - **When a filter caused the miss, delete the filter — do not extend it.** From the
    rotation notice's `--include='*.jsonl'`, which could not see `tool-results/*.txt`.
  - **A search over evidence that expires must report an empty result as UNVERIFIABLE.**
    From the `cleanupPeriodDays` measurement, and it binds the filed
    `forgeward-transcript-audit.sh` before that script exists.

  **MEASURED, because pass 3's entry says to.** `TODOS.md` went **117,273 → 102,241
  bytes**, a net **−15,032** after writing this entry back — against pass 3's net
  −1,392 on 85,990. Four entries out instead of one is the whole difference; the convention
  bounds the entry COUNT, and the byte count follows only from how many you cut. It is still
  roughly **2× the ~50KB threshold**, and the reason is unchanged and structural: the open
  half is **73,484 bytes across 10 topic sections, 72% of the file**, and nothing in this
  pass touches it.

  **What this pass did NOT do, stated so the numbers are not read as health:** it expired
  nothing. A stale-but-open entry and a live one are indistinguishable to an archive pass,
  and the open half grew as a share of the file (63% → 72%) precisely because only the
  completed half was cut. Triaging the open half is a different job with a different risk —
  archiving is reversible and pruning is not — and it remains undone.

- **P2: `.forgeward/config.yml` said nothing when it was read and discarded.** Shipped on
  `feat/config-warnings` as **PR #36, merged `e250ec8`, 2026-08-18** (0.13.0). Stamped by
  this sweep; the entry was written in the same commit as the work, so the PR was current
  the moment it opened and the number was not knowable then.

  The probe gained `config_warnings`, an integer count of settings it was addressed by and
  could not use, and the gate renders one line when it is non-zero. **Visibility only — every
  rule in the reader accepts and rejects exactly what it did before**, verified by the whole
  pre-existing E1–E27 block staying green unchanged. The counters are appended after every
  existing rule precisely so they cannot shadow one.

  **Two deliberate non-fires, and the second is the load-bearing one.** An empty item
  (`substitutes: []`, a trailing comma) names nothing, so nothing was discarded. And
  `seo.routes` plus its whole subtree is skipped by indent, because it is documented as
  unhonoured in README, `skills/gate/SKILL.md` and `agents/seo-reviewer.md` — a count that
  fires on a configuration that followed the docs trains the reader to ignore the count.
  That is the one place this reader treats indentation as structure.

  **`0` is not a clean bill, and this is now written in three shipped files** because it is
  the trap the field creates: a config the probe could not open at all also reports `0`, and
  only the separate `config` field distinguishes them. The live-test's symlink step is
  written as exactly that trap.

  **The vacuity direction here is the reverse of E1/E2's.** Nine of the ten new assertions
  want a non-zero count, so a counter stuck on `1` would green all nine while being useless;
  E28 (a fully-honoured config) and E34 (`seo.routes` plus subtree) are the only two
  asserting `0` and exist as that control. Confirmed by mutation: `warn()` as a no-op reddens
  exactly E29–E33 and E35–E37, flooring the count at `1` reddens exactly E28 and E34, and
  neither touches anything outside the block.

  **The three-file obligation was exercised for the second time and both failure modes
  re-measured rather than quoted** — see the entry under `## Standalone posture`. Suites at
  HEAD: gate 194/0, pre-push 15/0, rules 39/0, version-check 51/0.

- **P3: the two-arm unknown-mode divergence closed, and the fix's own guard turned out not
  to halt.** Shipped on `fix/normalize-manifest-mode-divergence` as **PR #35, merged
  `840d936`, 2026-08-18** — stamped by this sweep, as the placeholder that stood here asked
  for.

  **The fix is structural, not behavioural, and that was the choice.** The entry named
  aligning the two arms as the remedy; aligning them leaves two implementations that can
  drift again, which is precisely how this bug was born from the `top`/`plugins` alignment
  that preceded it. Instead the unknown-mode question is now asked **once, above the
  interpreter split**, and the `jq` arm's `*) cat ;;` — the arm that used to answer it —
  was deleted rather than mirrored. A second answer sitting beside the first is what
  invites someone to "fix" one branch to match the other. Raw passthrough is the answer
  because it matches the no-tool `else` arm: an unhandled manifest is hashed whole, so a
  version bump re-gates.

  **`exit 1` inside `$( )` kills the subshell, not the script — and this was found by
  running the fix, not by reading it.** `snapshot_manifest` gained a mode guard ending in
  `exit 1`; every call site is a command substitution, so the first version printed the
  guard's message to stderr, assigned an empty part, and emitted **a perfectly ordinary
  hash with status 0** — a louder version of the silence the guard was added to break.
  Fixed with `|| exit 1` on all three calls. `set -uo pipefail` does not catch it — there
  is no `-e`.

  **`-e` is not the reason, and three separate drafts of that claim were wrong — the
  errors are the part worth keeping.** Draft one asserted, without measuring, that `-e`
  "does not, reliably, across shells" catch an assignment from a substitution; measured,
  it **does** halt this exact shape on bash 5.1.16 and bash 5.3.15, and the `&&`-guarded
  appends survive it because a failing left operand is exempt. Draft two added dash to
  that list on the strength of a non-zero exit; that exit was `rc=2` from `Illegal option
  -o pipefail` at the `set` line, so the script never ran — **a non-zero exit is not
  evidence of the mechanism you are testing for.** Draft three, written *inside* the
  correction to draft one, said `-e` "changes the error semantics of every other command
  in the file"; enumerated, the only statement that changes is the unguarded
  `diff_part="$(git diff …)"` assignment. The real argument for `|| exit 1` is scope and
  locality over **one** line, not correctness over a file. That last claim is a universal
  in a bullet already wrong three times, so it is measured twice: `grep` finds exactly one
  unguarded assignment-from-substitution in the file, and an eight-case failure battery
  (bad base, bad tip, dash-led base, non-repo cwd, no jq, no python3, empty base,
  baseline) halts at that same statement in every divergent case and is byte-identical in
  the other four.

  **The repo sweep that shipped with this was wrong three times, and the method matters
  more than the list.** It filed `check_root` as exit-bearing — it is not; it returns 0/1
  and the `exit 0` sits at its *call site*. It missed `deny` entirely, because the `sed`
  range used to read function bodies ends at `/^}/` and `deny` emits a JSON heredoc whose
  closing brace is in column 0, so the range stopped short of its `exit`. And it had **no
  transitive tier at all**, so it read as complete while omitting three functions that
  exit by calling one that does — caught in round 3, where the reviewer flagged
  `_gl_target_guard` and re-enumerating turned up `require_blob` as well.

  Corrected and verified both directions: **direct** exits are `die`, `reject`, `deny`,
  `snapshot_manifest`; **transitive** are `out_reject` and `_gl_target_guard` (→ `reject`)
  and `require_blob` (→ `die`); and among the functions invoked inside a command
  substitution, `snapshot_manifest` is the only one that can exit. The rest return — and
  where one sits near an `exit`, that `exit` is at top level, after the body. That is
  precisely the trap `check_root` fell into.

  **Then a fourth draft was wrong too, and that is what settled the shape of the fix.**
  Round 4 caught the replacement asserting "thirteen functions are invoked inside a
  substitution" when a pattern that also matches pipe tails finds fifteen — and fifteen is
  not asserted as final either, it is just what the better method saw. Matching `$(fn`
  catches only a substitution's *first* stage, so `normalize_manifest` and `read_version`,
  both at the tail of a pipe inside `$( )`, were invisible. Four drafts, five distinct
  mechanisms once they were separated properly, one shape:

  | mechanism | effect | victim |
  |---|---|---|
  | `sed` range ends at `/^}/` | truncates at a heredoc's column-0 brace | `deny` |
  | same range vs. a one-liner def | overruns into a genuinely later function | `warn` (span 146) |
  | last def in file — no terminator | body runs to EOF, swallowing the call site | `check_root`, `snap` (×2) |
  | pattern anchored to `$(fn` | misses a pipe's tail stage | `normalize_manifest`, `read_version` |
  | `grep exit` counts comments | false positive | `read_version` |

  All five fail silently. **So the count was removed rather than corrected to fifteen** —
  a closed census that has been wrong every time it was asserted is the wrong shape for a
  shipped doc, and the safety property never depended on it. `CLAUDE.md` now states the
  property and the method, plus explicit non-goals. The property itself survived every one
  of these errors untouched; only the prose around it kept breaking.

  **And then the table above was wrong twice, which is the fifth iteration and the one
  that justifies the whole approach.** Round 5's reviewer caught the first: the one-liner
  row cited `honor_cd`, which is a four-line function at `forgeward-gate-check.sh:186-189`
  and has never been one line. Pushing on its second note — that it could not verify
  `check_root` as the one-liner-overrun victim — found the other, and the reviewer was
  right to doubt it: `check_root` closes at a column-0 `}` at
  `forgeward-detect-gstack-skill.sh:127` like any ordinary block, so that mechanism cannot
  be what misfiled it. The real one is that it is the **last** definition in its file, so
  an attributor with no closing-brace tracking runs its body to EOF and charges it with
  `check_root … && exit 0` at `:146` — its own call site — and `exit 1` at `:149`. Both
  rows are now corrected above. **A table explaining four bad scans was itself a bad scan**;
  prose describing a sweep is a sweep, and nothing re-runs it.

  **And then it was wrong a third time, in the same row, caught by round 7.** The
  one-liner-overrun row also cited `snap` in `forgeward-scan.sh` and
  `forgeward-workspace-guard.sh`. It is not that mechanism either: `snap` is the **last**
  definition in both files (`:321` of 358, `:48` of 71) and neither file has a later
  column-0 `}` at all, so the range runs to true EOF — the same mechanism as `check_root`,
  one row down. Moving it leaves `warn` as the overrun row's only instance in `scripts/`,
  and `warn` genuinely is one: defined at `forgeward-detect-base.sh:97`, next column-0 `}`
  at `:242`, so the range crosses into a later function's body. **Three corrections, two
  of them in the same row, all found by a reviewer rather than by me.** The row that keeps
  breaking is always the one asserting *which function* illustrates a mechanism — never
  the mechanism itself, never the safety property.

  **And the correction to that row introduced the next error, which is what finally
  identified the generator.** The rewritten text listed which `exit`s each `snap` range
  swallows, joining an exhaustive list for one file to an incomplete one for the other
  with "respectively" — so the incomplete half read as complete. It was caught in the very
  next round, in text written by the round before it. The verification pattern I used is
  what produced it: anchored to `exit` at a line start or right after a separator, it
  silently skipped the indented ones. **Each amend adds prose about the last correction,
  and that new prose is the next round's failure surface — so correcting sustains the
  loop rather than ending it.** The move that actually terminates is a **subtractive**
  edit: the itemized list was deleted, not completed, and replaced with the
  non-exhaustive phrasing the row above already used. Which `exit`s get swallowed was
  never load-bearing; the mechanism is that the range reaches EOF at all. **Prefer
  deleting a detail to correcting it, whenever the detail carries no weight** — a
  completed enumeration is still an enumeration, and it can rot the moment either file
  changes.

  **The units were inconsistent too, and that is the smaller finding with the longer
  reach.** "Up to 145 lines" for `warn` counted the span minus the definition line, while
  63/384/179 for the `test/` trio counted the raw span — two conventions in one document,
  presented as directly comparable. Both are now the raw span that
  `sed -n '/^fn()/,/^}/p' FILE | wc -l` returns, and `CLAUDE.md` now quotes that command
  next to the numbers. A figure without the command that produced it is not checkable, and
  an uncheckable figure in a doc about verification is the thing this entry is about.

  **Non-goals, now quantified rather than directional.** The sweep covers **12 of the 21
  tracked shell files**: 11 in `scripts/`, 1 in `ci/`. The 9 in `test/` and `live-test/`
  are excluded on purpose — a substitution-swallowed `exit` in a harness corrupts a test
  result, not a marker, so it cannot produce a false PASS. That is a blast-radius
  judgement, not a claim they are clean, and spot-checking proves the distinction matters:
  **three of the five mechanisms reproduce** in files no sweep has ever read, with one
  example each rather than three of one —

  | mechanism | reproduced in `test/` |
  |---|---|
  | one-liner overrun | `denies`, `gl`, `_hook_path` in `gate-test.sh` — spans 63, 384, 179 |
  | comment/string false positive | `expansion:26`, `det:2169` — both `-> exit code` in the def-line comment; `pre-push-test.sh` past `:144` — one comment, two message strings |
  | last def → body runs to EOF | `rules-test.sh:204` last def, top-level `exit 1` at `:257` |

  The first draft of this paragraph cited only the three one-liners and still said "three
  of the five mechanisms" — a true claim carrying evidence for a third of itself, which is
  the same shape as everything else in this entry. Verified the population is complete
  rather than sampled: no tracked file carries a shell shebang without a `.sh` extension,
  and `hooks/` holds only `hooks.json`.

  **Row 3 lost half its evidence in round 7, and the way it lost it is the entry's thesis
  in miniature.** It originally read `pre-push-test.sh:144`, `rules-test.sh:204`, "each
  with a top-level `exit` after". True of `rules-test.sh`. False of `pre-push-test.sh`:
  `ppjq()` at `:144` is genuinely its last definition, but **no executed `exit` follows it
  at all** — the file terminates on the bare status of `[ "$FAIL" -eq 0 ]`, and the three
  lines after `:144` carrying the word are the comment at `:148` and the `ok`/`nok`
  strings at `:154`/`:155`. So it was never an EOF instance; it is a **fourth instance of
  the comment/string false positive**, and it has been moved to row 2. A citation for the
  comment-false-positive mechanism was itself produced by the comment false positive.

  **Both new assertions were proven red on the old code before being wired in.** V9 (the
  two arms agree on an unrecognised mode) fails on `origin/master` with
  `jq='{"b":2,"a":1,…}'` against `py='{"a":1,"b":2,…}'` — the divergence itself, visible in
  the key order. V10 (a bad mode at a call site halts with no hash) fails on old code with
  `rc=0` and a legitimate-looking hash. A test that has never been observed to fail is a
  claim about the code, not evidence about it. Suites after: gate-test 184/0, pre-push
  15/0, rules 39/0, version-check 51/0.

  **No marker churn, and this was checked rather than assumed.** Running the old and the
  new script over the same input gives identical canonical bytes on both the `jq` path and
  the python3-only path, so no repo takes a re-gate for this. That mattered enough to verify
  because the script header records a prior alignment whose byte change cost a release of
  its own — the one-time cost is paid when the *reachable* modes move, and these did not.

  Quoted against a **fixed** range, `origin/master~1..origin/master`: all four combinations
  — {old script, new script} × {jq, no jq} — give `33751462a160ba83df171dfe`. **The fixed
  range is load-bearing.** This paragraph previously quoted the hash of
  `origin/master...HEAD`, which is a hash of the branch's *own diff* and so changes with
  every amend; it was stale before anyone could read it. A number that the act of committing
  invalidates is worse than no number, because it looks verifiable. It also survived one
  round longer than the same error in the commit message and the PR body, both of which were
  corrected while this file was not — two tracked files disagreeing inside one commit, which
  is a failure this very entry records happening earlier on the same branch.

  The first attempt at the no-jq arm compared two **empty** strings and reported a match:
  the shim `PATH` was hand-listed and missing tools the script needs, so both sides failed
  identically. That is the green-on-an-empty-set failure the `nok` arms added to V9/V10 in
  this same commit exist to prevent, committed while verifying the commit that argues for
  them. Redone by mirroring the whole real `PATH` minus `jq` and asserting non-emptiness
  before comparing.

  **The residue is filed, not waved off:** both guards sit on paths no call site reaches,
  so V9/V10 are the entire detection surface and both are text-coupled to the script. That
  is an open P4 under `## Gate — base detection and freshness`, not a closed question.

- **Archive pass 3: the currency check caught staleness for the second consecutive pass, and
  the PR's own headline count was wrong.** Shipped 2026-08-17 as #34 (`f0ac18e`), docs only —
  `CLAUDE.md`, `TODOS.md`, `TODOS-DONE.md`, +385/−100. No version bump (0.12.0 unchanged).

  **CURRENCY.** `## Completed` was stale by two merged PRs — #33 (`8baee22`) and #32
  (`11af421`), nineteen seconds apart — both written up from their commit bodies before
  anything moved. Pass 2 found it stale by three, pass 3 by two. **Two for two is the
  mechanism, not luck:** the entry describing a PR can only be written after that PR
  merges, and by then the branch that would have carried it is gone. The convention's
  *cut* step is still unverified by anything; only the extraction was ever named.

  **CUT.** One entry archived: #26 (`41324b0`, 0.10.0). Inserted at the TOP of
  `TODOS-DONE.md` rather than below #27, because #26 merged 39 minutes *after* #27 despite
  the lower number — established with `git log --first-parent`, not from the number or the
  date, which is what that file's header tells the next reader to do.

  **EXTRACTION — and the count in the title is wrong.** The squash title says seven rules,
  the commit body says six, and the merged diff adds **eight** bullets to `CLAUDE.md`
  (`git show f0ac18e -- CLAUDE.md | grep -c '^+- \*\*'`), none of them a move: zero bullets
  were removed, and neither `An interpreter dependency's posture…` nor `Pin a blind spot as
  expected-silent…` existed at `f0ac18e^`. The body's six was true when the first commit was
  written; two more landed in later commits on the same branch and neither the body nor the
  title was re-derived. **A count written before the branch finished is a claim about a
  draft, not about what merged** — the only moment it can be true is after the last commit.
  Recorded rather than silently corrected because the drift is the finding: the same PR that
  lifted "state only what you actually checked" into `CLAUDE.md` shipped a headline number
  that had gone stale inside its own branch.

- **P3 ×4 + P4: four entries were closed by going and measuring them, and three of the four
  measurements contradicted the entry.** Shipped 2026-08-17 as #33 (`8baee22`), docs and CI
  config only — no executable code, no version bump (0.12.0 unchanged; the monotonic rule is
  never-backward, not always-bump). `#32` (`11af421`, `actions/checkout` 4.4.0 → 7.0.1)
  merged 19 seconds behind it.

  **Dependabot stopped being an unverified automation.** The entry led with "configured but
  has never been observed to run, and an unverified automation reads as coverage", and that
  closed the same day it was written: #32 opened at 20:14 UTC, ~4 hours after
  `.github/dependabot.yml` merged, and merged 2026-08-17. Service enabled, schedule fires
  with nothing switched on in Settings, `actions` group name resolves. **The prediction the
  entry recorded held exactly** — it said to expect a *major* bump needing reading rather
  than merging on the tick, and a three-major jump arrived. The bounded-not-open claim was
  confirmed from #32's own rollup rather than assumed: `suites`, `shell`, `monotonic` all
  SUCCESS, four `sweep` entries correctly SKIPPED. **The lesson that outlives it: an
  automation nobody has watched run is a claim, not a control**, and the check that settles
  it is one glance at the PR list.

  **The flake sweep ran clean and still does not settle its question.** `workflow_dispatch`
  run `31970233140` on `master`: 25 runs, clean=25, `s7_fail_open=0`, `other_failures=0`,
  `harness_rc=0`, at `FORGEWARD_S7_LOAD=4`. First in-CI measurement of the load-sensitivity
  claim. Zero failures in 25 runs puts the 95% one-sided upper bound on the per-run flake
  rate at **11.3%** — and an 11% flake on a required check is precisely the failure the entry
  was opened to avoid, so **a clean sweep at n=25 is consistent with the outcome it was meant
  to rule out**. 25 is the harness default, not the number that answers the question. Costed
  the decisive version (n≈300 → 1.0%, ~2h of free runner time) and set the revisit trigger at
  n≥100 with zero flakes, which `test.yml` accrues passively for nothing.

  **The attribution entry undercounted its own scope, and sweeping is what showed it.** It
  named "the three merged PR bodies", which reads as the complete set; the bylines were
  stripped from #1/#2/#3 and re-read back from GitHub to confirm. Sweeping *every* PR, issue
  and commit then found **14 commits on `master` carrying an AI co-author trailer and one
  carrying a session permalink, out of 47** — invisible to an entry that only looked at PR
  bodies. Deliberately not actioned: it means rewriting 15 commits and force-pushing a
  **public** `master`, which is the owner's call. One apparent hit (#26) is a false positive —
  prose *about* a rejected attribution check — and **that got demonstrated live**: the global
  pre-PR hook blocked #33's own body, because the body quoted the byline while explaining it
  had been removed. A substring match cannot distinguish the check from the thing checked
  for. The prediction was paid within the hour of being written.

  **The python3 entry overstated its own scope.** It called python3 "the only external tool
  any script in this repo needs"; `test/rules-test.sh` needs `semgrep`, which degrades to a
  loud `1..0 # SKIP` rather than failing — precisely why it read as not-a-dependency. **A
  tool whose absence turns a suite green is still a dependency.** README now names both and
  states the distinction most likely to mislead: hooks read JSON with `jq` *or* `python3` and
  fail open, while `ci/check-version-monotonic.sh` requires it and fails closed.

  **Two shipped files disagreed about a fact they shipped together.** `.github/dependabot.yml`
  non-goal 3 said a version pinned inside a script does not exist here "today";
  `.github/workflows/shellcheck.yml`, same release, pins `SHELLCHECK_VERSION` in `env:` and
  downloads it in `run:` — and its own header states that limit from the other side. Also
  "across three workflows" where four carry a `uses:` site. Both corrected with the original
  wording quoted, so the correction is legible rather than silent.

  **README's Validation section was stale in three places**, all found by re-running rather
  than re-reading: "**Both** are framework-free" over **four** suites; `gate-test.sh` "(173
  assertions)" against a measured **182**; and a sentence whose entire job was to say the
  suite is "unchanged" carrying a count of 24. Counts now live in one place and the two
  previously undocumented suites (version-check 51, rules 39) are described. **A number
  nobody re-measures is a number that rots** — the one that existed only to say "unchanged"
  is gone.

  **Two cross-repo line citations into gstack became symbol references** and are labelled as
  pointers into a repo this one neither controls nor can keep current. Both were verified
  correct first: the claim was right, the citation *form* is what `CLAUDE.md` forbids. A
  third apparent stale citation was deliberately left alone — it sits inside a `## Completed`
  entry that is itself narrating that citation going stale, so it is quoted provenance, not a
  live reference. And the wip-tag decision got the fact it turns on: `item2-wip-quote-stripping`
  is local-only and `c7e56d0b` is not an ancestor of `origin/master`, so "keep it as an
  archaeological record" was never the status quo — the status quo is *ephemeral*.
