#!/usr/bin/env bash
# forgeward-scan.sh <tool> [args...]
#
# Run a deterministic scanner for a forgeward reviewer with its report on STDOUT,
# nothing left behind in the repository under review, and nothing read out of it that
# the review does not cover. Reviewers are read-only; this is the invocation that makes
# that true instead of merely asking for it.
#
# READ-ONLY CUTS BOTH WAYS. Layers 1-3 stop a scanner WRITING into the repo. Layer 4
# stops a secrets scanner READING files the review has no business seeing — because a
# secret scanner's output is itself secret-bearing, and a reviewer subagent's stdout
# becomes a persisted transcript on disk.
#
# WHY THIS EXISTS. security-reviewer twice created a `C:` directory tree at the root
# of the repo it was auditing (on-disk `C` + U+F03A) by passing a Windows scratch
# path to a scanner's output flag from a POSIX shell, where `C:/Users/...` is a
# RELATIVE path. The second occurrence happened with a spawn prompt that explicitly
# told the agent to write artifacts outside the repository — so a prompt-level
# instruction is demonstrably not a fix. Enforcement has to sit in the invocation.
#
# FOUR LAYERS, narrowest first:
#   1. Refuse a known output-file flag outright. Scanner output belongs on stdout;
#      the reviewer reads it there. This is the layer that removes the affordance.
#   2. Refuse any drive-letter argument (`C:/…`, `D:\…`). In a POSIX shell that is
#      never a valid absolute path, whatever flag it follows.
#   3. Diff the repo's untracked set across the run and REPORT anything new on stderr,
#      naming the drive-letter shape specifically and printing the exact removal
#      command. It never deletes — see the hazard note below.
#   4. Constrain the gitleaks SCAN TARGET: `gitleaks dir` must name exactly one existing
#      regular file that git already tracks. See the long note above `_gl_target_guard`.
#
# WHY LAYER 3 REPORTS AND DOES NOT DELETE. Auto-removing the tree it just watched a
# scanner create looks obviously safe and is not: on Git Bash, the contaminated
# directory is named `C` + U+F03A, which the MSYS runtime maps back to `C:` — and
# `readlink -f "C:"` there resolves to `C:/`, THE DRIVE ROOT (verified). An
# `rm -rf "$top"` in this script would have targeted the user's entire C: drive on
# exactly the platform where this bug occurs. Only the `./`-prefixed form
# (`rm -rf -- "./C:"`) stays relative, so that is what gets printed for the user to
# run deliberately. Do not "improve" this into an automatic delete.
#
# NON-GOALS / BLIND SPOTS, stated so the absence of a limit is not read as coverage:
#   - It does not sandbox the tool. A scanner with a hardcoded output path, or one
#     writing through a config file, still writes; layer 3 reports it, layer 1 cannot
#     see it.
#   - The output-flag list is an enumeration, not a rule. A tool with an unusual
#     output flag (or a bare `-r`, which means "recursive" in some tools and
#     "report path" in others) passes layer 1. Layers 2 and 3 are the net.
#   - It has no opinion on what the scanner reports; it never fails a scan.
#   - The per-tool `-o` exemption below trusts `basename "$tool"`, not the identity of
#     the binary that runs. An executable named `grype` that is not grype inherits it,
#     and could write a file named after one of the ~30 enumerated format words. Not
#     closed on purpose: this script runs `"$tool" "$@"`, so anyone able to place that
#     executable already has code execution here — the write is strictly weaker than
#     what they already hold, and probing `--version` would not help, since a spoofed
#     binary can print anything. Layer 3 still reports the result.
#   - Layer 4 is GITLEAKS-ONLY and is not a general "no directory targets" rule. These
#     stay allowed and must: `trivy fs .` and `semgrep scan <many files>` (a directory
#     or a path list is the correct target there), and `gitleaks git <repo>` (its target
#     is a commit range — untracked files are structurally out of scope), including with
#     no `--log-opts`, because auditing a repo's whole history for leaked secrets is a
#     legitimate thing to want.
#   - Layer 4 uses TRACKED as a proxy for "in the reviewed diff", which this script
#     cannot see: it gets an argv, not a base ref. A tracked file the diff never touched
#     passes. Diff scoping is the reviewer's job; this only removes the untracked-file
#     read that no diff could ever justify.
#   - Layer 4 tests `-f`, which is true for a symlink to a file. A tracked symlink
#     pointing outside the repo passes, and with `--follow-symlinks` gitleaks reads the
#     target. Not covered.
#   - Layer 4's tracked check needs a work tree. Run with a cwd outside any repo, only
#     the one-regular-file rule applies and ANY readable file passes. Not a live hole —
#     the reviewer always runs inside the repo under review, and layer 3's untracked
#     snapshot assumes the same — but it is a limit, so it is named here rather than
#     only inline at the check.
#   - `stdin` mode is allowed with nothing to guard, because there is no path token to
#     check. Nothing here can stop a caller piping untracked content in by hand
#     (`cat .env | forgeward-scan.sh gitleaks stdin`). That one is held by the
#     reviewers' standing instruction never to read a credential file, which is prose,
#     not a control — an argv wrapper structurally cannot see a pipe.
#   - Layer 1 matches flag TOKENS, so it does not see inside a flag's VALUE. Verified:
#     `gitleaks git --log-opts="--output=x"` forwards `--output` to `git log` and the
#     file IS written, because the token begins `--log-opts`, not `--output`. Layer 3
#     catches it — the run exits 3 with the new path named — so this is loud, not
#     silent, and that containment is the whole reason layer 3 exists. Named here
#     because `--log-opts` is the flag the reviewers are now told to use.
#   - Layer 4 checks the target, then the tool opens it: a TOCTOU window. Anything with
#     concurrent write access to that exact path can swap a tracked file for a symlink
#     to an untracked one in between. Deliberately not closed — that attacker already
#     has local write access to the repo, which is a far stronger primitive than the
#     thing this guard exists to stop (a reviewer aiming a scanner at the wrong path).
#
# Exit codes: the tool's own, so `--error`-style "findings found" codes survive — except
# that a tool exiting 0 after leaving new untracked paths in the repo becomes 3, so
# contamination cannot read as success to a caller that checks only `$?`.
set -uo pipefail

# Locale-pinned repo-wide, not per-effect — see CLAUDE.md. A non-interactive script
# must not have its behaviour depend on the invoker's environment: character classes,
# collation and grep's handling of invalid UTF-8 all move with the locale, and the
# last one was a complete bypass of an ambiguity guard before it was pinned.
export LC_ALL=C

tool="${1:-}"
[ -n "$tool" ] || { printf 'usage: forgeward-scan.sh <tool> [args...]\n' >&2; exit 64; }
shift

reject() { printf 'forgeward-scan: %s\n' "$1" >&2; exit 2; }

# Is $1 a destination PATH rather than a format token? `-o json` (grype, syft) selects
# a format and still writes to stdout; `-o out.json`, `-o myreport`, `-o C:/…` all write
# a file. DENY BY DEFAULT: anything that is not a recognized format word is treated as a
# destination. The earlier form did the opposite — it only refused values containing a
# slash or a known extension, so a bare `-o myreport` sailed through and created
# ./myreport in the repo. Erring toward refusal costs a reviewer one corrected command;
# erring the other way writes into the repo under review.
# WHETHER `-o <word>` IS A FORMAT OR A FILENAME IS A PER-TOOL FACT, NOT A GENERAL ONE.
# grype and syft OVERLOAD `-o`: `-o json` prints to stdout, `-o json=file` writes. But
# trivy's own help reads `-o, --output string   output file name`, with `-f, --format`
# separate — so `trivy -f json -o json .` writes a file literally named `json`. semgrep
# and gitleaks behave the same way. Treating the allowlist as tool-agnostic turned every
# format word into a writable filename for three of the four scanners this wrapper
# exists to guard, and the suite asserted that as correct. The exception now applies
# only to tools that actually overload the flag; everywhere else an output flag's value
# is a destination, full stop.
_tool_base="$(basename -- "$tool")"
case "$_tool_base" in
  grype|syft|grype.exe|syft.exe) _O_IS_FORMAT=1 ;;
  *)                             _O_IS_FORMAT=0 ;;
esac

# Short `-r` is PER-TOOL too, and in the opposite direction. The header lists a bare
# `-r` as a stated blind spot because it means "recursive" in some tools — true in
# general, false for gitleaks, whose own help reads `-r, --report-path string  report
# file`. The long form is enumerated below and the short one was not, so `gitleaks dir x
# -r evil.json` reached the same write the `--report-path` case exists to refuse, by the
# short spelling. Closed for gitleaks only; every other tool keeps `-r` untouched.
case "$_tool_base" in
  gitleaks|gitleaks.exe) _R_IS_REPORT=1 ;;
  *)                     _R_IS_REPORT=0 ;;
esac

# NOTE the newline normalization below. This list wraps across source lines, so the
# wrap points are literal newlines in the value, and a `*" $1 "*` test against the raw
# string silently fails for whichever words sit against a wrap — `yml`, `cyclonedx`,
# `compact` and `full` were all being treated as destination paths. Normalize first.
_FORMAT_WORDS=" json sarif table text template junit xml csv html markdown md yaml yml
cyclonedx spdx spdx-json github gitlab gitlab-codequality sonarqube emacs vim compact
full summary checkstyle codeclimate pretty plain quiet verbose "
looks_like_path() {
  case "$1" in
    "") return 1 ;;                                   # empty: not a path
    -)  return 1 ;;                                   # bare '-' is stdout — the ONE
                                                      # dash-led value that is not a file
  esac
  # Everything else dash-led IS checked. An earlier version short-circuited on `-*`
  # ("that's another flag, not this flag's value"), which is not true of getopt-family
  # parsers: pflag/Cobra — what gitleaks and trivy use — consume the next token as the
  # value unconditionally. `gitleaks dir . --report-path -evil.json` was passed straight
  # through and gitleaks wrote `-evil.json` into the repo under review. Verified.
  # Cost of the stricter rule: a malformed `--output --json` now gets refused instead of
  # ignored. That fails closed on a command that was broken anyway.
  if [ "$_O_IS_FORMAT" = 1 ]; then
    case " ${_FORMAT_WORDS//[$'\n\t']/ } " in
      *" $1 "*) return 1 ;;                           # this tool overloads -o: a bare
                                                      # format word stays on stdout
    esac
  fi
  return 0
}
out_reject() {
  reject "refusing '$1 $2': a read-only reviewer must not write scanner artifacts. Drop the flag and capture the report from STDOUT (add --json / --format json and read the output). If a file is genuinely unavoidable, put it under \$(forgeward-artifact-dir.sh), never a path inside the repo."
}

expect_path=""
for a in "$@"; do
  # A drive-letter path at a real path BOUNDARY: token start, after a '/', or right
  # after a flag (`-oC:/x` is ONE argv token, which is how the cuddled short form —
  # a standard getopt convention — slipped past a start-anchored pattern).
  #
  # Anchored on purpose. A fully unanchored `*[A-Za-z]:[\/]*` also matches any token
  # with a letter before "://" or ":/" — `--config https://semgrep.dev/p/ci`, and
  # syft/grype source specifiers like `dir:/repo` and `oci-dir:/img`. Those are
  # legitimate scanner arguments, and refusing them is friction that pushes a reviewer
  # to bypass this wrapper entirely, which costs more than the shape it was catching.
  # `:` is a flag/value separator too (`--output:C:/x`, the MSBuild/dotnet/PowerShell
  # convention), so it is accepted everywhere `=` is. Handling only `=` left every
  # ENUMERATED output flag reachable by an alternate separator — not an unlisted flag,
  # which is a stated non-goal, but a listed one through a side door.
  case "$a" in
    [A-Za-z]:[\\/]*|*/[A-Za-z]:[\\/]*|*[:=][A-Za-z]:[\\/]*)
      reject "refusing the drive-letter path in '$a': this shell is POSIX (Git Bash / WSL / Cygwin), where 'C:/…' is a RELATIVE path — it creates a 'C:' directory tree inside the repo under review. Capture the report from STDOUT instead; if a file is genuinely unavoidable, use a POSIX-absolute path from forgeward-artifact-dir.sh." ;;
  esac
  if [ "${a#-}" != "$a" ] && [[ "$a" =~ ^-[A-Za-z-]*[:=]?[\"\']?[A-Za-z]:[\\/] ]]; then
    reject "refusing the drive-letter path cuddled onto '${a%%[A-Za-z]:*}' in '$a': this shell is POSIX (Git Bash / WSL / Cygwin), where 'C:/…' is a RELATIVE path — it creates a 'C:' directory tree inside the repo under review. Capture the report from STDOUT instead; if a file is genuinely unavoidable, use a POSIX-absolute path from forgeward-artifact-dir.sh."
  fi

  if [ -n "$expect_path" ]; then
    looks_like_path "$a" && out_reject "$expect_path" "$a"
    expect_path=""
  fi
  if [ "$_R_IS_REPORT" = 1 ]; then
    case "$a" in
      -r)   expect_path="$a"; continue ;;
      -r?*) looks_like_path "${a#-r}" && out_reject "-r" "${a#-r}"; continue ;;
    esac
  fi
  case "$a" in
    -o|--output|--output-file|--outfile|--report-file|--report-path|--sarif-output|--json-output|--sarif-file|--out-file)
      expect_path="$a"; continue ;;
    --output[:=]*|--output-file[:=]*|--outfile[:=]*|--report-file[:=]*|--report-path[:=]*|--sarif-output[:=]*|--json-output[:=]*|--sarif-file[:=]*|--out-file[:=]*)
      looks_like_path "${a#*[:=]}" && out_reject "${a%%[:=]*}" "${a#*[:=]}" ;;
    # Cuddled short form: `-oREPORT`, `-oout.json`. Single token, so it matches none of
    # the patterns above.
    -o?*)
      looks_like_path "${a#-o}" && out_reject "-o" "${a#-o}" ;;
  esac
done

# ---- Layer 4: the gitleaks SCAN TARGET ---------------------------------------------
#
# WHY. `gitleaks dir` is a FILESYSTEM walk. It reads whatever is under the target,
# tracked or not. Point it at a directory and it reads the developer's local, gitignored
# `.env` — a file that by definition was never committed, so it cannot be the leak
# gitleaks exists to catch.
#
# Whether the VALUE then reaches stdout is an output-mode question, and the answer is
# "yes in every mode a reviewer can actually use". Verified on 8.30.1: `--no-banner`
# alone prints counts only, while `-v` prints `Secret: <value>` and `-f json -r -` prints
# `"Secret": "<value>"`. A reviewer needs one of the latter two to report `file:line` at
# all, so the count-only mode is not a mitigation — it is a mode in which the reviewer
# cannot do its job. For a reviewer subagent that stdout becomes context and then a
# PERSISTED transcript under ~/.claude/projects/<project>/<session>/subagents/agent-*.jsonl: outside the
# repo, outside every cleanup this plugin performs, and outside the user's line of sight.
# Observed on a real gate run — a private key plus three service credentials from an
# untracked `.env` were read and written to disk that way. The reviewer kept them out of
# its returned report; the transcript still held them. `--redact` fixes the value half
# and this guard fixes the read half; neither is sufficient alone.
#
# TWO DEFECTS, AND THE FIRST ONE HID THE SECOND. gitleaks takes exactly ONE positional
# path, and the reviewer's documented invocation passed the whole changed-path list:
#
#   cmd/directory.go, v8.30.1:
#     source := "."
#     if len(args) == 1 { source = args[0]; if source == "" { source = "." } }
#
# There is no cobra `Args` validator, so a second positional is not an error — `len(args)`
# is simply != 1 and `source` STAYS ".", the current working directory. `gitleaks dir
# app.php TODOS.md` scans the entire working tree while reading like a two-file scan.
# Verified against the real binary (8.30.1): one path scanned 15 bytes, two paths scanned
# 176 — byte-identical to `gitleaks dir .`, and from a parent directory the two-path form
# reported the leaks in a gitignored `.env` two levels down.
#
# THE LINE IS TRACKED VS UNTRACKED, NOT THE FILENAME. A blanket `.env` exclusion would be
# the wrong fix: a COMMITTED `.env` is a genuine, valuable gitleaks finding and must keep
# firing. It does — it is tracked, so it passes this guard and gets scanned.
#
# FAILS CLOSED, IN BOTH DIRECTIONS. The parse below skips flag values using an enumerated
# table of gitleaks' value-taking flags, and an unlisted one is the only way this parse
# can diverge from cobra's. After the subcommand that direction is already safe: the
# stray value looks like a positional, the count hits 2, and the command is refused.
# BEFORE the subcommand it is not — `gitleaks --unlisted V dir .` would make `V` look
# like the subcommand, so a naive "pos[0] is not dir, nothing to guard" would wave the
# directory scan straight through. So the subcommand itself is checked against an
# enumerated set and anything unrecognized is REFUSED rather than assumed harmless.
# Cost: a future gitleaks subcommand, and the pre-8.19 `detect`/`protect`, need a line
# added here. `detect --no-git` is this same filesystem walk under the old name, so
# refusing it until someone looks is the right default.
_gl_target_guard() {
  local a skip=0 endflags=0
  local -a pos=()
  for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    if [ "$endflags" = 0 ]; then
      case "$a" in
        --) endflags=1; continue ;;
        # Value-taking flags, space-separated form, from `gitleaks --help` + the `git`
        # subcommand's own. `--redact` is deliberately ABSENT: it is `uint[=100]`, so a
        # bare `--redact` takes no following token (verified — `gitleaks dir --redact
        # app.php` scanned app.php, not the tree).
        --baseline-path|--config|--diagnostics|--diagnostics-dir|--enable-rule\
        |--exit-code|--gitleaks-ignore-path|--log-level|--max-archive-depth\
        |--max-decode-depth|--max-target-megabytes|--report-format|--report-path\
        |--report-template|--timeout|--log-opts|--platform\
        |-b|-c|-i|-l|-f|-r)
          skip=1; continue ;;
        -*) continue ;;
      esac
    fi
    pos+=("$a")
  done

  # pos[0] is the subcommand, exactly as cobra resolves it: the first positional.
  [ "${#pos[@]}" -ge 1 ] || return 0            # `--version`, `--help`, bare: nothing to guard
  case "${pos[0]}" in
    dir|file|directory) ;;                      # the filesystem-walk family, and its aliases
    git|stdin|version|completion|help)
      return 0 ;;                               # 8.30.1's other subcommands: no filesystem
                                                # target to constrain. `git`'s target is a
                                                # commit range; `stdin` reads a pipe.
    *) reject "refusing 'gitleaks ${pos[0]}': unrecognized subcommand, so this wrapper cannot tell whether it walks the filesystem, and it will not assume. Recognized: dir/file/directory (guarded to one tracked file), git, stdin, version, completion, help. If this is a real gitleaks subcommand, add it to _gl_target_guard with a decision about its target — note that pre-8.19 'detect --no-git' is the same filesystem walk under an older name." ;;
  esac

  if [ "${#pos[@]}" -ne 2 ]; then
    reject "refusing 'gitleaks ${pos[0]}' with $(( ${#pos[@]} - 1 )) target paths: it takes exactly ONE, and given any other number it does NOT error — it silently scans the whole current directory instead (cmd/directory.go: \`source := \".\"; if len(args) == 1 {…}\`). That reads untracked, gitignored files such as a local .env and prints their values into your transcript. Scan the commit range instead — 'gitleaks git --log-opts=\"<base>...HEAD\" --no-banner --redact -f json -r -' — or run ONE invocation per changed file."
  fi

  local target="${pos[1]}"
  [ -f "$target" ] || reject "refusing 'gitleaks ${pos[0]} $target': the target must be an existing regular FILE. A directory target makes this a filesystem walk that reads untracked, gitignored files — a local .env is never the leak gitleaks exists to catch, and its values would land in your transcript. Scan the commit range instead: 'gitleaks git --log-opts=\"<base>...HEAD\" --no-banner --redact -f json -r -'."

  # Only meaningful inside a work tree. Outside one there is no tracked set to consult,
  # so the one-regular-file rule above stands alone.
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files --error-unmatch -- "$target" >/dev/null 2>&1 || \
      reject "refusing 'gitleaks ${pos[0]} $target': that file is NOT tracked by git. An untracked file was never published, so it cannot be the leak gitleaks exists to catch — but scanning it puts its plaintext values in your transcript, which is worse than the finding is worth. Scan only paths in the reviewed diff. (A COMMITTED .env is tracked, is a real finding, and is deliberately still scanned.)"
  fi
}
case "$_tool_base" in
  gitleaks|gitleaks.exe) _gl_target_guard "$@" ;;
esac

# Untracked-set snapshot, so layer 3 can attribute what this run created.
snap() { git -c core.quotepath=false status --porcelain --untracked-files=all 2>/dev/null | sed 's/^...//' | sort; }
before="$(snap)"

command -v "$tool" >/dev/null 2>&1 || {
  printf 'forgeward-scan: %s not installed (skipped)\n' "$tool" >&2; exit 127; }

"$tool" "$@"
rc=$?

after="$(snap)"
if [ "$before" != "$after" ]; then
  new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") 2>/dev/null || true)"
  drive=""
  printed=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$printed" = 0 ] && {
      # shellcheck disable=SC2016  # the backticks are prose the user reads, not a substitution
      printf 'forgeward-scan: this scan left new untracked paths in the repo under review; a read-only reviewer must not. Delete them before committing — `git add -A` would commit them:\n' >&2
      printed=1
    }
    printf '  %s\n' "$p" >&2
    case "${p%%/*}" in                  # first path component
      [A-Za-z]:|*$'\xef\x80\xba'*)      # 'C:' as MSYS/WSL show it, or its raw U+F03A byte form
        drive="${p%%/*}" ;;
    esac
  done <<EOF
$new
EOF
  [ -n "$drive" ] && printf 'forgeward-scan: '\''%s'\'' is the POSIX/Windows path-translation bug — the scan was handed a drive-letter path, which is RELATIVE in this shell, so it landed as a directory tree in the repo. Remove it with the leading "./" (see below) and re-run with the report on stdout.\n  rm -rf -- "./%s"\n' "$drive" "$drive" >&2
  # Contamination must not read as success. A scanner that finds nothing exits 0, so a
  # caller checking only $? would see a clean run while the repo has just been written
  # to. Signal it with a distinct code, but never mask a real tool failure: a non-zero
  # tool exit is preserved, because the caller already knows something went wrong.
  [ "$rc" = 0 ] && rc=3
fi

exit "$rc"
