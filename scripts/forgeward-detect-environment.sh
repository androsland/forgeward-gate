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
# THIS IS NOT A YAML PARSER, and must never be described as one. It reads exactly one
# shape and refuses everything else:
#
#   standalone:
#     substitutes:
#       - quality
#       - deep-audit
#
# Block sequence, two-space nesting, one bare scalar per line. It does NOT handle flow
# sequences (`[a, b]`), anchors, aliases, multi-document streams, tabs, quoted scalars
# with escapes, or `standalone` nested under anything. Every one of those reads as "no
# substitutes named", which disclose-by-default turns into a redundant paragraph rather
# than a hidden gap. A real YAML dependency is not worth taking for one optional key;
# if this shape stops being enough, take the dependency rather than growing this.
#
# SANITISED ON THE WAY OUT, and this is load-bearing rather than defensive. The value is
# the only part of the marker that comes from a file the repo controls, and the marker is
# assembled as JSON by string interpolation. A name carrying a quote or a brace would
# produce a malformed marker. Names are restricted to [A-Za-z0-9_-]; anything else is
# dropped. Note the failure would be fail-SAFE even unsanitised - an unparseable marker
# makes marker_get return empty, is_fresh() answers "stale", and the gate re-runs - but
# "it would only cost a re-gate" is a poor reason to interpolate unvalidated file content.
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
if [ -n "$cfg" ] && [ -L "$cfg" ]; then
  config_state="unreadable"
elif [ -n "$cfg" ] && [ -f "$cfg" ] && [ -r "$cfg" ]; then
  # Size cap before awk touches it. Nothing else bounds how much gets scanned, and a
  # config this large is malformed by definition — the supported shape is a handful of
  # short axis names. A `wc` that fails for any reason resolves to the refusing side.
  _sz="$(LC_ALL=C wc -c < "$cfg" 2>/dev/null || echo 999999999)"
  case "$_sz" in ''|*[!0-9]*) _sz=999999999 ;; esac
  if [ "$_sz" -gt 65536 ]; then
    config_state="unreadable"
  else
    config_state="present"
    # Tested as the `if` condition rather than by inspecting `$?` afterwards. `$?` does
    # survive an intervening comment, but only until someone inserts a command there,
    # and then the failure branch silently stops firing.
    if substitutes="$(awk '
      # Track only the two-level path standalone -> substitutes. Any line at column 0
      # that is not "standalone:" ends the section, so a later top-level key cannot
      # have its list adopted.
      /^standalone:[[:space:]]*$/ { in_s=1; in_sub=0; next }
      /^[^[:space:]#]/            { in_s=0; in_sub=0 }
      in_s && /^[[:space:]]+substitutes:[[:space:]]*$/ { in_sub=1; next }
      in_s && in_sub && /^[[:space:]]+-[[:space:]]*/ {
        v=$0
        sub(/^[[:space:]]+-[[:space:]]*/, "", v)
        sub(/[[:space:]]*(#.*)?$/, "", v)
        # Bounded on BOTH axes as well as charset. Charset alone stops forgery but not
        # size: a 5000-character all-alphanumeric name passes every metacharacter check
        # and lands in the marker verbatim. Not a forgery path — found by an injection
        # probe during 0.8.0 and confirmed Low by the security review — but a marker is
        # a small artifact read on every push, and nothing else bounds it. 64 chars and
        # 32 items are far above any real axis list and far below anything that matters.
        # `length()` and a counter rather than an `{n,m}` interval: interval expressions
        # need --re-interval on older gawk and are absent from some awks entirely.
        if (n < 32 && length(v) <= 64 && v ~ /^[A-Za-z0-9_-]+$/) {
          out = (out=="" ? v : out "," v); n++
        }
        next
      }
      # A non-item line at the substitutes indent level closes the list.
      in_sub && /^[[:space:]]+[^[:space:]-]/ { in_sub=0 }
      END { print out }
    ' "$cfg" 2>/dev/null)"; then
      :
    else
      # awk absent or exploded: say so rather than claiming an empty list, so the caller
      # discloses instead of silently believing nothing was configured.
      config_state="unreadable"; substitutes=""
    fi
  fi
elif [ -n "$cfg" ] && [ -e "$cfg" ]; then
  # Exists but is not a readable regular file: a directory at that path, or a file the
  # user cannot read. `-e` succeeds without read permission, so this catches chmod 000.
  # Reported as unreadable rather than absent because the two lead to the same disclosure
  # and this one is the more accurate answer.
  config_state="unreadable"
fi

printf '{"gstack_ship":"%s","gstack_review":"%s","gstack_cso":"%s","config":"%s","substitutes":"%s"}\n' \
  "$gs_ship" "$gs_review" "$gs_cso" "$config_state" "$substitutes"
exit 0
