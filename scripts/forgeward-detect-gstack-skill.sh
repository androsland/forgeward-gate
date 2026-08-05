#!/usr/bin/env bash
# forgeward-detect-gstack-skill.sh <skill-name>
#
# Answer one question deterministically: is a gstack skill by this name INSTALLED on
# this machine? Exit 0 and print the directory when it is, exit 1 and print nothing
# when it is not.
#
# WHY THIS EXISTS. forgeward is scoped as a delta against gstack, so a reviewer can
# defer an axis to a gstack skill BY NAME. Those deferrals shipped unconditional.
# `supply-chain-reviewer` was told, verbatim: "gstack's `/cso` Phase 3 already covers
# dependency CVEs, install-scripts, and lockfile integrity - do NOT re-do those." On a
# machine with no gstack, nobody checked them and the reviewer returned PASS clean.
# That is the same shape as the delegation reversed in DECISIONS.md on 2026-07-13: a
# deferral to a tool that is never run is not coverage, it is a hole with a citation in
# front of it. The difference is that the 2026-07-13 case assumed the user would RUN
# `/cso`; this one assumed they would HAVE it.
#
# FAILS CLOSED, ALWAYS. Every uncertain answer is "not installed". A false negative
# costs the caller duplicated work - it audits an axis `/cso` would also have audited,
# and the user sees two opinions instead of one. A false positive is a silently skipped
# check, which is the bug this script exists to prevent. The asymmetry is the whole
# design: nothing here should be relaxed to make detection more eager.
#
# WHAT COUNTS AS INSTALLED. A directory whose basename is the skill name, or that name
# behind a prefix (`gstack-cso`), which contains a `SKILL.md` whose frontmatter carries
# the `(gstack)` marker that gstack skill descriptions end with.
#
#   - The prefix arm is load-bearing, not defensive. gstack's `setup` defaults to
#     `SKILL_PREFIX=1` and names the entry it drops in the skills dir after the
#     frontmatter `name:` field, which `bin/gstack-patch-names` rewrites to
#     `gstack-<skill>` in prefix mode. A literal `cso` match therefore misses a
#     perfectly normal install - which would fail closed, but noisily and for everyone
#     who took the default.
#   - The marker arm is what stops an unrelated skill that happens to be named `cso`
#     from being read as gstack's. `gstack-patch-names` rewrites `name:` only and never
#     touches `description:`, so the marker survives prefixing - the two arms are
#     independent, which is why both can be required at once.
#
# Skills are installed as SYMLINKS into the gstack checkout (`link_claude_skill_dirs`),
# so every test here must follow links. `[ -d ]` and `[ -f ]` do; `find -type d` would
# not, and neither would `lstat`-based checks copied from the hardening in
# `forgeward-scan.sh`, where refusing to follow a link is the correct behaviour and here
# it is the wrong one.
#
# LIMITATION - presence, not diligence. This sees that a skill is on disk. It cannot see
# whether the user ever runs it, whether it is configured, or whether it covers the axis
# the caller is deferring. gstack installed and never once invoked is indistinguishable
# from gstack actively covering the axis. A caller must not read exit 0 as "the axis was
# audited" - only as "the tool the deferral names is present". The same limit applies to
# the review-ran check in TODOS.md, and for the same structural reason.
#
# LIMITATION - the marker is a convention, not a contract. If gstack ever drops the
# `(gstack)` suffix from a description, this reports ABSENT and callers duplicate work.
# That is the safe direction, and it is preferred to matching on the bare name.
#
# LIMITATION - it cannot see a substitute. A repo covering the axis with Dependabot,
# Snyk, or a CI SAST job looks identical to a repo covering it with nothing. Deciding
# what to do about that belongs to the caller and to `.forgeward/config.yml`, not here.
set -uo pipefail

skill="${1:-}"
case "$skill" in
  ''|*[!A-Za-z0-9_-]*)
    printf 'forgeward-detect-gstack-skill: usage: %s <skill-name>\n' "${0##*/}" >&2
    exit 2
    ;;
esac

claude_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"

# Does this SKILL.md's FRONTMATTER carry the marker? Scoped to the frontmatter on
# purpose: a skill body may quote "(gstack)" while describing an integration, and the
# body is the larger and far more quotable surface.
#
# Read through a command substitution rather than a pipe into `grep -q`. `grep -q` is an
# early-exit reader, and under this repo's `set -o pipefail` conventions that can kill
# the writer with SIGPIPE and invert the answer - the defect that cost an entire
# investigation in TODOS.md's completed P1. A command substitution drains to EOF and a
# `case` glob forks nothing, so neither half of that race exists here.
carries_marker() {
  local head1 fm
  IFS= read -r head1 < "$1" 2>/dev/null || return 1
  # Tolerate a CRLF checkout: the delimiter is `---` plus whatever line ending.
  case "$head1" in '---'*) ;; *) return 1 ;; esac
  fm="$(sed -n '2,/^---[[:cntrl:][:space:]]*$/p' "$1" 2>/dev/null)"
  case "$fm" in *'(gstack)'*) return 0 ;; *) return 1 ;; esac
}

# Print the first installed match under $1, or return 1.
check_root() {
  local root="$1" d base prefix
  [ -d "$root" ] || return 1
  # An unmatched glob stays literal here (no nullglob), and the `-d` test rejects it.
  for d in "$root/$skill" "$root"/*-"$skill"; do
    [ -d "$d" ] || continue
    base="${d##*/}"
    if [ "$base" != "$skill" ]; then
      # Constrain the prefix to the same shape the ship matcher accepts, so a directory
      # named `not-really-cso` cannot pass as a prefixed install.
      prefix="${base%-"$skill"}"
      case "$prefix" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    fi
    [ -f "$d/SKILL.md" ] || continue
    carries_marker "$d/SKILL.md" || continue
    printf '%s\n' "$d"
    return 0
  done
  return 1
}

roots=()
[ -n "$claude_dir" ] && roots+=("$claude_dir/skills")

# A project-local skill counts: it is installed for anyone working in this repo.
top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$top" ] && roots+=("$top/.claude/skills")

# gstack can also arrive as a plugin, in which case its skills live one marketplace and
# one plugin deep under the cache rather than in the skills dir.
if [ -n "$claude_dir" ]; then
  for cand in "$claude_dir"/plugins/cache/*/*/skills; do
    [ -d "$cand" ] && roots+=("$cand")
  done
fi

for root in "${roots[@]:-}"; do
  [ -n "$root" ] || continue
  check_root "$root" && exit 0
done

exit 1
