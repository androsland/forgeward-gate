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

# --- R19..R20: values that do not survive the shell -----------------------------------
#
# Round 5's class. `$(...)` deletes NUL bytes and strips trailing newlines, both legal
# inside a JSON string, so a shape check on the SHELL side validates a value the file
# does not contain. These fixtures must be built by python and never pass through a
# command substitution -- the first attempt to measure this used `V="$(python3 -c ...)"`
# to build the fixture and silently sanitised its own input, reporting the bug absent.
mkpoison() { # mkpoison <name> <python-expr-for-the-head-version>
  # Separate `local` statements DELIBERATELY. In `local a=$1 b=$TMP/$a`, the `$a` on the
  # right resolves to the GLOBAL `a`, not the local just declared -- bash creates every
  # name in the statement before assigning any of them. Verified: with no global it
  # yields empty (and errors under `set -u`), with one it silently yields the global's
  # value. That is a wrong answer, not a crash, which is the worse of the two.
  local name="$1"
  local expr="$2"
  local r="$TMP/$name"
  mkdir -p "$r/.claude-plugin"
  ( cd "$r" && git init -q . \
      && git config user.email t@t && git config user.name t \
      && git config commit.gpgsign false ) >/dev/null 2>&1
  POISON_DIR="$r" POISON_EXPR="$expr" python3 - <<'PY'
import json, os
r = os.environ["POISON_DIR"]
def write(v):
    for p in ["package.json", ".claude-plugin/plugin.json"]:
        open(os.path.join(r, p), "w").write(json.dumps({"name": "p", "version": v}))
    open(os.path.join(r, ".claude-plugin/marketplace.json"), "w").write(
        json.dumps({"plugins": [{"version": v}]}))
write("9.0.0")
PY
  ( cd "$r" && git add -A && git commit -qm base && git branch -M master \
      && git checkout -qb feat ) >/dev/null 2>&1
  POISON_DIR="$r" POISON_EXPR="$expr" python3 - <<'PY'
import json, os
r, expr = os.environ["POISON_DIR"], os.environ["POISON_EXPR"]
v = eval(expr)
for p in ["package.json", ".claude-plugin/plugin.json"]:
    open(os.path.join(r, p), "w").write(json.dumps({"name": "p", "version": v}))
open(os.path.join(r, ".claude-plugin/marketplace.json"), "w").write(
    json.dumps({"plugins": [{"version": v}]}))
PY
  ( cd "$r" && git add -A && git commit -qm head ) >/dev/null 2>&1
  printf '%s' "$r"
}

# R19: a NUL byte inside the version string. Base 9.0.0; the head manifest's version is
# the JSON string "1\u00009.0.0", which no conformant reader calls X.Y.Z. Before the fix
# the shell saw the two halves spliced into `19.0.0`, validated THAT, and reported
# `ok: version 19.0.0` -- a value present in no file anywhere. Asserts on the MESSAGE:
# the exit status alone would not distinguish this from any other refusal.
R="$(mkpoison nulsplice "'1' + chr(0) + '9.0.0'")"
run "$R" master
[ "$st" -ne 0 ] && case "$out" in *'is not X.Y.Z'*) true ;; *) false ;; esac \
  && ok "R19 a NUL inside the version is refused, not spliced into a valid number" \
  || nok "R19 NUL-splice refused" "st=$st out=$out"

# R19b: EXACTLY ONE trailing newline, and the count is the whole point of the assertion.
# `$(...)` strips any number of them, so all counts are equally a transport bug -- but
# only one newline also discriminates `re.fullmatch` from `re.match(r'...$')`, because
# Python's `$` matches at end-of-string OR just before a newline that is the LAST
# character. So `re.match` accepts "19.0.0\n" and rejects "19.0.0\n\n\n".
#
# This assertion was first written with three newlines and a comment claiming it pinned
# `fullmatch`. It did not: a mutation swapping `fullmatch` for `match(...$)` left the
# whole suite green. The comment asserted a property the fixture could not observe,
# which is the same failure R8 had against `grep -c` -- an assertion written next to a
# mechanism, inheriting its author's assumption about which case is hard.
R="$(mkpoison nlsplice "'19.0.0' + chr(10)")"
run "$R" master
[ "$st" -ne 0 ] && case "$out" in *'is not X.Y.Z'*) true ;; *) false ;; esac \
  && ok "R19b one trailing newline is refused (this is what pins fullmatch over \$)" \
  || nok "R19b single-trailing-newline splice refused" "st=$st out=$out"

# R19b2: several trailing newlines. Kept alongside R19b rather than replaced by it: the
# two fail for different reasons under a `match(...$)` regression, and a fixture that
# only covers the harder case cannot show that the easier one still works.
R="$(mkpoison nlsplice3 "'19.0.0' + chr(10) * 3")"
run "$R" master
[ "$st" -ne 0 ] && case "$out" in *'is not X.Y.Z'*) true ;; *) false ;; esac \
  && ok "R19b2 several trailing newlines are refused too" \
  || nok "R19b2 multi-newline splice refused" "st=$st out=$out"

# R19e: the refusal must name the value that is actually in the FILE. The reason string
# crosses the same command substitution the version does, so an unescaped value gets the
# same NUL deletion applied to it -- the run would refuse correctly while reporting
# `version 19.0.0`, a string appearing in no file, as the thing it refused. Round 2
# established that a guard citing the wrong reason is a guard the next person debugs
# past; this is that rule applied to the round-5 fix's own error path.
R="$(mkpoison nulmsg "'1' + chr(0) + '9.0.0'")"
run "$R" master
[ "$st" -ne 0 ] && case "$out" in *'u00009.0.0'*) true ;; *) false ;; esac \
  && ok "R19e the refusal names the escaped value, not the shell-mangled one" \
  || nok "R19e message escapes control bytes" "st=$st out=$out"

# R19c: the control. A trailing SPACE is not touched by command substitution, so this
# shape was already refused before the fix -- it is here so a regression that loosens
# the shape check cannot hide behind R19/R19b, which test the transport, not the shape.
R="$(mkpoison spacetail "'19.0.0 '")"
run "$R" master
[ "$st" -ne 0 ] && case "$out" in *'is not X.Y.Z'*) true ;; *) false ;; esac \
  && ok "R19c control: a trailing space is refused too" \
  || nok "R19c trailing space refused" "st=$st out=$out"

# R19d: the same fixture builder with a CLEAN version must still pass, or R19/R19b prove
# only that mkpoison produces something unreadable.
R="$(mkpoison cleanbump "'19.0.0'")"
run "$R" master
[ "$st" -eq 0 ] && case "$out" in *'version 19.0.0'*) true ;; *) false ;; esac \
  && ok "R19d the same builder with a clean version still passes" \
  || nok "R19d clean fixture passes" "st=$st out=$out"

# R20: a manifest nested deeper than python's recursion limit. `RecursionError` is not a
# `ValueError`, so before the fix it escaped the parse guard, python died with a bare
# traceback and empty stdout, and the run refused via the generic "no usable answer" arm.
# It failed CLOSED, which is why this is a message assertion and not a security one: the
# behaviour was already safe and only the reported reason was wrong.
R="$(mkfixture deepnest 0.9.0 0.9.0 0.9.0)"
setv "$R" 0.9.1 0.9.1 0.9.1
python3 -c "
import sys
sys.stdout.write('{\"a\":' * 3000 + '{\"version\":\"0.9.1\"}' + '}' * 3000)" \
  > "$R/.claude-plugin/plugin.json"
commit_head "$R"
run "$R" master
[ "$st" -ne 0 ] && case "$out" in *'nested too deeply'*) true ;; *) false ;; esac \
  && ok "R20 a too-deeply-nested manifest is refused by name, not by traceback" \
  || nok "R20 deep nesting named" "st=$st out=$out"

# --- R22: the repo under test must not be able to configure the interpreter judging it -
# Round 6 of the security review, and it is the one that got closest to shipping. The
# check runs from the root of the checkout it is judging, and `python3 -c` puts the CWD
# on `sys.path` -- so `import json` was resolved against REPO CONTENT. A fork PR author
# commits a five-line `json.py` next to a genuine backward bump and `json.loads` returns
# whatever they want. Verified before the fix: base 9.0.0, head manifests genuinely
# 1.0.0, output `ok: version 999.999.999, not behind master`, exit 0.
#
# Three channels are asserted because `-I` closes three and a `sys.path` edit would have
# closed one. The shape of the previous four rounds was: patch the instance, get defeated
# by a sibling mechanism next round. A test per channel is what makes "the flag is still
# there" observable rather than assumed.
#
# Each case asserts the BACKWARD message, not just a non-zero exit. A shadowed module can
# also make python crash, which fails closed for an unrelated reason and would satisfy an
# exit-status assertion while the version was never actually compared.
mkshadow() { # mkshadow <name> <filename> <python-source>
  local name="$1"
  local fname="$2"
  local src="$3"
  local r
  r="$(mkfixture "$name" 9.0.0 9.0.0 9.0.0)"
  setv "$r" 1.0.0 1.0.0 1.0.0          # a genuine, drastic BACKWARD move
  printf '%s\n' "$src" > "$r/$fname"
  commit_head "$r"
  printf '%s' "$r"
}

SHADOW_JSON='def loads(*a, **k): return {"version": "999.999.999"}
def dumps(o, *a, **k): return chr(34) + str(o) + chr(34)'
SHADOW_RE='def fullmatch(*a, **k): return True
def match(*a, **k): return True'

R="$(mkshadow shadow-json json.py "$SHADOW_JSON")"
run "$R"
case "$out" in
  *'would go BACKWARD'*) ok "R22 a repo-root json.py cannot forge the version (module shadowing)" ;;
  *) nok "R22 json.py shadow refused" "st=$st out=$out" ;;
esac

R="$(mkshadow shadow-re re.py "$SHADOW_RE")"
run "$R"
case "$out" in
  *'would go BACKWARD'*) ok "R22b a repo-root re.py cannot disable the shape check" ;;
  *) nok "R22b re.py shadow refused" "st=$st out=$out" ;;
esac

# PYTHONPATH is the same class arriving by a different door, and it is the channel a
# `sys.path[0]` fix would leave wide open. The module lives OUTSIDE the fixture so this
# cannot pass for the R22 reason.
R="$(mkfixture shadow-env 9.0.0 9.0.0 9.0.0)"
setv "$R" 1.0.0 1.0.0 1.0.0
commit_head "$R"
mkdir -p "$TMP/ppath" && printf '%s\n' "$SHADOW_JSON" > "$TMP/ppath/json.py"
out="$( cd "$R" && PYTHONPATH="$TMP/ppath" bash "$CHK" master 2>&1 )"; st=$?
case "$out" in
  *'would go BACKWARD'*) ok "R22c PYTHONPATH cannot inject a json module (-I implies -E)" ;;
  *) nok "R22c PYTHONPATH shadow refused" "st=$st out=$out" ;;
esac

# Positive control, and it is not optional. Every assertion above is satisfied by a check
# that has simply stopped working -- a python that cannot start refuses everything. This
# one proves the shadow FIXTURE is the thing being neutralized and not the interpreter:
# same builder, same planted json.py, a genuinely FORWARD version, must still pass.
R="$(mkfixture shadow-ok 9.0.0 9.0.0 9.0.0)"
setv "$R" 9.1.0 9.1.0 9.1.0
printf '%s\n' "$SHADOW_JSON" > "$R/json.py"
commit_head "$R"
run "$R"
case "$out" in
  ok:*9.1.0*) ok "R22d a forward bump still passes with json.py present (positive control)" ;;
  *) nok "R22d shadow positive control" "st=$st out=$out" ;;
esac

# --- R23: a manifest committed as a SYMLINK must be refused, not followed ----------
# Round 7 of the security review. `read_version "$f" < "$f"` was a plain open(2), which
# follows symlinks, while git tracks symlinks natively as mode 120000 -- so a fork PR
# author could commit `package.json` as a link to any absolute path on the CI runner and
# have the check parse a file that is not in the commit. R23 is the forged-PASS case and
# it is the one that matters: with all three manifests linked to an out-of-repo file, the
# pre-fix script printed `ok: version 13.37.0 ... all three agree` and exited 0 for a
# commit containing no version field at all.
#
# These assert the MESSAGE, not just the exit status -- for the standing reason (every
# assertion from round 3 on does) and for a sharper one here: a symlink's target text
# fails the JSON parse anyway, so the pre-fix script would ALSO have exited non-zero on
# the in-repo variant, for the wrong reason and blaming the wrong layer. An exit-status
# assertion could not tell the fix from the accident.
mklink() { # mklink <name> <target> <manifests...>   -> repo path, head committed
  local name="$1" target="$2"
  shift 2
  local r m
  r="$(mkfixture "$name" 9.0.0 9.0.0 9.0.0)"
  for m in "$@"; do
    rm -f "$r/$m"
    ln -s "$target" "$r/$m"
  done
  commit_head "$r"
  printf '%s' "$r"
}

OUTSIDE="$TMP/outside-the-repo.json"
printf '{"version":"13.37.0"}\n' > "$OUTSIDE"

R="$(mklink link-all "$OUTSIDE" package.json .claude-plugin/plugin.json .claude-plugin/marketplace.json)"
run "$R"
case "$out" in
  *'package.json is a symlink'*) ok "R23 three manifests linked outside the repo are refused (was a forged PASS)" ;;
  *) nok "R23 out-of-repo symlink refused" "st=$st out=$out" ;;
esac

R="$(mklink link-one "$OUTSIDE" .claude-plugin/plugin.json)"
run "$R"
case "$out" in
  *'plugin.json is a symlink'*) ok "R23b a single linked manifest is named, not silently skipped" ;;
  *) nok "R23b single symlink named" "st=$st out=$out" ;;
esac

# In-repo target: proves the refusal is about the ENTRY KIND, not about where the target
# happens to point. A fix that only rejected absolute or escaping targets would pass R23
# and fail here, and it would be the wrong fix -- the property wanted is "the bytes we
# parse are the blob in the commit", which an in-repo link breaks just as thoroughly.
R="$(mkfixture link-inside 9.0.0 9.0.0 9.0.0)"
printf '{"version":"13.37.0"}\n' > "$R/decoy.json"
rm -f "$R/package.json"; ln -s decoy.json "$R/package.json"
commit_head "$R"
run "$R"
case "$out" in
  *'package.json is a symlink'*) ok "R23c an IN-repo symlink is refused too (it is the entry kind, not the target)" ;;
  *) nok "R23c in-repo symlink refused" "st=$st out=$out" ;;
esac

# Base side. Never exposed -- `git show` returns a symlink's target text rather than
# following it -- so this pins the SYMMETRY: both sides run the same kind check, and the
# refusal names the tree entry instead of arriving as a parser error one step later.
R="$(mkfixture link-base 9.0.0 9.0.0 9.0.0)"
( cd "$R" && git checkout -q master && rm -f package.json && ln -s "$OUTSIDE" package.json \
   && git add -A && git commit -qm relink && git checkout -q feature ) >/dev/null 2>&1
setv "$R" 9.1.0 9.1.0 9.1.0
commit_head "$R"
run "$R"
case "$out" in
  *'master:package.json is a symlink'*) ok "R23d a symlink on the BASE side is refused by name (symmetry)" ;;
  *) nok "R23d base-side symlink named" "st=$st out=$out" ;;
esac

# Positive control. Same builder, no link: an ordinary forward bump must still pass, or
# every assertion above is satisfied by a script that refuses everything.
R="$(mkfixture link-control 9.0.0 9.0.0 9.0.0)"
setv "$R" 9.1.0 9.1.0 9.1.0
commit_head "$R"
run "$R"
case "$out" in
  ok:*9.1.0*) ok "R23e a forward bump with no symlink still passes (positive control)" ;;
  *) nok "R23e symlink positive control" "st=$st out=$out" ;;
esac

# --- R24: reading HEAD, and saying so when the worktree disagrees ------------------
# Reading the committed tree is what closes R23, and it costs something real: a hand-run
# no longer sees uncommitted edits. R24 pins the behaviour (the verdict is about HEAD)
# and R24b pins the mitigation (the ignored files are NAMED). Without R24b the check
# would answer about a file other than the one on the author's screen and say nothing,
# which is a debugging trap rather than a security hole -- and untested mitigations are
# how the previous six rounds' comments ended up describing behaviour the code lacked.
R="$(mkfixture dirty-head 9.0.0 9.0.0 9.0.0)"
setv "$R" 9.1.0 9.1.0 9.1.0
commit_head "$R"
setv "$R" 1.0.0 1.0.0 1.0.0        # a backward move left UNCOMMITTED
run "$R"
# NOT `ok:*` -- `run` folds stderr into $out and the dirty note is printed first, so the
# anchored form every other assertion here uses would fail on the note rather than on the
# verdict. Matching the whole summary line keeps it just as specific.
case "$out" in
  *'ok: version 9.1.0, not behind'*) ok "R24 an uncommitted backward edit does not change the verdict (HEAD is what merges)" ;;
  *) nok "R24 verdict follows HEAD" "st=$st out=$out" ;;
esac
case "$out" in
  *'uncommitted edits to'*'package.json'*) ok "R24b the ignored worktree edits are named in a note" ;;
  *) nok "R24b dirty note names the files" "st=$st out=$out" ;;
esac

# Runs from a SUBDIRECTORY. The worktree read this replaces was cwd-relative and would
# have died "missing from the working tree"; `--full-tree` and the `:/` pathspec make the
# whole check root-relative. Cheap to assert, and it is the kind of property that gets
# quietly broken by someone "simplifying" the mode lookup later.
R="$(mkfixture subdir-cwd 9.0.0 9.0.0 9.0.0)"
setv "$R" 9.1.0 9.1.0 9.1.0
commit_head "$R"
mkdir -p "$R/.claude-plugin"
out="$( cd "$R/.claude-plugin" && bash "$CHK" master 2>&1 )"; st=$?
case "$out" in
  ok:*9.1.0*) ok "R24c the check works from a subdirectory (paths resolve against the repo root)" ;;
  *) nok "R24c subdirectory cwd" "st=$st out=$out" ;;
esac

# R21: EVERY tracked file in this repo must be plain text -- NUL-free and valid UTF-8.
# Not a behaviour of the check; a property of the repo, and it is here because it went
# wrong repeatedly while rounds 5 and 6 were being written -- in this script's subject
# (`ci/check-version-monotonic.sh`), in this suite, in `DECISIONS.md`, in `TODOS.md`, in a
# heredoc for a commit message, and in a PR-body draft. No count is given because the
# honest answer is "more times than were counted at the time". Documenting a NUL
# byte is one keystroke away from EMBEDDING one, and a single NUL makes GNU grep answer
# `binary file matches` instead of the matching lines and makes git treat the file as
# binary in a diff. Worse on this machine: the interactive `grep` shims to ugrep, which
# returns NOTHING at all -- indistinguishable from "no matches", which is how a grep of
# this very suite came back empty and produced a wrong conclusion about its own contents.
#
# It is repo-wide rather than a list of paths because the first version WAS a list of
# paths -- the two code files this round touched -- and the next NUL landed in
# DECISIONS.md, in the paragraph explaining the hazard, while that version sat green.
# Widening it to five named files did not help either: the one after that went into
# TODOS.md, in a sentence saying to never write the byte literally. Enumerating the files
# that have been bitten is not a strategy when the trigger is "someone is writing ABOUT
# control bytes" and any file can be that file. The repo is 41 tracked files with no
# legitimately-binary member, so the whole-repo form costs nothing and has no exceptions
# to maintain; a repo that later adds an image needs an allowlist here, and that is the
# one edit this assertion should ever need.
#
# The byte is named by escape inside python and never written literally here, so this
# assertion cannot reintroduce the thing it forbids.
#
# Two assertions, not one. A sweep that enumerates nothing passes vacuously, and "checked
# 0 files, found 0 problems" is the exact green-for-no-reason shape this whole branch is
# about -- so the enumeration is asserted separately, with a floor and a named-member
# check, before its result is trusted.
R21_LIST="$(git -C "$PLUGIN" ls-files -z 2>/dev/null | tr '\0' '\n')"
R21_N="$(printf '%s' "$R21_LIST" | /usr/bin/grep -c . || true)"
case "$R21_LIST" in
  *"ci/check-version-monotonic.sh"*) R21_HAS_SELF=y ;;
  *)                                 R21_HAS_SELF=n ;;
esac
if [ "$R21_N" -ge 20 ] && [ "$R21_HAS_SELF" = y ]; then
  ok "R21 enumeration is live ($R21_N tracked files, includes the script under test)"
else
  nok "R21 enumeration is live" "found $R21_N file(s), script-under-test present: $R21_HAS_SELF"
fi

R21_BAD="$(printf '%s\n' "$R21_LIST" | python3 -c "
import sys, os
bad = []
for p in sys.stdin.read().splitlines():
    if not p:
        continue
    try:
        raw = open(os.path.join(sys.argv[1], p), 'rb').read()
    except OSError:
        continue            # deleted-but-tracked; not this assertion's question
    if b'\x00' in raw:
        bad.append(p + ' (NUL)')
        continue
    try:
        raw.decode('utf-8')
    except UnicodeDecodeError:
        bad.append(p + ' (not UTF-8)')
print('; '.join(bad))
" "$PLUGIN")"
[ -z "$R21_BAD" ] \
  && ok "R21 every tracked file is NUL-free, valid UTF-8 text" \
  || nok "R21 every tracked file is plain text" "$R21_BAD"

echo "1..$((PASS+FAIL))"
echo "# pass $PASS / fail $FAIL"
[ "$FAIL" -eq 0 ]
