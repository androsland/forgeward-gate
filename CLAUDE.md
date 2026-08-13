# forgeward-gate — load-bearing constraints

Imperatives lifted out of completed work as it was archived. Each exists because
building the obvious thing instead turned out to be wrong, got reversed, or shipped a
bug. The narrative, the repro and the dates are in [`DECISIONS.md`](DECISIONS.md) and
[`TODOS-DONE.md`](TODOS-DONE.md) — grep there before overriding a line here.

Cited **by symbol, never by line**: this file outlives line numbers, and `TODOS.md`
already carries one stale line reference.

## Parsing untrusted input

- **One reader per shape — never add a second parser arm.** A `jq` arm and a `python3`
  fallback hashed the same manifest differently; three bugs in this file's history are
  the same class (`json_get`, `strip_quoted`, `marker_get`). If a fallback is
  unavoidable, a test must assert the two arms agree byte-for-byte.
- **Every `python3 -c` that reads a manifest carries `-I`.** It drops the CWD from
  `sys.path` and implies `-E`/`-s`, so a `json.py` in the repo under review cannot be
  the module judging it. **Only `ci/check-version-monotonic.sh` has it today** —
  `forgeward-diff-hash.sh`, `forgeward-gate-check.sh` (×2) and `forgeward-pre-push.sh`
  do not, and that gap is filed as a P3 in `TODOS.md`. Add `-I` to any new site, and
  do not read this rule as a claim the existing ones are covered.
- **`export LC_ALL=C` script-wide, never a `local LC_ALL=C` beside it.** Two mechanisms
  for one invariant is how it drifts; the function-local one was deleted, not kept.
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

## Non-goals of this file

- It does **not** cover the reviewer prompts in `agents/` — those are judged by the
  live-test suite, not by a rule here.
- It cannot see a rule that was never written down when its entry was archived; the
  extraction step is judgment at archive time and nothing verifies it.
