#!/usr/bin/env bash
# forgeward-write-marker.sh <base-ref> <fired-csv> <reviewed-base> <reviewed-head> <run-id>
# forgeward-write-marker.sh --revoke <reviewed-head>
#
# Called by the /forgeward:gate skill ONLY after every fired reviewer returned
# "<AXIS> VERDICT: PASS". Writes the PASS marker so it is repo-scoped
# and never committed. The marker stores the substantive-diff hash that the
# PreToolUse hook re-checks at push time.
#
# The marker is keyed by BRANCH under the repo's COMMON git dir
# (git rev-parse --git-common-dir), not the per-worktree --git-dir. The common dir
# is shared across every linked worktree, so a gate run inside a worktree writes a
# marker the push hook finds even when the push is evaluated from a different
# checkout of the same repo. This is what makes the gate worktree-safe; keying by
# branch keeps concurrent worktrees on different branches from clobbering each
# other's marker.
#
# A MARKER CERTIFIES THE COMMITS THE REVIEWERS WERE GIVEN, NOT WHATEVER IS CHECKED OUT
# WHEN THIS RUNS. The gate freezes <reviewed-base> and <reviewed-head> in Step 0 and
# passes them here, and each must be the FULL commit id Step 0 printed (40 or 64
# lowercase hex) AND must resolve to itself. A symbolic name is refused: `HEAD` as
# <reviewed-head> would make the moved-HEAD check compare HEAD with itself, and a branch
# as <reviewed-base> would make the base comparison read one live ref twice -- both
# checks would pass vacuously. A short hex is refused too, because git resolves one that
# collides with a branch name to the branch. The shape alone is not enough: in a SHA-1
# repo a BRANCH may be named with 64 hex characters (in a SHA-256 repo, with 40), git
# resolves that name to the branch's live tip, and the moved-HEAD check passes vacuously
# again; an annotated tag's object id peels to a commit that is not the id given. So the
# resolved commit must EQUAL the argument byte-for-byte, or it is refused with exit 64.
# This refuses if HEAD is no longer <reviewed-head> (a commit landed while
# reviewers ran); refuses if either the reviewed pair or <base-ref> and <reviewed-head>
# share no merge base (orphan history, shallow clone), because forgeward-diff-hash.sh
# then hashes an EMPTY diff with exit 0 and the hooks would recompute that same empty
# hash for any later code; refuses if the hash of the frozen pair differs from the hash
# the push hook will recompute from <base-ref>; and stores the frozen pair's hash, so
# nothing is hashed from a live ref alone. A fetch that only advances <base-ref> leaves
# both hashes equal and is not refused. Until 0.31.0 this read HEAD and hashed the live
# range at write time, which pinned a marker to code no reviewer saw.
#
# --revoke <reviewed-head> takes the commit Step 0 FROZE, under the same full-id and
# resolves-to-itself rules, never live HEAD: if the checkout changed after Step 0, a
# revoke that followed HEAD would withdraw the new commit's markers and leave the
# reviewed commit's earlier PASS standing through a failed re-review. It deletes the
# marker of EVERY local branch whose tip is <reviewed-head> -- enumerated with the push
# hook's own `for-each-ref --points-at` expression, because the hook accepts any of them
# for that commit -- plus the current branch's own marker ONLY when HEAD's commit is
# <reviewed-head> (on a detached HEAD there, that is the literal `HEAD` key this writer
# uses). Markers of branches at OTHER commits are left alone, the current branch's
# included: they certify other diffs. Each branch is withdrawn under BOTH spellings of
# its name: the short one (`%(refname:short)`, what the hook enumerates and what this
# writer keys on, which becomes `heads/<name>` once a tag of the same name exists) and
# the canonical one (`refs/heads/` stripped, what the hook's destination-name lookup
# uses). Looking under one spelling only let a same-named tag created after the write
# hide the marker from revoke while the hook still accepted it. If the branches at the
# commit cannot be listed at all (a branch ref pointing at a missing object makes the
# enumeration exit non-zero), that is reported, every remaining path is still tried, and
# the exit is 1: an earlier PASS on an unlisted branch may still authorize a push. The
# gate runs --revoke when it commits to reviewing and again on every outcome that ends
# without a marker, so a failed or interrupted re-run never leaves an earlier PASS on a
# branch at that commit. A directory at a marker path is not a marker (the hooks cannot
# read one) and is skipped; a symlink is removed. Every path is tried before the exit
# status is decided: exit 1, naming each, when any marker exists and could not be
# removed -- that PASS may still authorize a push, and the gate stops on it.
#
# ONLY THE LATEST RUN ON A COMMIT MAY CERTIFY IT. Without this, run A passes and pauses
# before writing, run B on the same commit starts (revoke), fails and revokes again, and
# A resumes and writes a PASS for the commit B just rejected. So each run has an id:
# `--revoke <reviewed-head>` FIRST mints one and records it in
# `<common-dir>/forgeward-gate-runs/<reviewed-head>` (one file per commit, replaced
# atomically), THEN withdraws markers, and on exit 0 prints `RUN_ID=<id>` as its last
# line. The write takes that id as <run-id>; it is refused, before the environment probe
# runs, when the run file is missing or holds another id, and the run file is read AGAIN
# after the marker is written -- if it changed, the marker is removed when its bytes are
# still the bytes this process wrote, and the write is refused. Why that closes the race:
# a later revoke records its run id BEFORE it deletes anything. If its record lands
# before this writer's second read, the writer sees it and removes its own marker; if
# after, the revoke's delete comes after the write and removes it. Either way an older
# run's PASS cannot outlive a newer run's start or failure on that commit, with the one
# exception of a detached-HEAD write, the last residual below.
#
# Residuals of the run id, NON-GOALS rather than coverage:
#   - the compare-then-remove is not atomic, so a third run writing byte-identical
#     content in that instant loses its marker. Fail-closed: one re-gate.
#   - EVERY revoke supersedes, so a run whose own later revoke fires (a Step 3 halt or a
#     refused write) or another run's FAIL can refuse a concurrent PASS. Fail-closed.
#   - no lock is taken, deliberately: macOS ships no portable `flock`, and a stale lock
#     left by a killed run would wedge the gate, which is worse than a re-gate.
#   - a write from a DETACHED HEAD keys the literal `HEAD`, which a revoke run from a
#     branch checkout does not visit, so that one marker can outlive a newer run. The
#     enforced push hook reads `HEAD.json` only for a push whose destination branch is
#     literally named `HEAD`; the fast reminder reads it on any detached checkout. Not
#     fail-closed; filed in TODOS.md.
#
# NOT COVERED by --revoke, deliberately: the push hook also accepts the marker named
# after the push's DESTINATION branch. Revoke cannot know destination names, so pushing
# local branch `y` to remote branch `x` is still authorized by a stale `x` marker whose
# diff hash matches. Closing it would mean parsing marker JSON here, a dependency this
# script deliberately does not take (see the provenance block below). Filed in TODOS.md.
set -euo pipefail

# Locale-pinned repo-wide, not per-effect — see CLAUDE.md. A non-interactive script
# must not have its behaviour depend on the invoker's environment: character classes,
# collation and grep's handling of invalid UTF-8 all move with the locale, and the
# last one was a complete bypass of an ambiguity guard before it was pinned.
export LC_ALL=C
usage() {
  printf 'usage: forgeward-write-marker.sh <base-ref> <fired-csv> <reviewed-base> <reviewed-head> <run-id>\n' >&2
  printf '       forgeward-write-marker.sh --revoke <reviewed-head>\n' >&2
  exit 64
}
# The reviewed commits must be the full ids Step 0 printed; <base-ref> is a ref name and
# stays symbolic. Matched by length and charset first, not by asking git, because git is
# exactly what turns `HEAD`, `main` or a branch-colliding short hex into a live ref; the
# resolves-to-itself check after `commit_of` below is what closes a hex-shaped NAME.
hex_id() { # hex_id <value>: 40 or 64 lowercase hex
  case "${#1}:$1" in
    40:*[!0-9a-f]*|64:*[!0-9a-f]*) return 1 ;;
    40:*|64:*) return 0 ;;
  esac
  return 1
}
full_id() { # full_id <label> <value>
  hex_id "$2" && return 0
  printf "forgeward: %s '%s' must be the full commit id Step 0 printed (40 or 64 lowercase hex characters).\n" "$1" "$2" >&2
  exit 64
}
mode=write
if [ "${1:-}" = "--revoke" ]; then
  [ "$#" -eq 2 ] || usage
  mode=revoke
  reviewed_head_arg="$2"
  case "$reviewed_head_arg" in ''|-*) usage ;; esac
  full_id "reviewed head" "$reviewed_head_arg"
else
  [ "$#" -eq 5 ] || usage
  base="$1"; fired="$2"; reviewed_base_arg="$3"; reviewed_head_arg="$4"; run_id="$5"
  # Dash-led values are refused before git sees them: `git rev-parse` would read one as
  # an option. <fired-csv> may be empty; the other four may not.
  for _a in "$base" "$reviewed_base_arg" "$reviewed_head_arg" "$run_id"; do
    case "$_a" in ''|-*) usage ;; esac
  done
  full_id "reviewed base" "$reviewed_base_arg"
  full_id "reviewed head" "$reviewed_head_arg"
  hex_id "$run_id" || {
    printf "forgeward: run id '%s' must be the id from the RUN_ID=<id> line Step 2's --revoke printed (40 or 64 lowercase hex characters).\n" "$run_id" >&2
    exit 64; }
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "forgeward: not a git repo" >&2; exit 1; }

# Absolute path to the COMMON git dir (shared across all linked worktrees).
common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -z "$common_dir" ]; then
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
  case "$common_dir" in /*) ;; *) common_dir="$(cd "$common_dir" && pwd)" ;; esac
fi

# A detached HEAD reads as literal "HEAD" (and keys that marker). An UNBORN HEAD makes
# `--abbrev-ref` fail after printing "HEAD", so fall back to the symbolic name; revoke
# must not crash on either.
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" \
  || branch="$(git symbolic-ref --short -q HEAD 2>/dev/null)" || branch=""
# Nest the marker under refs-style branch path so 'design/x' and 'design-x' can't
# collide. Git branch names are already filesystem-safe (they map to
# refs/heads/<name> files), so no extra sanitization is needed. marker_of is the one
# reader of where a marker lives, for both modes and for every branch revoke visits.
marker_of() { printf '%s/forgeward-gate-markers/%s.json' "$common_dir" "$1"; }
marker="$(marker_of "$branch")"

commit_of() { git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null || true; }

# A reviewed commit must resolve to ITSELF (header: the shape alone is not enough). Called
# directly, never inside a substitution, so its exit stops the script (CLAUDE.md).
must_be_itself() { # must_be_itself <label> <arg> <resolved>
  [ -n "$3" ] || { printf 'forgeward: %s %s is not a commit\n' "$1" "$2" >&2; exit 64; }
  [ "$3" = "$2" ] || {
    printf "forgeward: %s '%s' resolves to %s rather than to itself; pass the full commit id Step 0 printed.\n" \
      "$1" "$2" "$3" >&2
    exit 64; }
}
if [ "$mode" = write ]; then
  reviewed_base="$(commit_of "$reviewed_base_arg")"
  must_be_itself "reviewed base" "$reviewed_base_arg" "$reviewed_base"
fi
reviewed_head="$(commit_of "$reviewed_head_arg")"
must_be_itself "reviewed head" "$reviewed_head_arg" "$reviewed_head"

# The CURRENT run id for <reviewed-head> (header: only the latest run on a commit may
# certify it). One file per commit, so a revoke for another commit supersedes nothing.
runs_dir="$common_dir/forgeward-gate-runs"
run_file="$runs_dir/$reviewed_head"
current_run() { cat "$run_file" 2>/dev/null || true; }

if [ "$mode" = revoke ]; then
  failed=0
  # MINT AND RECORD THE RUN ID FIRST, THEN WITHDRAW. The order is load-bearing: it is
  # what makes an older run's in-flight write lose either way (its second read sees this
  # id, or this run's delete lands after its write). Recording after the deletes would
  # open a window in which that write lands after the delete and still reads its own id.
  # Minted with git, not `od`: an unrelated `od` can sit earlier on PATH.
  run_id="$(printf '%s\n' "$$" "$(date -u +%Y%m%dT%H%M%S)" "$RANDOM$RANDOM$RANDOM$RANDOM" "$reviewed_head" \
    | git hash-object --stdin 2>/dev/null)" || run_id=""
  record_run() { # temp file in the same directory, then an atomic rename over the old one
    local tmp
    hex_id "$run_id" || return 1
    [ ! -d "$run_file" ] || return 1               # mv would move the new file INTO it
    mkdir -p "$runs_dir" 2>/dev/null || return 1
    tmp="$(mktemp "$runs_dir/.run.XXXXXX" 2>/dev/null)" || return 1
    if { printf '%s\n' "$run_id" > "$tmp"; } 2>/dev/null && mv -f "$tmp" "$run_file" 2>/dev/null; then
      return 0
    fi
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  }
  if ! record_run; then
    printf "forgeward: could not record this gate run for %s in %s, so an older run's write on that commit could still land.\n" \
      "${reviewed_head:0:12}" "$run_file" >&2
    failed=1
  fi
  # Every local branch at <reviewed-head>, by the push hook's own expression, under both
  # spellings: the short name (what the hook enumerates and this writer keys on) and the
  # canonical name minus refs/heads/ (what the hook's destination-name lookup uses). One
  # call emits both as consecutive lines; ref names cannot hold a newline, so the pairs
  # cannot drift.
  names=""
  if listing="$(git for-each-ref --format='%(refname:short)%0a%(refname)' --points-at "$reviewed_head" refs/heads/ 2>/dev/null)"; then
    while IFS= read -r short && IFS= read -r full; do
      names="$names$short"$'\n'"${full#refs/heads/}"$'\n'
    done <<EOF
$listing
EOF
  else
    printf "forgeward: could not list the local branches at %s, so an earlier PASS for one of them may still authorize a push. One cause is a branch ref that points at a missing object; \`git for-each-ref refs/heads/\` names it.\n" \
      "${reviewed_head:0:12}" >&2
    failed=1
  fi
  # The current branch, under both spellings, ONLY when HEAD is at <reviewed-head>: a
  # branch at another commit certifies another diff. On a detached HEAD there `$branch`
  # is the literal `HEAD` key the writer uses; on an unborn HEAD there is no commit.
  if [ "$(commit_of HEAD)" = "$reviewed_head" ]; then
    names="$names$branch"$'\n'
    canonical="$(git symbolic-ref -q HEAD 2>/dev/null || true)"
    case "$canonical" in refs/heads/?*) names="$names${canonical#refs/heads/}"$'\n' ;; esac
  fi
  names="$(printf '%s' "$names" | sort -u)"
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    m="$(marker_of "$b")"
    if [ -L "$m" ]; then :                       # a symlink is removed, whatever it points at
    elif [ -d "$m" ]; then continue              # a directory is not a marker
    elif [ -e "$m" ]; then :
    else continue
    fi
    rm -f -- "$m" 2>/dev/null || true
    if [ -e "$m" ] || [ -L "$m" ]; then
      printf "forgeward: could not withdraw the earlier PASS for '%s' (%s); it may still authorize a push.\n" \
        "$b" "$m" >&2
      failed=1
    else
      printf "forgeward gate: withdrew the earlier PASS marker for '%s'; it can no longer authorize a push.\n" "$b"
    fi
  done <<EOF
$names
EOF
  # On any failure no RUN_ID line: a run that could not withdraw or record must not be
  # able to certify anything.
  [ "$failed" = 0 ] || exit 1
  printf 'RUN_ID=%s\n' "$run_id"
  exit 0
fi
# A base ref that no longer resolves is refused before hashing: forgeward-diff-hash.sh
# hashes an EMPTY diff for a bad base and exits 0, so the comparison below would refuse
# with a misleading "base moved" message instead of this one.
base_commit="$(commit_of "$base")"
[ -n "$base_commit" ] || {
  printf "forgeward: base ref '%s' does not resolve to a commit; nothing was written.\n" "$base" >&2; exit 1; }
# With no merge base, forgeward-diff-hash.sh's `git diff <base>...<tip>` fails, its diff
# part is empty and it still exits 0 -- so the hash would be the EMPTY-diff hash, which
# both hooks recompute identically for any later code on the same pair. Refused here
# rather than in the helper; making the helper fail changes what both hooks do on a hash
# failure, which is its own decision (TODOS.md).
git merge-base "$reviewed_base" "$reviewed_head" >/dev/null 2>&1 || {
  printf 'forgeward: the reviewed base %s and the reviewed head %s share no merge base, so the reviewed diff cannot be hashed; nothing was written.\n' \
    "${reviewed_base:0:12}" "${reviewed_head:0:12}" >&2; exit 1; }
git merge-base "$base_commit" "$reviewed_head" >/dev/null 2>&1 || {
  printf "forgeward: the base '%s' and the reviewed head %s share no merge base, so the reviewed diff cannot be hashed; nothing was written.\n" \
    "$base" "${reviewed_head:0:12}" >&2; exit 1; }

head="$(commit_of HEAD)"
if [ "$head" != "$reviewed_head" ]; then
  printf 'forgeward: HEAD moved during the gate run (%s -> %s); nothing reviewed %s. Re-run /forgeward:gate.\n' \
    "${reviewed_head:0:12}" "${head:0:12}" "${head:0:12}" >&2
  exit 1
fi
# The REVIEWED hash is what the marker stores. The LIVE hash is what the push hook will
# recompute from `.base` (the ref name); if the two differ, the marker would certify a
# diff nobody reviewed. The comparison of the two hashes is the mechanism, not a check
# on any one ref.
hash="$("$here/forgeward-diff-hash.sh" "$reviewed_base" "$reviewed_head")" || {
  echo "forgeward: could not hash the reviewed diff; nothing was written." >&2; exit 1; }
live="$("$here/forgeward-diff-hash.sh" "$base" "$reviewed_head")" || {
  echo "forgeward: could not hash '$base'...HEAD; nothing was written." >&2; exit 1; }
if [ -z "$hash" ] || [ "$hash" != "$live" ]; then
  printf "forgeward: the base '%s' moved during the gate run in a way that changes the reviewed diff; nothing reviewed the new diff. Re-run /forgeward:gate.\n" "$base" >&2
  exit 1
fi

# This run must still be the CURRENT one for <reviewed-head>: a later run's revoke
# replaced the run file, or none was ever recorded. Checked here, after every other
# check and before the environment probe runs, and again after the write below.
superseded() { # superseded [<what happened>]
  printf 'forgeward: a later gate run on %s superseded this one (or no run is recorded for that commit); %s. Re-run /forgeward:gate.\n' \
    "${reviewed_head:0:12}" "${1:-nothing was written}" >&2
  exit 1
}
[ "$(current_run)" = "$run_id" ] || superseded

# --- environment provenance ---------------------------------------------------
# WHY THE MARKER CARRIES THIS. forgeward is scoped as a delta against gstack, so what
# a PASS actually COVERS depends on what else was installed on the machine that ran it.
# Two markers both saying `passed: true` can mean materially different things, and until
# now nothing recorded which. docs/axis-proposals.md §4 puts it as turning the coverage
# variance "from invisible into auditable". This is the auditable half; the disclosure
# the user reads is Step 1 of the gate skill.
#
# THIS IS PROVENANCE, NOT ENFORCEMENT. Nothing reads the field back — no freshness
# check consults it, no push is refused because of it. It answers "what did this PASS
# mean?" after the fact. Same is true of the `schema` number beside it, which is
# written here and read by nothing in the repo; do not mistake either for a
# compatibility mechanism.
#
# NEVER BLOCKS THE MARKER. The probe exits 0 by design, but it is still an external
# process that can be missing, unreadable, or replaced. A reviewer PASS that was
# genuinely earned must not be discarded because a provenance probe broke, so any
# unexpected output degrades to a recorded "unavailable" and the marker is written
# regardless. Losing the marker would force a full re-review; losing the provenance
# costs one unanswerable question later.
#
# VALIDATED BEFORE INTERPOLATION as an EXACT SHAPE, not a charset. The distinction is
# the whole point, and an earlier draft of this got it wrong in a way worth recording:
# it accepted any first line that began `{`, ended `}`, and drew only from the character
# set the probe uses. That is a CHARACTER allowlist, and it does not constrain STRUCTURE.
# A string like `{"a":"b"},"diff_hash":"forged","passed":false,"z":{}` satisfies every one
# of those conditions, and splicing it in produces a syntactically valid marker carrying
# DUPLICATE top-level keys — where jq and python3 both resolve last-value-wins, so the
# forged pair is what `is_fresh()` reads. Confirmed by proof-of-concept in the 0.8.0
# security review, which is also where the overstated comment was caught.
#
# So the check below matches the probe's output against the complete literal shape it is
# contracted to emit, anchored at both ends, with each field's value drawn from its own
# closed vocabulary. Duplicate-key splicing is unrepresentable: there is exactly one
# accepted string shape and it has no room for a second `diff_hash`.
#
# Deliberately NOT a jq/python3 structural parse, which was the reviewer's suggested fix.
# This script needs neither tool today and a marker write must not start depending on one
# — the marker is the artifact that authorizes a push, so its write path should have the
# fewest possible ways to fail. An anchored shape match is portable, needs no parser, and
# is strictly STRONGER than a generic `is this an object` test, which would still accept
# `{"passed":false}`.
#
# THE COST, stated because it is real: this couples the two scripts. Any new field in the
# probe's output must be added here in the same commit or the marker silently degrades to
# `probe: unavailable`. That failure is safe (provenance is lost, enforcement is not) and
# loud enough to notice in the E-series, but it is a genuine maintenance obligation and is
# recorded in TODOS.md.
#
# WHY VALIDATE AT ALL when the probe already sanitises its own output: the two files can
# be upgraded separately — this one ships in a plugin cache a user can edit — and the
# substitutes field is the only content here originating in a repo file rather than git.
env_json=""
if [ -x "$here/forgeward-detect-environment.sh" ]; then
  env_json="$("$here/forgeward-detect-environment.sh" 2>/dev/null | head -n 1 || true)"
fi
# `seo_posture` is matched as a CHARSET, not as the six-value enum the probe enforces,
# and the asymmetry with the fields above it is deliberate. The enum is validated at the
# source by whole-string comparison; repeating it here would add a second copy to drift
# out of sync while buying no additional structural constraint, because `[a-z-]` already
# excludes every character a splice needs (`"`, `,`, `{`, `}`) — which is the only thing
# this check is defending. Same reasoning as `substitutes` beside it.
#
# `config_warnings` is matched UNQUOTED and as digits, which is the narrowest arm in this
# whole expression — one to three digits with no quotes around them cannot express any
# character a splice needs. Written as `[0-9][0-9]?[0-9]?` rather than `[0-9]{1,3}`: the
# interval is valid POSIX ERE and grep -E honours it, but this repo already avoids interval
# expressions in its awk for portability and one spelling across both is worth more than
# three saved characters. Three digits is the probe's own 999 cap, so a longer run is
# out-of-contract output and correctly rejected rather than truncated.
_env_ok='^\{"gstack_ship":"(present|absent)","gstack_review":"(present|absent)","gstack_cso":"(present|absent)","config":"(present|absent|unreadable)","substitutes":"[A-Za-z0-9_,-]*","seo_posture":"[a-z-]*","config_warnings":[0-9][0-9]?[0-9]?\}$'
# This grep carried its own `LC_ALL=C` command prefix until the repo-wide pin at the top
# of the file took over. Both forms reach a child process, so the prefix was effective and
# not merely decorative — it was removed anyway, because two mechanisms claiming one
# invariant is how the next reader trusts the wrong one. The pin is what keeps `[^"]*`
# matching across invalid UTF-8, which is the property this guard rests on.
printf '%s' "$env_json" | grep -Eq "$_env_ok" || env_json=""
[ -n "$env_json" ] || env_json='{"probe":"unavailable"}'

mkdir -p "$(dirname "$marker")"

content="$(cat <<EOF
{
  "schema": 4,
  "passed": true,
  "branch": "$branch",
  "base": "$base",
  "reviewed_head": "$reviewed_head",
  "diff_hash": "$hash",
  "fired": "$fired",
  "environment": $env_json
}
EOF
)"
printf '%s\n' "$content" > "$marker"

# The SECOND read of the run file (header: why this closes the race). A revoke that
# recorded a newer run between the first read and the write has either already deleted
# this marker or will; one that recorded it before this read but deleted before the
# write is caught only here. The marker is removed only while its bytes are still the
# bytes this process wrote -- the WHOLE content, never a field pulled out of the JSON
# (CLAUDE.md: never text-match a field out of a structured document) -- so a newer run's
# marker at the same path is left alone.
if [ "$(current_run)" != "$run_id" ]; then
  on_disk="$(cat "$marker" 2>/dev/null || true; printf x)"; on_disk="${on_disk%x}"
  if [ "$on_disk" = "$content"$'\n' ]; then
    rm -f -- "$marker" 2>/dev/null || true
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      superseded "its marker at $marker could not be removed and may still authorize a push"
    fi
  fi
  superseded
fi

# --- GC: drop markers whose branch no longer exists ---------------------------
# Markers accumulate forever otherwise: one per branch ever gated, left behind by
# every merge-and-delete. Harmless (a dead branch's marker is never consulted, since
# lookup is keyed by the CURRENT branch) but unbounded, and it makes the directory
# useless for answering "what has been gated".
#
# Prune on write rather than behind a flag: a cleanup command nobody runs is not a
# cleanup. Deleting is fail-safe in the direction that matters — the worst outcome of
# a wrong deletion is one extra gate run, never a false PASS.
#
# Existence is checked against refs/heads, which lives in the COMMON git dir, so a
# branch checked out in ANOTHER linked worktree is correctly seen as alive and its
# marker survives. That is the case this must not fire on.
#
# BLIND SPOTS, stated so the limit is not mistaken for coverage:
#   - it cannot tell a branch deleted and later recreated under the same name from one
#     that was never gone, so such a marker survives. Deliberate: the staleness that
#     actually matters is content drift, and is_fresh() already re-checks the
#     substantive-diff hash on every push. This GC is disk hygiene, not freshness.
#   - on a DETACHED HEAD the branch reads as literal "HEAD", so that marker has no
#     refs/heads entry and a later run from a real branch sweeps it. Fail-safe in the
#     only direction that counts: it costs one re-gate, never a false PASS.
#   - `find -type f` stats without following links, so a SYMLINK sitting in the markers
#     directory is never seen by the sweep and never pruned. That is a completeness gap
#     in the cleanup, not a trust gap: GC only ever deletes, so an unpruned entry gains
#     nothing, and anyone able to plant one already has write access to the git dir and
#     could forge a marker outright. Left as-is rather than followed, because following
#     links is how a cleanup routine ends up deleting outside the directory it owns.
#   - CONCURRENT WRITES race. The live-branch snapshot and the batched delete are not
#     atomic, so if a second worktree creates and gates a branch inside that window,
#     this process's already-built delete list can remove that branch's just-written
#     marker. Demonstrated under an injected delay, not merely theorised. Same bounded
#     cost as the rest: one re-gate for that branch, never a false PASS, because the
#     push-time check re-validates the substantive-diff hash independently. Left
#     unfixed deliberately — locking a cleanup pass to close a window this narrow buys
#     less than the failure modes a lock introduces.
#   - it runs ONLY on the marker-write path, so nothing sweeps a repo that is not
#     gating anything. A branch merged and deleted leaves its marker behind, and on a
#     clean master there is no event left to prune it — the next gate of any branch
#     reaps it. Note a run can never reap its OWN receipt either: the branch is live
#     and explicitly skipped below, so a marker is only ever cleaned by a later,
#     unrelated gate. Harmless (GC only deletes, and the marker names a ref that no
#     longer resolves) but it has twice been mistaken for a broken sweep, which is the
#     actual cost. Deliberate: see "prune on write rather than behind a flag" above,
#     and the alternative — sweeping from gate-check or pre-push — means deleting
#     files during a push, on a path that must fail open so it never wedges one.
gc_markers() {
  local dir="$common_dir/forgeward-gate-markers" f name live
  [ -d "$dir" ] || return 0
  # Read every live branch ONCE. The obvious form -- `git show-ref` per marker file --
  # costs a process per file: benchmarked at ~11s for 1000 markers, paid on every gate
  # write. Wrapped in newlines so membership is a single unambiguous substring test;
  # git forbids newlines in ref names, so there is nothing to escape. Deliberately not
  # an associative array: bash 3.2 (still the system bash on macOS) has none.
  live=$'\n'"$(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)"$'\n'
  local -a doomed=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    name="${f#"$dir"/}"; name="${name%.json}"
    [ "$name" = "$branch" ] && continue          # never the marker just written
    case "$live" in
      *$'\n'"$name"$'\n'*) continue ;;           # branch still exists -> keep
    esac
    doomed+=("$f")
  done <<EOF
$(find "$dir" -name '*.json' -type f 2>/dev/null)
EOF
  # Batched, for the same reason the ref read is: one `rm` per file is one PROCESS per
  # file, and that -- not the ref lookup -- was the bulk of the cost once the per-file
  # git call was gone. `--` guards a path that begins with a dash. Paths come from
  # find under a directory this script owns, so no shell-metacharacter handling is
  # needed beyond quoting.
  [ ${#doomed[@]} -gt 0 ] && rm -f -- "${doomed[@]}"
  find "$dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}
gc_markers 2>/dev/null || true
# Run files, one per commit ever gated, pruned at 30 days on this same write-only path
# and with the same posture: GC never runs from a hook, and deleting one costs at most a
# refused write and one re-gate (no gate run spans a month), never a false PASS.
find "$runs_dir" -type f -mtime +30 -exec rm -f {} + 2>/dev/null || true

echo "forgeward gate: PASS marker written for '$branch' @ ${reviewed_head:0:8} (substantive-diff hash ${hash:0:12})"
