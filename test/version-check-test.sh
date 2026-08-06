#!/usr/bin/env bash
# Regression suite for ci/check-version-monotonic.sh.
#
# Framework-free, same as gate-test.sh and pre-push-test.sh: bash and git only, the
# real script under test, no copies. Runs standalone and via `npm test`.
#
# What is being pinned is a COMPARATOR, and a comparator's failure mode is that it
# quietly answers the wrong way rather than crashing. So the shape of this file is
# pairs: for each rule, the case that must FAIL and the neighbouring case that must
# PASS. An assertion that only ever checks the fail side cannot tell a working
# comparator from one that refuses everything, and a green "refuses everything" is how
# a required check gets deleted a week later.
set -uo pipefail

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHK="$PLUGIN/ci/check-version-monotonic.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok %d - %s\n' "$((PASS+FAIL))" "$1"; }
nok()  { FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$((PASS+FAIL))" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forgeward-vc-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# setv <repo> <package-version> <plugin-version> <marketplace-version>
# Written as three separate arguments ON PURPOSE. The realistic failure is a release
# that moves some manifests and not others, so the fixture has to be able to express a
# disagreement -- a single-version helper could not produce the R4 case at all.
setv() {
  local r="$1"
  mkdir -p "$r/.claude-plugin"
  printf '{\n  "name": "forgeward-gate",\n  "version": "%s",\n  "private": true\n}\n' "$2" > "$r/package.json"
  printf '{\n  "name": "forgeward",\n  "version": "%s",\n  "defaultEnabled": true\n}\n' "$3" > "$r/.claude-plugin/plugin.json"
  printf '{\n  "name": "forgeward-gate",\n  "plugins": [\n    { "name": "forgeward", "version": "%s" }\n  ]\n}\n' "$4" > "$r/.claude-plugin/marketplace.json"
}

# mkfixture <name> <base-versions...> -> repo path with master at base, feature checked out
# Callers set the head versions themselves and commit via `commit_head`.
mkfixture() { # mkfixture <name> <pkg> <plugin> <market>
  local r="$TMP/$1"
  git init -q "$r"
  git -C "$r" config user.email t@t.t
  git -C "$r" config user.name t
  git -C "$r" config commit.gpgsign false
  setv "$r" "$2" "$3" "$4"
  ( cd "$r" && git add -A && git commit -qm base && git branch -M master && git checkout -qb feature ) >/dev/null 2>&1
  printf '%s' "$r"
}
commit_head() { ( cd "$1" && git add -A && git commit -qm head ) >/dev/null 2>&1; }

# run <repo> [base] -> sets $out and $st
run() {
  out="$( cd "$1" && bash "$CHK" "${2:-master}" 2>&1 )"; st=$?
}

# --- R1/R2: the two shapes that must NOT fire ------------------------------------
# The rule is "never backward", not "always bump". Most PRs in this repo are docs or
# fixes that leave the version alone (#21 is one), so if equality failed here the check
# would be red on the common case and would be switched off rather than fixed.

R="$(mkfixture equal 0.9.0 0.9.0 0.9.0)"
( cd "$R" && echo change > f.txt ); commit_head "$R"
run "$R"
[ "$st" -eq 0 ] && ok "R1 equal version (a PR that does not touch the version) -> PASS" \
  || nok "R1 equality passes" "st=$st out=$out"

R="$(mkfixture forward 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.9.1 0.9.1 0.9.1; commit_head "$R"
run "$R"
[ "$st" -eq 0 ] && ok "R2 forward bump on all three -> PASS" || nok "R2 forward bump passes" "st=$st out=$out"

# --- R3: the hazard itself -------------------------------------------------------
# The live case: #17 bumped to 0.7.5 and #18 to 0.7.6, and merging #17 second would
# have walked the marketplace manifest back. Avoided by hand on 2026-08-06; this is
# the assertion that means nobody has to remember next time.
R="$(mkfixture backward 0.7.6 0.7.6 0.7.6)"
setv "$R" 0.7.5 0.7.5 0.7.5; commit_head "$R"
run "$R"
[ "$st" -ne 0 ] && case "$out" in *BACKWARD*) true ;; *) false ;; esac \
  && ok "R3 backward bump -> FAIL, and the message says BACKWARD" \
  || nok "R3 backward bump fails" "st=$st out=$out"

# --- R4: a release moves all three together --------------------------------------
# The half-bumped release. marketplace.json is the file a plugin manager actually
# reads, so a bump that lands everywhere except there ships an unchanged version to
# every user while the repo believes it released.
R="$(mkfixture disagree 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.9.1 0.9.1 0.9.0; commit_head "$R"
run "$R"
[ "$st" -ne 0 ] && case "$out" in *disagree*) true ;; *) false ;; esac \
  && ok "R4 manifests disagree on the head side -> FAIL" || nok "R4 disagreement fails" "st=$st out=$out"

R="$(mkfixture agree 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.9.1 0.9.1 0.9.1; commit_head "$R"
run "$R"
[ "$st" -eq 0 ] && ok "R4b all three agree -> PASS (R4 is not just refusing everything)" \
  || nok "R4b agreement passes" "st=$st out=$out"

# --- R5: 0.10.0 is AHEAD of 0.9.0 ------------------------------------------------
# A plain string comparison calls this backward and would refuse the release that
# leaves single-digit minors -- the first genuinely valuable bump this repo will make.
# Pinned in both directions so the fix cannot be "always return not-behind".
R="$(mkfixture tenten 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.10.0 0.10.0 0.10.0; commit_head "$R"
run "$R"
[ "$st" -eq 0 ] && ok "R5 0.9.0 -> 0.10.0 reads FORWARD (not a string comparison)" \
  || nok "R5 numeric minor ordering" "st=$st out=$out"

R="$(mkfixture tenten_rev 0.10.0 0.10.0 0.10.0)"
setv "$R" 0.9.0 0.9.0 0.9.0; commit_head "$R"
run "$R"
[ "$st" -ne 0 ] && ok "R5b 0.10.0 -> 0.9.0 reads BACKWARD" || nok "R5b reverse ordering" "st=$st out=$out"

# --- R6: no place-value ceiling --------------------------------------------------
# `major*1000000 + minor*1000 + patch` is the obvious comparator and it ties 1.0.1000
# with 1.1.0, so a backward merge across that boundary passes clean. Component-wise
# comparison has no such ceiling. This is the assertion that pins the difference.
R="$(mkfixture ceiling 1.1.0 1.1.0 1.1.0)"
setv "$R" 1.0.1000 1.0.1000 1.0.1000; commit_head "$R"
run "$R"
[ "$st" -ne 0 ] && ok "R6 1.1.0 -> 1.0.1000 reads BACKWARD (no weighted-sum tie)" \
  || nok "R6 place-value ceiling" "st=$st out=$out"

R="$(mkfixture ceiling_rev 1.0.1000 1.0.1000 1.0.1000)"
setv "$R" 1.1.0 1.1.0 1.1.0; commit_head "$R"
run "$R"
[ "$st" -eq 0 ] && ok "R6b 1.0.1000 -> 1.1.0 reads FORWARD" || nok "R6b ceiling reverse" "st=$st out=$out"

# --- R7: a shape it cannot order is REFUSED, never guessed ------------------------
# Blind spot 2. A prerelease has an ordering this script does not implement, and the
# failure mode of guessing is a silent wrong answer on exactly the release where care
# matters most. Red CI and a deliberate edit is the correct cost.
R="$(mkfixture prerelease 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.10.0-rc1 0.10.0-rc1 0.10.0-rc1; commit_head "$R"
run "$R"
[ "$st" -ne 0 ] && case "$out" in *'not X.Y.Z'*) true ;; *) false ;; esac \
  && ok "R7 a prerelease version is REFUSED, not mis-ordered" || nok "R7 prerelease refused" "st=$st out=$out"

# --- R8: ambiguity is refused, not guessed ---------------------------------------
# Blind spot 3. Two version fields means the script cannot know which one is the
# plugin's, and picking the first is a coin flip dressed as an answer.
R="$(mkfixture ambiguous 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.9.1 0.9.1 0.9.1
printf '{\n  "name": "p",\n  "version": "0.9.1",\n  "nested": { "version": "0.0.1" }\n}\n' > "$R/.claude-plugin/plugin.json"
commit_head "$R"
run "$R"
[ "$st" -ne 0 ] && case "$out" in *'exactly 1 version field'*) true ;; *) false ;; esac \
  && ok "R8 two version fields in one manifest -> REFUSED" || nok "R8 ambiguity refused" "st=$st out=$out"

# R8b: the SAME rule with both keys on ONE line. Split out from R8 because R8 alone
# could not tell the guard from its accident: the counter was `grep -c`, which counts
# matching LINES, so R8's two-line fixture was the only arrangement it got right. The
# one-line arrangement counted 1, skipped the guard, and still exited non-zero for an
# unrelated reason -- so an assertion checking only the exit status would have stayed
# green over the defect. This one reads the MESSAGE, which is the part that was wrong.
R="$(mkfixture ambiguous-oneline 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.9.1 0.9.1 0.9.1
printf '{"name":"p","version":"0.9.1","nested":{"version":"0.0.1"}}\n' > "$R/.claude-plugin/plugin.json"
commit_head "$R"
run "$R"
[ "$st" -ne 0 ] && case "$out" in *'exactly 1 version field'*) true ;; *) false ;; esac \
  && ok "R8b two version fields on ONE line -> REFUSED for the stated reason" \
  || nok "R8b same-line ambiguity refused" "st=$st out=$out"

# --- R9: adding a manifest is legitimate and must not fire ------------------------
# Blind spot 4. There is no prior value to compare against, which is not the same
# observation as "it went backward".
R="$(mkfixture newmanifest 0.9.0 0.9.0 0.9.0)"
( cd "$R" && git checkout -q master && git rm -q .claude-plugin/marketplace.json && git commit -qm "drop" && git checkout -q feature ) >/dev/null 2>&1
setv "$R" 0.9.1 0.9.1 0.9.1; commit_head "$R"
run "$R"
[ "$st" -eq 0 ] && case "$out" in *'no prior version'*) true ;; *) false ;; esac \
  && ok "R9 a manifest absent from base is skipped, not failed" || nok "R9 new manifest passes" "st=$st out=$out"

# --- R10: every manifest is compared, not just the first --------------------------
# The loop bug that a single-manifest fixture cannot see: base carries a HIGHER version
# in the third file only, while the head side is internally consistent. A check that
# compares package.json and stops reports a clean pass on a backward marketplace bump,
# which is the exact file the hazard was about.
R="$TMP/thirdonly"
git init -q "$R"; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t; git -C "$R" config commit.gpgsign false
setv "$R" 0.9.0 0.9.0 0.9.9
( cd "$R" && git add -A && git commit -qm base && git branch -M master && git checkout -qb feature ) >/dev/null 2>&1
setv "$R" 0.9.1 0.9.1 0.9.1; commit_head "$R"
run "$R"
[ "$st" -ne 0 ] && ok "R10 a backward move in the THIRD manifest alone is caught" \
  || nok "R10 all manifests compared" "st=$st out=$out"

# --- R11: an unresolvable base is a refusal, never a pass -------------------------
# A shallow CI checkout is the realistic cause, and the dangerous reading of it is a
# green tick. `fetch-depth: 0` in the workflow is what prevents it; this asserts what
# happens when that is forgotten.
R="$(mkfixture noref 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.9.1 0.9.1 0.9.1; commit_head "$R"
run "$R" "origin/does-not-exist"
[ "$st" -ne 0 ] && case "$out" in *'does not resolve'*) true ;; *) false ;; esac \
  && ok "R11 unresolvable base ref -> FAIL, not a vacuous pass" || nok "R11 missing base fails" "st=$st out=$out"

# --- R12: comparing NOTHING is not a pass ----------------------------------------
# The base resolves, so R11's guard does not fire, and every manifest is new -- so
# R9's skip fires three times and the loop ends having compared zero versions. Without
# the `compared > 0` floor the script prints "ok" on no evidence at all, which is the
# vacuous-green shape that E2 and R11 exist to prevent elsewhere. Found by mutation
# testing (the floor reddened nothing until this case existed), not by reading.
R="$TMP/nobase"
git init -q "$R"; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t; git -C "$R" config commit.gpgsign false
( cd "$R" && echo readme > README.md && git add -A && git commit -qm base && git branch -M master && git checkout -qb feature ) >/dev/null 2>&1
setv "$R" 0.9.0 0.9.0 0.9.0; commit_head "$R"
run "$R"
[ "$st" -ne 0 ] && case "$out" in *'zero evidence'*) true ;; *) false ;; esac \
  && ok "R12 no manifest on base at all -> FAIL (zero comparisons is not a pass)" \
  || nok "R12 zero-evidence floor" "st=$st out=$out"

# --- R13: no 64-bit ceiling either -----------------------------------------------
# Found by the security review of this very branch, and it falsified the comment that
# sat above the comparator. The first draft compared with `$((10#$x))`, which is bash's
# fixed-width signed 64-bit arithmetic: a component at or above 2^63 wraps, and the
# validating regex accepts a digit run of ANY length, so nothing bounded what got there.
# 18446744073709551617 is 2^64+1, which wrapped to 1 -- so this revert, a drastic
# backward move, printed `ok ... not behind` and exited 0.
#
# Absurd as an input and exactly the point: the check exists to catch bad states, so a
# fail-OPEN on a bad state is the one direction it must never take. R6 pinned the 10^3
# ceiling and passed throughout, because it was written against the comparator that had
# already been chosen -- an assertion cannot find a ceiling nobody suspected.
R="$(mkfixture bigrevert 18446744073709551617.0.0 18446744073709551617.0.0 18446744073709551617.0.0)"
setv "$R" 1.0.0 1.0.0 1.0.0; commit_head "$R"
run "$R"
[ "$st" -ne 0 ] && case "$out" in *BACKWARD*) true ;; *) false ;; esac \
  && ok "R13 a revert from a 2^64-scale version reads BACKWARD (no 64-bit ceiling)" \
  || nok "R13 bignum ceiling" "st=$st out=$out"

R="$(mkfixture bigforward 1.0.0 1.0.0 1.0.0)"
setv "$R" 18446744073709551617.0.0 18446744073709551617.0.0 18446744073709551617.0.0; commit_head "$R"
run "$R"
[ "$st" -eq 0 ] && ok "R13b the same pair in the forward direction still PASSES" \
  || nok "R13b bignum forward" "st=$st out=$out"

# --- R14: a zero-padded component is decimal, not a shorter number -----------------
# `1.08.0` is a legal shape for the validator, and the length-first comparison in
# num_lt would read `08` as two digits beating `9`'s one if the zero were not stripped.
# The old `10#` prefix existed for this; the replacement has to earn it back.
R="$(mkfixture padded 1.08.0 1.08.0 1.08.0)"
setv "$R" 1.9.0 1.9.0 1.9.0; commit_head "$R"
run "$R"
[ "$st" -eq 0 ] && ok "R14 1.08.0 -> 1.9.0 reads FORWARD (leading zero stripped, not length-compared)" \
  || nok "R14 zero padding" "st=$st out=$out"

R="$(mkfixture padded_rev 1.9.0 1.9.0 1.9.0)"
setv "$R" 1.08.0 1.08.0 1.08.0; commit_head "$R"
run "$R"
[ "$st" -ne 0 ] && ok "R14b 1.9.0 -> 1.08.0 reads BACKWARD" || nok "R14b zero padding reverse" "st=$st out=$out"

# --- R15: a version key hidden behind invalid UTF-8 is still counted ---------------
# The bypass round 3 of the security review found, and the reason the script exports
# LC_ALL=C. Under a UTF-8 locale GNU grep will not match `[^"]*` across bytes that are
# not valid UTF-8 and drops the line from `grep -o` output without erroring. A fork PR
# author owns every byte of their manifests, so a clean forward DECOY plus a poisoned
# real key made the poisoned one invisible here while JSON parsers take it (duplicate
# keys are last-wins everywhere). Repro before the fix: base 0.9.0, head decoy 0.9.1 +
# poisoned 0.1.0 -> `ok: version 0.9.1, not behind master`, exit 0.
#
# The assertion reads the MESSAGE, not the exit status: post-fix the poisoned key is
# visible, so this is refused as AMBIGUITY (two version fields), which is the correct
# and honest answer -- the script cannot order a value with junk bytes in it and must
# not try. An exit-status-only assertion would go green on any refusal at all.
R="$(mkfixture utf8_smuggle 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.9.1 0.9.1 0.9.1
printf '{"name":"p","version":"0.9.1","version":"0.1.0\xff\xfe"}\n' > "$R/.claude-plugin/plugin.json"
commit_head "$R"
run "$R"
[ "$st" -ne 0 ] && case "$out" in *'exactly 1 version field'*) true ;; *) false ;; esac \
  && ok "R15 a second version key hidden behind invalid UTF-8 is seen, not smuggled past" \
  || nok "R15 utf8-smuggled duplicate key refused" "st=$st out=$out"

# R15b: the same poisoning WITHOUT a decoy must not become a false FAIL on clean input.
# One poisoned key on its own is refused for being unorderable, which is right; the
# pair-partner here is that an ordinary all-ASCII manifest still passes, so R15 cannot
# be satisfied by a script that has simply started refusing everything.
R="$(mkfixture utf8_clean 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.9.1 0.9.1 0.9.1; commit_head "$R"
run "$R"
[ "$st" -eq 0 ] && ok "R15b clean ASCII manifests still PASS under the exported LC_ALL=C" \
  || nok "R15b LC_ALL=C did not break the normal path" "st=$st out=$out"

echo "1..$((PASS+FAIL))"
echo "# pass $PASS / fail $FAIL"
[ "$FAIL" -eq 0 ]
