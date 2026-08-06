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

# --- R15/R16: two smuggling shapes that beat a TEXTUAL reader ----------------------
# Rounds 3 and 4 of the security review, and together the reason the extraction is a
# real JSON parser instead of a grep. Both fixtures are a clean forward DECOY key plus
# a second key carrying a backward version, arranged so the old grep saw only the decoy
# while `JSON.parse`/`json.load` took the second (duplicate keys are last-wins in V8,
# Python and Go alike). Both printed `ok: version 0.9.1, not behind master` and exited 0
# before the fix.
#
# Every assertion here reads the MESSAGE, never just the exit status. All three defects
# on this branch failed closed for some unrelated reason at some point, so an
# exit-status assertion goes green on a script that is broken in a different way.

# R15: the second key is poisoned with invalid UTF-8. GNU grep under a UTF-8 locale
# silently drops a line holding invalid bytes, so the poisoned key was invisible.
# The parser refuses the manifest by name -- and note the reason CHANGED when the reader
# was replaced: a grep-based fix could only report this as ambiguity, whereas the true
# answer is that the file is not UTF-8 at all and no parser should have loaded it.
R="$(mkfixture utf8_smuggle 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.9.1 0.9.1 0.9.1
printf '{"name":"p","version":"0.9.1","version":"0.1.0\xff\xfe"}\n' > "$R/.claude-plugin/plugin.json"
commit_head "$R"
run "$R"
[ "$st" -ne 0 ] && case "$out" in *'not valid UTF-8'*) true ;; *) false ;; esac \
  && ok "R15 a manifest that is not valid UTF-8 is refused by name, not mis-read" \
  || nok "R15 invalid-UTF-8 manifest refused" "st=$st out=$out"

# R16: the second key is spelled `"\u0076ersion"` -- spec-legal JSON that decodes to
# `version` and contains no literal `"version"` bytes for a text matcher to find. This
# is the one that settles the argument for a parser: any of the seven characters can be
# escaped independently, so there is no finite set of spellings to grep for.
R="$(mkfixture escaped_key 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.9.1 0.9.1 0.9.1
printf '{"name":"p","version":"0.9.1","\\u0076ersion":"0.1.0"}\n' > "$R/.claude-plugin/plugin.json"
commit_head "$R"
run "$R"
[ "$st" -ne 0 ] && case "$out" in *'duplicate key'*) true ;; *) false ;; esac \
  && ok "R16 a \\uXXXX-escaped duplicate version key is resolved and refused" \
  || nok "R16 escaped duplicate key refused" "st=$st out=$out"

# R16b: an escape that is NOT an attack must still pass. Without this, R16 is satisfied
# by a reader that has simply started rejecting every backslash it sees -- and the whole
# point of using a parser is that it resolves escapes correctly rather than fearing them.
R="$(mkfixture escaped_ok 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.9.1 0.9.1 0.9.1
printf '{"n\\u0061me":"caf\\u00e9","version":"0.9.1"}\n' > "$R/.claude-plugin/plugin.json"
commit_head "$R"
run "$R"
[ "$st" -eq 0 ] && ok "R16b harmless \\uXXXX escapes elsewhere in a manifest still PASS" \
  || nok "R16b benign escapes pass" "st=$st out=$out"

# R17: malformed JSON is refused by name rather than partially read. The old textual
# reader would happily extract a version from a file no parser could load.
R="$(mkfixture malformed 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.9.1 0.9.1 0.9.1
printf '{"name":"p","version":"0.9.1",}\n' > "$R/.claude-plugin/plugin.json"
commit_head "$R"
run "$R"
[ "$st" -ne 0 ] && case "$out" in *'not valid JSON'*) true ;; *) false ;; esac \
  && ok "R17 a manifest that is not valid JSON is refused by name" \
  || nok "R17 malformed JSON refused" "st=$st out=$out"

# --- R18: the reader being unavailable is a FAIL, never a skip ---------------------
# Moving the extraction to python3 bought correctness and bought a dependency with it.
# The failure that matters is not "python3 is missing" -- it is a check that goes green
# because it could not run, which is the vacuous-pass class this file already refuses in
# R12. Both arms below are refusals, and both are asserted on the MESSAGE, because "exit
# non-zero" is what a script does when it is merely broken.
BASHBIN="$(command -v bash)"

# R18: python3 absent from PATH entirely. The shim dir carries only git, which is the
# script's one other external command.
SHIM="$TMP/nopy-bin"; mkdir -p "$SHIM"; ln -sf "$(command -v git)" "$SHIM/git"
R="$(mkfixture nopython 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.9.1 0.9.1 0.9.1; commit_head "$R"
out="$( cd "$R" && PATH="$SHIM" "$BASHBIN" "$CHK" master 2>&1 )"; st=$?
[ "$st" -ne 0 ] && case "$out" in *'python3 is required'*) true ;; *) false ;; esac \
  && ok "R18 python3 absent -> named FAIL, not a skip and not a pass" \
  || nok "R18 missing python3 refused by name" "st=$st out=$out"

# R18b: python3 present but answering with something that is neither `ok:` nor `err:`
# -- a wrapper, a broken build, a truncated write. The reader's contract is that only a
# recognised answer is an answer; anything else is a refusal rather than a default.
# Without this the `*)` arm is unreachable in tests and could be deleted unnoticed.
SHIM2="$TMP/junkpy-bin"; mkdir -p "$SHIM2"; ln -sf "$(command -v git)" "$SHIM2/git"
printf '#!/bin/sh\ncat >/dev/null\nprintf %%s "totally unexpected output"\n' > "$SHIM2/python3"
chmod +x "$SHIM2/python3"
R="$(mkfixture junkpython 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.9.1 0.9.1 0.9.1; commit_head "$R"
out="$( cd "$R" && PATH="$SHIM2" "$BASHBIN" "$CHK" master 2>&1 )"; st=$?
[ "$st" -ne 0 ] && case "$out" in *'no usable answer'*) true ;; *) false ;; esac \
  && ok "R18b an unrecognised reader answer is a refusal, not a default" \
  || nok "R18b junk reader output refused" "st=$st out=$out"

echo "1..$((PASS+FAIL))"
echo "# pass $PASS / fail $FAIL"
[ "$FAIL" -eq 0 ]
