#!/usr/bin/env bash
# forgeward-detect-base.sh
#
# Print the base branch this work targets — the same resolution /ship uses, and
# the single source of truth for gate SKILL.md Step 0. Resolution order:
#   1. GitHub default branch (gh, when a GitHub remote is reachable)
#   2. origin/HEAD's symbolic-ref target — ONLY when set and non-empty
#   3. origin/main, else local main, else master
#
# GUARANTEE: always prints a NON-EMPTY ref. The earlier inline form
#   ... || git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed ... || ...
# short-circuited to '' when origin/HEAD was unset: `sed` in the pipe exits 0 on
# empty input, so the `||` chain stopped before the main/master fallback. An empty
# base mis-scopes the diff (git diff "...HEAD" with an empty ref) -> wrong review
# surface -> a security tool reviewing the wrong thing. Base detection therefore
# lives here, under test (see test/gate-test.sh).
set -uo pipefail

base=""

# 1. GitHub default branch. Absent gh / no GitHub remote -> empty, fall through.
base="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"

# 2. origin/HEAD symbolic ref. Guard the empty-but-exit-0 trap EXPLICITLY: only
#    adopt it when the ref is actually set and non-empty.
if [ -z "$base" ]; then
  ref="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"
  [ -n "$ref" ] && base="${ref#refs/remotes/origin/}"
fi

# 3. origin/main, then local main, else master.
if [ -z "$base" ]; then
  if   git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then base=main
  elif git rev-parse --verify --quiet main        >/dev/null 2>&1; then base=main
  else base=master
  fi
fi

printf '%s\n' "$base"
