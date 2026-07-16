#!/usr/bin/env bash
# forgeward-gate-check.sh <mode>
#
# The FAST-FEEDBACK half of the gate, invoked by hooks/hooks.json.
#   mode "pretooluse" : on a publish command (git push / gh pr create / glab mr
#                       create), remind/deny when the current checkout's branch
#                       has not passed /forgeward:gate.
#   mode "expansion"  : block a user-typed /ship expansion unless a fresh PASS
#                       marker exists (fast halt before any wasted work).
#
# This is a SOFT GUARDRAIL, not the enforcement boundary. A PreToolUse hook only
# sees the command TEXT, and no amount of parsing can reliably tell what an
# arbitrary shell command will push (`git -C`, quoting, `$vars`, `xargs`, a script
# file, an alias) — earlier versions tried and every one was bypassable. So this
# layer stays deliberately simple: it catches the common, accidental "I forgot to
# gate" case and gives immediate feedback. The ENFORCEMENT that actually blocks an
# ungated ref lives in the git `pre-push` hook (scripts/forgeward-pre-push.sh),
# which receives the exact refs+SHAs on stdin, after the shell has resolved
# everything — nothing left to trick. Install it with forgeward-install-pre-push.sh.
#
# Reads the hook event JSON on stdin. READ-ONLY. Fails OPEN (allows) on anything it
# cannot evaluate — no JSON tool, parse error, not a git repo — so it never wedges
# unrelated work. WORKTREE-SAFE: markers are branch-keyed under the common git dir
# (see write-marker), and a leading `cd` is honored best-effort so a push issued
# into a worktree is evaluated there.
set -uo pipefail
mode="${1:-pretooluse}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input="$(cat)"

_HAVE_JQ=0; command -v jq >/dev/null 2>&1 && _HAVE_JQ=1
_HAVE_PY=0; command -v python3 >/dev/null 2>&1 && _HAVE_PY=1
[ "$_HAVE_JQ" = 0 ] && [ "$_HAVE_PY" = 0 ] && exit 0

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

marker_get() {
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

# absolute path to the COMMON git dir (shared across all linked worktrees)
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

current_branch() { git rev-parse --abbrev-ref HEAD 2>/dev/null; }

# fresh == a marker for <branch> exists AND the substantive-diff hash of <tip> vs
# the marker's recorded base still matches what was reviewed
is_fresh() { # is_fresh <branch> <tip>
  local branch="$1" tip="$2" marker base stored cur
  marker="$(marker_path "$branch")" || return 1
  [ -f "$marker" ] || return 1
  base="$(marker_get "$marker" '.base')";        [ -n "$base" ]   || return 1
  stored="$(marker_get "$marker" '.diff_hash')"; [ -n "$stored" ] || return 1
  cur="$("$here/forgeward-diff-hash.sh" "$base" "$tip" 2>/dev/null)" || return 1
  [ -n "$cur" ] && [ "$cur" = "$stored" ]
}

# emit a deny decision (exit 0 + JSON) and exit; JSON-escape the reason
deny() {
  local r="$1"
  r="${r//\\/\\\\}"; r="${r//\"/\\\"}"
  cat <<JSON
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "$r"
  }
}
JSON
  exit 0
}

# best-effort: if the command starts with `cd <path> &&|;`, print <path> so the
# common "cd into a worktree then push" case is evaluated in that worktree. Not a
# security control (this layer isn't one) — just makes the reminder accurate.
honor_cd() {
  local re="^[[:space:]]*cd[[:space:]]+(\"([^\"]*)\"|'([^']*)'|([^[:space:]&;|]+))[[:space:]]*(&&|;)"
  [[ "$1" =~ $re ]] && printf '%s' "${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
}

cwd="$(json_get '.cwd')"
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || true

if [ "$mode" = "expansion" ]; then
  git rev-parse --git-dir >/dev/null 2>&1 || exit 0
  if is_fresh "$(current_branch)" "HEAD"; then exit 0; fi
  echo "forgeward gate: /ship halted — the reviewers have not returned VERDICT: PASS on the current code." >&2
  echo "Run /forgeward:gate first. It fires the relevant read-only reviewers and, on PASS, ships in one motion." >&2
  exit 2
fi

# --- pretooluse ---
cmd="$(json_get '.tool_input.command')"
case "$cmd" in
  *"git push"*|*"gh pr create"*|*"glab mr create"*) ;;
  *) exit 0 ;;   # not a publish command — never interfere with other Bash
esac

# best-effort: evaluate the worktree a `cd`-prefixed push runs in
tgt="$(honor_cd "$cmd")"
[ -n "$tgt" ] && cd "$tgt" 2>/dev/null || true

git rev-parse --git-dir >/dev/null 2>&1 || exit 0   # not a git repo -> nothing to remind

b="$(current_branch)"
is_fresh "$b" "HEAD" && exit 0

short="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
deny "forgeward gate: the current branch (${b} @ ${short}) has not passed /forgeward:gate. This is a fast best-effort reminder; the enforced check is the pre-push hook. Run /forgeward:gate, then push."
