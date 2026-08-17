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
- **`normalize_manifest`'s two arms disagree on an unknown mode, which is the exact
  divergence class its own header forbids.** `scripts/forgeward-diff-hash.sh:69` says
  **"THE TWO BRANCHES MUST EMIT THE SAME BYTES, not merely the same semantics"**, and the
  paragraph under it documents a shipped bug of precisely this shape — `jq -S`
  pretty-printing where `json.dumps` was compact, so the same manifest hashed differently
  on a machine with `jq` than on one without, and a marker written on one read as stale on
  the other. The alignment fixed `top` and `plugins`. It did not fix the default: the `jq`
  arm has `*) cat ;;` at `:103` and emits **raw** bytes, while the python3 arm has no
  default at all — an unknown mode falls past both `if`/`elif` and still reaches
  `json.dumps(d, sort_keys=True, separators=(",",":"))` at `:116`, emitting bytes that are
  **canonicalized but not blanked**. Same input, two different outputs, decided by which
  interpreter is installed.
  **Latent, not live, and the reason it is latent is worth stating precisely:** the three
  call sites at `:149-151` pass string literals (`top`, `top`, `plugins`), so the `*)` arm
  is unreachable today and the fail direction on every reachable path is re-gate, never a
  false PASS. It goes live the moment someone adds a fourth manifest and mistypes the
  mode — and the failure would be a marker that reads fresh on one machine and stale on
  another, which is the symptom the header says took a release of its own to fix.
  **Aligning the two arms is the fix; where the alignment is enforced is the part that is
  easy to get wrong.** Mirroring `cat` in the python3 branch closes the divergence — but
  **the mode has to be tested before `json.load`, not at the `if`/`elif` chain where the
  modes are currently handled.** `json.load(sys.stdin)` at `:108` drains stdin before that
  chain runs, so a `*)`-equivalent added alongside the existing branches — the natural
  reading of "mirror `cat` in the python3 arm" — reads an already-consumed stdin and writes
  nothing. It would *look* like it worked, because `:131` rescues the empty result back to
  `$raw`, which means the mirror would silently depend on the very fallback this entry
  exists to say is not a control. Test the mode first, write `sys.stdin.buffer.read()`
  straight out. Adding an explicit die on an unrecognised mode
  *inside* `normalize_manifest` does not do more than that, and the first draft of this
  entry claimed it did: `snapshot_manifest` swallows the die twice — the `2>/dev/null` at
  `:130` discards whatever it writes to stderr, and `|| out=""` followed by
  `[ -z "$out" ] && out="$raw"` at `:131` converts the non-zero status into raw
  passthrough, which is **byte-identical to the mirrored-`cat` option and exactly as
  silent**. For a die to be visible it has to be checked before that fallback — validate
  the mode in `snapshot_manifest` ahead of `:130`, or at the top-level caller — or the
  `2>/dev/null` has to be narrowed so a mode error survives while parse noise stays
  suppressed. Not fixed in this PR: the branch is docs-only and a change to executable
  behaviour does not ride along with prose.
  (security review, archive pass 3 branch, 2026-08-17) **Priority:** P3

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
  baseline is zero and a genuinely-wrong SC2016 still fires. It installs a **checksum-verified
  v0.11.0** rather than using the runner's: it shipped unpinned in this same PR, went red on
  the first run against `ubuntu-latest`'s 0.9.0 over three SC2015 false positives, and the
  pin was the fix — suppressing them would have blinded three sites to satisfy a linter older
  than the code. `test/*.sh` is out of scope, 241 findings at that pin, stated in the workflow
  header so the tick is not over-read. `flake-sweep.yml`
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
