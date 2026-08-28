#!/usr/bin/env bash
# forgeward-gate-check.sh <mode>
#
# The FAST-FEEDBACK half of the gate, invoked by hooks/hooks.json.
#   mode "pretooluse" : on a publish command (git push / gh pr create / glab mr
#                       create), remind/deny when the current checkout's branch
#                       has not passed /forgeward:gate.
#   mode "expansion"    : block a Claude user-typed /ship expansion unless a
#                         fresh PASS marker exists.
#   mode "prompt-submit": inspect a Codex UserPromptSubmit payload and block a
#                         direct /ship or $ship-style invocation unless fresh.
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

# Locale-pinned repo-wide, not per-effect — see CLAUDE.md. A non-interactive script
# must not have its behaviour depend on the invoker's environment: character classes,
# collation and grep's handling of invalid UTF-8 all move with the locale, and the
# last one was a complete bypass of an ambiguity guard before it was pinned.
export LC_ALL=C
mode="${1:-pretooluse}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input="$(cat)"

_HAVE_JQ=0; command -v jq >/dev/null 2>&1 && _HAVE_JQ=1
_HAVE_PY=0; command -v python3 >/dev/null 2>&1 && _HAVE_PY=1
[ "$_HAVE_JQ" = 0 ] && [ "$_HAVE_PY" = 0 ] && exit 0

# NOTE the python3 branch writes BYTES rather than using print(). On Windows, python's
# stdout is a text stream and translates every "\n" to "\r\n", so a multi-line command
# came back with a CR that is not in the command the shell will actually run. That is
# invisible in most single-line cases and quietly breaks anything matching across a line
# boundary — it made the line-continuation join (below) a no-op on Git Bash while passing
# on WSL, which is the kind of difference only running both platforms catches. jq does
# not do this, so the bug only ever appeared on a machine without jq.
#
# jq's EXIT STATUS is checked, and that is load-bearing. `jq -r '.x // empty'` prints
# nothing for an absent field and exits 0, so discarding the status made "jq failed to
# run" and "the field is not there" the same observation. A failed jq therefore handed
# back an empty command, which died at the pre-filter below, and the hook exited 0
# without ever looking at a marker — a silent fail-OPEN on a real publish. `command -v
# jq` still succeeded, so the python3 branch was never reached: being INSTALLED was
# treated as being FUNCTIONAL. Deterministic under a jq that exits 1 or 127 (tests
# A13/A14), and the failure this layer's header says it must never take.
#
# The pipe itself is safe here even under pipefail, unlike the one that used to be in
# the test harness's denies(): jq and python3 both drain stdin to EOF, so the writer is
# never orphaned. Only an EARLY-EXIT reader (`grep -q`, `head`) can SIGPIPE its writer.
json_get() {
  local _out
  if [ "$_HAVE_JQ" = 1 ]; then
    if _out="$(printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null)"; then
      printf '%s' "$_out"
      return 0
    fi
    : # jq is installed but did not run — fall through and let python3 answer
  fi
  [ "$_HAVE_PY" = 1 ] || return 1
  # TWO try blocks, not one, and the split is the whole point. A single
  # `except Exception: pass` around both the load and the traversal made
  # "the input is not JSON" and "the field is not in it" the same observation —
  # the identical conflation the jq arm above was fixed for, left live one branch
  # down, where it silently NEUTRALIZED that fix: on malformed input jq exits
  # non-zero, control falls through to here, and here it came back empty with
  # status 0. Measured, not reasoned: with jq present AND with jq absent, a
  # truncated payload carrying a real publish verb was ALLOWED.
  #   parse failure  -> exit 1, so the caller can tell it learned nothing
  #   absent field   -> exit 0 with empty stdout, which is the legitimate answer
  printf '%s' "$input" | python3 -I -c 'import json,sys
path=sys.argv[1].lstrip(".").split(".")
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
try:
    for k in path: d=d[k]
    sys.stdout.buffer.write((d if isinstance(d,str) else "").encode("utf-8","surrogateescape"))
except Exception: pass' "$1"
}

# Writes bytes for the same reason as json_get above. The values here are single-line, so
# the continuation bug does not apply — but print() still appends a "\n" that Windows
# turns into "\r\n", and `$(...)` strips only the trailing "\n". The surviving CR would
# ride along on `base`, which is then passed to forgeward-diff-hash.sh as a ref: it fails
# to resolve, the error is swallowed, and a genuinely fresh marker reads as stale. That
# direction is safe (an extra gate run, never a false PASS) but it is still wrong, and
# leaving the twin of a just-fixed bug in place two functions away is how it survives.
#
# It also discarded jq's EXIT STATUS, the same way `json_get` did above. That is the
# third instance of this class in this file's history (`json_get`, `strip_quoted`,
# this), and the reason it survived the round that fixed the other two is worth
# recording: it fails CLOSED. A failed jq yields an empty `base`/`diff_hash`,
# `is_fresh()` returns 1, and the branch reads as ungated — a spurious re-gate, never
# a missed one. It was left alone deliberately at 0.7.3 rather than widen a
# security-relevant diff with a consistency fix.
#
# Aligning it now is still worth doing, and not only for symmetry: `command -v jq`
# succeeding means jq is INSTALLED, not that it RUNS. On a box where jq is present but
# broken, every marker read returned empty, so every gate was a re-gate and the python3
# fallback beside it was never reached. The fall-through makes the fallback mean what
# its name says. It cannot open the gate: python3 parses the SAME file, so a malformed
# marker fails both branches and still reads as ungated.
marker_get() {
  local _out
  if [ "$_HAVE_JQ" = 1 ]; then
    if _out="$(jq -r "$2 // empty" "$1" 2>/dev/null)"; then
      printf '%s' "$_out"
      return 0
    fi
    : # jq is installed but did not run — fall through and let python3 answer
  fi
  [ "$_HAVE_PY" = 1 ] || return 1
  python3 -I -c 'import json,sys
path=sys.argv[1].lstrip(".").split(".")
try:
    d=json.load(open(sys.argv[2]))
    for k in path: d=d[k]
    sys.stdout.buffer.write((d if isinstance(d,str) else "").encode("utf-8","surrogateescape"))
except Exception: pass' "$2" "$1"
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

# Block a direct ship invocation using the output contract for the event that called
# us. Claude's UserPromptExpansion uses exit 2 + stderr. Codex UserPromptSubmit accepts
# the top-level decision/reason shape and keeps exit 0 for a handled decision.
block_ship() {
  local r="forgeward gate: ship halted — the reviewers have not returned VERDICT: PASS on the current code. Run the forgeward gate first; on PASS it writes the marker, then hands off to ship when that skill is installed."
  if [ "$mode" = "prompt-submit" ]; then
    r="${r//\\/\\\\}"; r="${r//\"/\\\"}"
    printf '{"decision":"block","reason":"%s"}\n' "$r"
    exit 0
  fi
  echo "forgeward gate: /ship halted — the reviewers have not returned VERDICT: PASS on the current code." >&2
  echo "Run /forgeward:gate first. It fires the relevant read-only reviewers and, on PASS, writes the marker — then ships in the same motion if gstack's /ship is installed." >&2
  exit 2
}

# Codex does not apply a matcher to UserPromptSubmit, so the handler must narrow the
# event itself. Match only a direct skill/command invocation at the start of the prompt,
# never prose that merely mentions shipping. Both slash and dollar forms are accepted
# because Codex uses $skill while converted/legacy workflows may still submit /ship.
is_ship_prompt() {
  local re='^[[:space:]]*[/\$](([A-Za-z0-9_]+[-:])?ship)([[:space:]]|$)'
  [[ "$1" =~ $re ]]
}

# best-effort: if the command starts with `cd <path> &&|;`, print <path> so the
# common "cd into a worktree then push" case is evaluated in that worktree. Not a
# security control (this layer isn't one) — just makes the reminder accurate.
honor_cd() {
  local re="^[[:space:]]*cd[[:space:]]+(\"([^\"]*)\"|'([^']*)'|([^[:space:]&;|]+))[[:space:]]*(&&|;)"
  [[ "$1" =~ $re ]] && printf '%s' "${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
}

_unreadable=0
cwd="$(json_get '.cwd')" || _unreadable=1
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || true

if [ "$mode" = "expansion" ] || [ "$mode" = "prompt-submit" ]; then
  if [ "$mode" = "prompt-submit" ]; then
    prompt="$(json_get '.prompt')" || _unreadable=1
    if [ "$_unreadable" = 0 ]; then
      is_ship_prompt "$prompt" || exit 0
    else
      # This hook sees every prompt. On malformed input, refuse only when the raw
      # payload mentions the publish action; unrelated prompts must not be wedged.
      case "$input" in *ship*) : ;; *) exit 0 ;; esac
    fi
  fi
  # Unreadable input means we do not know WHICH REPO this /ship is for. `cwd` came back
  # empty, so no cd happened, and is_fresh() would answer for whatever directory the hook
  # process happened to inherit — a fresh marker in an unrelated repo would let the ship
  # through. Block instead of guessing.
  #
  # Unconditional here, with no raw-text narrowing, because this path is not the one that
  # fires on every Bash call: it runs only on a typed /ship, so the cost of a false block
  # is one retry rather than a wedged session. The pretooluse path below has to be
  # narrower for exactly that reason, and the asymmetry is the point, not an oversight.
  if [ "$_unreadable" = 1 ]; then
    if [ "$mode" = "prompt-submit" ]; then
      block_ship
    fi
    echo "forgeward gate: /ship halted — the hook input could not be parsed, so which repo this applies to is unknown." >&2
    echo "Re-run it; if this repeats, check that jq/python3 work (\`jq --version\`, \`python3 -V\`)." >&2
    exit 2
  fi
  git rev-parse --git-dir >/dev/null 2>&1 || exit 0
  if is_fresh "$(current_branch)" "HEAD"; then exit 0; fi
  block_ship
fi

# --- pretooluse ---
cmd="$(json_get '.tool_input.command')" || _unreadable=1

# Input we could not parse. `cmd` is empty here for the same reason it is empty when the
# tool simply has no command field, and those two must not be treated alike: the second
# is an ordinary non-Bash call, the first is a publish we cannot see.
#
# Deciding from the RAW TEXT is the same fallback A7 already uses when awk is missing —
# less precise than the scanner, and only ever in the closed direction. It is scoped
# deliberately: this hook runs on EVERY Bash tool call, so denying outright on an
# unreadable payload would wedge the whole session the moment the JSON tool broke. A
# payload with no publish verb anywhere in its bytes cannot be a publish, so it is
# allowed through untouched and ordinary work keeps running.
#
# The cost is over-denial on a mangled payload that merely MENTIONS a verb — a retry,
# and only in a state where the hook's input is already corrupt. The old behaviour cost
# an ungated publish, silently.
if [ "$_unreadable" = 1 ]; then
  case "$input" in
    *push*|*create*)
      deny "forgeward gate: the hook input could not be parsed, and its raw text mentions a publish verb. Refusing rather than guessing. Re-run the command; if this repeats, check that jq/python3 work (\`jq --version\`, \`python3 -V\`)." ;;
  esac
  exit 0
fi

# --- read-only artifact guard -------------------------------------------------
# Deny a SCANNER invocation whose output flag points at a DRIVE-LETTER path. In a
# POSIX shell (Git Bash, WSL, Cygwin) `C:/…` is a RELATIVE path, so the scanner
# creates a `C:` directory tree inside the repo under review — on-disk name `C` +
# U+F03A, untracked, matched by no common .gitignore, and therefore committed by any
# `git add -A`. Observed twice from security-reviewer; the second time the spawn
# prompt explicitly told the agent to write artifacts outside the repository and it
# did this anyway, so this is enforced rather than requested.
#
# NARROW ON PURPOSE — but it DOES misfire, and pretending otherwise would be the same
# over-claim this change exists to remove. It matches command TEXT, so a command that
# merely QUOTES the defective shape is denied even though it runs no scanner and writes
# nothing: `grep -rn 'semgrep -o "C:/Users' DECISIONS.md` is refused. That is
# over-denial, which fails safe and is recoverable (reword, or use a file), and it is
# the same leaky-by-design tradeoff the README states for the publish reminder. Explicit
# non-goals — all of these are ALLOWED and must stay allowed:
#   - `semgrep -o report.json` (a developer's own run; the gate has no business
#     blocking it), `-o /tmp/x.json`, and any output flag with a POSIX path;
#   - a drive path in a NON-scanner command, e.g. `docker run -v C:/repo:/scan …`,
#     which native Windows docker resolves correctly.
# BLIND SPOT: it matches an ENUMERATED set of tools and output flags from the
# command TEXT. An unlisted scanner, an unusual output flag, or a path built inside
# a shell variable all pass. forgeward-scan.sh (refuses the flag at the invocation)
# and forgeward-workspace-guard.sh (diffs the tree afterwards) cover from the other
# side; neither this nor those is sufficient alone.
case "$cmd" in
  *semgrep*|*trivy*|*gitleaks*|*phpcs*|*phpcbf*|*bandit*|*osv-scanner*|*grype*|*syft*|*checkov*|*tfsec*|*retire*)
    # Two forms. Separated (`-o C:/x`, `--output=C:/x`), and CUDDLED (`-oC:/x`) — one
    # argv token, so the separated pattern cannot see it. The cuddled pattern therefore
    # matches any flag immediately followed by a drive-letter path.
    _out_re='(^|[[:space:]])(-o|--output|--output-file|--outfile|--out-file|--report-file|--report-path|--sarif-output|--json-output|--sarif-file)([[:space:]]+|=)("|'"'"')?[A-Za-z]:[\\/]'
    _cuddle_re='(^|[[:space:]])-[A-Za-z][A-Za-z-]*=?("|'"'"')?[A-Za-z]:[\\/]'
    if [[ "$cmd" =~ $_out_re ]] || [[ "$cmd" =~ $_cuddle_re ]]; then
      deny "forgeward: refusing to run a scanner with a drive-letter output path. This shell is POSIX (Git Bash/WSL), where 'C:/...' is a RELATIVE path — the scanner would create a 'C:' directory tree inside the repo under review, untracked and matched by no .gitignore, and 'git add -A' would commit it. Reviewers are read-only: drop the output flag and capture the report from STDOUT (add --json and read the output), or run it through \"${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/scripts/forgeward-scan.sh\", which enforces this. If a file is genuinely unavoidable, put it under \$(\"${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/scripts/forgeward-artifact-dir.sh\")."
    fi
    ;;
esac

# --- publish matcher: ISSUED vs MENTIONED ------------------------------------
# The verb is matched against UNQUOTED text only. The old test matched it as a bare
# substring of the whole command, so a command that merely MENTIONED one was treated
# as issuing one. Not theoretical: it fired six times in one session on this repo,
# including on the patch script that was fixing it. A repo whose subject matter IS
# these commands trips it constantly.
#
# What separates a mention from an invocation is whether the text is DATA or CODE, and
# the shell already encodes that: quoting. So blank the quoted spans and run the plain
# substring test on what remains. That needs no knowledge of separators, reserved
# words, or command prefixes — `time git push` matches for the same reason a bare one
# does, and `echo 'Careful! git push will trigger CI'` does not.
#
# Two earlier attempts anchored the verb to a "command position" instead and failed in
# OPPOSITE directions — too narrow (`time`/`env`/`sudo`/backticks evaded) and too wide
# (widening the anchor class to `!` and `)` denied ordinary prose). Position was the
# wrong signal. A third used bash extglob substitution to blank the quotes; it was
# correct but superlinear in QUOTE DENSITY — measured here at 2.3s on 1KB and 55s on
# 3KB of quote-dense input, while looking fine (15ms) on quote-SPARSE 20KB, which is
# how the cost was missed the first time.
#
# The no-fork constraint that ruled out a helper process was self-imposed: json_get
# above already forks jq or python3 on EVERY invocation of this hook, so one more fork
# on the small subset of commands that survive the prefilter costs proportionally
# little. Measured on WSL/gawk 5.1.0: ~7ms for the fork, and the scan itself is linear
# and quote-density-independent — 1ms at 3KB, 10ms at 20KB, 17ms at 60KB. A typical
# command is indistinguishable from the bare fork.
#
# WHY SUBSTITUTIONS ARE NOT MODELLED, and this is the load-bearing decision here.
# A blanking scanner and a command substitution are a bad match. bash gives each
# `$( … )` and each backtick span its own quoting scope; a scanner that tracks state
# left-to-right does not, and every attempt to teach it produced a fresh desync whose
# damage lands AFTER the construct that caused it — state restored early, and real code
# past that point blanked as if it were data. Three consecutive security reviews each
# found a different one, all silently allowing a command that really pushed:
#   1. flat quote parity      git commit -m "$(printf '%s' "it's done")" && git push
#   2. plain paren pairs      git commit -m "$( (true) ; git push )"
#   3. case-clause `)`        echo "$(case y in y) git push;; esac)"
# Each fix was correct and each left another. A fourth version would model `case`, and
# the header of this file already says where that road ends.
#
# So substitutions are not parsed, they are DISTRUSTED: if the command contains `$(` or
# a backtick, the blanked residue is not trusted and the RAW text is matched instead.
# That deletes the entire desync class rather than its current instance, and it costs
# only over-denial on commands that both contain a substitution and mention a verb. The
# precise path still handles every command WITHOUT a substitution — which is the shape
# the reported over-denial actually had: a commit message, a grep pattern, a JSON
# payload, none of them substitutions.
#
# Precisely what that buys, because an earlier version of this comment said "cannot hide
# anything" and that was false: raw-text matching cannot hide anything QUOTING would have
# hidden. It does nothing about text that never contained the verb contiguously in the
# first place — `git${IFS}push` supplies the separator at runtime and is invisible to a
# regex looking for literal whitespace, in the raw text just as much as in the residue.
# That is a separate class, it is under-matched, and it is listed below rather than
# papered over.
#
# BLIND SPOTS. Each bullet is asserted in test A4, so a change in behaviour fails the
# suite instead of quietly outdating this comment. Three earlier versions of a comment
# like this claimed completeness and were wrong; the assertions exist because of that.
# Every line below was confirmed by EXECUTING the command against stubbed git/gh/glab
# and observing whether a publish actually ran — observed, not inferred.
#
#   UNDER-MATCHES (no reminder fires):
#   - the verb inside a QUOTED argument to a shell wrapper: `bash -c 'git push'`, and
#     the `eval`, `ssh host`, and `trap ... EXIT` equivalents. Blanking the quotes
#     hides them. Accepted deliberately: un-blanking is exactly the over-denial this
#     change removes, and none is the accidental "I forgot to gate" shape. The old
#     substring DID catch these, so this is a real reduction in incidental coverage.
#   - a QUOTED COMMAND WORD: `'git' push`, `git 'push'`, `g'i't push`, `g""it push`.
#     Quoting does not make a token inert — it suppresses splitting and globbing, and
#     the shell concatenates adjacent fragments back into one word, so every one of
#     these really runs. Blanking the span breaks the verb apart and the regex stops
#     seeing it. This is NOT fixable at this layer, and the reason is worth stating:
#     the only thing separating `git 'push'` (runs) from `echo 'the command is git
#     push'` (does not) is whether the quoted word sits in COMMAND POSITION. Any rule
#     that catches the first also catches the second, which is the exact over-denial
#     this change exists to remove; deciding position is the grammar-enumeration dead
#     end the header warns about. Pre-existing — the old substring missed these too,
#     because `'git' push` does not contain the characters `git push` either. Note the
#     class can also split the VERB itself: `git pu''sh` runs, and carries no literal
#     `push` at all, so it dies at the cheap pre-filter — a full miss where the
#     raw-text fallback never even runs.
#   - SYNTHESISED SEPARATORS: `git${IFS}push`, `git$IFS'push'`, `gh${IFS}pr${IFS}create`.
#     The regex wants literal whitespace between the words; an expansion supplies it at
#     RUNTIME, so the two words are adjacent for the shell and disjoint in the text.
#     Routing to raw text does not help — the raw text has no whitespace there either.
#     Catching it means modelling word-splitting and expansion, which is the same
#     grammar-enumeration dead end. Pre-existing: the old substring missed these too.
#   - `git -C <path> push`, and any indirection through a variable, alias, function,
#     or script file. Pre-existing: the old substring missed these too.
#
#   OVER-DENIES (fail-safe — costs a reword, never a missed gate):
#   - an UNQUOTED mention still denies: `echo git push is next`, and likewise a
#     heredoc body, which is data but carries no quotes. Since the verb test became
#     case-insensitive this includes mixed case, so `echo the docs say Git push first`
#     denies where it did not before. Quoted prose is unaffected — it is blanked.
#   - ANY command containing `$(`, a backtick, or `${` followed by whitespace or `|` is
#     matched on its RAW text, so a verb merely mentioned there denies too:
#     `git commit -m "$(printf 'docs: git push')"`. The `${` arm fires on an inert or
#     escaped `${ ` as readily as a real value substitution, since the test is textual.
#     See "why substitutions are not modelled" below — this is bought deliberately.
#
#   NOT a gap, though it looks like one: an unterminated quote blanks the rest of the
#   text, but such a command does not parse, so nothing executes and allowing it is
#   correct. Asserted so it stays that way rather than being "fixed" into an over-deny.
#
# None of this is a security boundary, because this layer is not one — see the header.
# The enforced check is the pre-push hook, which binds to resolved refs and SHAs. Note
# it is OPT-IN (`git config forgeward.gate`, set by forgeward-install-pre-push.sh) and
# git hooks are not cloned, so on a checkout where it was never installed this reminder
# is the only thing in front of an ungated publish. That is why the under-match list is
# kept honest rather than convenient.
#
# Join line continuations BEFORE anything else looks at the text, the pre-filter
# included. An unquoted backslash-newline is a splice: bash deletes both characters and
# the lines join with nothing between them, so `git pu\<newline>sh` really runs a push
# — and the raw text contains neither "push" nor "create", so a pre-filter reading it
# would exit before any scanning happened. (That is exactly what it did until this line
# moved above the filter.) Joining here is simpler than carrying a continuation state
# through the scanner, and it cannot create a false match inside single quotes because
# quoted spans are blanked anyway.
_cmd_j="${cmd//\\$'\n'/}"

# Cheap pre-filter. Every publish verb contains "push" or "create", so a command with
# neither cannot be one and needs no scan at all. That is nearly every command, and this
# hook runs on EVERY Bash tool call, so the common path stays fork-free.
case "$_cmd_j" in
  *push*|*create*) ;;
  *) exit 0 ;;   # not a publish command — never interfere with other Bash
esac

# Blank quoted spans in one left-to-right pass, tracking quote AND backslash state.
#
# Escape state is not optional: outside quotes `\'` is a LITERAL quote, so a scanner
# that only pairs quote characters mis-pairs on `echo start\'; git push; \'echo end`
# and blanks a publish command that really does execute. Verified against real bash,
# not against a reading of the grammar (see test A5).
#
# This runs only on commands with NO substitution (see the guard below), so it does not
# model `$( … )`, backticks, or parens at all, and deliberately so — that machinery is
# what produced three separate desyncs.
#
# Portability: POSIX awk only. The escaped-char branch assigns through a variable
# rather than concatenating a parenthesised expression, because `out = out (x ? y : z)`
# parses as a CALL to an undefined function `out` under busybox awk. Verified
# identical verdicts under gawk, mawk, and busybox awk.
strip_quoted() {
  printf '%s' "$1" | awk '
    BEGIN { st = 0 }   # 0 = unquoted, 1 = inside single quotes, 2 = inside double
    {
      line = $0; n = length(line); out = ""; i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (st == 0) {
          if (c == "\\") {
            out = out " "; i++
            if (i <= n) {
              d = substr(line, i, 1)
              if (d == "\047" || d == "\"") d = " "
              out = out d; i++
            }
            continue
          }
          if (c == "\047") { st = 1; out = out " "; i++; continue }
          if (c == "\"")   { st = 2; out = out " "; i++; continue }
          out = out c; i++
        } else if (st == 1) {
          if (c == "\047") st = 0
          out = out " "; i++
        } else {
          if (c == "\\") { out = out "  "; i += 2; continue }
          if (c == "\"") st = 0
          out = out " "; i++
        }
      }
      print out
    }' 2>/dev/null
}

# Word boundaries on both sides, so `git pushx` and `npm run push-docs` stay clear —
# the one thing the bare substring got wrong in the other direction.
_pub_re='(^|[^A-Za-z0-9_-])(git[[:space:]]+push|gh[[:space:]]+pr[[:space:]]+create|glab[[:space:]]+mr[[:space:]]+create)([^A-Za-z0-9_-]|$)'

# --- a push that only DELETES remote refs publishes no code -------------------
# The ENFORCED layer already allows this: forgeward-pre-push.sh skips any ref whose
# LOCAL sha is all-zero, which is precisely what git writes on the hook's stdin for a
# deletion (verified against real git for both `--delete` and `:refspec`). This layer
# denied it, so the "fast best-effort reminder" refused what the thing it reminds you
# about waves through — and the advice it gave was unactionable, because a push that
# publishes nothing gives a reviewer nothing to review and no marker can ever attest to
# it. Post-merge branch cleanup and dropping a stale branch that never had a PR both had
# to gate an UNRELATED branch to get through. This closes that gap from the text side.
#
# It cannot close it the same WAY, and that shapes every line below. pre-push reads
# resolved refs and SHAs; this layer reads TEXT. So the exemption is narrow and every
# ambiguity resolves to DENY:
#
#   - TRUSTED RESIDUE ONLY (enforced at the call site). strip_quoted has already blanked
#     quoted spans, so a `--delete` inside an argument or a commit message is spaces by
#     the time this sees it and cannot open the exemption. On the raw-text paths — a
#     command bearing `$(`/backtick/`${ `, or a failed awk — that guarantee is gone, so
#     the exemption is not offered at all and the old deny stands.
#   - ONE SIMPLE COMMAND. Any shell metacharacter (`;&|(){}<>`, a newline, `$`, a
#     backtick) means a second command could run or a word could be synthesised at
#     runtime, so the exemption is refused outright rather than working out which command
#     the verb belongs to — that is the grammar-enumeration dead end the file header
#     warns about. `git push origin --delete x && git push` denies for this reason, and
#     so does a stacked-branch workflow interleaving deletions with real pushes. That is
#     the point, not a casualty.
#   - `git push` must be the literal command word. `sudo`/`time`/`env` prefixes and a
#     leading `cd … &&` all deny. `gh`/`glab` are never exempt — they always publish, and
#     `-d` means `--draft` there.
#   - flags are WHOLE argv tokens, so `--delete-this-is-not-a-flag` and `--deletex` are
#     ordinary options and open nothing.
#
# The two forms are checked DIFFERENTLY, and that was settled by running real pushes at a
# real remote and diffing the remote's ref list, not by reading git-push(1):
#   `--delete`/`-d`  ALL listed refs become deletions — `git push origin --delete y z`
#                    removed both and published nothing — so the flag alone settles it.
#   `:<ref>`         only the colon-prefixed refspecs are deletions. `git push origin :q
#                    newcode` deleted `q` AND published `newcode`. So this form also
#                    requires that no PLAIN refspec is present: at most one non-option
#                    token (the remote) may sit beside the colon refspecs.
#
# Unrecognised options DENY rather than being skipped, and that is not mere caution —
# `git push --tags origin :d2` was observed deleting `d2` and publishing a tag pointing
# at an unpublished commit. An option can send refs the argument list never names, and it
# can also consume a separate VALUE token that would otherwise be counted as a refspec.
# The whitelist below is therefore restricted to flags that do neither. (`--delete` is
# immune to the first — git itself refuses "--delete is incompatible with --all, --mirror
# and --tags" — but the colon form is not, and nothing in the text says so.)
#
# BLIND SPOT, stated rather than implied: a deletion issued through INDIRECTION is
# invisible here and always will be — `bash -c "$CMD"`, an alias, a function, a script
# file, `git -C <path> push --delete x`, or flags arriving in a variable. That is the
# same class the file header already defers to the pre-push hook; this branch neither
# narrows it nor widens it. Anything it cannot see keeps denying, which costs a reword,
# and the pre-push hook is what decides whether the push actually happens.
_is_delete_only() { # _is_delete_only <trusted-residue> <raw-command> -> 0 iff it can only DELETE refs
  local s="$1" raw="$2" t del=0 colon=0 plain=0 i first_colon=-1 plain_i=-1
  local _meta_re='[;&|()<>{}$`]'
  [[ "$s" =~ $_meta_re ]] && return 1
  case "$s" in *$'\n'*) return 1 ;; esac
  # THE RESIDUE'S WORD BOUNDARIES ARE NOT BASH'S. `strip_quoted` BLANKS a quote or a
  # backslash to a space rather than deleting it (the residue-length guard depends on
  # that 1:1 mapping), so an empty quote pair or an escape sitting INSIDE one real argv
  # token splits it into two tokens that bash never produced. Found by the 0.9.1 security
  # review, demonstrated end to end: `git push /pub/repo'':x.git` is ONE repository
  # argument to bash, but blanks to `… /pub/repo  :x.git`, which counts as plain=1 colon=1
  # and was ALLOWED — while really pushing the current branch and publishing it.
  # Every other consumer of the residue is a boolean word match that extra spaces cannot
  # fool (`_pub_re` uses `[[:space:]]+`); this function is the first that depends on exact
  # token COUNTS and BOUNDARIES, so it needs its own precondition.
  # Refusing on the three characters is a COMPLETE cover, not a heuristic: `strip_quoted`
  # maps every character to itself or to a space and never removes one, so a boundary can
  # only ever be ADDED, and every path that adds one (lines ~434-452) requires a `'`, a
  # `"` or a `\` in the input. It costs an over-denial on a quoted branch name, which is
  # the direction this file always fails in.
  # shellcheck disable=SC1003  # `*'\'*` is a glob for a LITERAL backslash, not an escape
  case "$raw" in *"'"*|*'"'*|*'\'*) return 1 ;; esac
  # The command word must BE the verb, so `sudo git push -d …` and `time git push -d …`
  # deny. (`git -C <path> push -d …` never reaches here at all — `_pub_re` wants `git`
  # and `push` adjacent, so it is allowed one step earlier by the under-match A4
  # already pins. This branch neither causes that nor fixes it.)
  # Deliberately ONE test rather than a separate
  # check on each of the first two tokens: written as two, a mutation run showed neither
  # could be killed on its own, because `_pub_re` has already guaranteed the words `git
  # push` appear adjacent, so any command where they are not the first two tokens is
  # rejected by whichever check the other one missed. As one line it is pinned by A23's
  # `sudo git push origin --delete x` case. The PROGRAM name is matched
  # case-insensitively and the SUBCOMMAND is not — the same asymmetry the verb test above
  # is built on, and the reason A12's `GIT push` stays a deny.
  local _head_re='^[[:space:]]*[Gg][Ii][Tt][[:space:]]+push([[:space:]]|$)'
  [[ "$s" =~ $_head_re ]] || return 1
  local tk=()
  read -ra tk <<< "$s"   # `read` does no globbing, and the residue has no newline by now
  # EVERY TOKEN MUST BE INERT, and this is an ALLOWLIST on purpose. `read -ra` does not
  # glob, so an unquoted `[os]*` is ONE token here and however many files it matches when
  # bash runs it: the 0.9.1 review demonstrated `git push [os]* :newcode` reaching this
  # layer as plain=1 colon=1, being exempted, and then publishing a branch the text never
  # named. That was the SECOND finding of the same shape as the quote-blanking one above —
  # the classifier's word boundaries are not bash's — and two misses is the argument for
  # inverting the test. A blocklist is only as good as my memory of every construct that
  # can synthesize a word (glob, brace, substitution, process substitution, …); an
  # allowlist fails closed on the one I have not thought of yet.
  # The set is what a remote name, a URL, a path and a refspec are actually made of. It is
  # not a guess about git: `git check-ref-format` REJECTS `*`, `?` and `[` in a ref name,
  # so nothing nameable is lost. `~` `^` `%` and `?` in a URL query are excluded too, which
  # over-denies a handful of exotic-but-legal spellings — the direction this file fails in.
  # `_meta_re` above stays as the structural check even though this subsumes much of it:
  # it refuses a second COMMAND before tokenizing, which is a different claim.
  local _inert_re='^[A-Za-z0-9_.:/@+=-]+$'
  for ((i = 2; i < ${#tk[@]}; i++)); do
    t="${tk[i]}"
    [[ "$t" =~ $_inert_re ]] || return 1
    case "$t" in
      --delete|-d) del=1 ;;
      # Flags that neither generate refs nor take a separate value. Anything else falls
      # to the `-*` arm below and denies.
      -q|--quiet|-v|--verbose|--verify|--no-verify|--progress|--no-progress|--porcelain|--dry-run|-n|--atomic|-4|--ipv4|-6|--ipv6) ;;
      -*)          return 1 ;;
      :?*)         colon=$((colon + 1)); if [ "$first_colon" -lt 0 ]; then first_colon=$i; fi ;;
      *)           plain=$((plain + 1));  if [ "$plain_i" -lt 0 ];    then plain_i=$i;    fi ;;
    esac                                  # a plain token is the remote, or a refspec that PUBLISHES
  done
  [ "$del" = 1 ] && return 0
  # The colon form allows at most ONE plain token, and it must come FIRST, because that is
  # the only position where git reads it as the REPOSITORY. Order matters and the count
  # alone does not say so: git takes the first bare positional as the repo wherever the
  # colon refspecs sit, so `git push :x origin` has `origin` as a refspec, not a remote.
  # That one happens to fail in git today (`:x` resolves as an empty-host ssh target), but
  # the exemption must not rest on someone else's error path.
  [ "$colon" -ge 1 ] && [ "$plain" -le 1 ] &&
    { [ "$plain" = 0 ] || [ "$plain_i" -lt "$first_colon" ]; }
}

# Two cases where the residue is not trusted and the RAW text is matched instead. Both
# over-deny, which costs a reword; the other direction costs a missed gate silently.
#   1. the command can substitute — see "why substitutions are not modelled";
#   2. awk is missing, so the scan came back empty on non-empty input.
#
# The `${` arm is easy to misread as parameter expansion. It is not: bash 5.3 added
# ksh-style VALUE substitutions, `${ cmd; }` and `${| cmd; }`, which RUN a command with
# neither `$(` nor a backtick anywhere in the text. It is matched as `${` followed by
# whitespace or `|`, which is what separates that syntax from an ordinary `${VAR}` —
# matching a bare `${` would send most quoted-variable commands down the raw-text path
# and give back a large slice of the over-denial this change exists to remove.
#
# This arm is LIVE, not theoretical, and an earlier version of this comment said the
# opposite. It claimed neither shell here supports the syntax, on the strength of a
# probe that ran under /bin/bash (5.1.16). But this script's shebang is
# `#!/usr/bin/env bash`, and on this machine that resolves to a linuxbrew bash 5.3.15
# which executes `${ git push; }` for real. The probe answered a question about a
# different interpreter than the one the hook runs under. Git Bash's 4.4.23 does reject
# it. Verified since: with 5.3 the arm denies correctly.
#
# The patterns are single-quoted so `$(`, `${` and the backtick are matched literally
# rather than expanded or treated as glob syntax.
#
# `_residue_trusted` records WHICH of the two paths answered. It is not used by the verb
# test — that one is fail-safe either way, since the raw-text path only ever over-denies.
# It gates the deletion exemption below, which is the one decision here that can turn a
# deny into an ALLOW, and which relies on quoted spans actually having been blanked.
_residue_trusted=0
# shellcheck disable=SC2016  # the patterns match LITERAL `$(`, `${` and a backtick — the
# whole point is that they must not expand, and double-quoting them would defeat the check
case "$_cmd_j" in
  *'$('*|*'${'[[:space:]]*|*'${|'*|*'`'*) _scan="$_cmd_j" ;;
  *) _scan="$(strip_quoted "$_cmd_j")"
     # Trust the residue only if it is AT LEAST AS LONG as what went in. The property
     # relied on is NEVER-SHORTER, and only that. An earlier version of this comment
     # said "one-for-one, nothing is ever dropped" — that is FALSE, and a fuzz of the
     # awk (600k+ trials, gawk/mawk/busybox) found two shapes where the residue comes
     # back LONGER:
     #   - a dangling backslash at the true end of an unterminated double-quoted string
     #     (the st==2 branch does `i += 2` with no bounds check), e.g. `echo "\` → 8
     #     chars out of 7 in;
     #   - multi-byte UTF-8 inside quotes under a BYTE-oriented awk (mawk, busybox),
     #     where one character is blanked into several spaces while bash counts
     #     characters, e.g. 17 out of 15.
     # Longer is harmless here — the guard does not fire and the residue is used, which
     # is the intended path. Nothing found produced a SHORTER residue except genuine awk
     # failure, truncation, or absence, which is exactly what this guard exists to catch.
     #
     # A SHORTER residue therefore means awk truncated: it died mid-write, or something
     # on PATH answered that does not implement the program. The previous guard rescued
     # only a COMPLETELY empty residue, so a partial one was scanned as though it were
     # whole and the verb could fall off the end of it. That is a silent fail-OPEN, and
     # it is deterministic under a truncating awk (test A15). Falling back to raw text
     # over-denies at worst, which is the direction this layer requires.
     #
     # This subsumes the empty case (0 is shorter than any non-empty input) and is a
     # no-op for empty input. If a future edit makes the residue shorter for ordinary
     # input, every command starts taking the raw-text path and the quoted-mention ALLOW
     # assertions (A2/A4/A16) go red — so the property is pinned from the other side,
     # not merely asserted in this comment.
     if [ "${#_scan}" -lt "${#_cmd_j}" ]; then _scan="$_cmd_j"; else _residue_trusted=1; fi ;;
esac

# Case-insensitively, because the PROGRAM name resolves case-insensitively on an
# NTFS-backed checkout (Git Bash): `Git push` really runs a push there, while `git`'s own
# SUBCOMMAND parsing stays case-sensitive, so `GIT PUSH` does not. That asymmetry is why
# the pre-filter above can stay case-sensitive — a real publish always carries a
# lowercase `push`/`create` — while this test must not. Pre-existing: the old substring
# had the same gap. nocasematch is scoped to this one test and restored, because it also
# changes `case` semantics and the artifact guard above relies on those.
_ncm_was_set=0; shopt -q nocasematch && _ncm_was_set=1
shopt -s nocasematch
[[ "$_scan" =~ $_pub_re ]]; _pub_hit=$?
[ "$_ncm_was_set" = 1 ] || shopt -u nocasematch
[ "$_pub_hit" = 0 ] || exit 0   # not a publish command

# A push that can only DELETE remote refs publishes no code, so there is nothing to gate
# and no marker could ever attest to it — the enforced pre-push hook skips these too.
# Offered only on a trusted residue; see _is_delete_only for why, and for its limits.
[ "$_residue_trusted" = 1 ] && _is_delete_only "$_scan" "$_cmd_j" && exit 0

# best-effort: evaluate the worktree a `cd`-prefixed push runs in
tgt="$(honor_cd "$cmd")"
[ -n "$tgt" ] && cd "$tgt" 2>/dev/null || true

git rev-parse --git-dir >/dev/null 2>&1 || exit 0   # not a git repo -> nothing to remind

b="$(current_branch)"
is_fresh "$b" "HEAD" && exit 0

short="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
deny "forgeward gate: the current branch (${b} @ ${short}) has not passed /forgeward:gate. This is a fast best-effort reminder; the enforced check is the pre-push hook. Run /forgeward:gate, then push."
