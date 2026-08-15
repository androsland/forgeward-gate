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

## Tests

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

## Docs

- **A doc that describes gate behaviour is part of the gate's surface — change it in
  the same commit as the code.** The `/ship`-handoff gap survived because three
  documents described behaviour the code did not have (`live-test/LIVE-TEST.md`,
  `docs/axis-proposals.md`, and the hook's own halt message). Prose that has never been
  re-read against the code is how a fixed bug keeps being documented as working.
- **The oldest-out cut on `## Completed` is decided by merge order, not by the `Fixed`
  date in the entry.** Several entries carry the same date — #20 and #22 both say
  2026-08-06 and merged a day apart — so a cut read off the page archives the newer one.
  Resolve ties with `git log` before moving anything.

## Non-goals of this file

- It does **not** cover the reviewer prompts in `agents/` — those are judged by the
  live-test suite, not by a rule here.
- It cannot see a rule that was never written down when its entry was archived; the
  extraction step is judgment at archive time and nothing verifies it.
