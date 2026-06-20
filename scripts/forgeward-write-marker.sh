#!/usr/bin/env bash
# forgeward-write-marker.sh <base-ref> [fired-csv]
#
# Called by the /forgeward:gate skill ONLY after every fired reviewer returned
# "<AXIS> VERDICT: PASS". Writes the HEAD-pinned PASS marker into .git/ so it is
# repo-scoped and never committed. The marker stores the substantive-diff hash
# that the PreToolUse hook re-checks at push time.
set -euo pipefail
base="${1:?usage: forgeward-write-marker.sh <base-ref> [fired-csv]}"
fired="${2:-}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "forgeward: not a git repo" >&2; exit 1; }
git_dir="$(git rev-parse --git-dir)"
branch="$(git rev-parse --abbrev-ref HEAD)"
head="$(git rev-parse HEAD)"
hash="$("$here/forgeward-diff-hash.sh" "$base")"

cat > "$git_dir/forgeward-gate-marker.json" <<EOF
{
  "schema": 1,
  "passed": true,
  "branch": "$branch",
  "base": "$base",
  "reviewed_head": "$head",
  "diff_hash": "$hash",
  "fired": "$fired"
}
EOF

echo "forgeward gate: PASS marker written for '$branch' @ ${head:0:8} (substantive-diff hash ${hash:0:12})"
