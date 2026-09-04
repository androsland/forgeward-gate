#!/usr/bin/env bash
# ci/check-merged-prs-landed.sh [--pr-json <file>] [--ack <file>] [--default-branch <name>]
#                                [<ref>]                    default ref: origin/master
#
# Find a pull request that GitHub reports as MERGED and whose merge commit is on no ref
# the default branch can reach. Exit 0 and print a one-line summary when every merged PR
# landed, exit 1 and name the PR when one did not.
#
# WHY THIS EXISTS. On 2026-08-27 PR #55 was merged into a base branch that had itself
# merged twelve seconds earlier. GitHub recorded MERGED, the PR page shows MERGED, and
# the diff is on a ref `master` cannot reach. It stayed that way for seven days and was
# found by a person reading TODOS.md, not by anything automatic. The same shape hit #51
# ten minutes after it happened -- caught by a human that time too. One caught and one
# missed out of two occurrences is a coin, not a control.
#
# THE SHAPE IS KNOWABLE; THE POPULATION IS NOT, SO EVERY MERGED PR IS TESTED. A PR whose
# `baseRefName` is not the default branch is the shape that produced both real cases here,
# and the count of those is reported on the ok line because it is the useful statistic. It
# is NOT a filter, and an earlier draft made it one. "A PR based on the default branch
# lands there by construction" is an assumption about history never being rewritten, not a
# property: a force-push to the default branch drops merge commits, and a filtered check
# would exclude exactly those PRs from the sweep by construction -- never tested, never
# mentioned, invisible in the output. Measured 2026-09-04,
# `gh api repos/androsland/forgeward-gate/branches/master/protection` returns 404 Branch
# not protected, so on this repo that is an available accident, not a hypothetical.
#
# Testing all of them is free. Measured at `origin/master` = d9fa699: 60 merged PRs, 3 with
# a non-default base (#49, #51, #55), and the merge-commit test finds exactly the same two
# (#51, #55) whether it examines 3 or 60 -- 57 extra `git merge-base --is-ancestor` calls
# on local objects. There was never a cost to trade the coverage against.
#
# WHY SCHEDULED AND NOT `pull_request`. The condition is CREATED BY a merge, and it is
# created after the PR that suffers it has already closed. No PR event fires when a base
# branch merges out from under a dependent, so there is no pull_request run in which this
# could ever be true. A schedule is the only trigger that observes the state at all.
#
# THE OBVIOUS CHECK IS THE WRONG ONE, AND IT IS WRONG LOUDLY. Testing `headRefOid` for
# ancestry instead of `mergeCommit.oid` flags 45 of 60 PRs here -- measured against
# `origin/master` at d9fa699, and the figure MOVES WITH master, which is why it is quoted
# against a ref. A squash merge never leaves the head commit as an ancestor of anything,
# so on a healthy repo that form reports a 75% failure rate. A check that does that does
# not get run twice. `mergeCommit.oid` is the primary test and the only primary test.
#
# THE HEAD COMMIT IS A SUPPRESSOR, NEVER A PRIMARY. It is consulted only after the merge
# commit has already failed, and only to answer "did this content land anyway". #51's
# merge commit is orphaned while its head commit f118e8f IS on master, because #52
# re-landed it ten minutes later preserving the commit. Without the fallback this check
# reports 2 findings on a repo that has 1.
#
# ACKNOWLEDGMENTS ARE VALIDATED, NOT TRUSTED. The fallback only suppresses a re-land that
# preserved the original commit. A re-land done BY HAND produces different bytes -- #55
# was re-landed as #62 by three-way merge, and the bytes differ -- so neither the merge
# commit nor the head commit is an ancestor and the finding would repeat on every run
# forever, until somebody muted the check. `ci/relanded-prs.txt` is that mute, made
# checkable: an entry names the PR that re-landed the work, and this script suppresses
# the finding ONLY IF that named PR is itself merged and its own merge commit is an
# ancestor of the default branch. An acknowledgment for work that never landed suppresses
# nothing. Suppressed findings are still PRINTED, as a note rather than a failure, so the
# file cannot make anything invisible -- only non-fatal.
#
# FAILS CLOSED, LOUDLY, for the same reason ci/check-version-monotonic.sh does: this runs
# in CI where a false red costs one human glance. A missing interpreter, a missing `gh`, an
# unresolvable ref and unparseable JSON are each an exit 1 naming the reason. Nothing here
# should be softened into a skip -- a scheduled check that silently passes when its inputs
# are missing is worse than no scheduled check, because the green tick is read as evidence.
#
# BLIND SPOTS, stated so they are not mistaken for coverage:
#
#   1. It answers "did this merge commit land", never "is this work present". Those are
#      different questions and only the first is decidable from ancestry. A PR whose
#      content reached the default branch inside some unrelated commit reads as orphaned.
#   2. It cannot see a PR that landed and was then REVERTED. The merge commit is still an
#      ancestor, so the check is green while the work is gone. Nothing here looks at
#      content, and a revert is indistinguishable from normal history by this test.
#   3. It sees only what `gh pr list --limit` returns. The limit is 200 and this repo has
#      60 merged PRs; a repo past the cap gets SILENT truncation, so the script refuses
#      rather than reporting on a partial list when the returned count reaches the limit.
#      That guard fires at the limit and NOWHERE BELOW IT. If `gh` were ever to exit 0
#      having paginated only part of the list -- a transient API error or a secondary rate
#      limit on a middle page -- the result is a short, syntactically valid array and this
#      script reports `ok: N examined` on an undercount. Unverified: reproducing it needs a
#      real mid-pagination failure against the API, so it is stated as an open hole rather
#      than fixed on a guess about a behaviour nobody here has observed.
#   4. It cannot see the merge ORDER that caused the problem, only the state it left. Two
#      repos with identical findings can have had different accidents.
#   5. The default branch NAME decides the at-risk COUNT and nothing else. CI passes it
#      with `--default-branch`; a hand-run without that flag falls back to stripping the
#      ref to its last path segment, which is wrong for a default branch containing a
#      slash (`origin/release/2.0` -> `2.0`). Nothing detects that, and since the filter
#      was removed the consequence is a misleading number on the ok line, not a PR that
#      goes untested.
#   6. It cannot see a merge commit that a FORCE-PUSH removed and then re-created under a
#      different oid. Ancestry is asked about the oid GitHub recorded; a rewritten history
#      carrying the same changes under new oids reads as orphaned, and a rewritten history
#      that dropped the work entirely reads as orphaned too -- correct verdict, useless
#      diagnosis. Testing every merged PR (see the header) is what makes the second case
#      visible at all; distinguishing the two is not something ancestry can do.
#   7. It says nothing about an OPEN PR. Only a merged PR can be orphaned this way.

set -uo pipefail

# Script-wide and exported, per the repo convention pinned by A27/A28 in test/gate-test.sh.
# One mechanism, never a second inline prefix beside it: `local LC_ALL=C` is not passed to
# a spawned child, so the two forms are not equivalent and leaving both live is how the
# weaker one gets trusted. What it buys here is byte-exact sorting and deterministic tool
# output; `git` and `gh` are called as children, which is exactly the case `export` covers
# and `local` does not.
export LC_ALL=C

PR_JSON=""
ACK_FILE=""
DEFAULT_BRANCH=""
REF="origin/master"

while [ $# -gt 0 ]; do
  case "$1" in
    --pr-json)
      [ $# -ge 2 ] || { printf 'FAIL: --pr-json needs a file argument\n' >&2; exit 1; }
      PR_JSON="$2"; shift 2 ;;
    --pr-json=*) PR_JSON="${1#--pr-json=}"; shift ;;
    --ack)
      [ $# -ge 2 ] || { printf 'FAIL: --ack needs a file argument\n' >&2; exit 1; }
      ACK_FILE="$2"; shift 2 ;;
    --ack=*) ACK_FILE="${1#--ack=}"; shift ;;
    --default-branch)
      [ $# -ge 2 ] || { printf 'FAIL: --default-branch needs a name argument\n' >&2; exit 1; }
      DEFAULT_BRANCH="$2"; shift 2 ;;
    --default-branch=*) DEFAULT_BRANCH="${1#--default-branch=}"; shift ;;
    -h|--help)
      printf 'usage: %s [--pr-json <file>] [--ack <file>] [--default-branch <name>] [<ref>]\n' "$0"
      exit 0 ;;
    -*)
      printf 'FAIL: unknown option %s\n' "$1" >&2; exit 1 ;;
    *)
      REF="$1"; shift ;;
  esac
done

die() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# The bare branch name the API reports for a PR based on the default branch. It decides
# only which PRs are COUNTED as being at the shape's risk; since the filter was removed it
# can no longer exclude anything from the sweep, so getting it wrong now costs a wrong
# statistic rather than an untested PR.
#
# CI passes it explicitly (`--default-branch`) because the workflow already has the exact
# name from `github.event.repository.default_branch` and re-deriving it throws that away.
# The derivation below is the fallback for a hand-run, and it is lossy on purpose-built
# names: `${REF##*/}` on `origin/release/2.0` yields `2.0`. Blind spot 5.
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH="${REF##*/}"
  [ -n "$DEFAULT_BRANCH" ] || die "could not derive a branch name from ref '$REF'"
fi

# The limit is part of the contract, not a tuning knob: blind spot 3 turns on comparing
# the returned count against it, so the two must be the same number.
PR_LIMIT=200

# --- preflight: every dependency named, every absence fatal ------------------------

# python3 reads the API's JSON with the stdlib `json` module. Deliberately NOT softened
# into a grep/sed reader: this repo lost four separate times text-matching a field out of
# JSON, and a textual reader always disagrees with the parser the producer actually used.
# One reader, one shape, no second arm.
command -v python3 >/dev/null 2>&1 \
  || die "python3 is required to read the pull-request list (stdlib json only) and is not on PATH"

git rev-parse --verify --quiet "$REF" >/dev/null 2>&1 \
  || die "ref '$REF' does not resolve -- CI needs a full-history checkout (fetch-depth: 0)"

# A shallow clone is not a slower answer here, it is a WRONG one, and wrong in the
# direction that produces noise. `git merge-base --is-ancestor` on an object the clone
# does not have exits non-zero, which this script reads as "did not land". For a genuinely
# orphaned commit that verdict is right by accident -- the object is missing precisely
# because nothing reachable points at it. For a commit that DID land, a shallow clone is
# simply missing it, and every such PR is reported as a finding. Refuse rather than
# report on history that is not there.
[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "false" ] \
  || die "this is a shallow clone -- ancestry cannot be decided from partial history (need fetch-depth: 0)"

if [ -n "$PR_JSON" ]; then
  [ -f "$PR_JSON" ] || die "--pr-json file '$PR_JSON' does not exist"
else
  command -v gh >/dev/null 2>&1 \
    || die "gh is required to list merged pull requests and is not on PATH (or pass --pr-json)"
  PR_JSON="$(mktemp)" || die "mktemp failed"
  trap 'rm -f "$PR_JSON"' EXIT
  gh pr list --state merged --limit "$PR_LIMIT" \
      --json number,baseRefName,mergeCommit,headRefOid,title > "$PR_JSON" \
    || die "gh pr list failed -- the workflow needs 'pull-requests: read' and a token"
fi

# --- parse: one reader, TSV out ----------------------------------------------------
#
# `-I` is not hardening, it is the difference between reading the standard library and
# reading a file that arrived with the branch: `python3 -c` puts the process CWD at
# sys.path[0], so a `json.py` in the checkout would be imported instead of the stdlib.
# A25 in test/gate-test.sh fails on any site here that drops it.
#
# Emits one TAB-separated record per merged PR: number, baseRefName, mergeOid, headOid,
# title. Filtering to the at-risk population happens in the loop below, not here, so the
# total count stays available for the truncation guard.
PARSE_PY='
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
try:
    prs = json.loads(raw)
except Exception as e:
    sys.stderr.write("unparseable pull-request JSON: %s\n" % e)
    sys.exit(2)
if not isinstance(prs, list):
    sys.stderr.write("expected a JSON array of pull requests\n")
    sys.exit(2)
for p in prs:
    mc = p.get("mergeCommit") or {}
    # Tabs and newlines out of a title would forge a record boundary. The title is
    # cosmetic here, so it is sanitized rather than trusted -- it comes from a PR author.
    title = " ".join(str(p.get("title") or "").split())
    sys.stdout.write("\t".join([
        str(p.get("number") or ""),
        str(p.get("baseRefName") or ""),
        str(mc.get("oid") or ""),
        str(p.get("headRefOid") or ""),
        title,
    ]) + "\n")
'

RECORDS="$(python3 -I -c "$PARSE_PY" "$PR_JSON")" || die "could not read the pull-request list"

TOTAL="$(printf '%s\n' "$RECORDS" | grep -c . )"
[ "$TOTAL" -gt 0 ] || die "the pull-request list is empty -- a run that examined nothing has no pass to report"
[ "$TOTAL" -lt "$PR_LIMIT" ] \
  || die "got $TOTAL merged PRs at the --limit of $PR_LIMIT; the list is probably truncated and a partial answer is not one"

# --- acknowledgments ---------------------------------------------------------------
#
# `<orphaned-pr> <re-landing-pr>`, one per line, `#` comments and blank lines ignored.
# Read into two parallel space-delimited strings rather than an associative array so the
# script stays portable to bash 3.2 (macOS), which the rest of this repo's scripts are.
# `--ack` exists so the suite can drive this with its own fixture instead of the shipped
# file. A test that read ci/relanded-prs.txt would assert about whatever happens to be in
# it that week, and would go quietly vacuous the day an entry is removed.
[ -n "$ACK_FILE" ] || ACK_FILE="$(dirname -- "$0")/relanded-prs.txt"
ACK_KEYS=" "
ACK_VALS=" "
if [ -f "$ACK_FILE" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    # Carriage returns are stripped before anything else. The default IFS does not split
    # on \r, so a CRLF line hands `62\r` to the all-digit test, which rejects it, and the
    # entry vanishes -- the PR number never reaches ACK_KEYS, so the run does not even
    # report "the acknowledgment does not hold", it reports the generic finding as though
    # no ack file existed. This file is hand-edited by whoever re-landed the work and there
    # is no `.gitattributes` in this repo, so a Windows editor is an ordinary way to get
    # a permanently red check whose message never mentions the file sitting in front of you.
    _line="${_line//$'\r'/}"
    _line="${_line%%#*}"
    # `read` and not `set -- $_line`: the word splitting is wanted, the GLOBBING that
    # comes with it is not. An acknowledgment line reading `* 6` would expand against the
    # working directory, and the file is edited by hand by whoever re-landed the work.
    # A third field is read into `_c` purely so an over-long line can be REJECTED rather
    # than silently truncated to its first two -- `5 6 7` names no coherent pair.
    read -r _a _b _c <<< "$_line"
    [ -n "$_a" ] && [ -n "$_b" ] && [ -z "$_c" ] || continue
    case "$_a$_b" in *[!0-9]*) continue ;; esac
    # A repeated key is fatal rather than resolved. The lookup below takes the FIRST match,
    # so appending a corrected line without deleting the wrong one keeps trusting the wrong
    # one forever -- and because acks are validated against the tree, that only becomes a
    # false PASS when the stale entry happens to name some other genuinely landed PR, which
    # is precisely the shape a typo in a hand-edited file takes. Validation was built to
    # survive a machine bug; this is an operator bug and needs its own refusal.
    case "$ACK_KEYS" in
      *" $_a "*) die "$ACK_FILE names #$_a more than once; the first entry would silently win. Keep one line per orphaned PR." ;;
    esac
    ACK_KEYS="$ACK_KEYS$_a "
    ACK_VALS="$ACK_VALS$_a:$_b "
  done < "$ACK_FILE"
fi

# --- the sweep ---------------------------------------------------------------------

landed() { [ -n "$1" ] && git merge-base --is-ancestor "$1" "$REF" >/dev/null 2>&1; }

# The merge commit of a PR number, looked up in the records already parsed. Empty when the
# PR is not in the merged list at all, which is how an acknowledgment naming a still-open
# PR correctly fails to suppress anything.
merge_oid_of() {
  printf '%s\n' "$RECORDS" | awk -F'\t' -v n="$1" '$1 == n { print $3; exit }'
}

AT_RISK=0
FINDINGS=""
NOTES=""

while IFS=$'\t' read -r num base mergeoid headoid title; do
  [ -n "$num" ] || continue
  # Counted, never filtered on. See the header: skipping default-based PRs would make a
  # force-push-dropped merge commit structurally unreportable.
  [ "$base" != "$DEFAULT_BRANCH" ] && AT_RISK=$((AT_RISK + 1))

  # PRIMARY TEST. Never headRefOid -- see the header.
  landed "$mergeoid" && continue

  # SUPPRESSOR 1: the same commit reached the default branch another way (#51 via #52).
  if landed "$headoid"; then
    NOTES="$NOTES  note: #$num merge commit ${mergeoid:0:9} is unreachable from $REF, but its head commit ${headoid:0:9} IS -- the work landed, re-landed preserving the commit. $title
"
    continue
  fi

  # SUPPRESSOR 2: an acknowledgment, validated against the tree rather than believed.
  case "$ACK_KEYS" in
    *" $num "*)
      _by="$(printf '%s\n' "$ACK_VALS" | tr ' ' '\n' | awk -F: -v n="$num" '$1 == n { print $2; exit }')"
      _by_oid="$(merge_oid_of "$_by")"
      if landed "$_by_oid"; then
        NOTES="$NOTES  note: #$num did not land, and $ACK_FILE says #$_by re-landed it -- verified: #$_by's merge commit ${_by_oid:0:9} is an ancestor of $REF. $title
"
        continue
      fi
      FINDINGS="$FINDINGS  #$num (base '$base', merge commit ${mergeoid:-none}) -- $ACK_FILE claims #$_by re-landed it, but #$_by has NOT landed on $REF. The acknowledgment does not hold. $title
"
      continue ;;
  esac

  FINDINGS="$FINDINGS  #$num (base '$base', merge commit ${mergeoid:-none}) -- reported MERGED by GitHub, reachable from $REF by neither its merge commit nor its head commit. $title
"
done < <(printf '%s\n' "$RECORDS")

[ -n "$NOTES" ] && printf 'notes (not failures):\n%s' "$NOTES"

if [ -n "$FINDINGS" ]; then
  printf 'FAIL: a merged pull request is on no ref %s can reach:\n%s' "$REF" "$FINDINGS" >&2
  printf 'Re-land the work, then add "<pr> <re-landing-pr>" to %s.\n' "$ACK_FILE" >&2
  exit 1
fi

printf 'ok: %s merged PR(s) examined, %s with a non-default base, all reachable from %s\n' \
  "$TOTAL" "$AT_RISK" "$REF"
