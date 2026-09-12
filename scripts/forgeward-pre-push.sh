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
# (exit 1) the whole push if ANY branch ref being pushed lacks a fresh PASS marker,
# or if Gitleaks finds a credential in the commits being published. The credential
# scan runs for branch and tag updates whether or not a marker is fresh; deletions
# publish no object and are skipped.
#
# Honest limits (this is strong, not indestructible):
#   - `git push --no-verify` skips all pre-push hooks (a deliberate, visible opt-out).
#   - `FORGEWARD_SECRET_SCAN=skip` skips only the credential scan. The hook records
#     that event under the repo's common git dir without recording refs or values.
#   - the marker is a local file; anyone with repo access could forge one.
#   - git hooks are not cloned; a fresh clone must re-run the installer.
#   - binaries, LFS payloads, submodule contents, encoded/split credentials, and
#     commits already reachable from the remote boundary are outside this local scan.
# For an unbypassable boundary, gate the MERGE server-side (GitHub required checks +
# branch protection — see /forgeward:ci-gate). This hook stops the common/accidental
# ungated push, robustly, on the developer's machine.
#
# Fails OPEN only on missing tooling (no working jq/Python, no diff-hash script, or no
# Gitleaks) — never wedge a push because the gate's own dependencies are absent. It
# fails CLOSED on an ungated ref, an unresolvable scan range, or a scanner failure.
set -uo pipefail

# Locale-pinned repo-wide, not per-effect — see CLAUDE.md. A non-interactive script
# must not have its behaviour depend on the invoker's environment: character classes,
# collation and grep's handling of invalid UTF-8 all move with the locale, and the
# last one was a complete bypass of an ambiguity guard before it was pinned.
export LC_ALL=C
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIFF_HASH="$here/forgeward-diff-hash.sh"
SCAN_WRAPPER="$here/forgeward-scan.sh"
GITLEAKS_CONFIG="$here/../rules/gitleaks-pre-push.toml"
GITLEAKS_IGNORE="$here/../rules/gitleaks-pre-push.ignore"

# OPT-IN. This hook may live in a shared/global hooks dir (core.hooksPath), where it
# runs for EVERY repo. Enforce only in repos that explicitly turned the gate on
# (`git config forgeward.gate enabled`, set by the installer). Anywhere else: no-op.
[ "$(git config --get forgeward.gate 2>/dev/null || true)" = "enabled" ] || exit 0

[ -x "$DIFF_HASH" ] || { echo "forgeward pre-push: diff-hash helper missing ($DIFF_HASH) — allowing push (gate not enforced)." >&2; exit 0; }

_HAVE_JQ=0; _JQ_BIN=""; _probe=""
if _JQ_BIN="$(command -v jq 2>/dev/null)" \
  && _probe="$("$_JQ_BIN" -n -j '"forgeward-json-ok"' 2>/dev/null)" \
  && [ "$_probe" = "forgeward-json-ok" ]; then
  _HAVE_JQ=1
else
  _JQ_BIN=""
fi
_JSON_PY=""
for _py_name in python3 python; do
  _py_path="$(command -v "$_py_name" 2>/dev/null)" || continue
  [ -n "$_py_path" ] || continue
  _probe="$("$_py_path" -I -c 'import json,sys;sys.stdout.buffer.write(b"forgeward-json-ok")' 2>/dev/null)" || continue
  if [ "$_probe" = "forgeward-json-ok" ]; then
    _JSON_PY="$_py_path"
    break
  fi
done
[ "$_HAVE_JQ" = 0 ] && [ -z "$_JSON_PY" ] && { echo "forgeward pre-push: no working jq/python3/python — allowing push (gate not enforced)." >&2; exit 0; }

# The twin of gate-check.sh's marker_get, and it had drifted from it in TWO ways.
#
# 1. jq's EXIT STATUS was discarded, so "jq failed to run" and "the field is absent"
#    were the same observation. Fails CLOSED here — an empty `base` makes `is_fresh()`
#    return 1, the ref reads as ungated, and the push is refused — so this is friction,
#    not a hole. But `command -v jq` succeeding means jq is INSTALLED, not that it RUNS,
#    and while it was installed-and-broken the python3 fallback beside it was
#    unreachable: every push was blocked with no way to fall back.
#
# 2. It still used `print()`. DECISIONS.md (2026-08-02) records that "marker_get got the
#    same byte-writing treatment as json_get" — that landed in gate-check.sh only, and
#    this copy was never touched, so the entry described the repo as it was intended
#    rather than as it was. `print()` appends "\n", which becomes "\r\n" on Windows, and
#    `$(...)` strips only the LF; the surviving CR rides along on `base`, is passed to
#    forgeward-diff-hash.sh as a ref, fails to resolve, and makes a genuinely fresh
#    marker read as stale. Same fail-safe direction, same wrongness, one file over.
#
# Both are the error-path class this repo keeps re-finding. Neither can open the gate:
# python3 parses the SAME file, so a malformed marker fails both branches.
marker_get() { # marker_get <file> <dotpath>
  local _out
  if [ "$_HAVE_JQ" = 1 ]; then
    if _out="$("$_JQ_BIN" -r "$2 // empty" "$1" 2>/dev/null)"; then
      printf '%s' "$_out"
      return 0
    fi
    : # jq passed its probe but this read failed — let the verified Python answer
  fi
  [ -n "$_JSON_PY" ] || return 1
  "$_JSON_PY" -I -c 'import json,sys
path=sys.argv[1].lstrip(".").split(".")
try:
    d=json.load(open(sys.argv[2]))
    for k in path: d=d[k]
    sys.stdout.buffer.write((d if isinstance(d,str) else "").encode("utf-8","surrogateescape"))
except Exception: pass' "$2" "$1"
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

is_zero_sha() {
  [ -n "${1:-}" ] || return 1
  case "$1" in *[!0]*) return 1 ;; *) return 0 ;; esac
}

log_secret_scan_skip() {
  local common log_dir ts
  common="$(common_git_dir)" || return 0
  log_dir="$common/forgeward-security"
  mkdir -p "$log_dir" 2>/dev/null || return 0
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
  # Fixed strings only. A free-form reason would turn this visibility log into a
  # second place a user could accidentally persist the credential being bypassed.
  printf '{"ts":"%s","reason":"FORGEWARD_SECRET_SCAN=skip"}\n' "$ts" \
    >> "$log_dir/prepush-skip.jsonl" 2>/dev/null || true
}

# Resolve the default branch of the remote Git says this hook is pushing to. gstack's
# reference implementation checks origin/HEAD, origin/main, origin/master; using the
# supplied remote first preserves that order for origin and also works for a differently
# named upstream. No answer is normal: the caller then scans every commit reachable from
# the local tip, the commit-history equivalent of diffing its tree from the empty tree.
default_remote_branch() { # default_remote_branch <remote-name>
  local remote="$1" sym candidate
  sym="$(git symbolic-ref --quiet --short -- "refs/remotes/$remote/HEAD" 2>/dev/null || true)"
  if [ -n "$sym" ] && git rev-parse --verify --quiet "$sym^{commit}" >/dev/null; then
    printf '%s' "$sym"
    return 0
  fi
  for candidate in "$remote/main" "$remote/master"; do
    git rev-parse --verify --quiet "$candidate^{commit}" >/dev/null || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# Emit one tab-separated, terminal-safe record per finding. There are two parser
# implementations because user-machine hooks support jq OR Python; P22/P23 exercise
# both on the same JSON and require byte-identical records.
parse_gitleaks_findings() {
  if [ "$_HAVE_JQ" = 1 ]; then
    # shellcheck disable=SC2016  # jq program; $fallback is jq syntax, not shell expansion
    "$_JQ_BIN" -r '
      def clean: gsub("[\u0000-\u001f\u007f]"; "?") | .[0:240];
      def safe_string($fallback):
        if type == "string" and . != "" then clean else $fallback end;
      def safe_line:
        if type == "number" and . == floor then tostring
        elif type == "string" and test("^[0-9]+$") then clean
        else "?" end;
      if type != "array" then error("expected findings array") else . end
      | .[]
      | if type != "object" then error("expected finding object") else . end
      | [(.RuleID | safe_string("unknown-rule")),
         (.File | safe_string("(unknown-file)")),
         (.StartLine | safe_line)]
      | @tsv
    '
    return $?
  fi
  [ -n "$_JSON_PY" ] || return 1
  "$_JSON_PY" -I -c 'import json,math,re,sys
def clean(text):
    return "".join("?" if ord(c) < 32 or ord(c) == 127 else c for c in text)[:240]
def safe_string(value, fallback):
    return clean(value) if isinstance(value, str) and value else fallback
def safe_line(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value == math.floor(value):
        return str(int(value))
    if isinstance(value, str) and re.fullmatch(r"[0-9]+", value):
        return clean(value)
    return "?"
def reject_constant(_):
    raise ValueError("non-JSON numeric constant")
try:
    rows = json.load(sys.stdin, parse_constant=reject_constant)
    if not isinstance(rows, list): raise ValueError("expected findings array")
    out = []
    for row in rows:
        if not isinstance(row, dict): raise ValueError("expected finding object")
        out.append("\t".join((safe_string(row.get("RuleID"), "unknown-rule"),
                              safe_string(row.get("File"), "(unknown-file)"),
                              safe_line(row.get("StartLine")))))
    sys.stdout.buffer.write((("\n".join(out) + "\n") if out else "").encode("utf-8", "replace"))
except Exception:
    sys.exit(1)'
}

# Print only sanitized rule/file/line records. Gitleaks' JSON is held in memory and is
# never echoed or written to an artifact; --redact protects its Secret/Match fields,
# while deliberately discarding every other field keeps a credential-bearing commit
# message from becoming hook output.
scan_pushed_ref() { # scan_pushed_ref <local-sha> <remote-sha> <remote-name>
  local local_sha="$1" remote_sha="$2" remote_name="$3"
  local local_commit default_ref base log_opts scan_repo scan_json parsed scan_rc

  local_commit="$(git rev-parse --verify --quiet "$local_sha^{commit}" 2>/dev/null)" || return 2
  [ -n "$local_commit" ] || return 2

  if is_zero_sha "$remote_sha" || ! git cat-file -e "$remote_sha" 2>/dev/null; then
    default_ref="$(default_remote_branch "$remote_name" || true)"
    base=""
    if [ -n "$default_ref" ]; then
      base="$(git merge-base "$local_commit" "$default_ref" 2>/dev/null || true)"
    fi
    if [ -n "$base" ]; then
      log_opts="$base..$local_commit"
    else
      # `git log <tip>` includes the root diff and all reachable commits. For a
      # commit-wise scanner this is the empty-tree fallback: it scans all content
      # introduced in the history, including a secret later removed before the tip.
      log_opts="$local_commit"
    fi
  else
    log_opts="$remote_sha..$local_commit"
  fi

  git rev-list --max-count=1 "$log_opts" >/dev/null 2>&1 || return 2
  # Point Gitleaks at Git's object directory, not the worktree. Gitleaks otherwise
  # auto-loads a pushed root .gitleaksignore in addition to the explicit ignore
  # path, allowing repository content to suppress this independent guard.
  scan_repo="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 2
  case "$scan_repo" in
    [A-Za-z]:[\\/]*)
      command -v cygpath >/dev/null 2>&1 || return 2
      scan_repo="$(cygpath -u "$scan_repo" 2>/dev/null)" || return 2
      ;;
    /*) ;;
    *) return 2 ;;
  esac
  [ -d "$scan_repo" ] || return 2
  scan_json="$("$SCAN_WRAPPER" "$GITLEAKS_BIN" git \
    --log-opts="$log_opts" --config="$GITLEAKS_CONFIG" \
    --gitleaks-ignore-path="$GITLEAKS_IGNORE" --no-banner --no-color \
    --redact --exit-code=1 --report-format=json --report-path=- "$scan_repo" 2>/dev/null)"
  scan_rc=$?
  case "$scan_rc" in 0|1) ;; *) return 3 ;; esac

  parsed="$(printf '%s' "$scan_json" | parse_gitleaks_findings)" || return 3
  if [ -n "$parsed" ]; then
    printf '%s\n' "$parsed"
    return 1
  fi
  [ "$scan_rc" = 0 ] || return 3
  return 0
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
secret_findings=()
scan_failures=()

SECRET_SCAN=enabled
GITLEAKS_BIN=""
if [ "${FORGEWARD_SECRET_SCAN:-}" = "skip" ]; then
  SECRET_SCAN=skipped
  log_secret_scan_skip
  echo "forgeward pre-push: credential scan skipped via FORGEWARD_SECRET_SCAN=skip (logged without refs or values)." >&2
elif [ ! -x "$SCAN_WRAPPER" ] || [ ! -f "$GITLEAKS_CONFIG" ] || [ ! -f "$GITLEAKS_IGNORE" ]; then
  SECRET_SCAN=missing
  echo "forgeward pre-push: credential-scan helper/config missing — allowing push without a credential scan; marker enforcement remains active." >&2
elif GITLEAKS_BIN="$(command -v gitleaks 2>/dev/null)" && [ -n "$GITLEAKS_BIN" ]; then
  :
else
  SECRET_SCAN=missing
  GITLEAKS_BIN=""
  echo "forgeward pre-push: gitleaks not installed — allowing push without a credential scan; marker enforcement remains active." >&2
fi

# shellcheck disable=SC2034  # git's pre-push protocol puts FOUR fields on stdin and the
# positions are fixed; `local_ref` and `remote_sha` are named so the read stays readable
# against the documented shape, and are deliberately unread. Collapsing them into `_`
# would make the next person check git's docs to know which field is which.
# gstack's managed wrapper captures stdin with command substitution, which removes
# Git's trailing newline before it pipes the payload to pre-push.local. The second
# condition processes that final unterminated record; without it the chained hook is a
# total no-op for the common one-ref push.
while read -r local_ref local_sha remote_ref remote_sha || [ -n "${remote_ref:-}" ]; do
  [ -n "${remote_ref:-}" ] || continue
  is_zero_sha "$local_sha" && continue             # deletion -> publishes no object

  # Scan every published branch/tag ref independently of marker freshness. Keep going
  # after a failure so a multi-ref push reports every safely reportable finding at once.
  if [ "$SECRET_SCAN" = enabled ]; then
    scan_out="$(scan_pushed_ref "$local_sha" "$remote_sha" "${1:-origin}")"
    scan_rc=$?
    case "$scan_rc" in
      0) ;;
      1)
        while IFS=$'\t' read -r rule file line; do
          [ -n "${rule:-}" ] || continue
          secret_findings+=("$rule"$'\t'"$file"$'\t'"$line"$'\t'"$remote_ref")
        done <<< "$scan_out"
        ;;
      2) scan_failures+=("$remote_ref (pushed range could not be resolved)") ;;
      *) scan_failures+=("$remote_ref (gitleaks failed or returned invalid output)") ;;
    esac
  fi

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

if [ "${#secret_findings[@]}" -gt 0 ]; then
  {
    echo "forgeward pre-push: PUSH BLOCKED — credential(s) found in commits being published:"
    for finding in "${secret_findings[@]}"; do
      IFS=$'\t' read -r rule file line ref <<< "$finding"
      printf '  - %s  %s:%s  ref=%s  preview=[REDACTED]\n' "$rule" "$file" "$line" "$ref"
    done
    echo "Rotate the credential (a published secret is compromised) and remove it from every commit being pushed."
    echo "The preview is fully masked; no credential value was printed or logged."
  } >&2
fi

if [ "${#scan_failures[@]}" -gt 0 ]; then
  {
    echo "forgeward pre-push: PUSH BLOCKED — these ref(s) could not be scanned for credentials:"
    for failure in "${scan_failures[@]}"; do echo "  - $failure"; done
    echo "The scan fails closed when a pushed range is unresolvable or Gitleaks crashes."
  } >&2
fi

if [ "${#blocked[@]}" -eq 0 ] && [ "${#secret_findings[@]}" -eq 0 ] \
  && [ "${#scan_failures[@]}" -eq 0 ]; then
  exit 0
fi

if [ "${#blocked[@]}" -gt 0 ]; then
  {
    echo "forgeward gate: PUSH BLOCKED — these ref(s) have not passed /forgeward:gate:"
    for b in "${blocked[@]}"; do echo "  - $b"; done
    echo "Run /forgeward:gate on each (it reviews the diff and, on all-PASS, writes the marker), then re-push."
  } >&2
fi
echo "Bypass deliberately with git push --no-verify; skip only the credential scan with FORGEWARD_SECRET_SCAN=skip (logged)." >&2
exit 1
