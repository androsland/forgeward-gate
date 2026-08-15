#!/usr/bin/env bash
# forgeward-artifact-dir.sh
#
# Print a POSIX-absolute scratch directory, created if needed, that is guaranteed
# to be OUTSIDE the repository under review. Reviewers are read-only: if one truly
# needs a file on disk (a scanner that cannot write to stdout, an intermediate the
# reviewer re-reads), it goes here — never into the repo it is auditing.
#
# THE PROBLEM THIS SOLVES. A reviewer running under Git Bash was handed a Windows
# scratch path (`C:\Users\...\scratchpad`) and passed it to a scanner as an output
# path. Under a POSIX shell `C:/Users/...` is a RELATIVE path, so the scanner
# created a `C:` directory tree at the root of the repo under review — on-disk name
# `C` + U+F03A (43 EF 80 BA), the private-use colon substitute MSYS/Cygwin uses.
# Untracked, matched by no common .gitignore, so `git add -A` commits the reviewer's
# scratch tree into the user's repository.
#
# So the rule is not "use a scratch dir" — it is "use a path that is absolute IN THE
# SHELL THAT WILL OPEN IT". This script only ever emits such a path: a drive-letter
# candidate is translated with `cygpath -u` when available and discarded otherwise.
#
# Override the root with FORGEWARD_ARTIFACT_ROOT. Everything is per-process
# (`$$`), so concurrent gates never share a directory.
#
# LIMITATION: this hands out a safe path; it cannot make a tool use it. A scanner
# invoked with its own hardcoded output path ignores this entirely. That gap is
# covered from the other side by forgeward-scan.sh (which refuses output-file flags
# and cleans up what a scan leaves behind) and forgeward-workspace-guard.sh (which
# detects contamination after the fact, whatever produced it).
set -uo pipefail

# Locale-pinned repo-wide, not per-effect — see CLAUDE.md. A non-interactive script
# must not have its behaviour depend on the invoker's environment: character classes,
# collation and grep's handling of invalid UTF-8 all move with the locale, and the
# last one was a complete bypass of an ambiguity guard before it was pinned.
export LC_ALL=C

# Emit $1 as a POSIX-absolute path, or nothing if it cannot be one here.
posixify() {
  case "$1" in
    [A-Za-z]:[\\/]*)
      command -v cygpath >/dev/null 2>&1 && cygpath -u "$1" 2>/dev/null
      ;;
    /*) printf '%s' "$1" ;;
  esac
}

root=""
for cand in "${FORGEWARD_ARTIFACT_ROOT:-}" "${TMPDIR:-}" "${TMP:-}" "${TEMP:-}" /tmp; do
  [ -n "$cand" ] || continue
  p="$(posixify "$cand")"
  [ -n "$p" ] || continue
  root="${p%/}"
  break
done
[ -n "$root" ] || root=/tmp

# Never hand back a directory inside the repo under review, however TMPDIR is set.
# Normalize the toplevel too: under Git Bash `git rev-parse --show-toplevel` answers in
# Windows form (C:/Users/…), which would never textually match a POSIX $root.
top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$top" ]; then
  top_posix="$(posixify "$top")"
  [ -n "$top_posix" ] && top="$top_posix"
  case "$root/" in "${top%/}"/*) root=/tmp ;; esac
fi

dir="$root/forgeward-artifacts/$$"
mkdir -p "$dir" 2>/dev/null || { dir="/tmp/forgeward-artifacts/$$"; mkdir -p "$dir" || exit 1; }
printf '%s\n' "$dir"
