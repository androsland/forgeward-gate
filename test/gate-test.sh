#!/usr/bin/env bash
# Regression suite for the forgeward gate enforcement core.
#
# Framework-free on purpose: the system under test is bash + git, so this needs
# only bash, git, sha256sum, and jq-or-python3 — the plugin's own footprint, no
# extra test runtime. Runs standalone, and via `bun run test` / `npm test`
# (see package.json). Exercises the REAL plugin scripts in scripts/, not copies.
#
# A future edit that breaks deny/allow, hash version-invariance, or
# dependency-sensitivity fails this suite.
set -uo pipefail

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$PLUGIN/scripts/forgeward-gate-check.sh"
WRITE="$PLUGIN/scripts/forgeward-write-marker.sh"
HASH="$PLUGIN/scripts/forgeward-diff-hash.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok %d - %s\n' "$((PASS+FAIL))" "$1"; }
nok()  { FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$((PASS+FAIL))" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; }

# --- helpers that drive the real hook script the way Claude Code would ---
pretool() { # pretool <repo> <command>  -> stdout = hook decision JSON (or empty)
  printf '{"cwd":"%s","tool_input":{"command":"%s"}}' "$1" "$2" | "$CHECK" pretooluse
}
expansion() { # expansion <repo>  -> exit code (0 allow, 2 block)
  printf '{"cwd":"%s"}' "$1" | "$CHECK" expansion >/dev/null 2>&1; echo $?
}
denies()  { printf '%s' "$1" | grep -q '"permissionDecision": "deny"'; }

# --- scratch repo on the same shape as the demo (main + feature) ---
TMP="$(mktemp -d "${TMPDIR:-/tmp}/forgeward-test.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
R="$TMP/repo"
git init -q "$R"; cd "$R"
git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
printf '{\n  "name": "u",\n  "version": "1.0.0",\n  "dependencies": { "express": "^4.19.2" }\n}\n' > package.json
echo "ok" > src.js
git add -A; git commit -qm base; git branch -M main
git checkout -qb feature
printf 'const e = require("express");\nconst app = e();\napp.get("/x", (q,r)=>r.json({ok:true}));\n' > feature.js
git add -A; git commit -qm "feat: real work"

# S1: no marker -> publish denied
out="$(pretool "$R" "git push -u origin feature")"
denies "$out" && ok "no marker -> git push DENIED" || nok "no marker -> git push DENIED" "got: $out"

# S2: unrelated command never interfered with, even with no marker
out="$(pretool "$R" "npm test")"
[ -z "$out" ] && ok "non-publish command -> untouched (no deny)" || nok "non-publish command untouched" "got: $out"

# S3: gh pr create and glab mr create also gated
denies "$(pretool "$R" "gh pr create --base main")" && ok "no marker -> gh pr create DENIED" || nok "gh pr create DENIED"
denies "$(pretool "$R" "glab mr create -b main")"   && ok "no marker -> glab mr create DENIED" || nok "glab mr create DENIED"

# S4: expansion blocks a typed /ship with no marker (exit 2)
[ "$(expansion "$R")" = "2" ] && ok "no marker -> /ship expansion BLOCKED (exit 2)" || nok "/ship expansion blocked"

# S5: PASS marker written -> publish allowed
"$WRITE" main "privacy" >/dev/null
out="$(pretool "$R" "git push -u origin feature")"
[ -z "$out" ] && ok "PASS marker -> git push ALLOWED" || nok "PASS marker -> git push ALLOWED" "got: $out"
[ "$(expansion "$R")" = "0" ] && ok "PASS marker -> /ship expansion ALLOWED (exit 0)" || nok "/ship expansion allowed"

# S6: version-only bump (gstack Step 12) -> hash unchanged -> still allowed
h_before="$("$HASH" main)"
python3 -c "import json;d=json.load(open('package.json'));d['version']='1.0.1.0';open('package.json','w').write(json.dumps(d,indent=2)+chr(10))"
git add -A; git commit -qm "chore: bump version (v1.0.1.0)"
h_after="$("$HASH" main)"
[ "$h_before" = "$h_after" ] && ok "version-only bump -> hash UNCHANGED" || nok "version bump hash unchanged" "$h_before vs $h_after"
out="$(pretool "$R" "git push")"
[ -z "$out" ] && ok "after version bump -> git push still ALLOWED (marker survives)" || nok "version bump still allowed" "got: $out"

# S7: dependency added -> hash flips -> denied (re-gate forced)
python3 -c "import json;d=json.load(open('package.json'));d['dependencies']['expresss']='^4.0.0';open('package.json','w').write(json.dumps(d,indent=2)+chr(10))"
git add -A; git commit -qm "feat: add expresss dep"
h_dep="$("$HASH" main)"
[ "$h_before" != "$h_dep" ] && ok "dependency added -> hash CHANGED" || nok "dep add hash changed" "still $h_dep"
denies "$(pretool "$R" "git push")" && ok "dependency added after PASS -> git push DENIED (re-gate)" || nok "dep add re-gate denied"

# S8: new source code after marker -> stale -> denied
git checkout -q -- . 2>/dev/null; git reset -q --hard HEAD~1   # drop the dep commit, back to PASS state
out="$(pretool "$R" "git push")"; [ -z "$out" ] || { nok "reset-to-PASS sanity" "expected allow, got deny"; }
echo "// sneaky new code after gate" >> feature.js; git add -A; git commit -qm "feat: extra code"
denies "$(pretool "$R" "git push")" && ok "new code after marker -> git push DENIED (stale)" || nok "new code stale deny"

# S9: outside a git repo -> fail open (allow), never wedge
out="$(pretool "$TMP" "git push")"   # $TMP is not a git repo
[ -z "$out" ] && ok "outside a git repo -> fail open (allow)" || nok "fail-open outside repo" "got: $out"

# --- worktree: the PreToolUse layer is a best-effort REMINDER (not the lock), but it
# must still handle the common "cd into a worktree, then push" case — honor the cd and
# find the marker under the shared common git dir. Precise, per-ref ENFORCEMENT lives
# in the pre-push hook (test/pre-push-test.sh), which needs none of this text parsing.
# R stays on `feature`; worktrees are added without moving R's HEAD. ---
WT="$TMP/wt"
git -C "$R" worktree add -q -b wtfeat "$WT" main >/dev/null 2>&1
( cd "$WT"; printf 'const w = 1;\n' > wt.js; git add -A; git commit -qm "feat: worktree"; "$WRITE" main "privacy" ) >/dev/null

# W1: `cd <worktree> && git push` -> honor cd -> the worktree's GATED branch -> ALLOWED
# (marker written inside the worktree is found via the common git dir).
out="$(pretool "$R" "cd $WT && git push")"
[ -z "$out" ] && ok "worktree: 'cd <worktree> && git push' on a gated branch -> ALLOWED (honor cd + common-dir marker)" \
  || nok "worktree honor-cd gated allow" "got: $out"

# W2: a worktree on an UNGATED branch -> the reminder still fires there -> DENIED.
WTB="$TMP/wtbad"
git -C "$R" worktree add -q -b wtbad "$WTB" main >/dev/null 2>&1
( cd "$WTB"; echo x > b.js; git add -A; git commit -qm "feat: ungated" ) >/dev/null
denies "$(pretool "$R" "cd $WTB && git push")" \
  && ok "worktree: 'cd <worktree> && git push' on an ungated branch -> DENIED" \
  || nok "worktree honor-cd ungated deny"

# W3: single-quoted cd with a spaced path resolves too (gated) -> ALLOWED.
WTS="$TMP/wt spaced"
git -C "$R" worktree add -q -b wtspace "$WTS" main >/dev/null 2>&1
( cd "$WTS"; echo x > s.js; git add -A; git commit -qm "feat: spaced"; "$WRITE" main "privacy" ) >/dev/null
out="$(pretool "$R" "cd '$WTS' && git push")"
[ -z "$out" ] && ok "worktree: single-quoted 'cd <spaced worktree> && git push' (gated) -> ALLOWED" \
  || nok "worktree single-quoted cd allow" "got: $out"

# S10: the UserPromptExpansion matcher (read from the real hooks.json) must fire on
# `ship` AND any <prefix>-ship (gstack --prefix), but NOT on lookalike commands.
# Evaluated as a JS regex (node) to match Claude Code's matcher engine; python re
# fallback is equivalent for this anchored pattern.
# The path goes through argv, NOT interpolated into the -c script: under MSYS/Git
# Bash a POSIX path embedded in a script STRING reaches native Windows python
# untranslated ('/c/Users/...' -> FileNotFoundError -> empty matcher -> a regex that
# matches everything, so the false-positive assertions silently "pass" nothing).
# Path translation only happens for standalone arguments. Same MSYS boundary that
# produced the reviewer's 'C:' directory tree, mirrored.
MATCHER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["hooks"]["UserPromptExpansion"][0]["matcher"])' "$PLUGIN/hooks/hooks.json")"
[ -n "$MATCHER" ] || { nok "hooks.json matcher readable (test harness precondition)" "empty matcher"; }
rx() { # rx <pattern> <string> -> true|false (JS regex semantics)
  if command -v node >/dev/null 2>&1; then
    node -e 'process.stdout.write(String(new RegExp(process.argv[1]).test(process.argv[2])))' "$1" "$2"
  else
    python3 -c 'import re,sys;print(str(bool(re.search(sys.argv[1],sys.argv[2]))).lower())' "$1" "$2"
  fi
}
[ "$(rx "$MATCHER" ship)" = true ]        && ok "ship-matcher fires on 'ship'" || nok "matcher fires on ship" "pattern=$MATCHER"
[ "$(rx "$MATCHER" gstack-ship)" = true ] && ok "ship-matcher fires on 'gstack-ship' (--prefix default)" || nok "matcher fires on gstack-ship"
[ "$(rx "$MATCHER" myco-ship)" = true ]   && ok "ship-matcher fires on arbitrary '<prefix>-ship'" || nok "matcher fires on custom prefix"
[ "$(rx "$MATCHER" shipment)" = false ]   && ok "ship-matcher does NOT fire on lookalike 'shipment'" || nok "matcher false-positive: shipment"
[ "$(rx "$MATCHER" airship)" = false ]    && ok "ship-matcher does NOT fire on lookalike 'airship'" || nok "matcher false-positive: airship"

# S11: base detection (gate Step 0) must ALWAYS resolve to a real branch, falling
# through to main/master when origin/HEAD is unset. The old inline form returned ''
# because `git symbolic-ref ... | sed` exits 0 on empty input, short-circuiting the
# || chain before the fallback -> empty base -> mis-scoped review diff. Tested
# against the real scripts/forgeward-detect-base.sh.
DETECT="$PLUGIN/scripts/forgeward-detect-base.sh"
detect()      { ( cd "$1" && "$DETECT" 2>/dev/null ); }          # -> base ref (stderr = drift note)
detect_name() { ( cd "$1" && "$DETECT" --name 2>/dev/null ); }   # -> bare branch name

# B1 (the regression): origin/HEAD unset, local main exists -> 'main', NOT empty.
b="$(detect "$R")"
[ "$b" = "main" ] && ok "base detect: origin/HEAD unset -> 'main' via fallback (not empty)" \
  || nok "base detect unset->main" "got: '$b'"

# B2: no main anywhere, only master -> 'master' (final fallback). Force the initial
# branch to master so the global init.defaultBranch can't make this flaky.
RM="$TMP/repo-master"
git -c init.defaultBranch=master init -q "$RM"
( cd "$RM"; git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  echo x > f; git add -A; git commit -qm base ) >/dev/null
b="$(detect "$RM")"
[ "$b" = "master" ] && ok "base detect: no main, only master -> 'master' (final fallback)" \
  || nok "base detect ->master" "got: '$b'"

# B3: origin/HEAD SET -> uses it (behavior unchanged when set). Fake an origin whose
# HEAD points at origin/develop.
RH="$TMP/repo-head"
git init -q "$RH"
( cd "$RH"; git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  echo x > f; git add -A; git commit -qm base; git branch -M main
  git remote add origin /nonexistent.git
  git update-ref refs/remotes/origin/develop HEAD
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop ) >/dev/null
b="$(detect "$RH")"
# The NAME still comes from origin/HEAD; the REF is the remote-tracking one, because
# refs/remotes/origin/develop exists and is the publish boundary. (This previously
# asserted the bare name 'develop' — that assertion was the bug: a bare name
# resolves to the LOCAL branch, which drifts from the remote in both directions.)
[ "$b" = "origin/develop" ] && ok "base detect: origin/HEAD set -> honored, as the remote-tracking ref" \
  || nok "base detect set->origin/develop" "got: '$b'"
[ "$(detect_name "$RH")" = "develop" ] && ok "base detect: --name gives the bare branch back for PR targeting" \
  || nok "base detect --name on origin/HEAD repo" "got: '$(detect_name "$RH")'"

# B4 (direct-to-base): HEAD committed DIRECTLY on the base branch with
# origin/<base> behind by the unpushed commit. Bare 'main' makes "main...HEAD"
# EMPTY -> the gate mis-reads "nothing to gate" and deadlocks (push stays
# hook-blocked, yet no reviewable surface). Resolving to the publish boundary
# origin/main puts the real unpushed change in scope. Mirrors the live repro: a
# docs commit made straight to master. Stage B now covers this as one case of the
# general rule, so it no longer needs the special-cased "HEAD is on the base" arm.
RD="$TMP/repo-direct"
git init -q "$RD"
( cd "$RD"; git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  echo base > f; git add -A; git commit -qm base; git branch -M main
  git update-ref refs/remotes/origin/main HEAD                    # origin/main == C0
  echo changed > doc.md; git add -A; git commit -qm "docs: direct-to-base commit" ) >/dev/null  # HEAD == C1, on main
b="$(detect "$RD")"
[ "$b" = "origin/main" ] && ok "base detect: HEAD on base branch + unpushed commit -> origin/main (publish boundary)" \
  || nok "base detect direct-to-base -> origin/main" "got: '$b'"
# Meaningfulness: new base scopes the REAL change; the old bare base would be empty.
new_diff="$(cd "$RD" && git diff "$b...HEAD" --name-only)"
old_diff="$(cd "$RD" && git diff "main...HEAD" --name-only)"
{ [ "$new_diff" = "doc.md" ] && [ -z "$old_diff" ]; } \
  && ok "base detect: origin/main scopes real change (doc.md); bare 'main' diff is empty (proves the fix matters)" \
  || nok "direct-to-base diff meaningfulness" "new='$new_diff' old='$old_diff'"

# --- B5..B13: the base must be the PUBLISH BOUNDARY, not a local branch name -----
# A bare branch name resolves to the LOCAL branch, which is only as current as the
# last time the user checked it out. Both drift directions mis-scope the review:
#   behind the remote -> reviewers audit already-merged code (waste, wrong findings)
#   ahead of the remote -> the gate reviews LESS than the push publishes (false PASS)
# Helper: build a repo and echo nothing; every assertion cds in a subshell.
mkrepo() { # mkrepo <dir>
  git init -q "$1"
  git -C "$1" config user.email t@t.t
  git -C "$1" config user.name t
  git -C "$1" config commit.gpgsign false
}
cm() { # cm <dir> <file> <msg>
  ( cd "$1" && echo "$2" > "$2" && git add -A && git commit -qm "$3" ) >/dev/null 2>&1
}

# B5 (over-scoping, the VERIFIED repro): local main is 3 commits behind origin/main
# and the feature branch was cut from the FRESH remote. Bare 'main' drags every
# already-merged commit into the review surface.
RB="$TMP/repo-behind"
mkrepo "$RB"
( cd "$RB"
  echo c0 > f; git add -A; git commit -qm c0; git branch -M main
  for i in 1 2 3; do echo "m$i" > "merged$i.txt"; git add -A; git commit -qm "merged $i"; done
  git update-ref refs/remotes/origin/main HEAD                 # remote has all 3
  git update-ref refs/heads/main "$(git rev-parse HEAD~3)"     # local main never fast-forwarded
  git remote add origin ./.git
  git checkout -q -b feature origin/main
  echo new > feature.txt; git add -A; git commit -qm "feat: the actual PR" ) >/dev/null 2>&1
b="$(detect "$RB")"
[ "$b" = "origin/main" ] && ok "base detect: local base BEHIND remote -> origin/main (publish boundary), not stale 'main'" \
  || nok "base detect behind-remote -> origin/main" "got: '$b'"
new_files="$(cd "$RB" && git diff --name-only "$b...HEAD" | sort | tr '\n' ' ')"
old_files="$(cd "$RB" && git diff --name-only "main...HEAD" | sort | tr '\n' ' ')"
{ [ "$new_files" = "feature.txt " ] && [ "$old_files" != "feature.txt " ]; } \
  && ok "base detect: behind-remote scopes ONLY the PR (feature.txt); bare 'main' over-scopes to '$old_files'" \
  || nok "behind-remote scope" "new='$new_files' old='$old_files'"

# B6 (under-scoping — the FALSE PASS, previously unverified): the base branch has
# unpushed commits and the feature branched off them. `main...HEAD` hides the
# unpushed base commits that the push WILL publish -> the gate PASSes a surface it
# never saw. This is the dangerous direction.
RA="$TMP/repo-ahead"
mkrepo "$RA"
( cd "$RA"
  echo c0 > f; git add -A; git commit -qm c0; git branch -M main
  git update-ref refs/remotes/origin/main HEAD                 # remote stops here
  git remote add origin ./.git
  echo "vuln" > unpushed-base-1.php; git add -A; git commit -qm "unpushed base 1"
  echo "vuln" > unpushed-base-2.php; git add -A; git commit -qm "unpushed base 2"
  git checkout -q -b feature
  echo new > feature.txt; git add -A; git commit -qm "feat: the actual PR" ) >/dev/null 2>&1
b="$(detect "$RA")"
[ "$b" = "origin/main" ] && ok "base detect: local base AHEAD of remote -> origin/main (unpushed base commits are in scope)" \
  || nok "base detect ahead-of-remote -> origin/main" "got: '$b'"
gated="$(cd "$RA" && git diff --name-only "$b...HEAD" | sort | tr '\n' ' ')"
naive="$(cd "$RA" && git diff --name-only "main...HEAD" | sort | tr '\n' ' ')"
{ case "$gated" in *unpushed-base-1.php*unpushed-base-2.php*) true ;; *) false ;; esac } \
  && [ "$naive" = "feature.txt " ] \
  && ok "base detect: ahead-of-remote reviews everything the push publishes; bare 'main' saw only '$naive' (false PASS)" \
  || nok "ahead-of-remote scope" "gated='$gated' naive='$naive'"

# B7: no remote at all (local-only repo, or gh unauthenticated). There is no
# remote-tracking ref and the local branch IS the truth -> must stay bare, never
# blindly prefixed with origin/.
RN="$TMP/repo-noremote"
mkrepo "$RN"
( cd "$RN"; echo c0 > f; git add -A; git commit -qm c0; git branch -M main
  git checkout -q -b feature; echo x > x.txt; git add -A; git commit -qm feat ) >/dev/null 2>&1
b="$(detect "$RN")"
[ "$b" = "main" ] && ok "base detect: no remote at all -> bare 'main' (no blind origin/ prefix)" \
  || nok "base detect no-remote -> main" "got: '$b'"
( cd "$RN" && git rev-parse --verify --quiet "$b" >/dev/null ) \
  && ok "base detect: no-remote base resolves to a real ref" || nok "no-remote base resolves" "got: '$b'"

# B8: detached HEAD is a LEGITIMATE state (bisect, CI checkout, tag review). The
# script must still resolve a usable base and must not error out.
RDH="$TMP/repo-detached"
mkrepo "$RDH"
( cd "$RDH"; echo c0 > f; git add -A; git commit -qm c0; git branch -M main
  echo c1 > g; git add -A; git commit -qm c1
  git checkout -q --detach HEAD ) >/dev/null 2>&1
b="$( cd "$RDH" && "$DETECT" 2>/dev/null )"; rc=$?
{ [ "$rc" = 0 ] && [ -n "$b" ] && ( cd "$RDH" && git rev-parse --verify --quiet "$b" >/dev/null ); } \
  && ok "base detect: detached HEAD -> still resolves a real ref (exit 0, '$b')" \
  || nok "base detect detached HEAD" "rc=$rc got: '$b'"

# B9: a fork whose upstream is NOT origin. git's own tracking config is the truth;
# hardcoding origin/ would review against the wrong repository.
RF="$TMP/repo-fork"
mkrepo "$RF"
( cd "$RF"
  echo c0 > f; git add -A; git commit -qm c0; git branch -M main
  git update-ref refs/remotes/upstream/main HEAD
  echo forkonly > forkonly.txt; git add -A; git commit -qm "fork-only commit"
  git update-ref refs/remotes/origin/main HEAD                 # fork's origin is ahead
  git remote add origin ./.git; git remote add upstream ./.git
  git config branch.main.remote upstream
  git config branch.main.merge refs/heads/main
  git checkout -q -b feature; echo x > x.txt; git add -A; git commit -qm feat ) >/dev/null 2>&1
b="$(detect "$RF")"
[ "$b" = "upstream/main" ] && ok "base detect: fork tracking a non-origin upstream -> upstream/main (honors git config)" \
  || nok "base detect fork upstream" "got: '$b'"

# B10: a base branch that legitimately has no remote counterpart yet (created
# locally, never pushed) while other remote refs DO exist -> must stay bare.
RNC="$TMP/repo-nocounterpart"
mkrepo "$RNC"
( cd "$RNC"
  echo c0 > f; git add -A; git commit -qm c0; git branch -M main
  git remote add origin ./.git
  git update-ref refs/remotes/origin/other HEAD                # a remote exists, but not origin/main
  git checkout -q -b feature; echo x > x.txt; git add -A; git commit -qm feat ) >/dev/null 2>&1
b="$(detect "$RNC")"
[ "$b" = "main" ] && ok "base detect: base with no remote counterpart -> bare 'main' (not origin/main)" \
  || nok "base detect no-counterpart" "got: '$b'"

# B11: local branch tracking a DIFFERENTLY NAMED remote branch (local 'main' ->
# origin/master). Prefixing the local name would resolve to a ref that does not exist.
RR="$TMP/repo-renamed"
mkrepo "$RR"
( cd "$RR"
  echo c0 > f; git add -A; git commit -qm c0; git branch -M main
  git remote add origin ./.git
  git update-ref refs/remotes/origin/master HEAD
  git config branch.main.remote origin
  git config branch.main.merge refs/heads/master
  git checkout -q -b feature; echo x > x.txt; git add -A; git commit -qm feat ) >/dev/null 2>&1
b="$(detect "$RR")"
[ "$b" = "origin/master" ] && ok "base detect: local 'main' tracking origin/master -> origin/master (honors branch.*.merge)" \
  || nok "base detect renamed upstream" "got: '$b'"

# B12: the stale-local re-scope is CORRECTED SILENTLY ON STDOUT and REPORTED ON
# STDERR. stdout must stay exactly one clean ref (callers use "$(...)"), and the
# drift must not be swallowed — the user needs to know their checkout is stale.
lines="$( cd "$RB" && "$DETECT" 2>/dev/null | wc -l | tr -d ' ' )"
[ "$lines" = "1" ] && ok "base detect: stdout is exactly one line even when the drift note fires" \
  || nok "base detect stdout hygiene" "got $lines lines"
note="$( cd "$RB" && "$DETECT" 2>&1 >/dev/null )"
case "$note" in
  *behind*origin/main*) ok "base detect: stale local base REPORTED on stderr (not silently swallowed)" ;;
  *) nok "base detect stderr drift note" "got: '$note'" ;;
esac

# B13: --name gives the bare branch name back, for callers that need a branch
# (e.g. `gh pr create --base <name>`), where 'origin/main' would be wrong.
n="$(cd "$RB" && "$DETECT" --name 2>/dev/null)"
[ "$n" = "main" ] && ok "base detect: --name returns the bare branch name ('main') for PR targeting" \
  || nok "base detect --name" "got: '$n'"

# --- P1..P11: a read-only reviewer must not write scanner output into the repo ---
# Observed on Windows/Git Bash: semgrep invoked with `-o <windows-absolute-path>`
# under a POSIX shell created 'C:/Users/.../semgrep.json' as a RELATIVE directory
# tree at the root of the repo under review (on-disk name 'C' + U+F03A). Untracked,
# matched by no common .gitignore, so `git add -A` commits it — and a read-only
# reviewer wrote into the repo it was auditing. A prompt-level instruction was
# tried and failed twice, so enforcement lives in the hook and the scan wrapper.
SCAN="$PLUGIN/scripts/forgeward-scan.sh"
ARTDIR="$PLUGIN/scripts/forgeward-artifact-dir.sh"
GUARD="$PLUGIN/scripts/forgeward-workspace-guard.sh"

# P1/P2: the exact defective shape is DENIED (both slash conventions).
denies "$(pretool "$R" 'semgrep scan --config p/security-audit --json -o C:/Users/x/scratchpad/semgrep.json .')" \
  && ok "scan guard: semgrep -o <windows-abs-path> DENIED (the observed repo-contamination shape)" \
  || nok "scan guard denies drive-letter -o"
denies "$(pretool "$R" 'trivy fs --format json --output D:\\scan\\out.json .')" \
  && ok "scan guard: --output <drive:\\backslash path> DENIED too" \
  || nok "scan guard denies backslash drive path"
# P2b (regression): the CUDDLED short form is one argv token, so a pattern anchored to
# the start of a token misses it entirely. Both this guard and forgeward-scan.sh had
# that hole — the shape that was supposed to be caught by "layers 2 and 3 are the net"
# was in fact caught by neither.
denies "$(pretool "$R" 'semgrep scan --json -oC:/Users/x/scratchpad/semgrep.json .')" \
  && ok "scan guard: CUDDLED '-oC:/…' (single token) DENIED — not just the spaced form" \
  || nok "scan guard denies cuddled drive path"

# P3/P4/P5: explicit NON-GOALS. The guard fires on drive-letter paths only — it is
# not a ban on writing files, and it must never block a developer's own scanner run.
[ -z "$(pretool "$R" 'semgrep scan --config p/security-audit --json .')" ] \
  && ok "scan guard: stdout-only semgrep ALLOWED (the shape reviewers are told to use)" \
  || nok "scan guard allows stdout form"
[ -z "$(pretool "$R" 'semgrep scan --json -o report.json .')" ] \
  && ok "scan guard: deliberate relative -o ALLOWED (a developer's own run is none of the gate's business)" \
  || nok "scan guard allows relative -o"
[ -z "$(pretool "$R" 'semgrep scan --json -o /tmp/out.json .')" ] \
  && ok "scan guard: POSIX-absolute -o ALLOWED" || nok "scan guard allows posix-abs -o"
[ -z "$(pretool "$R" 'echo C:/Users/x/foo.json')" ] \
  && ok "scan guard: a drive path in a NON-scanner command ALLOWED (no collateral denials)" \
  || nok "scan guard non-scanner untouched"

# P7: the wrapper refuses an output-file flag outright, at the layer reviewers use.
out="$("$SCAN" semgrep scan --json -o C:/Users/x/semgrep.json . 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && case "$out" in *STDOUT*|*stdout*) true ;; *) false ;; esac; } \
  && ok "forgeward-scan: refuses -o and points at stdout capture (exit $rc)" \
  || nok "forgeward-scan refuses -o" "rc=$rc out='$out'"

# P8: the wrapper is a passthrough otherwise — stdout reaches the caller intact.
out="$("$SCAN" printf 'HELLO-STDOUT' 2>/dev/null)"
[ "$out" = "HELLO-STDOUT" ] && ok "forgeward-scan: passes tool stdout through unchanged" \
  || nok "forgeward-scan stdout passthrough" "got: '$out'"

# P8b: whether `-o <word>` is a FORMAT or a FILENAME is a PER-TOOL fact. grype and syft
# overload `-o` (`-o json` -> stdout, `-o json=file` -> writes). trivy does not: its own
# help reads `-o, --output string   output file name`, with `-f/--format` separate, so
# `trivy -f json -o json .` writes a file literally named `json`. semgrep and gitleaks
# match trivy. Treating the format allowlist as tool-agnostic made every format word a
# writable filename for three of the four scanners this wrapper guards.
STUBDIR="$TMP/stubs"; mkdir -p "$STUBDIR"
for _n in grype syft trivy semgrep; do
  printf '#!/usr/bin/env bash\necho "{}"\n' > "$STUBDIR/$_n"; chmod +x "$STUBDIR/$_n"
done
"$SCAN" "$STUBDIR/grype" -o json >/dev/null 2>&1
[ "$?" = 0 ] && ok "forgeward-scan: 'grype -o json' ALLOWED (grype overloads -o; the value is a format)" \
  || nok "forgeward-scan allows -o <format> for grype" "expected exit 0"
"$SCAN" "$STUBDIR/syft" -ojson >/dev/null 2>&1
[ "$?" = 0 ] && ok "forgeward-scan: cuddled 'syft -ojson' ALLOWED too" \
  || nok "forgeward-scan allows cuddled -o<format> for syft" "expected exit 0"
tool_ok=1; tool_bad=""
for _t in trivy semgrep; do
  "$SCAN" "$STUBDIR/$_t" -o json >/dev/null 2>&1
  [ "$?" = 2 ] || { tool_ok=0; tool_bad="$tool_bad $_t"; }
done
[ "$tool_ok" = 1 ] && ok "forgeward-scan: 'trivy/semgrep -o json' REFUSED — their -o is a filename, so that writes a file named 'json'" \
  || nok "forgeward-scan tool-agnostic format allowlist" "wrongly allowed:$tool_bad"
"$SCAN" "$STUBDIR/grype" -o json=out.json >/dev/null 2>&1
[ "$?" = 2 ] && ok "forgeward-scan: grype's WRITE form '-o json=out.json' still refused" \
  || nok "forgeward-scan refuses grype -o fmt=file" "expected exit 2"

# P8c/P8d (regressions): two shapes that slipped past the first version of the wrapper.
# The cuddled short flag is one token; and an extension-less relative value ('-o report')
# is still a FILE — the old check only refused values with a slash or a known extension,
# so it created ./report in the repo under review.
"$SCAN" printf X -oC:/Users/x/semgrep.json >/dev/null 2>&1
[ "$?" = 2 ] && ok "forgeward-scan: CUDDLED '-oC:/…' refused (drive letter found anywhere in the token)" \
  || nok "forgeward-scan refuses cuddled drive path" "expected exit 2"
"$SCAN" printf X -o myreport >/dev/null 2>&1
[ "$?" = 2 ] && ok "forgeward-scan: extension-less '-o myreport' refused (deny-by-default; only known FORMAT words pass)" \
  || nok "forgeward-scan refuses extension-less output value" "expected exit 2"

# P8e (regression): closing the cuddled hole with a FULLY unanchored drive-letter match
# over-refused. `<letter>:/` occurs inside legitimate scanner arguments — a remote
# --config URL, and syft/grype source specifiers — none of which are Windows paths.
# Refusing them is friction that pushes a reviewer to bypass the wrapper entirely.
allow_ok=1; allow_bad=""
for _a in "--config|https://semgrep.dev/p/ci" "dir:/home/user/repo" "oci-dir:/img"; do
  _l="${_a%%|*}"; _r="${_a#*|}"
  if [ "$_l" = "$_a" ]; then "$SCAN" printf X "$_a" >/dev/null 2>&1
  else "$SCAN" printf X "$_l" "$_r" >/dev/null 2>&1; fi
  [ "$?" = 0 ] || { allow_ok=0; allow_bad="$allow_bad $_a"; }
done
[ "$allow_ok" = 1 ] && ok "forgeward-scan: a ':/'-bearing NON-path arg is ALLOWED (remote --config URL, syft/grype 'dir:' specifier)" \
  || nok "forgeward-scan over-refuses ':/' args" "refused:$allow_bad"

# P8f (regression): _FORMAT_WORDS wraps across source lines, so the wrap points are
# literal newlines. A `*" $1 "*` test against the raw string silently dropped whichever
# words sat against a wrap — they were then treated as destination paths.
fmt_ok=1; fmt_bad=""
for _f in json sarif yml cyclonedx compact full summary verbose; do
  "$SCAN" "$STUBDIR/grype" -o "$_f" >/dev/null 2>&1
  [ "$?" = 0 ] || { fmt_ok=0; fmt_bad="$fmt_bad $_f"; }
done
[ "$fmt_ok" = 1 ] && ok "forgeward-scan: every format word is recognized, including the ones on _FORMAT_WORDS line wraps" \
  || nok "forgeward-scan format-word line-wrap bug" "wrongly refused:$fmt_bad"

# P8g (regression): ':' is a flag/value separator too (the MSBuild/dotnet/PowerShell
# convention). Handling only '=' left every ENUMERATED output flag reachable through an
# alternate separator — not an unlisted flag (a stated non-goal) but a listed one via a
# side door, so the wrapper's own guarantee was defeated rather than merely incomplete.
colon_ok=1; colon_bad=""
for _c in '--output:C:/x' '--report-file:C:/x' '--sarif-output:C:/x' '-o:C:/x' '--output:report.json' '--outfile:myreport'; do
  "$SCAN" printf X "$_c" >/dev/null 2>&1
  [ "$?" = 2 ] || { colon_ok=0; colon_bad="$colon_bad $_c"; }
done
[ "$colon_ok" = 1 ] && ok "forgeward-scan: COLON-joined output flags refused ('--output:C:/x'), not just '=' and space" \
  || nok "forgeward-scan colon-joined bypass" "passed through:$colon_bad"
# …and the colon widening must not repeat the earlier overshoot.
colon_allow=1; colon_abad=""
for _c in '--config:https://semgrep.dev/p/ci' 'localhost:5000/img:latest' 'dir:/home/user/repo'; do
  "$SCAN" printf X "$_c" >/dev/null 2>&1
  [ "$?" = 0 ] || { colon_allow=0; colon_abad="$colon_abad $_c"; }
done
[ "$colon_allow" = 1 ] && ok "forgeward-scan: colon-bearing NON-path args still ALLOWED (colon-joined URL, registry ref with port+tag)" \
  || nok "forgeward-scan colon widening over-refuses" "refused:$colon_abad"

# P8h (regression): a DASH-LED value for an output flag. looks_like_path() used to
# short-circuit on `-*` — "that's another flag, not this flag's value" — which is simply
# false for getopt-family parsers: pflag/Cobra (gitleaks, trivy) consume the next token
# unconditionally. `gitleaks dir . --report-path -evil.json` went through the wrapper
# with no objection and gitleaks wrote -evil.json into the repo under review. Bare '-'
# stays allowed: it means stdout, the one dash-led value that is not a file.
dash_ok=1; dash_bad=""
for _d in '--output|-x.json' '--report-path|-evil.json' '-o|-x.json' '--outfile|-report' '--output|--'; do
  "$SCAN" printf X "${_d%%|*}" "${_d#*|}" >/dev/null 2>&1
  [ "$?" = 2 ] || { dash_ok=0; dash_bad="$dash_bad ${_d/|/ }"; }
done
[ "$dash_ok" = 1 ] && ok "forgeward-scan: DASH-LED output values refused ('--report-path -evil.json'), incl. a '--' decoy" \
  || nok "forgeward-scan dash-led value bypass" "passed through:$dash_bad"
"$SCAN" printf X -o - >/dev/null 2>&1
[ "$?" = 0 ] && ok "forgeward-scan: bare '-o -' still ALLOWED (stdout, not a file)" \
  || nok "forgeward-scan refuses bare '-'" "expected exit 0"

# P8i: the same shape end-to-end against a REAL scanner, where one is installed — the
# proof that matters is that nothing lands in the repo, not that a string was matched.
if command -v gitleaks >/dev/null 2>&1; then
  DR="$TMP/dashrepo"; mkrepo "$DR"
  ( cd "$DR"; echo x > a.txt; git add -A; git commit -qm base ) >/dev/null 2>&1
  ( cd "$DR" && "$SCAN" gitleaks dir . --report-path -evil.json --no-banner ) >/dev/null 2>&1
  rc=$?
  { [ "$rc" = 2 ] && [ ! -e "$DR/-evil.json" ]; } \
    && ok "forgeward-scan: real gitleaks with a dash-led --report-path is refused and the repo stays clean" \
    || nok "forgeward-scan real dash-led write" "rc=$rc, -evil.json present: $([ -e "$DR/-evil.json" ] && echo yes || echo no)"
else
  ok "forgeward-scan real dash-led write: SKIPPED (gitleaks not installed)"
fi

# P9: the artifact dir is POSIX-absolute, exists, and is OUTSIDE the repo.
ad="$( cd "$R" && "$ARTDIR" )"
case "$ad" in
  /*) ok "artifact dir: POSIX-absolute ('$ad')" ;;
  *)  nok "artifact dir posix-absolute" "got: '$ad'" ;;
esac
[ -d "$ad" ] && ok "artifact dir: exists" || nok "artifact dir exists" "got: '$ad'"
case "$ad" in
  "$R"/*) nok "artifact dir outside repo" "'$ad' is inside the repo under review" ;;
  *)      ok "artifact dir: outside the repo under review" ;;
esac

# P10: the workspace guard catches ANY new untracked path a reviewer leaves behind —
# including shapes the command-text guard structurally cannot see.
snap="$ad/snapshot.txt"
( cd "$R" && "$GUARD" snapshot > "$snap" )
# A plain scratch file, because that is the general shape: the guard's job is to catch
# ANY new untracked path, whatever produced it. (Staging the literal 'C:' tree is
# platform-dependent — MSYS coreutils resolve it to a real Windows path — so it is
# asserted separately below, only where it can actually be staged.)
( cd "$R" && echo '{"results":[]}' > reviewer-scratch.json )
gout="$( cd "$R" && "$GUARD" check "$snap" 2>&1 )"; grc=$?
{ [ "$grc" != 0 ] && case "$gout" in *reviewer-scratch.json*) true ;; *) false ;; esac; } \
  && ok "workspace guard: flags a reviewer-created file by name and exits non-zero" \
  || nok "workspace guard detects contamination" "rc=$grc out='$gout'"
( cd "$R" && rm -f reviewer-scratch.json )
gout="$( cd "$R" && "$GUARD" check "$snap" 2>&1 )"; grc=$?
[ "$grc" = 0 ] && ok "workspace guard: clean tree -> exit 0 (no false alarm)" \
  || nok "workspace guard clean tree" "rc=$grc out='$gout'"
# The observed shape specifically, where the platform can stage it.
if ( cd "$R" && mkdir -p 'C:/Users/x/scratchpad' 2>/dev/null && echo '{}' > 'C:/Users/x/scratchpad/semgrep.json' 2>/dev/null && [ -e 'C:' ] ); then
  gout="$( cd "$R" && "$GUARD" check "$snap" 2>&1 )"; grc=$?
  { [ "$grc" != 0 ] && case "$gout" in *'C:'*) true ;; *) false ;; esac; } \
    && ok "workspace guard: flags the reviewer-created 'C:' tree specifically" \
    || nok "workspace guard detects C: tree" "rc=$grc out='$gout'"
  # './'-prefixed, per the invariant this change establishes: a BARE 'C:' resolves to the
  # drive root under MSYS. Unreachable there today (mkdir resolves it natively, so the
  # guard above is false), but the test must not depend on mkdir and rm translating a
  # drive-letter argument identically.
  ( cd "$R" && rm -rf -- './C:' )
else
  ok "workspace guard: 'C:' tree not stageable on this platform (drive paths resolve natively) — general case asserted above"
fi

# P11/P12: the LIVE filesystem behaviour, with a stub that writes its report exactly
# the way a scanner's -o does (makedirs + open on the path it was handed). Real
# semgrep reproduces this identically — verified by hand, and re-runnable here with
# FORGEWARD_TEST_SEMGREP=1 — but a registry-loading scanner is too slow and too
# network-dependent to sit in a regression suite.
#
# The control is PLATFORM-CONDITIONAL and that is the point: whether 'C:/x' lands
# inside the repo depends on who resolves the path. Under a POSIX runtime it is
# relative (contamination). Under MSYS coreutils or native Windows Python it is
# absolute (no contamination). So the test asks the platform first, then asserts the
# guard either way — a POSIX-only assertion would pass while the bug remained.
SGR="$TMP/scanrepo"; mkrepo "$SGR"
( cd "$SGR"; echo 'x' > a.js; git add -A; git commit -qm base ) >/dev/null 2>&1
STUB="$TMP/fakescan"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Stands in for a scanner writing its report to the path in --out (or a hardcoded one
# with --hardcoded), using the same makedirs+open a scanner's -o writer uses.
#
# It tries a native python3 first and, if that resolved the drive letter natively
# (Windows Python, so nothing landed in the CWD), retries through `wsl.exe -e python3`.
# That second runtime is not a contrivance: it is the configuration that produced the
# original bug — a POSIX-runtime scanner invoked from a Windows shell, where 'C:/…' is
# a relative path. It is what lets the Git Bash run exercise the real defect instead of
# reporting it unstageable.
out=""; rc=0
case "${1:-}" in
  --hardcoded)      out='C:/Users/x/scratchpad/semgrep.json' ;;
  --hardcoded-fail) out='C:/Users/x/scratchpad/semgrep.json'; rc=9 ;;  # contaminates AND fails
  # PLAIN-RELATIVE contamination: a scratch file with no drive letter, so it lands in
  # the repo on EVERY platform. The exit-code contract (0 -> 3, non-zero preserved) is
  # not a property of the drive-letter shape — it is a property of "this run left new
  # untracked paths behind" — so it must be asserted where the drive-letter shape is
  # unstageable (MSYS/native-Windows runtimes resolve 'C:/…' absolutely).
  --dirty)          out='reviewer-report.json' ;;
  --dirty-fail)     out='reviewer-report.json'; rc=9 ;;                # contaminates AND fails
  --out) out="${2:-}" ;;
esac
[ -n "$out" ] || { echo '{"results":[]}'; exit "$rc"; }
write() { "$@" -c 'import os,sys
p=sys.argv[1]; d=os.path.dirname(p)
if d: os.makedirs(d, exist_ok=True)
open(p,"w").write("{}")' "$out" 2>/dev/null; }
write python3
case "$out" in
  [A-Za-z]:[\\/]*)
    [ -e "./${out%%/*}" ] || { command -v wsl.exe >/dev/null 2>&1 && write wsl.exe -e python3; } ;;
esac
echo '{"results":[]}'
exit "$rc"
STUBEOF
chmod +x "$STUB"

( cd "$SGR" && "$STUB" --out 'C:/Users/x/scratchpad/semgrep.json' ) >/dev/null 2>&1
if [ -e "$SGR/C:" ]; then
  ok "scan control: an unguarded drive-letter output path DOES create the 'C:' tree in the repo on this platform (bug reproduced)"
  rm -rf "$SGR/C:"
  contaminates=1
else
  ok "scan control: this platform resolves 'C:/…' natively (MSYS/Windows runtime) — contamination not stageable here, guards asserted anyway"
  contaminates=0
fi

# P11: layer 2 — the wrapper refuses the drive-letter argument, so the tool never runs.
out="$("$SCAN" "$STUB" --out 'C:/Users/x/scratchpad/semgrep.json' 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && [ ! -e "$SGR/C:" ]; } \
  && ok "forgeward-scan: refuses a drive-letter output path outright (tool never runs, repo untouched)" \
  || nok "forgeward-scan refuses drive-letter arg" "rc=$rc"

# P12: layer 3 — a scanner whose bad path is INTERNAL passes every text-level guard
# (nothing in the command mentions it). The wrapper still catches it, because it diffs
# the repo's untracked set across the run.
#
# It REPORTS and does not delete, deliberately: on Git Bash the tree is named
# 'C' + U+F03A, which MSYS maps back to 'C:', and `readlink -f "C:"` there resolves to
# C:/ — THE DRIVE ROOT. An auto-`rm -rf` would have targeted the user's whole C: drive
# on exactly the platform this bug lives on. Only the './'-prefixed form stays
# relative, so that is what the wrapper prints for the user to run.
hard="$( cd "$SGR" && "$SCAN" "$STUB" --hardcoded 2>"$ad/scan-stderr.txt" )"; hard_rc=$?
serr="$(cat "$ad/scan-stderr.txt" 2>/dev/null)"
# P12b: contamination must not read as SUCCESS. The stub exits 0 (a scanner that finds
# nothing does too), so a caller checking only $? would see a clean run while the repo
# has just been written to. Only asserted where the platform can stage the write.
if [ "$contaminates" = 1 ]; then
  [ "$hard_rc" = 3 ] && ok "forgeward-scan: a tool that exits 0 but contaminates the repo yields exit 3, not 0" \
    || nok "forgeward-scan contamination exit code" "got rc=$hard_rc, expected 3"
  ( cd "$SGR" && rm -rf -- './C:' )
  # …and the substitution must never MASK a real tool failure. Only a zero becomes 3.
  ( cd "$SGR" && "$SCAN" "$STUB" --hardcoded-fail ) >/dev/null 2>&1; fail_rc=$?
  [ "$fail_rc" = 9 ] && ok "forgeward-scan: a tool that contaminates AND fails keeps its own exit code (9), not 3" \
    || nok "forgeward-scan masks tool failure" "got rc=$fail_rc, expected 9"
else
  [ "$hard_rc" = 0 ] && ok "forgeward-scan: clean run passes the tool's own exit code through (0)" \
    || nok "forgeward-scan clean exit passthrough" "got rc=$hard_rc"
fi
if [ "$contaminates" = 1 ]; then
  { case "$hard" in *results*) true ;; *) false ;; esac; } \
    && { case "$serr" in *'rm -rf -- "./'*) true ;; *) false ;; esac; } \
    && [ -e "$SGR/C:" ] \
    && ok "forgeward-scan: ran the tool (stdout intact), REPORTED the 'C:' tree it created via an INTERNAL path, and left removal to the user (auto-rm would hit the drive root here)" \
    || nok "forgeward-scan reports internal-path contamination" "stdout='$hard' stderr='$serr'"
  ( cd "$SGR" && rm -rf -- './C:' )
else
  case "$hard" in *results*) ok "forgeward-scan: internal-path contamination not stageable here (platform resolves drive paths natively); tool still ran, stdout intact" ;;
                  *) nok "forgeward-scan internal-path passthrough" "stdout='$hard'" ;; esac
fi

# P12c/P12d: the exit-code contract, asserted on EVERY platform.
#
# P12/P12b above can only run where the drive-letter tree is stageable, so on MSYS and
# native-Windows runtimes the two assertions that matter most — contamination is not
# success, and the substitution never masks a real failure — were skipped entirely. That
# is backwards: the wrapper's exit-code logic keys off "did the untracked set change",
# not off the drive letter, so a plain relative scratch file exercises the identical
# branch and lands in the repo everywhere. These run unconditionally; the drive-letter
# pair stays platform-conditional because the '.C:'-tree MESSAGE genuinely is
# platform-specific.
dfile="$SGR/reviewer-report.json"
dout="$( cd "$SGR" && "$SCAN" "$STUB" --dirty 2>"$ad/dirty-stderr.txt" )"; drc=$?
derr="$(cat "$ad/dirty-stderr.txt" 2>/dev/null)"
{ [ "$drc" = 3 ] && [ -e "$dfile" ]; } \
  && ok "forgeward-scan: a tool that exits 0 but leaves an untracked file yields exit 3 (asserted on every platform)" \
  || nok "forgeward-scan contamination exit code (platform-independent)" "rc=$drc, file present: $([ -e "$dfile" ] && echo yes || echo no)"
{ case "$derr" in *reviewer-report.json*) true ;; *) false ;; esac; } \
  && { case "$dout" in *results*) true ;; *) false ;; esac; } \
  && ok "forgeward-scan: names the contaminating path on stderr and still passes tool stdout through" \
  || nok "forgeward-scan contamination report (platform-independent)" "stdout='$dout' stderr='$derr'"
rm -f "$dfile"

# The one the checkpoint flagged as missing off-Linux: contaminates AND fails. Only a
# ZERO becomes 3; a tool that already failed keeps its own code, because the caller
# knows something went wrong and 3 would erase which thing.
( cd "$SGR" && "$SCAN" "$STUB" --dirty-fail ) >/dev/null 2>&1; dfrc=$?
{ [ "$dfrc" = 9 ] && [ -e "$dfile" ]; } \
  && ok "forgeward-scan: a tool that contaminates AND fails keeps its own exit code (9, not 3) — asserted on every platform" \
  || nok "forgeward-scan masks tool failure (platform-independent)" "rc=$dfrc, expected 9; file present: $([ -e "$dfile" ] && echo yes || echo no)"
rm -f "$dfile"

# Control: a clean run of the same stub must NOT trip the contamination path, or the two
# assertions above would pass for the wrong reason (any exit-3 would look like a catch).
( cd "$SGR" && "$SCAN" "$STUB" ) >/dev/null 2>&1; crc=$?
[ "$crc" = 0 ] && ok "forgeward-scan: same stub with no writes -> exit 0 (the exit-3 assertions above are not vacuous)" \
  || nok "forgeward-scan clean-run control" "rc=$crc, expected 0"

# Opt-in: the same control against the real scanner, off by default (slow, hits the
# rule registry). FORGEWARD_TEST_SEMGREP=1 bash test/gate-test.sh
if [ "${FORGEWARD_TEST_SEMGREP:-0}" = 1 ] && command -v semgrep >/dev/null 2>&1; then
  ( cd "$SGR" && semgrep scan --config "$PLUGIN/rules/wp-security.yml" --metrics=off --json \
      -o 'C:/Users/x/scratchpad/semgrep.json' a.js ) >/dev/null 2>&1
  real=0; [ -e "$SGR/C:" ] && real=1; rm -rf "$SGR/C:"
  [ "$real" = "$contaminates" ] \
    && ok "real semgrep matches the stub's contamination behaviour on this platform" \
    || nok "real semgrep vs stub" "semgrep=$real stub=$contaminates"
fi

# --- G1..G4 (marker GC): markers must not accumulate forever -------------------
# One marker per branch ever gated, left behind by every merge-and-delete. Never
# consulted (lookup is keyed by the CURRENT branch) but unbounded. write-marker prunes
# on write. Placed last so nothing downstream depends on R's marker state.
MARKDIR="$(git -C "$R" rev-parse --path-format=absolute --git-common-dir)/forgeward-gate-markers"

# G1: a marker is written for a branch that is about to be deleted.
( cd "$R" && git checkout -qb gcdead && echo g > gc.txt && git add -A && git commit -qm gc && "$WRITE" main "privacy" ) >/dev/null 2>&1
[ -f "$MARKDIR/gcdead.json" ] && ok "marker GC: precondition — a marker exists for branch 'gcdead'" \
  || nok "marker GC precondition" "no $MARKDIR/gcdead.json"

# G2: delete the branch, gate again -> the orphaned marker is pruned.
( cd "$R" && git checkout -q feature && git branch -D gcdead ) >/dev/null 2>&1
( cd "$R" && "$WRITE" main "privacy" ) >/dev/null 2>&1
[ ! -f "$MARKDIR/gcdead.json" ] && ok "marker GC: a marker whose branch no longer exists is pruned on the next write" \
  || nok "marker GC prunes orphan" "$MARKDIR/gcdead.json still present"

# G3: the marker just written survives (the obvious way to get this wrong).
[ -f "$MARKDIR/feature.json" ] && ok "marker GC: the marker just written survives its own GC pass" \
  || nok "marker GC ate its own marker" "no $MARKDIR/feature.json"

# G4 (the case it must NOT fire on): a branch checked out in ANOTHER linked worktree
# is alive. Existence is checked against refs/heads under the common git dir, which
# every worktree shares -- so 'wtfeat', gated from inside $WT and never checked out in
# R, must keep its marker. Deleting it would force a needless re-gate in that worktree.
{ [ -f "$MARKDIR/wtfeat.json" ] && [ -f "$MARKDIR/wtspace.json" ]; } \
  && ok "marker GC: markers for branches live in OTHER worktrees survive (refs/heads is shared)" \
  || nok "marker GC ate a live worktree branch's marker" "wtfeat/wtspace marker missing"

# M1 (manifest hooks guard): the standard hooks/hooks.json is auto-loaded by Claude
# Code, so .claude-plugin/plugin.json must NOT also reference it via the "hooks" key —
# doing so fails plugin load with "Duplicate hooks file detected". The manifest.hooks
# key is only for ADDITIONAL hook files. Guard it statically so a re-add is caught here.
MANIFEST="$PLUGIN/.claude-plugin/plugin.json"
hooks_ref="$(
  if command -v jq >/dev/null 2>&1; then jq -r '.hooks // ""' "$MANIFEST"
  else python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("hooks",""))' "$MANIFEST"
  fi
)"
case "$hooks_ref" in
  */hooks.json) nok "manifest does not re-reference the auto-loaded hooks/hooks.json" "plugin.json hooks='$hooks_ref' (remove it; the standard file auto-loads)" ;;
  *)            ok "manifest does not re-reference the auto-loaded hooks/hooks.json (no duplicate-load)" ;;
esac

echo "1..$((PASS+FAIL))"
echo "# pass $PASS / fail $FAIL"
[ "$FAIL" -eq 0 ]
