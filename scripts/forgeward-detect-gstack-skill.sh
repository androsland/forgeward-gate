#!/usr/bin/env bash
# forgeward-detect-gstack-skill.sh <skill-name>
#
# Answer one question deterministically: is a gstack skill by this name INSTALLED on
# this machine? Exit 0 and print the directory when it is, exit 1 and print nothing
# when it is not.
#
# WHY THIS EXISTS - written 2026-08-05, and the situation it describes is now HISTORY.
# forgeward was scoped as a delta against gstack, so a reviewer could defer an axis to a
# gstack skill BY NAME. Those deferrals shipped unconditional.
# `supply-chain-reviewer` was told, verbatim: "gstack's `/cso` Phase 3 already covers
# dependency CVEs, install-scripts, and lockfile integrity - do NOT re-do those." On a
# machine with no gstack, nobody checked them and the reviewer returned PASS clean.
# That is the same shape as the delegation reversed in DECISIONS.md on 2026-07-13: a
# deferral to a tool that is never run is not coverage, it is a hole with a citation in
# front of it. The difference is that the 2026-07-13 case assumed the user would RUN
# `/cso`; this one assumed they would HAVE it.
#
# FAILS CLOSED, ALWAYS. Every uncertain answer is "not installed". The asymmetry is the
# whole design and nothing here should be relaxed to make detection more eager - but READ
# WHOSE COST IT IS NOW, because the caller changed under it. While the deferral existed, a
# false negative cost duplicated work and a false positive was a silently skipped check,
# which is the bug this script was written to prevent. As of 0.23.0 no reviewer defers, so
# nothing calls this for `cso` at all. The one live consumer is
# forgeward-detect-environment.sh's `gstack_ship`, where a false negative costs a MISSED
# /ship handoff and a false positive costs the gate announcing a handoff it never
# performed. Different consequence, same direction: closed is still the safe answer.
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

# Locale-pinned repo-wide, not per-effect — see CLAUDE.md. A non-interactive script
# must not have its behaviour depend on the invoker's environment: character classes,
# collation and grep's handling of invalid UTF-8 all move with the locale, and the
# last one was a complete bypass of an ambiguity guard before it was pinned.
export LC_ALL=C

skill="${1:-}"
case "$skill" in
  ''|*[!A-Za-z0-9_-]*)
    printf 'forgeward-detect-gstack-skill: usage: %s <skill-name>\n' "${0##*/}" >&2
    exit 2
    ;;
esac

# With CLAUDE_CONFIG_DIR unset AND HOME unset or empty, the obvious one-liner
# (`${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}`) collapses to `/.claude` and sends this
# probing the filesystem root. Leave it empty instead, so that root is skipped and the
# git and plugin-cache roots still apply. Deliberately not pinned by a test: proving the
# difference needs a readable `/.claude/skills`, and a test that passes either way would
# be vacuous, which this suite treats as worse than absent.
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  claude_dir="$CLAUDE_CONFIG_DIR"
elif [ -n "${HOME:-}" ]; then
  claude_dir="$HOME/.claude"
else
  claude_dir=""
fi

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

# gstack can also arrive as a plugin, in which case its skills live under the cache rather
# than in the skills dir.
#
# TWO GLOB DEPTHS, and the deeper one is the only one that has ever fired. Until 0.18.0 this
# globbed `plugins/cache/*/*/skills` alone — one marketplace and one plugin deep — and that
# depth matched NOTHING: the installed layout carries a version,
# `cache/<marketplace>/<plugin>/<version>/skills`. Enumerated on the author's machine — 8
# marketplaces, 8 plugins, 15 version directories, 14 of them holding a `skills/`, and ZERO
# at the shallow depth. So this arm had never fired and a plugin-installed gstack read as
# absent on every probe. `scripts/forgeward-rubric-drift.sh` searched both depths from the
# start and its `gs_roots` loop is the precedent followed here; the two agree as of 0.18.0.
#
# The version level is CONSTRAINED to `[0-9]*` rather than left as a bare `*`, and that is a
# deliberate narrowing of the fix, not an oversight. A bare third `*` also matches
# `cache/<market>/<plugin>/node_modules/skills` and `.../docs/skills` — both reproduced
# returning exit 0 — which is detection getting MORE eager, the one direction the FAILS
# CLOSED paragraph above forbids. Semver cannot begin with a letter, so requiring a
# digit-first level costs nothing that is known to exist. Two limits, stated rather than
# implied:
#   - It does not verify the level IS a version. `2-backup` still matches. It excludes the
#     realistic accident, never a determined one.
#   - A non-numeric version scheme (`v1.2.3`, a branch name) now reads as ABSENT. That is
#     fail-closed and so permitted, but it IS a choice: if such a layout ships, this is the
#     line to widen, and widening it needs evidence the shallow depth below is still owed.
#
# The shallow depth is KEPT rather than replaced, on the same defensive footing the drift
# script keeps it: no install on this machine uses it, so there is no evidence it is a real
# layout, and equally none that it never was. It costs one glob. Do not delete it as dead
# without an installer-side statement that the version level is guaranteed.
#
# WHAT THIS STILL CANNOT TELL — a live false positive, which the ordering makes WORSE rather
# than merely possible. The cache retains every version ever installed (forgeward has 8 here
# while `~/.claude/plugins/installed_plugins.json` names exactly one as installed), and
# `check_root` returns the FIRST match. Glob order is lexicographic under this script's own
# `LC_ALL=C` pin, which is neither version order nor install order: the real cache enumerates
# `0.1.0 0.10.0 0.13.0 0.16.0 0.5.0 0.9.1 0.9.2 0.9.3`, so the OLDEST directory is tried
# first and the installed 0.16.0 is fourth. The UPGRADE case is the proven one and needs no
# uninstall to reach — gstack ships a skill, a later version drops it, and the old version
# dir survives the upgrade, so this answers "installed" for a skill the live gstack no longer
# has. Until 0.23.0 that re-opened the CVE hole WHY THIS EXISTS records; it cannot any more,
# because no reviewer defers. What it still does is make `gstack_ship` read present when
# `/ship` is gone — the gate then reports a handoff it never performed, which is the same bug
# shape one axis over. A platform sweep is not a mitigation: one ran on 2026-08-26 and left all 7 stale
# forgeward versions in place. This resolves "a copy is on disk", never "the active version
# is this". `installed_plugins.json` is the authoritative source and is deliberately not read
# here; filed in TODOS.md rather than fixed, because reading it changes what the gate defers
# on every probe.
if [ -n "$claude_dir" ]; then
  for cand in "$claude_dir"/plugins/cache/*/*/skills \
              "$claude_dir"/plugins/cache/*/*/[0-9]*/skills; do
    [ -d "$cand" ] && roots+=("$cand")
  done
fi

for root in "${roots[@]:-}"; do
  [ -n "$root" ] || continue
  check_root "$root" && exit 0
done

exit 1
