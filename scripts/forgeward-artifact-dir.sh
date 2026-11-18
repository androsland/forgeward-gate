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
# Windows form (C:/Users/…), which would never textually match a POSIX $root. Then compare
# PHYSICAL paths: a symlink alias or a `..` in the root passes a text comparison and lands
# inside the tree, where the gate's own snapshot would read as a changed path every run.
# A root that does not exist yet cannot be resolved, so it cannot be shown to be outside,
# and creating it to find out could create it inside the repo: fall back to /tmp.
# The directory handed out is checked as well as the root (below): a symlinked
# `<root>/forgeward-artifacts` would otherwise land inside the repo.
phys() { (cd "$1" 2>/dev/null && pwd -P); }
top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$top" ]; then
  top_posix="$(posixify "$top")"
  [ -n "$top_posix" ] && top="$top_posix"
  top_phys="$(phys "$top")"
  [ -n "$top_phys" ] && top="$top_phys"
  root_phys="$(phys "$root")"
  if [ -n "$root_phys" ]; then root="$root_phys"; else root=/tmp; fi
  case "$root/" in "${top%/}"/*) root=/tmp ;; esac
fi

dir="$root/forgeward-artifacts/$$"
# An existing <root>/forgeward-artifacts that resolves into the repo is refused BEFORE the
# mkdir, which would otherwise create the per-process directory inside the repo.
dir_phys=""
if [ -n "$top" ] && [ -e "$root/forgeward-artifacts" ]; then
  dir_phys="$(phys "$root/forgeward-artifacts")"
  case "$dir_phys/" in "${top%/}"/*) dir="" ;; esac
fi
if [ -n "$dir" ]; then
  mkdir -p "$dir" 2>/dev/null || { dir="/tmp/forgeward-artifacts/$$"; mkdir -p "$dir" || exit 1; }
fi
# The root was checked, not the directory handed out: `<root>/forgeward-artifacts` may be a
# symlink into the repo. Resolve the directory itself and repeat the test. Inside the repo,
# or unresolvable, fall back to a fresh mktemp -d: its name is unpredictable, so it cannot
# have been planted. That one is checked too, and exit 1 (the gate's 2a stops on it) if it
# is still inside.
if [ -n "$top" ]; then
  dir_phys=""
  if [ -n "$dir" ]; then
    dir_phys="$(phys "$dir")"
    case "$dir_phys/" in
      /*) case "$dir_phys/" in "${top%/}"/*) dir_phys="" ;; esac ;;
      *) dir_phys="" ;;
    esac
  fi
  if [ -z "$dir_phys" ]; then
    dir="$(mktemp -d /tmp/forgeward-artifacts.XXXXXX)" || exit 1
    dir_phys="$(phys "$dir")"
    case "$dir_phys/" in /*) ;; *) exit 1 ;; esac
    case "$dir_phys/" in "${top%/}"/*) exit 1 ;; esac
  fi
fi
printf '%s\n' "$dir"
