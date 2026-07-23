# Decisions

Durable decisions for the forgeward gate, with the reasoning that produced them.
`RESOLVED` entries record a real bug, its repro, and the fix, so a future regression
is recognizable from the symptom alone.

## DECISION — page posture is per route group, not per site; three postures became five plus `unknown`

**Date:** 2026-07-23

**Problem.** The seo-reviewer treated "public" and "indexable" as the same thing. A site
deliberately serving `User-agent: * / Disallow: /` while carrying Open Graph tags — so a
link renders a card in chat but never appears in search — was reported as Critical/High
("a public page that can't be indexed") and hard-failed the gate. That is a legitimate,
common design: share links, unlisted deliverables, client previews, invite-only pages.
No waiver mechanism existed, and `skills/gate/SKILL.md` correctly forbids the orchestrator
from rationalizing a FAIL into a pass, so the only escape was `git push --no-verify`,
which skips **every** axis to silence one.

**Why not a waiver.** A whitelist suppresses a finding; it does not teach the reviewer what
it is looking at. The reviewer would keep being wrong and the user would keep annotating
around it. Posture is the right primitive: declare (or detect) what the page IS, and the
ruleset follows. An expiring, committed waiver file remains a reasonable last resort for
genuine one-offs, but it is not the fix for this class.

**Decision.** The reviewer classifies posture **per route group** and switches ruleset:
`public-indexed`, `private-shareable`, `private-closed`, `staging-preview`,
`authenticated-shareable`, and `unknown`. Per-route matters more than the taxonomy itself —
the single most common real shape is indexed marketing pages plus an authenticated app on
one origin, and a site-wide verdict necessarily gets one of them wrong. `unknown` reports
only what holds under every candidate posture rather than guessing; a wrong posture yields
confident findings about the wrong thing, which is worse than an acknowledged gap.

Under `private-shareable` the checklist inverts: indexability findings are the intent and
must not appear at any severity (reporting them as Low still trains the reader to ignore
the reviewer), while a broken link preview becomes High — missing or partial OG tags,
client-rendered OG tags that preview bots never execute, a relative `og:image`, or a
blanket disallow with no per-agent allowlist group.

**Privacy consequence.** These sites have no authorization boundary — the URL *is* the
credential — and every rule in the privacy-reviewer presupposed one ("visible to users who
shouldn't see it" assumes accounts). Added an unauthenticated-PII-surface section, led by
two rules: bulk PII crossing to the client for a lookup UI (a search feature must match
server-side and return only the matching record), and two paths to one data store with
different auth postures, where the credentialed path creates false confidence about the
whole feature. The gate now fires the privacy-reviewer on `private-shareable` groups even
when the diff looks like markup or config, since on such a group any new route or
client-reachable data source is a personal-data change.

**Also recorded as a limit.** `skills/gate/SKILL.md` now requires the gate to state what the
diff cannot see — externally-resolved engines, submodules, gitignored paths that committed
tooling references — because a PASS on a thin customization layer must never read as a PASS
on the system. The privacy-reviewer carries a matching blind-spot list. An unstated limit is
indistinguishable from a claim of coverage.

**Deliberately excluded.** A `paywalled`/metered posture (its own specialist rulebook;
half-implementing it is worse than not claiming it) and an "indexed but no OG tags" posture
(on an indexed site missing OG is a defect, already Medium/Low — absence of OG only reads as
intent when the site has also opted out of search). Postures are capped deliberately: each
one added is another chance to misclassify.

## RESOLVED — gate false-blocks a push from a git worktree; enforcement moved to pre-push

**Date:** 2026-07-15 (resolved 2026-07-16)

**Symptom.** Work isolated in a linked `git worktree` passes `/forgeward:gate` (all
reviewers PASS, marker written), but the subsequent `git push` / `gh pr create` is denied
anyway: *"forgeward gate not passed for HEAD …"*. The branch is committed and genuinely
gated, yet the publish stays blocked. Re-running the gate does not help. Manifests only when
the Claude Code session's cwd is a **different checkout of the same repo** (typically the
main checkout) than the worktree holding the gated branch.

**Cause.** Both halves keyed the marker off `git rev-parse --git-dir`, and the check half
also recomputed the substantive-diff hash against **its own cwd's HEAD**:
- `forgeward-write-marker.sh` ran inside the worktree → `--git-dir` = the per-worktree git
  dir → marker written *there*, pinned to the worktree HEAD.
- `forgeward-gate-check.sh` (PreToolUse) `cd`s to the hook event's `.cwd` = the **session**
  cwd (the main checkout), so `--git-dir` = the main `.git`. It looked for the marker in the
  wrong git dir AND, via `is_fresh` → `forgeward-diff-hash.sh`, recomputed `base...HEAD`
  against the main checkout's HEAD (= `origin/main` → empty diff). Two independent
  fail-closed misses. It is a cwd/worktree mismatch, not a real gate failure — and the
  auto-mode classifier correctly refuses to let an agent route around a green-looking gate,
  so the push wedges.

**Fix — part 1: the marker is worktree-safe.** Two coordinated changes, needed by every
enforcement layer:
1. `forgeward-diff-hash.sh <base> [tip]` takes an explicit tip (defaults to `HEAD`, so
   existing single-checkout behavior is byte-for-byte unchanged), so freshness can be checked
   against a specific ref/SHA rather than whatever the caller has checked out.
2. `forgeward-write-marker.sh` stores the marker **branch-keyed under the common git dir**
   (`git rev-parse --git-common-dir`), shared across all linked worktrees, so a marker written
   from a worktree is found from any checkout of the repo. Keying by branch keeps concurrent
   worktrees on different branches from clobbering one another.

**Fix — part 2: enforcement moved OFF the PreToolUse hook and onto a git `pre-push` hook.**
The first attempt made the PreToolUse hook parse the push command to learn which ref it would
send. **Four** pre-merge security reviews each found the parser failing OPEN, and the pattern
was terminal: to know what a shell command pushes you must reimplement the shell's lexer, and
each round exposed another layer — word-splitting and `git -C` (R3), quote/backslash removal
`"git" push` (R4), then variable expansion. Closing expansion would require denying every
`git … $var`, which breaks ordinary git use. **Conclusion: a PreToolUse hook reads command
TEXT and cannot be both bypass-proof and usable.** (Most of these bypasses — `git -C`,
`git  push` — also exist in the pre-0.3.0 gate; this is architectural, not a regression.) So:

- **`forgeward-gate-check.sh` reverted to a simple best-effort REMINDER**: on a publish
  command, honor a leading `cd` and check the current checkout's branch marker; deny with a
  message that says the enforced check is pre-push. It is fast UX, explicitly NOT the lock.
- **`forgeward-pre-push.sh` is the enforcement.** A git pre-push hook runs INSIDE the push:
  git hands it the exact `<local-ref> <local-sha> <remote-ref> <remote-sha>` lines on stdin,
  after the shell has already resolved `git -C`, quoting, `$vars`, `xargs`, aliases — there is
  no text left to trick. It blocks the push if ANY branch ref being pushed lacks a fresh marker.
  It keys off the ref being UPDATED on the remote (`remote_ref`) and verifies the pushed COMMIT
  (`local_sha`, matched against any local branch's marker) — so `git push origin <sha>:refs/heads/x`
  or `HEAD:refs/heads/x`, where the local side isn't a `refs/heads/*` name, can't skip the check
  (a fail-open the final review caught before merge).
- **`forgeward-install-pre-push.sh`** installs it into the repo's EFFECTIVE hooks dir
  (honoring `core.hooksPath` — a global one is common and made per-repo `.git/hooks` installs
  dead) and sets a per-repo opt-in (`git config forgeward.gate enabled`). The enforcer no-ops
  unless that opt-in is present, so a hook living in a shared/global dir never blocks unrelated
  repos.

**Honest residual (this is strong, not indestructible).** `git push --no-verify` skips the
hook; the marker is a local file that can be forged; git hooks are not cloned (re-install in a
fresh clone, and after a plugin update, since the enforcer path is baked into the hook). Any
purely-local gate has these limits. For an **unbypassable** boundary, gate the MERGE
server-side — GitHub required checks + branch protection via `/forgeward:ci-gate` (which
already does this for the deterministic scanners). This hook stops the common/accidental
ungated push, robustly, on the developer's machine.

**Coverage.**
- `test/gate-test.sh` — the PreToolUse reminder: no-marker deny, non-publish untouched, PASS
  allow, version-bump-invariance, dependency-sensitivity, stale deny, fail-open outside a repo,
  the `/ship` expansion halt, and worktree honor-cd (a `cd <worktree> && git push`, gated →
  allow, ungated → deny, single-quoted spaced path → allow), plus base-detection and the
  manifest-hooks guard.
- `test/pre-push-test.sh` — the enforcer, driven exactly as git drives it (refs on stdin):
  gated allow; ungated block (names the ref); multi-ref one-ungated block / all-gated allow;
  branch deletion allow; post-marker commit stale block; version-only bump allow; tag (non-
  branch) allow; **a marker written inside a linked worktree honored from the main checkout**
  (the original bug, now handled with no cd and no parsing); and the opt-in no-op (a repo
  without `forgeward.gate` is not blocked — safe as a global hook).
- End-to-end (manual harness): real pushes through the installed hook against a bare remote
  confirm `git -C`, `git  push`, `"git" push`, and `g\it push` are all BLOCKED while ungated;
  `--no-verify` bypasses; and a gated ref pushes.

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
