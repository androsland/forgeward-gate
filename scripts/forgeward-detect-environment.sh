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
top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
cfg=""
[ -n "$top" ] && cfg="$top/.forgeward/config.yml"

config_state="absent"
substitutes=""
if [ -n "$cfg" ] && [ -f "$cfg" ]; then
  if [ -r "$cfg" ]; then
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
        if (v ~ /^[A-Za-z0-9_-]+$/) { out = (out=="" ? v : out "," v) }
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
  else
    config_state="unreadable"
  fi
fi

printf '{"gstack_ship":"%s","gstack_review":"%s","gstack_cso":"%s","config":"%s","substitutes":"%s"}\n' \
  "$gs_ship" "$gs_review" "$gs_cso" "$config_state" "$substitutes"
exit 0
