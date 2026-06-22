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

# S10: the UserPromptExpansion matcher (read from the real hooks.json) must fire on
# `ship` AND any <prefix>-ship (gstack --prefix), but NOT on lookalike commands.
# Evaluated as a JS regex (node) to match Claude Code's matcher engine; python re
# fallback is equivalent for this anchored pattern.
MATCHER="$(python3 -c "import json;print(json.load(open('$PLUGIN/hooks/hooks.json'))['hooks']['UserPromptExpansion'][0]['matcher'])")"
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
detect() { ( cd "$1" && "$DETECT" ); }   # detect <repo> -> base ref

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
[ "$b" = "develop" ] && ok "base detect: origin/HEAD set -> honored (unchanged when set)" \
  || nok "base detect set->develop" "got: '$b'"

# B4 (direct-to-base fix): HEAD committed DIRECTLY on the base branch with
# origin/<base> behind by the unpushed commit. Old logic resolved to bare 'main'
# -> "main...HEAD" is EMPTY -> the gate mis-reads "nothing to gate" and deadlocks
# (push stays hook-blocked, yet no reviewable surface). New step 4 re-scopes to
# origin/main so the real unpushed change is reviewed. Mirrors the live repro: a
# docs commit made straight to master.
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

echo "1..$((PASS+FAIL))"
echo "# pass $PASS / fail $FAIL"
[ "$FAIL" -eq 0 ]
