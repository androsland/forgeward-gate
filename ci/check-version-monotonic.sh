#!/usr/bin/env bash
# ci/check-version-monotonic.sh [<base-ref>]        default base-ref: origin/master
#
# Refuse a merge that would move the plugin version BACKWARD, and refuse one that
# moves only some of the four manifests that carry it. Exit 0 and print a one-line
# summary when the branch is safe to merge, exit 1 and name the offending file when
# it is not.
#
# WHY THIS EXISTS. The version lives in four manifests -- package.json,
# .claude-plugin/plugin.json, .claude-plugin/marketplace.json, and
# .codex-plugin/plugin.json -- and nothing until
# now checked that a merge moved it forward, so merge ORDER was load-bearing whenever
# two version-bumping PRs were open at once. On 2026-08-06 #17 bumped to 0.7.5 and #18
# to 0.7.6; merging #17 second would have taken the marketplace manifest 0.7.6 -> 0.7.5,
# and most plugin-manager update logic reads a backward version as no-op-or-worse rather
# than as an upgrade. That instance was avoided by merging #17 first, BY HAND. The hazard
# was never fixed, only dodged, and the only thing keeping four manifests monotonic was
# whoever happened to be paying attention at merge time.
#
# WHY CI AND NOT THE GATE. The gate is structurally the wrong layer and cannot be made
# the right one. V1-V3 deliberately neutralize a version-only bump in the substantive-diff
# hash so a release does not force a spurious re-gate, and that neutralization is
# DIRECTION-BLIND: a backward bump is exactly as invisible to the hash as a forward one.
# Nothing that reads the hash can see this class at all. It needs a check that compares
# two refs, which is what CI has and a local pre-push hook does not.
#
# THE RULE IS "NEVER BACKWARD", NOT "ALWAYS BUMP". Equality passes. Most PRs here are
# docs or fixes that do not touch the version (#21 is one), and a check that demanded a
# bump on every branch would fire on all of them -- a false FAIL on the common case,
# which is how a release check gets disabled. Only a strict DECREASE is refused.
#
# FAILS CLOSED, LOUDLY. Every uncertain answer is an exit 1 with the reason printed.
# That is the opposite of the direction the gate hook takes, and deliberately so: this
# runs in CI where a false red costs one human glance, while the hook fires on every
# Bash tool call and a false red wedges the session. Nothing here should be relaxed to
# make it quieter.
#
# BLIND SPOTS, stated so they are not mistaken for coverage:
#
#   1. It cannot see whether a version SHOULD have been bumped. A behaviour change that
#      ships under an unchanged version passes clean. This checks direction, never
#      whether the number earned its increment.
#   2. It reads X.Y.Z and refuses everything else, prereleases and build metadata
#      included (`0.9.0-rc1`, `0.9.0+build`). This repo has never shipped one. If that
#      changes, the refusal is a red CI run and a deliberate edit here -- not a silent
#      mis-comparison, which is what a hand-rolled prerelease ordering would produce.
#   3. It requires EXACTLY ONE `version` key per manifest, AT ANY DEPTH, and refuses
#      ambiguity rather than guessing which one is the plugin's. All four files have
#      exactly one today (marketplace.json's sits under `.plugins[]`). A nested version
#      added later turns this red on the next PR, which is the intended way to find out.
#      Duplicate keys within one object are refused separately and by name: a parser
#      resolves those last-wins in silence, so counting keys after parsing would see one
#      where the file has two.
#   4. A manifest absent from the base ref is skipped for the backward comparison (there
#      is no prior value to compare against) but still has to agree with the others on
#      the head side. Adding a manifest is a legitimate configuration and must not fire.
#      ALL FOUR absent is the different case and is refused, not skipped: a run that
#      compared nothing has no evidence to report a pass from, and "ok" on zero
#      comparisons is the vacuous green this repo has been burned by before. The cost is
#      that the one-time bootstrap PR introducing the manifests to a repo goes red and
#      needs a human to wave it through. Accepted -- it happens once, and the
#      alternative is a check that is silently inert on a repo that never had them.
#   5. It compares the CHECKED-OUT tree against a ref. Under `pull_request` the workflow
#      checks out the PR head sha explicitly rather than GitHub's synthetic merge commit,
#      so what is compared is what the author wrote. See the workflow for why.
#   6. It requires `python3` and reads the manifests with the stdlib `json` module. That
#      is a real external dependency and the only one -- see the note above read_version
#      for why a textual reader could not be made correct and why there is no second arm.
#      A box without python3 gets a named FAIL, never a quiet skip.
#      Read "the stdlib `json` module" as a claim that has to be EARNED, not a given:
#      this script runs from the root of the checkout it is judging, and an interpreter
#      takes part of its configuration from its environment and its CWD. Until round 6
#      that sentence was simply false -- `python3 -c` puts the CWD on `sys.path`, so a
#      `json.py` committed by the PR author was the module doing the parsing. `-I` at the
#      call site is what makes the sentence true; do not remove it. Pinned by R22/R22b/R22c.
#      A python too old for `-I` (pre-3.4) fails closed with the interpreter's own error
#      plus `returned no usable answer` -- verified, not assumed.
#   7. It validates the version FIELD, not the manifest. `json.load` will reject a file
#      that is not well-formed JSON or not valid UTF-8, so those two classes are covered
#      as a side effect, but nothing here checks that the rest of the document means
#      anything -- a manifest can be structurally valid and semantically nonsense and
#      this will happily compare its version. Widening that is open in TODOS.md.
#   8. It reports the version it read, and that number is only as trustworthy as the
#      channel it came back through. Round 5 is the entry to re-read before touching
#      `read_version`: `$(...)` deletes NUL bytes and strips trailing newlines, so a
#      value validated on the SHELL side is not necessarily the value in the file. The
#      shape check now runs inside the parser for that reason. Any future field read out
#      of a manifest has the same problem and needs the same treatment.
#   9. Under `pull_request` this script and its workflow are both read from the PR head,
#      so an author who wants the check gone can edit THIS FILE. That is inherent to any
#      repo-content-driven required check and is not fixable here -- the mitigations are
#      branch protection on workflow files and a human reading the diff. It is listed so
#      the check is not mistaken for an authority it does not have. Note this does NOT
#      make blind spot 6 moot, which is the tempting conclusion: editing the checker is
#      conspicuous in a diff, and a stray `json.py` at the repo root is not. The whole
#      value of that fix is that it forces the attack into the reviewable direction.
#  10. It reads the COMMITTED tree, never the working tree, so uncommitted edits to a
#      manifest are not considered -- see the note above the head-side loop for why that
#      is the correct reading and not merely the safe one. A hand-run against a dirty
#      worktree prints a note naming the files it ignored, because a check that silently
#      answers about a different version of the file than the one on your screen is a
#      debugging trap. The note is stderr-only and never changes the verdict.
set -uo pipefail

# Script-wide and exported. Be honest about what this is worth NOW, because its original
# reason is gone: it was added when round 3 found that GNU grep under a UTF-8 locale
# silently drops a line holding invalid UTF-8, which let a poisoned duplicate `version`
# key hide from the textual reader. Round 4 then broke that reader a different way and
# the extraction became a real JSON parser (see read_version), which reads raw bytes and
# is locale-independent -- so the bypass this line was added to close is now closed by
# construction, one layer up.
#
# What remains is genuinely smaller: `num_lt`'s `[[ x < y ]]` is a byte comparison only
# under a C locale, and deterministic tool output generally. No locale on this machine
# collates ASCII digits out of code-point order, so that effect is unobservable here and
# no assertion pins it -- stated plainly rather than left to read as covered. It stays
# because the cost is one line and the failure it prevents is a silent mis-ordering.
#
# Keep it `export`, not `local`. A `local` assignment is NOT passed to a spawned child
# unless the name was already exported -- verified: `local` gives the child `<unset>`,
# a command prefix and `export` both give it `C`. The `local` form works for a bash
# builtin and silently does nothing for any child process, which is the worst
# combination: it reads as the same pin and is not one. `num_lt` used to carry its own
# `local LC_ALL=C` and it was removed rather than kept beside this, because two
# mechanisms claiming one job is how the next reader trusts the wrong one -- and there
# the redundant mechanism was precisely the ineffective one.
export LC_ALL=C

BASE="${1:-origin/master}"

MANIFESTS="package.json .claude-plugin/plugin.json .claude-plugin/marketplace.json .codex-plugin/plugin.json"

die() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# The git mode of a path at a ref, empty when the path is not there. `--full-tree` so the
# pathspec resolves against the repo ROOT regardless of the caller's cwd, which is how
# the `<ref>:<path>` syntax used to fetch the content resolves too -- the two must not
# disagree about what `$f` names, or the file whose mode was approved is not the file
# that gets parsed. As a side effect the whole check now works from a subdirectory, which
# the worktree read it replaces did not.
tree_mode() { # tree_mode <ref> <path>
  local line mode
  line="$(git ls-tree --full-tree "$1" -- "$2" 2>/dev/null)"
  read -r mode _ <<<"$line"
  printf '%s' "${mode:-}"
}

# 0 when <path> is a regular file at <ref>, 1 when it is absent, and a hard exit for
# anything else. Round 7 of the security review, and the reason it refuses rather than
# tolerates: git tracks exactly four kinds of entry, and only one of them is a manifest.
# A symlink (mode 120000) is the dangerous one -- see the note above the head-side loop.
# A gitlink and a tree are not attacks, just nonsense in this position, and guessing at
# nonsense is how a check reports a pass it did not establish.
require_blob() { # require_blob <ref> <path> <label>
  local m
  m="$(tree_mode "$1" "$2")"
  case "$m" in
    100644|100755) return 0 ;;
    '')            return 1 ;;
    120000) die "$3 is a symlink, not a file -- refusing to read through it (blind spot 10)" ;;
    160000) die "$3 is a submodule gitlink, not a manifest -- refusing to guess what it means" ;;
    *)      die "$3 has git mode $m, which is not a regular file -- refusing to guess what it means" ;;
  esac
}

# A REAL JSON PARSER, and the reason is that text-matching this field lost four times.
#
# The extraction used to be `grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"'`. Three
# separate review rounds each broke it in a way the previous round's fix did not cover:
#
#   - `grep -c` counted matching LINES, so two keys on one line counted as one.
#   - Under a UTF-8 locale GNU grep silently drops a line holding invalid UTF-8, so a
#     poisoned duplicate key was invisible while every JSON parser still read it.
#   - `"version"` is spec-legal JSON that decodes to the key `version` and contains
#     no literal `"version"` bytes at all. Demonstrated: a clean decoy plus an escaped
#     duplicate carrying 0.1.0 printed `ok: version 0.9.1, not behind master`, exit 0,
#     while `JSON.parse` and `json.load` both read 0.1.0.
#
# The third one is the one that settles the argument, because it is not a bug in the
# pattern -- it is the pattern's premise failing. Any of the seven characters in the key
# can be escaped independently, so there is no finite set of spellings to match, and a
# textual reader will always disagree with the parser that the plugin manager actually
# uses. The threat model here is a value a JSON parser will load, so the check has to
# read it the way that parser does or it is guessing.
#
# WHY python3 AND NOT jq, AND WHY ONE ARM. This repo shipped a divergence between a `jq`
# arm and a `python3` arm once (0.7.5, `jq -S` vs the fallback, different bytes for the
# same manifest, V7/V8 exist because of it) and the standing conclusion is "one arm
# everybody gets beats a better arm some people get". Two earlier proposals to add a
# parser were DECLINED, and neither reason survives here: PyYAML is not stdlib, but
# `json` is; and `forgeward-write-marker.sh` runs on arbitrary user machines where the
# fewest ways to fail wins, while this runs on `ubuntu-latest` plus a developer shell.
# So: exactly one arm, stdlib only, no jq, no fallback to a second parser that could
# disagree with the first. If python3 is absent the run FAILS -- see the preflight.
#
# It also closes two classes for free: a manifest that is not valid UTF-8, and one that
# is not valid JSON, are now refused by name instead of being mis-read. And duplicate
# keys are refused explicitly via `object_pairs_hook` rather than inferred from a count
# -- the parser resolves duplicates last-wins silently, so counting after the fact would
# see one key where the file has two.
# THE SHAPE CHECK LIVES IN HERE, NOT IN THE SHELL, AND THAT IS THE WHOLE POINT.
# Round 5 of the security review found the mirror image of the bug the stdin pipe below
# was added to fix: the INPUT crossed the boundary intact and the OUTPUT did not.
# `out="$(python3 ...)"` deletes NUL bytes and strips trailing newlines, both of which
# are legal inside a JSON string (`"1\u00009.0.0"`, `"1.0.0\n"`), and both of which were
# applied BEFORE the old bash-side `X.Y.Z` regex ever saw the value. So the regex
# validated a string the file does not contain: `19.0.0` was spliced into `19.0.0`
# and passed, and the run printed a version no parser would ever produce. Demonstrated
# end to end; `1\u00000.0.0` reads as a forward `10.0.0` here while anything truncating
# at NUL sees `1`, i.e. backward -- the exact hazard this file exists to stop.
#
# Validating here means only a string matching `[0-9]+\.[0-9]+\.[0-9]+` is ever handed
# to the shell, and such a string is by construction immune to every transform command
# substitution performs. That is a closed argument about the whole channel rather than a
# patch for the two transforms that happen to be known -- the same move as round 4, for
# the same reason: the third one is not enumerable in advance.
#
# `re.fullmatch`, NOT `re.match(...$)`. In Python `$` also matches just before a trailing
# newline, so `re.match(r"^[0-9]+\.[0-9]+\.[0-9]+$", "1.0.0\n")` MATCHES -- which would
# have reimplemented the exact bypass being fixed, in the line fixing it. `fullmatch` has
# no such exception.
READ_VERSION_PY='
import json, re, sys

def say(s):
    # Every exit goes through here so no path can forget to answer.
    sys.stdout.buffer.write(s.encode("utf-8", "replace"))
    sys.exit(0)

def no_dupes(pairs):
    seen = {}
    for k, v in pairs:
        if k in seen:
            say("err:duplicate key " + json.dumps(k))
        seen[k] = v
    return seen

raw = sys.stdin.buffer.read()
try:
    text = raw.decode("utf-8")
except UnicodeDecodeError as e:
    say("err:not valid UTF-8 (%s)" % e)

found = []
def walk(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "version":
                found.append(v)
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)

try:
    walk(json.loads(text, object_pairs_hook=no_dupes))
except ValueError as e:
    say("err:not valid JSON (%s)" % e)
except RecursionError:
    say("err:nested too deeply for the JSON reader to walk")

if len(found) != 1:
    say("err:expected exactly 1 version field, found %d" % len(found))
v = found[0]
if not isinstance(v, str):
    say("err:version is a JSON %s, not a string" % type(v).__name__)
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", v):
    # json.dumps so the reason can name the value without shipping raw control
    # bytes back through the same command substitution that mangles them.
    say("err:version %s is not X.Y.Z (blind spot 2)" % json.dumps(v))
say("ok:" + v)
'

# Reads a manifest on STDIN and prints its version, or returns 1 having said why.
#
# Stdin rather than an argument ON PURPOSE. The old signature took the content as a
# shell string via `$(cat "$f")`, and command substitution strips trailing newlines and
# silently drops NUL bytes -- so the bytes being validated were not the bytes on disk.
# A pipe carries the file through unaltered, which is the only way "the check read what
# the parser will read" can be true. Note that this paragraph was already here, correctly
# naming both transforms, while the RETURN path below still performed both of them --
# see the round-5 note above READ_VERSION_PY. Knowing a hazard by name is not a guard
# against it, and a comment that proves you knew is not mitigation.
#
# The helper reports failures on STDOUT as `err:<reason>` rather than by exit status,
# because an exit status cannot distinguish "python3 refused this manifest" from
# "python3 is not installed" from "python3 was killed" -- and treating those alike is
# exactly the error-path class DECISIONS.md records as this repo's most repeated bug
# (an error path returning the same value as a legitimate empty result). Anything that
# is neither `ok:` nor `err:` is therefore itself a refusal, not a pass.
read_version() { # read_version <label>   [JSON on stdin]
  local out v
  # `-I`, and it is load-bearing. Round 6 of the security review: `python3 -c` sets
  # `sys.path[0]` to `''`, which resolves to the CURRENT WORKING DIRECTORY -- and this
  # script runs from the root of the very checkout it is judging. So `import json` was
  # resolved against repo content. A fork PR author drops a five-line `json.py` at the
  # repo root beside a genuine backward bump and `json.loads` returns whatever they
  # like. Reproduced end to end: base 9.0.0, head manifests genuinely 1.0.0, output
  # `ok: version 999.999.999, not behind master`, exit 0. The bash regex below cannot
  # see it -- the forged value is a perfectly well-formed X.Y.Z string.
  #
  # `-I` rather than a `sys.path` edit inside READ_VERSION_PY, because the CWD entry is
  # one of FOUR channels by which the repo under test configures the interpreter judging
  # it, and patching one is how rounds 2-4 went. `-I` closes the set: it drops the
  # CWD/script-dir entry, implies `-E` (ignore PYTHONPATH and the other PYTHON* vars)
  # and `-s` (ignore user site-packages, which also disables `usercustomize`). Available
  # since Python 3.4. Anything reading a manifest here must keep it.
  out="$(python3 -I -c "$READ_VERSION_PY")"
  case "$out" in
    ok:*)  v="${out#ok:}" ;;
    err:*) printf '%s in %s\n' "${out#err:}" "$1" >&2; return 1 ;;
    *)     printf 'the JSON reader returned no usable answer for %s -- refusing to guess\n' "$1" >&2; return 1 ;;
  esac
  # Belt-and-braces only. The AUTHORITATIVE shape check is inside READ_VERSION_PY, on
  # the far side of the command substitution -- see the round-5 note there for why it
  # cannot live here. This line is kept because it costs nothing and it catches the one
  # thing the python side cannot: a future edit that widens what `ok:` may carry.
  #
  # Bash regex, NOT `printf | grep -q`. Under the `set -o pipefail` above, `grep -q`
  # exits on match and can SIGPIPE the printf still writing to it; pipefail then
  # promotes 141 to the pipeline status and the test reports NO-MATCH on input it
  # just matched. That is the P1 in DECISIONS.md, found by a 20000-trial probe, and
  # it must not be reintroduced here.
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { printf 'version %s in %s did not survive the shell intact\n' "$v" "$1" >&2; return 1; }
  printf '%s' "$v"
}

# Strip leading zeros from a digit string, keeping a lone `0`. `1.08.0` is a legal
# shape for the regex above, and `08` must read as eight.
strip0() { local s="${1#"${1%%[!0]*}"}"; printf '%s' "${s:-0}"; }

# 0 when digit string $1 is numerically less than $2. NO BASH ARITHMETIC anywhere in
# this comparison, and that is the entire point.
#
# The first draft was component-wise `$((10#$a1))`, chosen over the obvious weighted
# sum `major*1000000 + minor*1000 + patch` because that form silently ties `1.0.1000`
# with `1.1.0`. The comment above it then claimed the fix had "no such ceiling", and
# the security review falsified that in one command: bash arithmetic is fixed-width
# signed 64-bit, so a component at or above 2^63 wraps two's-complement -- and nothing
# upstream bounded what reached it, because the validating regex accepts a digit run of
# ANY length. Demonstrated end to end: base `18446744073709551617.0.0`, head reverted
# to `1.0.0` -- a drastic backward move, the exact hazard this file exists to stop --
# printed `ok ... not behind` and exited 0. The ceiling had moved from 10^3 to 2^63; it
# had not gone away, and the comment asserting otherwise is how it survived review.
#
# Length-then-bytes has no ceiling at all, for real this time: with leading zeros gone,
# the longer numeral is always the larger one, and two numerals of EQUAL length compare
# numerically under a plain byte comparison because ASCII digits ascend in code-point
# order. That last step is bytes rather than ambient collation because of the
# script-wide `export LC_ALL=C` at the top -- this function used to carry its own
# `local LC_ALL=C`, which was removed rather than kept alongside it: two mechanisms
# claiming one job is how the next reader picks the wrong one to trust, and the `local`
# form is the one that does not survive a fork to `grep`. See the note by the export.
num_lt() { # num_lt <digits> <digits>
  local x y
  x="$(strip0 "$1")"; y="$(strip0 "$2")"
  [ "${#x}" -ne "${#y}" ] && { [ "${#x}" -lt "${#y}" ]; return $?; }
  [[ $x < $y ]]
}

# 0 when version $1 is strictly less than version $2. Callers must validate X.Y.Z
# first -- `read_version` does.
version_lt() { # version_lt <a> <b>
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$1"
  IFS=. read -r b1 b2 b3 <<<"$2"
  [ "$(strip0 "$a1")" != "$(strip0 "$b1")" ] && { num_lt "$a1" "$b1"; return $?; }
  [ "$(strip0 "$a2")" != "$(strip0 "$b2")" ] && { num_lt "$a2" "$b2"; return $?; }
  num_lt "$a3" "$b3"
}

# The one external requirement, checked up front so a missing interpreter is a named
# failure rather than three identical "no usable answer" lines. `ubuntu-latest` ships
# python3; a developer box running this by hand almost certainly has it. Deliberately
# NOT softened into a grep fallback -- the fallback is the thing that was broken, and a
# second arm that disagrees with the first is the divergence class this repo already
# paid for. No python3, no answer.
command -v python3 >/dev/null 2>&1 \
  || die "python3 is required to read the manifests (stdlib json only) and is not on PATH"

git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1 \
  || die "base ref '$BASE' does not resolve -- CI needs a full-history checkout (fetch-depth: 0)"

# --- head side: all four manifests must agree with each other ---------------------
# READ FROM THE OBJECT STORE, NOT THE WORKING TREE, and this is round 7's fix rather than
# a tidiness preference. The loop used to be `[ -f "$f" ]` then `read_version "$f" < "$f"`.
# A `<` redirect is a plain open(2), and open(2) FOLLOWS SYMLINKS -- while git natively
# tracks symlinks as mode 120000, so a fork PR author can commit `package.json` as a link
# to any absolute path on the CI runner and the check will dutifully parse whatever is
# there. Reproduced end to end: four manifests committed as symlinks to a file OUTSIDE
# the checkout, base at 9.0.0, and the check printed `ok: version 13.37.0, not behind
# master (4 manifest(s) compared, all four agree)` and exited 0 -- a PASS asserted about
# a commit that contains no version field anywhere, on the strength of a file that is not
# in the commit and never will be. Pointed at a file that merely EXISTS on the runner it
# also reflects a fragment of it into a world-readable job log.
#
# The tell was an asymmetry the file's own header described without noticing: the base
# side reads through `git show`, which returns a symlink's BLOB -- the literal target
# string -- and never dereferences it, so the base side was never exposed. One side asked
# git and one side asked the filesystem, and only the filesystem answers questions about
# things outside the repository. Both sides now ask git, so "the file in the commit" and
# "the bytes we parsed" are the same object by construction; the explicit mode check on
# top exists so the refusal NAMES the symlink rather than arriving as a confusing
# "could not read a version" when the target text fails to parse as JSON.
#
# Reading HEAD rather than the worktree is also the more correct question, not merely the
# safer one: what merges is the commit, and the workflow checks out
# `pull_request.head.sha` precisely so that HEAD *is* the thing under review. The cost is
# that a hand-run no longer sees uncommitted edits, which is a real footgun and is why
# the dirty-manifest note below exists. It is a note and not a failure -- the verdict
# about the commit is correct either way.
git rev-parse --verify --quiet HEAD >/dev/null 2>&1 \
  || die "HEAD does not resolve -- this must run inside a checkout with at least one commit"

head_version=""
for f in $MANIFESTS; do
  require_blob HEAD "$f" "$f" || die "$f does not exist at HEAD"
  v="$(git show "HEAD:$f" | read_version "$f")" || die "could not read a version from $f"
  if [ -z "$head_version" ]; then
    head_version="$v"
  elif [ "$v" != "$head_version" ]; then
    die "manifests disagree: $f says $v, an earlier manifest says $head_version -- a release bumps all four together"
  fi
done

# Say what was NOT read. Reading HEAD is right, and a check that quietly answers about a
# different version of the file than the one open in your editor is still a trap; naming
# the files costs four lines and removes the whole class of confused hand-run. `:/` keeps
# the pathspec repo-root-relative, matching `tree_mode`. stderr, and never a verdict.
dirty=""
for f in $MANIFESTS; do
  git diff --quiet HEAD -- ":/$f" 2>/dev/null || dirty="$dirty $f"
done
[ -z "$dirty" ] \
  || printf 'note: uncommitted edits to%s were NOT considered -- this check reads the committed tree (blind spot 10)\n' "$dirty" >&2

# --- base side: no manifest may go backward ----------------------------------------
compared=0
for f in $MANIFESTS; do
  # Existence is asked separately from content so the blob can be PIPED into the reader.
  # It used to be `blob="$(git show ...)" || continue`, which conflated the two answers
  # and, worse, routed the bytes through a shell variable -- the same lossy path (NUL
  # dropped, trailing newlines eaten) the head side was just moved off.
  #
  # `require_blob` rather than the `git cat-file -e` this used to be, so both sides run
  # the SAME existence-and-kind check. The base side was never exposed to round 7's
  # symlink bypass -- `git show` returns the target string rather than following it -- so
  # this arm is symmetry, not a fix. It is worth having anyway: a symlink here would have
  # died one step later with "could not read a version", blaming the parser for something
  # the tree entry decided, and the next person would debug the wrong layer.
  require_blob "$BASE" "$f" "$BASE:$f" || {
    # `>&2`, added in round 8. This note went to STDOUT while its sibling at the dirty
    # check goes to stderr, and the split is the point: stdout carries the verdict and
    # nothing else, so a caller can read the last stdout line as the answer. Not
    # exploitable and not a behaviour change for any current consumer -- CI gates on the
    # exit status and the suite folds the streams -- but "notes are diagnostics, the
    # summary is the result" is only a rule if both notes obey it. R25 pins the channel.
    printf 'note: %s does not exist on %s -- no prior version to compare (blind spot 4)\n' "$f" "$BASE" >&2
    continue
  }
  bv="$(git show "$BASE:$f" | read_version "$BASE:$f")" || die "could not read a version from $BASE:$f"
  if version_lt "$head_version" "$bv"; then
    die "$f would go BACKWARD: $BASE has $bv, this branch has $head_version -- rebase and re-resolve the version, do not merge"
  fi
  compared=$((compared + 1))
done

[ "$compared" -gt 0 ] || die "no manifest on $BASE could be compared -- refusing to report a pass on zero evidence"

printf 'ok: version %s, not behind %s (%d manifest(s) compared, all four agree)\n' "$head_version" "$BASE" "$compared"
