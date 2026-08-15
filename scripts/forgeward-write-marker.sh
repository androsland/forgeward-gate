#!/usr/bin/env bash
# forgeward-write-marker.sh <base-ref> [fired-csv]
#
# Called by the /forgeward:gate skill ONLY after every fired reviewer returned
# "<AXIS> VERDICT: PASS". Writes the HEAD-pinned PASS marker so it is repo-scoped
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
set -euo pipefail

# Locale-pinned repo-wide, not per-effect — see CLAUDE.md. A non-interactive script
# must not have its behaviour depend on the invoker's environment: character classes,
# collation and grep's handling of invalid UTF-8 all move with the locale, and the
# last one was a complete bypass of an ambiguity guard before it was pinned.
export LC_ALL=C
base="${1:?usage: forgeward-write-marker.sh <base-ref> [fired-csv]}"
fired="${2:-}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "forgeward: not a git repo" >&2; exit 1; }

# Absolute path to the COMMON git dir (shared across all linked worktrees).
common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -z "$common_dir" ]; then
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
  case "$common_dir" in /*) ;; *) common_dir="$(cd "$common_dir" && pwd)" ;; esac
fi

branch="$(git rev-parse --abbrev-ref HEAD)"
head="$(git rev-parse HEAD)"
hash="$("$here/forgeward-diff-hash.sh" "$base")"

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
_env_ok='^\{"gstack_ship":"(present|absent)","gstack_review":"(present|absent)","gstack_cso":"(present|absent)","config":"(present|absent|unreadable)","substitutes":"[A-Za-z0-9_,-]*","seo_posture":"[a-z-]*"\}$'
# This grep carried its own `LC_ALL=C` command prefix until the repo-wide pin at the top
# of the file took over. Both forms reach a child process, so the prefix was effective and
# not merely decorative — it was removed anyway, because two mechanisms claiming one
# invariant is how the next reader trusts the wrong one. The pin is what keeps `[^"]*`
# matching across invalid UTF-8, which is the property this guard rests on.
printf '%s' "$env_json" | grep -Eq "$_env_ok" || env_json=""
[ -n "$env_json" ] || env_json='{"probe":"unavailable"}'

# Nest the marker under refs-style branch path so 'design/x' and 'design-x' can't
# collide. Git branch names are already filesystem-safe (they map to
# refs/heads/<name> files), so no extra sanitization is needed.
marker="$common_dir/forgeward-gate-markers/$branch.json"
mkdir -p "$(dirname "$marker")"

cat > "$marker" <<EOF
{
  "schema": 4,
  "passed": true,
  "branch": "$branch",
  "base": "$base",
  "reviewed_head": "$head",
  "diff_hash": "$hash",
  "fired": "$fired",
  "environment": $env_json
}
EOF

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

echo "forgeward gate: PASS marker written for '$branch' @ ${head:0:8} (substantive-diff hash ${hash:0:12})"
