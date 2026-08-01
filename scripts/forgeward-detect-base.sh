#!/usr/bin/env bash
# forgeward-detect-base.sh [--name]
#
# Print the base REF this work targets — the PUBLISH BOUNDARY, i.e. the newest
# commit the remote already has. `git diff "<base>...HEAD"` against that ref is
# exactly the surface the next push publishes, which is the surface the gate must
# review. `--name` prints the bare branch NAME instead, for callers that need a
# branch rather than a ref (e.g. `gh pr create --base <name>`, where `origin/main`
# would be wrong).
#
# Resolution runs in two stages.
#
#   A. NAME — which branch is the base?
#      1. GitHub default branch (gh, when a GitHub remote is reachable)
#      2. origin/HEAD's symbolic-ref target — ONLY when set and non-empty
#      3. origin/main, else local main, else master
#
#   B. REF — which ref of that branch do we actually diff against?
#      4. the branch's configured upstream (`<base>@{upstream}`, i.e.
#         branch.<base>.remote + branch.<base>.merge). This is git's own answer,
#         so it honors a fork whose upstream remote is NOT `origin`, and a local
#         branch tracking a differently-named remote branch (main -> origin/master).
#      5. otherwise `<remote>/<base>` for the first remote that actually HAS that
#         ref, tried in order: the base branch's remote, the current branch's
#         remote, `origin`, and the sole remote when there is exactly one.
#      6. otherwise the LOCAL branch — a local-only repo, an unauthenticated gh, or
#         a base branch never pushed. There the local branch IS the truth, so it is
#         used bare. Nothing here ever blindly prefixes `origin/`: a remote ref is
#         used only when `git rev-parse` confirms it exists.
#
# WHY STAGE B EXISTS. Stage A returns a NAME, and a bare name resolves to the LOCAL
# branch, which is only as current as the last time the user touched it. Verified in
# a real repo whose local master had never been fast-forwarded (local de1bbf3,
# origin/master 5b94aac, 14 commits ahead): `git diff --name-only master...HEAD`
# reported 267 files, `origin/master...HEAD` reported 0. Both drift directions
# mis-scope the review, and the second is the dangerous one:
#   - local BEHIND the remote  -> already-merged commits enter the review surface.
#     Wasted budget, findings on lines the PR never touched, and a FAIL can land on
#     someone else's code.
#   - local AHEAD of the remote (unpushed commits on the base branch) -> the diff is
#     SMALLER than what the push publishes. The gate reviews less than ships and
#     writes a PASS marker for a surface it never saw. That is a false PASS.
# Guaranteeing a NON-EMPTY base (the reason this script exists) was never enough:
# it also has to be CURRENT, or it still fails at the thing it exists to prevent.
#
# SILENT CORRECTION ON STDOUT, LOUD REPORT ON STDERR — a deliberate choice.
# Blocking on drift was rejected: a base branch that is behind its remote is the
# normal state of a working checkout, not an error, and a gate that refuses to run
# on the common case gets bypassed — a bypassed gate reviews nothing. Correcting it
# silently was also rejected: "your local master is 14 commits behind" is a fact the
# user acts on, and a silent re-scope makes the reviewed surface differ from what
# the user would compute by hand. So the correction is automatic (a mis-scoped diff
# is a correctness bug, not a user preference) and the drift is reported on stderr:
# stdout stays exactly ONE clean ref so `$(...)` capture is unaffected, and the gate
# skill surfaces the note in its firing decision.
#
# LIMITATIONS — what this structurally CANNOT see. An unstated limit is
# indistinguishable from a claim of coverage:
#   - FETCH STALENESS. This never runs `git fetch` (network, credentials, offline
#     use), so `origin/<base>` is only as current as the last fetch. Commits pushed
#     to the base branch since then are invisible, and the gate then reviews against
#     a stale publish boundary — the same class of error, one level up. Only the
#     user's `git fetch` fixes it; the drift note says so.
#   - THE ACTUAL PR TARGET. This infers a base from repo defaults. It cannot know a
#     PR will be opened against a release branch, a stacked PR's parent branch, or
#     any base other than the repo default. If you are targeting something else,
#     pass the base explicitly instead of using this.
#   - Merge-base semantics only: `A...HEAD` compares against the merge base, so work
#     already contained in the base (cherry-picked, or merged then re-merged) is
#     legitimately invisible here.
set -uo pipefail

want_name=0
[ "${1:-}" = "--name" ] && want_name=1

warn() { printf 'forgeward-detect-base: %s\n' "$*" >&2; }

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  warn "not inside a git repository; printing 'master' so the caller's guarantee holds, but its git diff will fail."
  printf 'master\n'; exit 0
fi

# ---------------------------------------------------------------- stage A: NAME
base=""

# 1. GitHub default branch. Absent gh / no GitHub remote -> empty, fall through.
base="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"

# 2. origin/HEAD symbolic ref. Guard the empty-but-exit-0 trap EXPLICITLY: only
#    adopt it when the ref is actually set and non-empty. (The earlier inline form
#    `... | sed ... || ...` short-circuited to '' here, because sed exits 0 on empty
#    input, so the || chain stopped before the main/master fallback.)
if [ -z "$base" ]; then
  ref="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"
  [ -n "$ref" ] && base="${ref#refs/remotes/origin/}"
fi

# 3. origin/main, then local main, else master.
if [ -z "$base" ]; then
  if   git rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1; then base=main
  elif git rev-parse --verify --quiet refs/heads/main          >/dev/null 2>&1; then base=main
  else base=master
  fi
fi

name="$base"
[ "$want_name" = 1 ] && { printf '%s\n' "$name"; exit 0; }

# ----------------------------------------------------------------- stage B: REF
ref=""

# 4. The branch's configured upstream — git's own answer, so a fork tracking
#    `upstream` and a local branch tracking a differently-named remote branch both
#    resolve correctly without this script guessing a remote name.
up="$(git rev-parse --symbolic-full-name "${name}@{upstream}" 2>/dev/null || true)"
case "$up" in refs/remotes/*) ref="${up#refs/remotes/}" ;; esac

# 5. No configured upstream: the first remote that actually has the ref. Ordered
#    most-specific first. A remote-tracking ref is adopted only when it EXISTS, so a
#    base branch with no remote counterpart is left alone (step 6).
if [ -z "$ref" ]; then
  cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"     # "HEAD" when detached
  sole=""
  [ "$(git remote 2>/dev/null | wc -l | tr -d ' ')" = "1" ] && sole="$(git remote 2>/dev/null)"
  for r in \
    "$(git config --get "branch.${name}.remote" 2>/dev/null || true)" \
    "$(git config --get "branch.${cur}.remote"  2>/dev/null || true)" \
    origin \
    "$sole"
  do
    [ -n "$r" ] || continue
    if git rev-parse --verify --quiet "refs/remotes/$r/$name" >/dev/null 2>&1; then
      ref="$r/$name"; break
    fi
  done
fi

# 6. No remote counterpart anywhere -> the local branch is the truth.
if [ -z "$ref" ]; then
  ref="$name"
  git rev-parse --verify --quiet "refs/heads/$name" >/dev/null 2>&1 || \
    warn "base branch '$name' resolves to no local or remote ref; \"git diff '$name...HEAD'\" will fail. Fetch the remote, or check out the base branch."
fi

# Report drift between the local base branch and the publish boundary we picked.
# Only when they are genuinely different refs — a checkout in sync stays quiet.
if [ "$ref" != "$name" ] && git rev-parse --verify --quiet "refs/heads/$name" >/dev/null 2>&1; then
  counts="$(git rev-list --left-right --count "refs/heads/$name...$ref" 2>/dev/null || true)"
  if [ -n "$counts" ]; then
    ahead="${counts%%[![:digit:]]*}"
    behind="${counts##*[![:digit:]]}"
    if [ "${ahead:-0}" != 0 ] || [ "${behind:-0}" != 0 ]; then
      warn "local '$name' is ${behind:-0} commit(s) behind and ${ahead:-0} ahead of '$ref'; scoping the review to '$ref', the publish boundary (what this push actually adds). Run 'git fetch' if '$ref' itself may be stale — this script never fetches."
    fi
  fi
fi

printf '%s\n' "$ref"
