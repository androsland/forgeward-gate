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

# Nest the marker under refs-style branch path so 'design/x' and 'design-x' can't
# collide. Git branch names are already filesystem-safe (they map to
# refs/heads/<name> files), so no extra sanitization is needed.
marker="$common_dir/forgeward-gate-markers/$branch.json"
mkdir -p "$(dirname "$marker")"

cat > "$marker" <<EOF
{
  "schema": 2,
  "passed": true,
  "branch": "$branch",
  "base": "$base",
  "reviewed_head": "$head",
  "diff_hash": "$hash",
  "fired": "$fired"
}
EOF

echo "forgeward gate: PASS marker written for '$branch' @ ${head:0:8} (substantive-diff hash ${hash:0:12})"
