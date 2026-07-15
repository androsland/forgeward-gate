#!/usr/bin/env bash
# forgeward-pre-push.sh — the ENFORCEMENT half of the gate, run as a git pre-push
# hook. Install with forgeward-install-pre-push.sh.
#
# Why this and not the PreToolUse hook: a PreToolUse hook only sees command TEXT,
# which cannot be reliably mapped to "what will be pushed" (git -C, quoting, $vars,
# xargs, aliases all defeat text parsing). A pre-push hook runs INSIDE git's push,
# after the shell has resolved everything, and git hands it the exact local refs +
# SHAs on stdin. There is nothing left to trick, so the gate binds to the real
# refs. This is where enforcement belongs.
#
# Contract: git passes `<remote-name> <remote-url>` as $1/$2 and, on stdin, one line
# per ref being pushed: `<local-ref> <local-sha> <remote-ref> <remote-sha>`. We block
# (exit 1) the whole push if ANY branch ref being pushed lacks a fresh PASS marker.
#
# Honest limits (this is strong, not indestructible):
#   - `git push --no-verify` skips all pre-push hooks (a deliberate, visible opt-out).
#   - the marker is a local file; anyone with repo access could forge one.
#   - git hooks are not cloned; a fresh clone must re-run the installer.
# For an unbypassable boundary, gate the MERGE server-side (GitHub required checks +
# branch protection — see /forgeward:ci-gate). This hook stops the common/accidental
# ungated push, robustly, on the developer's machine.
#
# Fails OPEN only on missing tooling (no jq/python3, no diff-hash script) — never
# wedge a push because the gate's own dependencies are absent. It fails CLOSED on an
# ungated ref.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIFF_HASH="$here/forgeward-diff-hash.sh"
ZERO='0000000000000000000000000000000000000000'

# OPT-IN. This hook may live in a shared/global hooks dir (core.hooksPath), where it
# runs for EVERY repo. Enforce only in repos that explicitly turned the gate on
# (`git config forgeward.gate enabled`, set by the installer). Anywhere else: no-op.
[ "$(git config --get forgeward.gate 2>/dev/null || true)" = "enabled" ] || exit 0

[ -x "$DIFF_HASH" ] || { echo "forgeward pre-push: diff-hash helper missing ($DIFF_HASH) — allowing push (gate not enforced)." >&2; exit 0; }

_HAVE_JQ=0; command -v jq >/dev/null 2>&1 && _HAVE_JQ=1
_HAVE_PY=0; command -v python3 >/dev/null 2>&1 && _HAVE_PY=1
[ "$_HAVE_JQ" = 0 ] && [ "$_HAVE_PY" = 0 ] && { echo "forgeward pre-push: no jq/python3 — allowing push (gate not enforced)." >&2; exit 0; }

marker_get() { # marker_get <file> <dotpath>
  if [ "$_HAVE_JQ" = 1 ]; then
    jq -r "$2 // empty" "$1" 2>/dev/null
  else
    python3 -c 'import json,sys
path=sys.argv[1].lstrip(".").split(".")
try:
    d=json.load(open(sys.argv[2]))
    for k in path: d=d[k]
    print(d if isinstance(d,str) else "")
except Exception: pass' "$2" "$1"
  fi
}

common_git_dir() {
  local d
  d="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -z "$d" ]; then
    d="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
    [ -n "$d" ] || return 1
    case "$d" in /*) ;; *) d="$(cd "$d" 2>/dev/null && pwd)" || return 1 ;; esac
  fi
  printf '%s' "$d"
}

marker_path() {
  local common
  [ -n "$1" ] || return 1
  common="$(common_git_dir)" || return 1
  printf '%s/forgeward-gate-markers/%s.json' "$common" "$1"
}

# fresh == a marker for <branch> exists AND the substantive-diff hash of <tip-sha>
# vs the marker's recorded base matches what was reviewed (version-bump-invariant).
is_fresh() { # is_fresh <branch> <tip-sha>
  local branch="$1" tip="$2" marker base stored cur
  marker="$(marker_path "$branch")" || return 1
  [ -f "$marker" ] || return 1
  base="$(marker_get "$marker" '.base')";        [ -n "$base" ]   || return 1
  stored="$(marker_get "$marker" '.diff_hash')"; [ -n "$stored" ] || return 1
  cur="$("$DIFF_HASH" "$base" "$tip" 2>/dev/null)" || return 1
  [ -n "$cur" ] && [ "$cur" = "$stored" ]
}

blocked=()
while read -r local_ref local_sha remote_ref remote_sha; do
  [ -n "${remote_ref:-}" ] || continue
  [ "$local_sha" = "$ZERO" ] && continue          # branch deletion -> publishes no code
  # Decide from the ref actually being UPDATED on the remote, not from the local side
  # (the local side may be a bare SHA, HEAD, HEAD~1 — `git push origin <sha>:refs/heads/x`
  # is an ordinary idiom, and keying off it would silently skip gating = fail open).
  case "$remote_ref" in
    refs/heads/*) rbranch="${remote_ref#refs/heads/}" ;;
    *) continue ;;                                 # tags / other refs are not branch-gated here
  esac
  # The commit being published is <local_sha>, however its source was named. It is gated
  # iff some local branch's marker attests THIS commit: check every local branch whose tip
  # is <local_sha>, plus the destination branch name. No attesting marker -> fail closed.
  gated=0
  for b in $(git for-each-ref --format='%(refname:short)' --points-at "$local_sha" refs/heads/ 2>/dev/null) "$rbranch"; do
    [ -n "$b" ] || continue
    if is_fresh "$b" "$local_sha"; then gated=1; break; fi
  done
  [ "$gated" = 1 ] || blocked+=("$rbranch @ ${local_sha:0:12}")
done

[ "${#blocked[@]}" -eq 0 ] && exit 0

{
  echo "forgeward gate: PUSH BLOCKED — these ref(s) have not passed /forgeward:gate:"
  for b in "${blocked[@]}"; do echo "  - $b"; done
  echo "Run /forgeward:gate on each (it reviews the diff and, on all-PASS, writes the marker), then re-push."
  echo "To bypass deliberately: git push --no-verify."
} >&2
exit 1
