#!/usr/bin/env bash
# Regression suite for ci/check-merged-prs-landed.sh.
#
# Framework-free, same as gate-test.sh, pre-push-test.sh and version-check-test.sh:
# bash and git only, the real script under test, no copies except where a mutation is
# the assertion. Runs standalone and via `npm test`.
#
# WHAT KIND OF CONTROLS THESE ARE, said once here because it is not visible from a green
# line. The script is NEW, so `git show HEAD:ci/check-merged-prs-landed.sh` has nothing
# to redden against and **no assertion in this file is a pre-fix control** -- not one of
# them proves a bug existed, because none did. They are WRONG-FIX controls: each pins a
# plausible implementation that is shorter than the shipped one and would pass a naive
# reading of the requirement. Where an assertion is green against a wrong fix as well as
# the right one it says so in its own comment and is worth exactly what that is worth.
# M4 and M7 are the two that carry real information, and both work by mutation. M5 is a
# plain content assertion with no mutation control and was named here by mistake for two
# revisions; the maintainability reviewer on this branch is what caught it.
#
# THE FIXTURE IS A REPO WITH A DELIBERATE ORPHAN IN IT. Building the history by hand is
# the point: the condition under test is created by merge ORDER, and no amount of
# inspecting a healthy repo produces it. The shape is
#
#   master:  A --- MS(merge side) --- MR4(merge redo) --- MRL(merge reland)
#   side:      \-- S --- MT(merge stacked) --- MR3(merge redo) --- ML(merge lost)
#
# `side` merged into master at MS and then kept receiving merges. MT, MR3 and ML are on
# no ref master can reach. That is exactly what happened to #55 and #51 in real life.
set -uo pipefail

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHK="$PLUGIN/ci/check-merged-prs-landed.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok %d - %s\n' "$((PASS+FAIL))" "$1"; }
nok()  { FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$((PASS+FAIL))" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forgeward-orphan-test.XXXXXX")"
# Under `set -uo pipefail` without `-e` a failed mktemp yields an empty TMP, and every
# "$TMP/x" below becomes the ABSOLUTE path "/x". That fails with EACCES unprivileged and
# succeeds silently in a root-run CI container, which is the environment nobody watches.
[ -n "$TMP" ] && [ -d "$TMP" ] || { printf 'not ok 1 - mktemp -d failed; refusing to write to /\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

R="$TMP/repo"
g() { git -C "$R" "$@"; }
cm() { printf '%s\n' "$2" > "$R/$1"; g add -A; g commit -qm "$3"; g rev-parse HEAD; }

git init -q "$R"
g config user.email t@t.t
g config user.name t
g config commit.gpgsign false
g symbolic-ref HEAD refs/heads/master

cm a.txt a A >/dev/null    # the root commit; nothing below needs its sha
g checkout -qb side
S="$(cm s.txt s S)"
g checkout -q master
g merge -q --no-ff side -m "Merge #1"   ; MS="$(g rev-parse HEAD)"

# #2: stacked on `side` AFTER side had merged. Its merge commit lives on side alone.
g checkout -qb stacked side
T="$(cm t.txt t T)"
g checkout -q side
g merge -q --no-ff stacked -m "Merge #2"; MT="$(g rev-parse HEAD)"

# #3: same orphaned merge, but the head commit is later merged to master unchanged --
# the #51/#52 shape, a re-land that PRESERVED the commit.
g checkout -qb redo master
Rc="$(cm r.txt r R)"
g checkout -q side
g merge -q --no-ff redo -m "Merge #3"   ; MR3="$(g rev-parse HEAD)"
g checkout -q master
g merge -q --no-ff redo -m "Merge #4"   ; MR4="$(g rev-parse HEAD)"

# #5: orphaned in both commits -- the #55 shape. Re-landed BY HAND as #6, whose bytes
# differ, which is why neither of #5's commits can ever become an ancestor.
g checkout -qb lost master
L="$(cm l.txt l L)"
g checkout -q side
g merge -q --no-ff lost -m "Merge #5"   ; ML="$(g rev-parse HEAD)"
g checkout -qb reland master
RL="$(cm l.txt 'l, retyped' RL)"
g checkout -q master
g merge -q --no-ff reland -m "Merge #6" ; MRL="$(g rev-parse HEAD)"
g checkout -q master

# The population the script filters to is "base is not the default branch", so #1, #4 and
# #6 are here precisely to be filtered OUT. A fixture holding only at-risk PRs could not
# tell a working filter from no filter at all.
J="$TMP/prs.json"
cat > "$J" <<JSON
[
 {"number":1,"baseRefName":"master","mergeCommit":{"oid":"$MS"},"headRefOid":"$S","title":"side"},
 {"number":2,"baseRefName":"side","mergeCommit":{"oid":"$MT"},"headRefOid":"$T","title":"stacked"},
 {"number":3,"baseRefName":"side","mergeCommit":{"oid":"$MR3"},"headRefOid":"$Rc","title":"redo"},
 {"number":4,"baseRefName":"master","mergeCommit":{"oid":"$MR4"},"headRefOid":"$Rc","title":"redo to master"},
 {"number":5,"baseRefName":"side","mergeCommit":{"oid":"$ML"},"headRefOid":"$L","title":"lost"},
 {"number":6,"baseRefName":"master","mergeCommit":{"oid":"$MRL"},"headRefOid":"$RL","title":"reland"}
]
JSON

ACK_EMPTY="$TMP/ack-empty.txt"; : > "$ACK_EMPTY"
ACK_GOOD="$TMP/ack-good.txt"
# Acknowledges BOTH orphans, so a validated-acknowledgment run can actually be clean.
# #2 is credited to #4 and #5 to #6; both of those landed, which is the whole point --
# an entry only counts when the tree agrees with it.
printf '# comment\n\n2 4\n5 6\n' > "$ACK_GOOD"
ACK_STALE="$TMP/ack-stale.txt"
printf '5 2\n' > "$ACK_STALE"    # #2 is itself orphaned, so this claim is false
# Every line here NAMES #5 and none of them is well-formed. That is what gives M6 teeth:
# a parser that shrugged at the arity would read "5 6 7" as the pair (5, 6), #6 landed,
# and #5 would be suppressed by a line that says nothing coherent.
ACK_MALFORMED="$TMP/ack-malformed.txt"
# `5\t6` is deliberately NOT here: `read -r _a _b _c` splits on the default IFS, so a
# tab-separated pair is well-formed and DOES suppress. Discovered by this fixture failing
# against the `set -- $_line` the reader used before shellcheck sent it to `read`, and the
# fact survived the rewrite because both split on IFS. Recorded rather than papered over:
# "whitespace-separated" is the real contract, and "space-separated" was only what the
# format line happened to say.
printf '5\n5 6 7\n#5 6\n' > "$ACK_MALFORMED"

run() { out="$( cd "$R" && bash "$CHK" --pr-json "$J" --ack "$1" master 2>&1 )"; st=$?; }

# --- M1: the genuine orphan is found ---------------------------------------------
# WRONG-FIX CONTROL, and a weak one on its own: a script that reported every PR would
# also pass it. M4 is what stops that reading.
run "$ACK_EMPTY"
case "$st$out" in
  1*"#2 (base 'side'"*"reachable from master by neither"*) ok "M1 an orphaned merge commit is a failure naming the PR" ;;
  *) nok "M1 orphaned merge commit reported" "st=$st out=$out" ;;
esac

# --- M2: the head-commit fallback suppresses the #51 shape, and PRINTS it ----------
# The suppression and the printing are ONE assertion on purpose. A fallback that made the
# finding silent would satisfy "does not fail" while losing the thing this must never
# lose, so an absence check would pass the version that is wrong.
run "$ACK_EMPTY"
case "$out" in
  *"note: #3"*"head commit"*"IS"*) ok "M2 head commit on master downgrades to a printed note" ;;
  *) nok "M2 head commit on master downgrades to a printed note" "out=$out" ;;
esac

# --- M3: an acknowledgment is VALIDATED, not believed ------------------------------
# The plausible wrong fix is a plain suppression list, shorter than the shipped code by
# the whole merge_oid_of/landed pair. ACK_STALE names #2, which is itself orphaned, so a
# list-shaped implementation goes green here and the shipped one does not. Confirmed by
# mutation: forcing the validation branch true reddens exactly this line.
run "$ACK_STALE"
case "$st$out" in
  1*"claims #2 re-landed it, but #2 has NOT landed"*) ok "M3 an acknowledgment naming unlanded work does not suppress" ;;
  *) nok "M3 an acknowledgment naming unlanded work does not suppress" "st=$st out=$out" ;;
esac

# --- M4: a validated acknowledgment clears the run, and THE COUNT IS THE FILTER -----
# Two things, and the second is the one that carries information. "3 with a non-default
# base" is derived from the fixture, which holds six PRs of which three are at risk, so
# this is the floor: without it "no findings" is satisfied by a script that examined no
# PRs at all. It is ALSO the only assertion here that detects a dropped baseRefName
# filter -- measured by mutation, deleting the filter leaves every other line in this
# file green, because #1, #4 and #6 all landed and so pass silently when examined. An
# earlier draft asserted the absence of "#1"/"#4"/"#6" from the output for that job and
# was vacuous for exactly that reason; it was deleted rather than repaired.
run "$ACK_GOOD"
case "$st$out" in
  0*"ok: 6 merged PR(s) examined, 3 with a non-default base"*) ok "M4 validated acknowledgment clears the run; 3 of 6 examined pins the base filter" ;;
  *) nok "M4 validated acknowledgment clears the run; 3 of 6 examined pins the base filter" "st=$st out=$out" ;;
esac
case "$out" in
  *"note: #2"*"verified: #4's merge commit"*"note: #5"*"verified: #6's merge commit"*) ok "M5 a cleared run still prints BOTH acknowledged findings as notes" ;;
  *) nok "M5 a cleared run still prints BOTH acknowledged findings as notes" "out=$out" ;;
esac
# --- M6: a malformed acknowledgment line suppresses nothing ------------------------
# An earlier draft asserted that garbage from the file never appears in the OUTPUT, and
# mutation showed it could not fail: a malformed line yields a key no PR number matches,
# so the run is byte-identical whether the guards are there or not. It was rewritten
# rather than kept -- an assertion that cannot redden is not a weak assertion, it is a
# green line that means nothing. This form makes every malformed line name a PR that is
# genuinely orphaned, so a lax parser turns a FAILURE into a note and this reddens.
run "$ACK_MALFORMED"
case "$st$out" in
  1*"#5 (base 'side'"*"neither its merge commit nor its head commit"*) ok "M6 a malformed acknowledgment line suppresses nothing" ;;
  *) nok "M6 a malformed acknowledgment line suppresses nothing" "st=$st out=$out" ;;
esac

# --- M7: the primary test is mergeCommit.oid, and headRefOid is NOT a substitute ----
# THE ONE THAT CARRIES THE MOST INFORMATION, and the only way to get it is mutation --
# the shipped script cannot demonstrate what the rejected design would have done. A copy
# is made with the two tests swapped (head primary, merge as fallback), which is the
# obvious implementation and the one measured at 45 findings on 60 real PRs.
#
# The signal is not "the mutant fails" -- both variants exit 1 here, for different
# reasons, and an exit-status check would call that agreement. It is that the mutant goes
# SILENT about #3: head-primary short-circuits before any note is written, so a genuinely
# orphaned merge commit is never mentioned at all. Silence about a real orphan is
# precisely the loss the ordering exists to prevent.
MUT="$TMP/mutant.sh"
# shellcheck disable=SC2016  # `$mergeoid`/`$headoid` are the literal text being rewritten
#                              inside the script under test; expanding them here would
#                              match nothing and the mutation would silently not apply --
#                              which is why the cmp guard below exists as well.
sed -e 's/^  landed "$mergeoid" \&\& continue$/  landed "$headoid" \&\& continue/' \
    -e 's/^  if landed "$headoid"; then$/  if landed "$mergeoid"; then/' "$CHK" > "$MUT"
if ! cmp -s "$CHK" "$MUT"; then
  mout="$( cd "$R" && bash "$MUT" --pr-json "$J" --ack "$ACK_EMPTY" master 2>&1 )"
  case "$mout" in
    *"#3"*) nok "M7 keying on headRefOid loses the orphaned merge commit" "mutant still mentioned #3: $mout" ;;
    *)      ok "M7 keying on headRefOid silently loses #3's orphaned merge commit; mergeCommit.oid must stay primary" ;;
  esac
else
  nok "M7 mutation applied" "sed matched nothing -- the primary/fallback lines were renamed"
fi

# --- M8-M10: the input is refused rather than answered from nothing ----------------
# All three shapes LOOK like success from the outside: an empty array produces no
# findings, a truncated one produces no findings about the PRs it never saw, and a
# missing file produces no findings at all. A check whose "everything is fine" and "I
# could not see anything" are the same output is not a check.
printf '[]\n' > "$TMP/empty.json"
eout="$( cd "$R" && bash "$CHK" --pr-json "$TMP/empty.json" --ack "$ACK_EMPTY" master 2>&1 )"; est=$?
case "$est$eout" in
  1*"examined nothing has no pass to report"*) ok "M8 an empty pull-request list fails closed" ;;
  *) nok "M8 an empty pull-request list fails closed" "st=$est out=$eout" ;;
esac

# 200 entries is not a round number chosen for the fixture -- it is `PR_LIMIT`, and the
# guard fires on equality because `gh pr list --limit N` returning exactly N is
# indistinguishable from "there were more". A repo that genuinely has exactly 200 merged
# PRs is refused too; that false refusal is deliberate and is the cheap side of the
# trade, since the alternative is a silent partial answer.
python3 -I -c '
import json, sys
mc, head = sys.argv[1], sys.argv[2]
print(json.dumps([{"number": i, "baseRefName": "master",
                   "mergeCommit": {"oid": mc}, "headRefOid": head,
                   "title": "filler"} for i in range(1, 201)]))
' "$MS" "$S" > "$TMP/full.json"
tout="$( cd "$R" && bash "$CHK" --pr-json "$TMP/full.json" --ack "$ACK_EMPTY" master 2>&1 )"; tst=$?
case "$tst$tout" in
  1*"probably truncated"*) ok "M9 a list at the --limit is refused as probably truncated" ;;
  *) nok "M9 a list at the --limit is refused as probably truncated" "st=$tst out=$tout" ;;
esac

# NOT a control on the `isinstance` guard, and saying so is the point: measured by
# mutation, removing that guard still fails here, because iterating a dict yields its
# keys and `"not".get(...)` raises AttributeError -- same exit, same message. What this
# pins is the script's BEHAVIOUR on JSON that parses but is not a pull-request list. The
# guard buys a better diagnostic on stderr and nothing in this file notices if it goes.
printf '{"not":"a list"}\n' > "$TMP/bad.json"
bout="$( cd "$R" && bash "$CHK" --pr-json "$TMP/bad.json" --ack "$ACK_EMPTY" master 2>&1 )"; bst=$?
case "$bst$bout" in
  1*"could not read the pull-request list"*) ok "M10 JSON that is not a list of pull requests fails closed" ;;
  *) nok "M10 JSON that is not a list of pull requests fails closed" "st=$bst out=$bout" ;;
esac

nout="$( cd "$R" && bash "$CHK" --pr-json "$TMP/nope.json" --ack "$ACK_EMPTY" master 2>&1 )"; nst=$?
case "$nst$nout" in
  1*"does not exist"*) ok "M11 a missing --pr-json file fails closed" ;;
  *) nok "M11 a missing --pr-json file fails closed" "st=$nst out=$nout" ;;
esac

# --- M12: an unresolvable ref is named, never treated as "nothing landed" ----------
# Without this the whole population reports as orphaned -- the 45-of-60 noise mode
# arriving by a second route.
xout="$( cd "$R" && bash "$CHK" --pr-json "$J" --ack "$ACK_EMPTY" origin/nosuch 2>&1 )"; xst=$?
case "$xst$xout" in
  1*"does not resolve"*"fetch-depth"*) ok "M12 an unresolvable ref is named and fatal" ;;
  *) nok "M12 an unresolvable ref is named and fatal" "st=$xst out=$xout" ;;
esac

# --- M13: a shallow clone is refused ------------------------------------------------
# WRONG-FIX CONTROL for "just let ancestry answer": in a shallow clone the objects are
# absent, --is-ancestor exits non-zero, and every landed PR reads as orphaned. Asserted
# on the MESSAGE and not the status, because a shallow fixture is missing most of its
# history and several other things fail there too -- an exit-status check would pass for
# a reason that has nothing to do with shallowness.
SH="$TMP/shallow"
if git clone -q --depth 1 "file://$R" "$SH" 2>/dev/null; then
  git -C "$SH" config user.email t@t.t; git -C "$SH" config user.name t
  sout="$( cd "$SH" && bash "$CHK" --pr-json "$J" --ack "$ACK_EMPTY" master 2>&1 )"; sst=$?
  case "$sst$sout" in
    1*"shallow clone"*) ok "M13 a shallow clone is refused rather than answered wrongly" ;;
    *) nok "M13 a shallow clone is refused rather than answered wrongly" "st=$sst out=$sout" ;;
  esac
else
  nok "M13 shallow fixture" "git clone --depth 1 from a file:// url failed"
fi


# --- M14: the shape CI actually runs -------------------------------------------------
# Every assertion above drives the script with BOTH --pr-json and --ack, and the workflow
# passes NEITHER of those two: `.github/workflows/orphaned-merges.yml` runs
# `bash ci/check-merged-prs-landed.sh --default-branch "$DEFAULT_BRANCH" "origin/$DEFAULT_BRANCH"`.
# So the `gh pr list` call, the mktemp temp file, and the default resolution of the ack
# file were the three legs no test had an opinion about -- and the shipped
# `ci/relanded-prs.txt`, the only ack file that ever runs in production, was read by
# nothing.
#
# The invocation below mirrors that line rather than paraphrasing it, INCLUDING
# `--default-branch`, which the workflow always passes. An earlier revision of this comment
# said the workflow ran the ref "and nothing else"; that was true when it was written and
# stopped being true in the same branch, when the review that gated it added the flag. The
# gate's testing reviewer is what caught it. A comment that describes the production
# command is a claim about another file, and nothing re-runs a claim -- so the fix is to
# make the assertion itself carry the shape, not to correct the sentence and leave the
# invocation one flag short of what ships.
#
# What that does NOT buy, so the mirror is not read as coverage: in this fixture the
# derived name and the passed name are both `master`, so the flag changes no outcome here
# and M14 would stay green if it were ignored entirely. M23 is the assertion with an
# opinion about `--default-branch`, and M26 about its missing value. What M14 gains is only
# that the command it runs is the command that ships.
#
# WRONG-FIX CONTROL for the ack path specifically. The plausible wrong implementation is
# `ACK_FILE="ci/relanded-prs.txt"` relative to the CURRENT DIRECTORY, which is correct
# exactly when CI happens to run from the repo root and silently reads nothing otherwise.
# This runs the script from a DIFFERENT directory ($R, the fixture repo) than the one it
# lives in, so a cwd-relative default finds no file, suppresses nothing, and reddens here.
mkdir -p "$TMP/prod/ci" "$TMP/bin"
cat "$CHK" > "$TMP/prod/ci/check-merged-prs-landed.sh"
printf '2 4\n5 6\n' > "$TMP/prod/ci/relanded-prs.txt"
# A stub `gh` that records its own argv and serves the fixture. It is deliberately not a
# strict mock -- the argv assertion below is what pins the flags, so a stub that answered
# any argument list would still fail the run it is meant to pass.
cat > "$TMP/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$TMP/gh-argv"
cat "$J"
STUB
chmod 755 "$TMP/bin/gh"
pout="$( cd "$R" && PATH="$TMP/bin:$PATH" bash "$TMP/prod/ci/check-merged-prs-landed.sh" \
           --default-branch master master 2>&1 )"; pst=$?
pargv="$(cat "$TMP/gh-argv" 2>/dev/null || echo MISSING)"
case "$pst$pout" in
  0*"note: #2"*"note: #5"*"ok: 6 merged PR(s) examined, 3 with a non-default base"*)
    ok "M14 no-flag run reads gh and the ack file beside the script" ;;
  *) nok "M14 no-flag run reads gh and the ack file beside the script" "st=$pst out=$pout" ;;
esac
# Pinned separately from the run above: a `gh pr list` missing `mergeCommit` would return
# nulls, every PR would read as orphaned, and the run would fail for a reason that looks
# like a finding. The four fields are the contract with the API, not an implementation
# detail, so they are asserted as text rather than inferred from the verdict.
case "$pargv" in
  *"pr list"*"--state merged"*"--limit 200"*"--json number,baseRefName,mergeCommit,headRefOid,title"*)
    ok "M14b gh is called with the documented flags and field list" ;;
  *) nok "M14b gh is called with the documented flags and field list" "argv=$pargv" ;;
esac

# --- M15: a failed mktemp is fatal, not an empty path --------------------------------
# WRONG-FIX CONTROL for the bare `PR_JSON="$(mktemp)"`. Without the `|| die`, $PR_JSON is
# the empty string, `gh ... > ""` fails, and the script continues to a `python3` read of a
# file that does not exist -- a confusing failure two guards later instead of a named one
# here. This is the same class CLAUDE.md pins for `mktemp -d` in test harnesses; the
# consequence differs (no absolute-path write here) but the guard is the same shape.
mout="$( cd "$R" && TMPDIR="$TMP/does-not-exist" PATH="$TMP/bin:$PATH" \
         bash "$TMP/prod/ci/check-merged-prs-landed.sh" master 2>&1 )"; mst=$?
case "$mst$mout" in
  1*"mktemp failed"*) ok "M15 a failed mktemp is named and fatal" ;;
  *) nok "M15 a failed mktemp is named and fatal" "st=$mst out=$mout" ;;
esac

# --- M16: the --flag=value forms parse to the same thing as --flag value --------------
# Two parser arms for one option is the shape this repo has been bitten by four times
# (CLAUDE.md, "one reader per shape"). They are here because `--ack=` reads better in the
# workflow, and the cost of that convenience is an assertion that the two agree.
eout="$( cd "$R" && bash "$CHK" --pr-json="$J" --ack="$ACK_GOOD" master 2>&1 )"; est=$?
run "$ACK_GOOD"
if [ "$est" -eq "$st" ] && [ "$eout" = "$out" ]; then
  ok "M16 --flag=value and --flag value produce identical runs"
else
  nok "M16 --flag=value and --flag value produce identical runs" "eq=$est/$est vs sp=$st"
fi

# --- M17: the argument parser refuses what it cannot honour ---------------------------
# An unknown option must not be skipped. The same reasoning as the publish matcher's
# unrecognised-option DENY: a value-taking flag nobody enumerated can change what the run
# examines, and "ignored it" is indistinguishable from "honoured it" in the output.
hout="$(bash "$CHK" --help 2>&1)"; hst=$?
case "$hst$hout" in
  0*"usage:"*"--pr-json"*) ok "M17 --help prints usage and exits 0" ;;
  *) nok "M17 --help prints usage and exits 0" "st=$hst out=$hout" ;;
esac
uout="$(bash "$CHK" --bogus 2>&1)"; ust=$?
case "$ust$uout" in
  1*"unknown option --bogus"*) ok "M17b an unknown option is refused by name" ;;
  *) nok "M17b an unknown option is refused by name" "st=$ust out=$uout" ;;
esac
aout="$(bash "$CHK" --ack 2>&1)"; ast=$?
case "$ast$aout" in
  1*"--ack needs a file argument"*) ok "M17c a value-taking flag with no value is refused" ;;
  *) nok "M17c a value-taking flag with no value is refused" "st=$ast out=$aout" ;;
esac

# --- M18: no python3 is fatal, and says so --------------------------------------------
# CI-only code requires its interpreter and fails CLOSED -- the posture CLAUDE.md fixes
# for this file's class, and the opposite of what the two user-machine hooks do. Asserted
# on the MESSAGE: an empty PATH makes several things fail, and an exit-status check would
# pass for a reason unrelated to the guard.
mkdir -p "$TMP/emptybin"
# The interpreter is named by ABSOLUTE path: an empty PATH means `bash` itself does not
# resolve, and a run that dies at 127 before the script starts would satisfy an
# exit-status check while proving nothing. This is the same trap M13's comment records.
BASH_BIN="$(command -v bash)"
nout="$( cd "$R" && PATH="$TMP/emptybin" "$BASH_BIN" "$CHK" --pr-json "$J" --ack "$ACK_EMPTY" master 2>&1 )"; nst=$?
case "$nst$nout" in
  1*"python3 is required"*) ok "M18 an absent python3 is named and fatal" ;;
  *) nok "M18 an absent python3 is named and fatal" "st=$nst out=$nout" ;;
esac

# --- M19: an acknowledgment naming a PR that is not in the list suppresses nothing -----
# The header claims this is how an entry naming a still-open or invented PR fails to
# suppress. `merge_oid_of` returns the empty string there and the run must still report.
#
# It pins the OUTCOME, and deliberately not the mechanism -- `landed`'s `[ -n "$1" ]` is
# redundant on the git this was measured against: `git merge-base --is-ancestor "" master`
# exits 128 ("Not a valid object name") on git 2.34.1, so deleting the guard leaves this
# assertion green. That was found by mutating it, and it is recorded rather than dressed
# up: an assertion whose comment claims to cover a guard it does not cover is how a
# removed guard reads as tested. The guard stays because git's behaviour on an empty
# revision is not a contract this repo controls; the assertion is honest about which of
# the two it is watching.
ACK_ABSENT="$TMP/ack-absent.txt"
printf '2 99\n' > "$ACK_ABSENT"
run "$ACK_ABSENT"
case "$st$out" in
  1*"#2"*"claims #99 re-landed it, but #99 has NOT landed"*)
    ok "M19 an ack naming a PR absent from the list suppresses nothing" ;;
  *) nok "M19 an ack naming a PR absent from the list suppresses nothing" "st=$st out=$out" ;;
esac

# --- M20: a default-based PR is TESTED, not filtered out -------------------------------
# WRONG-FIX CONTROL for the filter this script used to have, and the one assertion that
# reddens if it comes back. The old loop began `[ "$base" != "$DEFAULT_BRANCH" ] || continue`
# on the reasoning that a PR based on the default branch lands there by construction. That
# is an assumption about history never being rewritten: a force-push drops merge commits,
# and `master` on this repo is verifiably unprotected (`gh api .../branches/master/protection`
# -> 404, 2026-09-04). Under the filter such a PR is not found-and-suppressed, it is never
# examined -- and nothing in the output would ever mention it.
#
# #7 is that shape: base `master`, merge commit `$ML`, which is on `side` and not on
# `master`. Its head commit is not on master either, so no suppressor can hide it.
J2="$TMP/prs-forcepush.json"
python3 -I - "$J" "$ML" "$L" > "$J2" <<'PY'
import json, sys
prs = json.load(open(sys.argv[1], encoding="utf-8"))
prs.append({"number": 7, "baseRefName": "master",
            "mergeCommit": {"oid": sys.argv[2]}, "headRefOid": sys.argv[3],
            "title": "landed then force-pushed away"})
json.dump(prs, sys.stdout)
PY
fout="$( cd "$R" && bash "$CHK" --pr-json "$J2" --ack "$ACK_GOOD" master 2>&1 )"; fst=$?
case "$fst$fout" in
  1*"#7 (base 'master'"*"reachable from master by neither"*)
    ok "M20 a default-based PR whose merge commit vanished is reported, not skipped" ;;
  *) nok "M20 a default-based PR whose merge commit vanished is reported, not skipped" "st=$fst out=$fout" ;;
esac
# --- M20b: the at-risk figure stays a statistic about BASE ---------------------------
# WRONG-FIX CONTROL for the counter that replaced the filter. `AT_RISK=$((AT_RISK + 1))`
# made unconditional is the shortest thing that compiles once the `[ "$base" != ... ]`
# test is deleted, and it turns the ok line into a restatement of the total -- true on
# every run, informative on none. #8 is a default-based PR that DID land, so it raises
# "examined" from 6 to 7 and must leave "with a non-default base" at 3.
#
# It is deliberately a separate fixture from M20's: that one ends in a FAIL, and a failing
# run never reaches the ok line, so the count cannot be asserted on the same input that
# proves the PR was examined at all.
J3="$TMP/prs-extra-default.json"
python3 -I - "$J" "$MS" "$S" > "$J3" <<'EXTRAPY'
import json, sys
prs = json.load(open(sys.argv[1], encoding="utf-8"))
prs.append({"number": 8, "baseRefName": "master",
            "mergeCommit": {"oid": sys.argv[2]}, "headRefOid": sys.argv[3],
            "title": "ordinary landed PR"})
json.dump(prs, sys.stdout)
EXTRAPY
gout="$( cd "$R" && bash "$CHK" --pr-json "$J3" --ack "$ACK_GOOD" master 2>&1 )"; gst=$?
case "$gst$gout" in
  0*"7 merged PR(s) examined, 3 with a non-default base"*)
    ok "M20b the at-risk count stays a statistic about base, not a count of the sweep" ;;
  *) nok "M20b the at-risk count stays a statistic about base, not a count of the sweep" "st=$gst out=$gout" ;;
esac

# --- M21: a CRLF acknowledgment file works exactly like an LF one -----------------------
# The default IFS does not split on \r, so `55 62\r` hands `62\r` to the all-digit test,
# which rejects it, and the entry never reaches ACK_KEYS at all. The failure that produces
# is not "the acknowledgment does not hold" -- it is the generic finding, worded as though
# no ack file existed, in front of a maintainer who is looking at the ack file. This file
# is hand-edited and the repo has no `.gitattributes`, so a Windows editor is an ordinary
# way to reach it. Asserted by requiring byte-identical output to the LF run.
ACK_CRLF="$TMP/ack-crlf.txt"
printf '# comment\r\n\r\n2 4\r\n5 6\r\n' > "$ACK_CRLF"
run "$ACK_CRLF"; cst=$st; cout="${out//"$ACK_CRLF"/ACKFILE}"
run "$ACK_GOOD";        out="${out//"$ACK_GOOD"/ACKFILE}"
# The ack file's own path is printed in every note, so the two runs can never be
# byte-identical as they stand; the path is substituted out rather than the comparison
# being loosened to a substring, which would go green on a run that suppressed nothing.
if [ "$cst" -eq "$st" ] && [ "$cout" = "$out" ]; then
  ok "M21 a CRLF acknowledgment file parses identically to an LF one"
else
  nok "M21 a CRLF acknowledgment file parses identically to an LF one" "crlf=$cst lf=$st out=$cout"
fi

# --- M22: a repeated key in the acknowledgment file is fatal ----------------------------
# The lookup takes the first match, so appending a correction without deleting the mistake
# keeps trusting the mistake. Acks are validated against the tree, which makes this survive
# a machine bug and not an operator one: the stale first entry becomes a false PASS the
# moment it names any other genuinely landed PR. Refusing is the only reading that cannot
# silently pick the wrong line.
ACK_DUP="$TMP/ack-dup.txt"
printf '2 4\n2 6\n' > "$ACK_DUP"
run "$ACK_DUP"
case "$st$out" in
  1*"names #2 more than once"*) ok "M22 a repeated acknowledgment key is refused" ;;
  *) nok "M22 a repeated acknowledgment key is refused" "st=$st out=$out" ;;
esac

# --- M23: --default-branch beats the derivation --------------------------------------
# CI passes the exact name it already has rather than letting the script strip the ref to
# its last path segment, which is wrong for any default branch containing a slash. A name
# no PR is based on makes every PR at-risk, which is a verdict the derivation cannot
# produce from this ref and so cannot be reached by accident.
dout="$( cd "$R" && bash "$CHK" --pr-json "$J" --ack "$ACK_GOOD" --default-branch nosuchbranch master 2>&1 )"; dst=$?
case "$dst$dout" in
  0*"6 merged PR(s) examined, 6 with a non-default base"*)
    ok "M23 --default-branch overrides the name derived from the ref" ;;
  *) nok "M23 --default-branch overrides the name derived from the ref" "st=$dst out=$dout" ;;
esac

# --- M24/M25/M26: the three fail-closed paths that had no assertion --------------------
# All three are WRONG-FIX CONTROLS -- this script is new, so no assertion here can be a
# pre-fix control; there is no prior version of it for one to redden against. What they
# pin is that the guard fails for the REASON it was written for. Added because the gate's
# testing reviewer noticed these were the only documented fail-closed paths in the file
# without one, which made them read as an intentional gap the header discusses. They are
# not: every sibling guard (M8-M13, M15, M17c, M18) has had one from the first commit.
#
# `gh` is reached only on the branch this suite otherwise never takes -- every other
# assertion passes `--pr-json`, which is precisely why these went unwritten.

# A stub PATH rather than a prepended one: prepending leaves the real `gh` reachable if
# the stub name is ever misspelled, and the assertion would then go green against the live
# API. Named ABSOLUTELY for `bash` for M18's reason -- a run that dies at 127 before the
# script starts satisfies an exit-status check while proving nothing.
stub_bin() {  # stub_bin <dir> <tool>...  -- symlink real tools into an otherwise empty dir
  mkdir -p "$1"
  _d="$1"; shift
  for _t in "$@"; do ln -sf "$(command -v "$_t")" "$_d/$_t"; done
}

# --- M24: no gh, and no --pr-json, is fatal and says so -------------------------------
stub_bin "$TMP/noghbin" python3 git
gout24="$( cd "$R" && PATH="$TMP/noghbin" "$BASH_BIN" "$CHK" --ack "$ACK_EMPTY" master 2>&1 )"; gst24=$?
case "$gst24$gout24" in
  1*"gh is required"*) ok "M24 an absent gh is named and fatal when no --pr-json is given" ;;
  *) nok "M24 an absent gh is named and fatal when no --pr-json is given" "st=$gst24 out=$gout24" ;;
esac

# --- M25: a gh that exits non-zero is fatal, and names the permission it needs ---------
# The realistic failure is not an absent binary, it is a present one without
# `pull-requests: read` on the workflow token. `gh` writes its own diagnostic to stderr
# and exits non-zero, and the redirection means the truncated stdout still lands in
# $PR_JSON -- so a script that ignored the status would go on to parse an EMPTY file and
# report `ok: 0 examined`. That is the false PASS this pins: a clean bill from a run that
# listed nothing. `mktemp` and `rm` are in the stub because the guard sits AFTER the
# temp-file allocation and its EXIT trap.
stub_bin "$TMP/failghbin" python3 git mktemp rm
printf '#!/bin/sh\necho "gh: HTTP 403" >&2\nexit 1\n' > "$TMP/failghbin/gh"
chmod 755 "$TMP/failghbin/gh"
gout25="$( cd "$R" && PATH="$TMP/failghbin" "$BASH_BIN" "$CHK" --ack "$ACK_EMPTY" master 2>&1 )"; gst25=$?
case "$gst25$gout25" in
  1*"gh pr list failed"*"pull-requests: read"*)
    ok "M25 a failing gh pr list is fatal rather than parsed as an empty list" ;;
  *) nok "M25 a failing gh pr list is fatal rather than parsed as an empty list" "st=$gst25 out=$gout25" ;;
esac

# --- M26: --default-branch with no value is refused -----------------------------------
# The third value-taking flag. M17c pins `--ack`; this one exists because `--default-branch`
# is the flag CI actually passes, so a shift bug here mis-parses the workflow's own
# invocation -- `"$2"` would take the REF as the branch name and every PR would read
# at-risk, which is a plausible-looking output rather than an error.
dout26="$(bash "$CHK" --default-branch 2>&1)"; dst26=$?
case "$dst26$dout26" in
  1*"--default-branch needs a name argument"*)
    ok "M26 --default-branch with no value is refused" ;;
  *) nok "M26 --default-branch with no value is refused" "st=$dst26 out=$dout26" ;;
esac

# --- M27: a PR title cannot forge a record boundary ------------------------------------
# WRONG-FIX CONTROL for the `" ".join(...split())` sanitization in PARSE_PY. The reader
# emits TSV and the loop reads it with `IFS=$'\t' read -r num base mergeoid headoid title`,
# so the title is the ONLY field that is both last and attacker-controlled: a PR author
# picks it, and a newline inside it ends the record early. The plausible wrong fix is to
# drop the sanitization as cosmetic -- the comment above it calls the title "cosmetic", and
# it is, right up until the bytes it carries are read as structure rather than as text.
#
# The title below is shaped to be USED if it survives: a tab, a newline, and then a
# complete well-formed record for a PR #999 whose merge and head commits are both the
# all-zero OID. Unsanitized, the loop reads a seventh PR that GitHub never reported, finds
# neither commit reachable, and FAILS naming #999 -- a fabricated finding, which is worse
# than a garbled one because it is actionable and there is nothing to act on. Sanitized,
# the newline and tab collapse to spaces, the forged fields land harmlessly at the tail of
# #9's title, and the run is the ordinary all-landed pass.
#
# Asserted in both directions on purpose: the count pins that #9 WAS examined (a reader
# that dropped the record entirely would also print no #999), and the absence of the
# forged number pins that it was examined as one record rather than two.
J4="$TMP/prs-title-injection.json"
python3 -I - "$J" "$MS" "$S" > "$J4" <<'EVILPY'
import json, sys
Z = "0" * 40
prs = json.load(open(sys.argv[1], encoding="utf-8"))
prs.append({"number": 9, "baseRefName": "master",
            "mergeCommit": {"oid": sys.argv[2]}, "headRefOid": sys.argv[3],
            "title": "evil\ttab\n999\tmaster\t%s\t%s\tforged record" % (Z, Z)})
json.dump(prs, sys.stdout)
EVILPY
iout="$( cd "$R" && bash "$CHK" --pr-json "$J4" --ack "$ACK_GOOD" master 2>&1 )"; ist=$?
case "$iout" in
  *"#999"*) nok "M27 a tab/newline in a PR title cannot forge a record" "forged #999 was read as a PR: st=$ist out=$iout" ;;
  *) case "$ist$iout" in
       0*"7 merged PR(s) examined, 3 with a non-default base"*)
         ok "M27 a tab/newline in a PR title cannot forge a record" ;;
       *) nok "M27 a tab/newline in a PR title cannot forge a record" "st=$ist out=$iout" ;;
     esac ;;
esac
echo "1..$((PASS+FAIL))"
echo "# pass $PASS / fail $FAIL"
[ "$FAIL" -eq 0 ]
