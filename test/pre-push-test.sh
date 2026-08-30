#!/usr/bin/env bash
# Regression suite for the forgeward pre-push ENFORCER (scripts/forgeward-pre-push.sh).
#
# Drives it exactly as git does: argv = `<remote> <url>`, and on stdin one line per
# ref being pushed: `<local-ref> <local-sha> <remote-ref> <remote-sha>`. Because git
# supplies concrete refs+SHAs, this layer needs no command parsing — the shell-text
# bypasses that plagued the PreToolUse hook simply don't exist here. Framework-free.
set -uo pipefail
PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREPUSH="$PLUGIN/scripts/forgeward-pre-push.sh"
WRITE="$PLUGIN/scripts/forgeward-write-marker.sh"
ZERO='0000000000000000000000000000000000000000'
RSHA='1111111111111111111111111111111111111111'   # arbitrary "remote" sha (hook ignores it)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok %d - %s\n' "$((PASS+FAIL))" "$1"; }
nok() { FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$((PASS+FAIL))" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; }

# run the enforcer from <cwd> with <stdin-lines>; sets RC (exit) and OUT (merged output)
pp() { OUT="$( cd "$1" && printf '%s' "$2" | "$PREPUSH" origin /nonexistent.git 2>&1 )"; RC=$?; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forgeward-prepush.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"; git init -q "$R"; cd "$R"
git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
git config forgeward.gate enabled   # opt in (the enforcer no-ops without this)
printf '{\n  "name":"u","version":"1.0.0","dependencies":{"express":"^4.19.2"}\n}\n' > package.json
echo ok > src.js; git add -A; git commit -qm base; git branch -M main

git checkout -qb g   main; echo g > g.js;  git add -A; git commit -qm g;  "$WRITE" main "privacy" >/dev/null
SHA_G="$(git rev-parse refs/heads/g)"
git checkout -qb g2  main; echo g2 > g2.js; git add -A; git commit -qm g2; "$WRITE" main "privacy" >/dev/null
SHA_G2="$(git rev-parse refs/heads/g2)"
git checkout -qb bad main; echo b > b.js;  git add -A; git commit -qm bad          # no marker
SHA_BAD="$(git rev-parse refs/heads/bad)"
git checkout -q main

# P1: gated ref -> allowed
pp "$R" "refs/heads/g $SHA_G refs/heads/g $RSHA"$'\n'
[ "$RC" = 0 ] && ok "gated ref -> push ALLOWED (exit 0)" || nok "gated allowed" "rc=$RC out=$OUT"

# P2: ungated ref -> blocked, and the message names it
pp "$R" "refs/heads/bad $SHA_BAD refs/heads/bad $RSHA"$'\n'
# `case`, not `printf | grep -q`: with the `set -o pipefail` above, grep -q exits on
# first match and printf takes SIGPIPE, so the pipeline reports failure on input it
# just matched. Same defect this suite's sibling carried; see denies() in gate-test.sh.
{ [ "$RC" = 1 ] && case "$OUT" in *bad*) true ;; *) false ;; esac; } \
  && ok "ungated ref -> push BLOCKED (exit 1, names the ref)" || nok "ungated blocked" "rc=$RC out=$OUT"

# P3: multi-ref, one ungated -> the whole push is blocked (git enumerates the refs for us)
pp "$R" "refs/heads/g $SHA_G refs/heads/g $RSHA"$'\n'"refs/heads/bad $SHA_BAD refs/heads/bad $RSHA"$'\n'
[ "$RC" = 1 ] && ok "multi-ref with an ungated ref -> push BLOCKED" || nok "multi-ref blocked" "rc=$RC out=$OUT"

# P4: multi-ref, every ref gated -> allowed
pp "$R" "refs/heads/g $SHA_G refs/heads/g $RSHA"$'\n'"refs/heads/g2 $SHA_G2 refs/heads/g2 $RSHA"$'\n'
[ "$RC" = 0 ] && ok "multi-ref, every ref gated -> ALLOWED" || nok "multi-ref allowed" "rc=$RC out=$OUT"

# P5: branch deletion (zero local sha) -> allowed (publishes no code)
pp "$R" "(delete) $ZERO refs/heads/bad $RSHA"$'\n'
[ "$RC" = 0 ] && ok "branch deletion (zero sha) -> ALLOWED" || nok "deletion allowed" "rc=$RC out=$OUT"

# P6: a NEW commit on g after the marker -> stale -> blocked
git checkout -q g; echo more >> g.js; git add -A; git commit -qm "post-gate code"
SHA_G_STALE="$(git rev-parse refs/heads/g)"; git checkout -q main; git branch -f g "$SHA_G"
pp "$R" "refs/heads/g $SHA_G_STALE refs/heads/g $RSHA"$'\n'
[ "$RC" = 1 ] && ok "post-marker commit -> stale -> BLOCKED" || nok "stale blocked" "rc=$RC out=$OUT"

# P7: version-only bump on g -> hash invariant -> still allowed
git checkout -q g
python3 -c "import json;d=json.load(open('package.json'));d['version']='1.0.1.0';open('package.json','w').write(json.dumps(d,indent=2)+chr(10))"
git add -A; git commit -qm "chore: bump version"
SHA_G_BUMP="$(git rev-parse refs/heads/g)"; git checkout -q main; git branch -f g "$SHA_G"
pp "$R" "refs/heads/g $SHA_G_BUMP refs/heads/g $RSHA"$'\n'
[ "$RC" = 0 ] && ok "version-only bump on a gated ref -> still ALLOWED (marker survives)" || nok "version bump allowed" "rc=$RC out=$OUT"

# P8: a non-branch ref (tag) -> not branch-gated here -> allowed
pp "$R" "refs/tags/v1 $SHA_BAD refs/tags/v1 $RSHA"$'\n'
[ "$RC" = 0 ] && ok "non-branch ref (tag) -> ALLOWED (not branch-gated)" || nok "tag allowed" "rc=$RC out=$OUT"

# P9 (the original worktree bug, now handled robustly): a marker written INSIDE a
# linked worktree is honored when the push is evaluated from the MAIN checkout. No cd,
# no parsing — git hands the exact ref+sha on stdin and the marker is found under the
# shared common git dir.
WT="$TMP/wt"; git -C "$R" worktree add -q -b wt "$WT" main >/dev/null 2>&1
( cd "$WT"; echo w > w.js; git add -A; git commit -qm wt; "$WRITE" main "privacy" ) >/dev/null
SHA_WT="$(git -C "$R" rev-parse refs/heads/wt)"
pp "$R" "refs/heads/wt $SHA_WT refs/heads/wt $RSHA"$'\n'
[ "$RC" = 0 ] && ok "worktree: marker from a linked worktree honored from the main checkout (exact ref on stdin)" \
  || nok "worktree pre-push allow" "rc=$RC out=$OUT"

# P11: publish a GATED commit to a remote branch via a bare-SHA source
# (`git push origin <sha>:refs/heads/main`) — local_ref is the SHA, not refs/heads/*.
# Gating must key off the REMOTE ref + the commit, not the local side. ALLOWED.
pp "$R" "$SHA_G $SHA_G refs/heads/main $RSHA"$'\n'
[ "$RC" = 0 ] && ok "bare-SHA source of a gated commit -> ALLOWED (keys off remote ref + commit)" \
  || nok "sha-source gated allowed" "rc=$RC out=$OUT"

# P12: publish an UNGATED commit via a bare-SHA source -> BLOCKED. The old code keyed off
# local_ref, saw a non-refs/heads value, and SKIPPED the line — a silent fail-open.
pp "$R" "$SHA_BAD $SHA_BAD refs/heads/main $RSHA"$'\n'
[ "$RC" = 1 ] && ok "bare-SHA source of an ungated commit -> BLOCKED (fail-open fixed)" \
  || nok "sha-source ungated blocked" "rc=$RC out=$OUT"

# P13: HEAD source (`git push origin HEAD:refs/heads/main`) — local_ref is 'HEAD'.
pp "$R" "HEAD $SHA_G refs/heads/main $RSHA"$'\n'
[ "$RC" = 0 ] && ok "HEAD source of a gated commit -> ALLOWED" || nok "HEAD-source gated allowed" "rc=$RC out=$OUT"
pp "$R" "HEAD $SHA_BAD refs/heads/main $RSHA"$'\n'
[ "$RC" = 1 ] && ok "HEAD source of an ungated commit -> BLOCKED" || nok "HEAD-source ungated blocked" "rc=$RC out=$OUT"

# P14: marker_get must trust jq's EXIT STATUS, not just its output.
#
# This copy of marker_get had drifted from gate-check.sh's in two ways at once: it
# discarded jq's exit status, and it still used print() instead of sys.stdout.buffer.write
# (DECISIONS.md recorded that second fix as landed; it had only ever landed next door).
#
# The exit-status half is what this pins. `command -v jq` succeeding means jq is
# INSTALLED, not that it RUNS; while it was installed-and-broken, every marker read came
# back empty, is_fresh() returned 1, and EVERY push was refused with the python3 fallback
# sitting one branch away and unreachable. Fail-closed, so nothing shipped ungated — but
# a hook that blocks every push regardless of the marker is not enforcing anything.
#
# The print() half is NOT observable on POSIX: print() appends "\n" and `$( )` strips it,
# so both forms produce identical bytes here. It only diverges on Windows, where Python
# translates that "\n" to "\r\n" in text mode and `$( )` strips only the LF — the stray
# CR then rides on `base`, fails to resolve as a ref, and a fresh marker reads as stale.
# Stated rather than asserted, because faking a CRLF stdout would test the fake. What
# catches it instead is A19 in gate-test.sh, which pins the two copies byte-identical.
#
# Own repo, deliberately WITHOUT any version-bearing manifest: forgeward-diff-hash.sh
# consults jq only to canonicalize those, so this leaves marker_get as the one jq
# consumer on the path and a red result has one cause.
R3="$TMP/repo-markerget"; git init -q "$R3"
( cd "$R3"; git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  git config forgeward.gate enabled
  echo base > a.txt; git add -A; git commit -qm base; git branch -M main
  git checkout -qb ungated; echo u > u.txt; git add -A; git commit -qm ungated
  git checkout -qb gated main; echo w > w.txt; git add -A; git commit -qm work
  "$WRITE" main "privacy" ) >/dev/null 2>&1
SHA_MG="$(git -C "$R3" rev-parse refs/heads/gated)"
SHA_MGU="$(git -C "$R3" rev-parse refs/heads/ungated)"

JQFAIL="$TMP/shadow-jq"; mkdir -p "$JQFAIL"
printf '#!/bin/sh\nexit 1\n' > "$JQFAIL/jq"; chmod +x "$JQFAIL/jq"
ppjq() { OUT="$( cd "$1" && printf '%s' "$2" | PATH="$JQFAIL:$PATH" "$PREPUSH" origin /nonexistent.git 2>&1 )"; RC=$?; }

pp   "$R3" "refs/heads/gated $SHA_MG refs/heads/gated $RSHA"$'\n';   RC_HEALTHY=$RC
ppjq "$R3" "refs/heads/gated $SHA_MG refs/heads/gated $RSHA"$'\n';   RC_BROKEN=$RC
# The control that makes this non-vacuous: exit 0 also means "the hook bailed early"
# (missing tooling and a non-git cwd both fail OPEN by design). Under the SAME broken jq
# an ungated ref must still be BLOCKED, which proves the enforcer actually ran.
ppjq "$R3" "refs/heads/ungated $SHA_MGU refs/heads/ungated $RSHA"$'\n'; RC_CONTROL=$RC

{ [ "$RC_HEALTHY" = 0 ] && [ "$RC_BROKEN" = 0 ] && [ "$RC_CONTROL" = 1 ]; } \
  && ok "jq present but exiting 1 -> a valid marker is still READ (python3 answers; gated ref allowed, ungated still blocked)" \
  || nok "marker_get discards jq's exit status (a broken jq refuses every push, gated or not)" \
         "healthy=$RC_HEALTHY broken=$RC_BROKEN control=$RC_CONTROL (want 0/0/1)"

# P15: interpreter discovery must probe, not merely find, python3. This mirrors the
# native-Windows Microsoft Store alias shape with a deterministic shim: jq and python3
# are both present but unusable, while `python` is a working interpreter. Exercise both
# verdict directions so an early fail-open cannot satisfy the fresh-marker control.
PYFALLBACK="$TMP/python-fallback"; mkdir -p "$PYFALLBACK"
printf '#!/bin/sh\nexit 1\n' > "$PYFALLBACK/jq"
printf '#!/bin/sh\nexit 1\n' > "$PYFALLBACK/python3"
ln -s "$(command -v python3)" "$PYFALLBACK/python"
chmod +x "$PYFALLBACK/jq" "$PYFALLBACK/python3"
pppy() { OUT="$( cd "$1" && printf '%s' "$2" | PATH="$PYFALLBACK:$PATH" "$PREPUSH" origin /nonexistent.git 2>&1 )"; RC=$?; }

pppy "$R3" "refs/heads/gated $SHA_MG refs/heads/gated $RSHA"$'\n';       RC_PY_GATED=$RC
pppy "$R3" "refs/heads/ungated $SHA_MGU refs/heads/ungated $RSHA"$'\n'; RC_PY_UNGATED=$RC
{ [ "$RC_PY_GATED" = 0 ] && [ "$RC_PY_UNGATED" = 1 ]; } \
  && ok "unusable python3 falls through to working python (gated allowed, ungated blocked)" \
  || nok "pre-push functional Python fallback" "gated=$RC_PY_GATED ungated=$RC_PY_UNGATED (want 0/1)"

# P10 (opt-in safety): a repo that never enabled the gate is a NO-OP, even for an
# ungated ref — so a shared/global pre-push hook can't block unrelated repos.
R2="$TMP/repo2"; git init -q "$R2"
( cd "$R2"; git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  echo x > f; git add -A; git commit -qm base ) >/dev/null   # NOTE: no forgeward.gate config
SHA_R2="$(git -C "$R2" rev-parse HEAD)"
pp "$R2" "refs/heads/master $SHA_R2 refs/heads/master $RSHA"$'\n'
[ "$RC" = 0 ] && ok "opt-in: a repo without forgeward.gate is a NO-OP (safe as a global hook)" \
  || nok "opt-in no-op" "rc=$RC out=$OUT"

echo "1..$((PASS+FAIL))"
echo "# pass $PASS / fail $FAIL"
[ "$FAIL" -eq 0 ]
