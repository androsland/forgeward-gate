# TODOS — completed

Completed work archived out of [`TODOS.md`](TODOS.md), newest first. It lives here
because `TODOS.md` is read in full on every pre-commit sweep, and finished work can
never be acted on by a sweep.

**Ordering is by MERGE ORDER, not by the `Fixed` date printed in an entry** — several
entries carry the same date, and #26 merged 39 minutes *after* #27 despite the lower
number, so both a date sort and a number sort get this file wrong. Resolve with
`git log --first-parent` before inserting anything.

Three passes so far: 12 entries at 0.10.0 (#27), 4 more at 0.12.0, and 1 on
2026-08-17. Each pass is relief, never a fix — `TODOS.md` was over the ~50KB
threshold after all three, and pass 3 measured *why*: it archived **6,883 bytes**
and wrote **5,491** back as the `## Completed` entry for the newly-merged work, a
net **−1,392 bytes on an 85,990-byte file**. **Keeping "the 5 most recent" bounds
the entry COUNT, not the byte count** — a pass removes one entry and adds one, so
the section's size tracks how large recent entries are, and nothing here caps that.
Anyone expecting this convention to shrink `TODOS.md` should stop expecting it;
what it buys is that a sweep reads five current entries instead of eighteen stale
ones. If the byte count is ever the actual problem, the lever is the open half
(59,964 bytes across 10 topic sections, 71% of the file), not this one.

Nothing was pruned. These entries carry the reversed decisions, the deliberate
non-goals and the "we shipped the narrow fix on purpose, here is what it does not
cover" that a later change needs before it re-opens the same ground. The rules worth
obeying were lifted into [`CLAUDE.md`](CLAUDE.md) on the way out, and this file is
their provenance — grep here before overriding one of them.

`DECISIONS.md` remains the source of truth for *why* a design is the way it is. This
file records what was done and what it deliberately left undone.

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

- **P3: the completed half of `TODOS.md` was pure carrying cost on every sweep — 12 entries
  archived, 12 rules lifted.** Shipped 2026-08-14 as #27 (`f148a6a`), docs only. This file,
  `CLAUDE.md`, and the convention both implement are what that PR produced, so this is the
  entry that describes the archive you are reading.

  `TODOS.md` is read in full on every pre-commit sweep and re-read from cache on every
  request after, while completed work is the one thing a sweep can never act on. The 12
  oldest completed entries moved here; the 5 most recent stayed, because those are the ones
  a sweep actually consults ("did I already do this?"). **One commit, not two** — an entry
  deleted from `TODOS.md` that never lands in the archive is invisible across two diffs and
  obvious inside one.

  **Nothing was pruned, and archiving alone would have made things worse.** These entries
  carry the reversed decisions and the deliberate non-goals, so moving them out of the swept
  read path makes that precedent *less* findable, not more. Twelve rules were lifted into a
  new root `CLAUDE.md` on the way out, with this file and `DECISIONS.md` as their provenance,
  cited **by symbol, never by line**: `TODOS.md` already carried one stale line reference,
  and the extracted file is meant to outlive line numbers.

  **Two things this pass found rather than moved.** `## Completed` was **stale by two
  releases** — the 0.9.2 secrets-scanner fix (#24) and its 0.9.3 follow-up (#25) had no entry
  at all, so "the 5 most recent" silently meant five older ones, and splitting on that would
  have mis-dated the archive permanently; the entry was written from the two commit bodies
  *before* the split, including the four gaps that shipped disclosed-not-fixed. And
  `DECISIONS.md` was newest-first for 15 sections with the 16th at the bottom — 2026-08-10,
  the newest of the lot, appended below a 2026-06-22 entry — so a top-down reader concluded
  2026-08-07 was the latest decision. Moved to the top, and the ordering is now stated in
  that file's header, since it broke for want of ever being written down. Verified as a pure
  move: the 228-line section is byte-identical at its new position.

  **The `-I` rule was extracted WITH its exception, deliberately.** At the time,
  `ci/check-version-monotonic.sh` was the only site carrying `python3 -I`;
  `forgeward-diff-hash.sh`, `forgeward-gate-check.sh` (×2) and `forgeward-pre-push.sh` did
  not, and that gap was already filed as a P3. Extracting the rule without the exception
  would have converted a filed hole into a false claim of coverage, so `CLAUDE.md` named the
  four sites and said not to read the rule as coverage. (Closed the next day by #30, which
  put `-I` at every site and pinned it with A25/A26 — the rule in `CLAUDE.md` now reads as
  coverage because it finally is.)

  **Filed, not fixed**, in a new `## Docs hygiene` section. The load-bearing one: **nothing
  verifies the rule-extraction step this convention depends on** — a pass that archives
  without lifting rules is a silent regression on precedent retrieval, and the archive named
  four pieces of reasoning that did not become rules. Also: the open half was still ~70KB and
  untriaged (the completed half was only 22% of the file, so a split is relief and never a
  fix), and `CLAUDE.md` now ships to plugin installers — inert in the cache, but keep it free
  of anything machine-specific.

  **Gated:** privacy fired and returned PASS; UI, LLM, public-pages, deps and code-security
  all skipped, the diff being four Markdown files. The elevated risk was specific — the new
  entry and the moved `DECISIONS.md` section both narrate a real incident in which a scanner
  read a developer's untracked `.env` into a persisted transcript — so the reviewer swept both
  files for credential shapes and found only the detection patterns themselves and an
  illustrative `://user:pass@`. It also re-derived the split arithmetic independently (16 + 1
  = 17, 5 kept, 12 archived, the archived block byte-identical to the original lines) and
  verified the `-I` count in **both** directions. One Low, fixed in place: the entry had dated
  the 0.9.3 docs correction 2026-08-10, which is the *security* fix's authored date; both of
  #25's dates are 2026-08-12.

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
