#!/usr/bin/env bash
# forgeward-transcript-audit.sh [--root DIR] [--project SLUG] [--urls] [--patterns]
#
# Search Claude Code's persisted transcripts for credential-SHAPED strings and report
# FILENAMES ONLY. Never prints a match, a line, or a byte of the value — printing it is
# the exposure this exists to measure.
#
# WHY IT EXISTS. forgeward 0.2.0-0.9.1 documented a Gitleaks invocation that passed a
# path LIST to `gitleaks dir`, which takes exactly one positional path; given any other
# number it silently scans the current directory instead. A scan that read as "these two
# changed files" was a walk of the whole working tree, untracked and gitignored files
# included, and whatever it read was written into the reviewer subagent's persisted
# transcript. The gate can prevent a write. It had no way to look at one that already
# happened, so the README could only say "rotate". This is the looking.
#
# It is not scoped to that defect. The same shape recurs whenever any tool reads a file
# nobody meant it to read and the output lands in a transcript -- a reviewer told to
# `cat` a config, a scanner handed a directory instead of a file, a debug dump pasted
# into a prompt. Also usable as a plain hygiene check before handing over a machine.
#
# AT LEAST THREE CHANNELS, WHICH IS WHY THE PATH DOES THE SCOPING. The two that were
# already known:
#
#   ~/.claude/projects/<project-slug>/<session-uuid>/subagents/agent-*.jsonl
#   ~/.claude/projects/<project-slug>/<session-uuid>/tool-results/<id>.txt
#
# A tool result over 30 000 characters is TRUNCATED in the .jsonl and written in full to
# tool-results/, with the transcript keeping only a `persistedOutputPath` pointer -- so
# the .txt can hold key material the .jsonl beside it does not.
#
# The third was found by this script's own first run and had not been written down:
#
#   ~/.claude/projects/<project-slug>/<session-uuid>.jsonl      (top-level, no subdir)
#
# Measured on the machine it was written on: of 20 files matching a credential shape,
# 14 were under subagents/, 1 under tool-results/, and 5 were top-level session
# transcripts in neither. An audit that enumerated the two documented channels would
# have missed a QUARTER of the hits, and reported the rest as the whole picture.
#
# So this searches the tree with NO extension filter and NO channel list: the path does
# the scoping and depth takes care of itself. The 0.9.2 notice used `--include='*.jsonl'`
# and could not match a .txt at all; enumerating the two known directories is the same
# mistake one level up. There is a fourth directory in the wild already -- `memory/` --
# which a recursive search covers for free. Assume there will be a fifth.
#
# SCOPE IS EVERY PROJECT BY DEFAULT, AND THAT IS A CORRECTION. The obvious design is to
# audit "this repo's own project directory". It does not work, and the failure is silent:
# the slug is keyed on the directory Claude Code was LAUNCHED from, not on the repo root.
# Measured on the machine this was written on: 26 project slugs, and not one of them
# contains "forgeward" -- every transcript for this repo lives under the slug of its
# PARENT directory, because that is where the session started. A per-repo audit would
# have reported a clean sweep for the very repo it shipped in. `--project` narrows it for
# someone who knows their slug; nothing derives one for you.
#
# WHAT IT STRUCTURALLY CANNOT SEE:
#   - any credential with no distinctive prefix: a bare bearer token, an opaque session
#     cookie, a password that is not inside a connection URL. The pattern set covers ten
#     shapes and there is no eleventh it can infer.
#   - anything Claude Code has already reaped. `cleanupPeriodDays` defaults to 30 and the
#     unit deleted is the SESSION DIRECTORY, aged by the parent's recency rather than per
#     file -- so a short-lived session's evidence is gone inside the month while a busy
#     session's subagent transcripts outlive it. One AKIA-shaped finding was lost this way
#     between two consecutive days, at age 31, before it could be re-read.
#   - whether a match is a real credential. It matches SHAPES.
#
# WHAT IT MUST NOT BE READ AS. A repository whose own documentation contains
# credential-shaped literals will match, and that is correct behaviour rather than a bug
# to filter out: forgeward-gate's own README carries `AKIA[0-9A-Z]{16}` as a literal, so
# any machine that has worked on this repo has transcripts that hit. Deliberately NOT
# filtered -- excluding by content is the narrowing that caused the defect this tool was
# built for, and a filter that hides documentation would hide the same string in a real
# leak. Read the filenames; that is why filenames are the output.
#
# EXIT CODES:  0 no prefixed match   1 a prefixed shape matched   2 nothing to search
#              64 usage error
# The URL-password pattern is advisory and never sets exit 1 -- it is noisy enough that
# doing so would make the script permanently red and therefore permanently ignored. A
# zero is "none of these ten shapes, in what still exists". It is never "clean".
set -uo pipefail

# Locale-pinned repo-wide, not per-effect -- see CLAUDE.md. grep's character classes and
# its handling of invalid UTF-8 both move with the locale, and a transcript is arbitrary
# tool output: it routinely contains bytes that are not valid UTF-8, which under a UTF-8
# locale can make GNU grep skip a whole file as binary and report nothing.
export LC_ALL=C

ROOT="${HOME}/.claude/projects"
PROJECT=""
SHOW_URLS=0

# The ten prefixed shapes, kept in ONE array so the audit and `--patterns` cannot drift.
# Every one is passed to grep with -e, and for the PEM entry that is load-bearing rather
# than stylistic: it begins with `-`, so without -e grep parses it as a flag and dies.
PATTERNS=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'AKIA[0-9A-Z]{16}'
  'ghp_[A-Za-z0-9]{36}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'sk-ant-[A-Za-z0-9_-]{20,}'
  'sk-proj-[A-Za-z0-9_-]{20,}'
  '[sr]k_(live|test)_[A-Za-z0-9]{20,}'
  'AIza[0-9A-Za-z_-]{35}'
  'npm_[A-Za-z0-9]{36}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
)

# Kept OUT of the array above on purpose. On the machine the original defect was found
# on it matched 201 files against 15 for all ten prefixed shapes combined, and folding it
# in buries three private-key hits under two hundred `https://user:pass@` strings from
# documentation. Reported as a count always, listed only under --urls.
URL_PATTERN='://[^:/@[:space:]]+:[^@/[:space:]]+@'

# Printed after EVERY filename list this script emits, which is the whole reason it is a
# function: the first version of this warning sat under the prefixed-shape list only, and
# `--urls` printed a second list of the same slug-bearing paths with no warning at all.
# One list warned and one not is worse than neither, because it reads as a considered
# distinction. Raised by the privacy review of the commit that added the warning.
redact_note() {
  printf '\n  REDACT BEFORE PASTING. These paths are not the credential, but they are not\n'
  printf '  nothing either: a project slug is a directory path with the punctuation\n'
  printf '  flattened, so it carries your home-directory name and your repo or client\n'
  printf '  names. The likely next step after a hit is pasting this list into an issue,\n'
  printf '  a chat, or a prompt -- all of which publish that to someone who was not\n'
  printf '  going to see it.\n'
}

usage() {
  cat >&2 <<'EOF'
usage: forgeward-transcript-audit.sh [--root DIR] [--project SLUG] [--urls] [--patterns]

  --root DIR       search DIR instead of ~/.claude/projects
  --project SLUG   restrict to one project slug (no slug is derived for you -- see the
                   header: the slug follows the launch directory, not the repo root)
  --urls           also list the files matching the URL-embedded-password pattern,
                   which is noisy by design and is otherwise reported as a count only
  --patterns       print the pattern set and exit, so you can extend it for your stack
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root)    ROOT="${2:-}"; [ -n "$ROOT" ] || { usage; exit 64; }; shift 2 ;;
    --project) PROJECT="${2:-}"; [ -n "$PROJECT" ] || { usage; exit 64; }; shift 2 ;;
    --urls)    SHOW_URLS=1; shift ;;
    --patterns)
      printf 'forgeward-transcript-audit: %d prefixed shapes\n' "${#PATTERNS[@]}"
      printf '  %s\n' "${PATTERNS[@]}"
      printf 'plus, reported separately:\n  %s\n' "$URL_PATTERN"
      exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *)         printf 'forgeward-transcript-audit: unknown argument %s\n' "$1" >&2; usage; exit 64 ;;
  esac
done

TARGET="$ROOT"
[ -n "$PROJECT" ] && TARGET="$ROOT/$PROJECT"

if [ ! -d "$TARGET" ]; then
  printf 'forgeward-transcript-audit: no such directory: %s\n' "$TARGET" >&2
  printf '  Nothing was searched. This is NOT a clean result.\n' >&2
  [ -n "$PROJECT" ] && printf '  A slug that does not exist looks exactly like a project with no findings.\n' >&2
  exit 2
fi

# Counted BEFORE grepping so an empty finding list can be reported against a denominator.
# "0 hits" and "0 hits over 12 480 files" are different claims and only the second one is
# worth anything to the person reading it.
files_scanned="$(find "$TARGET" -type f 2>/dev/null | wc -l | tr -d ' ')"
sessions="$(find "$TARGET" -mindepth 1 -maxdepth 2 -type d -name '*-*-*-*-*' 2>/dev/null | wc -l | tr -d ' ')"

printf 'forgeward transcript audit\n'
printf '  scope    %s\n' "$TARGET"
printf '  files    %s across %s session directories\n' "$files_scanned" "$sessions"

if [ "$files_scanned" -eq 0 ]; then
  printf '  RESULT   nothing to search -- 0 files under that path.\n'
  printf '           An empty tree is UNVERIFIABLE, not clean: Claude Code reaps whole\n'
  printf '           session directories on cleanupPeriodDays (default 30).\n'
  exit 2
fi

# -l for filenames only: this must not put a value back on the screen. -I skips files
# grep considers binary rather than printing a "binary file matches" line for them.
grep_args=()
for p in "${PATTERNS[@]}"; do grep_args+=(-e "$p"); done
hits="$(grep -rlIE "${grep_args[@]}" "$TARGET" 2>/dev/null || true)"
url_hits="$(grep -rlIE -e "$URL_PATTERN" "$TARGET" 2>/dev/null || true)"

n_hits=0;     [ -n "$hits" ]     && n_hits="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
n_url=0;      [ -n "$url_hits" ] && n_url="$(printf '%s\n' "$url_hits" | wc -l | tr -d ' ')"

printf '\nPREFIXED CREDENTIAL SHAPES (%d patterns): %s file(s)\n' "${#PATTERNS[@]}" "$n_hits"
if [ "$n_hits" -gt 0 ]; then
  printf '%s\n' "$hits" | sed 's/^/  /'
  redact_note
  # Which SHAPE matched is metadata, and it is the difference between "go look at this
  # today" and "skim it". Re-grepped over the hit list only -- a handful of files, not
  # the whole tree -- so this costs nothing next to the sweep that produced the list.
  printf '\n  by shape:\n'
  for p in "${PATTERNS[@]}"; do
    c="$(printf '%s\n' "$hits" | tr '\n' '\0' | xargs -0 -r grep -lIE -e "$p" 2>/dev/null | wc -l | tr -d ' ')"
    [ "$c" -gt 0 ] && printf '  %5s  %s\n' "$c" "$p"
  done
  printf '\n  Filenames and shapes only -- open them yourself. Some will be documentation\n'
  printf '  quoting a pattern; that is not filtered, because filtering by content is what\n'
  printf '  caused the defect this tool audits.\n'
fi

printf '\nPASSWORD IN A CONNECTION URL: %s file(s)\n' "$n_url"
if [ "$n_url" -gt 0 ] && [ "$SHOW_URLS" -eq 1 ]; then
  printf '%s\n' "$url_hits" | sed 's/^/  /'
  redact_note
elif [ "$n_url" -gt 0 ]; then
  printf '  Count only -- this pattern is noisy by design (measured 201 files against 15\n'
  printf '  for all ten prefixed shapes combined). Re-run with --urls to list them.\n'
fi

# The permissions finding. Cheap, independent of any pattern, and nobody runs it by hand:
# on the machine the defect was found on, 279 of 279 tool-results/*.txt were mode 0644
# against 1878 of 1879 transcripts at 0600 -- so the copy easiest to MISS is also, as a
# rule, the copy any other local account can read. A count, not a verdict: a single-user
# machine may not care, and this script does not chmod anything it did not create.
#
# `stat -c` is GNU-specific. On BSD and macOS the flag does not exist, every call fails,
# and the loop would report a confident 0 -- which is the exact false-clean shape this
# whole script exists to argue against. So the mode is probed once and an unusable stat
# is reported as UNAVAILABLE rather than as a count.
world=0
stat_ok=0
probe="$(find "$TARGET" -type f -print -quit 2>/dev/null)"
if [ -n "$probe" ] && stat -c '%a' "$probe" >/dev/null 2>&1; then stat_ok=1; fi

if [ "$stat_ok" -eq 1 ]; then
  while IFS= read -r f; do
    m="$(stat -c '%a' "$f" 2>/dev/null || true)"
    case "$m" in ''|*[!0-9]*) continue ;; esac
    [ "$(( 8#$m & 8#077 ))" -ne 0 ] && world=$((world + 1))
  done < <(find "$TARGET" -type f -path '*/tool-results/*' 2>/dev/null)
  printf '\nGROUP/OTHER-READABLE tool-results files: %s\n' "$world"
else
  printf '\nGROUP/OTHER-READABLE tool-results files: UNAVAILABLE\n'
  printf '  stat -c is GNU-only and this platform does not have it (BSD, macOS). Not\n'
  printf '  zero -- unmeasured. The BSD equivalent is: stat -f %%Lp <file>\n'
fi

printf '\nWHAT THIS RUN DID NOT ESTABLISH\n'
printf '  - A zero above means "none of these ten shapes", never "nothing was exposed".\n'
printf '    Any credential without a distinctive prefix cannot match. Add your own with\n'
printf '    --patterns as the starting list.\n'
printf '  - It cannot see what has already been deleted. cleanupPeriodDays defaults to 30\n'
printf '    and reaps the whole session directory, aged by the parent, so a short session\n'
printf '    is gone inside the month. An empty result is UNVERIFIABLE, not safe.\n'
printf '  - If you ran forgeward 0.2.0 through 0.9.1 in a repo holding an untracked\n'
printf '    credential file, ROTATE regardless of what this printed.\n'
printf '  - The permissions count needs GNU stat. Where it reads UNAVAILABLE above,\n'
printf '    nothing about file modes was checked at all.\n'

[ "$n_hits" -gt 0 ] && exit 1
exit 0
