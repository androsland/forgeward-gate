#!/usr/bin/env bash
# Regression suite for the forgeward gate enforcement core.
#
# Framework-free on purpose: the system under test is bash + git, so this needs
# only bash, git, sha256sum, and jq-or-python3 — the plugin's own footprint, no
# extra test runtime. Runs standalone, and via `bun run test` / `npm test`
# (see package.json). Exercises the REAL plugin scripts in scripts/, not copies.
#
# A future edit that breaks deny/allow, hash version-invariance, or
# dependency-sensitivity fails this suite.
set -uo pipefail

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$PLUGIN/scripts/forgeward-gate-check.sh"
WRITE="$PLUGIN/scripts/forgeward-write-marker.sh"
HASH="$PLUGIN/scripts/forgeward-diff-hash.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok %d - %s\n' "$((PASS+FAIL))" "$1"; }
nok()  { FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$((PASS+FAIL))" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; }

# --- helpers that drive the real hook script the way Claude Code would ---
pretool() { # pretool <repo> <command>  -> stdout = hook decision JSON (or empty)
  printf '{"cwd":"%s","tool_input":{"command":"%s"}}' "$1" "$2" | "$CHECK" pretooluse
}
expansion() { # expansion <repo>  -> exit code (0 allow, 2 block)
  printf '{"cwd":"%s"}' "$1" | "$CHECK" expansion >/dev/null 2>&1; echo $?
}
# Fork-free ON PURPOSE — this is a correctness fix, not a speed one.
#
# This was `printf '%s' "$1" | grep -q '...'` under the `set -o pipefail` above, and
# that combination silently inverts the answer. `grep -q` exits the instant it
# matches, closing the read end while printf may still be writing; printf then takes
# SIGPIPE and exits 141; pipefail promotes that to the pipeline's status. The helper
# reports NO-DENY on output it just successfully matched.
#
# Observed, not theorised: PIPESTATUS=(141 0) — printf killed, grep matched — 7 times
# in 20000 under fork pressure and 0 times on a quiet box (test/denies-race-probe.sh).
# Every deny assertion in this file ran through here, so a scheduling hiccup surfaced
# as an intermittent GATE fail-open that no amount of staring at the gate could
# explain. That is the P1 in TODOS.md, and it was never in the gate at all.
#
# A `case` glob forks nothing, so it can neither lose that race nor fail to exec.
# Only an EARLY-EXIT reader can orphan its writer this way, which is why `jq` and
# `python3` pipelines elsewhere (they drain to EOF) are not affected.
denies()  { case "$1" in *'"permissionDecision": "deny"'*) return 0 ;; *) return 1 ;; esac; }

# --- scratch repo on the same shape as the demo (main + feature) ---
TMP="$(mktemp -d "${TMPDIR:-/tmp}/forgeward-test.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
R="$TMP/repo"
git init -q "$R"; cd "$R"
git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
printf '{\n  "name": "u",\n  "version": "1.0.0",\n  "dependencies": { "express": "^4.19.2" }\n}\n' > package.json
echo "ok" > src.js
git add -A; git commit -qm base; git branch -M main
git checkout -qb feature
printf 'const e = require("express");\nconst app = e();\napp.get("/x", (q,r)=>r.json({ok:true}));\n' > feature.js
git add -A; git commit -qm "feat: real work"

# S1: no marker -> publish denied
out="$(pretool "$R" "git push -u origin feature")"
denies "$out" && ok "no marker -> git push DENIED" || nok "no marker -> git push DENIED" "got: $out"

# S2: unrelated command never interfered with, even with no marker
out="$(pretool "$R" "npm test")"
[ -z "$out" ] && ok "non-publish command -> untouched (no deny)" || nok "non-publish command untouched" "got: $out"

# S3: gh pr create and glab mr create also gated
denies "$(pretool "$R" "gh pr create --base main")" && ok "no marker -> gh pr create DENIED" || nok "gh pr create DENIED"
denies "$(pretool "$R" "glab mr create -b main")"   && ok "no marker -> glab mr create DENIED" || nok "glab mr create DENIED"

# S4: expansion blocks a typed /ship with no marker (exit 2)
[ "$(expansion "$R")" = "2" ] && ok "no marker -> /ship expansion BLOCKED (exit 2)" || nok "/ship expansion blocked"

# --- A1..A7 (publish matcher: ISSUED vs MENTIONED) ----------------------------
# Runs HERE, before S5 writes a marker, so a match is observable as a deny.
# The matcher must fire on a publish command ISSUED and stay silent on one MENTIONED.
# The old glob matched the verb anywhere in the text and denied both; it fired six
# times in one session on this repo, whose own docs and tests are ABOUT these commands.
#
# The distinction is drawn by QUOTING, not by position: quoted spans are blanked and
# the plain substring test runs on the remainder. Two earlier designs anchored the verb
# to a command position and both failed review in opposite directions -- too narrow
# (prefixes like `time`/`env`/`sudo` and backticks evaded) and too wide (`!` and `)` in
# the anchor class denied ordinary prose). A1 below carries every shape those reviews
# surfaced, so a return to position-anchoring fails here.
#
# The expected verdicts are not a reading of shell grammar. Each case was run against
# stubbed git/gh/glab binaries to observe whether a publish verb ACTUALLY executed, and
# the table below matches that observation -- including the divergences pinned in A4,
# which is the authority on that list (a count here would just go stale). One case in an
# earlier draft (`echo "start\"; ..."`) was expected to deny and turned out to execute
# nothing; the oracle corrected it, not the reverse.
#
# Note the mention cases use single quotes where the payload must stay valid JSON
# through pretool(); backslash cases are written doubled for the same reason.
matrix() { # matrix <name> <label>  — reads want|cmd lines on stdin
  local name="$1" label="$2" want cmd got bad=""
  local okflag=1
  while IFS='|' read -r want cmd; do
    [ -n "$want" ] || continue
    if denies "$(pretool "$R" "$cmd")"; then got=deny; else got=allow; fi
    [ "$got" = "$want" ] || { okflag=0; bad="$bad [$want!=$got: $cmd]"; }
  done
  [ "$okflag" = 1 ] && ok "$label" || nok "$name" "$bad"
}

matrix "publish matcher MISSES an issued publish command (recall regression)" \
  "publish matcher: fires on a publish command ISSUED in unquoted text, whatever precedes it (separators, keywords, command prefixes, substitution)" <<'CASES'
deny|git   push
deny|git add -A; git push
deny|foo | git push
deny|(git push)
deny|git push;
deny|set -e\ngit push
deny|cd /x && gh pr create --base main
deny|glab mr create -b main
deny|{ git push; }
deny|if true; then git push; fi
deny|while true; do git push; break; done
deny|if x; then y; else git push; fi
deny|case x in x) git push;; esac
deny|! git push
deny|f(){ git push; }; f
deny|until done; do gh pr create; done
deny|time git push
deny|exec git push
deny|command git push
deny|nohup git push &
deny|env FOO=bar git push
deny|sudo git push
deny|timeout 30 git push
deny|nice -n5 git push
deny|stdbuf -oL git push
deny|\\git push
deny|x=`git push`
deny|$(git push)
deny|git push > out.txt
deny|time gh pr create
deny|exec glab mr create
CASES

matrix "publish matcher over-denies a mention" \
  "publish matcher: a MENTIONED publish command in an argument is NOT denied (the over-denial this fixes)" <<'CASES'
allow|git commit -m 'docs: run gh pr create after the gate'
allow|git commit -m 'chore: mention git push in the README'
allow|grep -rn 'gh pr create' README.md
allow|echo 'the command is git push'
allow|printf '{\"command\":\"git push\"}' > payload.json
allow|git pushx
allow|npm run push-docs
allow|echo 'Careful! git push will trigger CI'
allow|git commit -m 'Add CI helper (git push automation)'
allow|git commit -m 'fix; git push now'
allow|echo \"say 'git push' loudly\"
allow|echo 'say \"git push\" loudly'
CASES

# A3 (the reserved-word trap): `then`/`do`/`else` are ordinary English words. Under the
# current quote-stripping design these pass for the simple reason that they are quoted.
# The block is kept because the trap is real for any POSITION-based design: an earlier
# version anchored on a bare ' do ' and denied ordinary prose. If someone reintroduces
# keyword anchoring, this fails here before it reaches review.
matrix "publish matcher denies quoted prose containing a reserved word" \
  "publish matcher: quoted prose containing shell reserved words stays allowed (guards against reintroducing keyword anchoring)" <<'CASES'
allow|echo 'what to do git push now'
allow|echo 'things to do: git push'
allow|echo 'or else git push manually'
allow|echo 'wait until git push finishes'
CASES

# A4: the DISCLOSED gaps, asserted so they STAY disclosed. These pin real limits, not
# desired behaviour -- if one starts behaving differently, the BLIND SPOTS comment in
# forgeward-gate-check.sh has gone stale and must be updated in the same commit. Every
# line here was confirmed to diverge by running it against stubbed publish binaries.
#
# The SYNTHESISED SEPARATOR group (`git${IFS}push`) is the other unfixable one: the
# regex wants literal whitespace between the words and an expansion supplies it at
# RUNTIME, so the words are adjacent for the shell and disjoint in the text. Routing to
# raw text does not help -- the raw text has no whitespace there either. It is here
# because an earlier version of the source comment claimed raw-text matching "cannot
# hide anything", which this falsifies.
#
# The QUOTED COMMAND WORD group (`'git' push` and friends) is the uncomfortable one:
# each really executes. It is here rather than fixed because the only thing separating
# `git 'push'` from `echo 'the command is git push'` is command position, and any rule
# that catches the first catches the second -- which is the over-denial this whole
# change exists to remove. The old bare substring missed these too (`'git' push` does
# not contain the characters `git push`), so nothing regressed; the gap simply was not
# disclosed before, and an earlier version of this file wrongly called the list complete.
matrix "a disclosed gap changed behaviour — update the BLIND SPOTS comment" \
  "publish matcher: disclosed gaps behave as documented (quoted-wrapper and -C under-match; UNQUOTED mention over-denies)" <<'CASES'
allow|bash -c 'git push'
allow|eval 'git push'
allow|ssh host 'git push'
allow|trap 'git push' EXIT
allow|git -C /some/path push
allow|'git' push
allow|git 'push'
allow|g'i't push
allow|g""it push
allow|gh 'pr' create
allow|git pu''sh
allow|git${IFS}push
allow|git$IFS'push'
allow|gh${IFS}pr${IFS}create
allow|echo 'unterminated; git push
deny|echo git push is next
deny|echo $(echo git push)
deny|echo \"$(echo 'git push')\"
deny|git commit -m \"$(printf 'docs: git push notes')\"
CASES

# A8: COMMAND SUBSTITUTIONS ARE DISTRUSTED, NOT PARSED.
#
# A blanking scanner and a substitution are a bad match: bash gives each `$( … )` and
# each backtick span its own quoting scope, a left-to-right scanner does not, and three
# consecutive security reviews of this branch each found a DIFFERENT desync from trying
# to teach it one. All three had the same shape -- state restored early, real code after
# that point blanked as data -- and all three silently allowed a command that really
# pushed:
#   1. flat quote parity   git commit -m "$(printf '%s' "it's done")" && git push
#   2. plain paren pairs   git commit -m "$( (true) ; git push )"
#   3. case-clause `)`     echo "$(case y in y) git push;; esac)"
# Each fix was correct and each left another, which is the tell that the approach was
# wrong rather than the implementation. So a command containing `$(` or a backtick is
# matched on its RAW text instead: it cannot hide anything, and it retires the whole
# class rather than its current instance.
#
# Every deny below is a command that really executes a publish (confirmed against
# stubbed binaries), including all three historical repros. The allow cases are the
# controls that keep this from being vacuous -- substitutions with no verb anywhere in
# the text, which must still pass through untouched.
#
# The `${ ... }` pair is bash 5.3's ksh-style value substitution, which RUNS a command
# with neither `$(` nor a backtick in the text. Neither bash here (5.1) nor Git Bash's
# (4.4) supports it -- both reject it as a bad substitution, so these two cases assert
# the GUARD rather than an observed execution, and they are the one pair in this file
# whose expected verdict is not backed by the oracle on this machine. Said plainly
# because an unstated exception is how the last three disclosures went wrong.
#
# The first two allow cases are the ones that actually exercise the guard. The other
# three contain no `push`/`create` anywhere, so the pre-filter short-circuits them
# before the guard is ever consulted -- they were the only controls here at first, which
# made the "controls" claim hollow in precisely the way A9 exists to catch. These two
# carry `push` (inside `push-docs`, which the word boundary must reject) AND a
# substitution, so they reach the guard, take the raw-text path, and must still allow.
# `${HOME}` also pins that ordinary parameter expansion is NOT treated as a value
# substitution -- if it were, most quoted-variable commands would over-deny.
matrix "publish matcher trusts a substitution-bearing command's stripped residue" \
  "publish matcher: a command containing \$( ) or a backtick is matched on raw text, so no substitution-scope desync can hide a publish" <<'CASES'
deny|a=\"$(printf '\"')\" git push
deny|y=\"$(printf '%s' \"it's fine\")\"; git push
deny|git commit -m \"$(printf '%s' \"it's done\")\" && git push
deny|git commit -m \"$( (true) ; git push )\"
deny|git commit -m \"$( x=$(( 1+2 )) ; git push )\"
deny|git commit -m \"`(true) ; git push`\"
deny|echo \"$(case y in y) git push;; esac)\"
deny|echo \"`case y in y) git push;; esac`\"
deny|echo \"$(echo \"$(case y in y) git push;; esac)\")\"
deny|echo \"$( (echo hi) ; git push )\"
deny|echo \"$(date) deploying\" && git push
deny|x=$(echo hi); echo \"it's $x\"; git push
deny|echo \"$(git push)\"
deny|echo \"outer `git push` inner\"
deny|echo \"$(( 1+2 )) done\"; git push
deny|echo \"${ git push; }\"
deny|echo \"${| git push; }\"
allow|git commit -m \"$(cat msg.txt)\" && npm run push-docs
allow|echo \"${HOME}/bin\" && npm run push-docs
allow|git commit -m \"$(cat msg.txt)\"
allow|git commit -m \"$( (echo safe) )\"
allow|echo \"$( (echo 'it') ; echo done )\"
CASES

# A10: the non-substitution constructs that carry parens must keep working, since the
# guard above does not cover them -- these go through the scanner, not the raw text.
# A12: PROGRAM-NAME CASE. On an NTFS-backed checkout the program name resolves
# case-insensitively, so `Git push` really runs a push on Git Bash while `git`'s own
# subcommand parsing stays case-sensitive (`GIT PUSH` does not run one -- git rejects
# `PUSH`). The verb test is therefore case-insensitive and the pre-filter deliberately is
# not: a real publish always carries a lowercase `push`/`create`, so the cheap filter
# stays exact while the decision does not. Pre-existing before this change; the old
# substring had the same gap. The allow cases are the control -- quoted prose is blanked,
# so making the test case-insensitive must not start denying quoted mentions. The last
# case pins the one NEW over-denial this bought: an UNQUOTED mixed-case mention now
# denies where the case-sensitive matcher allowed it. Fail-safe, and disclosed.
matrix "publish matcher misses a case-variant program name" \
  "publish matcher: program-name case is ignored (Git/GIT resolve on a case-insensitive filesystem) while quoted mentions stay allowed" <<'CASES'
deny|Git push
deny|GIT push
deny|Gh pr create
deny|Glab mr create
allow|echo 'Git Push is the plan'
allow|git commit -m 'docs: Git push notes'
deny|echo the docs say Git push first
CASES

matrix "publish matcher mishandles parens outside a substitution" \
  "publish matcher: subshells, case arms, function bodies and process substitution still classify correctly without any paren modelling" <<'CASES'
deny|(git push)
deny|case x in x) git push;; esac
deny|f(){ git push; }; f
deny|diff <(echo a) <(echo b); git push
deny|(( 1 + 2 )); git push
allow|echo 'in a case arm: x) git push;; esac'
CASES

# A11: LINE CONTINUATION. An unquoted backslash-newline is a splice -- bash deletes both
# characters and the lines join with NOTHING between them, so `git pu\<newline>sh` really
# runs a push. Two separate things went wrong here before the join was added: awk saw two
# records and put a space and a record boundary where bash puts nothing, and the raw text
# contains neither "push" nor "create", so the pre-filter exited before any scanning
# happened at all. The second is why the join has to sit ABOVE the pre-filter, and the
# first case below fails if it is ever moved back down. The third case is the control:
# a continuation inside quotes is still a mention and must stay allowed.
#
# This block is also the only thing that catches a CR bug in json_get: on Windows,
# python3's stdout is a text stream and turns every "\n" into "\r\n", so a multi-line
# command arrived carrying a CR the real shell never sees, and the join silently matched
# nothing. It passed on WSL and failed on Git Bash. Note the coverage is conditional --
# jq does not translate newlines, so on a machine WITH jq these cases exercise the jq
# path and say nothing about the python one. Both machines here lack jq, which is why it
# was observable at all.
lc_ok=1; lc_bad=""
lc_check() { # lc_check <want> <cmd>
  local got
  if denies "$(pretool "$R" "$1")"; then got=deny; else got=allow; fi
  [ "$got" = "$2" ] || { lc_ok=0; lc_bad="$lc_bad [$2!=$got]"; }
}
lc_check 'git pu\\\nsh' deny
lc_check 'gi\\\nt push' deny
lc_check "echo 'safe \\\nmention of git push'" allow
[ "$lc_ok" = 1 ] && ok "publish matcher: a backslash-newline line continuation is joined before both the pre-filter and the scan, so a spliced verb is still caught" \
  || nok "publish matcher misses a verb split across a line continuation" "$lc_bad"

# A9: the harness itself. pretool() assembles JSON with raw printf, so a case whose
# payload contains an unescaped double quote produces MALFORMED JSON; json_get then
# returns an empty command and the hook allows via the empty-command short-circuit
# rather than by classifying anything. A mention case would still read "allow" and
# look correct while testing nothing. This case must DENY, so a malformed payload
# fails loudly here instead of silently hollowing out the cases above.
denies "$(pretool "$R" 'echo \"a\"; git push')" \
  && ok "test harness: a payload containing escaped double quotes survives JSON assembly intact (guards the A2/A5/A8 cases against silently testing nothing)" \
  || nok "test harness produces malformed JSON for payloads containing double quotes — the quoted cases are not testing what they claim"

# A5: BACKSLASH state. Outside quotes `\'` is a LITERAL quote, so a scanner that only
# pairs quote characters mis-pairs here and blanks a command that really does execute.
# The extglob-substitution attempt failed exactly this. Inside double quotes `\"` is
# also literal, which is why the second case runs nothing and must stay allowed.
matrix "publish matcher mishandles backslash-escaped quotes" \
  "publish matcher: escaped quotes cannot hide an issued publish, nor manufacture a mentioned one" <<'CASES'
deny|echo start\\'; git push; \\'echo end
deny|echo 'a'\\''b'; git push
allow|echo 'it'\\''s fine to git push later'
allow|echo \"start\\\"; git push; \\\"end\"
CASES

# A6: LINEAR in quote density. The extglob attempt was correct but superlinear here:
# 2.3s on 1KB and 55s on 3KB of quote-dense input, while measuring 15ms on quote-SPARSE
# 20KB -- so a sparse benchmark hides it entirely and this case must stay dense. The
# bound is deliberately loose; it separates "linear" from "blows up", not fast from slow.
dense=""; while [ "${#dense}" -lt 3000 ]; do dense="$dense'a'"; done
t0=$(date +%s)
dense_out="$(pretool "$R" "echo $dense; git push")"
t1=$(date +%s)
if denies "$dense_out" && [ "$((t1-t0))" -lt 5 ]; then
  ok "publish matcher: quote-dense 3KB command scanned in $((t1-t0))s and still denied (linear in quote density)"
else
  nok "publish matcher is superlinear in quote density, or missed the trailing publish" \
      "elapsed=$((t1-t0))s denied=$(denies "$dense_out" && echo yes || echo no)"
fi

# A7: awk unavailable -> fall back to the RAW text. The scan is the only part of this
# matcher that needs a helper process, and the failure mode has to be OVER-denial, not
# under-denial: a reworded command costs a retry, a missed gate does not announce
# itself. Simulated with a failing awk on PATH rather than a stripped PATH, because
# stripping PATH removes coreutils too and would test the wrong thing.
SHADOW="$TMP/noawk"; mkdir -p "$SHADOW"
printf '#!/bin/sh\nexit 127\n' > "$SHADOW/awk"; chmod +x "$SHADOW/awk"
pretool_noawk() { printf '{"cwd":"%s","tool_input":{"command":"%s"}}' "$1" "$2" | PATH="$SHADOW:$PATH" "$CHECK" pretooluse; }

noawk_issued="$(pretool_noawk "$R" "git push")"
noawk_mention="$(pretool_noawk "$R" "echo 'the command is git push'")"
noawk_other="$(pretool_noawk "$R" "npm test")"
if denies "$noawk_issued" && denies "$noawk_mention" && [ -z "$noawk_other" ]; then
  ok "publish matcher: with awk unavailable it degrades to the old raw-text test (issued DENIED, mention over-denied, unrelated untouched) — fails closed, never open"
else
  nok "publish matcher fails OPEN when awk is unavailable" \
      "issued=$(denies "$noawk_issued" && echo deny || echo allow) mention=$(denies "$noawk_mention" && echo deny || echo allow) other=${noawk_other:-empty}"
fi

# A13/A14/A15: a helper that FAILS AT RUNTIME must not open the gate.
#
# A7 above covers awk MISSING — exit 127, empty output, rescued by the raw-text
# fallback. It does not cover the two neighbouring shapes, and both were observed
# failing OPEN when probed directly (test/helper-failure-probe.sh):
#
#   - jq PRESENT but exiting non-zero. json_get discards stderr AND exit status, so
#     "jq failed to run" and "the field is absent" are the same observation. The
#     resulting empty command dies at the pre-filter and the hook exits 0 without
#     ever looking at a marker. `command -v jq` still succeeds, so the python3
#     branch is never reached — being installed is treated as being functional.
#   - awk returning TRUNCATED but non-empty output. The existing guard rescues only
#     EMPTY output (`[ -z "$_scan" ]`), so a partial residue is scanned as if it were
#     the whole command and the verb can fall off the end of it.
#
# The direction is the entire point: both are UNDER-denial, which this file's own
# header calls the one failure this layer must never take ("a reworded command costs
# a retry, a missed gate does not announce itself"). Runs here, before S5 writes a
# marker, so a correct match is observable as a deny.
#
# Why runtime failure rather than absence is worth pinning separately: absence is
# stable and gets noticed, while a transient failure under fork or memory pressure
# is silent, self-healing, and looks exactly like a flaky test.
shadow_of() { # shadow_of <name> <script-body-file>  -> dir to prepend to PATH
  local d="$TMP/shadow-$1"; mkdir -p "$d"
  cp "$2" "$d/$1"; chmod +x "$d/$1"; printf '%s' "$d"
}
hook_with() { # hook_with <path-prefix> <cmd> -> hook stdout
  printf '{"cwd":"%s","tool_input":{"command":"%s"}}' "$R" "$2" | PATH="$1:$PATH" "$CHECK" pretooluse
}

printf '#!/bin/sh\nexit 1\n' > "$TMP/_jqfail"
JQ_FAIL="$(shadow_of jq "$TMP/_jqfail")"
out_jqfail="$(hook_with "$JQ_FAIL" "git push")"
denies "$out_jqfail" \
  && ok "A13: jq present but exiting 1 -> still DENIED (a failed helper is not read as an absent field)" \
  || nok "A13: publish matcher fails OPEN when jq is present but fails at runtime" \
         "got: ${out_jqfail:-<empty — silent allow>}"

printf '#!/bin/sh\nexit 127\n' > "$TMP/_jq127"
JQ_127="$(shadow_of jq "$TMP/_jq127")"
out_jq127="$(hook_with "$JQ_127" "git push")"
denies "$out_jq127" \
  && ok "A14: jq present but exiting 127 -> still DENIED" \
  || nok "A14: publish matcher fails OPEN when jq exits 127" \
         "got: ${out_jq127:-<empty — silent allow>}"

# Emits only the first whitespace-delimited token: truncated, non-empty, exit 0 —
# precisely the residue shape the `[ -z "$_scan" ]` guard cannot see.
cat > "$TMP/_awkpart" <<'AWKPART'
#!/bin/sh
read -r line
printf '%s\n' "${line%% *}"
AWKPART
AWK_PART="$(shadow_of awk "$TMP/_awkpart")"
out_awkpart="$(hook_with "$AWK_PART" "git push")"
denies "$out_awkpart" \
  && ok "A15: awk returning TRUNCATED non-empty output -> still DENIED (partial residue is not trusted)" \
  || nok "A15: publish matcher fails OPEN when awk truncates its output" \
         "got: ${out_awkpart:-<empty — silent allow>}"

# A16: the residue-length guard added for A15 must not OVER-deny.
#
# That guard falls back to raw text whenever the stripped residue is shorter than the
# input, which is safe only because strip_quoted substitutes one-for-one. If that ever
# stops holding for some real shape, the fallback fires on ordinary commands and a
# merely-MENTIONED verb starts denying — the exact over-denial the quoting design was
# built to remove. MULTI-LINE input is the shape most likely to break the assumption,
# since awk works per line and `$( )` strips trailing newlines; those cases are the
# point of this block, and they are not covered anywhere above.
#
# (A trailing newline survives the round trip because the command substitution that
# EXTRACTS the command strips it too, so both sides shorten together. Asserted rather
# than reasoned about, because that symmetry is not obvious and could quietly change.)
matrix "residue-length guard OVER-denies (strip_quoted may have stopped preserving length)" \
  "publish matcher: the residue-length guard leaves quoted mentions allowed, including across multiple lines, while still denying an issued publish" <<'CASES'
allow|echo 'the docs say git push first'
allow|echo hello\necho 'then git push'
allow|echo 'a git push'\necho 'b git push'
allow|echo 'see git push'\n
allow|echo \"it's git push\"
allow|echo one\necho two
deny|git push
deny|echo hi\ngit push
deny|echo 'about git push'\ngit push
CASES

# A17: the residue-length guard under a BYTE-oriented awk.
#
# The guard compares ${#_scan} with ${#_cmd_j}, both measured by BASH, which counts
# characters in a UTF-8 locale. mawk and busybox awk are byte-oriented regardless of
# locale, so a multi-byte character inside quotes is blanked into SEVERAL spaces and
# the residue comes back LONGER than the input (measured: 17 vs 15). Longer is the
# safe direction — the guard does not fire — but that is a fact about the awk, not
# something the guard enforces, so it is asserted rather than assumed.
#
# The file header's "identical verdicts under gawk, mawk, and busybox awk" claim
# predates this guard and covered only the VERDICTS, never the length arithmetic the
# guard now depends on. Hence a separate case.
#
# Skipped when neither alternative awk is installed, so this adds no required tool —
# the suite still needs only bash, git, sha256sum and jq-or-python3.
_alt_awks=""
command -v mawk    >/dev/null 2>&1 && _alt_awks="$_alt_awks mawk"
command -v busybox >/dev/null 2>&1 && _alt_awks="$_alt_awks busybox"
if [ -n "$_alt_awks" ]; then
  _a17_bad=""
  for _impl in $_alt_awks; do
    _d="$TMP/awkimpl-$_impl"; mkdir -p "$_d"
    case "$_impl" in
      busybox) printf '#!/bin/sh\nexec %s awk "$@"\n' "$(command -v busybox)" > "$_d/awk" ;;
      *)       printf '#!/bin/sh\nexec %s "$@"\n'     "$(command -v "$_impl")" > "$_d/awk" ;;
    esac
    chmod +x "$_d/awk"
    # A quoted mention carrying multi-byte text must still be ALLOWED (the residue is
    # longer, the guard stays quiet, the quoted span is blanked as normal)...
    _m="$(hook_with "$_d" "echo 'the gate — git push — is next'")"
    [ -z "$_m" ] || _a17_bad="$_a17_bad [$_impl over-denied a multi-byte quoted mention]"
    # ...and an issued publish alongside multi-byte text must still be DENIED.
    _i="$(hook_with "$_d" "echo 'note — about git push'\ngit push")"
    denies "$_i" || _a17_bad="$_a17_bad [$_impl allowed an issued publish]"
  done
  [ -z "$_a17_bad" ] \
    && ok "A17: residue-length guard behaves under byte-oriented awk (${_alt_awks# }) — multi-byte quoted mentions still allowed, issued publishes still denied" \
    || nok "A17: residue-length guard misbehaves under a byte-oriented awk" "$_a17_bad"
else
  ok "A17: byte-oriented awk comparison SKIPPED (needs mawk or busybox present)"
fi

# S5: PASS marker written -> publish allowed
"$WRITE" main "privacy" >/dev/null
out="$(pretool "$R" "git push -u origin feature")"
[ -z "$out" ] && ok "PASS marker -> git push ALLOWED" || nok "PASS marker -> git push ALLOWED" "got: $out"
[ "$(expansion "$R")" = "0" ] && ok "PASS marker -> /ship expansion ALLOWED (exit 0)" || nok "/ship expansion allowed"

# S6: version-only bump (gstack Step 12) -> hash unchanged -> still allowed
h_before="$("$HASH" main)"
python3 -c "import json;d=json.load(open('package.json'));d['version']='1.0.1.0';open('package.json','w').write(json.dumps(d,indent=2)+chr(10))"
git add -A; git commit -qm "chore: bump version (v1.0.1.0)"
h_after="$("$HASH" main)"
[ "$h_before" = "$h_after" ] && ok "version-only bump -> hash UNCHANGED" || nok "version bump hash unchanged" "$h_before vs $h_after"
out="$(pretool "$R" "git push")"
[ -z "$out" ] && ok "after version bump -> git push still ALLOWED (marker survives)" || nok "version bump still allowed" "got: $out"

# --- S7 fail-open forensics (runs ONLY when the assertion below fails) --------
#
# HISTORY, so nobody re-chases this: the intermittent S7 "fail-open" that motivated
# this block was NOT a gate bug. It was denies() above returning a false negative —
# SIGPIPE plus pipefail — on a hook output that was a perfectly good deny. Fixed at
# the helper; see TODOS.md "Completed". This block is kept anyway, because a real
# fail-open is still possible and, if one ever happens, it should not cost another
# investigation to find out WHICH path allowed the push.
#
# forgeward-gate-check.sh has THREE silent-allow exits and only the last is a hash.
# Named by construct rather than by line number ON PURPOSE — the line numbers in the
# first draft of this comment were stale within one commit, which is the same way the
# ":398" in TODOS went stale:
#
#   REGEX  `[ "$_pub_hit" = 0 ] || exit 0`
#          The publish regex missed. Reachable when strip_quoted's awk returns output
#          that is GARBLED but non-empty. A7 covers only awk exiting 127 (empty ->
#          raw-text fallback), so that shape is unguarded.
#   REPO   `git rev-parse --git-dir >/dev/null 2>&1 || exit 0`
#          stderr is swallowed, so a transient failure fails open with no trace at all.
#   FRESH  `is_fresh "$b" "HEAD" && exit 0`
#          The hash-equality path everyone assumed.
#
# Every other branch in is_fresh() returns 1 (deny), so FRESH is its only fail-open.
# The evidence recorded in TODOS argues AGAINST FRESH: the companion assertion on the
# line above saw the hash genuinely CHANGE on both observed failures. Nobody had
# instrumented REGEX or REPO. So this dump exists to tell the three apart on the next
# occurrence, and to say whether the state repeats or the moment was transient.
s7d() { printf '  # %s\n' "$*"; }
s7_forensics() { # s7_forensics <hook-stdout> <hook-stderr-file>
  local out="$1" errf="$2" mdir mfile base stored cur repeat=0 i ln
  local tracef="$TMP/s7-trace.txt"
  s7d "===== S7 FAIL-OPEN FORENSICS ====="
  s7d "when=$(date -u +%Y-%m-%dT%H:%M:%SZ) host=$(uname -sr)"
  s7d "load=$(cat /proc/loadavg 2>/dev/null || echo n/a)"
  # squashed to one line: a genuine fail-open gives empty stdout, but anything else
  # arriving here must not break the `#`-prefixed line format the logs are read with
  s7d "hook stdout (a deny was expected): $( [ -n "$out" ] && printf '%s' "$out" | tr '\n' ' ' || echo '<EMPTY -- silent allow>' )"
  s7d "hook stderr: $( [ -s "$errf" ] && tr '\n' ' ' < "$errf" || echo '<empty>' )"

  # --- marker, read the same two ways the hook can read it (P2: jq and python3
  # canonicalise differently, so a divergence here is itself a finding) ---
  mdir="$(git -C "$R" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  mfile="$mdir/forgeward-gate-markers/$(git -C "$R" rev-parse --abbrev-ref HEAD 2>/dev/null).json"
  s7d "marker path: $mfile (exists=$( [ -f "$mfile" ] && echo yes || echo NO ))"
  if [ -f "$mfile" ]; then
    while IFS= read -r ln; do s7d "  marker| $ln"; done < "$mfile"
    if command -v jq >/dev/null 2>&1; then
      s7d "jq      base=$(jq -r '.base // empty' "$mfile" 2>/dev/null) diff_hash=$(jq -r '.diff_hash // empty' "$mfile" 2>/dev/null)"
    fi
    if command -v python3 >/dev/null 2>&1; then
      s7d "python3 base=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("base",""))' "$mfile" 2>/dev/null) diff_hash=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("diff_hash",""))' "$mfile" 2>/dev/null)"
    fi
    base="$(jq -r '.base // empty' "$mfile" 2>/dev/null)"
    stored="$(jq -r '.diff_hash // empty' "$mfile" 2>/dev/null)"
    [ -n "$base" ] || base="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("base",""))' "$mfile" 2>/dev/null)"
    [ -n "$stored" ] || stored="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("diff_hash",""))' "$mfile" 2>/dev/null)"
  fi

  # --- the discriminator: did the hook's own freshness comparison actually match? ---
  cur="$("$HASH" "${base:-main}" HEAD 2>&1)"
  s7d "test-side  h_before=$h_before"
  s7d "test-side  h_dep   =$h_dep"
  s7d "marker     stored  =${stored:-<none>}"
  s7d "recomputed cur     =$cur   (base=${base:-main} tip=HEAD)"
  if [ -n "$stored" ] && [ "$stored" = "$cur" ]; then
    s7d "VERDICT: stored == recomputed -> this IS the FRESH (is_fresh) path"
  else
    s7d "VERDICT: stored != recomputed -> is_fresh could NOT have returned true;"
    s7d "         the allow came from REGEX (publish regex missed) or REPO (rev-parse failed)"
  fi

  # --- git state, in case the repo itself is what went sideways (the REPO exit) ---
  s7d "branch=$(git -C "$R" rev-parse --abbrev-ref HEAD 2>&1) head=$(git -C "$R" rev-parse --short HEAD 2>&1)"
  s7d "git-dir=$(git -C "$R" rev-parse --git-dir 2>&1) common=$(git -C "$R" rev-parse --git-common-dir 2>&1)"
  s7d "status: $(git -C "$R" status --porcelain 2>&1 | tr '\n' ';')"
  while IFS= read -r ln; do s7d "  log| $ln"; done < <(git -C "$R" log --oneline -3 2>&1)

  # --- transient or sticky? the single most useful bit for the next reader ---
  for i in 1 2 3 4 5; do
    denies "$(pretool "$R" "git push")" && repeat=$((repeat+1))
  done
  s7d "immediate re-runs: $repeat/5 denied  (5/5 => one-shot transient; 0/5 => sticky state)"

  # --- traced re-run. /usr/bin/env bash on purpose: that is what the hook's shebang
  # resolves to (linuxbrew 5.3 here, NOT /bin/bash 5.1), and tracing the wrong
  # interpreter answers a question about a different program. ---
  printf '{"cwd":"%s","tool_input":{"command":"%s"}}' "$R" "git push" \
    | /usr/bin/env bash -x "$CHECK" pretooluse >/dev/null 2>"$tracef"
  s7d "--- traced re-run, last 40 xtrace lines (shows the exact exit line) ---"
  while IFS= read -r ln; do s7d "  x| $ln"; done < <(tail -40 "$tracef" 2>/dev/null)

  s7d "toolchain: awk=$(command -v awk 2>/dev/null || echo MISSING) [$(awk --version 2>&1 | head -1)]"
  s7d "toolchain: jq=$(command -v jq 2>/dev/null || echo absent) python3=$(command -v python3 2>/dev/null || echo absent)"
  s7d "toolchain: env bash=$(/usr/bin/env bash --version 2>/dev/null | head -1)"
  s7d "awk liveness on the real input: '$(printf '%s' 'git push' | awk '{print}' 2>&1)'"
  s7d "===== END FORENSICS ====="
}

# S7: dependency added -> hash flips -> denied (re-gate forced)
python3 -c "import json;d=json.load(open('package.json'));d['dependencies']['expresss']='^4.0.0';open('package.json','w').write(json.dumps(d,indent=2)+chr(10))"
git add -A; git commit -qm "feat: add expresss dep"
h_dep="$("$HASH" main)"
[ "$h_before" != "$h_dep" ] && ok "dependency added -> hash CHANGED" || nok "dep add hash changed" "still $h_dep"
# The call itself stays byte-for-byte what pretool() does, minus a stderr redirect —
# the flake is timing-shaped, so the observed invocation must not be perturbed. All
# tracing happens in the failure branch, after the fact.
s7_err="$TMP/s7-hook.err"
s7_out="$(printf '{"cwd":"%s","tool_input":{"command":"%s"}}' "$R" "git push" | "$CHECK" pretooluse 2>"$s7_err")"
if denies "$s7_out"; then
  ok "dependency added after PASS -> git push DENIED (re-gate)"
else
  nok "dep add re-gate denied" "FAIL-OPEN reproduced — forensics follow"
  s7_forensics "$s7_out" "$s7_err"
fi

# S8: new source code after marker -> stale -> denied
git checkout -q -- . 2>/dev/null; git reset -q --hard HEAD~1   # drop the dep commit, back to PASS state
out="$(pretool "$R" "git push")"; [ -z "$out" ] || { nok "reset-to-PASS sanity" "expected allow, got deny"; }
echo "// sneaky new code after gate" >> feature.js; git add -A; git commit -qm "feat: extra code"
denies "$(pretool "$R" "git push")" && ok "new code after marker -> git push DENIED (stale)" || nok "new code stale deny"

# S9: outside a git repo -> fail open (allow), never wedge
out="$(pretool "$TMP" "git push")"   # $TMP is not a git repo
[ -z "$out" ] && ok "outside a git repo -> fail open (allow)" || nok "fail-open outside repo" "got: $out"

# --- worktree: the PreToolUse layer is a best-effort REMINDER (not the lock), but it
# must still handle the common "cd into a worktree, then push" case — honor the cd and
# find the marker under the shared common git dir. Precise, per-ref ENFORCEMENT lives
# in the pre-push hook (test/pre-push-test.sh), which needs none of this text parsing.
# R stays on `feature`; worktrees are added without moving R's HEAD. ---
WT="$TMP/wt"
git -C "$R" worktree add -q -b wtfeat "$WT" main >/dev/null 2>&1
( cd "$WT"; printf 'const w = 1;\n' > wt.js; git add -A; git commit -qm "feat: worktree"; "$WRITE" main "privacy" ) >/dev/null

# W1: `cd <worktree> && git push` -> honor cd -> the worktree's GATED branch -> ALLOWED
# (marker written inside the worktree is found via the common git dir).
out="$(pretool "$R" "cd $WT && git push")"
[ -z "$out" ] && ok "worktree: 'cd <worktree> && git push' on a gated branch -> ALLOWED (honor cd + common-dir marker)" \
  || nok "worktree honor-cd gated allow" "got: $out"

# W2: a worktree on an UNGATED branch -> the reminder still fires there -> DENIED.
WTB="$TMP/wtbad"
git -C "$R" worktree add -q -b wtbad "$WTB" main >/dev/null 2>&1
( cd "$WTB"; echo x > b.js; git add -A; git commit -qm "feat: ungated" ) >/dev/null
denies "$(pretool "$R" "cd $WTB && git push")" \
  && ok "worktree: 'cd <worktree> && git push' on an ungated branch -> DENIED" \
  || nok "worktree honor-cd ungated deny"

# W3: single-quoted cd with a spaced path resolves too (gated) -> ALLOWED.
WTS="$TMP/wt spaced"
git -C "$R" worktree add -q -b wtspace "$WTS" main >/dev/null 2>&1
( cd "$WTS"; echo x > s.js; git add -A; git commit -qm "feat: spaced"; "$WRITE" main "privacy" ) >/dev/null
out="$(pretool "$R" "cd '$WTS' && git push")"
[ -z "$out" ] && ok "worktree: single-quoted 'cd <spaced worktree> && git push' (gated) -> ALLOWED" \
  || nok "worktree single-quoted cd allow" "got: $out"

# S10: the UserPromptExpansion matcher (read from the real hooks.json) must fire on
# `ship` AND any <prefix>-ship (gstack --prefix), but NOT on lookalike commands.
# Evaluated as a JS regex (node) to match Claude Code's matcher engine; python re
# fallback is equivalent for this anchored pattern.
# The path goes through argv, NOT interpolated into the -c script: under MSYS/Git
# Bash a POSIX path embedded in a script STRING reaches native Windows python
# untranslated ('/c/Users/...' -> FileNotFoundError -> empty matcher -> a regex that
# matches everything, so the false-positive assertions silently "pass" nothing).
# Path translation only happens for standalone arguments. Same MSYS boundary that
# produced the reviewer's 'C:' directory tree, mirrored.
MATCHER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["hooks"]["UserPromptExpansion"][0]["matcher"])' "$PLUGIN/hooks/hooks.json")"
[ -n "$MATCHER" ] || { nok "hooks.json matcher readable (test harness precondition)" "empty matcher"; }
rx() { # rx <pattern> <string> -> true|false (JS regex semantics)
  if command -v node >/dev/null 2>&1; then
    node -e 'process.stdout.write(String(new RegExp(process.argv[1]).test(process.argv[2])))' "$1" "$2"
  else
    python3 -c 'import re,sys;print(str(bool(re.search(sys.argv[1],sys.argv[2]))).lower())' "$1" "$2"
  fi
}
[ "$(rx "$MATCHER" ship)" = true ]        && ok "ship-matcher fires on 'ship'" || nok "matcher fires on ship" "pattern=$MATCHER"
[ "$(rx "$MATCHER" gstack-ship)" = true ] && ok "ship-matcher fires on 'gstack-ship' (--prefix default)" || nok "matcher fires on gstack-ship"
[ "$(rx "$MATCHER" myco-ship)" = true ]   && ok "ship-matcher fires on arbitrary '<prefix>-ship'" || nok "matcher fires on custom prefix"
[ "$(rx "$MATCHER" shipment)" = false ]   && ok "ship-matcher does NOT fire on lookalike 'shipment'" || nok "matcher false-positive: shipment"
[ "$(rx "$MATCHER" airship)" = false ]    && ok "ship-matcher does NOT fire on lookalike 'airship'" || nok "matcher false-positive: airship"

# S11: base detection (gate Step 0) must ALWAYS resolve to a real branch, falling
# through to main/master when origin/HEAD is unset. The old inline form returned ''
# because `git symbolic-ref ... | sed` exits 0 on empty input, short-circuiting the
# || chain before the fallback -> empty base -> mis-scoped review diff. Tested
# against the real scripts/forgeward-detect-base.sh.
DETECT="$PLUGIN/scripts/forgeward-detect-base.sh"
detect()      { ( cd "$1" && "$DETECT" 2>/dev/null ); }          # -> base ref (stderr = drift note)
detect_name() { ( cd "$1" && "$DETECT" --name 2>/dev/null ); }   # -> bare branch name

# B1 (the regression): origin/HEAD unset, local main exists -> 'main', NOT empty.
b="$(detect "$R")"
[ "$b" = "main" ] && ok "base detect: origin/HEAD unset -> 'main' via fallback (not empty)" \
  || nok "base detect unset->main" "got: '$b'"

# B2: no main anywhere, only master -> 'master' (final fallback). Force the initial
# branch to master so the global init.defaultBranch can't make this flaky.
RM="$TMP/repo-master"
git -c init.defaultBranch=master init -q "$RM"
( cd "$RM"; git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  echo x > f; git add -A; git commit -qm base ) >/dev/null
b="$(detect "$RM")"
[ "$b" = "master" ] && ok "base detect: no main, only master -> 'master' (final fallback)" \
  || nok "base detect ->master" "got: '$b'"

# B3: origin/HEAD SET -> uses it (behavior unchanged when set). Fake an origin whose
# HEAD points at origin/develop.
RH="$TMP/repo-head"
git init -q "$RH"
( cd "$RH"; git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  echo x > f; git add -A; git commit -qm base; git branch -M main
  git remote add origin /nonexistent.git
  git update-ref refs/remotes/origin/develop HEAD
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop ) >/dev/null
b="$(detect "$RH")"
# The NAME still comes from origin/HEAD; the REF is the remote-tracking one, because
# refs/remotes/origin/develop exists and is the publish boundary. (This previously
# asserted the bare name 'develop' — that assertion was the bug: a bare name
# resolves to the LOCAL branch, which drifts from the remote in both directions.)
[ "$b" = "origin/develop" ] && ok "base detect: origin/HEAD set -> honored, as the remote-tracking ref" \
  || nok "base detect set->origin/develop" "got: '$b'"
[ "$(detect_name "$RH")" = "develop" ] && ok "base detect: --name gives the bare branch back for PR targeting" \
  || nok "base detect --name on origin/HEAD repo" "got: '$(detect_name "$RH")'"

# B4 (direct-to-base): HEAD committed DIRECTLY on the base branch with
# origin/<base> behind by the unpushed commit. Bare 'main' makes "main...HEAD"
# EMPTY -> the gate mis-reads "nothing to gate" and deadlocks (push stays
# hook-blocked, yet no reviewable surface). Resolving to the publish boundary
# origin/main puts the real unpushed change in scope. Mirrors the live repro: a
# docs commit made straight to master. Stage B now covers this as one case of the
# general rule, so it no longer needs the special-cased "HEAD is on the base" arm.
RD="$TMP/repo-direct"
git init -q "$RD"
( cd "$RD"; git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  echo base > f; git add -A; git commit -qm base; git branch -M main
  git update-ref refs/remotes/origin/main HEAD                    # origin/main == C0
  echo changed > doc.md; git add -A; git commit -qm "docs: direct-to-base commit" ) >/dev/null  # HEAD == C1, on main
b="$(detect "$RD")"
[ "$b" = "origin/main" ] && ok "base detect: HEAD on base branch + unpushed commit -> origin/main (publish boundary)" \
  || nok "base detect direct-to-base -> origin/main" "got: '$b'"
# Meaningfulness: new base scopes the REAL change; the old bare base would be empty.
new_diff="$(cd "$RD" && git diff "$b...HEAD" --name-only)"
old_diff="$(cd "$RD" && git diff "main...HEAD" --name-only)"
{ [ "$new_diff" = "doc.md" ] && [ -z "$old_diff" ]; } \
  && ok "base detect: origin/main scopes real change (doc.md); bare 'main' diff is empty (proves the fix matters)" \
  || nok "direct-to-base diff meaningfulness" "new='$new_diff' old='$old_diff'"

# --- B5..B13: the base must be the PUBLISH BOUNDARY, not a local branch name -----
# A bare branch name resolves to the LOCAL branch, which is only as current as the
# last time the user checked it out. Both drift directions mis-scope the review:
#   behind the remote -> reviewers audit already-merged code (waste, wrong findings)
#   ahead of the remote -> the gate reviews LESS than the push publishes (false PASS)
# Helper: build a repo and echo nothing; every assertion cds in a subshell.
mkrepo() { # mkrepo <dir>
  git init -q "$1"
  git -C "$1" config user.email t@t.t
  git -C "$1" config user.name t
  git -C "$1" config commit.gpgsign false
}
cm() { # cm <dir> <file> <msg>
  ( cd "$1" && echo "$2" > "$2" && git add -A && git commit -qm "$3" ) >/dev/null 2>&1
}

# B5 (over-scoping, the VERIFIED repro): local main is 3 commits behind origin/main
# and the feature branch was cut from the FRESH remote. Bare 'main' drags every
# already-merged commit into the review surface.
RB="$TMP/repo-behind"
mkrepo "$RB"
( cd "$RB"
  echo c0 > f; git add -A; git commit -qm c0; git branch -M main
  for i in 1 2 3; do echo "m$i" > "merged$i.txt"; git add -A; git commit -qm "merged $i"; done
  git update-ref refs/remotes/origin/main HEAD                 # remote has all 3
  git update-ref refs/heads/main "$(git rev-parse HEAD~3)"     # local main never fast-forwarded
  git remote add origin ./.git
  git checkout -q -b feature origin/main
  echo new > feature.txt; git add -A; git commit -qm "feat: the actual PR" ) >/dev/null 2>&1
b="$(detect "$RB")"
[ "$b" = "origin/main" ] && ok "base detect: local base BEHIND remote -> origin/main (publish boundary), not stale 'main'" \
  || nok "base detect behind-remote -> origin/main" "got: '$b'"
new_files="$(cd "$RB" && git diff --name-only "$b...HEAD" | sort | tr '\n' ' ')"
old_files="$(cd "$RB" && git diff --name-only "main...HEAD" | sort | tr '\n' ' ')"
{ [ "$new_files" = "feature.txt " ] && [ "$old_files" != "feature.txt " ]; } \
  && ok "base detect: behind-remote scopes ONLY the PR (feature.txt); bare 'main' over-scopes to '$old_files'" \
  || nok "behind-remote scope" "new='$new_files' old='$old_files'"

# B6 (under-scoping — the FALSE PASS, previously unverified): the base branch has
# unpushed commits and the feature branched off them. `main...HEAD` hides the
# unpushed base commits that the push WILL publish -> the gate PASSes a surface it
# never saw. This is the dangerous direction.
RA="$TMP/repo-ahead"
mkrepo "$RA"
( cd "$RA"
  echo c0 > f; git add -A; git commit -qm c0; git branch -M main
  git update-ref refs/remotes/origin/main HEAD                 # remote stops here
  git remote add origin ./.git
  echo "vuln" > unpushed-base-1.php; git add -A; git commit -qm "unpushed base 1"
  echo "vuln" > unpushed-base-2.php; git add -A; git commit -qm "unpushed base 2"
  git checkout -q -b feature
  echo new > feature.txt; git add -A; git commit -qm "feat: the actual PR" ) >/dev/null 2>&1
b="$(detect "$RA")"
[ "$b" = "origin/main" ] && ok "base detect: local base AHEAD of remote -> origin/main (unpushed base commits are in scope)" \
  || nok "base detect ahead-of-remote -> origin/main" "got: '$b'"
gated="$(cd "$RA" && git diff --name-only "$b...HEAD" | sort | tr '\n' ' ')"
naive="$(cd "$RA" && git diff --name-only "main...HEAD" | sort | tr '\n' ' ')"
{ case "$gated" in *unpushed-base-1.php*unpushed-base-2.php*) true ;; *) false ;; esac } \
  && [ "$naive" = "feature.txt " ] \
  && ok "base detect: ahead-of-remote reviews everything the push publishes; bare 'main' saw only '$naive' (false PASS)" \
  || nok "ahead-of-remote scope" "gated='$gated' naive='$naive'"

# B7: no remote at all (local-only repo, or gh unauthenticated). There is no
# remote-tracking ref and the local branch IS the truth -> must stay bare, never
# blindly prefixed with origin/.
RN="$TMP/repo-noremote"
mkrepo "$RN"
( cd "$RN"; echo c0 > f; git add -A; git commit -qm c0; git branch -M main
  git checkout -q -b feature; echo x > x.txt; git add -A; git commit -qm feat ) >/dev/null 2>&1
b="$(detect "$RN")"
[ "$b" = "main" ] && ok "base detect: no remote at all -> bare 'main' (no blind origin/ prefix)" \
  || nok "base detect no-remote -> main" "got: '$b'"
( cd "$RN" && git rev-parse --verify --quiet "$b" >/dev/null ) \
  && ok "base detect: no-remote base resolves to a real ref" || nok "no-remote base resolves" "got: '$b'"

# B8: detached HEAD is a LEGITIMATE state (bisect, CI checkout, tag review). The
# script must still resolve a usable base and must not error out.
RDH="$TMP/repo-detached"
mkrepo "$RDH"
( cd "$RDH"; echo c0 > f; git add -A; git commit -qm c0; git branch -M main
  echo c1 > g; git add -A; git commit -qm c1
  git checkout -q --detach HEAD ) >/dev/null 2>&1
b="$( cd "$RDH" && "$DETECT" 2>/dev/null )"; rc=$?
{ [ "$rc" = 0 ] && [ -n "$b" ] && ( cd "$RDH" && git rev-parse --verify --quiet "$b" >/dev/null ); } \
  && ok "base detect: detached HEAD -> still resolves a real ref (exit 0, '$b')" \
  || nok "base detect detached HEAD" "rc=$rc got: '$b'"

# B9: a fork whose upstream is NOT origin. git's own tracking config is the truth;
# hardcoding origin/ would review against the wrong repository.
RF="$TMP/repo-fork"
mkrepo "$RF"
( cd "$RF"
  echo c0 > f; git add -A; git commit -qm c0; git branch -M main
  git update-ref refs/remotes/upstream/main HEAD
  echo forkonly > forkonly.txt; git add -A; git commit -qm "fork-only commit"
  git update-ref refs/remotes/origin/main HEAD                 # fork's origin is ahead
  git remote add origin ./.git; git remote add upstream ./.git
  git config branch.main.remote upstream
  git config branch.main.merge refs/heads/main
  git checkout -q -b feature; echo x > x.txt; git add -A; git commit -qm feat ) >/dev/null 2>&1
b="$(detect "$RF")"
[ "$b" = "upstream/main" ] && ok "base detect: fork tracking a non-origin upstream -> upstream/main (honors git config)" \
  || nok "base detect fork upstream" "got: '$b'"

# B10: a base branch that legitimately has no remote counterpart yet (created
# locally, never pushed) while other remote refs DO exist -> must stay bare.
RNC="$TMP/repo-nocounterpart"
mkrepo "$RNC"
( cd "$RNC"
  echo c0 > f; git add -A; git commit -qm c0; git branch -M main
  git remote add origin ./.git
  git update-ref refs/remotes/origin/other HEAD                # a remote exists, but not origin/main
  git checkout -q -b feature; echo x > x.txt; git add -A; git commit -qm feat ) >/dev/null 2>&1
b="$(detect "$RNC")"
[ "$b" = "main" ] && ok "base detect: base with no remote counterpart -> bare 'main' (not origin/main)" \
  || nok "base detect no-counterpart" "got: '$b'"

# B11: local branch tracking a DIFFERENTLY NAMED remote branch (local 'main' ->
# origin/master). Prefixing the local name would resolve to a ref that does not exist.
RR="$TMP/repo-renamed"
mkrepo "$RR"
( cd "$RR"
  echo c0 > f; git add -A; git commit -qm c0; git branch -M main
  git remote add origin ./.git
  git update-ref refs/remotes/origin/master HEAD
  git config branch.main.remote origin
  git config branch.main.merge refs/heads/master
  git checkout -q -b feature; echo x > x.txt; git add -A; git commit -qm feat ) >/dev/null 2>&1
b="$(detect "$RR")"
[ "$b" = "origin/master" ] && ok "base detect: local 'main' tracking origin/master -> origin/master (honors branch.*.merge)" \
  || nok "base detect renamed upstream" "got: '$b'"

# B12: the stale-local re-scope is CORRECTED SILENTLY ON STDOUT and REPORTED ON
# STDERR. stdout must stay exactly one clean ref (callers use "$(...)"), and the
# drift must not be swallowed — the user needs to know their checkout is stale.
lines="$( cd "$RB" && "$DETECT" 2>/dev/null | wc -l | tr -d ' ' )"
[ "$lines" = "1" ] && ok "base detect: stdout is exactly one line even when the drift note fires" \
  || nok "base detect stdout hygiene" "got $lines lines"
note="$( cd "$RB" && "$DETECT" 2>&1 >/dev/null )"
case "$note" in
  *behind*origin/main*) ok "base detect: stale local base REPORTED on stderr (not silently swallowed)" ;;
  *) nok "base detect stderr drift note" "got: '$note'" ;;
esac

# B13: --name gives the bare branch name back, for callers that need a branch
# (e.g. `gh pr create --base <name>`), where 'origin/main' would be wrong.
n="$(cd "$RB" && "$DETECT" --name 2>/dev/null)"
[ "$n" = "main" ] && ok "base detect: --name returns the bare branch name ('main') for PR targeting" \
  || nok "base detect --name" "got: '$n'"

# B14: step 1 of stage A (`gh repo view`) is a NETWORK call. It must not fire when
# no remote could possibly BE a GitHub repo — a repo with no remote at all, or one
# whose remote is a filesystem path — because it can only ever fail there, and this
# script runs ~15 times per suite (unguarded 114s/201s/93s vs guarded 29s/33s/37s
# over three runs each; the 108s-wide spread is the network showing through). The
# guard must be a short-circuit, not a behavior change: with a networked remote the
# call still fires and still wins, so the positive control below is the assertion
# that matters. A stub `gh` on PATH records whether it was invoked.
GHBIN="$TMP/ghstub"; mkdir -p "$GHBIN"
printf '#!/usr/bin/env bash\nprintf "called\\n" >> "$GH_STUB_LOG"\nexit 1\n' > "$GHBIN/gh"
chmod +x "$GHBIN/gh"
gh_calls() { # gh_calls <repo>  -> number of times detect invoked gh
  local log="$TMP/gh-stub.log"
  : > "$log"
  ( cd "$1" && PATH="$GHBIN:$PATH" GH_STUB_LOG="$log" "$DETECT" >/dev/null 2>&1 )
  wc -l < "$log" | tr -d ' '
}

# RN has no remote at all; RB has one, but it is the filesystem path './.git'.
[ "$(gh_calls "$RN")" = "0" ] && ok "base detect: no remote at all -> gh NOT invoked (network call skipped)" \
  || nok "no-remote skips gh" "gh was invoked $(gh_calls "$RN") time(s)"
[ "$(gh_calls "$RB")" = "0" ] && ok "base detect: filesystem-path remote -> gh NOT invoked (a path is never a GitHub repo)" \
  || nok "path-remote skips gh" "gh was invoked $(gh_calls "$RB") time(s)"

# Positive control: a networked remote MUST still reach gh, or the guard has
# silently deleted step 1 rather than short-circuiting it. Uses a URL that is never
# contacted — the stub answers first.
RGH="$TMP/repo-github"
mkrepo "$RGH"
( cd "$RGH"; echo c0 > f; git add -A; git commit -qm c0; git branch -M main
  git remote add origin https://github.com/example/example.git
  git checkout -q -b feature; echo x > x.txt; git add -A; git commit -qm feat ) >/dev/null 2>&1
[ "$(gh_calls "$RGH")" -ge 1 ] && ok "base detect: networked remote -> gh IS invoked (guard short-circuits, does not remove step 1)" \
  || nok "networked remote reaches gh" "gh was never invoked"
# Still with the stub on PATH: the suite must never make a real network call, and
# the stub's non-zero exit is exactly the "gh present but unhelpful" case anyway.
n_gh="$( cd "$RGH" && PATH="$GHBIN:$PATH" GH_STUB_LOG="$TMP/gh-stub.log" "$DETECT" --name 2>/dev/null )"
[ "$n_gh" = "main" ] \
  && ok "base detect: gh failing after the guard still falls through to the local answer ('main')" \
  || nok "gh-failure fallthrough" "got: '$n_gh'"

# The guard must not change WHICH base the no-remote repos resolve to (B7 asserts
# the value; this asserts the guard did not perturb it).
[ "$(detect "$RN")" = "main" ] && ok "base detect: guard leaves the no-remote answer unchanged ('main')" \
  || nok "guard perturbed no-remote answer" "got: '$(detect "$RN")'"

# The guard classifies by URL SHAPE, and the shapes that must still reach gh are the
# ones an allow-list gets wrong. git makes the `user@` of scp-like syntax OPTIONAL,
# so `github.com:org/repo.git` and an SSH-config alias like `gh:org/repo` are both
# ordinary networked remotes. An early version of this guard allow-listed `*@*:*`
# and classified those as local, which silently resolved the base to a STALE local
# branch — the false-PASS direction. Each row: <url> <must-reach-gh>.
url_reaches_gh() { # url_reaches_gh <url> -> "yes"/"no"
  local d="$TMP/urlprobe" log="$TMP/gh-url.log"
  rm -rf "$d"; mkrepo "$d" >/dev/null 2>&1
  ( cd "$d" && echo c0 > f && git add -A && git commit -qm c0 && git branch -M main
    git remote add origin "$1" ) >/dev/null 2>&1
  : > "$log"
  ( cd "$d" && PATH="$GHBIN:$PATH" GH_STUB_LOG="$log" "$DETECT" >/dev/null 2>&1 )
  [ -s "$log" ] && echo yes || echo no
}
while read -r u want; do
  [ -n "$u" ] || continue
  got="$(url_reaches_gh "$u")"
  [ "$got" = "$want" ] \
    && ok "base detect: remote '$u' -> gh reached=$got (as required)" \
    || nok "remote URL classification: $u" "wanted reached=$want, got=$got"
# Every `yes` row below was verified against the real binary, not reasoned about:
# `GIT_SSH_COMMAND='echo dialed' git ls-remote <url>` dials for the tilde-host, bare
# host, IPv6 and scp-like rows, and does not for the path rows. `~mybox:repo.git` and
# `foo/bar:baz` are the pair that matters — they differ from their neighbours only in
# whether a slash precedes the first colon, which is exactly git's rule and exactly
# what three rounds of prefix-guessing kept getting wrong.
done <<'URLS'
https://github.com/o/r.git yes
ssh://git@github.com/o/r yes
git@github.com:o/r.git yes
github.com:o/r.git yes
gh:o/r yes
~mybox:repo.git yes
[::1]:repo yes
./.git no
/srv/mirror/r.git no
../sibling no
~/local/repo no
foo/bar:baz no
file:///srv/mirror/r.git no
URLS

# The drive-letter shapes get their own assertions because their correct answer
# FLIPS with the platform, and both directions were live bugs during 0.7.2.
#
# Off Windows, git's has_dos_drive_prefix() is compiled out, so it parses
# `C:/foo/bar` as scp-like with the one-letter HOSTNAME `C` and really dials it:
#   GIT_SSH_COMMAND='echo $@' git ls-remote 'C:/foo/bar'  ->  C git-upload-pack '/foo/bar'
# `g:/data/repo.git` — an SSH alias plus an absolute path, the ordinary
# gitolite/gitea shape — must therefore reach gh.
#
# On Windows the same string is a real drive path, AND it is what MSYS rewrites an
# absolute POSIX remote into: `git remote add origin /srv/mirror/r.git` is stored as
# `C:/Program Files/Git/srv/mirror/r.git`. So there the answer is the opposite, and a
# guard with no drive-letter arm classified a plain local mirror as networked.
# Deleting the arm to satisfy the first case broke the second; only a platform check
# satisfies both.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) drive_want=no  ; drive_why="drive path (git compiles in has_dos_drive_prefix here)" ;;
  *)                    drive_want=yes ; drive_why="one-letter SSH host (git really dials it here)" ;;
esac
for u in 'g:/data/repo.git' 'C:/Users/x/repo.git'; do
  got="$(url_reaches_gh "$u")"
  [ "$got" = "$drive_want" ] \
    && ok "base detect: remote '$u' -> gh reached=$got — $drive_why" \
    || nok "drive-letter classification: $u" "wanted reached=$drive_want on $(uname -s), got=$got"
done

# --- P1..P11: a read-only reviewer must not write scanner output into the repo ---
# Observed on Windows/Git Bash: semgrep invoked with `-o <windows-absolute-path>`
# under a POSIX shell created 'C:/Users/.../semgrep.json' as a RELATIVE directory
# tree at the root of the repo under review (on-disk name 'C' + U+F03A). Untracked,
# matched by no common .gitignore, so `git add -A` commits it — and a read-only
# reviewer wrote into the repo it was auditing. A prompt-level instruction was
# tried and failed twice, so enforcement lives in the hook and the scan wrapper.
SCAN="$PLUGIN/scripts/forgeward-scan.sh"
ARTDIR="$PLUGIN/scripts/forgeward-artifact-dir.sh"
GUARD="$PLUGIN/scripts/forgeward-workspace-guard.sh"

# P1/P2: the exact defective shape is DENIED (both slash conventions).
denies "$(pretool "$R" 'semgrep scan --config p/security-audit --json -o C:/Users/x/scratchpad/semgrep.json .')" \
  && ok "scan guard: semgrep -o <windows-abs-path> DENIED (the observed repo-contamination shape)" \
  || nok "scan guard denies drive-letter -o"
denies "$(pretool "$R" 'trivy fs --format json --output D:\\scan\\out.json .')" \
  && ok "scan guard: --output <drive:\\backslash path> DENIED too" \
  || nok "scan guard denies backslash drive path"
# P2b (regression): the CUDDLED short form is one argv token, so a pattern anchored to
# the start of a token misses it entirely. Both this guard and forgeward-scan.sh had
# that hole — the shape that was supposed to be caught by "layers 2 and 3 are the net"
# was in fact caught by neither.
denies "$(pretool "$R" 'semgrep scan --json -oC:/Users/x/scratchpad/semgrep.json .')" \
  && ok "scan guard: CUDDLED '-oC:/…' (single token) DENIED — not just the spaced form" \
  || nok "scan guard denies cuddled drive path"

# P3/P4/P5: explicit NON-GOALS. The guard fires on drive-letter paths only — it is
# not a ban on writing files, and it must never block a developer's own scanner run.
[ -z "$(pretool "$R" 'semgrep scan --config p/security-audit --json .')" ] \
  && ok "scan guard: stdout-only semgrep ALLOWED (the shape reviewers are told to use)" \
  || nok "scan guard allows stdout form"
[ -z "$(pretool "$R" 'semgrep scan --json -o report.json .')" ] \
  && ok "scan guard: deliberate relative -o ALLOWED (a developer's own run is none of the gate's business)" \
  || nok "scan guard allows relative -o"
[ -z "$(pretool "$R" 'semgrep scan --json -o /tmp/out.json .')" ] \
  && ok "scan guard: POSIX-absolute -o ALLOWED" || nok "scan guard allows posix-abs -o"
[ -z "$(pretool "$R" 'echo C:/Users/x/foo.json')" ] \
  && ok "scan guard: a drive path in a NON-scanner command ALLOWED (no collateral denials)" \
  || nok "scan guard non-scanner untouched"

# P7: the wrapper refuses an output-file flag outright, at the layer reviewers use.
out="$("$SCAN" semgrep scan --json -o C:/Users/x/semgrep.json . 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && case "$out" in *STDOUT*|*stdout*) true ;; *) false ;; esac; } \
  && ok "forgeward-scan: refuses -o and points at stdout capture (exit $rc)" \
  || nok "forgeward-scan refuses -o" "rc=$rc out='$out'"

# P8: the wrapper is a passthrough otherwise — stdout reaches the caller intact.
out="$("$SCAN" printf 'HELLO-STDOUT' 2>/dev/null)"
[ "$out" = "HELLO-STDOUT" ] && ok "forgeward-scan: passes tool stdout through unchanged" \
  || nok "forgeward-scan stdout passthrough" "got: '$out'"

# P8b: whether `-o <word>` is a FORMAT or a FILENAME is a PER-TOOL fact. grype and syft
# overload `-o` (`-o json` -> stdout, `-o json=file` -> writes). trivy does not: its own
# help reads `-o, --output string   output file name`, with `-f/--format` separate, so
# `trivy -f json -o json .` writes a file literally named `json`. semgrep and gitleaks
# match trivy. Treating the format allowlist as tool-agnostic made every format word a
# writable filename for three of the four scanners this wrapper guards.
STUBDIR="$TMP/stubs"; mkdir -p "$STUBDIR"
for _n in grype syft trivy semgrep; do
  printf '#!/usr/bin/env bash\necho "{}"\n' > "$STUBDIR/$_n"; chmod +x "$STUBDIR/$_n"
done
"$SCAN" "$STUBDIR/grype" -o json >/dev/null 2>&1
[ "$?" = 0 ] && ok "forgeward-scan: 'grype -o json' ALLOWED (grype overloads -o; the value is a format)" \
  || nok "forgeward-scan allows -o <format> for grype" "expected exit 0"
"$SCAN" "$STUBDIR/syft" -ojson >/dev/null 2>&1
[ "$?" = 0 ] && ok "forgeward-scan: cuddled 'syft -ojson' ALLOWED too" \
  || nok "forgeward-scan allows cuddled -o<format> for syft" "expected exit 0"
tool_ok=1; tool_bad=""
for _t in trivy semgrep; do
  "$SCAN" "$STUBDIR/$_t" -o json >/dev/null 2>&1
  [ "$?" = 2 ] || { tool_ok=0; tool_bad="$tool_bad $_t"; }
done
[ "$tool_ok" = 1 ] && ok "forgeward-scan: 'trivy/semgrep -o json' REFUSED — their -o is a filename, so that writes a file named 'json'" \
  || nok "forgeward-scan tool-agnostic format allowlist" "wrongly allowed:$tool_bad"
"$SCAN" "$STUBDIR/grype" -o json=out.json >/dev/null 2>&1
[ "$?" = 2 ] && ok "forgeward-scan: grype's WRITE form '-o json=out.json' still refused" \
  || nok "forgeward-scan refuses grype -o fmt=file" "expected exit 2"

# P8c/P8d (regressions): two shapes that slipped past the first version of the wrapper.
# The cuddled short flag is one token; and an extension-less relative value ('-o report')
# is still a FILE — the old check only refused values with a slash or a known extension,
# so it created ./report in the repo under review.
"$SCAN" printf X -oC:/Users/x/semgrep.json >/dev/null 2>&1
[ "$?" = 2 ] && ok "forgeward-scan: CUDDLED '-oC:/…' refused (drive letter found anywhere in the token)" \
  || nok "forgeward-scan refuses cuddled drive path" "expected exit 2"
"$SCAN" printf X -o myreport >/dev/null 2>&1
[ "$?" = 2 ] && ok "forgeward-scan: extension-less '-o myreport' refused (deny-by-default; only known FORMAT words pass)" \
  || nok "forgeward-scan refuses extension-less output value" "expected exit 2"

# P8e (regression): closing the cuddled hole with a FULLY unanchored drive-letter match
# over-refused. `<letter>:/` occurs inside legitimate scanner arguments — a remote
# --config URL, and syft/grype source specifiers — none of which are Windows paths.
# Refusing them is friction that pushes a reviewer to bypass the wrapper entirely.
allow_ok=1; allow_bad=""
for _a in "--config|https://semgrep.dev/p/ci" "dir:/home/user/repo" "oci-dir:/img"; do
  _l="${_a%%|*}"; _r="${_a#*|}"
  if [ "$_l" = "$_a" ]; then "$SCAN" printf X "$_a" >/dev/null 2>&1
  else "$SCAN" printf X "$_l" "$_r" >/dev/null 2>&1; fi
  [ "$?" = 0 ] || { allow_ok=0; allow_bad="$allow_bad $_a"; }
done
[ "$allow_ok" = 1 ] && ok "forgeward-scan: a ':/'-bearing NON-path arg is ALLOWED (remote --config URL, syft/grype 'dir:' specifier)" \
  || nok "forgeward-scan over-refuses ':/' args" "refused:$allow_bad"

# P8f (regression): _FORMAT_WORDS wraps across source lines, so the wrap points are
# literal newlines. A `*" $1 "*` test against the raw string silently dropped whichever
# words sat against a wrap — they were then treated as destination paths.
fmt_ok=1; fmt_bad=""
for _f in json sarif yml cyclonedx compact full summary verbose; do
  "$SCAN" "$STUBDIR/grype" -o "$_f" >/dev/null 2>&1
  [ "$?" = 0 ] || { fmt_ok=0; fmt_bad="$fmt_bad $_f"; }
done
[ "$fmt_ok" = 1 ] && ok "forgeward-scan: every format word is recognized, including the ones on _FORMAT_WORDS line wraps" \
  || nok "forgeward-scan format-word line-wrap bug" "wrongly refused:$fmt_bad"

# P8g (regression): ':' is a flag/value separator too (the MSBuild/dotnet/PowerShell
# convention). Handling only '=' left every ENUMERATED output flag reachable through an
# alternate separator — not an unlisted flag (a stated non-goal) but a listed one via a
# side door, so the wrapper's own guarantee was defeated rather than merely incomplete.
colon_ok=1; colon_bad=""
for _c in '--output:C:/x' '--report-file:C:/x' '--sarif-output:C:/x' '-o:C:/x' '--output:report.json' '--outfile:myreport'; do
  "$SCAN" printf X "$_c" >/dev/null 2>&1
  [ "$?" = 2 ] || { colon_ok=0; colon_bad="$colon_bad $_c"; }
done
[ "$colon_ok" = 1 ] && ok "forgeward-scan: COLON-joined output flags refused ('--output:C:/x'), not just '=' and space" \
  || nok "forgeward-scan colon-joined bypass" "passed through:$colon_bad"
# …and the colon widening must not repeat the earlier overshoot.
colon_allow=1; colon_abad=""
for _c in '--config:https://semgrep.dev/p/ci' 'localhost:5000/img:latest' 'dir:/home/user/repo'; do
  "$SCAN" printf X "$_c" >/dev/null 2>&1
  [ "$?" = 0 ] || { colon_allow=0; colon_abad="$colon_abad $_c"; }
done
[ "$colon_allow" = 1 ] && ok "forgeward-scan: colon-bearing NON-path args still ALLOWED (colon-joined URL, registry ref with port+tag)" \
  || nok "forgeward-scan colon widening over-refuses" "refused:$colon_abad"

# P8h (regression): a DASH-LED value for an output flag. looks_like_path() used to
# short-circuit on `-*` — "that's another flag, not this flag's value" — which is simply
# false for getopt-family parsers: pflag/Cobra (gitleaks, trivy) consume the next token
# unconditionally. `gitleaks dir . --report-path -evil.json` went through the wrapper
# with no objection and gitleaks wrote -evil.json into the repo under review. Bare '-'
# stays allowed: it means stdout, the one dash-led value that is not a file.
dash_ok=1; dash_bad=""
for _d in '--output|-x.json' '--report-path|-evil.json' '-o|-x.json' '--outfile|-report' '--output|--'; do
  "$SCAN" printf X "${_d%%|*}" "${_d#*|}" >/dev/null 2>&1
  [ "$?" = 2 ] || { dash_ok=0; dash_bad="$dash_bad ${_d/|/ }"; }
done
[ "$dash_ok" = 1 ] && ok "forgeward-scan: DASH-LED output values refused ('--report-path -evil.json'), incl. a '--' decoy" \
  || nok "forgeward-scan dash-led value bypass" "passed through:$dash_bad"
"$SCAN" printf X -o - >/dev/null 2>&1
[ "$?" = 0 ] && ok "forgeward-scan: bare '-o -' still ALLOWED (stdout, not a file)" \
  || nok "forgeward-scan refuses bare '-'" "expected exit 0"

# P8i: the same shape end-to-end against a REAL scanner, where one is installed — the
# proof that matters is that nothing lands in the repo, not that a string was matched.
if command -v gitleaks >/dev/null 2>&1; then
  DR="$TMP/dashrepo"; mkrepo "$DR"
  ( cd "$DR"; echo x > a.txt; git add -A; git commit -qm base ) >/dev/null 2>&1
  ( cd "$DR" && "$SCAN" gitleaks dir . --report-path -evil.json --no-banner ) >/dev/null 2>&1
  rc=$?
  { [ "$rc" = 2 ] && [ ! -e "$DR/-evil.json" ]; } \
    && ok "forgeward-scan: real gitleaks with a dash-led --report-path is refused and the repo stays clean" \
    || nok "forgeward-scan real dash-led write" "rc=$rc, -evil.json present: $([ -e "$DR/-evil.json" ] && echo yes || echo no)"
else
  ok "forgeward-scan real dash-led write: SKIPPED (gitleaks not installed)"
fi

# P9: the artifact dir is POSIX-absolute, exists, and is OUTSIDE the repo.
ad="$( cd "$R" && "$ARTDIR" )"
case "$ad" in
  /*) ok "artifact dir: POSIX-absolute ('$ad')" ;;
  *)  nok "artifact dir posix-absolute" "got: '$ad'" ;;
esac
[ -d "$ad" ] && ok "artifact dir: exists" || nok "artifact dir exists" "got: '$ad'"
case "$ad" in
  "$R"/*) nok "artifact dir outside repo" "'$ad' is inside the repo under review" ;;
  *)      ok "artifact dir: outside the repo under review" ;;
esac

# P10: the workspace guard catches ANY new untracked path a reviewer leaves behind —
# including shapes the command-text guard structurally cannot see.
snap="$ad/snapshot.txt"
( cd "$R" && "$GUARD" snapshot > "$snap" )
# A plain scratch file, because that is the general shape: the guard's job is to catch
# ANY new untracked path, whatever produced it. (Staging the literal 'C:' tree is
# platform-dependent — MSYS coreutils resolve it to a real Windows path — so it is
# asserted separately below, only where it can actually be staged.)
( cd "$R" && echo '{"results":[]}' > reviewer-scratch.json )
gout="$( cd "$R" && "$GUARD" check "$snap" 2>&1 )"; grc=$?
{ [ "$grc" != 0 ] && case "$gout" in *reviewer-scratch.json*) true ;; *) false ;; esac; } \
  && ok "workspace guard: flags a reviewer-created file by name and exits non-zero" \
  || nok "workspace guard detects contamination" "rc=$grc out='$gout'"
( cd "$R" && rm -f reviewer-scratch.json )
gout="$( cd "$R" && "$GUARD" check "$snap" 2>&1 )"; grc=$?
[ "$grc" = 0 ] && ok "workspace guard: clean tree -> exit 0 (no false alarm)" \
  || nok "workspace guard clean tree" "rc=$grc out='$gout'"
# The observed shape specifically, where the platform can stage it.
if ( cd "$R" && mkdir -p 'C:/Users/x/scratchpad' 2>/dev/null && echo '{}' > 'C:/Users/x/scratchpad/semgrep.json' 2>/dev/null && [ -e 'C:' ] ); then
  gout="$( cd "$R" && "$GUARD" check "$snap" 2>&1 )"; grc=$?
  { [ "$grc" != 0 ] && case "$gout" in *'C:'*) true ;; *) false ;; esac; } \
    && ok "workspace guard: flags the reviewer-created 'C:' tree specifically" \
    || nok "workspace guard detects C: tree" "rc=$grc out='$gout'"
  # './'-prefixed, per the invariant this change establishes: a BARE 'C:' resolves to the
  # drive root under MSYS. Unreachable there today (mkdir resolves it natively, so the
  # guard above is false), but the test must not depend on mkdir and rm translating a
  # drive-letter argument identically.
  ( cd "$R" && rm -rf -- './C:' )
else
  ok "workspace guard: 'C:' tree not stageable on this platform (drive paths resolve natively) — general case asserted above"
fi

# P11/P12: the LIVE filesystem behaviour, with a stub that writes its report exactly
# the way a scanner's -o does (makedirs + open on the path it was handed). Real
# semgrep reproduces this identically — verified by hand, and re-runnable here with
# FORGEWARD_TEST_SEMGREP=1 — but a registry-loading scanner is too slow and too
# network-dependent to sit in a regression suite.
#
# The control is PLATFORM-CONDITIONAL and that is the point: whether 'C:/x' lands
# inside the repo depends on who resolves the path. Under a POSIX runtime it is
# relative (contamination). Under MSYS coreutils or native Windows Python it is
# absolute (no contamination). So the test asks the platform first, then asserts the
# guard either way — a POSIX-only assertion would pass while the bug remained.
SGR="$TMP/scanrepo"; mkrepo "$SGR"
( cd "$SGR"; echo 'x' > a.js; git add -A; git commit -qm base ) >/dev/null 2>&1
STUB="$TMP/fakescan"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Stands in for a scanner writing its report to the path in --out (or a hardcoded one
# with --hardcoded), using the same makedirs+open a scanner's -o writer uses.
#
# It tries a native python3 first and, if that resolved the drive letter natively
# (Windows Python, so nothing landed in the CWD), retries through `wsl.exe -e python3`.
# That second runtime is not a contrivance: it is the configuration that produced the
# original bug — a POSIX-runtime scanner invoked from a Windows shell, where 'C:/…' is
# a relative path. It is what lets the Git Bash run exercise the real defect instead of
# reporting it unstageable.
out=""; rc=0
case "${1:-}" in
  --hardcoded)      out='C:/Users/x/scratchpad/semgrep.json' ;;
  --hardcoded-fail) out='C:/Users/x/scratchpad/semgrep.json'; rc=9 ;;  # contaminates AND fails
  # PLAIN-RELATIVE contamination: a scratch file with no drive letter, so it lands in
  # the repo on EVERY platform. The exit-code contract (0 -> 3, non-zero preserved) is
  # not a property of the drive-letter shape — it is a property of "this run left new
  # untracked paths behind" — so it must be asserted where the drive-letter shape is
  # unstageable (MSYS/native-Windows runtimes resolve 'C:/…' absolutely).
  --dirty)          out='reviewer-report.json' ;;
  --dirty-fail)     out='reviewer-report.json'; rc=9 ;;                # contaminates AND fails
  --out) out="${2:-}" ;;
esac
[ -n "$out" ] || { echo '{"results":[]}'; exit "$rc"; }
write() { "$@" -c 'import os,sys
p=sys.argv[1]; d=os.path.dirname(p)
if d: os.makedirs(d, exist_ok=True)
open(p,"w").write("{}")' "$out" 2>/dev/null; }
write python3
case "$out" in
  [A-Za-z]:[\\/]*)
    [ -e "./${out%%/*}" ] || { command -v wsl.exe >/dev/null 2>&1 && write wsl.exe -e python3; } ;;
esac
echo '{"results":[]}'
exit "$rc"
STUBEOF
chmod +x "$STUB"

( cd "$SGR" && "$STUB" --out 'C:/Users/x/scratchpad/semgrep.json' ) >/dev/null 2>&1
if [ -e "$SGR/C:" ]; then
  ok "scan control: an unguarded drive-letter output path DOES create the 'C:' tree in the repo on this platform (bug reproduced)"
  rm -rf "$SGR/C:"
  contaminates=1
else
  ok "scan control: this platform resolves 'C:/…' natively (MSYS/Windows runtime) — contamination not stageable here, guards asserted anyway"
  contaminates=0
fi

# P11: layer 2 — the wrapper refuses the drive-letter argument, so the tool never runs.
out="$("$SCAN" "$STUB" --out 'C:/Users/x/scratchpad/semgrep.json' 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && [ ! -e "$SGR/C:" ]; } \
  && ok "forgeward-scan: refuses a drive-letter output path outright (tool never runs, repo untouched)" \
  || nok "forgeward-scan refuses drive-letter arg" "rc=$rc"

# P12: layer 3 — a scanner whose bad path is INTERNAL passes every text-level guard
# (nothing in the command mentions it). The wrapper still catches it, because it diffs
# the repo's untracked set across the run.
#
# It REPORTS and does not delete, deliberately: on Git Bash the tree is named
# 'C' + U+F03A, which MSYS maps back to 'C:', and `readlink -f "C:"` there resolves to
# C:/ — THE DRIVE ROOT. An auto-`rm -rf` would have targeted the user's whole C: drive
# on exactly the platform this bug lives on. Only the './'-prefixed form stays
# relative, so that is what the wrapper prints for the user to run.
hard="$( cd "$SGR" && "$SCAN" "$STUB" --hardcoded 2>"$ad/scan-stderr.txt" )"; hard_rc=$?
serr="$(cat "$ad/scan-stderr.txt" 2>/dev/null)"
# P12b: contamination must not read as SUCCESS. The stub exits 0 (a scanner that finds
# nothing does too), so a caller checking only $? would see a clean run while the repo
# has just been written to. Only asserted where the platform can stage the write.
if [ "$contaminates" = 1 ]; then
  [ "$hard_rc" = 3 ] && ok "forgeward-scan: a tool that exits 0 but contaminates the repo yields exit 3, not 0" \
    || nok "forgeward-scan contamination exit code" "got rc=$hard_rc, expected 3"
  ( cd "$SGR" && rm -rf -- './C:' )
  # …and the substitution must never MASK a real tool failure. Only a zero becomes 3.
  ( cd "$SGR" && "$SCAN" "$STUB" --hardcoded-fail ) >/dev/null 2>&1; fail_rc=$?
  [ "$fail_rc" = 9 ] && ok "forgeward-scan: a tool that contaminates AND fails keeps its own exit code (9), not 3" \
    || nok "forgeward-scan masks tool failure" "got rc=$fail_rc, expected 9"
else
  [ "$hard_rc" = 0 ] && ok "forgeward-scan: clean run passes the tool's own exit code through (0)" \
    || nok "forgeward-scan clean exit passthrough" "got rc=$hard_rc"
fi
if [ "$contaminates" = 1 ]; then
  { case "$hard" in *results*) true ;; *) false ;; esac; } \
    && { case "$serr" in *'rm -rf -- "./'*) true ;; *) false ;; esac; } \
    && [ -e "$SGR/C:" ] \
    && ok "forgeward-scan: ran the tool (stdout intact), REPORTED the 'C:' tree it created via an INTERNAL path, and left removal to the user (auto-rm would hit the drive root here)" \
    || nok "forgeward-scan reports internal-path contamination" "stdout='$hard' stderr='$serr'"
  ( cd "$SGR" && rm -rf -- './C:' )
else
  case "$hard" in *results*) ok "forgeward-scan: internal-path contamination not stageable here (platform resolves drive paths natively); tool still ran, stdout intact" ;;
                  *) nok "forgeward-scan internal-path passthrough" "stdout='$hard'" ;; esac
fi

# P12c/P12d: the exit-code contract, asserted on EVERY platform.
#
# P12/P12b above can only run where the drive-letter tree is stageable, so on MSYS and
# native-Windows runtimes the two assertions that matter most — contamination is not
# success, and the substitution never masks a real failure — were skipped entirely. That
# is backwards: the wrapper's exit-code logic keys off "did the untracked set change",
# not off the drive letter, so a plain relative scratch file exercises the identical
# branch and lands in the repo everywhere. These run unconditionally; the drive-letter
# pair stays platform-conditional because the '.C:'-tree MESSAGE genuinely is
# platform-specific.
dfile="$SGR/reviewer-report.json"
dout="$( cd "$SGR" && "$SCAN" "$STUB" --dirty 2>"$ad/dirty-stderr.txt" )"; drc=$?
derr="$(cat "$ad/dirty-stderr.txt" 2>/dev/null)"
{ [ "$drc" = 3 ] && [ -e "$dfile" ]; } \
  && ok "forgeward-scan: a tool that exits 0 but leaves an untracked file yields exit 3 (asserted on every platform)" \
  || nok "forgeward-scan contamination exit code (platform-independent)" "rc=$drc, file present: $([ -e "$dfile" ] && echo yes || echo no)"
{ case "$derr" in *reviewer-report.json*) true ;; *) false ;; esac; } \
  && { case "$dout" in *results*) true ;; *) false ;; esac; } \
  && ok "forgeward-scan: names the contaminating path on stderr and still passes tool stdout through" \
  || nok "forgeward-scan contamination report (platform-independent)" "stdout='$dout' stderr='$derr'"
rm -f "$dfile"

# The one the checkpoint flagged as missing off-Linux: contaminates AND fails. Only a
# ZERO becomes 3; a tool that already failed keeps its own code, because the caller
# knows something went wrong and 3 would erase which thing.
( cd "$SGR" && "$SCAN" "$STUB" --dirty-fail ) >/dev/null 2>&1; dfrc=$?
{ [ "$dfrc" = 9 ] && [ -e "$dfile" ]; } \
  && ok "forgeward-scan: a tool that contaminates AND fails keeps its own exit code (9, not 3) — asserted on every platform" \
  || nok "forgeward-scan masks tool failure (platform-independent)" "rc=$dfrc, expected 9; file present: $([ -e "$dfile" ] && echo yes || echo no)"
rm -f "$dfile"

# Control: a clean run of the same stub must NOT trip the contamination path, or the two
# assertions above would pass for the wrong reason (any exit-3 would look like a catch).
( cd "$SGR" && "$SCAN" "$STUB" ) >/dev/null 2>&1; crc=$?
[ "$crc" = 0 ] && ok "forgeward-scan: same stub with no writes -> exit 0 (the exit-3 assertions above are not vacuous)" \
  || nok "forgeward-scan clean-run control" "rc=$crc, expected 0"

# Opt-in: the same control against the real scanner, off by default (slow, hits the
# rule registry). FORGEWARD_TEST_SEMGREP=1 bash test/gate-test.sh
if [ "${FORGEWARD_TEST_SEMGREP:-0}" = 1 ] && command -v semgrep >/dev/null 2>&1; then
  ( cd "$SGR" && semgrep scan --config "$PLUGIN/rules/wp-security.yml" --metrics=off --json \
      -o 'C:/Users/x/scratchpad/semgrep.json' a.js ) >/dev/null 2>&1
  real=0; [ -e "$SGR/C:" ] && real=1; rm -rf "$SGR/C:"
  [ "$real" = "$contaminates" ] \
    && ok "real semgrep matches the stub's contamination behaviour on this platform" \
    || nok "real semgrep vs stub" "semgrep=$real stub=$contaminates"
fi

# --- G1..G4 (marker GC): markers must not accumulate forever -------------------
# One marker per branch ever gated, left behind by every merge-and-delete. Never
# consulted (lookup is keyed by the CURRENT branch) but unbounded. write-marker prunes
# on write. Placed last so nothing downstream depends on R's marker state.
MARKDIR="$(git -C "$R" rev-parse --path-format=absolute --git-common-dir)/forgeward-gate-markers"

# G1: a marker is written for a branch that is about to be deleted.
( cd "$R" && git checkout -qb gcdead && echo g > gc.txt && git add -A && git commit -qm gc && "$WRITE" main "privacy" ) >/dev/null 2>&1
[ -f "$MARKDIR/gcdead.json" ] && ok "marker GC: precondition — a marker exists for branch 'gcdead'" \
  || nok "marker GC precondition" "no $MARKDIR/gcdead.json"

# G2: delete the branch, gate again -> the orphaned marker is pruned.
( cd "$R" && git checkout -q feature && git branch -D gcdead ) >/dev/null 2>&1
( cd "$R" && "$WRITE" main "privacy" ) >/dev/null 2>&1
[ ! -f "$MARKDIR/gcdead.json" ] && ok "marker GC: a marker whose branch no longer exists is pruned on the next write" \
  || nok "marker GC prunes orphan" "$MARKDIR/gcdead.json still present"

# G3: the marker just written survives (the obvious way to get this wrong).
[ -f "$MARKDIR/feature.json" ] && ok "marker GC: the marker just written survives its own GC pass" \
  || nok "marker GC ate its own marker" "no $MARKDIR/feature.json"

# G4 (the case it must NOT fire on): a branch checked out in ANOTHER linked worktree
# is alive. Existence is checked against refs/heads under the common git dir, which
# every worktree shares -- so 'wtfeat', gated from inside $WT and never checked out in
# R, must keep its marker. Deleting it would force a needless re-gate in that worktree.
{ [ -f "$MARKDIR/wtfeat.json" ] && [ -f "$MARKDIR/wtspace.json" ]; } \
  && ok "marker GC: markers for branches live in OTHER worktrees survive (refs/heads is shared)" \
  || nok "marker GC ate a live worktree branch's marker" "wtfeat/wtspace marker missing"

# --- V1..V5: version-bearing manifests -----------------------------------------
# A Claude Code plugin carries its version in THREE files, and a release bumps all
# of them together. Neutralizing only package.json meant every release flipped the
# substantive-diff hash and forced a spurious re-gate, so the "cosmetic bookkeeping
# stays invisible" contract held for ordinary repos but not for a plugin.
#
# V2 is the assertion that matters. Bump-invariance failing costs a re-gate;
# substantive-blindness failing costs a false PASS on a manifest that declares
# hooks, permissions and entrypoints. The loose direction is the expensive one, so
# it is pinned per manifest and per version-field SHAPE (top-level vs nested).
RV="$TMP/repo-manifests"
mkrepo "$RV"
( cd "$RV"
  mkdir -p .claude-plugin
  printf '{\n  "name": "u",\n  "version": "1.0.0"\n}\n' > package.json
  printf '{\n  "name": "p",\n  "version": "1.0.0",\n  "defaultEnabled": true\n}\n' > .claude-plugin/plugin.json
  printf '{\n  "name": "m",\n  "plugins": [\n    { "name": "p", "version": "1.0.0" }\n  ]\n}\n' > .claude-plugin/marketplace.json
  echo ok > src.js
  git add -A; git commit -qm base; git branch -M main
  git checkout -q -b feature; echo more > f.js; git add -A; git commit -qm feat ) >/dev/null 2>&1

setjson() { # setjson <repo> <file> <python-expr-on-d>
  ( cd "$1" && python3 -c "import json,sys
d=json.load(open('$2'))
$3
open('$2','w').write(json.dumps(d,indent=2)+chr(10))" )
}

v_base="$(cd "$RV" && "$HASH" main)"

# V1: a version-only bump across ALL THREE manifests leaves the hash alone.
setjson "$RV" package.json                      "d['version']='1.0.1'"
setjson "$RV" .claude-plugin/plugin.json        "d['version']='1.0.1'"
setjson "$RV" .claude-plugin/marketplace.json   "d['plugins'][0]['version']='1.0.1'"
( cd "$RV" && git add -A && git commit -qm "chore: bump version" ) >/dev/null 2>&1
v_bump="$(cd "$RV" && "$HASH" main)"
[ "$v_base" = "$v_bump" ] && ok "manifests: version-only bump across all three -> hash UNCHANGED (no spurious re-gate on release)" \
  || nok "three-manifest bump invariance" "$v_base vs $v_bump"

# V2: a SUBSTANTIVE change to plugin.json must still flip the hash. plugin.json
# declares hooks, permissions and entrypoints — going blind to it is a false PASS,
# which is the failure this whole file exists to prevent.
setjson "$RV" .claude-plugin/plugin.json "d['hooks']='./hooks/extra.json'"
( cd "$RV" && git add -A && git commit -qm "feat: declare an extra hooks file" ) >/dev/null 2>&1
v_hook="$(cd "$RV" && "$HASH" main)"
[ "$v_bump" != "$v_hook" ] && ok "manifests: non-version change to plugin.json -> hash CHANGED (re-gate forced)" \
  || nok "plugin.json substantive change flips hash" "still $v_hook — a manifest change is now INVISIBLE to the gate"
( cd "$RV" && git reset -q --hard HEAD~1 ) >/dev/null 2>&1

# V3: same for marketplace.json, whose version is NESTED at .plugins[].version —
# a different code path from the top-level case, so it needs its own assertion.
setjson "$RV" .claude-plugin/marketplace.json "d['plugins'][0]['source']='https://elsewhere.example/evil'"
( cd "$RV" && git add -A && git commit -qm "feat: repoint the plugin source" ) >/dev/null 2>&1
v_src="$(cd "$RV" && "$HASH" main)"
[ "$v_bump" != "$v_src" ] && ok "manifests: non-version change to marketplace.json -> hash CHANGED (nested shape not over-neutralized)" \
  || nok "marketplace.json substantive change flips hash" "still $v_src"
( cd "$RV" && git reset -q --hard HEAD~1 ) >/dev/null 2>&1

# V4: BACK-COMPAT. A repo with no .claude-plugin/ must hash to exactly the bytes
# this script produced before the two extra manifests were handled, or every marker
# in every ordinary repo goes stale on upgrade. The expected value is rebuilt here
# from the legacy payload format independently, so a change to the script's
# assembly fails this test rather than silently redefining "unchanged".
RL="$TMP/repo-legacy"
mkrepo "$RL"
( cd "$RL"
  printf '{\n  "name": "u",\n  "version": "1.0.0",\n  "dependencies": { "express": "^4.19.2" }\n}\n' > package.json
  echo ok > src.js; git add -A; git commit -qm base; git branch -M main
  git checkout -q -b feature; echo more > f.js; git add -A; git commit -qm feat ) >/dev/null 2>&1
legacy="$( cd "$RL"
  dp="$(git diff "main...HEAD" -- . ':(exclude)VERSION' ':(exclude)CHANGELOG.md' \
        ':(exclude)CHANGELOG' ':(exclude)TODOS.md' ':(exclude)package.json' 2>/dev/null)"
  raw="$(git show "HEAD:package.json" 2>/dev/null)"
  if command -v jq >/dev/null 2>&1; then pp="$(printf '%s' "$raw" | jq -S '.version = "<<forgeward-gated>>"')"
  else pp="$(printf '%s' "$raw" | python3 -c 'import json,sys
d=json.load(sys.stdin); d["version"]="<<forgeward-gated>>"
sys.stdout.buffer.write(json.dumps(d,sort_keys=True,separators=(",",":")).encode())')"
  fi
  printf '%s\n--FORGEWARD-PKG--\n%s\n' "$dp" "$pp" | sha256sum | awk '{print $1}' )"
[ "$(cd "$RL" && "$HASH" main)" = "$legacy" ] \
  && ok "manifests: repo with no .claude-plugin/ hashes to the LEGACY bytes (existing markers survive the upgrade)" \
  || nok "legacy payload back-compat" "got $(cd "$RL" && "$HASH" main), legacy $legacy"

# V5: the python3 fallback must implement the SAME semantics as the jq path, not
# merely run. Exercised by putting a PATH in front that has python3 but no jq. Only
# meaningful where jq is the branch that would otherwise be taken.
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
  for t in env bash git sha256sum awk python3; do
    p="$(command -v "$t" 2>/dev/null)"; [ -n "$p" ] && ln -sf "$p" "$NOJQ/$t"
  done
  v_saved="$( cd "$RV" && git rev-parse HEAD )"
  fb_bump="$( cd "$RV" && PATH="$NOJQ" "$HASH" main )"
  ( cd "$RV" && git reset -q --hard HEAD~1 ) >/dev/null 2>&1   # back to pre-bump
  fb_base="$( cd "$RV" && PATH="$NOJQ" "$HASH" main )"
  ( cd "$RV" && git reset -q --hard "$v_saved" ) >/dev/null 2>&1
  { [ -n "$fb_bump" ] && [ "$fb_bump" = "$fb_base" ]; } \
    && ok "manifests: python3 fallback reproduces bump-invariance with jq unavailable (same semantics, not just runnable)" \
    || nok "python3 fallback invariance" "base='$fb_base' bump='$fb_bump'"

  # V6: invariance alone is the cheap half. A fallback that neutralized too much
  # would satisfy V5 perfectly while going blind to a real manifest change, so the
  # substantive direction has to be asserted under the SAME jq-less PATH.
  setjson "$RV" .claude-plugin/plugin.json "d['permissions']={'allow':['Bash(rm -rf /)']}"
  ( cd "$RV" && git add -A && git commit -qm "feat: widen permissions" ) >/dev/null 2>&1
  fb_subst="$( cd "$RV" && PATH="$NOJQ" "$HASH" main )"
  ( cd "$RV" && git reset -q --hard "$v_saved" ) >/dev/null 2>&1
  [ -n "$fb_subst" ] && [ "$fb_subst" != "$fb_bump" ] \
    && ok "manifests: python3 fallback still flips the hash on a substantive plugin.json change (not over-neutralizing)" \
    || nok "python3 fallback substantive detection" "bump='$fb_bump' subst='$fb_subst' — the fallback is BLIND to a manifest change"
else
  ok "manifests: python3-fallback comparison SKIPPED (needs both jq and python3 present)"
fi

# M1 (manifest hooks guard): the standard hooks/hooks.json is auto-loaded by Claude
# Code, so .claude-plugin/plugin.json must NOT also reference it via the "hooks" key —
# doing so fails plugin load with "Duplicate hooks file detected". The manifest.hooks
# key is only for ADDITIONAL hook files. Guard it statically so a re-add is caught here.
MANIFEST="$PLUGIN/.claude-plugin/plugin.json"
hooks_ref="$(
  if command -v jq >/dev/null 2>&1; then jq -r '.hooks // ""' "$MANIFEST"
  else python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("hooks",""))' "$MANIFEST"
  fi
)"
case "$hooks_ref" in
  */hooks.json) nok "manifest does not re-reference the auto-loaded hooks/hooks.json" "plugin.json hooks='$hooks_ref' (remove it; the standard file auto-loads)" ;;
  *)            ok "manifest does not re-reference the auto-loaded hooks/hooks.json (no duplicate-load)" ;;
esac

# D1-D12: gstack skill detection, which decides whether supply-chain-reviewer audits
# dependency CVEs or defers them to `/cso`. The deferral used to be unconditional, so on
# a machine without gstack nobody checked CVEs and the reviewer returned PASS clean.
#
# EVERY assertion here pins a DIRECTION, not just a result. A false negative costs the
# reviewer duplicated work; a false positive is a silently skipped check — the original
# bug. So the interesting cases below are the ones that must come back "not installed",
# and a future edit that makes detection more eager has to turn one of them red.
#
# CLAUDE_CONFIG_DIR is set on every call. Without it these would read the developer's
# REAL ~/.claude — where gstack is very likely installed — and D3 would pass by finding
# somebody's actual /cso.
DET="$PLUGIN/scripts/forgeward-detect-gstack-skill.sh"
det() { # det <config-dir> <skill> -> exit code
  ( CLAUDE_CONFIG_DIR="$1" "$DET" "$2" >/dev/null 2>&1 ); echo $?
}
mkskill() { # mkskill <dir> <description-line>
  mkdir -p "$1"
  printf -- '---\nname: cso\nversion: 2.0.0\n%s\n---\n\nBody of the skill.\n' "$2" > "$1/SKILL.md"
}
MARKER='description: Chief Security Officer mode. (gstack)'

# D1: the --no-prefix install shape.
D1="$TMP/det1"; mkskill "$D1/skills/cso" "$MARKER"
[ "$(det "$D1" cso)" = 0 ] \
  && ok "detect: bare skill dir with the (gstack) marker is INSTALLED" \
  || nok "detect D1" "expected 0"

# D2: the DEFAULT install shape. gstack's setup ships SKILL_PREFIX=1, so the skills-dir
# entry is named after the patched `name:` field — `gstack-cso`. A literal `cso` match
# misses this, which fails closed but does so for everyone who took the default.
D2="$TMP/det2"; mkskill "$D2/skills/gstack-cso" "$MARKER"
[ "$(det "$D2" cso)" = 0 ] \
  && ok "detect: gstack- PREFIXED dir is INSTALLED (the default setup shape)" \
  || nok "detect D2" "expected 0"

# D3: the case the whole change exists for — no gstack at all.
D3="$TMP/det3"; mkdir -p "$D3/skills"
[ "$(det "$D3" cso)" = 1 ] \
  && ok "detect: empty skills dir is NOT installed (the standalone case)" \
  || nok "detect D3" "expected 1 — a false positive here re-opens the CVE hole"

# D4: a skill genuinely named `cso` that is not gstack's. The name alone must not be
# enough, or an unrelated skill silently switches the reviewer into DEFERRED mode.
D4="$TMP/det4"; mkskill "$D4/skills/cso" 'description: Some other vendor CSO helper.'
[ "$(det "$D4" cso)" = 1 ] \
  && ok "detect: same-named skill WITHOUT the marker is NOT installed (name alone is not enough)" \
  || nok "detect D4" "expected 1 — an unrelated skill was read as gstack's"

# D5: a directory with no SKILL.md is not a skill.
D5="$TMP/det5"; mkdir -p "$D5/skills/cso"
[ "$(det "$D5" cso)" = 1 ] \
  && ok "detect: directory with no SKILL.md is NOT installed" \
  || nok "detect D5" "expected 1"

# D6: THE REAL INSTALL SHAPE. link_claude_skill_dirs drops SYMLINKS into the skills dir,
# so a check that refuses to follow links (find -type d, or an lstat copied from the
# hardening in forgeward-scan.sh, where refusing IS correct) reports every real gstack
# install as absent.
D6="$TMP/det6"; mkskill "$TMP/det6-src/cso" "$MARKER"; mkdir -p "$D6/skills"
ln -s "$TMP/det6-src/cso" "$D6/skills/cso"
[ "$(det "$D6" cso)" = 0 ] \
  && ok "detect: SYMLINKED skill dir is INSTALLED (how gstack actually installs)" \
  || nok "detect D6" "expected 0 — link-following broke, so every real install reads as absent"

# D7: the prefix is constrained to the same shape the ship matcher accepts
# ([A-Za-z0-9_]+-), so a name that merely ENDS in -cso does not qualify.
D7="$TMP/det7"; mkskill "$D7/skills/not-really-cso" "$MARKER"
[ "$(det "$D7" cso)" = 1 ] \
  && ok "detect: a dir merely ENDING in -cso does not qualify as a prefixed install" \
  || nok "detect D7" "expected 1"

# D8: gstack can arrive as a plugin instead, one marketplace and one plugin deep.
D8="$TMP/det8"; mkskill "$D8/plugins/cache/some-marketplace/gstack/skills/cso" "$MARKER"
[ "$(det "$D8" cso)" = 0 ] \
  && ok "detect: plugin-cache install is INSTALLED" \
  || nok "detect D8" "expected 0"

# D9: the marker is looked for in the FRONTMATTER only. A body may quote "(gstack)"
# while describing an integration, and the body is the larger, far more quotable surface.
D9="$TMP/det9"; mkdir -p "$D9/skills/cso"
printf -- '---\nname: cso\ndescription: Some other helper.\n---\n\nWorks well with (gstack).\n' \
  > "$D9/skills/cso/SKILL.md"
[ "$(det "$D9" cso)" = 1 ] \
  && ok "detect: marker in the BODY does not count (frontmatter only)" \
  || nok "detect D9" "expected 1"

# D10: a folded or quoted description still carries the marker. This is why the check
# scans the frontmatter BLOCK rather than matching a `description:` line — gstack's own
# skills use all three forms (plain, quoted, folded).
D10="$TMP/det10"; mkdir -p "$D10/skills/cso"
printf -- '---\nname: cso\ndescription: |\n  Chief Security Officer mode. Infrastructure-first\n  security audit and threat modeling. (gstack)\n---\n\nBody.\n' \
  > "$D10/skills/cso/SKILL.md"
[ "$(det "$D10" cso)" = 0 ] \
  && ok "detect: FOLDED multi-line description still carries the marker" \
  || nok "detect D10" "expected 0"

# D11: a project-local skill counts — it is installed for anyone working in this repo.
D11="$TMP/det11"; mkdir -p "$D11/skills"
mkskill "$R/.claude/skills/cso" "$MARKER"
[ "$( ( cd "$R" && CLAUDE_CONFIG_DIR="$D11" "$DET" cso >/dev/null 2>&1 ); echo $? )" = 0 ] \
  && ok "detect: project-local .claude/skills counts as INSTALLED" \
  || nok "detect D11" "expected 0"
rm -rf "$R/.claude"

# D12: a malformed argument is a usage error (2), not a silent "installed". Any non-zero
# is FULL mode for the caller, so this direction is safe either way — asserted so the
# distinction between "absent" and "you called it wrong" does not quietly disappear.
[ "$(det "$D1" 'cso/../../etc')" = 2 ] \
  && ok "detect: a path-shaped argument is a usage error, never a match" \
  || nok "detect D12" "expected 2"

echo "1..$((PASS+FAIL))"
echo "# pass $PASS / fail $FAIL"
[ "$FAIL" -eq 0 ]
