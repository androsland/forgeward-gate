#!/usr/bin/env bash
# Targeted probe for the P1 fail-open (TODOS.md, "Gate — test suite").
#
# The 200-run loop reproduced no S7 failure but DID fail assertion 10 once, on
# `git commit -m "$( (true) ; git push )"` — expected deny, got allow. Same
# direction, same hook, but that assertion fires at the MATCHER stage, before any
# hash logic exists. If the matcher can intermittently not fire, S7's evidence
# stops being mysterious: the hash was correct and the hook allowed anyway.
#
# Hypothesis under test: the hook forks helpers whose failure is swallowed, so a
# transient fork/exec failure is indistinguishable from a legitimate empty result
# and the hook exits 0 (allow):
#   json_get       `jq -r ... 2>/dev/null` -- stderr AND exit status discarded.
#                  Empty cmd -> the *push*|*create* pre-filter exits 0.
#   strip_quoted   awk -- empty output falls back to raw text (guarded by A7),
#                  but PARTIAL output does not, and is unguarded.
# Both predict load dependence, which fits the original sighting (twice in one
# ~5-minute window) and the run-19 hit (box was at load 15).
#
# This probe drives the hook directly, thousands of times, with no suite around it.
# A fixture repo with NO marker is used, so a correctly-matched publish ALWAYS
# denies and any empty reply is a fail-open, full stop.
#
# Usage:  bash test/matcher-flake-probe.sh [iterations] [--load N]
#         bash test/matcher-flake-probe.sh 5000 --load 8
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
CHECK="$PLUGIN/scripts/forgeward-gate-check.sh"
[ -f "$CHECK" ] || { echo "cannot find $CHECK" >&2; exit 1; }

ITER="${1:-2000}"
LOAD=0
[ "${2:-}" = "--load" ] && LOAD="${3:-8}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forgeward-probe.XXXXXX")"
LOADPIDS=()
cleanup() {
  for p in ${LOADPIDS+"${LOADPIDS[@]}"}; do kill "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

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

# Exactly the payload shape the suite builds: the matrix reads a raw line and
# pretool() printf's it into the JSON, so the backslash-escaped quotes are literal
# here too. Single-quoted so this shell expands nothing.
CMD_SUBST='git commit -m \"$( (true) ; git push )\"'
CMD_PLAIN='git push'

hook() { # hook <cmd-literal> <stderr-file>  -> stdout
  printf '{"cwd":"%s","tool_input":{"command":"%s"}}' "$R" "$1" | "$CHECK" pretooluse 2>"$2"
}
# Fork-free: the pipeline form is itself the bug this probe uncovered — grep -q exits
# on match, printf takes SIGPIPE, pipefail reports failure on a successful match. A
# probe carrying that defect measures its own harness, not the hook.
denies() { case "$1" in *'"permissionDecision": "deny"'*) return 0 ;; *) return 1 ;; esac; }

# Sanity first: if these do not deny on a quiet box the probe is measuring nothing.
errf="$TMP/e"
denies "$(hook "$CMD_SUBST" "$errf")" || { echo "ABORT: substitution case does not deny even once — probe invalid" >&2; exit 1; }
denies "$(hook "$CMD_PLAIN" "$errf")" || { echo "ABORT: plain publish does not deny even once — probe invalid" >&2; exit 1; }
echo "sanity: both cases deny on a quiet box"

if [ "$LOAD" -gt 0 ]; then
  echo "spawning $LOAD fork-pressure workers (fork/exec churn, not just CPU burn —"
  echo "the hypothesis is a failing fork, so exec rate matters more than spin)"
  # Arithmetic-for rather than $(seq ...): see the note in denies-race-probe.sh — seq
  # is not in the footprint this repo's test suite commits to.
  for ((_i = 0; _i < LOAD; _i++)); do
    ( while :; do /bin/true; done ) & LOADPIDS+=("$!")
  done
  sleep 1
fi

echo "iterations=$ITER load_workers=$LOAD"
echo "loadavg at start: $(cat /proc/loadavg 2>/dev/null || echo n/a)"
echo "---"

probe() { # probe <label> <cmd-literal>
  local label="$1" cmd="$2" i out allows=0 first=""
  local ef="$TMP/err-$label"
  for ((i=1; i<=ITER; i++)); do
    out="$(hook "$cmd" "$ef")"
    if ! denies "$out"; then
      allows=$((allows+1))
      [ -z "$first" ] && {
        first="$i"
        echo "  *** FAIL-OPEN at iteration $i (label=$label)"
        echo "      stdout: ${out:-<EMPTY>}"
        echo "      stderr: $( [ -s "$ef" ] && tr '\n' ' ' < "$ef" || echo '<empty>' )"
        echo "      loadavg: $(cat /proc/loadavg 2>/dev/null || echo n/a)"
        # Is it the swallowed-jq path? Ask jq the same question right now.
        echo "      jq re-read of the same payload: '$(printf '{"cwd":"%s","tool_input":{"command":"%s"}}' "$R" "$cmd" | jq -r '.tool_input.command // empty' 2>&1)'"
      }
    fi
  done
  echo "$label: $allows fail-open / $ITER  (first at ${first:-none})"
}

probe "subst" "$CMD_SUBST"
probe "plain" "$CMD_PLAIN"

echo "---"
echo "loadavg at end: $(cat /proc/loadavg 2>/dev/null || echo n/a)"
