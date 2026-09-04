#!/usr/bin/env bash
# forgeward-rubric-drift.sh
#
# Report whether forgeward's ported gstack material still matches the files it was
# ported from. Informational only: it prints at most a few lines, never fails a gate,
# and always exits 0.
#
# WHY THIS EXISTS. forgeward's quality reviewers (maintainability, testing,
# performance, api-contract, data-migration) are ports of gstack's Review Army
# specialist checklists, and `skills/audit/` is a port of gstack's `/cso` audit
# phases — all taken under MIT with the source commit and a sha256 recorded in the
# ported file. A port removes the runtime dependency — forgeward reviews quality and
# runs a deep audit on a machine with no gstack at all — but it buys that with drift:
# gstack can improve a checklist and nothing would tell us. This closes that loop the
# cheap way. It is a handful of sha256 comparisons against files that are already on
# disk, so it costs nothing to run inside a gate that is already invoking the
# environment probe.
#
# WHAT IT SCANS: `agents/*-reviewer.md` and `skills/*/SKILL.md`. Neither glob is a
# claim that everything under it is a port — a file with no `source-path`/`source-sha256`
# pair is skipped silently, which is the normal case for the reviewers that are not
# ports and for `skills/gate/` and `skills/ci-gate/`.
#
# TWO SHAPES IT STRUCTURALLY CANNOT SEE, stated as non-goals because an unstated limit
# reads as a claim of coverage:
#   1. A ported artefact placed OUTSIDE both globs is unchecked with nobody told. A glob
#      list is the same narrowing that let the skills directory go unscanned until
#      0.20.0, and nothing detects the next one.
#   2. Only the FIRST `source-path`/`source-sha256` pair in a file is compared (both
#      readers end in `head -1`), so a file ported from two upstream sources is pinned
#      on one of them. That is live, not theoretical: `skills/audit/SKILL.md` takes
#      Phases 2-11 from `cso/sections/audit-phases.md`, which is pinned, and Phases
#      0/1/12/13/14 from `cso/SKILL.md`, which is deliberately not — see
#      THIRD-PARTY-LICENSES.md. A second pair added to a ported file would be read as
#      covered and never compared.
#   3. The three NOTE accumulators render `$name` and `$src_path` RAW, one entry per
#      line, so a name or path holding a newline forges what looks like an extra entry
#      in the printed list. The COUNTS beside them are correct -- they are integers
#      incremented once per entry, which is what R18 pins and why the tail `grep -c`
#      was deleted -- so a run reporting `2 ported rubric(s) have drifted` above three
#      visible lines is the reader seeing this limit, not a miscount. Escaping on the
#      way into the accumulators is the fix and is filed rather than taken: it changes
#      what every drift report looks like, which is a wider blast radius than the
#      defect. This is NOT the same shape as the candidate list below, which had a
#      real joining bug (`${gs_roots[*]}` splitting a spaced path into two entries)
#      and was fixed.
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

# `pwd -P`, not `pwd`. Bash's builtin `pwd` is LOGICAL: invoked through a symlinked
# `scripts/` directory it returns the symlink's path, `$here/..` is then the symlink's
# parent rather than the plugin root, and `agents_dir`/`skills_dir` point at nothing.
# Every file falls through the `[ -f "$f" ] || continue` guard and the run is silent
# with rc=0 -- byte-identical to a clean run. Reproduced before fixing. Symlinking the
# whole plugin directory was always safe and stays safe; this is about symlinking the
# `scripts/` directory alone.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$here/.." && pwd -P)"
agents_dir="$root/agents"
skills_dir="$root/skills"

verbose=0
[ "${1:-}" = "--verbose" ] && verbose=1

# One digest, two spellings of the same tool. See the LIMITATION note above.
#
# HASHED THROUGH STDIN, NOT BY FILENAME, AND THAT IS NOT A STYLE CHOICE. Given a path
# containing a backslash or a newline, GNU coreutils escapes the whole output line: it
# prefixes it with `\` and escapes the offending character. `cut -d' ' -f1` then returns
# `\73cb...` where the digest is `73cb...`, the comparison at the drift test can never
# match, and every affected rubric is reported as DRIFTED with a printed instruction to
# re-port a file that is byte-identical. Measured, not reasoned: `sha256sum -- 'a\b.md'`
# emits `\73cb3858...`, and `sha256sum < 'a\b.md'` emits `73cb3858...`.
#
# The serious form reaches through `gs_root`, not the rubric name -- a `HOME`,
# `CLAUDE_CONFIG_DIR` or plugin-cache path holding a backslash makes EVERY port report as
# drifted at once, and `skills/gate/SKILL.md` instructs the gate to relay that verbatim.
# So the blast radius is a path this script does not choose and cannot validate.
# R16 tested a SPACE and read as covering the class; a space is the one metacharacter
# `sha256sum` does not escape, which is exactly how a sample gets mistaken for a spec.
# R16b pins the backslash and is a pre-fix control. `shasum` has the identical defect and
# gets the identical treatment. The group redirect (rather than a trailing `2>/dev/null`)
# is what keeps a failed redirect on an unreadable file quiet, since redirections are set
# up before the commands inside the group run.
if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { { sha256sum < "$1" | cut -d' ' -f1; } 2>/dev/null; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { { shasum -a 256 < "$1" | cut -d' ' -f1; } 2>/dev/null; }
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

# TWO LANDMARKS AND TWO PASSES. A candidate qualifies as a gstack checkout if it holds
# `review/specialists` (where the five reviewer rubrics come from) or `cso` (where the
# audit phases come from). Pass 1 takes the first candidate holding ALL of them, so a
# checkout that can answer every ported artefact always beats one that can answer some.
# Pass 2 is the fallback for a genuinely partial machine, and it is landmark-major
# rather than candidate-major so a `cso`-only root cannot shadow a `review/specialists`
# root that sorts later.
#
# THE COMPLETENESS PASS IS NOT A NICETY. Without it the first candidate holding EITHER
# landmark won outright, and the plugin-cache candidates arrive glob-sorted — so a
# marketplace or version directory that sorts earlier (`1.10.0` sorts before `1.9.0`)
# and predates `cso/` was selected over a complete checkout on the same machine. The
# run then printed `no longer exist ... Upstream may have renamed or removed them` for
# the audit port while the file it names sat on disk one directory over: an advisory
# telling the user something false about upstream, which is worse than the silence this
# script defaults to. Reproduced before the fix and pinned by R14e.
#
# Both passes read ONE list, so adding a third landmark cannot update one and miss the
# other — but note that it silently widens what pass 1 counts as "complete", and a
# machine holding two of three landmarks then falls through to pass 2. Neither landmark
# matches `~/.claude/skills/review`, the stub that holds SKILL.md and nothing else,
# which is the configuration this must keep NOT firing on. A port from some third
# gstack subtree would need its landmark added here; nothing detects that.
gs_landmarks=(review/specialists cso)
gs_root=""
for cand in "${gs_roots[@]:-}"; do
  [ -n "$cand" ] || continue
  all_present=1
  for landmark in "${gs_landmarks[@]}"; do
    [ -d "$cand/$landmark" ] || { all_present=0; break; }
  done
  if [ "$all_present" -eq 1 ]; then
    gs_root="$cand"
    break
  fi
done
if [ -z "$gs_root" ]; then
  for landmark in "${gs_landmarks[@]}"; do
    for cand in "${gs_roots[@]:-}"; do
      [ -n "$cand" ] && [ -d "$cand/$landmark" ] || continue
      gs_root="$cand"
      break 2
    done
  done
fi

if [ -z "$gs_root" ]; then
  # THREE LINES, NOT ONE, AND THE THIRD IS THE POINT. The old single line ended
  # `Searched: %s`, which reads as a complete account of where this script looked and is
  # not one: a plugin-cache path enters `gs_roots` only when `[ -d ]` already holds, so
  # the locations that do not exist were never candidates and never appear -- while the
  # explicit root and the two fixed locations are appended unguarded and appear whether
  # they exist or not. One word covered both, mixing "looked here, nothing there" with
  # "never looked", and someone debugging a silent run acts on that difference.
  # Dropping the `[ -d ]` guard to make the list uniform is the wrong fix: an unmatched
  # glob would then put its own literal pattern into the list. Say what the list is
  # instead. Pinned by R19.
  if [ "$verbose" -eq 1 ]; then
    printf 'rubric-drift: no gstack rubrics at any searched root — nothing to compare.\n'
    # ONE PER LINE, because the six lines around this one exist to make the reader parse
    # it as an enumeration of what was and was not tested. `${gs_roots[*]}` joins on a
    # space, so a candidate path containing a space renders as two entries and one
    # containing a newline forges an extra -- in the exact output that is claiming to be
    # a precise account of coverage. `[@]` with a per-element format cannot do either.
    printf 'rubric-drift: candidates tested:\n'
    if [ "${#gs_roots[@]}" -eq 0 ]; then
      printf 'rubric-drift:   <none>\n'
    else
      printf 'rubric-drift:   %s\n' "${gs_roots[@]}"
    fi
    printf 'rubric-drift: tested, not considered — a plugin-cache path becomes a candidate only if it\n'
    printf 'already exists, so cache locations that do not exist were never tested and cannot appear\n'
    printf 'above. Every other candidate form (FORGEWARD_GSTACK_ROOT, and the two fixed locations it\n'
    printf 'overrides) is listed whether or not it exists.\n'
  fi
  exit 0
fi

# --- compare each ported reviewer ------------------------------------------
drifted=''
missing=''
malformed=''
# COUNTED AT THE APPEND SITE, NOT AT THE TAIL. These three were `printf '%s' "$x" | grep -c .`
# on the accumulated strings, which counts LINES; a rubric whose name carries a newline is
# one entry across two lines and over-counted by one. The name comes from a skill DIRECTORY
# name or a reviewer FILENAME, both of which may legally hold a newline, so the input is not
# under this script's control. Incrementing here is the only form that cannot disagree with
# the string it describes. R18 is the pre-fix control. Do not reintroduce a tail count.
n_drift=0
n_miss=0
n_bad=0
# TWO COUNTERS, NOT ONE, AND THEY ANSWER DIFFERENT QUESTIONS. `parsed` is how many files
# carried a readable provenance block; `checked` is how many of those had a live upstream
# file to hash. They diverge exactly when a port goes missing upstream, which is reported,
# and `parsed` is the one the vacuity guard needs -- a run that parses nothing has nothing
# to say about drift and must not look like a run that found none.
parsed=0
checked=0

for f in "$agents_dir"/*-reviewer.md "$skills_dir"/*/SKILL.md; do
  [ -f "$f" ] || continue
  # BOTH READERS ARE DELIBERATELY TOLERANT ON THE THINGS THAT ARE NOT THE VALUE, because
  # every way this reader can miss produces the same output as a clean run. Two shapes
  # were reproduced against the strict form: a CRLF checkout (the trailing `\r` defeated
  # a ` *$` anchor and parsed ZERO ports out of the whole plugin), and an uppercase
  # digest (PowerShell's `Get-FileHash` and GitHub's blob view both emit uppercase, and
  # this is a plugin people install on Windows). `[[:space:]]` under the script-wide
  # `LC_ALL=C` covers `\r` and tabs; the digest is matched case-insensitively and folded
  # to lowercase, because `A9F` and `a9f` are the same hash and rejecting one of them
  # buys nothing. The `parsed` guard below is the backstop for the misses this does not
  # anticipate -- a tolerant regex narrows the class, it does not close it.
  src_path="$(sed -n 's/^[[:space:]]*source-path:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' "$f" | head -1)"
  src_sha="$(sed -n 's/^[[:space:]]*source-sha256:[[:space:]]*\([0-9a-fA-F]\{64\}\)[[:space:]]*$/\1/p' "$f" | head -1)"
  [ -n "$src_path" ] && [ -n "$src_sha" ] || continue   # not a port
  # `sed y///`, not `tr` and not bash's `${x,,}`. `tr` would be a NEW external tool on a
  # script whose whole dependency set is one digest tool plus sed/cut/basename/dirname/
  # head/grep -- and R8 caught it the moment it was added, by running this file under a
  # PATH holding only that set. `${x,,}` is bash 4.0, and the `shasum` branch above exists
  # because this runs on macOS, where `/usr/bin/env bash` can still be 3.2 and the
  # expansion is a SYNTAX error -- which takes the whole script down rather than one
  # comparison. `y` is POSIX sed and costs nothing already spent.
  src_sha="$(printf '%s' "$src_sha" | sed 'y/ABCDEF/abcdef/')"
  parsed=$((parsed + 1))

  # NAMING. A reviewer is `agents/<name>-reviewer.md` and names itself; a ported skill
  # is `skills/<name>/SKILL.md`, where the basename is a constant and the DIRECTORY
  # carries the identity. Taking the basename for both reported the audit skill as
  # `SKILL` — not a name, and the same string for every skill that is ever ported, so
  # two drifting skills would print one indistinguishable line each. Derived once here,
  # above the traversal guard, so the malformed report uses the same key as every other
  # branch -- and each of the four exits a file can take is pinned by its own assertion,
  # because "derived once" is a claim about this line and the branches are what a reader
  # sees: R14 (ok), R14f (drifted), R14c (missing) and R14g (malformed). This comment
  # said "pinned by R14" for four rounds and R14 reaches only the first of them, which is
  # the shape worth naming: a comment asserting coverage it does not have is a defect on
  # its own account, not merely a label on the gap it hides.
  # What this does NOT resolve: `agents/x-reviewer.md` alongside
  # `skills/x-reviewer/SKILL.md` would print the same key twice. No such pair exists and
  # nothing enforces it.
  case "$(basename "$f")" in
    SKILL.md) name="$(basename "$(dirname "$f")")" ;;
    *)        name="$(basename "$f" .md)" ;;
  esac

  # A `source-path` with a `..` segment resolves OUTSIDE the rubric tree, and the
  # comparison then reports `ok` for a file that is not the rubric -- the false
  # all-clear this script exists to refuse. This is NOT a security boundary and must
  # not be read as one: both globs read committed, reviewed files that the model
  # EXECUTES as instructions -- a reviewer prompt and a skill alike -- so anyone who can
  # write one already has a far larger lever than a hash oracle. The guard is here
  # for the realistic case -- a hand-edited or mis-ported provenance block -- and it
  # is LOUD rather than silent, because unlike a reviewer with no provenance at all
  # (normal: six shipped reviewers are not ports) a malformed one is unambiguously a
  # defect, and skipping it quietly would shrink drift coverage with no one told.
  # Slash-wrapped so `..` matches only as a whole segment: `foo..bar.md` is a legal
  # filename and is not rejected. A LEADING slash is left alone deliberately -- string
  # concatenation makes it `$gs_root//etc/passwd`, which stays inside the tree and is
  # already reported as missing (verified). Pinned by R12.
  case "/$src_path/" in
    */../*) malformed="$malformed  $name  ($src_path)
"
            n_bad=$((n_bad + 1))
            continue ;;
  esac

  live="$gs_root/$src_path"

  if [ ! -f "$live" ]; then
    missing="$missing  $name  ($src_path)
"
    n_miss=$((n_miss + 1))
    continue
  fi
  checked=$((checked + 1))

  now="$(sha256_of "$live")"
  if [ "$now" != "$src_sha" ]; then
    drifted="$drifted  $name  ($src_path)
"
    n_drift=$((n_drift + 1))
  elif [ "$verbose" -eq 1 ]; then
    printf 'rubric-drift: ok       %s\n' "$name"
  fi
done

[ "$verbose" -eq 1 ] && printf 'rubric-drift: %d ported rubric(s) parsed, %d checked against %s\n' "$parsed" "$checked" "$gs_root"

# THE VACUITY GUARD, AND IT IS THE REASON SILENCE FROM THIS SCRIPT MEANS ANYTHING. Every
# other branch here is verbose-only, and the gate invokes this script with no arguments --
# so before this existed, "checked 6 files, all clean" and "checked 0 files because the
# reader broke" were the same empty output on the same exit code. That is the worst shape
# an advisory can take: it is not that the check is missing, it is that its absence is
# indistinguishable from its success. Unconditional on purpose.
#
# It fires only when a gstack root WAS found, so the ordinary no-gstack machine -- the one
# this port exists to serve -- stays silent as designed. The one legitimate configuration
# it would fire on is a fork that has deleted every ported rubric while keeping this
# script; there the remedy is to delete the script too, and an informational line that
# never fails a gate is an acceptable cost for closing a silent-zero.
if [ "$parsed" -eq 0 ]; then
  printf 'NOTE: a gstack checkout was found at %s but NO ported rubric could be read.\n' "$gs_root"
  printf 'forgeward ships ported rubrics, so this is a defect in this run rather than a clean result:\n'
  printf 'the provenance blocks did not parse (a CRLF checkout does this), or agents/ and skills/ were\n'
  printf 'not where this script looked. Drift was NOT checked. Re-run with --verbose for the roots tried.\n'
fi

if [ "$n_drift" -gt 0 ]; then
  printf 'NOTE: %d ported rubric(s) have drifted from the installed gstack copy:\n%s' "$n_drift" "$drifted"
  printf 'Re-port from %s and update source-commit/source-sha256 in the same commit.\n' "$gs_root"
  printf 'The gate is unaffected — forgeward'"'"'s copy is authoritative and was used for this run.\n'
fi

if [ "$n_miss" -gt 0 ]; then
  printf 'NOTE: %d ported rubric(s) no longer exist in the installed gstack copy:\n%s' "$n_miss" "$missing"
  printf 'Compared against %s. Upstream may have renamed or removed them -- but a wrong root or an\n' "$gs_root"
  printf 'unreadable directory produces this same line, so check that path before believing the upstream\n'
  printf 'half. forgeward'"'"'s copy still works either way; drift can no longer be checked for these.\n'
fi

if [ "$n_bad" -gt 0 ]; then
  printf 'NOTE: %d ported rubric(s) record a source-path that escapes the rubric tree:\n%s' "$n_bad" "$malformed"
  printf 'These were NOT checked. Fix the source-path in the provenance block; a ".." path segment\n'
  printf 'compares against the wrong file and would report a clean run that means nothing.\n'
fi

exit 0
