#!/usr/bin/env bash
# Regression suite for scripts/forgeward-transcript-audit.sh.
#
# Framework-free, same as the other four: bash and git only, the real script under test,
# no copies. Runs standalone and via `npm test`.
#
# The property under test is UNUSUAL and shapes the whole file: this script's job is to
# find credential-shaped strings and then NOT show them. Most of what could go wrong is
# therefore an assertion about ABSENCE -- and an absence assertion passes for free on a
# script that crashed, printed nothing, or searched the wrong directory. So every
# silence check here is paired with a positive control that proves the check can fail,
# per CLAUDE.md: a silence-asserting suite needs a trust check that runs first.
#
# The second shape is the channel set. The script deliberately enumerates no directory
# names, because the two documented channels turned out to be three. Fixtures plant the
# same needle in all three plus an undocumented fourth, so a future refactor that
# reintroduces a channel list fails here rather than in someone's transcripts.
#
# One harness trap, hit while writing this: under `set -o pipefail`, `CMD | grep -q` is
# a FALSE NEGATIVE generator. grep -q exits the moment it matches, CMD takes SIGPIPE and
# dies 141, and pipefail hands the pipeline that 141 -- so a successful match reads as a
# failed test. Capture output into a variable first, then grep the variable. Five
# assertions here failed that way before the cause was found.
set -uo pipefail

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$PLUGIN/scripts/forgeward-transcript-audit.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok %d - %s\n' "$((PASS+FAIL))" "$1"; }
nok()  { FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$((PASS+FAIL))" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; }

# Guarded because `mktemp -d` failing under `set -uo pipefail` without -e leaves TMP
# empty, and every path below then resolves against the filesystem root.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/forgeward-ta-test.XXXXXX")" || { printf 'Bail out! mktemp failed\n'; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { printf 'Bail out! TMP not a directory\n'; exit 1; }
trap 'rm -rf "$TMP"' EXIT

[ -x "$AUDIT" ] || { printf 'Bail out! %s is not executable\n' "$AUDIT"; exit 1; }

# The needle. Assembled from pieces so this FILE does not itself contain a string that
# the audit script would flag when someone runs it over a machine that has read this
# repo -- the tool matching its own test fixtures is a documented non-goal, not a reason
# to make the fixtures unreadable.
AKIA_NEEDLE="AKIA$(printf '0123456789ABCDEF')"
PEM_NEEDLE="-----BEGIN RSA PRIVATE KEY-----"

# mkfix <root> -- one project slug, one session, a needle in each of the FOUR known
# locations: top-level session transcript, subagents/, tool-results/, and memory/.
mkfix() {
  local r="$1"
  local s="$r/-slug-x"
  local u="11111111-2222-3333-4444-555555555555"
  mkdir -p "$s/$u/subagents" "$s/$u/tool-results" "$s/$u/memory"
  printf 'top level %s tail\n'   "$AKIA_NEEDLE" > "$s/$u.jsonl"
  printf 'subagent %s tail\n'    "$AKIA_NEEDLE" > "$s/$u/subagents/agent-1.jsonl"
  printf 'toolresult %s tail\n'  "$AKIA_NEEDLE" > "$s/$u/tool-results/big.txt"
  printf 'memory %s tail\n'      "$AKIA_NEEDLE" > "$s/$u/memory/note.md"
}

run() { "$AUDIT" --root "$1" "${@:2}" 2>&1; }

# ---------------------------------------------------------------------------
# 1. THE TRUST CHECK. Runs first, and everything after it depends on it.
#    Prove the value-leak detector can actually fail before trusting it to pass.
# ---------------------------------------------------------------------------
leaky="$(printf 'here is the value: %s\n' "$AKIA_NEEDLE")"
if printf '%s' "$leaky" | grep -qF "$AKIA_NEEDLE"; then
  ok "trust check: a printed value IS detected by the leak assertion"
else
  nok "trust check: a printed value IS detected by the leak assertion" \
      "the leak check cannot fail, so every silence assertion below is worthless"
fi

# ---------------------------------------------------------------------------
# 2. NEVER PRINTS A VALUE. The load-bearing property.
# ---------------------------------------------------------------------------
R1="$TMP/r1"; mkdir -p "$R1"; mkfix "$R1"
out="$(run "$R1")"
if printf '%s' "$out" | grep -qF "$AKIA_NEEDLE"; then
  nok "output never contains the matched value" "the needle appeared in stdout/stderr"
else
  ok "output never contains the matched value"
fi
# Paired positive: it did find something, so the silence above is silence-with-a-hit
# rather than silence-because-nothing-ran.
if printf '%s' "$out" | grep -q 'PREFIXED CREDENTIAL SHAPES (10 patterns): 4 file(s)'; then
  ok "found all four planted files while printing none of their contents"
else
  nok "found all four planted files while printing none of their contents" \
      "$(printf '%s' "$out" | grep 'PREFIXED CREDENTIAL' || echo 'no count line at all')"
fi

# ---------------------------------------------------------------------------
# 3. CHANNEL COVERAGE. The pairs: each location found, and no location enumerated.
# ---------------------------------------------------------------------------
for loc in "555555555555.jsonl" "subagents/agent-1.jsonl" "tool-results/big.txt" "memory/note.md"; do
  if printf '%s' "$out" | grep -qF "$loc"; then
    ok "reports a hit at $loc"
  else
    nok "reports a hit at $loc" "a channel list has been reintroduced, or depth is capped"
  fi
done
# The undocumented-channel guard: a fifth directory nobody has named must work too.
R2="$TMP/r2"; mkdir -p "$R2/-slug-y/22222222-3333-4444-5555-666666666666/future-channel"
printf 'x %s y\n' "$AKIA_NEEDLE" > "$R2/-slug-y/22222222-3333-4444-5555-666666666666/future-channel/f.log"
o2="$(run "$R2")"
if printf '%s' "$o2" | grep -qF 'future-channel/f.log'; then
  ok "finds a channel that does not exist yet (path scoping, not enumeration)"
else
  nok "finds a channel that does not exist yet (path scoping, not enumeration)"
fi

# ---------------------------------------------------------------------------
# 4. THE PEM PATTERN. It begins with '-', so a rewrite that drops `-e` turns the
#    whole run into a usage error. Pinned because that failure is total and silent
#    in the sense that matters: the other nine shapes still work.
# ---------------------------------------------------------------------------
R3="$TMP/r3"; mkdir -p "$R3/-slug-z/33333333-4444-5555-6666-777777777777"
printf '%s\nbody\n' "$PEM_NEEDLE" > "$R3/-slug-z/33333333-4444-5555-6666-777777777777/s.jsonl"
o3="$(run "$R3")"
if printf '%s' "$o3" | grep -q 'PREFIXED CREDENTIAL SHAPES (10 patterns): 1 file(s)'; then
  ok "matches a PEM header (the leading-dash pattern still reaches grep as a pattern)"
else
  nok "matches a PEM header (the leading-dash pattern still reaches grep as a pattern)"
fi
# -e is load-bearing: the needle begins with '-', so a bare `grep -qF "$PEM_NEEDLE"`
# errors with "unrecognized option" and exits 2. That is NOT zero, so the silence
# assertion below would have PASSED without ever looking at the output -- which is the
# exact false-pass this suite exists to prevent, found while writing it.
if printf '%s' "$o3" | grep -qF -e "$PEM_NEEDLE"; then
  nok "PEM run prints no value" "the PEM needle appeared in the output"
else
  ok "PEM run prints no value"
fi

# ---------------------------------------------------------------------------
# 5. PRECISION PAIRS. For each rule, the case that must match and the neighbour
#    that must not -- a matcher that fires on everything is as broken as one that
#    fires on nothing, and only the pair can tell them apart.
# ---------------------------------------------------------------------------
R4="$TMP/r4"; mkdir -p "$R4/-slug-n/44444444-5555-6666-7777-888888888888"
printf 'AKIA0123456789ABCDE short\n' > "$R4/-slug-n/44444444-5555-6666-7777-888888888888/s.jsonl"
o4="$(run "$R4")"
if printf '%s' "$o4" | grep -q 'PREFIXED CREDENTIAL SHAPES (10 patterns): 0 file(s)'; then
  ok "AKIA + 15 chars does not match (the 16-char bound is real)"
else
  nok "AKIA + 15 chars does not match (the 16-char bound is real)"
fi

# ---------------------------------------------------------------------------
# 6. THE URL PATTERN IS ADVISORY. Counted, not listed, and never sets exit 1 --
#    if it did, the script would be permanently red and therefore ignored.
# ---------------------------------------------------------------------------
R5="$TMP/r5"; mkdir -p "$R5/-slug-u/55555555-6666-7777-8888-999999999999"
printf 'db https://user:hunter2@example.com/x\n' > "$R5/-slug-u/55555555-6666-7777-8888-999999999999/s.jsonl"
o5="$(run "$R5")"; run "$R5" >/dev/null 2>&1; rc5=$?
if [ "$rc5" -eq 0 ]; then ok "a URL-password-only hit exits 0 (advisory)"
else nok "a URL-password-only hit exits 0 (advisory)" "exit was $rc5"; fi
if printf '%s' "$o5" | grep -q 'PASSWORD IN A CONNECTION URL: 1 file(s)'; then
  ok "a URL-password hit is counted"
else
  nok "a URL-password hit is counted"
fi
if printf '%s' "$o5" | grep -qF 'hunter2'; then
  nok "the URL password is not printed without --urls" "the password appeared"
else
  ok "the URL password is not printed without --urls"
fi
o5u="$("$AUDIT" --root "$R5" --urls 2>&1)"
if printf '%s' "$o5u" | grep -q 's.jsonl'; then
  ok "--urls lists the filename"
else
  nok "--urls lists the filename"
fi

# ---------------------------------------------------------------------------
# 7. EXIT CODES. Each one is a different claim and callers branch on them.
# ---------------------------------------------------------------------------
run "$R1" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then ok "exit 1 when a prefixed shape matched"; else nok "exit 1 when a prefixed shape matched" "got $rc"; fi

R6="$TMP/r6"; mkdir -p "$R6/-slug-c/66666666-7777-8888-9999-000000000000"
printf 'nothing interesting\n' > "$R6/-slug-c/66666666-7777-8888-9999-000000000000/s.jsonl"
"$AUDIT" --root "$R6" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then ok "exit 0 when nothing matched"; else nok "exit 0 when nothing matched" "got $rc"; fi

"$AUDIT" --root "$TMP/does-not-exist" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "exit 2 when the root does not exist"; else nok "exit 2 when the root does not exist" "got $rc"; fi

# The trap this code exists for: a slug that is not there must NOT look like a slug with
# no findings. The project slug follows Claude Code's launch directory, not the repo
# root, so a wrong guess is the expected case rather than the exotic one.
"$AUDIT" --root "$R1" --project no-such-slug >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "exit 2 for a nonexistent --project slug (not a clean 0)"; else nok "exit 2 for a nonexistent --project slug (not a clean 0)" "got $rc"; fi
ons="$("$AUDIT" --root "$R1" --project no-such-slug 2>&1)"
if printf '%s' "$ons" | grep -q 'NOT a clean result'; then
  ok "a nonexistent slug says so in words, not just in the exit code"
else
  nok "a nonexistent slug says so in words, not just in the exit code"
fi

R7="$TMP/r7"; mkdir -p "$R7"
"$AUDIT" --root "$R7" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "exit 2 on an empty tree (unverifiable, not clean)"; else nok "exit 2 on an empty tree (unverifiable, not clean)" "got $rc"; fi

"$AUDIT" --nonsense >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 64 ]; then ok "exit 64 on an unknown argument"; else nok "exit 64 on an unknown argument" "got $rc"; fi

"$AUDIT" --root >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 64 ]; then ok "exit 64 when --root is given no value"; else nok "exit 64 when --root is given no value" "got $rc"; fi

# ---------------------------------------------------------------------------
# 8. --patterns is the extension point. If it drifts from the array the audit
#    uses, someone extends a list that is not the one doing the work.
# ---------------------------------------------------------------------------
p_out="$("$AUDIT" --patterns 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "--patterns exits 0"; else nok "--patterns exits 0" "got $rc"; fi
n_listed="$(printf '%s\n' "$p_out" | grep -c '^  ')"
if [ "$n_listed" -eq 11 ]; then
  ok "--patterns lists all 10 prefixed shapes plus the URL pattern"
else
  nok "--patterns lists all 10 prefixed shapes plus the URL pattern" "listed $n_listed"
fi
if printf '%s' "$p_out" | grep -q '10 prefixed shapes'; then
  ok "--patterns states the count the audit reports"
else
  nok "--patterns states the count the audit reports"
fi

# ---------------------------------------------------------------------------
# 9. THE DENOMINATOR. "0 hits" and "0 hits over N files" are different claims,
#    and the whole point of this script is that only the second one is worth
#    anything. Pinned so a tidy-up cannot drop it.
# ---------------------------------------------------------------------------
o6="$("$AUDIT" --root "$R6" 2>&1)"
if printf '%s\n' "$o6" | grep -qE '^  files    1 across 1 session directories$'; then
  ok "reports files scanned and session count as the denominator"
else
  nok "reports files scanned and session count as the denominator"
fi
for phrase in "UNVERIFIABLE" "ROTATE regardless" "never \"nothing was exposed\""; do
  if printf '%s' "$o6" | grep -qF "$phrase"; then
    ok "a clean run still says: $phrase"
  else
    nok "a clean run still says: $phrase" "the caveat block is what stops 0 reading as safe"
  fi
done

# ---------------------------------------------------------------------------
# 10. BY-SHAPE TRIAGE. Names the shape, never the value.
# ---------------------------------------------------------------------------
if printf '%s' "$out" | grep -qE '^      4  AKIA'; then
  ok "by-shape breakdown attributes the hits to a named pattern"
else
  nok "by-shape breakdown attributes the hits to a named pattern"
fi

# ---------------------------------------------------------------------------
# 11. THE OUTPUT IS ITSELF IDENTIFYING, and the person about to paste it into
#     an issue is the one who needs telling. A project slug is a directory
#     path with the punctuation flattened, so the filename list carries a home
#     directory name and repo/client names. Raised by the privacy review of
#     the commit that shipped this script.
# ---------------------------------------------------------------------------
if printf '%s' "$out" | grep -qF 'REDACT BEFORE PASTING'; then
  ok "a run with hits warns that the printed paths are identifying"
else
  nok "a run with hits warns that the printed paths are identifying"
fi
if printf '%s' "$o6" | grep -qF 'REDACT BEFORE PASTING'; then
  nok "the redact warning does not fire on a run with no filenames to redact"
else
  ok "the redact warning does not fire on a run with no filenames to redact"
fi

# ---------------------------------------------------------------------------
# 12. `stat -c` IS GNU-ONLY. On BSD and macOS every call fails and a naive
#     loop reports a confident 0 world-readable files -- the exact false-clean
#     shape this script exists to argue against. Simulated with a stat on PATH
#     that always fails, because the alternative is not testing it at all.
# ---------------------------------------------------------------------------
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/stat"; chmod 755 "$FAKEBIN/stat"
o7="$(PATH="$FAKEBIN:$PATH" "$AUDIT" --root "$R6" 2>&1)"
if printf '%s' "$o7" | grep -qF 'tool-results files: UNAVAILABLE'; then
  ok "an unusable stat reports UNAVAILABLE, not a confident 0"
else
  nok "an unusable stat reports UNAVAILABLE, not a confident 0" "a silent 0 is a false clean"
fi
if printf '%s' "$o6" | grep -qE 'tool-results files: [0-9]+'; then
  ok "a working stat still reports a number"
else
  nok "a working stat still reports a number" "the probe must not disable the real check"
fi

printf '\n1..%d\n' "$((PASS+FAIL))"
printf '# pass %d, fail %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
