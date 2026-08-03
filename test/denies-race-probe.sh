#!/usr/bin/env bash
# Is the P1 "fail-open" actually in the TEST HARNESS rather than the gate?
#
# The load probe reproduced 4 "fail-opens" in 3000 — and printed, as the offending
# hook output, a completely well-formed DENY. The hook did its job. denies() said
# otherwise. That points at denies() itself:
#
#     denies() { printf '%s' "$1" | grep -q '"permissionDecision": "deny"'; }
#
# with `set -o pipefail` in force. `grep -q` exits the moment it matches, closing the
# read end while printf may still be writing. printf then takes SIGPIPE and exits 141.
# pipefail promotes that to the pipeline's status, so denies() returns FALSE on input
# it just successfully matched. Whether printf finishes first is a scheduling race, so
# it is invisible on a quiet box and shows up in bursts under load — which is exactly
# the shape of the original sighting (twice in one ~5-minute window, then 22+ clean).
#
# This probe does not infer that from the grammar. It runs the real pipeline and reads
# PIPESTATUS on every miss, so the answer is observed: a miss with PIPESTATUS=(141 0)
# is printf killed by SIGPIPE while grep matched, and nothing else.
#
# It then measures the two candidate replacements under identical load.
#
# Usage:  bash test/denies-race-probe.sh [iterations] [load-workers]
set -uo pipefail

ITER="${1:-20000}"
LOAD="${2:-16}"

# Byte-identical in shape to what deny() emits, so the pipe carries a realistic size.
DENY_JSON='{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "forgeward gate: the current branch (feature @ fc9ef95) has not passed /forgeward:gate. This is a fast best-effort reminder; the enforced check is the pre-push hook. Run /forgeward:gate, then push."
  }
}'
PAT='"permissionDecision": "deny"'

LOADPIDS=()
cleanup() { for p in ${LOADPIDS+"${LOADPIDS[@]}"}; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

# --- the three implementations under test ---------------------------------------
# current: pipeline, vulnerable to SIGPIPE + pipefail
denies_current() { printf '%s' "$1" | grep -q "$PAT"; }
# candidate A: here-string. No writer process, so no pipe to break.
denies_herestring() { grep -q "$PAT" <<< "$1"; }
# candidate B: pure bash, no fork at all. Cannot race, cannot fail to exec, and is
# faster — this hook helper runs on every assertion in the suite.
denies_case() { case "$1" in *"$PAT"*) return 0 ;; *) return 1 ;; esac; }

if [ "$LOAD" -gt 0 ]; then
  # `for ((...))`, not `$(seq ...)`: seq would be the only call to it anywhere in the
  # repo, and gate-test.sh's header commits to needing "only bash, git, sha256sum, and
  # jq-or-python3 — no extra test runtime". Arithmetic-for is pure bash and forks less.
  for ((_i = 0; _i < LOAD; _i++)); do ( while :; do /bin/true; done ) & LOADPIDS+=("$!"); done
  sleep 1
fi

echo "iterations=$ITER load_workers=$LOAD  pipefail=$(set -o | grep pipefail | awk '{print $2}')"
echo "loadavg at start: $(cat /proc/loadavg)"
echo "---"

# --- the decisive measurement: WHY does the current form miss? -------------------
miss=0; sig=0; other=0; i=0
declare -A seen=()
while [ "$i" -lt "$ITER" ]; do
  i=$((i+1))
  printf '%s' "$DENY_JSON" | grep -q "$PAT"
  # PIPESTATUS must be read FIRST and in one go: every subsequent command resets it,
  # and `rc=$?` is itself a command. Reading $? first and PIPESTATUS second reports
  # the ASSIGNMENT's status, which is always (0) and says nothing. With pipefail the
  # pipeline's status is derivable from the array anyway, so the array is all we need.
  psarr=( "${PIPESTATUS[@]}" )
  ps="${psarr[*]}"
  rc=0
  for _st in "${psarr[@]}"; do [ "$_st" = 0 ] || rc="$_st"; done
  if [ "$rc" != 0 ]; then
    miss=$((miss+1))
    seen["$ps"]=$(( ${seen["$ps"]:-0} + 1 ))
    case "$ps" in
      "141 0") sig=$((sig+1)) ;;
      *)       other=$((other+1)) ;;
    esac
  fi
done
echo "current  (printf | grep -q): $miss miss / $ITER"
for k in "${!seen[@]}"; do
  echo "    PIPESTATUS=($k) x${seen[$k]}$( [ "$k" = "141 0" ] && echo '   <- printf SIGPIPEd, grep MATCHED: a false negative' )"
done

# --- do the candidates hold up under the same conditions? ------------------------
m=0; i=0
while [ "$i" -lt "$ITER" ]; do i=$((i+1)); denies_herestring "$DENY_JSON" || m=$((m+1)); done
echo "candidate A (grep -q <<<):   $m miss / $ITER"

m=0; i=0
while [ "$i" -lt "$ITER" ]; do i=$((i+1)); denies_case "$DENY_JSON" || m=$((m+1)); done
echo "candidate B (bash case):     $m miss / $ITER"

# Both must still REJECT a non-deny, or they are trivially "reliable" by always
# returning true — which would silently disable every deny assertion in the suite.
ALLOW_JSON=''
denies_herestring "$ALLOW_JSON" && echo "candidate A: BROKEN — matches empty input" || echo "candidate A: correctly rejects empty input"
denies_case "$ALLOW_JSON"       && echo "candidate B: BROKEN — matches empty input" || echo "candidate B: correctly rejects empty input"
denies_case '{"permissionDecision": "allow"}' && echo "candidate B: BROKEN — matches an allow" || echo "candidate B: correctly rejects an allow"

echo "---"
echo "loadavg at end: $(cat /proc/loadavg)"
