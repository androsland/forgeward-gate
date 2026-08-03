#!/usr/bin/env bash
# Loop driver for the P1 S7 fail-open flake (see TODOS.md, "Gate — test suite").
#
# S7 ("dep add re-gate denied") was seen ALLOWING a publish it should have denied,
# twice inside one ~5-minute window while building 0.7.2, then never again in 22+
# consecutive runs. An isolated replay of the S5->S7 sequence alone was clean 15/15,
# so this driver runs the WHOLE suite — the surrounding A1..A7 matrix and its awk /
# PATH-shadowing work are part of the context that produced the two sightings, and
# reproducing without them has already been tried and failed.
#
# It invokes test/gate-test.sh IN PLACE rather than copying it. The suite derives
# PLUGIN from BASH_SOURCE, so a copy outside the repo tree silently reviews the wrong
# scripts and the run is worthless (that mistake has already cost one window).
#
# Usage:  bash test/s7-flake-loop.sh [runs]        # default 200, keeps going after a hit
#         FORGEWARD_S7_STOP=1 bash test/s7-flake-loop.sh 500
#         FORGEWARD_S7_LOGS=/some/dir bash test/s7-flake-loop.sh
#
# Every run's full TAP output is kept. A run that reproduces the flake is copied to
# HIT-<n>.log and carries the forensics block the suite dumps on failure.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="$HERE/gate-test.sh"
[ -f "$SUITE" ] || { echo "cannot find $SUITE" >&2; exit 1; }

RUNS="${1:-200}"
# mktemp -d, not a fixed path. A predictable `/tmp/forgeward-s7-flake` can be
# pre-created or pre-symlinked by a co-resident local user before this runs, and the
# script then mkdir -p's it and writes/cp's logs in. Nothing here is sensitive and
# nothing is rm -rf'd, so the impact is small — but the three sibling probes all use
# mktemp and there is no reason this one should not. An explicit FORGEWARD_S7_LOGS
# still wins, since a long sweep is easier to follow at a known path.
LOGS="${FORGEWARD_S7_LOGS:-$(mktemp -d "${TMPDIR:-/tmp}/forgeward-s7-flake.XXXXXX")}"
STOP="${FORGEWARD_S7_STOP:-0}"
# Fork/exec pressure. The first 200-run sweep was clean on a quiet box and the one
# failure it did catch (run 19) landed while the machine was independently at load 15
# — so a quiet loop is the weaker experiment. Churning /bin/true rather than spinning
# on CPU because the failures being hunted are fork- and scheduling-shaped.
LOAD="${FORGEWARD_S7_LOAD:-0}"
LOADPIDS=()
cleanup_load() { for p in ${LOADPIDS+"${LOADPIDS[@]}"}; do kill "$p" 2>/dev/null; done; }
trap cleanup_load EXIT

# The assertion under investigation, matched on the exact TAP text the suite emits.
# Kept as one string so a rename in gate-test.sh breaks this loudly instead of
# silently never matching and reporting a clean sweep forever.
NEEDLE='not ok .* - dep add re-gate denied'

mkdir -p "$LOGS"
SUMMARY="$LOGS/summary.txt"
: > "$SUMMARY"

hits=0; other=0; clean=0; n=0
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

say() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }

if [ "$LOAD" -gt 0 ]; then
  # Arithmetic-for rather than $(seq ...): see the note in denies-race-probe.sh.
  for ((_i = 0; _i < LOAD; _i++)); do ( while :; do /bin/true; done ) & LOADPIDS+=("$!"); done
  sleep 1
fi

say "S7 flake loop: $RUNS runs, suite=$SUITE"
say "logs=$LOGS  started=$started  stop_on_hit=$STOP  load_workers=$LOAD"
say "awk=$(command -v awk 2>/dev/null || echo MISSING)  jq=$(command -v jq 2>/dev/null || echo absent)  python3=$(command -v python3 2>/dev/null || echo absent)"
say "env bash=$(/usr/bin/env bash --version 2>/dev/null | head -1)"
say "---"

while [ "$n" -lt "$RUNS" ]; do
  n=$((n+1))
  log="$LOGS/run-$(printf '%04d' "$n").log"
  t0=$(date +%s)
  /usr/bin/env bash "$SUITE" > "$log" 2>&1
  rc=$?
  t1=$(date +%s)

  if grep -qE "$NEEDLE" "$log"; then
    hits=$((hits+1))
    cp "$log" "$LOGS/HIT-$(printf '%04d' "$n").log"
    say "run $n: *** S7 FAIL-OPEN REPRODUCED *** rc=$rc $((t1-t0))s -> $LOGS/HIT-$(printf '%04d' "$n").log"
    # Surface the verdict line immediately; the full forensics stay in the log.
    grep -E 'VERDICT|immediate re-runs|hook stdout|hook stderr' "$log" | sed 's/^/    /' | tee -a "$SUMMARY"
    [ "$STOP" = "1" ] && { say "stopping on hit (FORGEWARD_S7_STOP=1)"; break; }
  elif [ "$rc" -ne 0 ]; then
    other=$((other+1))
    cp "$log" "$LOGS/OTHERFAIL-$(printf '%04d' "$n").log"
    say "run $n: a DIFFERENT assertion failed (rc=$rc, $((t1-t0))s) -> OTHERFAIL-$(printf '%04d' "$n").log"
    grep -E '^not ok' "$log" | sed 's/^/    /' | tee -a "$SUMMARY"
  else
    clean=$((clean+1))
    # Keep the console quiet but legible: one line every 10 clean runs.
    [ $((n % 10)) -eq 0 ] && say "run $n: clean ($((t1-t0))s)  tally: clean=$clean s7_hits=$hits other=$other"
  fi
done

say "---"
say "done: $n runs  clean=$clean  s7_fail_open=$hits  other_failures=$other"
say "finished=$(date -u +%Y-%m-%dT%H:%M:%SZ) (started $started)"
if [ "$hits" -gt 0 ]; then
  say "observed S7 fail-open rate: $hits/$n"
  say "read: $LOGS/HIT-*.log  (search for 'S7 FAIL-OPEN FORENSICS')"
else
  say "no reproduction in $n runs."
  say "Read that as evidence, not proof: a clean sweep lowers the odds of a flake at a"
  say "given rate, it never excludes one. At an 8%-per-run rate, $n clean runs still"
  say "happen by chance with probability 0.92^$n. Record the count and the machine load"
  say "it ran under — a quiet box is the weak version of this experiment (see --load)."
fi
