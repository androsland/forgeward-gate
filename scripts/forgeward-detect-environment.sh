#!/usr/bin/env bash
# forgeward-detect-environment.sh
#
# Answer one question: what does this machine give the gate, and what does it not?
# Prints a single-line JSON object on stdout and always exits 0.
#
# WHY THIS EXISTS. forgeward is scoped as a DELTA against gstack: the README's reviewer
# table has a column literally headed "why it's here (not redundant with gstack)". Scoping
# by delta means every deferral becomes a hole the moment the other side is absent, and one
# already shipped that way (`supply-chain-reviewer` declined dependency CVEs by name to a
# `/cso` that need not exist — see DECISIONS.md). Option B, chosen in docs/axis-proposals.md
# §3, is: DISCLOSE the unowned axes rather than fail. That requires knowing what is here.
#
# ALWAYS EXITS 0. This is informational. A caller must never be wedged because the probe
# had an opinion, and the gate's own discipline is that the enforcement path fails open on
# missing tooling. Errors are reported IN the JSON, not as a status.
#
# DISCLOSURE FAILS OPEN, WHICH IS THE NOISY DIRECTION - deliberately the opposite of
# forgeward-detect-gstack-skill.sh. That script fails CLOSED because a false "installed"
# silently skips a check. Here the output drives a SENTENCE, not a skip: being wrong costs
# the user a redundant paragraph, while being wrong the other way hides a real gap. So an
# unreadable config, a missing config, or any parse trouble all resolve to "disclose".
#
# LIMITATION - presence, not diligence. Inherited wholesale from the detector this calls.
# gstack installed and never once run is indistinguishable from gstack actively covering
# the axis. Callers must render this as "the tool is present", never "the axis was audited".
set -uo pipefail

# Locale-pinned repo-wide, not per-effect — see CLAUDE.md. A non-interactive script
# must not have its behaviour depend on the invoker's environment: character classes,
# collation and grep's handling of invalid UTF-8 all move with the locale, and the
# last one was a complete bypass of an ambiguity guard before it was pinned.
export LC_ALL=C

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
detect="$here/forgeward-detect-gstack-skill.sh"

# The gstack skills forgeward's own text names. Kept to the three that are actually
# referenced: `cso` (supply-chain-reviewer's conditional deferral), `review` (the
# code-quality claim in README), and `ship` (the Step 3 handoff). Adding a name here
# without a corresponding claim in the text would produce a disclosure about nothing.
probe() { # probe <skill> -> present|absent
  [ -x "$detect" ] || { printf 'absent'; return 0; }
  if "$detect" "$1" >/dev/null 2>&1; then printf 'present'; else printf 'absent'; fi
}

gs_ship="$(probe ship)"
gs_review="$(probe review)"
gs_cso="$(probe cso)"

# --- .forgeward/config.yml -----------------------------------------------------------
# THIS IS NOT A YAML PARSER, and must never be described as one. It reads a fixed set of
# shapes under two top-level keys and refuses everything else:
#
#   standalone:
#     substitutes:            # block sequence
#       - quality
#       - "deep-audit"        # a simply-quoted scalar is accepted
#   seo:
#     posture: private-shareable
#
#   standalone:
#     substitutes: [quality, deep-audit]      # flow sequence, equivalent to the above
#
# HONOURED KEYS ARE EXACTLY `standalone.substitutes` AND `seo.posture`. `seo.routes` is
# named in `skills/gate/SKILL.md` and `agents/seo-reviewer.md` and is NOT read here — a
# per-route mapping with glob keys cannot be parsed by this reader without turning it into
# the YAML parser this header forbids, and a partially-honoured pin is worse than an
# openly-unhonoured one. Both documents now say so; if that changes, change them together.
#
# It does NOT handle anchors, aliases, multi-document streams, escapes inside quoted
# scalars, block scalars, an unterminated flow sequence, or `standalone:`/`seo:` nested
# under anything. Every one of those reads as "nothing configured", which
# disclose-by-default turns into a redundant paragraph rather than a hidden gap.
#
# WHY NOT A REAL YAML PARSER, since the shapes keep growing: the obvious candidate is
# python3's `yaml` module with this awk as the fallback, copying the jq/python3 two-arm
# pattern in the hooks. It was declined because **PyYAML is not in the standard library**
# (verified: no `yaml` in `sys.stdlib_module_names`), so `python3` being present says
# nothing about `import yaml` succeeding. That makes arm selection a coin flip on what
# happens to be installed, and two arms that parse DIFFERENT shapes is the exact
# divergence 0.7.5 shipped and V7 now exists to catch. One arm that everyone gets is worth
# more here than a better arm some people get. If a genuine parser is ever needed, take
# the dependency outright rather than conditionally.
#
# SANITISED ON THE WAY OUT, and this is load-bearing rather than defensive. These are the
# only parts of the marker that come from a file the repo controls, and the marker is
# assembled as JSON by string interpolation. A name carrying a quote or a brace would
# produce a malformed marker. Substitute names are restricted to [A-Za-z0-9_-]; the
# posture must be one of the six literal values the reviewers know, compared as whole
# strings rather than matched by charset. Anything else is dropped. Note the failure would
# be fail-SAFE even unsanitised - an unparseable marker makes marker_get return empty,
# is_fresh() answers "stale", and the gate re-runs - but "it would only cost a re-gate" is
# a poor reason to interpolate unvalidated file content.
#
# AN UNRECOGNISED POSTURE IS DROPPED SILENTLY, and that is the fail-open direction here: a
# typo'd or invented value reads as "not pinned", so the seo-reviewer classifies by
# detection — its normal job — instead of acting on a pin nobody can honour. Same for every
# other shape above: refusing costs a disclosure the user already answered, never a skipped
# check, so the DROPPING stays. What changed is that it is no longer SILENT.
#
# `config_warnings` COUNTS THE DROPS. It is a count and nothing else — no key names, no line
# numbers, no prose. Three reasons it is a bare integer rather than a message: this output is
# interpolated into the pass marker as JSON by `printf`, so every field is an injection
# surface and an integer is the only shape with no representable `"`, `,`, `{` or `}`; the
# marker's shape check in `forgeward-write-marker.sh` validates against a closed vocabulary,
# which prose has none of; and the caller renders one line, for which "n settings were read
# and discarded" is enough to send someone to their own config. Someone wanting the offending
# keys named should read the file — this field exists to tell them there is a reason to.
#
# IT CHANGES NOTHING ABOUT WHAT IS HONOURED. Every rule below that accepted or rejected a
# line before still accepts or rejects it identically; the counter is additive. That is
# deliberate: this entry was filed because silence is bad feedback, not because the parsing
# is wrong, and coupling a visibility fix to a behaviour change would make the behaviour
# change ship unreviewed.
#
# WHAT IT COUNTS — one per setting the reader was addressed by and could not use:
#   1. a top-level key that is not `standalone:` or `seo:`
#   2. an indented key under `standalone:` that is not `substitutes:`  (`substitues:`)
#   3. an indented key under `seo:` that is not `posture:` or `routes:`  (`postures:`)
#   4. a `posture:` value outside the six literals, including an empty one
#   5. a `substitutes` item dropped by the charset, the 64-char cap or the 32-item cap
#   6. an unterminated flow sequence (`substitutes: [a, b`), which reaches rule 2
#
# WHAT IT DELIBERATELY DOES NOT COUNT, written here because an unstated limit reads as a
# claim of coverage:
#   - `seo.routes` and everything indented under it. It is documented in README,
#     `skills/gate/SKILL.md` and `agents/seo-reviewer.md` as having no effect, so a repo that
#     pins it followed the docs; warning about it would fire on a legitimate configuration
#     and train the reader to ignore the count. Its subtree is skipped by INDENT, which is
#     the one place this reader looks at indentation as structure.
#   - an empty item (`substitutes: []`, or a trailing comma). Nothing was named, so nothing
#     was discarded.
#   - comments and blank lines, at any indent.
#
# WHAT IT STRUCTURALLY CANNOT SEE, same reason: this is still not a YAML parser, so a file
# using anchors, aliases, multi-document streams or block scalars produces a count over lines
# that were never keys — the number is meaningless there, and nothing detects that case. It
# also cannot see a DUPLICATE key (YAML resolves last-wins; both spellings are honoured-
# looking here and neither is counted), and it cannot see a key nested three levels deep as
# distinct from a legitimate one, because the reader only ever tracked two.
#
# ZERO IS NOT A CLEAN BILL. `config_warnings: 0` on a config the reader could not open at all
# reads exactly like 0 on a perfect one — `config` carries that distinction, not this field,
# and a caller must read both.
#
# SYMLINKS ARE REFUSED, NOT FOLLOWED. `[ -f ]` and `[ -r ]` both follow links, so before
# this check a repo could commit `.forgeward/config.yml` as a git symlink (mode 120000)
# pointing at any file readable by whoever checks the branch out and runs the gate. The
# 0.8.0 security review demonstrated it end-to-end: a link to a file outside the repo,
# shaped like a config, was followed and its value carried into the pass marker. Impact
# was bounded — the marker is local, never committed, and nothing in the repo transmits
# it — but the weaker oracle is real: `config` would report present/unreadable for any
# path an attacker named, and awk would scan a file of any size.
#
# Refusal rather than resolve-and-contain (the reviewer's other suggestion) because the
# cost of refusing is exactly the cost this whole script already accepts: this key only
# SILENCES A DISCLOSURE, so a config we decline to read costs one redundant paragraph —
# the same fail-open direction chosen everywhere else here. Containment would need
# `readlink -f`, which is not portable to the older macOS bash 3.2 environments this repo
# still targets, and a hand-rolled resolver on the path that authorizes pushes is a poor
# trade for a convenience key.
#
# WHAT THIS DELIBERATELY BREAKS, stated so the limit is not mistaken for coverage: a
# monorepo that legitimately symlinks `.forgeward/config.yml` to a shared config
# elsewhere in the tree is ignored, and reads as `unreadable` rather than silently empty
# so the disclosure still fires. That is a real configuration someone will have; it is
# refused knowingly, not overlooked. Such a repo must use a regular file.
top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
cfg=""
[ -n "$top" ] && cfg="$top/.forgeward/config.yml"

config_state="absent"
substitutes=""
seo_posture=""
config_warnings=0
if [ -n "$cfg" ] && [ -L "$cfg" ]; then
  config_state="unreadable"
elif [ -n "$cfg" ] && [ -f "$cfg" ] && [ -r "$cfg" ]; then
  # Size cap before awk touches it. Nothing else bounds how much gets scanned, and a
  # config this large is malformed by definition — the supported shape is a handful of
  # short axis names. A `wc` that fails for any reason resolves to the refusing side.
  # The `LC_ALL=C` prefix that used to sit here is now the script-wide pin at the top,
  # which also covers the `awk` below — the asymmetry between the two was the P3 that
  # prompted the repo-wide convention.
  _sz="$(wc -c < "$cfg" 2>/dev/null || echo 999999999)"
  case "$_sz" in ''|*[!0-9]*) _sz=999999999 ;; esac
  if [ "$_sz" -gt 65536 ]; then
    config_state="unreadable"
  else
    config_state="present"
    # Three values come back on ONE line separated by `|`, which none can contain: the
    # substitute charset excludes it, the posture is compared against six literals, and
    # the third field is `%d` of a counter this program owns.
    # A separator rather than three lines because splitting lines in bash 3.2 without
    # `read -d` or a second tool is clumsier than a parameter expansion, and this keeps
    # the script's tool set at git/wc/awk.
    #
    # `sq` carries the apostrophe in from the shell. Writing it inside this
    # single-quoted program would end the quote, and the alternative (`"\047"`) leans on
    # octal string escapes that not every awk implements.
    #
    # Tested as the `if` condition rather than by inspecting `$?` afterwards. `$?` does
    # survive an intervening comment, but only until someone inserts a command there,
    # and then the failure branch silently stops firing.
    if _cfgout="$(awk -v sq="'" '
      # A simply-quoted scalar has its quotes removed; anything else is returned as-is
      # and fails the charset/enum test below on its own merits. Escapes inside the
      # quotes are NOT interpreted - a backslash is just another character the charset
      # rejects.
      function unquote(s,   q) {
        if (length(s) >= 2) {
          q = substr(s, 1, 1)
          if ((q == "\"" || q == sq) && substr(s, length(s), 1) == q)
            s = substr(s, 2, length(s) - 2)
        }
        return s
      }
      function trim(s) {
        sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s
      }
      # Capped at 999 for the same reason every other value here is bounded: this lands in
      # a marker read on every push, and the 64KB size cap upstream still permits a file
      # with thousands of junk lines. The cap is not reported as a cap — a config that
      # produces 999 warnings has a problem the exact number does not sharpen.
      function warn() { if (w < 999) w++ }
      # The ONLY place this reader treats indentation as structure, and it is confined to
      # skipping a subtree it has already decided not to read. `match` sets RLENGTH, which
      # is the portable way to measure a leading run without a substr loop.
      function indent(s) { match(s, /^[[:space:]]*/); return RLENGTH }
      # Bounded on BOTH axes as well as charset. Charset alone stops forgery but not
      # size: a 5000-character all-alphanumeric name passes every metacharacter check
      # and lands in the marker verbatim. Not a forgery path — found by an injection
      # probe during 0.8.0 and confirmed Low by the security review — but a marker is
      # a small artifact read on every push, and nothing else bounds it. 64 chars and
      # 32 items are far above any real axis list and far below anything that matters.
      # `length()` and a counter rather than an `{n,m}` interval: interval expressions
      # need --re-interval on older gawk and are absent from some awks entirely.
      # The caps are shared by both list shapes, so a flow sequence cannot buy a bigger
      # budget than a block one.
      function additem(v) {
        v = unquote(v)
        # An empty item is not a discarded setting — `[]` and a trailing comma both split
        # to one here and neither named anything — so it returns before the counter.
        if (v == "") return
        if (n < 32 && length(v) <= 64 && v ~ /^[A-Za-z0-9_-]+$/) {
          out = (out=="" ? v : out "," v); n++
        } else warn()
      }
      # Track only the two-level paths standalone -> substitutes and seo -> posture. Any
      # line at column 0 that is not one of those two headers ends both sections, so a
      # later top-level key cannot have its list or its posture adopted.
      # `skip` is cleared by all three because a column-0 line ends every subtree by
      # definition; clearing it here rather than at the bottom keeps the reset on the
      # rules that already own section state instead of splitting the invariant in two.
      /^standalone:[[:space:]]*$/ { in_s=1; in_sub=0; in_seo=0; skip=0; next }
      /^seo:[[:space:]]*$/        { in_seo=1; in_s=0; in_sub=0; skip=0; next }
      /^[^[:space:]#]/            { in_s=0; in_sub=0; in_seo=0; skip=0 }
      # Flow sequence, complete on its own line. Requires the closing bracket: an
      # unterminated `[a, b` falls through to the list-closing rule and reads as nothing
      # configured, which discloses. Both strips are anchored - `^[^[]*\[` takes
      # everything up to the FIRST bracket, `\][[:space:]]*(#.*)?$` everything from the
      # last one - so an item containing a stray bracket cannot shift the boundaries.
      in_s && /^[[:space:]]+substitutes:[[:space:]]*\[.*\][[:space:]]*(#.*)?$/ {
        v=$0
        sub(/^[^[]*\[/, "", v)
        sub(/\][[:space:]]*(#.*)?$/, "", v)
        m = split(v, parts, ",")
        for (i = 1; i <= m; i++) additem(trim(parts[i]))
        in_sub=0
        next
      }
      in_s && /^[[:space:]]+substitutes:[[:space:]]*$/ { in_sub=1; next }
      in_s && in_sub && /^[[:space:]]+-[[:space:]]*/ {
        v=$0
        sub(/^[[:space:]]+-[[:space:]]*/, "", v)
        sub(/[[:space:]]*(#.*)?$/, "", v)
        additem(v)
        next
      }
      # Whole-string comparison against the six postures the reviewers implement, not a
      # charset: an unrecognised value must read as "not pinned" rather than reach the
      # marker and then a reviewer that has no ruleset for it.
      #
      # Matched at ANY indent under `seo:`, not only at two spaces, which is the same
      # laxity the substitutes items above have. So a `posture:` nested deeper (under a
      # hypothetical `seo.defaults:`) is adopted, and the last one in the file wins. Left
      # lax deliberately: tightening to a fixed indent is a new branch that would drop the
      # pin of anyone indenting with four spaces, and the over-read only fires on shapes
      # nothing documents, in the direction of honouring a pin the user did write.
      in_seo && /^[[:space:]]+posture:[[:space:]]*/ {
        v=$0
        sub(/^[[:space:]]+posture:[[:space:]]*/, "", v)
        sub(/[[:space:]]*(#.*)?$/, "", v)
        v = unquote(v)
        if (v == "public-indexed" || v == "private-shareable" || v == "private-closed" ||
            v == "staging-preview" || v == "authenticated-shareable" || v == "unknown")
          posture = v
        else
          warn()   # includes a bare `posture:` with no value — a key that named nothing
        next
      }
      # A non-item line at the substitutes indent level closes the list.
      in_sub && /^[[:space:]]+[^[:space:]-]/ { in_sub=0 }

      # --- counting, and it must stay LAST ------------------------------------------
      # Every rule above either honoured its line or ignored it on purpose, and each of
      # them ends in `next`. So a line arriving here is one nothing above claimed, which
      # is exactly the population this field is about. Putting the counters last is what
      # lets them be purely additive: they cannot shadow a rule that used to fire.
      #
      # The two exceptions are the rules that deliberately fall through — the column-0
      # reset above and the list-closer immediately preceding — and both want their line
      # counted, which is why they do not `next`.
      skip > 0 { if (indent($0) > skip) next; skip = 0 }
      in_seo && /^[[:space:]]+routes:/ { skip = indent($0); next }
      # An indented key under either section. `[^[:space:]#-]` excludes comments and block
      # sequence items; `[^:]*:` requires a colon, so a bare word or a stray value line is
      # not counted as a key. An unterminated `substitutes: [a, b` lands here, correctly.
      (in_s || in_seo) && /^[[:space:]]+[^[:space:]#-][^:]*:/ { warn(); next }
      # A top-level key that is neither `standalone:` nor `seo:` — those two `next`ed far
      # above and can never reach this line. Anchored at column 0, so `---`, a comment and
      # any indented line are all excluded by the pattern itself.
      /^[A-Za-z_][A-Za-z0-9_-]*:/ { warn() }
      END { printf "%s|%s|%d\n", out, posture, w }
    ' "$cfg" 2>/dev/null)"; then
      # Exit status 0 is not enough: the END block always prints BOTH separators, so output
      # with fewer means awk produced something other than this program did - the same
      # "it ran" vs "it worked" distinction that cost 0.7.3 and 0.7.6. The pattern counts
      # two on purpose; `*"|"*` would accept the old two-field line from a half-upgraded
      # copy of this script and silently read the posture as the warning count.
      case "$_cfgout" in
        *"|"*"|"*)
          substitutes="${_cfgout%%|*}"
          _rest="${_cfgout#*|}"
          seo_posture="${_rest%%|*}"
          config_warnings="${_rest#*|}"
          # Re-validated here rather than trusted from awk. The field is interpolated into
          # the marker and `%d` on a non-numeric string is undefined across printf
          # implementations, so a count that is not digits is treated as the awk-exploded
          # case below - the same refusing direction the size cap takes.
          case "$config_warnings" in
            ''|*[!0-9]*)
              config_state="unreadable"; substitutes=""; seo_posture=""; config_warnings=0 ;;
          esac
          ;;
        *) config_state="unreadable"; substitutes=""; seo_posture=""; config_warnings=0 ;;
      esac
    else
      # awk absent or exploded: say so rather than claiming an empty list, so the caller
      # discloses instead of silently believing nothing was configured.
      config_state="unreadable"; substitutes=""; seo_posture=""; config_warnings=0
    fi
  fi
elif [ -n "$cfg" ] && [ -e "$cfg" ]; then
  # Exists but is not a readable regular file: a directory at that path, or a file the
  # user cannot read. `-e` succeeds without read permission, so this catches chmod 000.
  # Reported as unreadable rather than absent because the two lead to the same disclosure
  # and this one is the more accurate answer.
  config_state="unreadable"
fi

# Field order is part of the contract: `forgeward-write-marker.sh` validates this line
# against its complete literal shape, anchored at both ends. Adding, removing or
# reordering a field here without editing `_env_ok` in the same commit makes every marker
# record `environment: {"probe":"unavailable"}` — safe, but provenance is lost silently
# except for E10 going red. Adding a field here is a TWO-file edit: this `printf` and
# `_env_ok`. It was a three-file edit through 0.13.0 — E17 in test/gate-test.sh carried a
# hand-copied duplicate of this line, and a copy left stale was refused on its prefix and
# silently stopped testing the anchor it exists for, reddening nothing. That leg is closed
# by construction rather than by warning: E17 now derives its prefix from the live probe,
# so it cannot fall behind. Do not reintroduce a literal copy of this line anywhere.
#
# `config_warnings` is the only UNQUOTED value here, and the asymmetry is deliberate: it is
# a count, JSON has numbers, and `[0-9]` is a strictly narrower vocabulary than any quoted
# field beside it — a bare integer cannot carry the `"`/`,`/`{`/`}` a splice needs, so the
# marker's shape check is tighter on this field than on the strings, not looser. `%d`
# rather than `%s` because the value has already been proven to be digits and `%d` fails
# loudly on anything else.
printf '{"gstack_ship":"%s","gstack_review":"%s","gstack_cso":"%s","config":"%s","substitutes":"%s","seo_posture":"%s","config_warnings":%d}\n' \
  "$gs_ship" "$gs_review" "$gs_cso" "$config_state" "$substitutes" "$seo_posture" "$config_warnings"
exit 0
