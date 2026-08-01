#!/usr/bin/env bash
# forgeward-scan.sh <tool> [args...]
#
# Run a deterministic scanner for a forgeward reviewer with its report on STDOUT and
# nothing left behind in the repository under review. Reviewers are read-only; this
# is the invocation that makes that true instead of merely asking for it.
#
# WHY THIS EXISTS. security-reviewer twice created a `C:` directory tree at the root
# of the repo it was auditing (on-disk `C` + U+F03A) by passing a Windows scratch
# path to a scanner's output flag from a POSIX shell, where `C:/Users/...` is a
# RELATIVE path. The second occurrence happened with a spawn prompt that explicitly
# told the agent to write artifacts outside the repository — so a prompt-level
# instruction is demonstrably not a fix. Enforcement has to sit in the invocation.
#
# THREE LAYERS, narrowest first:
#   1. Refuse a known output-file flag outright. Scanner output belongs on stdout;
#      the reviewer reads it there. This is the layer that removes the affordance.
#   2. Refuse any drive-letter argument (`C:/…`, `D:\…`). In a POSIX shell that is
#      never a valid absolute path, whatever flag it follows.
#   3. Diff the repo's untracked set across the run and REPORT anything new on stderr,
#      naming the drive-letter shape specifically and printing the exact removal
#      command. It never deletes — see the hazard note below.
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
#
# Exit codes: the tool's own, so `--error`-style "findings found" codes survive — except
# that a tool exiting 0 after leaving new untracked paths in the repo becomes 3, so
# contamination cannot read as success to a caller that checks only `$?`.
set -uo pipefail

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
case "$(basename -- "$tool")" in
  grype|syft) _O_IS_FORMAT=1 ;;
  *)          _O_IS_FORMAT=0 ;;
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
