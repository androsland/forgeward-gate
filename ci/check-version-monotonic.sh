#!/usr/bin/env bash
# ci/check-version-monotonic.sh [<base-ref>]        default base-ref: origin/master
#
# Refuse a merge that would move the plugin version BACKWARD, and refuse one that
# moves only some of the three manifests that carry it. Exit 0 and print a one-line
# summary when the branch is safe to merge, exit 1 and name the offending file when
# it is not.
#
# WHY THIS EXISTS. The version lives in three manifests -- package.json,
# .claude-plugin/plugin.json and .claude-plugin/marketplace.json -- and nothing until
# now checked that a merge moved it forward, so merge ORDER was load-bearing whenever
# two version-bumping PRs were open at once. On 2026-08-06 #17 bumped to 0.7.5 and #18
# to 0.7.6; merging #17 second would have taken the marketplace manifest 0.7.6 -> 0.7.5,
# and most plugin-manager update logic reads a backward version as no-op-or-worse rather
# than as an upgrade. That instance was avoided by merging #17 first, BY HAND. The hazard
# was never fixed, only dodged, and the only thing keeping three manifests monotonic was
# whoever happened to be paying attention at merge time.
#
# WHY CI AND NOT THE GATE. The gate is structurally the wrong layer and cannot be made
# the right one. V1-V3 deliberately neutralize a version-only bump in the substantive-diff
# hash so a release does not force a spurious re-gate, and that neutralization is
# DIRECTION-BLIND: a backward bump is exactly as invisible to the hash as a forward one.
# Nothing that reads the hash can see this class at all. It needs a check that compares
# two refs, which is what CI has and a local pre-push hook does not.
#
# THE RULE IS "NEVER BACKWARD", NOT "ALWAYS BUMP". Equality passes. Most PRs here are
# docs or fixes that do not touch the version (#21 is one), and a check that demanded a
# bump on every branch would fire on all of them -- a false FAIL on the common case,
# which is how a release check gets disabled. Only a strict DECREASE is refused.
#
# FAILS CLOSED, LOUDLY. Every uncertain answer is an exit 1 with the reason printed.
# That is the opposite of the direction the gate hook takes, and deliberately so: this
# runs in CI where a false red costs one human glance, while the hook fires on every
# Bash tool call and a false red wedges the session. Nothing here should be relaxed to
# make it quieter.
#
# BLIND SPOTS, stated so they are not mistaken for coverage:
#
#   1. It cannot see whether a version SHOULD have been bumped. A behaviour change that
#      ships under an unchanged version passes clean. This checks direction, never
#      whether the number earned its increment.
#   2. It reads X.Y.Z and refuses everything else, prereleases and build metadata
#      included (`0.9.0-rc1`, `0.9.0+build`). This repo has never shipped one. If that
#      changes, the refusal is a red CI run and a deliberate edit here -- not a silent
#      mis-comparison, which is what a hand-rolled prerelease ordering would produce.
#   3. It requires EXACTLY ONE `"version"` field per manifest and refuses ambiguity
#      rather than guessing which one is the plugin's. All three files have exactly one
#      today. A nested version added later turns this red on the next PR, which is the
#      intended way to find out.
#   4. A manifest absent from the base ref is skipped for the backward comparison (there
#      is no prior value to compare against) but still has to agree with the others on
#      the head side. Adding a manifest is a legitimate configuration and must not fire.
#      ALL THREE absent is the different case and is refused, not skipped: a run that
#      compared nothing has no evidence to report a pass from, and "ok" on zero
#      comparisons is the vacuous green this repo has been burned by before. The cost is
#      that the one-time bootstrap PR introducing the manifests to a repo goes red and
#      needs a human to wave it through. Accepted -- it happens once, and the
#      alternative is a check that is silently inert on a repo that never had them.
#   5. It compares the CHECKED-OUT tree against a ref. Under `pull_request` the workflow
#      checks out the PR head sha explicitly rather than GitHub's synthetic merge commit,
#      so what is compared is what the author wrote. See the workflow for why.
set -uo pipefail

BASE="${1:-origin/master}"

MANIFESTS="package.json .claude-plugin/plugin.json .claude-plugin/marketplace.json"

die() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Extract the single version field from a JSON blob. Refuses zero matches and refuses
# more than one -- see blind spot 3. Prints nothing and returns 1 on either.
read_version() { # read_version <json-text> <label>
  local n v
  n="$(printf '%s\n' "$1" | grep -c '"version"[[:space:]]*:[[:space:]]*"[^"]*"')"
  [ "$n" = "1" ] || { printf 'expected exactly 1 version field in %s, found %s\n' "$2" "$n" >&2; return 1; }
  v="$(printf '%s\n' "$1" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')"
  # Bash regex, NOT `printf | grep -q`. Under the `set -o pipefail` above, `grep -q`
  # exits on match and can SIGPIPE the printf still writing to it; pipefail then
  # promotes 141 to the pipeline status and the test reports NO-MATCH on input it
  # just matched. That is the P1 in DECISIONS.md, found by a 20000-trial probe, and
  # it must not be reintroduced here. `grep -c` and `grep -o` above drain to EOF and
  # so cannot lose that race; only an early-exit reader can.
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { printf 'version %s in %s is not X.Y.Z (blind spot 2)\n' "$v" "$2" >&2; return 1; }
  printf '%s' "$v"
}

# Strip leading zeros from a digit string, keeping a lone `0`. `1.08.0` is a legal
# shape for the regex above, and `08` must read as eight.
strip0() { local s="${1#"${1%%[!0]*}"}"; printf '%s' "${s:-0}"; }

# 0 when digit string $1 is numerically less than $2. NO BASH ARITHMETIC anywhere in
# this comparison, and that is the entire point.
#
# The first draft was component-wise `$((10#$a1))`, chosen over the obvious weighted
# sum `major*1000000 + minor*1000 + patch` because that form silently ties `1.0.1000`
# with `1.1.0`. The comment above it then claimed the fix had "no such ceiling", and
# the security review falsified that in one command: bash arithmetic is fixed-width
# signed 64-bit, so a component at or above 2^63 wraps two's-complement -- and nothing
# upstream bounded what reached it, because the validating regex accepts a digit run of
# ANY length. Demonstrated end to end: base `18446744073709551617.0.0`, head reverted
# to `1.0.0` -- a drastic backward move, the exact hazard this file exists to stop --
# printed `ok ... not behind` and exited 0. The ceiling had moved from 10^3 to 2^63; it
# had not gone away, and the comment asserting otherwise is how it survived review.
#
# Length-then-bytes has no ceiling at all, for real this time: with leading zeros gone,
# the longer numeral is always the larger one, and two numerals of EQUAL length compare
# numerically under a plain byte comparison because ASCII digits ascend in code-point
# order. `LC_ALL=C` is set locally so that last step is bytes rather than whatever the
# ambient locale's collation does with digits -- the same pinning the probe's `wc -c`
# has and its `awk` still lacks (open in TODOS.md).
num_lt() { # num_lt <digits> <digits>
  local LC_ALL=C x y
  x="$(strip0 "$1")"; y="$(strip0 "$2")"
  [ "${#x}" -ne "${#y}" ] && { [ "${#x}" -lt "${#y}" ]; return $?; }
  [[ $x < $y ]]
}

# 0 when version $1 is strictly less than version $2. Callers must validate X.Y.Z
# first -- `read_version` does.
version_lt() { # version_lt <a> <b>
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$1"
  IFS=. read -r b1 b2 b3 <<<"$2"
  [ "$(strip0 "$a1")" != "$(strip0 "$b1")" ] && { num_lt "$a1" "$b1"; return $?; }
  [ "$(strip0 "$a2")" != "$(strip0 "$b2")" ] && { num_lt "$a2" "$b2"; return $?; }
  num_lt "$a3" "$b3"
}

git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1 \
  || die "base ref '$BASE' does not resolve -- CI needs a full-history checkout (fetch-depth: 0)"

# --- head side: all three manifests must agree with each other --------------------
head_version=""
for f in $MANIFESTS; do
  [ -f "$f" ] || die "$f is missing from the working tree"
  v="$(read_version "$(cat "$f")" "$f")" || die "could not read a version from $f"
  if [ -z "$head_version" ]; then
    head_version="$v"
  elif [ "$v" != "$head_version" ]; then
    die "manifests disagree: $f says $v, an earlier manifest says $head_version -- a release bumps all three together"
  fi
done

# --- base side: no manifest may go backward ----------------------------------------
compared=0
for f in $MANIFESTS; do
  blob="$(git show "$BASE:$f" 2>/dev/null)" || {
    printf 'note: %s does not exist on %s -- no prior version to compare (blind spot 4)\n' "$f" "$BASE"
    continue
  }
  bv="$(read_version "$blob" "$BASE:$f")" || die "could not read a version from $BASE:$f"
  if version_lt "$head_version" "$bv"; then
    die "$f would go BACKWARD: $BASE has $bv, this branch has $head_version -- rebase and re-resolve the version, do not merge"
  fi
  compared=$((compared + 1))
done

[ "$compared" -gt 0 ] || die "no manifest on $BASE could be compared -- refusing to report a pass on zero evidence"

printf 'ok: version %s, not behind %s (%d manifest(s) compared, all three agree)\n' "$head_version" "$BASE" "$compared"
