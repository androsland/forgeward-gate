#!/usr/bin/env bash
# forgeward-workspace-guard.sh snapshot | check <snapshot-file>
#
# Prove the read-only contract instead of asserting it. The gate advertises that its
# reviewers never write to the repo they audit ("a model that fixes what it judges
# produces biased reviews"), and that claim was false: security-reviewer twice
# created a `C:` directory tree at the repo root by handing a scanner a Windows path
# from a POSIX shell. Untracked, matched by no common .gitignore — one `git add -A`
# and the reviewer's scratch tree is in the user's history.
#
#   snapshot            -> print the repo's dirty+untracked path set (stdout)
#   check <snapshot>    -> print paths that appeared since; exit 1 if any, else 0
#
# Take the snapshot BEFORE spawning reviewers, check AFTER they return, and write
# the snapshot file OUTSIDE the repo (use forgeward-artifact-dir.sh) — a guard that
# contaminates the tree it is guarding is not a guard.
#
# WHY THIS IS THE BACKSTOP AND NOT THE FIX. forgeward-scan.sh refuses the known bad
# invocation and the PreToolUse hook denies the known bad command shape; both work
# from the command TEXT, so both are enumerations. This one works from the
# filesystem, so it sees any contamination regardless of which tool, flag, or path
# produced it.
#
# WHAT IT STRUCTURALLY CANNOT SEE:
#   - a write to a path that is already gitignored (git status will not report it),
#   - a write anywhere OUTSIDE this repo, including another repo on the machine,
#   - a modification to a file's mtime/permissions with identical content,
#   - who wrote it: this reports that the tree changed, never which reviewer did it.
# It also cannot distinguish a reviewer's artifact from a file the user created in
# another terminal during the run, which is exactly why it only ever REPORTS —
# deleting untracked files is destructive and is the caller's decision, not this
# script's.
set -uo pipefail

# Locale-pinned repo-wide, not per-effect — see CLAUDE.md. A non-interactive script
# must not have its behaviour depend on the invoker's environment: character classes,
# collation and grep's handling of invalid UTF-8 all move with the locale, and the
# last one was a complete bypass of an ambiguity guard before it was pinned.
export LC_ALL=C

mode="${1:-}"

git rev-parse --git-dir >/dev/null 2>&1 || {
  printf 'forgeward-workspace-guard: not a git repository; nothing to guard.\n' >&2; exit 0; }

# core.quotepath=false so a non-ASCII path (a U+F03A colon substitute among them)
# comes back verbatim instead of \NNN-escaped, and compares stably across runs.
snap() { git -c core.quotepath=false status --porcelain --untracked-files=all 2>/dev/null | sed 's/^...//' | sort; }

case "$mode" in
  snapshot)
    snap
    ;;
  check)
    file="${2:-}"
    [ -n "$file" ] && [ -f "$file" ] || {
      printf 'usage: forgeward-workspace-guard.sh check <snapshot-file>\n' >&2; exit 64; }
    new="$(comm -13 "$file" <(snap) 2>/dev/null || true)"
    [ -n "$new" ] || exit 0
    printf 'forgeward: the repository under review CHANGED while the read-only reviewers ran.\n' >&2
    printf 'New paths (a reviewer wrote into the repo it was auditing):\n' >&2
    printf '%s\n' "$new" | sed 's/^/  /' >&2
    # shellcheck disable=SC2016  # the backticks are prose the user reads, not a substitution
    printf 'Delete these before committing — `git add -A` would commit them into your history.\n' >&2
    exit 1
    ;;
  *)
    printf 'usage: forgeward-workspace-guard.sh snapshot | check <snapshot-file>\n' >&2
    exit 64
    ;;
esac
