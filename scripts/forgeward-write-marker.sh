#!/usr/bin/env bash
# forgeward-write-marker.sh <base-ref> <fired-csv> <reviewed-base> <reviewed-head> <run-id>
# forgeward-write-marker.sh --revoke <reviewed-head>
#
# Called by the /forgeward:gate skill ONLY after every fired reviewer returned
# "<AXIS> VERDICT: PASS". Writes the PASS marker, keyed by branch under the repo's COMMON
# git dir (`git rev-parse --git-common-dir`, shared by every linked worktree, so a marker
# written in one worktree is found by a push evaluated from another) and never committed.
# It stores the substantive-diff hash and the gate run's id; both hooks re-check both at
# push time.
#
# A MARKER CERTIFIES THE COMMITS STEP 0 FROZE, NOT WHATEVER IS CHECKED OUT. <reviewed-base>
# and <reviewed-head> must each be the FULL commit id Step 0 printed (40 or 64 lowercase
# hex) and must resolve to ITSELF, or the call is exit 64: a symbolic name, a short hex, a
# hex-shaped branch name or a tag's id would let a check below compare a live ref with
# itself (CLAUDE.md, "A marker certifies the commits Step 0 froze"). The write refuses
# when HEAD is no longer <reviewed-head>, when the reviewed pair or <base-ref> and
# <reviewed-head> share no merge base, when the frozen pair's hash differs from the hash
# the hooks will recompute from <base-ref>, or when this run is no longer the latest on
# <reviewed-head>; it stores the frozen pair's hash. A fetch that only advances
# <base-ref> leaves both hashes equal and is not refused.
#
# ONLY THE LATEST RUN ON A COMMIT CERTIFIES IT. `--revoke <reviewed-head>` (same full-id
# rules: the commit Step 0 froze, never live HEAD) first mints a run id and records it in
# `<common-dir>/forgeward-gate-runs/<reviewed-head>`, one file per commit, replaced
# atomically; on exit 0 its last line is `RUN_ID=<id>`. The write takes that id, is
# refused unless the run file holds it -- read before the write and again after, so a
# superseded run never reports a PASS -- and stores it as the marker's `run_id`. Both
# hooks accept a marker only while the run file for its `reviewed_head` still holds its
# `run_id`, and refuse it for a pushed commit that has a run file of its own and is not
# its `reviewed_head`. The run file is the authority: a newer revoke stales every marker
# for that commit, under any name, already on disk or still to land.
#
# --revoke then deletes the marker of every local branch at <reviewed-head> (by the push
# hook's own `for-each-ref --points-at` expression), plus the current branch's only when
# HEAD is at <reviewed-head> (the literal `HEAD` key on a detached HEAD), each under both
# spellings of its name: `%(refname:short)`, which a same-named tag turns into
# `heads/<name>`, and the canonical name with `refs/heads/` stripped. The run file is
# what the hooks consult; the deletions narrow the per-diff residual (first non-goal) for
# the branch's own follow-up commits. A branch's marker may certify an EARLIER commit with
# the same diff, whose run this revoke does not touch: without the deletion, a later
# commit on that branch with no run file of its own would push on it. They are also the
# only revocation a pre-push hook installed before 0.31.0 sees. Branches at other
# commits are left alone; their markers may certify the same diff, but they belong to
# other runs. A directory at a marker path is skipped; a symlink is removed.
# Exit 1, every path still tried and no RUN_ID line, when the run cannot be recorded, the
# branches at the commit cannot be listed, or a marker exists and could not be removed;
# the gate stops on it. Why the run file and not the name list: DECISIONS.md, 2026-11-16.
#
# NON-GOALS, so the limits are not read as coverage:
#   - acceptance is per DIFF, revocation per COMMIT. A PASS on C1 and a FAIL on C2 with
#     the same diff do not stop a push of a third commit C3 with that diff that no gate
#     run ever started on. That is what lets a /ship version bump push on the PASS
#     before it.
#   - a write stalled across a whole newer run can overwrite that run's marker and then
#     remove it, costing the newer run its PASS. Fail-closed: one re-gate.
#   - EVERY revoke supersedes, so a run's own later revoke (a Step 3 halt or a refused
#     write) or another run's FAIL refuses a concurrent PASS. Fail-closed.
#   - no lock is taken: macOS ships no portable `flock`, and a stale lock left by a killed
#     run would wedge the gate, which is worse than a re-gate.
#   - run files are kept forever, one small file per commit ever gated. Nothing here
#     deletes one: a delete by path cannot be made safe against revoke's atomic replace
#     without a lock, and deleting a fresh run file lets a same-diff PASS on another
#     commit authorize that commit while its review is pending or after it FAILs.
#     Deleting `forgeward-gate-runs` by hand makes every marker read stale (one re-gate)
#     and drops those commits' refusal of a same-diff PASS on another commit.
#   - markers and run files are local files; forging both by hand is outside the threat
#     model, as the hooks' own bypasses are.
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
mode='write'
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

# The CURRENT run id for <reviewed-head> (header: only the latest run on a commit
# certifies it). One file per commit, so a revoke for another commit supersedes nothing.
runs_dir="$common_dir/forgeward-gate-runs"
run_file="$runs_dir/$reviewed_head"
# The FIRST line, read exactly as the hooks' run_is_current reads it. `cat` read the whole
# file, so a run file holding the run id and then more text was accepted by both hooks and
# refused here; the writer and the hooks must answer the same question (P43).
current_run() {
  local line=""
  { IFS= read -r line || [ -n "$line" ]; } 2>/dev/null < "$run_file" || true
  printf '%s' "$line"
}

if [ "$mode" = revoke ]; then
  failed=0
  # MINT AND RECORD THE RUN ID FIRST, THEN WITHDRAW. Once recorded, every marker for this
  # commit names a stale run to both hooks. Recording before the deletes also means an
  # older run's in-flight write whose second read comes after this record refuses rather
  # than reporting a PASS. Minted with git, not `od`: an unrelated `od` can sit earlier on
  # PATH.
  run_id="$(printf '%s\n' "$$" "$(date -u +%Y%m%dT%H%M%S)" "$RANDOM$RANDOM$RANDOM$RANDOM" "$reviewed_head" \
    | git hash-object --stdin 2>/dev/null)" || run_id=""
  # mktemp creates the temp file 0600 whatever the umask, and the rename keeps that mode, so
  # a run file was unreadable to anyone the marker beside it (written with `>`, so the
  # umask decides) was readable to. The chmod gives it the marker's mode (K41).
  record_run() { # temp file in the same directory, then an atomic rename over the old one
    local tmp
    hex_id "$run_id" || return 1
    [ ! -d "$run_file" ] || return 1               # mv would move the new file INTO it
    mkdir -p "$runs_dir" 2>/dev/null || return 1
    tmp="$(mktemp "$runs_dir/.run.XXXXXX" 2>/dev/null)" || return 1
    if { printf '%s\n' "$run_id" > "$tmp"; } 2>/dev/null \
       && chmod "$(printf '%04o' $(( 0666 & ~0$(umask) )))" "$tmp" 2>/dev/null \
       && mv -f "$tmp" "$run_file" 2>/dev/null; then
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
  # branch at another commit belongs to another run. On a detached HEAD there `$branch`
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
# A base ref that no longer resolves is refused before hashing, and so is a pair with no
# merge base: forgeward-diff-hash.sh refuses both too, but only as "could not hash", and
# these name the cause.
base_commit="$(commit_of "$base")"
[ -n "$base_commit" ] || {
  printf "forgeward: base ref '%s' does not resolve to a commit; nothing was written.\n" "$base" >&2; exit 1; }
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
  "schema": 5,
  "passed": true,
  "branch": "$branch",
  "base": "$base",
  "reviewed_head": "$reviewed_head",
  "run_id": "$run_id",
  "diff_hash": "$hash",
  "fired": "$fired",
  "environment": $env_json
}
EOF
)"
printf '%s\n' "$content" > "$marker"

# The SECOND read of the run file, so a run superseded while it wrote never reports a
# PASS. The marker it wrote names this run, which neither hook accepts once the run file
# holds another id, so removing it is hygiene: done only while its bytes are still the
# bytes this process wrote -- the WHOLE content, never a field pulled out of the JSON
# (CLAUDE.md: never text-match a field out of a structured document) -- so a newer run's
# marker at the same path is left alone.
if [ "$(current_run)" != "$run_id" ]; then
  on_disk="$(cat "$marker" 2>/dev/null || true; printf x)"; on_disk="${on_disk%x}"
  [ "$on_disk" != "$content"$'\n' ] || rm -f -- "$marker" 2>/dev/null || true
  superseded "nothing it wrote can authorize a push"
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

echo "forgeward gate: PASS marker written for '$branch' @ ${reviewed_head:0:8} (substantive-diff hash ${hash:0:12})"
