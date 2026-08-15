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
#      1. GitHub default branch (gh — only when a remote carries a network URL;
#         see the guard at step 1 for why, and for what it costs)
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
#   - THE STEP-1 GUARD'S OWN BLIND SPOT. A repo whose only remote is a filesystem
#     path — a clone of a clone, a local mirror — skips step 1 even if the far end
#     ultimately IS a GitHub repo, and falls through to origin/HEAD and the
#     main/master fallback. That is the same path a repo with no gh, no auth, or no
#     network already takes, so it costs a resolution step that was never reliable
#     for that shape rather than introducing a new failure. Steps 2 and 3 are
#     local-only and unaffected. The test is a deny-list of path forms, so a URL it
#     does not recognize as a path still reaches gh; that asymmetry is deliberate,
#     see the guard for why. What the deny-list currently skips is the four arms
#     written there and nothing else FOUND so far — stated that way on purpose. An
#     earlier draft of this line claimed filesystem paths were "the ONLY shape the
#     guard skips", and the drive-letter arm was already falsifying it as the words
#     were written. A claim about what a pattern list CANNOT miss is not something
#     this file gets to make; B14's table is the record of what has been checked.
set -uo pipefail

# Locale-pinned repo-wide, not per-effect — see CLAUDE.md. A non-interactive script
# must not have its behaviour depend on the invoker's environment: character classes,
# collation and grep's handling of invalid UTF-8 all move with the locale, and the
# last one was a complete bypass of an ambiguity guard before it was pinned.
export LC_ALL=C

want_name=0
[ "${1:-}" = "--name" ] && want_name=1

warn() { printf 'forgeward-detect-base: %s\n' "$*" >&2; }

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  warn "not inside a git repository; printing 'master' so the caller's guarantee holds, but its git diff will fail."
  printf 'master\n'; exit 0
fi

# ---------------------------------------------------------------- stage A: NAME

# 1. GitHub default branch. Absent gh / no GitHub remote -> empty, fall through.
#
# GUARDED ON A NETWORKED REMOTE. `gh repo view` is a NETWORK call, and this script
# is driven ~15 times per suite run, so an unguarded call taxes every run with
# GitHub latency in scratch repos that have no remote, or a local-path one, and
# therefore cannot get a useful answer from it anyway.
#
# Measured on test/gate-test.sh, same 104 assertions either way, three runs each:
# unguarded 114s / 201s / 93s, guarded 29s / 33s / 37s. The ~2min figure quoted
# when this was filed reproduces. Note WHICH number moved: the guarded spread is
# 8s wide and the unguarded one is 108s wide, because the unguarded runtime is a
# network measurement wearing a test suite's clothes. A single sample of either
# side is worth very little here — an early one-shot pair read as 48s -> 22s and
# would have understated the win by roughly 3x.
#
# The guard is a pure SHORT-CIRCUIT, not a reordering: whenever a networked remote
# exists the call still runs, still runs FIRST, and still wins. Resolution order is
# unchanged for every real checkout. Reordering was considered and rejected —
# putting the free origin/HEAD lookup ahead of gh would let a stale symbolic ref
# (set at clone time, or by an old `git remote set-head`) outrank GitHub's actual
# default branch, and stage A feeds the diff scope that produced the false PASS
# this script exists to prevent. A cheaper answer is not worth a wronger one.
#
# "Networked" is deliberately host-agnostic. Matching on `github.com` was rejected:
# it would skip GitHub Enterprise, whose remotes are on customer domains, silently
# costing those users step 1.
#
# THE TEST IS A DENY-LIST OF LOCAL PATHS, NOT AN ALLOW-LIST OF NETWORK FORMS, and
# the direction is the whole point. The two misclassifications are not symmetric:
#   - local mistaken for networked -> one wasted `gh` call that fails. Costs latency.
#   - networked mistaken for local -> step 1 is skipped and a STALER answer wins.
#     That silently re-scopes the diff the entire gate reviews, which is the false
#     PASS this script exists to prevent.
# So anything not recognizably a path is treated as networked.
#
# THE RULE IS GIT'S, NOT AN APPROXIMATION OF IT, and that is the entire point. Three
# consecutive review rounds each found a DIFFERENT remote URL that this guard called
# local while git really dials it over the network. Every one was a fresh instance of
# one class: a prefix that LOOKS like a path but does not structurally guarantee what
# git's parser requires. Enumerating "looks like a path" shapes in bash was the wrong
# approach, not merely an under-populated list, and the third round is what settled
# that — the same lesson the publish matcher learned in DECISIONS.md, where three
# consecutive desyncs meant delete the machinery rather than patch it again.
#
# git's actual predicate is url_is_local_not_ssh() in url.c — LOCAL iff:
#
#     !colon || (slash && slash < colon) || (has_dos_drive_prefix() && is_valid_path())
#
# The first two clauses are encoded exactly here, so shapes nobody enumerated resolve
# correctly by construction. Verified against the real binary rather than recalled —
# `GIT_SSH_COMMAND='echo dialed' git ls-remote <url>` dials for `~mybox:repo.git`,
# `myhost:path/to/x` and `[::1]:repo`, and does not for `~/local/repo` or
# `foo/bar:baz`.
#
# THE THIRD CLAUSE IS APPROXIMATED, and saying so is the point. `[A-Za-z]:[/\\]*` is
# narrower than git's in both directions:
#   - has_dos_drive_prefix() is just isalpha(p[0]) && p[1]==':', with nothing required
#     after the colon, so drive-RELATIVE `C:foo` is local to git and networked here.
#     Harmless: one wasted gh call.
#   - is_valid_path() on a native Windows build is is_valid_win32_path(), which with
#     the default core.protectNTFS=true REJECTS a path segment named for a DOS device
#     (aux, con, prn, nul, com1-9, lpt1-9) or ending in a space or period. When it
#     rejects, all three clauses are false and git dials SSH to a one-letter host —
#     while the pattern here still says local. That is the dangerous direction, and it
#     is a real divergence, not a theoretical one.
# Left approximated deliberately: the true clause depends on core.protectNTFS and the
# NTFS reserved-name table, which a bash script cannot evaluate without the Win32 API.
# The residual needs a native-Windows git AND a remote path containing a literal DOS
# device segment — a shape no GitHub, GHE, gitolite or gitea host produces, and one an
# attacker can only arrange by already owning .git/config, which is well outside what
# this advisory step defends. Recorded rather than closed; see TODOS.md.
#
# The three attempts it replaces, all failing in the SAME direction — calling
# something networked local, which skips step 1 and lets a staler answer win — and
# all caught by the security reviewer on this change's own gate run, never by tests:
#
#   1. An allow-list of `*://*` and the scp-like `*@*:*`. git makes the `user@`
#      component OPTIONAL, so the ordinary `github.com:org/repo.git` and every
#      SSH-config alias like `gh:org/repo` matched neither and read as local.
#   2. Then, with the deny-list in place, an arm excluding `[A-Za-z]:[/\\]*` as a
#      "Windows drive path". That classification is only true where git's
#      has_dos_drive_prefix() is compiled in, i.e. native Windows. Everywhere else —
#      Linux, macOS, WSL — git parses the SAME string as scp-like syntax with a
#      one-letter HOSTNAME, and really does dial it:
#        $ GIT_SSH_COMMAND='echo $@' git ls-remote 'C:/foo/bar'
#        C git-upload-pack '/foo/bar'
#      So a remote like `g:/data/repos/myrepo.git` — an SSH alias plus an absolute
#      path, the ordinary gitolite/gitea shape — read as local, skipped step 1, and
#      returned the stale local branch. Verified end to end.
#
# The first fix for (2) DELETED the drive-letter arm outright, reasoning that fewer
# branches means fewer chances to misclassify. The Windows suite immediately failed:
# MSYS rewrites an absolute POSIX remote on the way in, so `git remote add origin
# /srv/mirror/r.git` is STORED as `C:/Program Files/Git/srv/mirror/r.git` and the
# colon-bearing result then read as networked. Observed, not predicted.
#
# So the arm is back, gated on the platform. `X:/…` genuinely means opposite things
# either side of that line — a drive path where git compiles in
# has_dos_drive_prefix(), a one-letter SSH host everywhere else — and no single
# pattern can be right on both. Asking `uname -s` is the only honest answer; picking
# one meaning is what produced both halves of this bug. The reviewer offered exactly
# this alternative when it flagged the deletion; the deletion was tried first because
# it was simpler, and simpler was wrong.
#
#   3. `~*`, treating every tilde-led URL as a path. A bare `~mybox:repo.git` has no
#      slash before its colon, so git dials SSH to the host `~mybox`; only `~/…` is
#      actually a path. This one is not patched with a fourth arm — it is what
#      retired the enumeration in favour of git's rule above, which subsumes all
#      three and also stops calling `foo/bar:baz` networked (a slash DOES precede
#      that colon, so git treats it as local; harmless, but wrong).
remote_is_networked() {
  local r url dos=0
  # `X:/…` means opposite things by platform, so ask which shell we are in rather
  # than picking one meaning. This mirrors git's own has_dos_drive_prefix().
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) dos=1 ;; esac
  for r in $(git remote 2>/dev/null); do
    url="$(git remote get-url "$r" 2>/dev/null || true)"
    case "$url" in
      "")       continue ;;   # no URL configured
      file://*) continue ;;   # explicitly local
      *://*)    return 0 ;;   # any other scheme is a transport
    esac
    # Windows only, and checked before the general rule because a drive path would
    # otherwise satisfy it: git compiles in has_dos_drive_prefix() there and nowhere
    # else, so `X:/…` and `X:\…` are drive paths on this platform alone.
    if [ "$dos" = 1 ]; then
      case "$url" in [A-Za-z]:[/\\]*) continue ;; esac
    fi
    # git's own scp-like rule, encoded rather than approximated: a URL is a
    # transport iff it contains a colon and NO slash appears before the first one.
    case "$url" in
      *:*) case "${url%%:*}" in */*) continue ;; *) return 0 ;; esac ;;
      *)   continue ;;
    esac
  done
  return 1
}

base=""
if remote_is_networked; then
  base="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
fi

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
