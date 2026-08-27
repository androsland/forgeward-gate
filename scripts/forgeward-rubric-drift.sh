#!/usr/bin/env bash
# forgeward-rubric-drift.sh
#
# Report whether forgeward's five ported quality rubrics still match the gstack
# files they were ported from. Informational only: it prints at most a few lines,
# never fails a gate, and always exits 0.
#
# WHY THIS EXISTS. forgeward's quality reviewers (maintainability, testing,
# performance, api-contract, data-migration) are ports of gstack's Review Army
# specialist checklists, taken under MIT with the source commit and a sha256
# recorded in each `agents/*-reviewer.md`. A port removes the runtime dependency —
# forgeward reviews quality on a machine with no gstack at all — but it buys that
# with drift: gstack can improve a checklist and nothing would tell us. This
# closes that loop the cheap way. It is five sha256 comparisons against files that
# are already on disk, so it costs nothing to run inside a gate that is already
# invoking the environment probe.
#
# The alternative that was considered and rejected was reading gstack's rubrics at
# runtime instead of porting them. That keeps the copy authoritative and auto-
# updating, but it puts the quality axis back behind "is gstack installed" — the
# same delta-scoping hole that `supply-chain-reviewer` had to grow out of. It also
# turns out to be less available than it looks: see PATH RESOLUTION below.
#
# PATH RESOLUTION, and why it does not use forgeward-detect-gstack-skill.sh.
# That detector answers "is the /review skill installed" and returns the skill
# DIRECTORY — on a normal install, `~/.claude/skills/review`, which contains
# SKILL.md and nothing else. The specialist checklists are not there. gstack's own
# SKILL.md reaches them by absolute path into its checkout
# (`~/.claude/skills/gstack/review/specialists/…`), so that checkout is the only
# place the rubrics reliably live and it is what this script probes. Override with
# FORGEWARD_GSTACK_ROOT, which is also how the test suite drives it.
#
# LIMITATION: a sha256 says the file changed, never whether the change matters. A
# reworded heading and a new category are the same signal here, and reading the
# diff is a human step this cannot do. It is also one-directional: it detects
# gstack moving, not forgeward's own copy being edited away from the source — that
# is what the recorded source-sha256 in each agent file is for, and nothing
# verifies a stale one was updated honestly.
#
# LIMITATION: silence has two causes. No gstack on this machine and no drift both
# print nothing, because a standalone install must not be nagged about a tool it
# deliberately does not have. `--verbose` separates them.

#
# LIMITATION: it needs a sha256 tool. `sha256sum` (GNU coreutils) is tried first and
# `shasum -a 256` (which is what macOS ships) second; if neither is present the script
# says so under --verbose and exits 0 rather than reporting a false all-clear. Two arms
# for one value is normally this repo's `json_get` mistake — it is allowed here only
# because a digest has exactly one correct answer, and it is pinned twice: R7 asserts
# the two arms agree byte-for-byte on this machine, and R8 drives the SECOND arm
# through this script under a PATH with `sha256sum` hidden. R7 alone was not enough --
# it runs both tools by hand and never enters this file, so the `elif` branch below was
# dead code on every machine that has `sha256sum`, which is every CI runner this repo
# uses. A typo inside it would have shipped green and failed only on the macOS installs
# the branch exists for.

set -uo pipefail

# Locale-pinned repo-wide, not per-effect — see CLAUDE.md. A non-interactive script
# must not have its behaviour depend on the invoker's environment.
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
agents_dir="$root/agents"

verbose=0
[ "${1:-}" = "--verbose" ] && verbose=1

# One digest, two spellings of the same tool. See the LIMITATION note above.
if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 -- "$1" 2>/dev/null | cut -d' ' -f1; }
else
  [ "$verbose" -eq 1 ] && printf 'rubric-drift: no sha256sum or shasum on PATH — drift cannot be checked.\n'
  exit 0
fi

# --- locate gstack's rubric tree -------------------------------------------
# gstack does not install to exactly one path, and assuming it does fails in the worst
# available direction: on a plugin-installed gstack this printed what NO gstack prints
# — silence, exit 0 — so drift went unmonitored with nobody told. That is the false
# all-clear the header refuses. Pinned by R13.
#
# TWO GLOB DEPTHS, and the second is the one that fires. The installed layout carries a
# version level — `cache/<marketplace>/<plugin>/<version>/skills`. Enumerated on the
# author's machine: 8 marketplaces, 8 plugins, 15 version directories, 14 holding a
# `skills/`, and zero at the shallower `cache/<marketplace>/<plugin>/skills`. The shallow
# depth is kept defensively rather than from evidence, and R13b is what stops it being
# deleted as dead. The version level is constrained to `[0-9]*` for the reason
# `scripts/forgeward-detect-gstack-skill.sh` gives at its own copy of this loop — a bare `*`
# also matches `node_modules/skills`, which is detection getting more eager — and R13c pins
# it. The two scripts must keep agreeing here; they diverged once and it cost ten versions.
#
# $HOME is guarded, never interpolated straight into a default. Under `set -u` an unset
# HOME makes `${VAR:-$HOME/...}` abort with `HOME: unbound variable` and exit 1 —
# reproduced, not theorised — which breaks the always-exits-0 contract this script
# advertises and that skills/gate/SKILL.md relies on when it calls this inside a gate
# run. `env -i`, some cron and systemd units, and minimal CI containers all reach it.
# The sibling guards this one correctly; that precedent is applied. Pinned by R11.
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  claude_dir="$CLAUDE_CONFIG_DIR"
elif [ -n "${HOME:-}" ]; then
  claude_dir="$HOME/.claude"
else
  claude_dir=""
fi

# An explicit override wins OUTRIGHT and is never merged into the search order: the
# suite drives synthetic roots through it, and a variable that merely joined the list
# would make those assertions depend on whatever gstack happens to be installed on the
# machine running them — the vacuity trap the drift block's header describes.
gs_roots=()
if [ -n "${FORGEWARD_GSTACK_ROOT:-}" ]; then
  gs_roots+=("$FORGEWARD_GSTACK_ROOT")
else
  [ -n "$claude_dir" ] && gs_roots+=("$claude_dir/skills/gstack")
  # A project-local install counts: it is installed for anyone working in this repo.
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] && gs_roots+=("$top/.claude/skills/gstack")
  if [ -n "$claude_dir" ]; then
    for cand in "$claude_dir"/plugins/cache/*/*/skills/gstack \
                "$claude_dir"/plugins/cache/*/*/[0-9]*/skills/gstack; do
      [ -d "$cand" ] && gs_roots+=("$cand")
    done
  fi
fi

gs_root=""
for cand in "${gs_roots[@]:-}"; do
  [ -n "$cand" ] && [ -d "$cand/review/specialists" ] || continue
  gs_root="$cand"
  break
done

if [ -z "$gs_root" ]; then
  [ "$verbose" -eq 1 ] && printf 'rubric-drift: no gstack rubrics at any searched root — nothing to compare. Searched: %s\n' "${gs_roots[*]:-<none>}"
  exit 0
fi

# --- compare each ported reviewer ------------------------------------------
drifted=''
missing=''
malformed=''
checked=0

for f in "$agents_dir"/*-reviewer.md; do
  [ -f "$f" ] || continue
  src_path="$(sed -n 's/^ *source-path: *\(.*[^ ]\) *$/\1/p' "$f" | head -1)"
  src_sha="$(sed -n 's/^ *source-sha256: *\([0-9a-f]\{64\}\) *$/\1/p' "$f" | head -1)"
  [ -n "$src_path" ] && [ -n "$src_sha" ] || continue   # not a ported reviewer

  # A `source-path` with a `..` segment resolves OUTSIDE the rubric tree, and the
  # comparison then reports `ok` for a file that is not the rubric -- the false
  # all-clear this script exists to refuse. This is NOT a security boundary and must
  # not be read as one: `agents/*-reviewer.md` are committed, reviewed files, and
  # anyone who can write one can already put arbitrary instructions in a prompt the
  # model executes, which is a far larger lever than a hash oracle. The guard is here
  # for the realistic case -- a hand-edited or mis-ported provenance block -- and it
  # is LOUD rather than silent, because unlike a reviewer with no provenance at all
  # (normal: six shipped reviewers are not ports) a malformed one is unambiguously a
  # defect, and skipping it quietly would shrink drift coverage with no one told.
  # Slash-wrapped so `..` matches only as a whole segment: `foo..bar.md` is a legal
  # filename and is not rejected. A LEADING slash is left alone deliberately -- string
  # concatenation makes it `$gs_root//etc/passwd`, which stays inside the tree and is
  # already reported as missing (verified). Pinned by R12.
  case "/$src_path/" in
    */../*) malformed="$malformed  $(basename "$f" .md)  ($src_path)
"
            continue ;;
  esac

  checked=$((checked + 1))
  name="$(basename "$f" .md)"
  live="$gs_root/$src_path"

  if [ ! -f "$live" ]; then
    missing="$missing  $name  ($src_path)
"
    continue
  fi

  now="$(sha256_of "$live")"
  if [ "$now" != "$src_sha" ]; then
    drifted="$drifted  $name  ($src_path)
"
  elif [ "$verbose" -eq 1 ]; then
    printf 'rubric-drift: ok       %s\n' "$name"
  fi
done

[ "$verbose" -eq 1 ] && printf 'rubric-drift: %d ported rubric(s) checked against %s\n' "$checked" "$gs_root"

n_drift=$(printf '%s' "$drifted" | grep -c . || true)
n_miss=$(printf '%s' "$missing" | grep -c . || true)
n_bad=$(printf '%s' "$malformed" | grep -c . || true)

if [ "$n_drift" -gt 0 ]; then
  printf 'NOTE: %d ported quality rubric(s) have drifted from the installed gstack copy:\n%s' "$n_drift" "$drifted"
  printf 'Re-port from %s and update source-commit/source-sha256 in the same commit.\n' "$gs_root"
  printf 'The gate is unaffected — forgeward'"'"'s copy is authoritative and was used for this run.\n'
fi

if [ "$n_miss" -gt 0 ]; then
  printf 'NOTE: %d ported rubric(s) no longer exist in the installed gstack copy:\n%s' "$n_miss" "$missing"
  printf 'Upstream may have renamed or removed them. forgeward'"'"'s copy still works; drift can no longer be checked for these.\n'
fi

if [ "$n_bad" -gt 0 ]; then
  printf 'NOTE: %d ported rubric(s) record a source-path that escapes the rubric tree:\n%s' "$n_bad" "$malformed"
  printf 'These were NOT checked. Fix the source-path in the provenance block; a ".." path segment\n'
  printf 'compares against the wrong file and would report a clean run that means nothing.\n'
fi

exit 0
