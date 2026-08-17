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
  **This paragraph got its own count wrong three times before it was run** — six-unscoped,
  then five-invoke, each asserted from a `grep -c` that a reviewer had to correct. That is
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

## Reviewer scope and severity

- **What a reviewer BLOCKS is the remit that matters, not what it prints.** Critical/High
  is the only bar that fails a gate, so a pack pinned at Low widens the *reporting* surface
  and leaves the *blocking* surface bit-for-bit unchanged. That is how `rules/env-config.yml`
  ships inside the security reviewer without widening security's remit — structurally,
  rather than by intention. Enforce the pin in all three places that must agree: the rule's
  `metadata.forgeward-report-severity`, the pack header, and the Step 2 instruction to report
  at that severity **regardless of what the JSON says**, with an explicit "do not promote one
  because the consequence sounds severe".
- **Do not disclose an axis as unowned in the same run that just scanned for it.** The
  rejected alternative to the Low pin was announcing `build-config` as covered by nothing
  while the reviewer was finding instances of it — a worse lie than the silence it replaces.
  A disclosure is for an axis nothing looks at, never for one whose findings you are printing.
- **No AI-attribution / co-author-trailer check in the gate.** Considered and rejected at
  0.10.0: `/gate` handing off to `/ship` is structurally a perfect chokepoint, but forgeward
  is a plugin other people install and plenty of them legitimately want that trailer. If it
  is ever added it is an opt-in config key defaulting to off — a separate decision, not a
  reviewer rule. (A repo-local hook is the right layer for a personal policy; this is about
  what ships to installers.)

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

## Docs

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
- **Extract a rule WITH its exception, or don't extract it.** When the `-I` rule was
  lifted, only one of five sites carried the flag and the gap was already filed; stating
  the rule bare would have converted a filed hole into a claim of coverage. If the
  exception is too awkward to state, the rule is not ready to leave `TODOS.md`.
- **A filing-only PR still gets a `## Completed` entry.** It leaves nothing in the tree,
  so the measurement it was built on is the only durable thing it produced — and the next
  pass will re-derive it from scratch if the entry is missing. #28 is the worked example.

## Non-goals of this file

- It does **not** cover the reviewer prompts in `agents/` — those are judged by the
  live-test suite, not by a rule here.
- It cannot see a rule that was never written down when its entry was archived; the
  extraction step is judgment at archive time and nothing verifies it.
