#!/usr/bin/env bash
# forgeward-gate-check.sh <mode>
#
# The enforcement handler invoked by hooks/hooks.json.
#   mode "pretooluse" : deny `git push` / `gh pr create` / `glab mr create`
#                       unless a fresh PASS marker matches the current code.
#   mode "expansion"  : block a user-typed /ship expansion unless a fresh PASS
#                       marker exists (fast halt before any wasted work).
#
# Reads the hook event JSON on stdin. READ-ONLY. Fails OPEN (allows) on anything
# it cannot evaluate — not a git repo, no JSON tool, parse error, missing base
# ref — so it never wedges unrelated work. The PreToolUse/Bash layer is the
# guaranteed floor; the expansion layer is a fast-halt convenience.
set -uo pipefail
mode="${1:-pretooluse}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input="$(cat)"

# Need a JSON reader. jq preferred, python3 fallback. Neither -> fail open.
_HAVE_JQ=0; command -v jq >/dev/null 2>&1 && _HAVE_JQ=1
_HAVE_PY=0; command -v python3 >/dev/null 2>&1 && _HAVE_PY=1
[ "$_HAVE_JQ" = 0 ] && [ "$_HAVE_PY" = 0 ] && exit 0

# json_get <dotpath> : read a string field from $input (stdin JSON)
json_get() {
  if [ "$_HAVE_JQ" = 1 ]; then
    printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null
  else
    printf '%s' "$input" | python3 -c 'import json,sys
path=sys.argv[1].lstrip(".").split(".")
try:
    d=json.load(sys.stdin)
    for k in path: d=d[k]
    print(d if isinstance(d,str) else "")
except Exception: pass' "$1"
  fi
}

# marker_get <dotpath> : read a string field from the marker file
marker_get() {
  if [ "$_HAVE_JQ" = 1 ]; then
    jq -r "$1 // empty" "$marker" 2>/dev/null
  else
    python3 -c 'import json,sys
path=sys.argv[1].lstrip(".").split(".")
try:
    d=json.load(open(sys.argv[2]))
    for k in path: d=d[k]
    print(d if isinstance(d,str) else "")
except Exception: pass' "$1" "$marker"
  fi
}

cwd="$(json_get '.cwd')"
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || true

# Not a git repo -> nothing to gate.
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
git_dir="$(git rev-parse --git-dir)"
marker="$git_dir/forgeward-gate-marker.json"

# Fresh == marker exists AND the substantive-diff hash still matches what was
# reviewed. Any new code/deps since the gate change the hash -> not fresh.
is_fresh() {
  [ -f "$marker" ] || return 1
  local base stored cur
  base="$(marker_get '.base')";       [ -n "$base" ]   || return 1
  stored="$(marker_get '.diff_hash')"; [ -n "$stored" ] || return 1
  cur="$("$here/forgeward-diff-hash.sh" "$base" 2>/dev/null)" || return 1
  [ -n "$cur" ] && [ "$cur" = "$stored" ]
}

if [ "$mode" = "expansion" ]; then
  # Matcher already restricted this to the `ship` command name.
  if is_fresh; then exit 0; fi
  echo "forgeward gate: /ship halted — the reviewers have not returned VERDICT: PASS on the current code." >&2
  echo "Run /forgeward:gate first. It fires the relevant read-only reviewers and, on PASS, ships in one motion." >&2
  exit 2   # exit 2 blocks the expansion (generic blocking-error contract)
fi

# --- pretooluse: only act on the publish commands ---
cmd="$(json_get '.tool_input.command')"
case "$cmd" in
  *"git push"*|*"gh pr create"*|*"glab mr create"*) ;;
  *) exit 0 ;;   # not a publish command — never interfere with other Bash
esac

if is_fresh; then exit 0; fi

short="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
# Documented PreToolUse contract: emit a deny decision (exit 0 + JSON).
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "forgeward gate not passed for HEAD ${short}. This publish (git push / PR create) is blocked because the read-only reviewers have not returned VERDICT: PASS on the current code. Run /forgeward:gate — it reviews the diff, writes the pass marker on all-PASS, then ships."
  }
}
EOF
exit 0
