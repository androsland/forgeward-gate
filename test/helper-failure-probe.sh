#!/usr/bin/env bash
# Deterministic probe: what does the hook do when a forked HELPER fails at runtime?
#
# Not a timing experiment. A7 already pins the awk-missing case ("the failure mode
# has to be OVER-denial, not under-denial: a reworded command costs a retry, a missed
# gate does not announce itself"). Nothing pins the equivalent for jq, and json_get
# in forgeward-gate-check.sh runs `jq -r ... 2>/dev/null` with BOTH stderr and
# exit status discarded — so "jq failed to run" and "the field is absent" are the
# same observation to the caller. An empty cmd then reaches the *push*|*create*
# pre-filter, which exits 0. Silent allow.
#
# Three shapes are exercised, each a helper that EXISTS (so `command -v` still finds
# it and the hook takes that branch) but fails when invoked:
#   1. jq exits 1        -- the plausible transient: fork/exec or resource failure
#   2. jq exits 127      -- the shape A7 uses for awk
#   3. awk prints PARTIAL output and exits 0 -- the gap A7 does NOT cover, since the
#      existing guard only rescues EMPTY output (`[ -z "$_scan" ] && _scan=...`)
#
# The fixture repo carries NO marker, so a correctly-matched publish must ALWAYS
# deny. Any empty reply here is a fail-open, and it is deterministic, not a flake.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
CHECK="$PLUGIN/scripts/forgeward-gate-check.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forgeward-helper.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

R="$TMP/repo"
git init -q "$R"
git -C "$R" config user.email t@t.t
git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
echo ok > "$R/f.js"
git -C "$R" add -A
git -C "$R" commit -qm base
git -C "$R" branch -M main
git -C "$R" checkout -qb feature

PUB='git push'

hook() { # hook <extra-PATH-prefix>  -> stdout
  local pfx="${1:-}"
  if [ -n "$pfx" ]; then
    printf '{"cwd":"%s","tool_input":{"command":"%s"}}' "$R" "$PUB" | PATH="$pfx:$PATH" "$CHECK" pretooluse
  else
    printf '{"cwd":"%s","tool_input":{"command":"%s"}}' "$R" "$PUB" | "$CHECK" pretooluse
  fi
}
# Fork-free — see the note on denies() in gate-test.sh. The pipeline form reports a
# false negative under load, which would look exactly like the fail-open being probed.
denies() { case "$1" in *'"permissionDecision": "deny"'*) return 0 ;; *) return 1 ;; esac; }

verdict() { # verdict <label> <output>
  if denies "$2"; then
    printf 'DENY      %s\n' "$1"
  else
    printf 'ALLOW  << %s   *** FAIL-OPEN ***\n' "$1"
  fi
}

echo "baseline (all helpers healthy):"
verdict "no shadow" "$(hook '')"
echo

# 1. jq exists but exits 1
S1="$TMP/jq-exit1"; mkdir -p "$S1"
printf '#!/bin/sh\nexit 1\n' > "$S1/jq"; chmod +x "$S1/jq"
echo "1. jq present but exits 1 (transient fork/resource failure shape):"
verdict "jq exits 1" "$(hook "$S1")"
echo

# 2. jq exists but exits 127 (the shape A7 uses for awk)
S2="$TMP/jq-exit127"; mkdir -p "$S2"
printf '#!/bin/sh\nexit 127\n' > "$S2/jq"; chmod +x "$S2/jq"
echo "2. jq present but exits 127:"
verdict "jq exits 127" "$(hook "$S2")"
echo

# 3. awk returns PARTIAL output and exits 0. A7 covers awk exiting 127, which yields
#    EMPTY output and is rescued by the `[ -z "$_scan" ]` guard. Truncated-but-
#    non-empty output slips past that guard and is scanned as if it were the whole
#    command. Emitting only the first token models exactly that.
S3="$TMP/awk-partial"; mkdir -p "$S3"
printf '#!/bin/sh\nread -r line\nprintf "%%s\\n" "${line%%%% *}"\n' > "$S3/awk"; chmod +x "$S3/awk"
echo "3. awk returns PARTIAL (truncated, non-empty) output and exits 0:"
verdict "awk truncates" "$(hook "$S3")"
echo

echo "note: a fail-open above is DETERMINISTIC and needs no load to reproduce."
echo "It does not by itself prove the observed intermittent failure took that path,"
echo "but it does show the path is live and swallows its own error."
