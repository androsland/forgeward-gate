# Decisions

Durable decisions for the forgeward gate, with the reasoning that produced them.
`RESOLVED` entries record a real bug, its repro, and the fix, so a future regression
is recognizable from the symptom alone.

## DECISION — add a security reviewer + CI enforcement (reversed "delegate security to /cso")

**Date:** 2026-07-13

**Prior decision.** forgeward deliberately shipped no general security reviewer, delegating the
OWASP/STRIDE/CVE axis to gstack's `/cso`, and the README documented "no SAST, no CI merge-gating —
handle those in your project's CI." The rationale was avoiding duplication of `/cso`.

**What broke it.** On a real PR (a wp-admin SQL runner executing committed `.sql` against a live
DB), the gate fired only privacy + accessibility and returned PASS. `/cso` is opt-in and manual;
it wasn't run. A commercial SAST scanner (Wiz) independently flagged **1 critical + 13 high** on
the same diff — including a SQL-injection-class finding. The delegation assumed `/cso` would be
run; in the real workflow it wasn't, so the security axis was simply absent at the moment of ship.

**Decision.** (1) Add `security-reviewer` as a sixth gate reviewer — diff-scoped, read-only, runs
a bundled framework-aware SAST rulepack (`rules/wp-security.yml`) plus injection/authz reasoning,
returns `SECURITY VERDICT: PASS|FAIL`. (2) Add `/forgeward:ci-gate` (absorbing the former
`readiness` skill) to wire real scanners (Semgrep, PHPCS/WPCS, Trivy, Gitleaks) into CI and
optionally make them required checks via branch protection. `/cso` remains the deep whole-repo
audit; the reviewer does not replace it — it stops the gate greenlighting injection.

**Scope note.** `security-reviewer` is diff-scoped and one reviewer won't match a commercial SAST
engine's recall — the `ci-gate` CI scanners are the unskippable floor; the reviewer is fast local
feedback. Verified: the bundled rulepack flags 8 dynamic-SQL sinks on the PR above (6 unprepared
`$wpdb` queries + a value interpolated into a `prepare()` format string) and stays silent on
correctly-prepared and literal queries.

## RESOLVED — base detection on a direct-to-base commit (origin/<base> fallback)

**Date:** 2026-06-22

**Symptom.** A commit made directly on the base branch (e.g. a docs edit straight to
`master`, no feature branch) could not be gated. `scripts/forgeward-detect-base.sh`
resolved to the bare base branch, so the gate's diff scope `base...HEAD` was **empty**
— local `master` equals `HEAD`, so the three-dot diff has nothing in it. The
`/forgeward:gate` skill then hit its "you're on the base branch, nothing to gate" stop,
while the `PreToolUse` push hook still (correctly) blocked the push for lack of a PASS
marker. Net result: a deadlock — a real unpushed change about to publish, but no
non-empty surface to review, so no honest marker could be written.

**Repro.** On `master`, commit a change directly. `origin/master` is now behind `HEAD`
by that commit. `git diff master...HEAD` is empty; the push hook blocks; the gate reads
"nothing to gate." First observed live while shipping the README "Security scope" note
(worked around at the time by manually scoping the marker to `origin/master`).

**Fix.** Step 4 in `scripts/forgeward-detect-base.sh`: when `HEAD` is ON the resolved
base branch AND `origin/<base>` exists AND differs from `HEAD`, return `origin/<base>`
(the publish boundary). The diff then scopes to the real unpushed change. Guarded two
ways: a base branch in sync with its remote keeps the bare base (genuinely nothing to
gate), and a feature branch (`HEAD != base`) skips step 4 entirely, so that resolution
is byte-for-byte unchanged.

**Coverage.** `test/gate-test.sh` B4 (assertions 22–23): a direct-to-base commit with
`origin/main` behind → detect returns `origin/main`, and the test proves meaningfulness
(the new base scopes the real changed file; the old bare-`main` diff is empty). The three
prior base-detection tests (origin/HEAD unset, origin/HEAD set, master-only fallback)
still pass unchanged.

## RESOLVED — duplicate hooks load (manifest re-referenced the auto-loaded hooks.json)

**Date:** 2026-06-22

**Symptom.** Plugin load failed on reload/reinstall: *"Hook load failed: Duplicate hooks
file detected: ./hooks/hooks.json resolves to already-loaded file …/hooks/hooks.json. The
standard hooks/hooks.json is loaded automatically, so manifest.hooks should only reference
additional hook files."* With hooks failing to load, the enforcement gate is effectively
DOWN — pushes/PRs are no longer intercepted.

**Cause.** `.claude-plugin/plugin.json` set `"hooks": "./hooks/hooks.json"`. Claude Code
auto-loads the standard `hooks/hooks.json` by convention; the explicit manifest reference
then loads the same file a second time. (Not introduced by a code change — it surfaced when
the plugin reload began enforcing the auto-load convention.)

**Fix.** Remove the `"hooks"` key from `plugin.json`. The standard `hooks/hooks.json` still
loads automatically; `manifest.hooks` is reserved for ADDITIONAL hook files, of which this
plugin has none.

**Coverage.** `test/gate-test.sh` M1 (assertion 24): static guard that `plugin.json`'s
`hooks` value does not point at the auto-loaded `hooks.json` — a re-add fails the suite.
