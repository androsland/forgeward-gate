# forgeward-gate — load-bearing constraints

Imperatives lifted out of completed work as it was archived. Each exists because
building the obvious thing instead turned out to be wrong, got reversed, or shipped a
bug. The narrative, the repro and the dates are in [`DECISIONS.md`](DECISIONS.md) and
[`TODOS-DONE.md`](TODOS-DONE.md) — grep there before overriding a line here.

Cited **by symbol, never by line**: this file outlives line numbers. `TODOS.md` carried
two stale line citations, and the second correction drifted *again* inside the same
commit that was fixing it — a line number cannot survive its own fix.

## Parsing untrusted input

- **One reader per shape — never add a second parser arm.** A `jq` arm and a `python3`
  fallback hashed the same manifest differently; three bugs in this file's history are
  the same class (`json_get`, `strip_quoted`, `marker_get`). If a fallback is
  unavoidable, a test must assert the two arms agree byte-for-byte.
- **Specifically: no PyYAML arm for `.forgeward/config.yml`.** `yaml` is not in
  `sys.stdlib_module_names`, so `python3` being present says nothing about `import yaml`
  working — the arm would be selected by what happens to be installed and would parse
  different shapes from the fallback, which is the 0.7.5 divergence exactly. The single
  `awk` reader was extended instead, verified identical under gawk, mawk and busybox awk.
- **Every `python3 -c` carries `-I`.** It drops the CWD from `sys.path` and implies
  `-E`/`-s`, so a `json.py` in the repo under review cannot be the module judging it.
  All five shipped sites have it, and A25 fails on any new one that does not. This is
  not hardening: A26 demonstrates an `-I`-stripped hook **allowing** a publish it
  should deny, and the shadowing file arrives with the branch you cloned to review —
  Python imports a file, not an index, so no write access to the checkout is needed.
- **An interpreter dependency's posture is decided by WHO RUNS THE SCRIPT, not by what the
  script does.** All four scripts that call `python3` read JSON, and they fail in three
  different directions on purpose. (Four *scripts*, five *invocations* — the `-I` bullet
  above counts the latter, and `forgeward-gate-check.sh` holds two of them.)
  - **CI-only code requires it and fails CLOSED.** `ci/check-version-monotonic.sh` dies with
    a named message (`python3 is required to read the manifests…`). A CI check that silently
    skips is worse than one that goes red, and `ubuntu-latest` ships python3, so the
    requirement costs nothing it does not buy.
  - **User-machine hooks treat it as optional and fail OPEN.** `forgeward-gate-check.sh` and
    `forgeward-pre-push.sh` each `exit 0` when neither `jq` nor `python3` is present, the
    pre-push one saying so on stderr. A hook that wedges the session is worse than one that
    under-enforces — and the server-side `ci-gate` is the boundary that does not depend on
    what is installed on a laptop.
  - **A helper on the gating path fails toward RE-GATING, never toward a false PASS.**
    `forgeward-diff-hash.sh`'s `normalize_manifest` falls through to `cat`, so the version
    field is never neutralized, the hash differs, and the marker reads stale. More gating,
    not less. Any new arm here inherits that obligation.

  **Two things this rule must not be read as claiming.** `git grep -l python3 -- 'scripts/*.sh'
  'ci/*.sh'` finds **six** scripts and only **four** call it — `forgeward-detect-environment.sh`
  and `forgeward-write-marker.sh` mention it in comments explaining why they deliberately do
  *not* take the dependency, so a text match overcounts the surface by 50%. Run that grep
  **unscoped** and it returns **19**, and the surplus 13 is not what it sounds like: **zero**
  reviewer prompts mention `python3`, seven docs/config files discuss it, and six `test/`
  harnesses match — of which **four genuinely invoke it**, `denies-race-probe.sh` names it
  in a comment, and `s7-flake-loop.sh:67` only runs `command -v python3` in a diagnostic
  line. So the unscoped count is not "shipped scripts plus chatter": it hides real call
  sites in `test/` behind files that only talk, and it flattens a **third** category —
  a PATH probe that never executes the interpreter, which is the same shape
  `forgeward-gate-check.sh:38` and `forgeward-pre-push.sh:46` use, except that there the
  probe sits beside a real invocation and in `s7-flake-loop.sh` it is all there is. The
  pathspec is what confines the count to *shipped* scripts, and quoting the command without
  it is the same error the bullet is about.
  **This paragraph was wrong three times before it was run** — first the unscoped six, then
  a wrong account of what the surplus 13 actually was, then five-invoke where it is four.
  Only the first and third were miscounts; the middle one paired a correct number with an
  invented reason, which is the same defect wearing a number that checks out. That is
  not an embarrassing aside, it is the strongest evidence the bullet has: the failure mode
  is not "someone else greps carelessly", it is that *counting matches is not counting
  behaviour*, and the person writing the warning is as exposed to it as the person reading
  it. And the third posture is narrower than it looks — but not
  as narrow as it first reads. `cat` at `normalize_manifest`'s `else` arm is reached only
  when `jq` **and** `python3` are both absent, which is the same condition under which the
  two hooks have already exited 0, so on that box enforcement is off regardless and the
  re-gate direction protects the marker *afterwards* rather than acting as a live control.
  The raw-passthrough **posture** reaches further than that branch does: `snapshot_manifest`
  falls back to `$raw` on any parse failure (`|| out=""`, then `[ -z "$out" ] && out="$raw"`),
  which fires with `jq` installed-but-broken or a malformed manifest — a box where neither
  hook has bailed and enforcement *is* live. The direction is unchanged, because raw bytes
  still carry the version field and so a bump re-gates; only the reach is wider.
- **`export LC_ALL=C` at the top of every tracked `*.sh` outside `test/`, and never a
  second locale mechanism beside it.** Both inline `LC_ALL=` prefixes were deleted when
  the script-wide pin landed, not kept — the two forms are not equivalent (`local` is
  not passed to a spawned child), so leaving both live is how the weaker one gets
  trusted. A27/A28 enumerate from `git ls-files`, so a new script is in scope the day
  it is added. `test/` is out of scope on purpose: the suite spawns these scripts, so a
  pin there would be inherited and make the property untestable from inside the test.
- **Rewriting a tracked script in place must preserve its mode.** `awk … > tmp && mv tmp
  script` recreates the file at the umask default, dropping 755 to 644. When the `LC_ALL`
  pin landed this de-executed **eleven** scripts at once and broke the plugin outright;
  every invocation became `Permission denied`, and the suite surfaced it only as 28
  unrelated assertions collapsing together, naming nothing. A29 names it now. Edit in
  place, or restore the mode explicitly, and read `git diff` for `mode change` lines before
  committing. Applies to tracked *executables* — `rules/*.yml` and the docs are 644 by
  design and must stay that way.

- **The matcher trusts `strip_quoted`'s residue only when it is never shorter than the
  input.** The residue's word boundaries are not bash's, so the three-character refusal
  is a complete cover rather than a heuristic — do not relax it into a pattern list.
- **The delete-only exemption (`_is_delete_only`) is offered on a trusted residue
  only**, and its four invariants are stated at the function. Widening it to an
  untrusted command re-opens the class it was written to close.
  **An option can send refs the argument list never names** — `--tags origin :d2` deletes
  `d2` and *publishes* a tag on an unpublished commit — which is why an unrecognised
  option DENIES rather than being skipped. Three pushes at a real remote wrote that
  design; reading `git-push(1)` did not and would not have.
- **Never text-match a field out of a structured document — parse it.** `grep`/`sed`/`awk`
  against JSON lost four times on the same field in one file: `grep -c` counts *lines* not
  occurrences; GNU grep under a UTF-8 locale silently drops a line holding invalid UTF-8;
  `"version"` decodes to the key `version` while containing none of its bytes; and any
  of the key's characters can be escaped independently, so there is no finite set of
  spellings to match. Three independent evasions of one approach is not three bugs — the
  class is *text tools do not parse JSON*, its members cannot be enumerated, and the reader
  was deleted rather than patched a fourth time. A textual reader will always disagree with
  the parser the consumer actually uses, which is the only comparison that matters.
- **The two unreadable-input paths are deliberately asymmetric.** The enforced hook
  refuses; the fast reminder allows, because an unreadable payload would otherwise
  wedge the whole session the moment the JSON tool broke. Do not "consistency"-fix one
  to match the other.

## Markers and the gate contract

- **`marker_get` must stay byte-identical in both copies** (`forgeward-gate-check.sh`
  and `forgeward-pre-push.sh`). A19 in `test/gate-test.sh` is the only thing preventing
  drift — if you touch one copy, that assertion is the reason the other one matters.
- **The marker is written on all-PASS, before the conditional `/ship` handoff.** A
  missing gstack costs two commands, never a re-review, and an unconditional Skill call
  on a machine without gstack produces a false success report.
- **`gc_markers` runs on the marker-write path only.** It is not a scheduled sweep and
  must not become one.
- **Version-field neutralization in `normalize_manifest` is per-manifest-path, never
  recursive.** A recursive strip removes `version` from dependency entries too, and the
  hash then stops noticing a dependency bump.
- **A guard that `exit`s inside a command substitution does not stop the script — check
  the status at the call site.** `snapshot_manifest`'s mode guard exits 1; each caller is
  `part="$(snapshot_manifest …)"`, so the exit killed only the subshell and
  `forgeward-diff-hash.sh` went on to print an ordinary-looking hash with status 0.
  Observed, not reasoned: the guard's message appeared on stderr, a hash appeared on
  stdout, and the script succeeded. `set -uo pipefail` does not catch it — there is no
  `-e`. Every such call carries `|| exit 1`, and V10 pins it by injecting a bad mode into
  a copy of the script and requiring no hash. **`-e` is NOT what this rejects, and saying
  it was is the mistake to avoid repeating** — measured, `-e` halts this exact shape on
  bash 5.1.16 and bash 5.3.15, and the `&&`-guarded lines survive it because a failing
  left operand is exempt. Not dash: `set -uo pipefail` is fatal there, so the script never
  runs and its non-zero status is `Illegal option`, not a halt — **a non-zero exit is not
  evidence of the mechanism you are testing for.** `|| exit 1` wins on scope and locality,
  not correctness, and the scope is **one line**: the unguarded
  `diff_part="$(git diff …)"` assignment is the only statement whose behaviour changes
  under `-e`. That is measured twice over, because it is a universal quantifier and this
  bullet has already been wrong three times. `grep` over the file finds exactly one
  unguarded assignment-from-substitution; the other four carry `|| exit 1` or `|| out=""`,
  and every bare command sits behind a guard or is the final pipeline. An eight-case
  failure battery (bad base, bad tip, dash-led base, non-repo cwd, no jq, no python3,
  empty base, baseline) agrees: every divergent case halts at that one statement, and the
  four non-divergent ones are byte-identical with and without `-e`. An earlier draft said
  "every other command in the file" — the same universal-ahead-of-evidence shape the
  bullet below it exists to warn about, committed inside the correction to it.
  Swept `scripts/*.sh` and `ci/*.sh` when this was found — `hooks/` holds no shell, only
  `hooks.json`. Functions that exit **directly**: `die`, `reject`, `deny`,
  `snapshot_manifest`. Functions that exit **transitively**, by calling one of those:
  `out_reject` and `_gl_target_guard` (→ `reject`), `require_blob` (→ `die`).
  `snapshot_manifest` is the only one of those seven invoked inside a substitution; the
  rest are called directly, from `case` arms or `||` guards. Checked the other direction
  too — every function reached from inside a `$(…)` or `<(…)` was read, and
  `snapshot_manifest` is the only one that can exit. Where another sits near an `exit`,
  that `exit` is at **top level**, after the function body; that is the trap `check_root`
  fell into.
  **Deliberately no count of the substitution-invoked set appears above, and that is the
  most useful thing in this bullet.** Four successive drafts asserted a closed census and
  four were wrong: `check_root` misfiled as exit-bearing, `deny` missed entirely, the
  transitive tier absent, and finally "thirteen" when the answer was fifteen. Each miss
  had its own mechanism, which is why patching the number never held:
    - a `sed` range ending at `/^}/` stops on the column-0 `}` of the JSON heredoc `deny`
      emits, **truncating** before the `exit`;
    - the same range **overruns** a one-liner definition into a genuinely later function,
      sweeping that function's top-level `exit`s into the body. `warn` at
      `forgeward-detect-base.sh:97` is the only instance in `scripts/`: the next column-0
      `}` is at `:242`, so the range spans 146 lines;
    - a **last** function in the file has nothing after it to terminate the range, so any
      attributor that does not track the closing brace runs its body to EOF.
      `check_root` is the last definition in `forgeward-detect-gstack-skill.sh`, closing
      cleanly at `:127`; the `exit`s it was charged with are `check_root … && exit 0` at
      `:146` — its own **call site** — and a bare `exit 1` at `:149`. `snap` is the same
      shape twice over, at `forgeward-scan.sh:321` and
      `forgeward-workspace-guard.sh:48` — last definition in each, no later column-0 `}`
      at all, so the range runs to EOF and sweeps in whatever top-level `exit`s follow;
    - matching `$(fn` finds only a substitution's **first** stage, so a function at the
      tail of a pipe (`out="$(printf … | normalize_manifest …)"`, `read_version`) is
      invisible;
    - `grep` for `exit` counts the word in **comments** — `read_version` reads as
      exit-bearing on a naive scan and is not.
  All five are silent. **State the safety property and the method; do not assert a
  closed count.** The property is what matters and it is stable: no function that can
  `exit` is invoked inside a substitution except `snapshot_manifest`, which now checks
  its status at the call site.
  **This list itself shipped wrong three separate times, which is the point rather than
  an embarrassment.** Its first version named `honor_cd` as a one-liner — it is four
  lines at `forgeward-gate-check.sh:186-189` and has never been one — and it filed
  `check_root` under the one-liner overrun, which cannot be its mechanism because
  `check_root` closes at a column-0 brace like any other block. Its second version then
  filed `snap` under that same overrun row, and `snap` is not that either: it is the
  last definition in both its files with no later column-0 `}` anywhere, so it is the
  EOF case, and removing it left `warn` as the row's only instance. So the table
  explaining four wrong censuses has now been wrong three times on its own account, in
  the same row twice. That is the reason the remedy is a property and a method, not a
  better table: **prose describing a scan is a scan too, and nothing re-runs it.**
  **Every figure below is quoted as the raw span `sed -n '/^fn()/,/^}/p' FILE | wc -l`
  returns**, because two of these numbers previously used different conventions — one
  counting the span, one counting the span minus the definition line — while being
  presented as directly comparable. Quote the command with the number or the number is
  not checkable.
  **Non-goals, so the limits are not read as coverage:** this sweep is a snapshot,
  nothing enforces it, and no test asserts it. It covers **12 of the 21 tracked shell
  files** — the 11 in `scripts/` and the 1 in `ci/`. The 9 in `test/` and `live-test/`
  are outside it, deliberately: a substitution-swallowed `exit` in a harness corrupts a
  test result, not a marker, so it cannot produce a false PASS. That is a judgement about
  blast radius, never a claim those files are clean — and spot-checking them reproduced
  **three of the five mechanisms above**, one example each rather than three of one:
  `denies`, `gl` and `_hook_path` in `gate-test.sh` are one-liners whose `/^}/` range
  spans 63, 384 and 179 lines; `expansion:26` and `det:2169` both carry the word `exit`
  in the comment `-> exit code` and read as exit-bearing to a naive `grep`; and
  `rules-test.sh` closes on a last definition at `:204` with a top-level `exit 1` at
  `:257`, which is the run-to-EOF case.
  **`pre-push-test.sh` was cited alongside it for that third mechanism and did not
  belong there** — `ppjq()` at `:144` is genuinely its last definition, but no executed
  `exit` follows it anywhere: the file ends on the bare status of `[ "$FAIL" -eq 0 ]`,
  and the three post-`:144` lines carrying the word are one comment and two `ok`/`nok`
  message strings. It is a **fourth instance of the comment/string false positive**, not
  an EOF case — the doc's own mechanism, misfiring inside the doc's own evidence for
  that mechanism. Found by the round-7 security reviewer.
- **"Is this gstack skill installed?" is answered by `forgeward-detect-gstack-skill.sh`,
  fail-closed — never by a prompt instruction.** Deferrals to a named gstack skill
  shipped unconditional once, and the axis silently went uncovered.

## Running other people's tools

- **Allow-list the subcommand; never deny-list flags.** `gitleaks` ships `detect --no-git`
  and `protect` as HIDDEN in 8.30.1 — absent from `--help`, still live, the same
  filesystem walk under older names, and all three read an untracked file before the guard
  refused them. A deny-list covers the names you knew about on the day you wrote it.
  Match the subcommand against an enumerated set and refuse anything else, so an unlisted
  value-taking flag placed *before* it cannot smuggle one past.
- **A scanner's target must be one existing regular file that git tracks** — zero paths,
  two paths, a directory and an untracked file are all refused. `gitleaks dir` silently
  replaces the whole target when it gets a second positional (`len(args) != 1` leaves
  `source = "."`), so "the extra path is ignored" is not the failure mode; scanning the cwd
  is.
- **Never fix a scanner leak with a filename exclusion.** A *committed* credential file is
  a genuine finding and must keep being reported. The fix is to make the scanner
  structurally unable to see outside the reviewed diff, not to teach it to skip `.env`.
- **The argv wrapper cannot see a pipe, and layer 1 cannot see inside a flag's VALUE.**
  Both are stated as non-goals in the script and pinned as accepted-and-contained (P8l),
  not asserted away. Do not widen a claim about the wrapper to cover `stdin` mode.

- **A scan whose filename is a constant must be keyed by DIRECTORY.** `forgeward-rubric-drift.sh`
  iterates `skills/*/SKILL.md`, where every basename is the string `SKILL.md`, so a
  basename key reported every skill as `SKILL` — and `ok  beta` and `ok  SKILL` are not
  mutually exclusive outputs, which is why the assertion has to check the broken form
  explicitly rather than merely check for the right one.

- **Pick a candidate root by a COMPLETENESS pass first, and never emit an advisory the
  selected root cannot support.** Ordering the scan by landmark is asymmetric: it stops a
  partial root shadowing a complete one in one direction only, and in the other a
  plugin-cache directory sorting earlier (`1.10.0` before `1.9.0`) that predates a landmark
  beat a complete checkout on the same machine. The run then printed
  `no longer exist … Upstream may have renamed or removed them` about a file sitting one
  directory over. **An advisory that asserts something false about upstream is worse than
  this script's default silence** — take the first candidate holding EVERY landmark, and
  keep the landmark-major scan only as the fallback for a genuinely partial machine.

## Reviewer scope and severity

- **Reviewer model and effort are properties of the runtime launch, never of the parent
  session.** Claude Code's native plugin-agent frontmatter pins every
  `agents/*-reviewer.md` to `model: sonnet` and `effort: medium`; Codex Gate spawns pin
  `model: gpt-5.6-terra`, `reasoning_effort: medium` and `fork_turns: none`. Audit's
  independent verifiers use the same runtime selections. A new reviewer must join both
  enumerations in `test/dual-client-test.sh`, and a new subagent launch in any Forgeward
  skill must make the same runtime choice explicitly. Gate launch prompts carry only the
  complete rubric, absolute repository/plugin roots, exact base and resolved HEAD context,
  read-only instruction and verdict format. Do not pass the parent conversation or a
  suspected finding: inheritance raises both cost and anchoring risk. An unknown runtime
  keeps the existing fail-closed Gate fallback; Audit keeps its labeled self-verification
  fallback.
- **What a reviewer BLOCKS is the remit that matters, not what it prints.** Critical/High
  is the only bar that fails a gate, so a pack pinned at Low widens the *reporting* surface
  and leaves the *blocking* surface bit-for-bit unchanged. That is how `rules/env-config.yml`
  ships inside the security reviewer without widening security's remit — structurally,
  rather than by intention. Enforce the pin in all three places that must agree: the rule's
  `metadata.forgeward-report-severity`, the pack header, and the Step 2 instruction to report
  at that severity **regardless of what the JSON says**, with an explicit "do not promote one
  because the consequence sounds severe".
- **A11y's blocking surface was widened DELIBERATELY at 0.14.0, and it is the one place
  this repo has done that.** Two classes now qualify as High on their own: an accessible
  name that is WRONG rather than missing, and any text below AA contrast. The old rubric
  said "a real barrier that blocks a user from completing a task", which reads a
  wrong-but-present name as Low — the user does complete the task, they are simply told
  something untrue on the way — and it qualified contrast as "on key text", a phrase with
  no definition that resolves to whatever the reviewer already thinks is important. Per
  the rule above, this is a change to what the gate BLOCKS, not to what it prints, and it
  is meant to be. **The two non-goals are written into the reviewer prompt itself, not
  left implied**: a terse-but-accurate name is a pass (the test is whether the name is
  TRUE, never whether it is long), and runtime-composed contrast — a theme token, an
  `opacity-*` over an unknown backdrop, a UA stylesheet — is not computable from a diff
  and must be reported as "unmeasured, needs a rendered check" rather than as a High. A
  vendor's documented value is not evidence for that third case: one shipped UA rule for
  disabled input text predicts ~2.0:1 where the engine paints 7.57:1.
- **Do not disclose an axis as unowned in the same run that just scanned for it.** The
  rejected alternative to the Low pin was announcing `build-config` as covered by nothing
  while the reviewer was finding instances of it — a worse lie than the silence it replaces.
  A disclosure is for an axis nothing looks at, never for one whose findings you are printing.
- **forgeward owns the `quality` axis outright (0.17.0). Never disclose it, never name
  gstack as its owner, never tell a user to run `/review` before merging.** Five ported
  reviewers — `maintainability`, `testing`, `performance`, `api-contract`,
  `data-migration` — fire from the Step 1 table and bind the gate like any other. This
  **supersedes the 0.15.0 rule** that the axis keys on `gstack_ship`: there is no longer
  an axis to key. What 0.15.0 got right and is still load-bearing is *why the gate cannot
  run `/review` itself* — its `allowed-tools` include `Edit` and `Write`, and Step 2
  snapshots the tree to prove the gate is read-only, so a reviewer that may legitimately
  edit code cannot run inside that envelope; and `/review` resolves its own base branch
  while Step 0 resolves the **publish boundary**, which are different refs. Porting the
  checklists sidesteps both: prose has no tools, and the gate scopes them itself. What
  0.15.0 got wrong was treating that as permanent. The configuration it existed to catch
  (`/review` present, `/ship` absent, no handoff) and the one it admitted it could not
  see (`/ship` present, handoff not taken — forgeward's *own* workflow, because `/ship`
  would re-bump the version) are both now simply covered.
  **What the port does not buy, stated so it is not read as coverage:** the rubrics are a
  snapshot, not a subscription. An improvement gstack makes reaches this gate only when
  someone re-ports it. `scripts/forgeward-rubric-drift.sh` detects that gstack moved; it
  cannot make anyone act, and it is blind on a machine with no gstack — which is exactly
  the machine the port exists to serve, so its silence there is not a clean bill.
- **`supply-chain-reviewer` owns dependency CVEs, install-time scripts and lockfile
  integrity outright (0.23.0). Never re-key any of the five classes on whether gstack's
  `/cso` is installed, and never restore a `DEFERRED`/`FULL` mode.** Detection sees
  *presence*, never diligence — a probe can tell that `/cso` is installed and can never
  tell that anyone ran it — so keying an axis on it reports coverage nothing checked.
  Same failure the `quality` bullet above records, one axis over. **The mechanism stays
  even though this caller went:** `scripts/forgeward-detect-gstack-skill.sh` is pinned by
  D1–D12, `forgeward-detect-environment.sh` still emits `gstack_cso`, and
  `forgeward-write-marker.sh`'s `_env_ok` regex **requires** that field — dropping it
  fails every marker validation. Do not tidy it away as dead. **What this does not buy:**
  the reviewer is still diff-scoped and still has no scanner of its own, so a machine with
  no `trivy` and no `osv-scanner` checks CVEs by hand or states the gap — unconditional
  ownership is not a coverage claim, and the duplicated work on a machine that also runs
  `/cso` is an accepted cost, not a bug to fix by restoring the branch.
- **No AI-attribution / co-author-trailer check in the gate.** Considered and rejected at
  0.10.0: `/gate` handing off to `/ship` is structurally a perfect chokepoint, but forgeward
  is a plugin other people install and plenty of them legitimately want that trailer. If it
  is ever added it is an opt-in config key defaulting to off — a separate decision, not a
  reviewer rule. (A repo-local hook is the right layer for a personal policy; this is about
  what ships to installers.)

- **A count or warning the gate PRINTS must not fire on a configuration the docs endorse.**
  `config_warnings` counts settings `.forgeward/config.yml` was addressed by and could not
  use, and it skips `seo.routes` and its whole subtree by indent because README,
  `skills/gate/SKILL.md` and `agents/seo-reviewer.md` all document that key as unhonoured —
  a count that fires on a config which followed the docs trains the reader to ignore the
  count. **Carried with its exception:** `0` from that field is not a clean bill, because a
  config the probe could not open at all also reports `0`, and only the separate `config`
  field distinguishes them. That trap is written into three shipped files and is what the
  live-test's symlink step exists to exercise.

## Tests

- **A rulepack's fixtures are generated into a scratch dir and NEVER committed.** A `.ts` or
  `.php` fixture living under `test/` would itself be scanned by forgeward's own gate on
  every later PR — the suite's inputs would become the gate's findings.
- **A suite that asserts SILENCE needs a trust check that runs first.** A fixture the engine
  cannot parse turns every "the rule correctly does not fire here" assertion green, so a
  non-empty `errors` array is a hard failure, not a warning. Not hypothetical: a fixture
  syntax error masked results during development of `rules-test.sh`, and later a botched
  mutation truncated a file by 141 lines and only this check caught it.
- **`mktemp -d` needs its failure handled explicitly under `set -uo pipefail` without `-e`.**
  A failed `mktemp` yields an empty `$TMP`, so `$TMP/fixtures` becomes the **absolute** path
  `/fixtures` and the heredocs write outside the sandbox the file's header promises. It fails
  with `EACCES` unprivileged and **succeeds silently in a root-run CI container**, which is
  the environment where nobody is watching. Verify by pointing `TMPDIR` at a nonexistent
  directory.
- **Pin a blind spot as expected-silent only when this repo owns the rule — never when the
  engine owns it.** A gap in a bundled pack should fail the suite the day it closes, so the
  doc gets corrected instead of quietly becoming a lie. **The exception is the reason the
  rule needs stating:** semgrep 1.169 scanning `.js/.mjs/.cjs/.jsx/.ts/.tsx` but silently
  **not** `.mts`/`.cts` is an engine property, and pinning it would turn the suite red the
  day a future semgrep fixes it. That one is recorded in the pack header and deliberately
  left unasserted.
- **No `printf … | grep -q` in a test helper under `set -o pipefail`.** `grep -q` exits
  on first match, `printf` takes SIGPIPE and exits 141, and pipefail promotes that to
  the pipeline's status — a passing assertion reads as a failure.
- **A suite passing is evidence about the assertions in it and nothing else.** Every
  guard added here wants a mutation check: disable the guard and confirm the named
  assertion fails.
- **An end-to-end leak fixture needs a control leg** that bypasses the wrapper and
  asserts the raw command DOES leak. Without it the assertions pass with the guard
  removed.
- **Pin the VIOLATING form and guard the enumeration against emptiness.** "Five sites
  carry the flag" goes green the day a sixth arrives without it; "zero sites lack it"
  does not. Any assertion that counts or enumerates needs a floor (A19's non-empty
  extraction, A25/A27/A29's minimum counts) or it asserts a property of nothing.
- **A positive control is mandatory wherever the real thing is present on the author's
  machine.** E2 exists because gstack IS installed here and the probe is not a PATH
  lookup, so an assertion that forgets one of its three roots finds the real gstack and
  greens vacuously.
- **An assertion that pins another file's output must DERIVE that output, never copy it.**
  E17 fed the marker writer a hand-typed duplicate of the probe's `printf` line, and nothing
  compared the two. A field added to the probe without updating the copy made the payload fail
  on its **prefix**, so the assertion still printed `ok` while no longer testing the trailing
  anchor it exists for — and the regression it guards reddened nothing. It had been copied
  correctly twice, which is why it read as handled: the control was a person remembering. The
  remedy is to delete the copy (E17 now derives from `$E1J`), not to document the obligation in
  more places. Pair it with a floor — a derived value that can be empty asserts a property of
  nothing — and know which assertion covers the opposite direction: **E10 is what reddens when
  `_env_ok` is the side that fell behind**, and neither is sufficient alone.
- **Assert on the MESSAGE, not the exit status.** From round 3 of the version-check review
  on, every new assertion reads the message, because two inputs failed closed for an
  *unrelated* reason and would have passed an exit-status check while the guard they were
  written for was bypassed. A check that fails for the wrong reason is a check that is not
  there.
- **An assertion written alongside a mechanism inherits that mechanism's blind spot.** R6
  pinned a 10^3 ceiling and stayed green while the replacement comparator wrapped at 2^63;
  R8's fixture put two keys on separate lines, the one arrangement `grep -c` gets right.
  Only an outside reader or a mutation sees past it — which is why an adversarial review
  found seven defects here and the suite found none of them.
- **A mutation that reports nothing is a claim to verify, not a finding to accept.** Of
  four "vacuous" results, three were harness artifacts that never applied and one applied
  cleanly and was still a no-op (an added `ok:*)` arm after the real one — `case` takes the
  first match). Accepting any of them would have added a test for a guard already pinned.
  `assert count == 1` on the anchor catches the first cause and structurally cannot catch
  the second.
- **When tightening a matcher that previously refused everything, the refusal assertions
  prove nothing.** Every deny case for the publish matcher was already green before
  `_is_delete_only` existed, so only the allow half and mutation testing carried
  information — and mutation is what found the fail-OPEN (`--delete x\ngit push origin
  main` slipping through `read -ra`, which sees one line).
- **Verify a claim about a tool by invoking the binary the code invokes.** An interactive
  `grep` here is a shell function shimming to ugrep 7.5.0; a script gets `/usr/bin/grep`,
  GNU 3.7, and shell functions are not inherited by a non-interactive child. The first
  attempt to check a real finding appeared to refute it because the ad-hoc check and the
  code under test were different programs. Use `type -a` and an absolute path.

- **A tool whose absence turns a suite GREEN is still a dependency.** `test/rules-test.sh`
  needs `semgrep` and degrades to a loud `1..0 # SKIP` without it — which is precisely why
  it read as not-a-dependency in an entry that called `python3` "the only external tool any
  script in this repo needs". README names both now, with the distinction most likely to
  mislead: the hooks read JSON with `jq` *or* `python3` and fail open, while
  `ci/check-version-monotonic.sh` requires it and fails closed.
- **An automation nobody has watched run is a claim, not a control.** Dependabot was
  configured, unobserved, and read as coverage until #32 actually arrived — service
  enabled, schedule firing, `actions` group name resolving, all of it unverified until
  then. The check that settles it costs one glance at the PR list, and it binds any
  scheduled workflow this repo adds later, not just that one.

- **A pre-fix control and a wrong-fix control are different assertions, and a fix needs
  both.** An assertion that fails against the old script proves the bug existed; it says
  nothing about the fix being the RIGHT one, because the obvious wrong fix usually fails
  that assertion too. 0.20.0 shipped four of these controls — four of the twelve R14-family
  assertions that one commit added: R14 and R14b were verified to fail against
  `git show HEAD:scripts/forgeward-rubric-drift.sh`, while R14c and R14d are green against
  the pre-fix script **by construction** and exist to pin the plausible wrong fix — R14c
  that candidate selection is landmark-major rather than candidate-major, verified by
  mutation, since candidate-major is shorter and nothing else in the suite reddens on it.
  Say in the assertion's comment which of the two kinds it is; an author reading four green
  lines cannot otherwise tell that two of them never had an opinion about the bug.
  **This is not a claim that both kinds together are sufficient** — R14e was added by the
  review that gated that same branch, for a case R14c's own fixture comment had already
  mislabelled as covered.

- **A skill's read-only posture is asserted by a NON-EMPTY `allowed-tools` floor, never by
  the absence of `Edit`/`Write`.** A *missing* key grants every tool, so "the frontmatter
  does not list `Write`" is satisfied by frontmatter that lists nothing — the assertion
  passes at its most permissive. A30 is shaped that way on purpose and must not be
  re-written as an absence check or cited as closing the surface: it pins that the key is
  present and non-empty, and the tool list itself is still prose no test reads.

## Docs

- **Codex's `PLUGIN_ROOT` contract belongs to plugin hook processes, not ordinary skill
  shell commands.** Hook manifests should keep using the injected variable. Skill
  instructions must derive the root from their own exact catalogued `SKILL.md` path,
  verify the plugin layout, and use the resulting absolute path; they must never stop
  merely because the hook-only environment is absent or pin a versioned cache path.
- **A doc that describes gate behaviour is part of the gate's surface — change it in
  the same commit as the code.** The `/ship`-handoff gap survived because three
  documents described behaviour the code did not have (`live-test/LIVE-TEST.md`,
  `docs/axis-proposals.md`, and the hook's own halt message). Prose that has never been
  re-read against the code is how a fixed bug keeps being documented as working.
- **The oldest-out cut on `## Completed` is decided by merge order, not by the `Fixed`
  date in the entry — and not by the PR number either.** Several entries carry the same
  date (#20 and #22 both say 2026-08-06 and merged a day apart), and **#26 merged 39
  minutes AFTER #27**, so a number sort is wrong in the other direction. Resolve with
  `git log --first-parent` before moving anything. Both traps have now been hit once each.
  **A third: `gh pr view --json mergedAt` is when the PR merged into ITS OWN BASE, which
  for a stacked PR is another branch.** #49 reports `05:10:01Z` and reached `master` at
  `05:13:51Z` inside #48's merge commit — one landing, two timestamps, and the pair are a
  tie no sort can separate. Worse, that field is not even evidence the work landed: #55
  reports `MERGED` and its diff is on no ref `master` can reach, because it was merged into
  a base branch twelve seconds after that base had itself merged. **Before writing "merged"
  into a durable entry, check the tree** — `git merge-base --is-ancestor <mergeCommit>
  origin/master`. Test the MERGE commit, not the head: a squash merge never leaves the head
  commit as an ancestor of anything, so the head-commit form of that check reports 45 of 59
  PRs orphaned on a repo where two are — a figure that moves with `master`, measured here
  against `be6a01d`, so quote the ref with it. **The merge-commit test has a false positive
  of its own**: a re-landed PR keeps an orphaned merge commit while its content is on
  `master` (#51, re-landed as #52), so fall back to the head commit before alerting.
- **Extract a rule WITH its exception, or don't extract it.** When the `-I` rule was
  lifted, only one of five sites carried the flag and the gap was already filed; stating
  the rule bare would have converted a filed hole into a claim of coverage. If the
  exception is too awkward to state, the rule is not ready to leave `TODOS.md`.
- **When a filter caused the miss, delete the filter — do not extend it.** The 0.9.2
  rotation notice searched with `--include='*.jsonl'` and so could not see
  `tool-results/<id>.txt`, where a tool result over 30 000 characters is persisted in full
  while the transcript keeps only a pointer. Widening it to two extensions was the smaller
  diff and the worse fix: an extension list is the same shape of narrowing that caused the
  defect, and it would miss a third channel exactly as silently. The path does the scoping
  now. This is about filters that *scope a search*; it is not an argument against the
  scanner allow-lists above, which exist to bound what a tool may be told to do.
- **A search over evidence that expires must report an empty result as UNVERIFIABLE, not
  clean.** Claude Code reaps whole session directories on `cleanupPeriodDays` (default 30),
  aged by the parent's recency rather than per file — measured on one machine: 0 of 247
  top-level transcripts survived past 30 days, while **20 of 1574** subagent transcripts
  did, alive only because their parent session stayed in use. So the channel that leaks is
  the one that outlives the window, and a short-lived session's evidence is gone inside the
  month; one AKIA-shaped finding was already lost that way between two consecutive days.
  Any audit tooling this repo grows — `scripts/forgeward-transcript-audit.sh` since 0.16.0 —
  must say what it could not check and keep the rotate-regardless advice for
  the window it cannot see. The measurement is one machine and one Claude Code version
  (2.1.232), `cleanupPeriodDays` is user-configurable, and none of it was checked on
  Windows; treat 30 as a default, not a guarantee.
- **Scope a transcript search by PATH, never by a list of channels.** The README enumerated
  the persistence channels as two (`subagents/*.jsonl`, `tool-results/*.txt`) through two
  revisions; the first real run of `forgeward-transcript-audit.sh` put **5 of 20** prefixed
  hits at the top level, `<project-slug>/<session-uuid>.jsonl`, outside both. A channel list
  is an `--include` filter in different clothes and fails the same way: silently, on the
  channel nobody has thought of yet. `grep -r` from `~/.claude/projects/` found all three
  because it was told about none of them. Three is now a **floor**, not a total — a
  `memory/` directory sits beside them and simply held no hit that run. Same rule as the
  filter bullet above, arrived at from the other direction.
- **The transcript audit's default scope is every project on the machine, and that is not
  over-reach.** A project slug is keyed to the session's LAUNCH directory, so a repo has no
  slug of its own unless someone launched a session in it — measured here, **0 of 26** slugs
  contained `forgeward`, meaning a repo-scoped audit would report the repo that ships the
  script clean while it is the one repo guaranteed to have been discussed. `--project SLUG`
  narrows it; nothing derives a slug from a repo path, because that derivation is what
  produces a confident empty result.
- **A filing-only PR still gets a `## Completed` entry.** It leaves nothing in the tree,
  so the measurement it was built on is the only durable thing it produced — and the next
  pass will re-derive it from scratch if the entry is missing. #28 is the worked example.

- **Prefer DELETING a weightless detail to correcting it.** Each amend adds prose about the
  last correction, and that new prose is the next round's failure surface — so correcting
  sustains the loop rather than ending it. The move that terminates is subtractive: the
  itemized list of which `exit`s a `sed` range swallows was deleted, not completed, and
  replaced with the non-exhaustive phrasing the line above it already used. Which ones was
  never load-bearing; that the range reaches EOF at all is the mechanism. A completed
  enumeration is still an enumeration, and it rots the moment either file changes.
- **A number in a doc is re-derived from what MERGED, and quoted against a FIXED range.**
  Two shapes of one defect. A count written before the branch finished is a claim about a
  draft — pass 3's squash title said seven rules, its body said six, and the merged diff
  added eight, none of them a move. And a hash quoted against `origin/master...HEAD` is a
  hash of the branch's own diff, so every amend invalidates it: use
  `origin/master~1..origin/master` or another range the act of committing cannot move.
  **A number that committing invalidates is worse than no number, because it looks
  verifiable** — and the only moment either can be true is after the last commit.

## Non-goals of this file

- It does **not** cover the reviewer prompts in `agents/` — those are judged by the
  live-test suite, not by a rule here.
- It cannot see a rule that was never written down when its entry was archived; the
  extraction step is judgment at archive time and nothing verifies it.
