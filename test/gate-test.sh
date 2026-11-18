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
# The writer takes the reviewed commits and the gate run's id since 0.31.0. Every caller
# here gates the commit it just made, so both are resolved in the caller's cwd at call
# time, and the run is minted the way Step 2 mints it: a `--revoke` of that commit, whose
# `RUN_ID=` line is taken and whose other output is kept off this helper's stdout. That
# revoke withdraws the marker of every branch at the commit, so a fixture that wants two
# branches' markers at ONE commit cannot get them from two calls of this helper.
write_marker_with() { # write_marker_with <writer> <base-ref> <fired-csv>
  local head run
  head="$(git rev-parse HEAD)"
  run="$("$1" --revoke "$head" | sed -n 's/^RUN_ID=//p')"
  "$1" "$2" "$3" "$(git rev-parse "$2")" "$head" "$run"
}
write_marker() { write_marker_with "$WRITE" "$@"; } # write_marker <base-ref> <fired-csv>
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
# AD_OUT: directories forgeward-artifact-dir.sh handed out (P9..P9d). Its fallbacks are
# hard-coded under the real /tmp, outside $TMP, so the trap removes them too. Only one path
# component below /tmp is ever removed; anything with a further `/` is left alone.
AD_OUT=()
cleanup() {
  local d
  for d in ${AD_OUT[@]+"${AD_OUT[@]}"}; do
    case "$d" in
      /tmp/forgeward-artifacts/*/*|/tmp/forgeward-artifacts.*/*) ;;
      /tmp/forgeward-artifacts/[0-9]*|/tmp/forgeward-artifacts.??????) rm -rf -- "$d" ;;
    esac
  done
  rm -rf "$TMP"
}
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
# One case in that group is written `g\"\"it push` rather than `g""it push`, and the
# escaping is load-bearing: pretool() assembles its JSON with raw printf, so the bare
# form emits two adjacent strings and the payload is not JSON at all. It passed for
# years by short-circuiting on an empty command — precisely the hollow "allow" A9 below
# exists to catch, in the one place A9 does not look. Escaped, the field decodes to
# `g""it push` and the matcher is actually asked, which is what the line claims to test.
# (It still allows: the disclosure stands, it is now earned.) Found when the
# unparseable-input fix at A20 turned this red — the case's verdict had been coming from
# the harness rather than from the code under test.
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
allow|g\"\"it push
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

# A23: A PUSH THAT ONLY DELETES REMOTE REFS PUBLISHES NO CODE, so it is allowed.
#
# The two layers disagreed here, and the FAST one was the stricter: pre-push skips any
# ref whose local sha is all-zero (`forgeward-pre-push.sh`, "branch deletion -> publishes
# no code"), which is exactly what git sends for both `--delete` and `:refspec`, while
# this layer matched `git push` as a word and denied. A reminder that refuses what the
# enforcement it reminds you about waves through is a bug in the reminder. Worse, the
# advice it gave was unactionable: nothing is published, so there is nothing for a
# reviewer to review and no marker could ever attest to it — the only way through was to
# gate an unrelated branch first.
#
# Two unrelated cases this must serve: post-merge cleanup of a branch you just merged,
# and dropping a stale branch that never had a PR (no marker will EVER exist for it).
#
# The verdicts below are not read off git's manual. Every ALLOW was executed against a
# real remote and the remote's ref list compared before and after; every DENY that could
# publish was executed too, and two of them did:
#   git push origin :x main    -> deleted x AND published main
#   git push --tags origin :x  -> deleted x AND published a tag on an unpublished commit
# The second is why unrecognised OPTIONS deny rather than being skipped: `--tags` sends
# refs the argument list never names. (`--delete` is safe from that — git itself refuses
# "--delete is incompatible with --all, --mirror and --tags" — but the colon form is not,
# and that asymmetry is invisible from the text.)
#
# The QUOTE cases are the ones the first draft got wrong, and they were a real ALLOW on a
# real publish. `strip_quoted` BLANKS a quote or backslash to a space instead of removing
# it, so `git push /pub/repo'':x.git` — ONE repository argument to bash — reaches the
# classifier as `… /pub/repo  :x.git`, counts plain=1 colon=1, and was exempted while
# actually pushing the current branch. Reproduced against a real remote before the fix
# (`refs/heads/main` appeared on a target that had no refs), which is why the same shape
# appears here in three spellings: `''`, `""` and `\`. They are the whole blanking set —
# `strip_quoted` maps every character to itself or a space and never deletes one, so a
# word boundary can only be ADDED, and every path that adds one needs one of those three.
# `git push origin\ --delete x` is the same defect aimed at the OTHER branch: bash reads
# one token, the residue shows a `--delete` flag that was never issued as one.
#
# The GLOB cases are the same defect a second time, via a different bash feature, and
# they are why the token test is an ALLOWLIST rather than a longer list of bad characters.
# `read -ra` does not glob, so `git push [os]* :newcode` is ONE token here and however many
# files it matches when bash runs it. Reproduced against a real remote: allowed by the
# matcher, and it deleted `newcode` while PUBLISHING `secretbranch`, a ref the command text
# never named. Nothing legitimate is lost — `git check-ref-format` rejects `*`, `?` and `[`
# in a ref name, verified rather than assumed. `git push origin~1 :x` is the same rule
# catching a character that is merely exotic rather than dangerous, which is the cost side.
#
# `git push origin :x 'main'` is the WORST shape of the quote defect and the reason the
# quote refusal is pinned by more than the splitting spellings. Here the quoting does not
# split a token, it DELETES one: `strip_quoted` blanks the span, so the publishing refspec
# `main` is simply absent from the residue, leaving `origin :x` — a textbook delete-only
# push — while bash still hands `main` to git as a live argument. Every guard downstream is
# defeated by a token it never sees, so the raw-text refusal is the only thing that catches
# it. Surfaced by the third security review, which found it exploitable against a mutant
# with that line removed (`git push origin :x secretbranch2` really created the branch).
# Its sibling `git push origin ':x' main` is here as a NEAR MISS, not a duplicate: quoting
# the colon token instead removes it entirely, so `colon=0` and the aggregation check
# refuses it while the raw-text refusal never comes into play. Both were run against a
# real remote and both really delete `x` AND publish `main`; they simply die at different
# guards, which is only visible from a mutation run and not from reading either one.
#
# `git push :x origin` pins ORDER, not count. git takes the first bare positional as the
# repository wherever the colon refspecs sit, so `origin` there is a refspec. It fails in
# git today for an unrelated reason (`:x` resolves as an empty-host ssh target) — the
# exemption must not rest on someone else's error path, so the classifier refuses it.
#
# The compound-command denials are the load-bearing half. A stacked-branch workflow that
# interleaves deletions with real pushes must keep being gated, so ANY shell
# metacharacter refuses the exemption outright rather than trying to work out which
# command the verb belongs to — that is the grammar-enumeration dead end this file's
# header exists to warn about.
matrix "deletion exemption misclassifies a push (it must allow ONLY what publishes nothing)" \
  "publish matcher: a push that can only DELETE remote refs is allowed (no code is published, so no marker could attest to it), while anything that might also publish still denies" <<'CASES'
allow|git push origin --delete fix/my-branch
allow|git push origin -d fix/my-branch
allow|git push -d origin fix/my-branch
allow|git push origin --delete stale-a stale-b
allow|git push -q --no-verify origin --delete stale
allow|git push --atomic origin --delete stale
allow|git push origin :refs/heads/x
allow|git push origin :x
allow|git push origin :x :y
deny|git push origin --delete x && git push
deny|git push origin --delete x; git push origin main
deny|git push origin --delete x\ngit push origin main
deny|git push origin --delete x && gh pr create --base main
deny|git push origin :x main
deny|git push --tags origin :x
deny|git push --all origin
deny|git push --mirror origin
deny|git push --delete-this-is-not-a-flag origin x
deny|git push origin --deletex
deny|git push -o ci.skip origin --delete x
deny|sudo git push origin --delete x
deny|time git push origin --delete x
deny|cd /x && git push origin --delete y
deny|git push origin '--delete' x
deny|git push /pub/repo'':x.git
deny|git push /pub/repo\"\":x.git
deny|git push /pub/repo\\:x.git
deny|git push origin\\ --delete x
deny|git push :x origin
deny|git push [os]* :newcode
deny|git push * :newcode
deny|git push origin --delete stale-?
deny|git push origin --delete [ab]-stale
deny|git push origin~1 :x
deny|git push origin :x 'main'
deny|git push origin ':x' main
deny|git push origin --delete $B
deny|git push origin --delete $(cat b)
deny|git push origin --delete `cat b`
deny|echo 'git push origin --delete x'; git push
deny|gh pr create -d --base main
deny|glab mr create -d -b main
deny|git push origin main
deny|git push
CASES

# A24: the exemption is only ever taken on a TRUSTED residue.
#
# The whole reason a quoted `--delete` cannot open it is that strip_quoted has already
# blanked the span by the time the token check runs. On the paths where the residue is
# NOT trusted — a command bearing `$(`/backtick/`${ `, or an awk that failed — the raw
# text still carries its quotes and that guarantee is gone, so the exemption is refused
# and the pre-existing deny stands. Same direction as A7: degrade closed, never open.
#
# Asserted rather than reasoned about, because the trust flag is one variable away from
# being dropped in a refactor and nothing else in the suite would notice.
noawk_del="$(pretool_noawk "$R" "git push origin --delete x")"
noawk_colon="$(pretool_noawk "$R" "git push origin :refs/heads/x")"
if denies "$noawk_del" && denies "$noawk_colon"; then
  ok "A24: with awk unavailable the deletion exemption is NOT taken (an untrusted residue cannot tell a quoted --delete from an issued one) — degrades closed"
else
  nok "A24: the deletion exemption fires on an UNTRUSTED residue, where a quoted flag is indistinguishable from an issued one" \
      "delete=$(denies "$noawk_del" && echo deny || echo allow) colon=$(denies "$noawk_colon" && echo deny || echo allow)"
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

# A18: marker_get must trust jq's EXIT STATUS, not just its output.
#
# A13/A14 cover a broken jq at the FRONT of the hook (json_get, reading the tool_input).
# They cannot see the back of it: with no marker present the hook denies either way, so
# a marker_get that returns empty on every read is indistinguishable from a correct one.
# That is exactly why this third instance of the error-path class outlived the round that
# fixed json_get and strip_quoted — every existing assertion was blind to it.
#
# The failure it pins is UNDER-approval, not under-denial: a jq that is installed but
# fails at runtime made every marker read empty, so every gated branch re-gated forever
# and the python3 fallback sitting beside it was unreachable. Safe, and still a bug.
#
# Its own repo, and deliberately WITHOUT any of the four version-bearing manifests:
# forgeward-diff-hash.sh consults jq only to canonicalize those, so a manifest-free repo
# leaves marker_get as the single jq consumer on this path. Shadowing jq then changes
# exactly one thing, and a red result has exactly one cause.
_MG="$TMP/repo-markerget"
git init -q "$_MG"
( cd "$_MG"
  git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  echo base > a.txt; git add -A; git commit -qm base; git branch -M main
  git checkout -qb ungated; echo u > u.txt; git add -A; git commit -qm ungated
  git checkout -qb gated main; echo w > w.txt; git add -A; git commit -qm work
  write_marker main "privacy" ) >/dev/null 2>&1

_mg_push() { # _mg_push <path-prefix|empty> <branch> -> hook stdout
  git -C "$_MG" checkout -q "$2"
  if [ -n "$1" ]; then
    printf '{"cwd":"%s","tool_input":{"command":"git push"}}' "$_MG" | PATH="$1:$PATH" "$CHECK" pretooluse
  else
    printf '{"cwd":"%s","tool_input":{"command":"git push"}}' "$_MG" | "$CHECK" pretooluse
  fi
}

_mg_healthy="$(_mg_push ""         gated)"    # control: the marker is good to begin with
_mg_broken="$( _mg_push "$JQ_FAIL" gated)"    # the assertion: python3 must answer instead
# The OTHER control, and the one that makes this non-vacuous: an empty hook stdout also
# means "the hook exited before it looked at anything". Under the same broken jq, a
# branch with NO marker must still DENY — which proves the front half ran, the matcher
# fired, and the freshness check was genuinely reached on the line above.
_mg_control="$(_mg_push "$JQ_FAIL" ungated)"

if [ -z "$_mg_healthy" ] && [ -z "$_mg_broken" ] && denies "$_mg_control"; then
  ok "A18: jq present but exiting 1 -> a valid marker is still READ (python3 answers; gated branch stays allowed, ungated still denied)"
else
  nok "A18: marker_get discards jq's exit status (a broken jq makes every marker read empty)" \
      "healthy=${_mg_healthy:-allow} broken=${_mg_broken:-allow} control=$(denies "$_mg_control" && echo deny || echo "${_mg_control:-allow}")"
fi

# A19: the two marker_get implementations must stay byte-identical.
#
# gate-check.sh and pre-push.sh each carry their own copy — they are separate entry
# points with no shared library, which is deliberate (a sourced helper is one more file
# a hook can fail to find). The cost is drift, and drift is what actually happened:
# the 0.7.3 fix that gave marker_get sys.stdout.buffer.write instead of print() landed
# in gate-check.sh only, while DECISIONS.md recorded it as done. For two years' worth of
# reading, the repo's own record described the intent rather than the state.
#
# Comparing the FUNCTION BODIES (the header line is excluded, so each file keeps its own
# argument comment) makes the duplication self-enforcing: the next person to fix one copy
# gets a red suite until they fix the other. Guarding on non-empty means a broken
# extraction fails loudly instead of comparing "" with "".
_mg_body() { awk '/^marker_get\(\)/{f=1;next} f{print} f&&/^\}$/{exit}' "$1"; }
_mg_a="$(_mg_body "$PLUGIN/scripts/forgeward-gate-check.sh")"
_mg_b="$(_mg_body "$PLUGIN/scripts/forgeward-pre-push.sh")"
if [ -n "$_mg_a" ] && [ "$_mg_a" = "$_mg_b" ]; then
  ok "A19: marker_get is byte-identical in gate-check.sh and pre-push.sh (the twins cannot drift silently)"
else
  nok "A19: marker_get has drifted between gate-check.sh and pre-push.sh" \
      "$([ -z "$_mg_a" ] && echo 'extraction returned nothing — the function shape changed' || diff <(printf '%s\n' "$_mg_a") <(printf '%s\n' "$_mg_b") | tr '\n' ' ')"
fi

# A20/A21: input that cannot be PARSED must not read as "there is no command".
#
# A13/A14 pin json_get's JQ arm: a jq that runs but fails now falls through instead of
# returning a bogus empty answer. That fix was NEUTRALIZED one branch down. The python3
# arm wrapped the json.load and the field traversal in a single `except Exception: pass`,
# so unparseable input came back empty with status 0 — exactly the observation an absent
# field produces. `cmd` was empty, the pre-filter saw no verb, and the hook exited 0.
#
# So the measured behaviour was: a truncated payload carrying a real publish verb was
# ALLOWED — with jq present (jq fails, falls through, python3 swallows) AND with jq
# absent (python3 swallows directly). Two arms, one hole, and the arm that was fixed
# could not close it alone. That is why this is asserted on BOTH paths below rather than
# only on the one where the defect was first noticed.
#
# A21 is the half that keeps the fix from being worse than the bug. This hook fires on
# EVERY Bash tool call, so denying on any unreadable payload would wedge the entire
# session the moment jq or python3 broke. The raw-text check narrows it to payloads whose
# bytes could plausibly be a publish; everything else is allowed through untouched.
# A jq-less PATH: the REAL PATH with each jq-bearing directory swapped for a mirror of
# itself minus jq. Order is preserved, so the only difference from a normal environment
# is the one under test.
#
# Not a hand-written list of the tools the hook uses, which is how the first draft went
# wrong: it omitted `dirname`, the script died on its second line, emitted nothing, and
# "no output" is indistinguishable from ALLOW — a green assertion proving nothing. Not a
# mirror of the WHOLE path either: that was 14882 symlinks and 80 seconds here, and worse
# on a fatter box. Only the directories that actually carry jq are copied (111 entries).
_NOJQ20="$TMP/nojq-a20"; mkdir -p "$_NOJQ20"
_nojq_path=""
for _d in $(printf '%s' "$PATH" | tr ':' '\n'); do
  [ -d "$_d" ] || continue
  if [ -x "$_d/jq" ]; then
    for _f in "$_d"/*; do
      _n="${_f##*/}"
      [ "$_n" = "jq" ] && continue
      [ -x "$_f" ] && [ ! -e "$_NOJQ20/$_n" ] && ln -s "$_f" "$_NOJQ20/$_n" 2>/dev/null
    done
    _rep="$_NOJQ20"
  else
    _rep="$_d"
  fi
  case ":$_nojq_path:" in *":$_rep:"*) ;; *) _nojq_path="${_nojq_path:+$_nojq_path:}$_rep" ;; esac
done
_hook_path() { printf '%s' "$2" | PATH="$1" "$CHECK" pretooluse; }   # $1 = the FULL PATH

_a20_pub="$(printf '{"cwd":"%s","tool_input":{"command":"git push"}}' "$_MG")";  _a20_pub="${_a20_pub%\}\}}"
_a20_plain="$(printf '{"cwd":"%s","tool_input":{"command":"ls -la"}}' "$_MG")";  _a20_plain="${_a20_plain%\}\}}"

if command -v python3 >/dev/null 2>&1; then
  # Positive controls first, and they carry the weight: DENY is also what a hook that
  # dies before doing anything produces once this guard exists, and ALLOW is what one
  # that dies at line 1 produced before it. Both shim PATHs must therefore be shown to
  # run the whole script — valid JSON, ungated branch, correct verdict — or A20/A21
  # below are measuring the shim rather than the fix.
  git -C "$_MG" checkout -q ungated
  _a20_valid="$(printf '{"cwd":"%s","tool_input":{"command":"git push"}}' "$_MG")"
  _a20_setup=""
  PATH="$_nojq_path" command -v jq >/dev/null 2>&1 && _a20_setup="$_a20_setup [jq still reachable on the jq-less PATH]"
  denies "$(_hook_path "$JQ_FAIL:$PATH" "$_a20_valid")" || _a20_setup="$_a20_setup [broken-jq shim: hook did not run end to end]"
  denies "$(_hook_path "$_nojq_path"    "$_a20_valid")" || _a20_setup="$_a20_setup [no-jq shim: hook did not run end to end]"
  [ -n "$_a20_setup" ] && nok "A20 setup: a shim PATH is not exercising the hook — the arms below prove nothing" "$_a20_setup"

  _a20_bad=""
  # …with jq installed but failing (json_get falls through to python3)
  denies "$(_hook_path "$JQ_FAIL:$PATH" "$_a20_pub")"  || _a20_bad="$_a20_bad [broken-jq: allowed an unparseable publish]"
  # …and with no jq at all (python3 is the only arm)
  denies "$(_hook_path "$_nojq_path"    "$_a20_pub")"  || _a20_bad="$_a20_bad [no-jq: allowed an unparseable publish]"
  [ -z "$_a20_bad" ] \
    && ok "A20: UNPARSEABLE hook input carrying a publish verb -> DENIED on both arms (a payload that cannot be read is not an absent field)" \
    || nok "A20: unparseable hook input fails OPEN (json_get conflates 'not JSON' with 'field absent')" "$_a20_bad"

  # A22: the SAME unreadable input on the /ship expansion path, where the stakes differ.
  # There the empty `cwd` means no cd happened, so is_fresh() would answer for whatever
  # directory the hook process inherited — a fresh marker in an unrelated repo would let
  # the ship through. Blocked unconditionally, with no raw-text narrowing, because this
  # path fires only on a typed /ship: a false block costs one retry, not a wedged session.
  # The gated-branch control proves the block comes from the unreadable flag and not from
  # the expansion path simply refusing everything.
  # The hook process is deliberately run FROM the gated repo. That is what makes this
  # non-vacuous, and it was not obvious: the first draft ran from the harness's own cwd,
  # which at this point has no marker, so deleting the guard entirely still produced
  # exit 2 and the assertion stayed green. The mutation test caught it. Run from a repo
  # whose current branch IS gated and the two verdicts separate — without the guard the
  # inherited marker satisfies is_fresh() and /ship proceeds for a repo the payload never
  # named; with it, the halt fires before is_fresh() is ever consulted.
  git -C "$_MG" checkout -q gated
  _exp_from() { # _exp_from <cwd> <PATH> <payload> -> exit code
    ( cd "$1" && printf '%s' "$3" | PATH="$2" "$CHECK" expansion >/dev/null 2>&1 ); echo $?
  }
  _a22_valid="$(printf '{"cwd":"%s"}' "$_MG")"
  _a22_bad_json="${_a22_valid%\}}"
  _a22_bad=""
  [ "$(_exp_from "$_MG" "$JQ_FAIL:$PATH" "$_a22_valid")"    = 0 ] || _a22_bad="$_a22_bad [control: a GATED branch was blocked anyway]"
  [ "$(_exp_from "$_MG" "$JQ_FAIL:$PATH" "$_a22_bad_json")" = 2 ] || _a22_bad="$_a22_bad [broken-jq: unreadable input did NOT halt /ship]"
  [ "$(_exp_from "$_MG" "$_nojq_path"    "$_a22_bad_json")" = 2 ] || _a22_bad="$_a22_bad [no-jq: unreadable input did NOT halt /ship]"
  [ -z "$_a22_bad" ] \
    && ok "A22: UNPARSEABLE input on the /ship expansion path -> HALTED (the repo it applies to is unknown), while a gated branch still ships" \
    || nok "A22: unreadable input lets /ship proceed against whatever repo the hook inherited" "$_a22_bad"

  _a21_bad=""
  [ -z "$(_hook_path "$JQ_FAIL:$PATH" "$_a20_plain")" ] || _a21_bad="$_a21_bad [broken-jq: denied ordinary Bash]"
  [ -z "$(_hook_path "$_nojq_path"    "$_a20_plain")" ] || _a21_bad="$_a21_bad [no-jq: denied ordinary Bash]"
  [ -z "$_a21_bad" ] \
    && ok "A21: UNPARSEABLE hook input with no publish verb -> still ALLOWED (a broken JSON tool cannot wedge every Bash call)" \
    || nok "A21: the unparseable-input guard OVER-denies and would wedge ordinary work" "$_a21_bad"
else
  ok "A20/A21: unparseable-input arms SKIPPED (needs python3)"
fi

# S5: PASS marker written -> publish allowed
write_marker main "privacy" >/dev/null
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
( cd "$WT"; printf 'const w = 1;\n' > wt.js; git add -A; git commit -qm "feat: worktree"; write_marker main "privacy" ) >/dev/null

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
( cd "$WTS"; echo x > s.js; git add -A; git commit -qm "feat: spaced"; write_marker main "privacy" ) >/dev/null
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
# The target is a TRACKED FILE, not '.', on purpose: since P8k the wrapper refuses a
# directory target for gitleaks outright, and with '.' this assertion would pass on the
# target guard without ever exercising the dash-led-flag guard it exists to test.
if command -v gitleaks >/dev/null 2>&1; then
  DR="$TMP/dashrepo"; mkrepo "$DR"
  ( cd "$DR"; echo x > a.txt; git add -A; git commit -qm base ) >/dev/null 2>&1
  ( cd "$DR" && "$SCAN" gitleaks dir a.txt --report-path -evil.json --no-banner ) >/dev/null 2>&1
  rc=$?
  { [ "$rc" = 2 ] && [ ! -e "$DR/-evil.json" ]; } \
    && ok "forgeward-scan: real gitleaks with a dash-led --report-path is refused and the repo stays clean" \
    || nok "forgeward-scan real dash-led write" "rc=$rc, -evil.json present: $([ -e "$DR/-evil.json" ] && echo yes || echo no)"
  # …and the SHORT spelling of the same flag. gitleaks' own help reads
  # `-r, --report-path string  report file`, but only the long form was enumerated, so
  # `-r evil.json` reached the write the long form exists to refuse. Both separated and
  # cuddled. Bare '-r -' is stdout and must stay allowed.
  ( cd "$DR" && "$SCAN" gitleaks dir a.txt -r evil.json --no-banner ) >/dev/null 2>&1
  rc1=$?
  ( cd "$DR" && "$SCAN" gitleaks dir a.txt -revil2.json --no-banner ) >/dev/null 2>&1
  rc2=$?
  # `-r -` needs `-f` alongside it: gitleaks exits 1 with "Unknown report format" when a
  # report path is given without one. That is gitleaks' rule, not the wrapper's.
  ( cd "$DR" && "$SCAN" gitleaks dir a.txt -f json -r - --no-banner --redact ) >/dev/null 2>&1
  rc3=$?
  { [ "$rc1" = 2 ] && [ "$rc2" = 2 ] && [ "$rc3" = 0 ] \
    && [ ! -e "$DR/evil.json" ] && [ ! -e "$DR/evil2.json" ]; } \
    && ok "forgeward-scan: gitleaks SHORT '-r <file>' (separated and cuddled) refused, '-r -' still allowed" \
    || nok "forgeward-scan gitleaks short -r" "rc=$rc1/$rc2/$rc3, files: $(ls "$DR" | tr '\n' ' ')"
else
  ok "forgeward-scan real dash-led write: SKIPPED (gitleaks not installed)"
  ok "forgeward-scan gitleaks short -r: SKIPPED (gitleaks not installed)"
fi

# P8j: the gitleaks TARGET guard, argv-level. gitleaks takes exactly ONE positional path
# and, given any other number, does not error — cmd/directory.go keeps `source = "."`, so
# the scan silently becomes the whole current directory. The documented reviewer
# invocation passed the entire changed-path list, which is how a two-file scan became a
# working-tree scan that read a gitignored .env.
#
# Unit-level first (no gitleaks needed): the guard runs before the tool does, so a stub
# `tool` proves the argv rules on their own. Uses the real gitleaks name via a symlink so
# `basename` dispatch is exercised for real rather than asserted about.
GLDIR="$TMP/glstub"; mkdir -p "$GLDIR"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GLDIR/gitleaks"; chmod +x "$GLDIR/gitleaks"
GT="$TMP/gtrepo"; mkrepo "$GT"
( cd "$GT"; echo x > a.txt; echo y > b.txt; mkdir -p sub; echo z > sub/c.txt
  printf 'a.local\n' > .gitignore; echo untracked > a.local
  git add -A; git commit -qm base ) >/dev/null 2>&1
gl() { ( cd "$GT" && "$SCAN" "$GLDIR/gitleaks" "$@" >/dev/null 2>&1; echo $? ); }
tgt_bad=""
# refused: two paths (the reported defect), zero paths, a directory, '.', an untracked file
for _c in 'dir|a.txt|b.txt' 'dir|--no-banner' 'dir|sub' 'dir|.' 'dir|a.local' 'file|a.txt|b.txt' 'directory|.'; do
  IFS='|' read -r -a _a <<< "$_c"
  [ "$(gl "${_a[@]}")" = 2 ] || tgt_bad="$tgt_bad [refuse:${_c//|/ }]"
done
# allowed: exactly one tracked regular file, in any argv position, and `git` mode — whose
# target is a commit range, so untracked files are structurally out of scope. A bare
# `gitleaks git` with no --log-opts scans full history and stays allowed on purpose:
# auditing a repo's history for leaked secrets is a legitimate thing to want.
for _c in 'dir|a.txt' 'dir|a.txt|--no-banner' 'dir|--redact|a.txt' 'dir|-f|json|-r|-|a.txt' 'dir|sub/c.txt' 'git|--log-opts=HEAD~1...HEAD' 'git|.' 'git' 'stdin' 'version' '--version'; do
  IFS='|' read -r -a _a <<< "$_c"
  [ "$(gl "${_a[@]}")" = 0 ] || tgt_bad="$tgt_bad [allow:${_c//|/ }]"
done
# An UNRECOGNIZED subcommand is refused, not waved through. This is the one place the
# argv parse can diverge from cobra's in the fail-OPEN direction: an unlisted
# value-taking flag placed BEFORE the subcommand makes its value look like the
# subcommand, and `gitleaks --unlisted V dir .` would otherwise reach a directory scan
# on a "pos[0] isn't dir, nothing to guard" reading. Also covers the pre-8.19
# `detect --no-git`, which is the same filesystem walk under an older name.
# The `detect` legs are the exact argv a security review reproduced against the real
# 8.30.1 binary through the pre-fix wrapper: `detect --no-git` with no target defaults
# to the cwd and scanned byte-identically to the refused `dir .`, and with `--source
# .env` it read the untracked file outright. `--source` is deliberately NOT in the
# value-taking table — it does not need to be, because `detect` never reaches the
# target checks. `protect` is its staged-changes sibling and dies at the same gate.
for _c in 'detect|--no-git|.' 'detect|--no-git|--no-banner' \
          'detect|--no-git|--source|.env|--no-banner' 'protect|--no-banner' \
          '--baseline-path|x|frobnicate|.' 'frobnicate'; do
  IFS='|' read -r -a _a <<< "$_c"
  [ "$(gl "${_a[@]}")" = 2 ] || tgt_bad="$tgt_bad [refuse-unknown-subcmd:${_c//|/ }]"
done
[ -z "$tgt_bad" ] \
  && ok "forgeward-scan: gitleaks dir target must be ONE tracked regular file; directory / multi-path / untracked refused, 'git' mode untouched" \
  || nok "forgeward-scan gitleaks target guard" "wrong verdict on:$tgt_bad"

# audit_fence <marker> [line]: the first ```bash fence after the line of skills/audit/SKILL.md
# that starts with <marker>, with `<forgeward-root>` substituted and nothing else changed, so
# the recipe a reworded skill prints is what runs here, never a copy. With `line`, the
# fence's opening line number instead, which is what P8r's census compares. Prints nothing
# when the marker or its fence is gone, so a caller must fail on an empty result, not run it.
AUDIT_SKILL="$PLUGIN/skills/audit/SKILL.md"
audit_fence() {
  local f
  f="$(awk -v m="$1" -v at="${2:-}" 'index($0,m)==1{f=1;next} f&&/^```bash$/{if(at!=""){print NR;exit} on=1;next} on&&/^```$/{exit} on{print}' "$AUDIT_SKILL")"
  [ -z "$f" ] || printf '%s\n' "${f//<forgeward-root>/$PLUGIN}"
}

# P8k: the exposure itself, end-to-end against the REAL binary. A repo with a gitignored
# .env holding a fake AWS key and two clean tracked files as the changed paths — exactly
# the shape observed on a real gate run. Four things must hold at once:
#   0. the defect still REPRODUCES without the wrapper — otherwise the rest is vacuous;
#   1. the documented two-path invocation is refused and prints no secret;
#   2. the endorsed shapes (one file at a time, and `git --log-opts`) never see the
#      untracked .env;
#   3. a COMMITTED secret still fires. That is what stops the fix from degenerating into
#      a blanket .env exclusion: the line is tracked vs untracked, not the filename.
#
# NOTE ON OUTPUT MODE, because it decides whether this test can fail at all. In gitleaks
# 8.30.1 `--no-banner` alone prints COUNTS ONLY — no file, no value. The value reaches
# stdout under `-v` or a JSON report, which is precisely what a reviewer must ask for to
# report `file:line` at all. So the legs below use `-f json -r -`; asserting against the
# count-only shape would pass with the guard ripped out and prove nothing.
if command -v gitleaks >/dev/null 2>&1; then
  ER="$TMP/envrepo"; mkrepo "$ER"
  # Split literal: assembled at runtime so no complete credential exists in this file and
  # a gitleaks run over forgeward's own repo cannot flag its own regression fixture.
  FAKE_AWS="AKIA""QYLPMN5HGZTHHFPQ"
  ( cd "$ER"
    printf '.env\n'                      > .gitignore
    printf 'AWS_ACCESS_KEY_ID=%s\n' "$FAKE_AWS" > .env      # untracked, gitignored
    printf 'clean one\n'                 > app.php          # the changed paths:
    printf '# todos\n'                   > TODOS.md         # both clean, both tracked
    git add -A; git commit -qm base ) >/dev/null 2>&1
  env_bad=""
  # 0. Control: BYPASS the wrapper and run the documented invocation raw. It must leak,
  #    or this fixture is not reproducing the defect and every assertion below is
  #    vacuous. If this ever fails, re-derive the defect against the installed gitleaks
  #    BEFORE weakening the guard — do not just delete the leg.
  out="$( cd "$ER" && gitleaks dir app.php TODOS.md --no-banner -f json -r - 2>&1 )"
  case "$out" in
    *"$FAKE_AWS"*) ;;
    *) env_bad="$env_bad [control: raw two-path scan did NOT leak — fixture no longer reproduces the defect]" ;;
  esac
  # 1. the documented shape THROUGH the wrapper: refused, and nothing from .env anywhere.
  out="$( cd "$ER" && "$SCAN" gitleaks dir app.php TODOS.md --no-banner -f json -r - 2>&1 )"; rc=$?
  [ "$rc" = 2 ] || env_bad="$env_bad [two-path not refused rc=$rc]"
  case "$out" in *"$FAKE_AWS"*) env_bad="$env_bad [SECRET LEAKED by two-path scan]" ;; esac
  # 2a. one tracked file at a time — the endorsed dir shape. Never reaches .env.
  for _f in app.php TODOS.md; do
    out="$( cd "$ER" && "$SCAN" gitleaks dir "$_f" --no-banner --redact -f json -r - 2>&1 )"
    case "$out" in *"$FAKE_AWS"*) env_bad="$env_bad [SECRET LEAKED by per-file scan of $_f]" ;; esac
  done
  # 2b. commit-range mode — the primary shape. Untracked files are structurally excluded.
  out="$( cd "$ER" && "$SCAN" gitleaks git --log-opts="HEAD" --no-banner --redact -f json -r - 2>&1 )"
  case "$out" in *"$FAKE_AWS"*) env_bad="$env_bad [SECRET LEAKED by git-range scan]" ;; esac
  # 3. the other half of the contract: a COMMITTED secret is a real finding and must
  #    still fire. Tracked vs untracked is the line, not the filename — so commit the
  #    very same .env and require a hit.
  ( cd "$ER"
    : > .gitignore
    git add -A; git commit -qm "oops: commit the .env" ) >/dev/null 2>&1
  out="$( cd "$ER" && "$SCAN" gitleaks git --log-opts="HEAD~1..HEAD" --no-banner --redact -f json -r - 2>&1 )"
  case "$out" in
    *'"RuleID": "aws-access-token"'*) ;;
    *) env_bad="$env_bad [committed .env NOT detected — fix over-reaches]" ;;
  esac
  case "$out" in *"$FAKE_AWS"*) env_bad="$env_bad [--redact did not redact]" ;; esac
  [ -z "$env_bad" ] \
    && ok "forgeward-scan: an untracked gitignored .env is never read by any endorsed gitleaks shape, and a COMMITTED .env still fires (redacted)" \
    || nok "forgeward-scan gitleaks untracked-.env exposure" "$env_bad"

  # P8k (Message leg): `--redact` masks a record's Secret and Match and NOT its commit
  # Message, so a commit whose message quotes the key prints the key in full in every
  # record from that commit. /forgeward:audit's history recipe filters each record down
  # to RuleID/File/StartLine/Commit/Entropy for that reason, and this runs that recipe
  # as the skill prints it: the fence is extracted from SKILL.md and only
  # `<forgeward-root>` is substituted. The control runs the raw `--redact` shape first;
  # if it stops carrying the key, the filtered assertion proves nothing.
  if command -v jq >/dev/null 2>&1; then
    MR="$TMP/msgrepo"; mkrepo "$MR"
    ( cd "$MR"
      printf 'clean\n' > app.php; git add -A; git commit -qm base
      printf 'AWS_ACCESS_KEY_ID=%s\n' "$FAKE_AWS" > .env
      git add -A; git commit -qm "rotate $FAKE_AWS" ) >/dev/null 2>&1
    msg_bad=""
    out="$( cd "$MR" && "$SCAN" gitleaks git --log-opts="HEAD~1..HEAD" --no-banner --redact -f json -r - 2>/dev/null )"
    case "$out" in
      *"$FAKE_AWS"*) ;;
      *) msg_bad="$msg_bad [control: raw --redact JSON did not carry the key in Message, so this fixture no longer reproduces the leak]" ;;
    esac
    _p8k_hist="$(audit_fence '**Run the gitleaks history scan on every pass')"
    printf '%s\n' "$_p8k_hist" > "$TMP/p8k-hist.sh"
    case "$_p8k_hist" in
      *"gitleaks git"*"jq -c"*) ;;
      *) msg_bad="$msg_bad [could not extract the history recipe from SKILL.md]" ;;
    esac
    out="$( cd "$MR" && bash "$TMP/p8k-hist.sh" 2>&1 )"
    case "$out" in *"$FAKE_AWS"*) msg_bad="$msg_bad [the audit's history recipe printed the key]" ;; esac
    case "$out" in
      *'"RuleID":"aws-access-token"'*) ;;
      *) msg_bad="$msg_bad [the recipe reported no aws-access-token record, so there was nothing to filter]" ;;
    esac
    case "$out" in *"gitleaks rc=1"*) ;; *) msg_bad="$msg_bad [the recipe did not print its gitleaks rc line]" ;; esac
    [ -z "$msg_bad" ] \
      && ok "audit: the history recipe keeps the finding and drops a key quoted in the commit message, which raw --redact JSON prints" \
      || nok "audit P8k: the gitleaks history recipe leaks the commit Message" "$msg_bad"
  else
    ok "audit gitleaks history recipe Message filter: SKIPPED (jq not installed)"
  fi
else
  ok "forgeward-scan gitleaks untracked-.env exposure: SKIPPED (gitleaks not installed)"
  ok "audit gitleaks history recipe Message filter: SKIPPED (gitleaks not installed)"
fi

# P8l: layer 1 refuses output-file FLAGS, but it matches whole tokens and therefore cannot
# see inside a flag's VALUE. `--log-opts` is forwarded verbatim to `git log`, so
# `--log-opts="--output=x"` really does write `x` — and `--log-opts` is the flag the
# reviewers are now told to use, which is what puts this in scope here.
#
# This is pinned as ACCEPTED-AND-CONTAINED, not as a refusal: the assertion is that
# layer 3 notices (exit 3, path named), i.e. that the gap stays LOUD. Asserting rc=2
# would be asserting a fix that deliberately was not made — the value-allowlist that
# would close it properly is a TODO, not this change. If someone later closes it, this
# leg should be rewritten to expect refusal, not deleted.
if command -v gitleaks >/dev/null 2>&1; then
  LR="$TMP/logopts"; mkrepo "$LR"
  ( cd "$LR"; printf 'x\n' > a.txt; git add -A; git commit -qm base ) >/dev/null 2>&1
  lo_bad=""
  out="$( cd "$LR" && "$SCAN" gitleaks git --log-opts="--output=pwned.txt" --no-banner 2>&1 )"; rc=$?
  [ -f "$LR/pwned.txt" ] || lo_bad="$lo_bad [precondition: git log did not write the file, so this no longer tests anything]"
  [ "$rc" = 3 ] || lo_bad="$lo_bad [layer 3 did not flag the write: rc=$rc, expected 3]"
  case "$out" in *pwned.txt*) ;; *) lo_bad="$lo_bad [the new path was not named in the report]" ;; esac
  [ -z "$lo_bad" ] \
    && ok "forgeward-scan: a write smuggled through --log-opts is not refused by layer 1 but IS caught and named by layer 3 (exit 3)" \
    || nok "forgeward-scan --log-opts write containment" "$lo_bad"
else
  ok "forgeward-scan --log-opts write containment: SKIPPED (gitleaks not installed)"
fi

# P8m: the per-tool `-o` exemption dispatches on `basename "$tool"`, and that is a
# DOCUMENTED limit rather than a defect awaiting a fix — this script runs `"$tool" "$@"`,
# so anyone able to place the executable already holds code execution here, and probing
# `--version` would not help because a spoofed binary can print anything.
#
# "Cannot be forged" is not something a test can show, so what is pinned instead is the
# behaviour under three NAMED forgeries — a rename, a symlink, and an innocent basename
# collision — plus the containment the header claims: layer 3 still reports the result.
#
# Two of the three need REAL scanners, and that is the whole reason they are worth
# running: with a stub on both sides, "the wrapper dispatched on the name" and "the
# wrapper identified the binary" produce identical output, so a stub cannot tell them
# apart. If someone later closes this gap, rewrite these legs to expect refusal rather
# than deleting them.
FORGEDIR="$TMP/forge"; mkdir -p "$FORGEDIR"
FGR="$TMP/forgerepo"; mkrepo "$FGR"
mkdir -p "$FGR/tools"
# an ordinary project script that happens to be named `grype` and is not grype:
printf '#!/usr/bin/env bash\nwhile [ $# -gt 0 ]; do [ "$1" = "-o" ] && : > "$2"; shift; done\nexit 0\n' > "$FGR/tools/grype"
chmod +x "$FGR/tools/grype"
( cd "$FGR"; printf 'x\n' > a.txt; git add -A; git commit -qm base ) >/dev/null 2>&1

# (A) RENAME. The real syft binary reached under the name `trivy`. syft genuinely
# overloads `-o` — `syft -o json` prints to stdout and writes nothing — so a refusal here
# can only be coming from the name. Hard link where the filesystem allows it; the copy is
# the fallback, and either way it is byte-identical to the installed binary.
if command -v syft >/dev/null 2>&1; then
  ln "$(command -v syft)" "$FORGEDIR/trivy" 2>/dev/null || cp "$(command -v syft)" "$FORGEDIR/trivy"
  ( cd "$FGR" && "$SCAN" "$FORGEDIR/trivy" -o json ) >/dev/null 2>&1; rc=$?
  ren_bad=""
  # The fixture check is load-bearing HERE in a way it is not in most tests, so it is not
  # ceremony: layer 1 rejects on the basename inside its argument loop, BEFORE the script
  # ever runs `command -v "$tool"`. A path that does not exist therefore also exits 2 — so
  # if the hardlink and the copy both failed, the exit code below would still be 2 and
  # this leg would print `ok` next to a message asserting "the REAL syft binary", which
  # would be false. Verified: `$SCAN /nonexistent/trivy -o json` exits 2.
  [ -x "$FORGEDIR/trivy" ] || ren_bad="$ren_bad [precondition: the syft hardlink/copy was not created, so nothing was forged and the exit code below proves nothing]"
  [ "$rc" = 2 ] || ren_bad="$ren_bad [real syft named 'trivy' was not refused -o json: rc=$rc, expected 2]"
  [ -z "$ren_bad" ] \
    && ok "forgeward-scan: forgery 1/3 (rename) — the REAL syft binary under the name 'trivy' is refused '-o json'; the exemption follows the name, not the tool" \
    || nok "forgeward-scan basename forgery: rename" "$ren_bad"
else
  ok "forgeward-scan basename forgery 1/3 (rename): SKIPPED (syft not installed)"
fi

# (B) SYMLINK, in the permissive direction — the one that matters. A link named `grype`
# pointing at the real trivy inherits grype's exemption: the wrapper does not readlink
# the path. trivy's own global parser then rejects `-o` (`unknown shorthand flag`), which
# is trivy's verdict and not the wrapper's, so the assertion is that the WRAPPER stayed
# out of it — no refusal line, an exit that is not 2, and nothing new in the repo.
if command -v trivy >/dev/null 2>&1; then
  ln -s "$(command -v trivy)" "$FORGEDIR/grype" 2>/dev/null
  fsym="$( cd "$FGR" && "$SCAN" "$FORGEDIR/grype" -o json 2>&1 >/dev/null )"; rc=$?
  sym_bad=""
  # Unlike leg A this one already fails safe without the check — a missing link makes the
  # wrapper print its own "not installed (skipped)" line, which trips the *forgeward-scan:*
  # case below. What it does not do is say WHY, so the check is here for the diagnostic.
  [ -L "$FORGEDIR/grype" ] || sym_bad="$sym_bad [precondition: the symlink was not created]"
  [ "$rc" != 2 ] || sym_bad="$sym_bad [wrapper refused it — if the exemption now resolves symlinks, rewrite this leg]"
  case "$fsym" in *forgeward-scan:*) sym_bad="$sym_bad [wrapper printed a verdict: $fsym]" ;; esac
  [ -e "$FGR/json" ] && sym_bad="$sym_bad [a file named 'json' was created]"
  [ -z "$sym_bad" ] \
    && ok "forgeward-scan: forgery 2/3 (symlink) — a link named 'grype' pointing at the REAL trivy inherits the exemption; the wrapper does not resolve the link" \
    || nok "forgeward-scan basename forgery: symlink" "$sym_bad"
else
  ok "forgeward-scan basename forgery 2/3 (symlink): SKIPPED (trivy not installed)"
fi

# (C) COLLISION, and the containment. No forger is needed for this one: a project that
# ships its own `./tools/grype` collides with the exempt name by accident, and the script
# below writes whatever `-o` names. Layer 1 lets `-o sarif` through — that IS the limit —
# and the assertion is that layer 3 catches the write, names the path, and turns the
# script's exit 0 into 3 so the caller cannot read contamination as success.
fcol="$( cd "$FGR" && "$SCAN" ./tools/grype -o sarif 2>&1 >/dev/null )"; rc=$?
col_bad=""
[ -e "$FGR/sarif" ] || col_bad="$col_bad [precondition: the collided script wrote nothing, so this no longer tests the limit]"
[ "$rc" = 3 ] || col_bad="$col_bad [layer 3 did not flag the write: rc=$rc, expected 3]"
case "$fcol" in *sarif*) ;; *) col_bad="$col_bad [the written path was not named in the report]" ;; esac
[ -z "$col_bad" ] \
  && ok "forgeward-scan: forgery 3/3 (basename collision) — a project's own './tools/grype' inherits the exemption at layer 1, and layer 3 reports the file it wrote (exit 3)" \
  || nok "forgeward-scan basename forgery: collision containment" "$col_bad"

# P8n: THE MISSING-TOOL CONTRACT that /forgeward:audit's Scanner evidence section quotes.
# A tool the wrapper cannot find exits 127 with one stderr line,
# `forgeward-scan: <tool> not installed (skipped)`. osv-scanner --offline with no database
# ALSO exits 127, so the audit tells the model that a 127 with this line is SKIPPED and any
# other 127 is a failed run. The line is the whole distinction: reword it and every
# skipped scanner reads as a failure, with nothing else going red. The expected text is
# DERIVED from the skill's own sentence, never copied here.
# The skill must quote the template exactly ONCE. `head -1` on several copies would test
# the first and let a second, reworded copy be the one the model reads; `grep -o | wc -l`
# counts occurrences, where `grep -c` would count lines.
_p8n_tool="forgeward-no-such-scanner-$$"
_p8n_tpl="$(grep -o 'forgeward-scan: <tool> not installed (skipped)' "$PLUGIN/skills/audit/SKILL.md" | head -1)"
_p8n_cnt="$(grep -o 'forgeward-scan: <tool> not installed (skipped)' "$PLUGIN/skills/audit/SKILL.md" | wc -l)"
_p8n_want="${_p8n_tpl/<tool>/$_p8n_tool}"
_p8n_err="$( cd "$FGR" && "$SCAN" "$_p8n_tool" --version 2>&1 >/dev/null )"; rc=$?
_p8n_bad=""
[ -n "$_p8n_tpl" ] || _p8n_bad="$_p8n_bad [the audit skill no longer quotes the message, so there is nothing to derive from]"
[ "$_p8n_cnt" -eq 1 ] || _p8n_bad="$_p8n_bad [the audit skill quotes the template $_p8n_cnt times, expected exactly 1]"
[ "$rc" = 127 ] || _p8n_bad="$_p8n_bad [rc=$rc, expected 127]"
[ "$_p8n_err" = "$_p8n_want" ] || _p8n_bad="$_p8n_bad [stderr='$_p8n_err', expected '$_p8n_want']"
[ -z "$_p8n_bad" ] \
  && ok "forgeward-scan: a tool that is not installed exits 127 with exactly the stderr line /forgeward:audit tells the model to look for" \
  || nok "forgeward-scan P8n: the missing-tool contract the audit quotes has drifted" "$_p8n_bad"

# P8o: /forgeward:audit's tracked-.env loop, run EXACTLY as the skill prints it: the fence
# is extracted from SKILL.md and only `<forgeward-root>` is substituted, so a reworded
# recipe is what runs here, never a copy. A stub gitleaks on PATH records each call's
# argv, cwd and stdin and prints `[]`, so this needs jq but no scanner.
#
# The fixture's file names are repo-supplied input: a command substitution, a backtick, a
# leading dash, and a newline followed by a forged label. The control leg proves they are
# hostile, by re-parsing them through eval and requiring the substitution to run. Without
# it, every "nothing ran" assertion below would pass on a fixture that cannot inject.
#
# What else must hold: every tracked `.env` reaches the scanner, a template is labelled as
# one, the bundled config and ignore file are passed, the scanner runs inside the git dir
# (so the reviewed repo's own `.gitleaksignore` in the work tree is not loaded), and a
# skip-worktree file is scanned as the INDEX holds it, not as the work tree shows it.
if command -v jq >/dev/null 2>&1; then
  _p8o_fence="$(audit_fence '**`.env` files tracked by git.**')"
  printf '%s\n' "$_p8o_fence" > "$TMP/p8o-loop.sh"
  # The MARK of every file the loop must scan, one scanner call each. The call count and the
  # records-line count below are derived from this list rather than typed beside it.
  _p8o_marks=(root dash sub dotdir subst tick nl template sw-index)
  EV="$TMP/envloop"; mkrepo "$EV"
  EVSTUB="$TMP/envloop-stub"; EVLOG="$TMP/envloop-log"; mkdir -p "$EVSTUB" "$EVLOG"
  printf '%s\n' '#!/usr/bin/env bash' \
    "d=\"\$(mktemp -d \"$EVLOG/call.XXXXXX\")\" || exit 99" \
    'printf "%s\n" "$@" > "$d/argv"; pwd -P > "$d/cwd"; cat > "$d/stdin"; printf "[]\n"' \
    > "$EVSTUB/gitleaks"
  chmod +x "$EVSTUB/gitleaks"
  _p8o_nl=$'x\ntracked: forged.env'
  ( cd "$EV"
    mkdir -p sub deploy.example.com sw src
    printf 'MARK=root\n'     > .env
    printf 'MARK=dash\n'     > ./-d.env
    printf 'MARK=sub\n'      > sub/.env.local
    printf 'MARK=dotdir\n'   > deploy.example.com/.env.production
    printf 'MARK=subst\n'    > '$(touch PWNED).env'
    printf 'MARK=tick\n'     > '`touch PWNED2`.env'
    printf 'MARK=nl\n'       > "$_p8o_nl"
    printf 'MARK=template\n' > .env.example
    printf 'MARK=notenv\n'   > src/config.env.ts
    printf 'MARK=sw-index\n' > sw/.env.local
    git add -A; git commit -qm base
    printf 'MARK=sw-worktree\n' > sw/.env.local
    git update-index --skip-worktree -- sw/.env.local ) >/dev/null 2>&1
  _p8o_bad=""
  # Control: re-parse the names the way an unquoted or eval'd loop would. The substitution
  # must run, or the fixture is not hostile and the assertions below are vacuous.
  ( cd "$EV" && git ls-files -- '*.env' | while IFS= read -r p; do eval "printf '%s\n' $p" >/dev/null 2>&1; done )
  [ -e "$EV/PWNED" ] || _p8o_bad="$_p8o_bad [control: an eval re-parse did not run the fixture's substitution, so it no longer tests injection]"
  rm -f "$EV/PWNED" "$EV/PWNED2"
  _p8o_out="$( cd "$EV" && PATH="$EVSTUB:$PATH" bash "$TMP/p8o-loop.sh" 2>&1 )"
  _p8o_gd="$(cd "$(git -C "$EV" rev-parse --absolute-git-dir)" && pwd -P)"
  [ -z "$(find "$EV" -name 'PWNED*' 2>/dev/null)" ] || _p8o_bad="$_p8o_bad [a file name was executed: $(find "$EV" -name 'PWNED*')]"
  for _l in 'tracked: -d.env' 'tracked: sub/.env.local' 'tracked: deploy.example.com/.env.production' 'template: .env.example'; do
    printf '%s\n' "$_p8o_out" | grep -qxF -- "$_l" || _p8o_bad="$_p8o_bad [no '$_l' line]"
  done
  printf '%s\n' "$_p8o_out" | grep -qxF 'tracked: forged.env' && _p8o_bad="$_p8o_bad [a newline in a file name forged a label line]"
  _p8o_calls=0; _p8o_in=""
  for _d in "$EVLOG"/call.*; do
    [ -d "$_d" ] || continue
    _p8o_calls=$((_p8o_calls+1))
    _p8o_in="$_p8o_in$(cat "$_d/stdin")"$'\n'
    [ "$(head -1 "$_d/argv")" = stdin ] || _p8o_bad="$_p8o_bad [a call was not 'gitleaks stdin': $(head -1 "$_d/argv")]"
    [ "$(grep -A1 -xF -- --config "$_d/argv" | tail -1)" = "$PLUGIN/rules/gitleaks-pre-push.toml" ] \
      || _p8o_bad="$_p8o_bad [a call did not pass the bundled --config]"
    [ "$(grep -A1 -xF -- --gitleaks-ignore-path "$_d/argv" | tail -1)" = "$PLUGIN/rules/gitleaks-pre-push.ignore" ] \
      || _p8o_bad="$_p8o_bad [a call did not pass the bundled --gitleaks-ignore-path]"
    [ "$(cat "$_d/cwd")" = "$_p8o_gd" ] || _p8o_bad="$_p8o_bad [a call ran in $(cat "$_d/cwd"), not the git dir]"
  done
  [ "$_p8o_calls" -eq "${#_p8o_marks[@]}" ] || _p8o_bad="$_p8o_bad [$_p8o_calls scanner calls, expected ${#_p8o_marks[@]}]"
  for _m in "${_p8o_marks[@]}"; do
    printf '%s' "$_p8o_in" | grep -qxF "MARK=$_m" || _p8o_bad="$_p8o_bad [$_m was not scanned]"
  done
  printf '%s' "$_p8o_in" | grep -qxF 'MARK=sw-worktree' && _p8o_bad="$_p8o_bad [the work-tree copy of a skip-worktree file was scanned instead of the index blob]"
  printf '%s' "$_p8o_in" | grep -qxF 'MARK=notenv' && _p8o_bad="$_p8o_bad [a non-.env file was scanned]"
  [ "$(printf '%s\n' "$_p8o_out" | grep -cxF '{"records":0}')" -eq "${#_p8o_marks[@]}" ] || _p8o_bad="$_p8o_bad [expected ${#_p8o_marks[@]} records lines]"
  [ -z "$_p8o_bad" ] \
    && ok "audit: the tracked-.env loop scans every tracked .env from the index inside the git dir with the bundled config, labels templates, and executes no file name" \
    || nok "audit P8o: the tracked-.env recipe" "$_p8o_bad"
else
  ok "audit tracked-.env recipe: SKIPPED (jq not installed)"
fi

# P8p: the audit's other secret LOCATORS, each run exactly as the skill prints it. Their job
# is to say WHERE a credential is without putting it in the transcript: the history searches
# print a hash and a file name, never a subject or a patch, and the git-grep recipes cut each
# hit to `file:line`. So each leg asserts the exact located output, which pins the matches
# and the exclusions together (placeholders, localhost/127.0.0.1/example.com, `${{`,
# `secrets.`, `var.`, `git@`), and that no planted value reaches either stream.
#
# Each leg has a control that runs the recipe without its redaction and requires a value to
# appear: the history searches with the pre-0.30.0 `--oneline` (every fixture commit subject
# quotes its credential), and the git-grep recipes without `| cut -d: -f1,2`. Without it,
# the no-value assertions pass on a fixture whose values were never reachable. The values
# are split literals, so no complete credential exists in this file for the push-time scan.
_p8p_aws="AKIA""ZXCVBNMQWERTYUIO"; _p8p_sk="sk-""live0123456789abcdefABCDEF"
_p8p_ghp="ghp_""aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"; _p8p_xox="xoxb-""1234567890-abcdefghijklmnop"
_p8p_pem="-----BEGIN RSA PRIV""ATE KEY-----"; _p8p_pw="Hunter2""Zq9pw"
_p8p_vals=("$_p8p_aws" "$_p8p_sk" "$_p8p_ghp" "$_p8p_xox" "$_p8p_pem" "$_p8p_pw")

# History: one commit per search, in the fence's order, each adding one file whose content
# and commit subject carry one value. The expected output is each commit's hash and file,
# read after the last commit so the abbreviation is the one the recipe will see.
P8H="$TMP/p8p-hist"; mkrepo "$P8H"
( cd "$P8H" && printf 'base\n' > README && git add -A && git commit -qm base ) >/dev/null 2>&1
_p8p_files=()
_p8p_commit() {  # <file> <value> <content>
  printf '%s\n' "$3" > "$P8H/$1"
  ( cd "$P8H" && git add -A && git commit -qm "add $2" ) >/dev/null 2>&1
  _p8p_files+=("$1")
}
_p8p_commit .env        "$_p8p_aws" "AWS_ACCESS_KEY_ID=$_p8p_aws"
_p8p_commit config.json "$_p8p_sk"  "{\"k\":\"$_p8p_sk\"}"
_p8p_commit ci.sh       "$_p8p_ghp" "export T=$_p8p_ghp"
_p8p_commit slack.txt   "$_p8p_xox" "SLACK=$_p8p_xox"
_p8p_commit id_rsa      "$_p8p_pem" "$_p8p_pem"$'\nMIIB'
_p8p_commit app.yml     "$_p8p_pw"  $'db:\n  password: '"$_p8p_pw"
_p8p_want=""
for _f in "${_p8p_files[@]}"; do
  _p8p_want="$_p8p_want${_p8p_want:+$'\n'}$(git -C "$P8H" log --format=%h --diff-filter=A -- "$_f")"$'\n'"$_f"
done
_p8p_bad=""
audit_fence '**Never print raw `git log -p --all`' > "$TMP/p8p-hist.sh"
grep -q -- '--format=%h --name-only' "$TMP/p8p-hist.sh" || _p8p_bad="$_p8p_bad [could not extract the history searches from SKILL.md]"
_p8p_out="$( cd "$P8H" && bash "$TMP/p8p-hist.sh" 2>&1 )"
[ "$(printf '%s\n' "$_p8p_out" | grep -v '^$')" = "$_p8p_want" ] \
  || _p8p_bad="$_p8p_bad [located '$(printf '%s' "$_p8p_out" | tr '\n' ' ')', expected '$(printf '%s' "$_p8p_want" | tr '\n' ' ')']"
for _v in "${_p8p_vals[@]}"; do
  case "$_p8p_out" in *"$_v"*) _p8p_bad="$_p8p_bad [printed a planted value]" ;; esac
done
sed 's/--format=%h/--oneline/' "$TMP/p8p-hist.sh" > "$TMP/p8p-hist-oneline.sh"
_p8p_ctl="$( cd "$P8H" && bash "$TMP/p8p-hist-oneline.sh" 2>&1 )"; _p8p_miss=0
for _v in "${_p8p_vals[@]}"; do
  case "$_p8p_ctl" in *"$_v"*) ;; *) _p8p_miss=$((_p8p_miss+1)) ;; esac
done
[ "$_p8p_miss" -eq 0 ] || _p8p_bad="$_p8p_bad [control: $_p8p_miss of ${#_p8p_vals[@]} planted subjects were missing from the --oneline output, so the fixture no longer proves --format=%h is what hides them]"
[ -z "$_p8p_bad" ] \
  && ok "audit: the history searches locate every planted credential by hash and file name and print none of them" \
  || nok "audit P8p: the history-search recipe" "$_p8p_bad"

# The four git-grep locators share one fixture, so each recipe's exact output also proves it
# does not reach into the files the other three are about.
P8G="$TMP/p8p-grep"; mkrepo "$P8G"
( cd "$P8G" && mkdir -p .github/workflows .circleci config
  printf '%s\n' 'name: x' "url: https://deploy:$_p8p_pw@git.example.invalid/x.git" > deploy.yml
  printf '%s\n' 'a: https://deploy:${DB_PASS}@h.invalid/x' 'b: https://deploy:$PASS@h.invalid/x' \
    'c: https://deploy:<password>@h.invalid/x' 'd: https://deploy:{{ pass }}@h.invalid/x' \
    'e: https://deploy@h.invalid/x' > placeholders.yml
  printf '%s\n' 'env:' "  password: $_p8p_pw" '  token: ${{ secrets.T }}' '  api_key: secrets.API' > .github/workflows/ci.yml
  printf '%s\n' 'vars:' "  secret: $_p8p_pw" > .gitlab-ci.yml
  printf '%s\n' 'jobs:' "  token: $_p8p_ghp" > .circleci/config.yml
  printf '%s\n' "password: $_p8p_pw" > notci.yml
  printf '%s\n' 'production:' "  url: postgres://app:$_p8p_pw@db.prod.internal:5432/app" \
    'development:' "  url: postgres://app:$_p8p_pw@localhost:5432/app" \
    '  url2: mysql://app:${DB_PASS}@db/x' "  cache: rediss://:$_p8p_pw@cache.prod.internal:6380" \
    "  mongo: mongodb+srv://u:$_p8p_pw@cluster.example.com/db" \
    "  test: postgres://app:$_p8p_pw@127.0.0.1/app" > config/database.yml
  printf '%s\n' '{' "  \"Db\": \"Server=db;Database=x;Password=$_p8p_pw;\"," \
    '  "Db2": "Server=db;Password=$DBPW;",' "  \"Api\": \"https://api.prod.internal/x?user=a&pwd=$_p8p_pw\"" '}' > appsettings.json
  printf '%s\n' 'resource "aws_db_instance" "db" {' "  password = \"$_p8p_pw\"" '  master_password = var.db_password' \
    '  api_key = "${var.k}"' '  private_key = <<EOF' 'MIIB' 'EOF' '}' 'module "net" {' \
    "  source = \"git::https://$_p8p_ghp@git.example.invalid/o/net.git\"" '}' 'module "ok" {' \
    '  source = "git::ssh://git@git.example.invalid/o/ok.git"' '}' > main.tf
  printf '%s\n' "db_secret = \"$_p8p_pw\"" > prod.tfvars
  git add -A && git commit -qm base ) >/dev/null 2>&1
_p8p_leg() {  # <name> <fence> <expected stdout>
  local bad="" out err raw n i want_err=""
  printf '%s\n' "$2" > "$TMP/p8p-leg.sh"
  case "$2" in *'git grep'*'| cut -d: -f1,2'*) ;; *) bad="$bad [could not extract the recipe, or it no longer cuts each hit to file:line]" ;; esac
  err="$( cd "$P8G" && bash "$TMP/p8p-leg.sh" 2>&1 >"$TMP/p8p-leg.out" )"
  out="$(cat "$TMP/p8p-leg.out")"
  [ "$out" = "$3" ] || bad="$bad [located '$(printf '%s' "$out" | tr '\n' ' ')', expected '$(printf '%s' "$3" | tr '\n' ' ')']"
  # One `git grep rc=0` per git grep in the fence: rc=1 is "no match" and anything higher is a
  # failed run, which the skill tells the model to report as a gap rather than a clean result.
  n="$(grep -c 'git grep' "$TMP/p8p-leg.sh")"
  for ((i = 0; i < n; i++)); do want_err="$want_err${want_err:+$'\n'}git grep rc=0"; done
  [ "$n" -ge 1 ] && [ "$err" = "$want_err" ] || bad="$bad [stderr '$(printf '%s' "$err" | tr '\n' ' ')', expected $n 'git grep rc=0' line(s)]"
  for _v in "$_p8p_pw" "$_p8p_ghp"; do
    case "$out$err" in *"$_v"*) bad="$bad [printed a planted value]" ;; esac
  done
  sed 's/ | cut -d: -f1,2$//' "$TMP/p8p-leg.sh" > "$TMP/p8p-leg-raw.sh"
  raw="$( cd "$P8G" && bash "$TMP/p8p-leg-raw.sh" 2>/dev/null )"
  case "$raw" in *"$_p8p_pw"*|*"$_p8p_ghp"*) ;; *) bad="$bad [control: without the cut the recipe printed no value, so the fixture no longer proves the cut is what hides them]" ;; esac
  [ -z "$bad" ] \
    && ok "audit: the $1 locator prints exactly the expected file:line set and no value" \
    || nok "audit P8p: the $1 locator" "$bad"
}
_p8p_leg "URL-userinfo" "$(audit_fence '**Credentials in URL userinfo**')" \
  "$(printf '%s\n' config/database.yml:2 config/database.yml:4 config/database.yml:6 config/database.yml:7 config/database.yml:8 deploy.yml:2)"
_p8p_leg "CI-config" "$(audit_fence '**CI configs with inline secrets**')" \
  "$(printf '%s\n' .circleci/config.yml:2 .github/workflows/ci.yml:2 .gitlab-ci.yml:2)"
_p8p_leg "production-credential" "$(audit_fence '**Config files with production credentials:**')" \
  "$(printf '%s\n' appsettings.json:2 appsettings.json:4 config/database.yml:2 config/database.yml:6)"
_p8p_leg "IaC" "$(audit_fence '**IaC:**')" \
  "$(printf '%s\n' main.tf:2 main.tf:5 prod.tfvars:1 main.tf:10)"

# P8q: the trivy config recipe, end-to-end against the REAL binary. trivy's JSON quotes the
# offending lines of a scanned file, and its log prints a module source URL with a token in
# the username position in full (measured on 0.74.0), so the recipe's jq and awk filters are
# the only thing between a misconfigured resource's password and the transcript. The control
# runs the same scan unfiltered and requires the password on stdout and the token on stderr;
# without it, every no-value assertion passes on a fixture trivy would not have quoted.
# Skipped without trivy, jq or an unprivileged network namespace. The skill's fallback for a
# box where `unshare -rn true` fails (no isolation, an explicit --misconfig-scanners list) is
# prose and is not run here.
# Both runs get a private TMPDIR, because trivy stages remote modules under `$TMPDIR/.aqua/cache`
# and concurrent scans on one machine share it. Observed with six scans at once: one logged
# `No files found` for the module at INFO, reported no error and quoted nothing, which here reads
# as a lost `module not loaded` line or a control with no token. With a private TMPDIR, eight
# concurrent scans all quoted it.
if command -v trivy >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && unshare -rn true 2>/dev/null; then
  TV="$TMP/p8q"; mkrepo "$TV"
  printf '%s\n' 'resource "aws_db_instance" "db" {' '  engine              = "mysql"' \
    "  password            = \"$_p8p_pw\"" '  publicly_accessible = true' '  storage_encrypted   = false' '}' \
    'module "net" {' "  source = \"git::https://$_p8p_ghp@git.example.invalid/o/net.git\"" '}' > "$TV/main.tf"
  ( cd "$TV" && git add -A && git commit -qm base ) >/dev/null 2>&1
  _p8q_tmp="$TMP/p8q-tmp"; mkdir -p "$_p8q_tmp"
  _p8q_bad=""
  audit_fence 'Run the misconfiguration scan as `trivy config`' > "$TMP/p8q-trivy.sh"
  grep -q 'trivy config' "$TMP/p8q-trivy.sh" && grep -q 'jq -c' "$TMP/p8q-trivy.sh" \
    || _p8q_bad="$_p8q_bad [could not extract the trivy recipe from SKILL.md]"
  # stderr through a command substitution, not a file: the awk filter runs in a process
  # substitution the script does not wait for, and the pipe is what waits for its output.
  _p8q_err="$( cd "$TV" && TMPDIR="$_p8q_tmp" bash "$TMP/p8q-trivy.sh" 2>&1 >"$TMP/p8q.out" )"
  _p8q_out="$(cat "$TMP/p8q.out")"
  for _v in "$_p8p_pw" "$_p8p_ghp"; do
    case "$_p8q_out$_p8q_err" in *"$_v"*) _p8q_bad="$_p8q_bad [printed a planted value]" ;; esac
  done
  grep -qE '^\{"targets":[1-9][0-9]*\}$' <<< "$_p8q_out" || _p8q_bad="$_p8q_bad [no non-zero targets line]"
  grep -qF '"ID":"AWS-' <<< "$_p8q_out" || _p8q_bad="$_p8q_bad [no misconfiguration record]"
  [ "${_p8q_out##*$'\n'}" = 'jq rc=0' ] || _p8q_bad="$_p8q_bad [stdout did not end in 'jq rc=0']"
  grep -qxF 'trivy rc=0' <<< "$_p8q_err" || _p8q_bad="$_p8q_bad [no 'trivy rc=0' line]"
  grep -qxF 'module not loaded: main.tf:7-9' <<< "$_p8q_err" || _p8q_bad="$_p8q_bad [no 'module not loaded: main.tf:7-9' line]"
  while IFS= read -r _l; do
    case "$_l" in
      'forgeward-scan: '*|'unshare: '*|'trivy: falling back to embedded checks'|'module not loaded: '*|*' other trivy error line(s) withheld'|'trivy rc='*) ;;
      *) _p8q_bad="$_p8q_bad [a stderr line outside the filter's fixed shapes reached the caller]" ;;
    esac
  done <<< "$_p8q_err"
  _p8q_ctl_err="$( cd "$TV" && TMPDIR="$_p8q_tmp" unshare -rn "$SCAN" trivy config --config /dev/null --disable-telemetry \
    --skip-check-update --skip-version-check --format json . 2>&1 >"$TMP/p8q-ctl.out" )"
  case "$(cat "$TMP/p8q-ctl.out")" in *"$_p8p_pw"*) ;; *) _p8q_bad="$_p8q_bad [control: the unfiltered JSON did not quote the password]" ;; esac
  case "$_p8q_ctl_err" in *"$_p8p_ghp"*) ;; *) _p8q_bad="$_p8q_bad [control: the unfiltered log did not print the token]" ;; esac
  [ -z "$_p8q_bad" ] \
    && ok "audit: the trivy config recipe reports targets, records and the unloaded module and prints neither planted value" \
    || nok "audit P8q: the trivy config recipe" "$_p8q_bad"
else
  ok "audit trivy config recipe: SKIPPED (needs trivy, jq and unshare -rn)"
fi

# P8r: every bash fence in the audit skill is either run by an assertion or listed here as
# an accepted gap, with the reason. Each entry's marker must resolve to a distinct fence, and
# the resolved set must equal every fence the skill holds, so a new recipe fails here until
# someone decides which it is. An entry owned by an assertion must also be extracted by it
# under that exact marker, so the census cannot claim a fence its owner does not run (an
# owner may still SKIP on a box without its scanner, as P8k and P8q do). The census cannot be
# empty and every entry must resolve, so a fence scan that found nothing fails too.
# Non-goal: a recipe put in an untagged ``` fence is invisible to this, as are inline
# one-line commands in the prose (the zizmor line in Phase 4 is one).
_p8r_census=(
  '**Never write inside the repository under audit.**|gap: one call to forgeward-artifact-dir.sh, whose output P9 pins'
  'Any deterministic scanner goes through the wrapper|gap: the wrapper argv template, with <tool> a placeholder; P8-P8n pin the wrapper'
  '## Phase 0|gap: stack probes that print file names, never contents'
  '**Infrastructure surface:**|gap: a find/ls census that prints names and a count, never contents'
  '**Never print raw `git log -p --all`|P8p'
  '**Run the gitleaks history scan on every pass|P8k'
  '**Credentials in URL userinfo**|P8p'
  '**`.env` files tracked by git.**|P8o'
  '**CI configs with inline secrets**|P8p'
  'Run the misconfiguration scan as `trivy config`|P8q'
  '**Config files with production credentials:**|P8p'
  '**IaC:**|P8p'
)
# This file, by absolute path: the suite has already cd'd into $R, so BASH_SOURCE is stale.
_p8r_self="$PLUGIN/test/${BASH_SOURCE[0]##*/}"
_p8r_bad=""; _p8r_at=()
[ -f "$_p8r_self" ] || _p8r_bad="$_p8r_bad [cannot find this suite at $_p8r_self to check owners against]"
for _e in "${_p8r_census[@]}"; do
  _m="${_e%%|*}"; _o="${_e#*|}"
  _l="$(audit_fence "$_m" line)"
  [ -n "$_l" ] || { _p8r_bad="$_p8r_bad [no bash fence follows '$_m']"; continue; }
  _p8r_at+=("$_l")
  case "$_o" in
    'gap: '*) ;;
    *) grep -qF -- "audit_fence '$_m'" "$_p8r_self" || _p8r_bad="$_p8r_bad [$_o is named as the owner of '$_m' but nothing here extracts that fence]" ;;
  esac
done
_p8r_all="$(awk '/^```(bash|sh|shell|console)$/{print NR}' "$AUDIT_SKILL")"
_p8r_got="$(printf '%s\n' "${_p8r_at[@]}" | sort -n)"
[ "$_p8r_got" = "$_p8r_all" ] \
  || _p8r_bad="$_p8r_bad [census resolves to lines '$(printf '%s' "$_p8r_got" | tr '\n' ' ')', the skill's fences open at '$(printf '%s' "$_p8r_all" | tr '\n' ' ')']"
[ -z "$_p8r_bad" ] \
  && ok "audit: each of the skill's $(printf '%s\n' "$_p8r_all" | wc -l) bash recipes is run by an assertion or listed as an accepted gap" \
  || nok "audit P8r: the recipe census" "$_p8r_bad"

# P9: the artifact dir is POSIX-absolute, exists, and is OUTSIDE the repo.
ad="$( cd "$R" && "$ARTDIR" )"; AD_OUT+=("$ad")
case "$ad" in
  /*) ok "artifact dir: POSIX-absolute ('$ad')" ;;
  *)  nok "artifact dir posix-absolute" "got: '$ad'" ;;
esac
[ -d "$ad" ] && ok "artifact dir: exists" || nok "artifact dir exists" "got: '$ad'"
case "$ad" in
  "$R"/*) nok "artifact dir outside repo" "'$ad' is inside the repo under review" ;;
  *)      ok "artifact dir: outside the repo under review" ;;
esac

# P9b (0.32.0): containment compares PHYSICAL paths. A symlink aliasing the repo, or a
# `..` that walks back into it, passes a text comparison and lands inside the tree, where
# the gate's own workspace snapshot would read as a new path on every run.
_rp="$(cd "$R" && pwd -P)"
ln -s "$R" "$TMP/repo-alias"; mkdir -p "$TMP/walk"
# repo_tree <dir>: every path below <dir> except .git, sorted. `git status` lists no empty
# directory, so it cannot witness that a call created nothing inside the repo; this can.
repo_tree() { find "$1" -path "$1/.git" -prune -o -print | sort; }
_rt="$(repo_tree "$R")"
for _root in "$TMP/repo-alias" "$TMP/walk/../repo"; do
  _ad="$( cd "$R" && FORGEWARD_ARTIFACT_ROOT="$_root" "$ARTDIR" )"; AD_OUT+=("$_ad")
  _adp="$(cd "$_ad" 2>/dev/null && pwd -P)"
  case "${_adp:-/}/" in
    "$_rp"/*|//) nok "artifact dir: a root of '${_root#"$TMP"/}' must resolve outside the repo" "got '$_ad' -> '$_adp'" ;;
    *) ok "artifact dir: a root of '${_root#"$TMP"/}' that resolves into the repo is refused" ;;
  esac
  # Handing out a directory outside is not enough: one created inside on the way (a root
  # compared as text, not by physical path, mkdirs through the alias first) is left behind.
  _new="$(comm -13 <(printf '%s\n' "$_rt") <(repo_tree "$R"))"
  [ -z "$_new" ] && ok "artifact dir: a root of '${_root#"$TMP"/}' creates nothing inside the repo" \
    || nok "artifact dir: a root of '${_root#"$TMP"/}' created a path inside the repo" "${_new//$'\n'/ }"
done

# P10: the workspace guard catches ANY new untracked path a reviewer leaves behind —
# including shapes the command-text guard structurally cannot see.
snap="$ad/snapshot.txt"
( cd "$R" && "$GUARD" snapshot "$(git rev-parse HEAD)" > "$snap" )
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

# W1..W59 -- workspace guard v2 (design §5.1, §5.5). Every recorded field has a fixture
# that changes only that field; every must-not-fire case is a legitimate change made
# while a gate runs. Assertions read the MESSAGE, not only the exit status.
WG="$TMP/wguard"; mkrepo "$WG"
( cd "$WG" && mkdir -p d/e && printf 'a\n' > a && printf 'b\n' > b && printf 'c\n' > d/e/c \
    && git add -A && git commit -qm base && git branch -M main ) >/dev/null 2>&1
WG0="$(git -C "$WG" rev-parse HEAD)"
WGC="$(git -C "$WG" rev-parse --path-format=absolute --git-common-dir)"
WS="$TMP/wguard.snap"
# Some fixtures can hang a naive guard (a FIFO is read forever), so every guard call runs
# under `timeout` where the machine has one: a hang then fails its assertion, not the suite.
wto() { if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"; else "$@"; fi; }
# wsnap: snapshot the fixture at its live HEAD. Sets wsrc and wserr.
wsnap() {
  local h; h="$(git -C "$WG" rev-parse HEAD)"
  ( cd "$WG" && wto "$GUARD" snapshot "$h" ) > "$WS" 2>"$TMP/wguard.err"; wsrc=$?
  wserr="$(cat "$TMP/wguard.err")"
}
# wcheck [dir]: check the fixture from <dir> (default its root). Sets wrc and wout.
wcheck() { wout="$( cd "${1:-$WG}" && wto "$GUARD" check "$WS" 2>&1 )"; wrc=$?; }
# wfires <label> <line fragment>: the check exits 1 and prints that line.
wfires() {
  wcheck
  case "$wout" in
    *"$2"*) [ "$wrc" = 1 ] && { ok "$1 -> exit 1 and names it"; return 0; } ;;
  esac
  nok "$1" "rc=$wrc out='$wout'"
}
# wquiet <label>: the check exits 0 and prints nothing.
wquiet() {
  wcheck
  { [ "$wrc" = 0 ] && [ -z "$wout" ]; } && ok "$1 -> exit 0" || nok "$1 must not fire" "rc=$wrc out='$wout'"
}
# wcannot <label> <message fragment>: the check exits 2 and names the cause.
wcannot() {
  case "$wout" in
    *"$2"*) [ "$wrc" = 2 ] && { ok "$1 -> exit 2 and names the cause"; return 0; } ;;
  esac
  nok "$1" "rc=$wrc out='$wout'"
}
wg() { git -C "$WG" "$@" >/dev/null 2>&1; }

# --- Detection: each changes one recorded field. ---
wsnap; printf 'x\n' > "$WG/new.txt"
wfires "W1: a new path" "new path: new.txt"; rm -f "$WG/new.txt"
wsnap; printf 'edited\n' >> "$WG/b"
wfires "W1b: a clean tracked file edited" "changed: b (was clean, now ' M')"
case "$wout" in *"new path"*|*'rm -rf'*) nok "W1c: an edited tracked file is called a new path" "out='$wout'" ;;
  *) ok "W1c: an edited tracked file is not called a new path, and no rm advice is printed" ;; esac
printf 'b\n' > "$WG/b"
printf 'dirty\n' >> "$WG/a"; wsnap; printf 'a\n' > "$WG/a"
wfires "W2: a path leaving the dirty set" "left the dirty set: a"
printf 'dirty\n' >> "$WG/a"; wsnap; printf 'more\n' >> "$WG/a"
wfires "W3: changed content in an already-dirty tracked file" "changed content: a"
case "$wout" in *"git diff shows what is there now"*) ok "W3b: the dirty-file advice is printed" ;;
  *) nok "W3b: the dirty-file advice is missing" "out='$wout'" ;; esac
printf 'a\n' > "$WG/a"
printf 'u\n' > "$WG/u.txt"; wsnap; printf 'u2\n' > "$WG/u.txt"
wfires "W4: changed content in an untracked file" "changed content: u.txt"; rm -f "$WG/u.txt"
wsnap; wg commit -q --allow-empty -m moved
wfires "W5: HEAD moving" "HEAD moved or switched branch"
wsnap; wg checkout -q -b wsib
wfires "W6: a switch to a sibling branch at the same commit" "HEAD moved or switched branch"
wg checkout -q main
printf 'dirty\n' >> "$WG/a"; wsnap; wg add a
wfires "W7: the index, via git add of an already-dirty file" "the index changed"
wg reset -q -- a; printf 'a\n' > "$WG/a"
wsnap; wg update-index --skip-worktree b
wfires "W8: skip-worktree set on a clean tracked file" "the index changed"; wg update-index --no-skip-worktree b
wsnap; wg update-index --assume-unchanged b
wfires "W9: assume-unchanged set on a clean tracked file" "the index changed"; wg update-index --no-assume-unchanged b
# The stash ref is moved with update-ref: the property is "refs/stash changed", and this
# needs no stash entry to exist.
wsnap; wg update-ref refs/stash "$WG0"
wfires "W10: the stash" "the stash changed"; wg update-ref -d refs/stash
wsnap; wg config core.hooksPath .hk
wfires "W11: core.hooksPath" "core.hooksPath changed"; wg config --unset core.hooksPath
printf '#!/bin/sh\n' > "$WG/.git/hooks/pre-push"; wsnap; printf '#!/bin/sh\nexit 0\n' > "$WG/.git/hooks/pre-push"
wfires "W12: the pre-push hook's content" "hook file changed: pre-push"
wsnap; printf '#!/bin/sh\n' > "$WG/.git/hooks/pre-push.local"
wfires "W13: pre-push.local appearing (gstack's wrapper owns pre-push)" "new hook file: pre-push.local"
wsnap; printf '#!/bin/sh\nexit 0\n' > "$WG/.git/hooks/pre-push.local"
wfires "W14: pre-push.local changing" "hook file changed: pre-push.local"
rm -f "$WG/.git/hooks/pre-push" "$WG/.git/hooks/pre-push.local"
wg config forgeward.gate enabled; wsnap; wg config --unset forgeward.gate
wfires "W15: forgeward.gate unset" "forgeward.gate changed (was 'enabled', now absent)"
# The run file, written the way a reviewer holding Bash would: the real writer's --revoke.
wsnap; ( cd "$WG" && "$WRITE" --revoke "$(git rev-parse HEAD)" ) >/dev/null 2>&1
wfires "W16: this commit's run file" "gate run file changed"
mkdir -p "$WGC/forgeward-gate-markers"
wsnap; printf '{}\n' > "$WGC/forgeward-gate-markers/main.json"
wfires "W17: this branch's marker appearing" "a PASS marker appeared for main"
rm -f "$WGC/forgeward-gate-markers/main.json"
wg branch wsib2; wsnap; printf '{}\n' > "$WGC/forgeward-gate-markers/wsib2.json"
wfires "W18: a sibling branch's marker, at the same commit, appearing" "a PASS marker appeared for wsib2"
rm -f "$WGC/forgeward-gate-markers/wsib2.json"

# --- Must NOT fire: legitimate changes during a gate run. ---
wsnap; wg config branch.main.remote origin
wquiet "W19: a config write to branch.<name>.remote"; wg config --unset branch.main.remote
wg branch wfar "$WG0"; wsnap; printf '{}\n' > "$WGC/forgeward-gate-markers/wfar.json"
wquiet "W20: a marker for a branch at another commit (another worktree's gate run)"
rm -f "$WGC/forgeward-gate-markers/wfar.json"
wsnap; touch -t 200101010000 "$WG/b"
wquiet "W21: touch on a clean tracked file"
printf 'o1\n' > "$TMP/wguard-outside.txt"; ln -s "$TMP/wguard-outside.txt" "$WG/lnk"
wsnap; printf 'o2\n' > "$TMP/wguard-outside.txt"
wquiet "W22: a change to the file an in-repo symlink points at, outside the repo"
rm -f "$WG/lnk"

# --- Where it runs: the worktree root, whatever the caller's directory. ---
( cd "$WG/d/e" && wto "$GUARD" snapshot "$(git rev-parse HEAD)" ) > "$WS" 2>/dev/null
wquiet "W23: snapshot from a subdirectory, check from the root"
wsnap; wcheck "$WG/d/e"
{ [ "$wrc" = 0 ] && [ -z "$wout" ]; } && ok "W24: snapshot from the root, check from a subdirectory -> exit 0" \
  || nok "W24: check from a subdirectory" "rc=$wrc out='$wout'"
( cd "$WG/d/e" && wto "$GUARD" snapshot "$(git rev-parse HEAD)" ) > "$WS" 2>/dev/null
printf 'n\n' > "$WG/d/new.txt"; wcheck "$WG/d/e"
case "$wout" in *"new path: d/new.txt"*) [ "$wrc" = 1 ] && ok "W25: from a subdirectory, an edit in a sibling directory is seen" \
  || nok "W25: sibling-directory edit" "rc=$wrc" ;; *) nok "W25: sibling-directory edit" "rc=$wrc out='$wout'" ;; esac
rm -f "$WG/d/new.txt"

# --- The frozen commit. ---
wout="$( cd "$WG" && "$GUARD" snapshot "$WG0" 2>&1 >/dev/null )"; wrc=$?
wcannot "W26: snapshot when HEAD is not <HEAD_SHA>" "HEAD moved since Step 0"
wout="$( cd "$WG" && "$GUARD" snapshot "$(git rev-parse --short HEAD)" 2>&1 >/dev/null )"; wrc=$?
case "$wout" in *"is not a full commit id that resolves to itself"*) [ "$wrc" = 64 ] && ok "W27: a short id -> exit 64" \
  || nok "W27: short id" "rc=$wrc" ;; *) nok "W27: short id" "rc=$wrc out='$wout'" ;; esac
wout="$( cd "$WG" && "$GUARD" snapshot main 2>&1 >/dev/null )"; wrc=$?
case "$wout" in *"is not a full commit id that resolves to itself"*) [ "$wrc" = 64 ] && ok "W28: a symbolic name -> exit 64" \
  || nok "W28: symbolic name" "rc=$wrc" ;; *) nok "W28: symbolic name" "rc=$wrc out='$wout'" ;; esac

# --- Wedge controls: each shape is present at snapshot; both commands must exit 0. ---
wwedge() { # wwedge <label>: snapshot and check both exit 0 on the unchanged tree
  wsnap; wcheck
  { [ "$wsrc" = 0 ] && [ "$wrc" = 0 ]; } && ok "$1 -> snapshot and check exit 0" \
    || nok "$1 wedged the guard" "snapshot=$wsrc check=$wrc err='$wserr' out='$wout'"
}
ln -s nowhere "$WG/dangling"; wwedge "W29: a dangling symlink"; rm -f "$WG/dangling"
ln -s b "$WG/tofile"; wwedge "W30: a symlink to a file"; rm -f "$WG/tofile"
if command -v mkfifo >/dev/null 2>&1; then
  rm -f "$WG/b"; mkfifo "$WG/b"; wwedge "W31: a FIFO replacing a tracked file"
  case "$wserr" in *"recorded without its content"*"b ( M special)"*) ok "W31b: the coverage note names the FIFO" ;;
    *) nok "W31b: no coverage note for the FIFO" "err='$wserr'" ;; esac
  rm -f "$WG/b"; printf 'b\n' > "$WG/b"
else
  ok "W31: SKIPPED (no mkfifo on this machine) -- the FIFO wedge is unverified here, not verified"
fi
WSUB="$TMP/wguard-sub"; mkrepo "$WSUB"; ( cd "$WSUB" && git commit -q --allow-empty -m s ) >/dev/null 2>&1
wg -c protocol.file.allow=always submodule add -q "$WSUB" sm; wg commit -qm sub
# The submodule is a fresh clone with no repo-local identity, so the commit names one itself:
# CI has no global identity, and without it the commit fails silently and the fixture is clean.
git -C "$WG/sm" -c user.email=t@t.t -c user.name=t -c commit.gpgsign=false \
  commit -q --allow-empty -m dirty >/dev/null 2>&1
case "$(git -C "$WG" status --porcelain)" in *" M sm"*) wwedge "W32: a dirty submodule" ;;
  *) nok "W32: the fixture did not produce a dirty submodule" "$(git -C "$WG" status --porcelain | tr '\n' ' ')" ;; esac
mkrepo "$WG/nested"; ( cd "$WG/nested" && git commit -q --allow-empty -m n ) >/dev/null 2>&1
wwedge "W33: an untracked nested repository"
case "$(cat "$WS")" in *"nested/"*"?? repo:"*) ok "W33b: the nested repository is recorded by its commit" ;;
  *) nok "W33b: nested repository record" "$(grep -a nested "$WS")" ;; esac
rm -rf "$WG/nested"
# A submodule whose gitfile is broken: git status itself fails (exit 128, measured), so the
# guard cannot record the workspace. That is exit 2 -- fail closed -- and never a hang.
cp "$WG/sm/.git" "$TMP/wguard-gitfile"; printf 'gitdir: /nonexistent\n' > "$WG/sm/.git"
wsnap; wout="$wserr"; wrc="$wsrc"
wcannot "W34: a submodule with a broken gitfile" "git failed while the workspace was being recorded"
cp "$TMP/wguard-gitfile" "$WG/sm/.git"
if [ "$(id -u)" != 0 ]; then
  printf 's\n' > "$WG/noread"; chmod 000 "$WG/noread"; wwedge "W35: an unreadable file"
  case "$wserr" in *"recorded without its content"*"noread (?? unreadable)"*) ok "W35b: the coverage note names it" ;;
    *) nok "W35b: no coverage note for the unreadable file" "err='$wserr'" ;; esac
  chmod 600 "$WG/noread"; rm -f "$WG/noread"
else
  ok "W35: SKIPPED as root, where nothing is unreadable -- unverified here, not verified"
fi

# --- The guard writes nothing: no index rewrite, no object. ---
# Control leg first: on this same stale-stat tree a plain `git status` DOES rewrite the
# index. Without that, the byte-identity below would pass with --no-optional-locks gone.
touch -t 200201010000 "$WG/a"; cp "$WG/.git/index" "$TMP/wguard-index"
git -C "$WG" status --porcelain >/dev/null 2>&1
if cmp -s "$WG/.git/index" "$TMP/wguard-index"; then
  nok "W36: control -- a plain git status did not rewrite the index, so W37 would be vacuous"
else
  ok "W36: control -- a plain git status rewrites the index on a stale-stat tree"
fi
touch -t 200301010000 "$WG/a"; cp "$WG/.git/index" "$TMP/wguard-index"
wobj="$(git -C "$WG" count-objects | sed 's/ .*//')"
wsnap; wcheck
if cmp -s "$WG/.git/index" "$TMP/wguard-index" && [ "$(git -C "$WG" count-objects | sed 's/ .*//')" = "$wobj" ]; then
  ok "W37: snapshot and check leave the index byte-identical and write no object"
else
  nok "W37: the guard wrote to the repository" "index-identical=$(cmp -s "$WG/.git/index" "$TMP/wguard-index" && echo y || echo n)"
fi

# --- Exit 2: never read as clean, and the message names the cause. ---
wsnap
wout="$( cd "$WG" && "$GUARD" check "$TMP/wguard.missing" 2>&1 )"; wrc=$?
wcannot "W38: a missing snapshot" "is missing or unreadable"
printf 'a\nb\n' > "$TMP/wguard.v1"
wout="$( cd "$WG" && "$GUARD" check "$TMP/wguard.v1" 2>&1 )"; wrc=$?
wcannot "W39: a v1 path-list snapshot" "is not a v2 workspace snapshot"
sed '$d' "$WS" > "$TMP/wguard.noend"
wout="$( cd "$WG" && "$GUARD" check "$TMP/wguard.noend" 2>&1 )"; wrc=$?
wcannot "W40: a snapshot with its end line removed" "is truncated or corrupt"
awk 'NR != 3' "$WS" > "$TMP/wguard.norec"
wout="$( cd "$WG" && "$GUARD" check "$TMP/wguard.norec" 2>&1 )"; wrc=$?
wcannot "W41: a snapshot with a record removed" "is truncated or corrupt"
wout="$( cd "$TMP" && "$GUARD" check "$WS" 2>&1 )"; wrc=$?
wcannot "W42: a run outside a repository" "not a git repository"
# git failing mid-build: a stub that fails only `status`, so the run gets past the repo
# check and fails where the manifest is built.
WGBIN="$TMP/wguard-gitstub"; mkdir -p "$WGBIN"
printf '#!/bin/sh\ncase " $* " in *" status "*) exit 128 ;; esac\nexec %s "$@"\n' "$(command -v git)" > "$WGBIN/git"
chmod +x "$WGBIN/git"
wout="$( cd "$WG" && PATH="$WGBIN:$PATH" "$GUARD" check "$WS" 2>&1 )"; wrc=$?
wcannot "W43: git failing while the manifest is built" "git failed while the workspace was being recorded"

# --- Paths that must round-trip without forging or hiding a record. ---
WNL="$(printf 'n\nl')"; WTAB="$(printf 't\tab')"; WCR="$(printf 'cr\r')"
printf '1\n' > "$WG/$WNL"; printf '2\n' > "$WG/$WTAB"; printf '3\n' > "$WG/pre"; printf '4\n' > "$WG/pre-x"
printf '5\n' > "$WG/cr"; printf '6\n' > "$WG/$WCR"; printf '7\n' > "$WG/plain"; printf '8\n' > "$WG/\"plain\""
wwedge "W44: newline, tab, prefix, CR and quote paths round-trip unchanged"
printf '1b\n' > "$WG/$WNL"; printf '2b\n' > "$WG/$WTAB"; printf '3b\n' > "$WG/pre"
printf '6b\n' > "$WG/$WCR"; printf '8b\n' > "$WG/\"plain\""
wcheck
wlines="$(printf '%s\n' "$wout" | grep -c '^  changed content: ')"
case "$wout" in
  *'changed content: n\nl '*'changed content: t\tab '*)
    { [ "$wrc" = 1 ] && [ "$wlines" = 5 ]; } && ok "W45: a changed newline or tab path is named in its encoded form, five changes, five lines" \
      || nok "W45: newline/tab paths" "rc=$wrc lines=$wlines out='$wout'" ;;
  *) nok "W45: newline/tab paths" "rc=$wrc out='$wout'" ;;
esac
# `pre` changed and `pre-x` did not; `cr<CR>` changed and its twin `cr` did not; `"plain"`
# changed and `plain` did not. Raw, `git hash-object --stdin-paths` would hash `cr` for
# `cr<CR>` and `plain` for `"plain"`, with status 0 (measured), so those changes would be
# invisible. Pins the C-quoting.
case "$wout" in
  *'changed content: pre-x '*|*'changed content: cr '*|*'changed content: plain '*)
    nok "W46: an unchanged twin was reported" "out='$wout'" ;;
  *'changed content: \"plain\" '*) case "$wout" in *'changed content: cr\r '*'changed content: pre '*)
    ok "W46: CR and quote twins, and a prefix, are told apart" ;;
    *) nok "W46: CR twin or prefix not seen" "out='$wout'" ;; esac ;;
  *) nok "W46: the quoted path's change was not seen" "out='$wout'" ;;
esac
rm -f "$WG/$WNL" "$WG/$WTAB" "$WG/pre" "$WG/pre-x" "$WG/cr" "$WG/$WCR" "$WG/plain" "$WG/\"plain\""

# --- Agreement: the guard records exactly the markers --revoke withdraws. ---
# W47: the shared implementation is byte-identical, on F1's pattern, with a floor.
_rn_body() { awk '/^revoke_names\(\)/{f=1;next} f{print} f&&/^\}$/{exit}' "$1"; }
_rn_a="$(_rn_body "$WRITE")"; _rn_b="$(_rn_body "$GUARD")"
if [ -n "$_rn_a" ] && [ -n "$_rn_b" ] && [ "$_rn_a" = "$_rn_b" ]; then
  ok "W47: revoke_names is byte-identical in the marker writer and the workspace guard"
else
  nok "W47: revoke_names has drifted between the writer and the guard" \
      "$({ [ -z "$_rn_a" ] || [ -z "$_rn_b" ]; } && echo 'extraction returned nothing -- the function shape changed' || diff <(printf '%s\n' "$_rn_a") <(printf '%s\n' "$_rn_b") | tr '\n' ' ')"
fi
# W48: derived, never copied. A branch, a branch with a same-named tag (two spellings), a
# detached HEAD at the commit, and a branch at another commit. Every candidate gets a
# marker; the guard's marker records must equal the names --revoke then withdraws.
wg checkout -q main; wg branch -f wa; wg branch -f wdup; wg tag -f wdup; wg checkout -q --detach
WGH="$(git -C "$WG" rev-parse HEAD)"
for n in wa wdup heads/wdup HEAD main wfar; do
  mkdir -p "$(dirname "$WGC/forgeward-gate-markers/$n.json")"; printf '{}\n' > "$WGC/forgeward-gate-markers/$n.json"
done
wguard_names="$( ( cd "$WG" && "$GUARD" snapshot "$WGH" 2>/dev/null ) | awk -F'\t' '$1 == "marker" { print $2 }' | sort)"
wwriter_names="$( ( cd "$WG" && "$WRITE" --revoke "$WGH" 2>/dev/null ) \
  | sed -n "s/^forgeward gate: withdrew the earlier PASS marker for '\(.*\)'; .*/\1/p" | sort)"
wn="$(printf '%s\n' "$wguard_names" | grep -c .)"
if [ "$wn" -ge 5 ] && [ "$wguard_names" = "$wwriter_names" ]; then
  case "$wguard_names" in *wfar*) nok "W48: a marker at another commit was recorded" ;;
    *) ok "W48: the guard records exactly the $wn markers --revoke withdraws (derived on a same-named tag and a detached HEAD)" ;; esac
else
  nok "W48: the guard's marker list and --revoke's disagree" \
      "guard=[$(echo $wguard_names)] writer=[$(echo $wwriter_names)]"
fi
wg checkout -q main

# --- Tools: only git, bash, sort, comm, awk and readlink on PATH. ---
WGT="$TMP/wguard-tools"; mkdir -p "$WGT"
for t in git bash sort comm awk readlink; do ln -sf "$(command -v "$t")" "$WGT/$t"; done
wh="$(git -C "$WG" rev-parse HEAD)"
( cd "$WG" && PATH="$WGT" "$GUARD" snapshot "$wh" ) > "$WS" 2>/dev/null; wtsrc=$?
printf 'x\n' > "$WG/tool.txt"
wout="$( cd "$WG" && PATH="$WGT" "$GUARD" check "$WS" 2>&1 )"; wrc=$?
rm -f "$WG/tool.txt"; sed '$d' "$WS" > "$TMP/wguard.tnoend"
wout2="$( cd "$WG" && PATH="$WGT" "$GUARD" check "$TMP/wguard.tnoend" 2>&1 )"; wrc2=$?
case "$wout|$wout2" in
  *"new path: tool.txt"*"|"*"is truncated or corrupt"*)
    { [ "$wtsrc" = 0 ] && [ "$wrc" = 1 ] && [ "$wrc2" = 2 ]; } \
      && ok "W49: detection and exit 2 work with PATH holding only git, bash, sort, comm, awk and readlink" \
      || nok "W49: restricted PATH" "snapshot=$wtsrc check=$wrc truncated=$wrc2" ;;
  *) nok "W49: restricted PATH" "snapshot=$wtsrc out='$wout' out2='$wout2'" ;;
esac

# --- W50..W59: the holes the final whole-branch reviews found. ---
# W50 (final review, A1): `$(…)` strips a trailing newline and git does not, so a
# core.hooksPath that gains a LF runs hooks from another directory. Pin: it fires.
wg config core.hooksPath .hk; wsnap; wg config core.hooksPath $'.hk\n'
wfires "W50: core.hooksPath gaining a trailing newline" "core.hooksPath changed"
wg config --unset core.hooksPath
# W51/W52: an entry flagged BEFORE the snapshot is invisible to `git status`, and the index
# hash does not move when it is edited. W51 skip-worktree, W52 assume-unchanged.
wg update-index --skip-worktree b; wsnap; printf 'edited\n' >> "$WG/b"
wfires "W51: a file flagged skip-worktree before the snapshot, edited" "changed: b (flagged skip-worktree or assume-unchanged, so git status does not show it)"
wg update-index --no-skip-worktree b; printf 'b\n' > "$WG/b"
wg update-index --assume-unchanged a; wsnap; printf 'edited\n' >> "$WG/a"
wfires "W52: a file flagged assume-unchanged before the snapshot, edited" "changed: a (flagged skip-worktree or assume-unchanged, so git status does not show it)"
wg update-index --no-assume-unchanged a; printf 'a\n' > "$WG/a"
# W53: a flagged entry ABSENT at snapshot gets no record (a sparse checkout's normal state),
# so the unchanged tree is quiet; creating the file reads as new.
wg update-index --skip-worktree d/e/c; rm -f "$WG/d/e/c"; wsnap
{ [ "$wsrc" = 0 ] && [ "$(awk -F'\t' '$1 == "flagged"' "$WS" | grep -c .)" = 0 ]; } \
  && ok "W53a: an absent flagged entry has no record" || nok "W53a: an absent flagged entry was recorded" "snapshot=$wsrc"
wquiet "W53b: a flagged entry absent at snapshot, tree unchanged"
printf 'c\n' > "$WG/d/e/c"
wfires "W53c: a flagged entry created after the snapshot" "new: d/e/c (flagged skip-worktree or assume-unchanged"
wg update-index --no-skip-worktree d/e/c
# W54: a failed stash lookup is a git failure, not "no stash". The stub fails only the
# refs/stash lookup; the control leg is the real git on an unchanged tree.
wsnap
WGSB="$TMP/wguard-stashstub"; mkdir -p "$WGSB"
printf '#!/bin/sh\ncase " $* " in *" refs/stash "*) exit 128 ;; esac\nexec %s "$@"\n' "$(command -v git)" > "$WGSB/git"
chmod +x "$WGSB/git"
wout="$( cd "$WG" && PATH="$WGSB:$PATH" wto "$GUARD" check "$WS" 2>&1 )"; wrc=$?
wcannot "W54: git failing the stash lookup" "git failed while the workspace was being recorded"
wquiet "W54b (control): the real git on the unchanged tree"
# W55: after `git rm --cached` git lists the path twice (`D ` and `??`). An unchanged tree
# must still check clean (the wedge), and an edit is a content change, not a new path.
wg rm -q --cached b; wwedge "W55: git rm --cached on a tracked file, unchanged tree"
printf 'edited\n' >> "$WG/b"
wfires "W55b: an untracked-from-index file edited" "changed content: b"
case "$wout" in *"new path"*|*'rm -rf'*) nok "W55c: a file untracked from the index is called a new path" "out='$wout'" ;;
  *) ok "W55c: no new-path report and no rm advice for a file untracked from the index" ;; esac
wg add b; printf 'b\n' > "$WG/b"
# W56: a check run from another linked worktree is not the snapshot's worktree.
wg checkout -q --detach; wsnap
wg worktree add -q --detach "$TMP/wguard-wt2" HEAD
wcheck "$TMP/wguard-wt2"
case "$wout" in *"this check ran in another worktree than the snapshot"*)
  [ "$wrc" != 0 ] && ok "W56: a check from another linked worktree differs" || nok "W56: exit status" "rc=$wrc out='$wout'" ;;
  *) nok "W56: another worktree was not noticed" "rc=$wrc out='$wout'" ;; esac
wg worktree remove --force "$TMP/wguard-wt2"; wg checkout -q main
# W57: PINNED BLIND SPOT, ruling C2. The hooks record covers the entries DIRECTLY in the
# effective hooks directory; a subdirectory is one `dir` record and the files below it are
# not followed. This repo owns that rule, so the day this reddens, design §5.4 and the
# guard's header must change with it.
mkdir -p "$WG/.git/hooks/sub"; printf 'x\n' > "$WG/.git/hooks/sub/helper"; wsnap
printf 'y\n' > "$WG/.git/hooks/sub/helper"; wcheck
{ [ "$wrc" = 0 ] && [ -z "$wout" ] && [ "$(awk -F'\t' '$1 == "hook" && $2 == "sub" && $3 == "dir"' "$WS" | grep -c .)" = 1 ]; } \
  && ok "W57: a file below a hooks subdirectory is not followed (pinned blind spot): one 'dir' record, check exits 0" \
  || nok "W57: the hooks-subdirectory ruling changed" "rc=$wrc out='$wout'"
rm -rf "$WG/.git/hooks/sub"
# W58 (final review F5): an untracked directory holding a file at snapshot, and a new file
# written inside it. Pins --untracked-files=all (the default collapses it to `dir/`).
mkdir -p "$WG/udir"; printf '1\n' > "$WG/udir/one"; wsnap; printf '2\n' > "$WG/udir/two"
wfires "W58: a new file inside an already-untracked directory" "new path: udir/two"
rm -rf "$WG/udir"
# W59 (final review F5): submodule.<name>.ignore=all hides a submodule's new commit from a
# default `git status`. Pins --ignore-submodules=none. Own repo: it adds a submodule.
WGSAVE="$WG"; WG="$TMP/wguard-sm"; WGSRC="$TMP/wguard-smsrc"
mkrepo "$WGSRC"; ( cd "$WGSRC" && printf 's\n' > s && git add s && git commit -qm s ) >/dev/null 2>&1
mkrepo "$WG"; ( cd "$WG" && printf 'a\n' > a && git add a && git commit -qm base \
  && git -c protocol.file.allow=always submodule add -q "$WGSRC" sm && git commit -qm sm \
  && git config submodule.sm.ignore all ) >/dev/null 2>&1
wsnap; git -C "$WG/sm" -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m inner >/dev/null 2>&1
wfires "W59: a commit inside a submodule marked ignore=all" "changed: sm"
WG="$WGSAVE"

# --- W60..W62: the holes the gstack /review outside pass found (2026-11-17). ---
# W60: a worktree whose path ENDS in a newline, beside a sibling without it at the same
# commit. `$(…)` strips trailing newlines, so a toplevel read without a sentinel enters the
# sibling and checks the wrong tree. Own repos.
WGSAVE="$WG"; WG="$TMP/wguard-nl"$'\n'; mkrepo "$WG"
( cd "$WG" && printf 'a\n' > a && git add a && git commit -qm base ) >/dev/null 2>&1
git clone -q "$WG" "$TMP/wguard-nl" >/dev/null 2>&1
wsnap; printf 'x\n' > "$WG/leak"
wfires "W60: a write in a worktree whose path ends in a newline, beside a sibling without it" "new path: leak"
# W60b: the same stripping in the nested-repository test read a nested repo whose name ends
# in a newline as unreadable, so a commit inside it was not seen.
rm -f "$WG/leak"; mkrepo "$WG/nest"$'\n'
( cd "$WG/nest"$'\n' && printf 'n\n' > n && git add n && git commit -qm inner ) >/dev/null 2>&1; wsnap
case "$(cat "$WS")" in
  *"repo:unreadable"*) nok "W60b: a nested repo whose name ends in a newline was recorded as unreadable" "snapshot=$wsrc" ;;
  *" repo:$(git -C "$WG/nest"$'\n' rev-parse HEAD)"*) ok "W60b: a nested repo whose name ends in a newline is recorded by its commit" ;;
  *) nok "W60b: no record of the nested repo's commit" "snapshot=$wsrc" ;;
esac
WG="$WGSAVE"
# W61a/b: a config value spelling the placeholder for "not set" (`unset` for core.hooksPath,
# `absent` for forgeward.gate) must not read as not set. Both hooks directories hold the
# same entries and the new one is excluded, so only the config record can see the change.
mkdir -p "$WG/unset" "$WG/.git/info"; cp -pR "$WG/.git/hooks/." "$WG/unset/"
cp "$WG/.git/info/exclude" "$TMP/wguard-exclude" 2>/dev/null || : > "$TMP/wguard-exclude"
printf 'unset\n' >> "$WG/.git/info/exclude"
wsnap; wg config core.hooksPath unset
wfires "W61a: core.hooksPath set to the literal value 'unset'" "core.hooksPath changed"
wg config --unset core.hooksPath
wsnap; wg config forgeward.gate absent
wfires "W61b: forgeward.gate set to the literal value 'absent'" "forgeward.gate changed"
wg config --unset forgeward.gate; rm -rf "$WG/unset"; cat "$TMP/wguard-exclude" > "$WG/.git/info/exclude"
# W62: the comparison itself failing is exit 2, never a clean check. The stub fails only the
# comparison's awk (four arguments, the last `-`); the snapshot is valid, so validation
# passes and the comparison is what fails. W40 cannot see this: a truncated snapshot stops
# at validation, before the comparison runs.
wsnap
WGAW="$TMP/wguard-awkstub"; mkdir -p "$WGAW"
printf '#!/bin/sh\n[ "$#" = 4 ] && [ "$4" = - ] && exit 2\nexec %s "$@"\n' "$(command -v awk)" > "$WGAW/awk"
chmod +x "$WGAW/awk"
wout="$( cd "$WG" && PATH="$WGAW:$PATH" wto "$GUARD" check "$WS" 2>&1 )"; wrc=$?
wcannot "W62: the comparison failing on a valid snapshot" "the two manifests could not be compared"
wquiet "W62b (control): the real awk on the unchanged tree"

# P9c (B1): the directory handed out is checked, not only the root. A symlinked
# <root>/forgeward-artifacts that points into the repo must not be returned.
_p9c="$TMP/p9c-root"; mkdir -p "$_p9c"; ln -s "$R" "$_p9c/forgeward-artifacts"
_rt="$(repo_tree "$R")"
_ad="$( cd "$R" && FORGEWARD_ARTIFACT_ROOT="$_p9c" "$ARTDIR" )"; _adrc=$?; AD_OUT+=("$_ad")
_adp="$(cd "$_ad" 2>/dev/null && pwd -P)"
case "${_adp:-/}/" in
  "$_rp"/*|//) nok "P9c: a symlinked forgeward-artifacts into the repo must not be handed out" "rc=$_adrc got '$_ad' -> '$_adp'" ;;
  *) [ "$_adrc" = 0 ] && ok "P9c: a symlinked <root>/forgeward-artifacts into the repo is refused" \
       || nok "P9c: exit status" "rc=$_adrc" ;;
esac
# ...and refused BEFORE the mkdir: without the pre-mkdir refusal the per-process directory
# is created inside the repo through the symlink, then refused, and left there.
_new="$(comm -13 <(printf '%s\n' "$_rt") <(repo_tree "$R"))"
[ -z "$_new" ] && ok "P9c: nothing is created inside the repo through the symlink" \
  || nok "P9c: a path was created inside the repo through the symlink" "${_new//$'\n'/ }"
# P9d: a nonexistent root falls back under /tmp (the documented fallback, now pinned).
_ad="$( cd "$R" && FORGEWARD_ARTIFACT_ROOT="$TMP/p9d-nonexistent" "$ARTDIR" )"; AD_OUT+=("$_ad")
case "$_ad" in /tmp/*) [ -d "$_ad" ] && ok "P9d: a nonexistent root falls back under /tmp" || nok "P9d: fallback dir missing" "$_ad" ;;
  *) nok "P9d: a nonexistent root did not fall back under /tmp" "got '$_ad'" ;; esac

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
( cd "$R" && git checkout -qb gcdead && echo g > gc.txt && git add -A && git commit -qm gc && write_marker main "privacy" ) >/dev/null 2>&1
[ -f "$MARKDIR/gcdead.json" ] && ok "marker GC: precondition — a marker exists for branch 'gcdead'" \
  || nok "marker GC precondition" "no $MARKDIR/gcdead.json"

# G2: delete the branch, gate again -> the orphaned marker is pruned.
( cd "$R" && git checkout -q feature && git branch -D gcdead ) >/dev/null 2>&1
( cd "$R" && write_marker main "privacy" ) >/dev/null 2>&1
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
# This dual-client plugin carries its version in FOUR files, and a release bumps all
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
  mkdir -p .claude-plugin .codex-plugin
  printf '{\n  "name": "u",\n  "version": "1.0.0"\n}\n' > package.json
  printf '{\n  "name": "p",\n  "version": "1.0.0",\n  "defaultEnabled": true\n}\n' > .claude-plugin/plugin.json
  printf '{\n  "name": "m",\n  "plugins": [\n    { "name": "p", "version": "1.0.0" }\n  ]\n}\n' > .claude-plugin/marketplace.json
  printf '{\n  "name": "p",\n  "version": "1.0.0",\n  "hooks": "./hooks/codex-hooks.json"\n}\n' > .codex-plugin/plugin.json
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

# V1: a version-only bump across ALL FOUR manifests leaves the hash alone.
setjson "$RV" package.json                      "d['version']='1.0.1'"
setjson "$RV" .claude-plugin/plugin.json        "d['version']='1.0.1'"
setjson "$RV" .claude-plugin/marketplace.json   "d['plugins'][0]['version']='1.0.1'"
setjson "$RV" .codex-plugin/plugin.json         "d['version']='1.0.1'"
( cd "$RV" && git add -A && git commit -qm "chore: bump version" ) >/dev/null 2>&1
v_bump="$(cd "$RV" && "$HASH" main)"
[ "$v_base" = "$v_bump" ] && ok "manifests: version-only bump across all four -> hash UNCHANGED (no spurious re-gate on release)" \
  || nok "four-manifest bump invariance" "$v_base vs $v_bump"

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

# V4: PAYLOAD ASSEMBLY, rebuilt independently. A repo with no .claude-plugin/ must
# hash to exactly the payload this test constructs by hand — same sections, same
# separators, same trailing newline — so a change to the script's assembly fails here
# rather than silently redefining "unchanged".
#
# THIS IS NO LONGER A BACK-COMPAT ASSERTION, and the change was deliberate. It used to
# claim that markers in ordinary repos survive an upgrade, which held while the only
# edit was appending sections for files those repos do not have. The jq/python
# byte-alignment rewrote the canonical bytes INSIDE the package.json section, so every
# repo re-gates once at that version. The independent rebuild below therefore tracks
# the CURRENT canonicalization (`jq -S -c -a`) — if you change it there, you change it
# here, and the one-time re-gate is the accepted cost stated in the script header. The
# diff part is rebuilt with the CURRENT pinned invocation too (root-relative pathspecs,
# config-independent options): the suite runs under the invoker's own git config, so a
# bare `git diff` here would track that config while the helper does not.
RL="$TMP/repo-legacy"
mkrepo "$RL"
( cd "$RL"
  printf '{\n  "name": "u",\n  "version": "1.0.0",\n  "dependencies": { "express": "^4.19.2" }\n}\n' > package.json
  echo ok > src.js; git add -A; git commit -qm base; git branch -M main
  git checkout -q -b feature; echo more > f.js; git add -A; git commit -qm feat ) >/dev/null 2>&1
legacy="$( cd "$RL"
  dp="$(GIT_DIFF_OPTS= git -c diff.relative=false -c diff.noprefix=false -c diff.mnemonicPrefix=false \
        -c diff.suppressBlankEmpty=false -c diff.interHunkContext=0 -c diff.indentHeuristic=false \
        -c core.quotePath=true diff --no-ext-diff --no-textconv --full-index --no-color --no-renames \
        -U3 --diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/ --ignore-submodules=none \
        --submodule=short "main...HEAD" -- ':(top)' ':(top,exclude)VERSION' \
        ':(top,exclude)CHANGELOG.md' ':(top,exclude)CHANGELOG' ':(top,exclude)TODOS.md' \
        ':(top,exclude)package.json' 2>/dev/null)"
  raw="$(git show "HEAD:package.json" 2>/dev/null)"
  if command -v jq >/dev/null 2>&1; then pp="$(printf '%s' "$raw" | jq -S -c -a '.version = "<<forgeward-gated>>"')"
  else pp="$(printf '%s' "$raw" | python3 -c 'import json,sys
d=json.load(sys.stdin); d["version"]="<<forgeward-gated>>"
sys.stdout.buffer.write(json.dumps(d,sort_keys=True,separators=(",",":")).encode())')"
  fi
  printf '%s\n--FORGEWARD-PKG--\n%s\n' "$dp" "$pp" | sha256sum | awk '{print $1}' )"
[ "$(cd "$RL" && "$HASH" main)" = "$legacy" ] \
  && ok "manifests: repo with no .claude-plugin/ hashes to the independently-rebuilt payload (section layout + canonicalization both pinned)" \
  || nok "payload assembly" "got $(cd "$RL" && "$HASH" main), rebuilt $legacy"

# V5: the python3 fallback must implement the SAME semantics as the jq path, not
# merely run. Exercised by putting a PATH in front that has python3 but no jq. Only
# meaningful where jq is the branch that would otherwise be taken.
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
  # `cat` joined this list for V9, the only assertion here that reaches a raw
  # passthrough arm. Without it that arm has nothing to exec and emits EMPTY, so V9
  # goes red comparing raw against empty — a true failure signal for a false reason,
  # which is worse than either a pass or an honest fail. V5-V8 never noticed because
  # they only ever drive the two real modes with python3 present.
  for t in env bash git sha256sum awk python3 cat; do
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

  # V7: the assertion V5/V6 could not make. Those pin that the fallback has the same
  # SEMANTICS (invariant on a bump, sensitive to a substantive change); both passed
  # for a year while the two branches emitted different BYTES for the same manifest,
  # because each was only ever compared against itself. The marker records a hash, so
  # equal semantics is not enough — a marker written under jq must still read fresh
  # under python3 and vice versa. This compares the two branches to EACH OTHER on the
  # same commit, which is the only shape that catches it.
  jq_hash="$( cd "$RV" && "$HASH" main )"
  py_hash="$( cd "$RV" && PATH="$NOJQ" "$HASH" main )"
  { [ -n "$jq_hash" ] && [ "$jq_hash" = "$py_hash" ]; } \
    && ok "manifests: jq and python3 produce the IDENTICAL hash for the same manifest (marker portable across machines)" \
    || nok "jq/python3 hash parity" "jq='$jq_hash' py='$py_hash' — a marker written on one machine reads STALE on the other"

  # V8: pins the ONE disclosed residual, so a jq or python that closes it turns this
  # red instead of quietly outdating the BLIND SPOT paragraph in the script header.
  # jq preserves a number's source text; python normalizes it through float. Nothing
  # in this file can align them (see the header for why python cannot be patched), so
  # the divergence is asserted as KNOWN rather than left to be rediscovered. A
  # manifest reaching this needs a float in scientific notation or with a trailing
  # zero — npm and plugin manifests carry versions as strings, so it is unreachable in
  # practice. If this test fails, the fix is to DELETE it and the header paragraph.
  RN="$TMP/repo-numeric"
  mkrepo "$RN"
  ( cd "$RN"
    printf '{\n  "name": "n",\n  "version": "1.0.0",\n  "weight": 1e10\n}\n' > package.json
    echo ok > src.js; git add -A; git commit -qm base; git branch -M main
    git checkout -q -b feature; echo more > f.js; git add -A; git commit -qm feat ) >/dev/null 2>&1
  n_jq="$( cd "$RN" && "$HASH" main )"
  n_py="$( cd "$RN" && PATH="$NOJQ" "$HASH" main )"
  { [ -n "$n_jq" ] && [ -n "$n_py" ] && [ "$n_jq" != "$n_py" ]; } \
    && ok "manifests: number-literal divergence between jq and python3 is still present and DISCLOSED (known residual, pinned)" \
    || nok "disclosed numeric residual changed" "jq='$n_jq' py='$n_py' — if these now MATCH, delete V8 and the BLIND SPOT paragraph in forgeward-diff-hash.sh"

  # V9: the two arms must agree on an UNRECOGNISED mode, not merely on the real ones.
  # V5-V8 all drive the script through its public interface, which takes <base> [tip]
  # and passes mode literals internally, so none of them can reach a default arm — and
  # the two defaults disagreed for as long as both existed: jq's `*) cat ;;` emitted
  # the raw bytes while the python3 branch had no default at all, fell past both
  # conditionals, and still reached json.dumps, canonicalized but NOT blanked. Same
  # input, two outputs, decided by which interpreter was installed. Unreachable in
  # production and therefore untestable through the front door, so this reaches in and
  # extracts the function. The extraction is asserted BEFORE it is used: a reformat
  # that breaks the sed range fails loudly here rather than quietly reducing this
  # assertion to comparing two empty strings.
  nm_fn="$(sed -n '/^normalize_manifest()/,/^}/p' "$HASH")"
  nm_raw='{"b":2,"a":1,"version":"9.9.9"}'
  case "$nm_fn" in
    *"normalize_manifest()"*)
      nm_jq="$( eval "$nm_fn"; printf '%s' "$nm_raw" | normalize_manifest bogus-mode 2>/dev/null )"
      nm_py="$( PATH="$NOJQ" bash -c 'eval "$1"; printf "%s" "$2" | normalize_manifest bogus-mode 2>/dev/null' _ "$nm_fn" "$nm_raw" )"
      { [ "$nm_jq" = "$nm_py" ] && [ "$nm_jq" = "$nm_raw" ]; } \
        && ok "manifests: jq and python3 agree on an unrecognised mode — raw passthrough, no silent canonicalization" \
        || nok "unknown-mode arm divergence" "jq='$nm_jq' py='$nm_py' raw='$nm_raw' — the branches answer differently for a mode neither handles, so the same manifest hashes differently depending on what is installed"
      ;;
    *)
      nok "V9 extraction failed" "could not extract normalize_manifest from $HASH — the sed range no longer matches, so V9 asserted NOTHING"
      ;;
  esac
else
  ok "manifests: python3-fallback comparison SKIPPED — V5/V6/V7/V8/V9 all need BOTH jq and python3 present, so the jq/python3 hash-parity guarantee is UNVERIFIED on this machine"
fi

# V10: the mode guard must HALT, not merely complain — and it needs no interpreter, so
# it runs unconditionally. snapshot_manifest's guard ends in `exit 1`, but every call
# site is a command substitution, where that exit kills only the SUBSHELL. The first
# cut of this fix did exactly that: it printed the guard's message to stderr, assigned
# an empty part, and went on to emit an ordinary-looking hash with status 0 — a die
# that did not die, which is the same defect the guard was written to prevent. The
# `|| exit 1` on each call site is what makes it real. Pinned here so removing one of
# them fails a test instead of silently restoring a hash nobody should trust.
BM="$TMP/badmode-diff-hash.sh"
awk '{gsub(/snapshot_manifest \.claude-plugin\/marketplace\.json plugins/,"snapshot_manifest .claude-plugin/marketplace.json bogus-mode")}1' "$HASH" > "$BM"
chmod +x "$BM"
if grep -q 'bogus-mode' "$BM"; then
  bm_out="$( cd "$RV" && "$BM" main 2>/dev/null )"; bm_rc=$?
  { [ "$bm_rc" -ne 0 ] && [ -z "$bm_out" ]; } \
    && ok "manifests: an unknown mode at a call site halts with no hash (exit inside \$(...) alone would not)" \
    || nok "mode guard does not halt" "rc=$bm_rc out='$bm_out' — a mistyped mode still emits a hash that looks legitimate"
else
  nok "V10 setup failed" "could not inject a bad mode into a copy of $HASH — the call-site text no longer matches, so V10 asserted NOTHING"
fi

# V11-V13: a `git diff` that FAILS must not hash as the empty diff. The diff part was an
# unguarded assignment, so a failed diff left it empty with exit 0 and the hash was the
# empty-diff hash -- which every later commit on that pair also produces, because its
# diff fails the same way. V11 and V12 are PRE-FIX controls (6e11899's helper printed a
# hash for both, and its writer certified V11's repo so the later push was allowed);
# V13 is the positive control. Mutation-checked: removing the guard turns V11 and V12 red.
VDMSG='failed; refusing to hash an empty diff'
VD="$TMP/vdiff"; mkrepo "$VD"
( cd "$VD" && git config forgeward.gate enabled && echo base > a.txt && git add -A && git commit -qm base \
   && git branch -M main && git checkout -qb vfeat && echo change >> a.txt && git commit -qam feat ) >/dev/null 2>&1
VDB="$(git -C "$VD" rev-parse main)"; VDH="$(git -C "$VD" rev-parse vfeat)"
# V13 (positive control): the intact repo hashes.
v13_out="$(cd "$VD" && "$HASH" main "$VDH" 2>&1)"; v13_rc=$?
[ "$v13_rc" -eq 0 ] && [ "${#v13_out}" -eq 64 ] && case "$v13_out" in *[!0-9a-f]*) false ;; *) true ;; esac \
  && ok "V13: an intact repo still hashes (control for V11/V12)" \
  || nok "V13: intact repo did not hash" "rc=$v13_rc out=$v13_out"
# V11: the base-side blob of a.txt is missing (a partial clone or corruption); the merge
# base is intact, so only the guard can refuse.
v11_blob="$(git -C "$VD" rev-parse main:a.txt)"
rm -f "$VD/.git/objects/${v11_blob:0:2}/${v11_blob:2}"
v11_out="$(cd "$VD" && "$HASH" main "$VDH" 2>"$TMP/v11.err")"; v11_rc=$?
v11_err="$(cat "$TMP/v11.err")"
v11_run="$(cd "$VD" && "$WRITE" --revoke "$VDH" 2>/dev/null | sed -n 's/^RUN_ID=//p')"
v11_wout="$(cd "$VD" && "$WRITE" main privacy "$VDB" "$VDH" "$v11_run" 2>&1)"; v11_wrc=$?
( cd "$VD" && echo new > new.txt && git add new.txt && git commit -qm "unreviewed" ) >/dev/null 2>&1
v11_z="$(git -C "$VD" rev-parse HEAD)"
v11_push="$(cd "$VD" && printf 'refs/heads/vfeat %s refs/heads/vfeat %s\n' "$v11_z" 0000000000000000000000000000000000000000 \
  | FORGEWARD_SECRET_SCAN=skip "$PLUGIN/scripts/forgeward-pre-push.sh" origin /nonexistent.git 2>&1)"; v11_prc=$?
[ "$v11_rc" -ne 0 ] && [ -z "$v11_out" ] \
  && case "$v11_err" in *"forgeward-diff-hash: git diff main...$VDH $VDMSG"*) true ;; *) false ;; esac \
  && [ "$v11_wrc" -eq 1 ] && case "$v11_wout" in *"could not hash the reviewed diff; nothing was written."*) true ;; *) false ;; esac \
  && [ "$v11_prc" -eq 1 ] && case "$v11_push" in *"have not passed /forgeward:gate"*"vfeat @ ${v11_z:0:12}"*) true ;; *) false ;; esac \
  && ok "V11: a diff that fails on a missing blob prints no hash and says why; the writer refuses and a later commit cannot be pushed" \
  || nok "V11: a failed diff still produced a hash or a usable marker" \
         "rc=$v11_rc out=$v11_out err=$v11_err write=$v11_wrc:$v11_wout push=$v11_prc:$v11_push"
# V12: a tip with no merge base with the base.
VN="$TMP/vnomb"; mkrepo "$VN"
( cd "$VN" && echo a > a.txt && git add -A && git commit -qm base && git branch -M main \
   && git checkout -q --orphan vorph && git rm -rqf . && echo o > o.txt && git add o.txt && git commit -qm o ) >/dev/null 2>&1
VNO="$(git -C "$VN" rev-parse vorph)"
v12_out="$(cd "$VN" && "$HASH" main "$VNO" 2>"$TMP/v12.err")"; v12_rc=$?
v12_err="$(cat "$TMP/v12.err")"
[ "$v12_rc" -ne 0 ] && [ -z "$v12_out" ] \
  && case "$v12_err" in *"forgeward-diff-hash: git diff main...$VNO $VDMSG"*) true ;; *) false ;; esac \
  && ok "V12: a tip with no merge base with the base prints no hash and says why" \
  || nok "V12: no-merge-base diff still hashed" "rc=$v12_rc out=$v12_out err=$v12_err"

# V14-V19: the diff part is ROOT-RELATIVE and does not follow diff config. V14, V15,
# V18, V19 and every V17 "leaves the hash unchanged" case are PRE-FIX controls:
# e9ab0e0's helper (`-- .` and a bare `git diff`) fails each, measured by running this
# file against it. V16 is the floor that keeps V17 from asserting a property of nothing;
# the V17 orderFile assertion pins a stated non-goal and is green on e9ab0e0 too.
# V14: a hash taken in a subdirectory equals the hash taken at the root. Mutation-checked:
# `-- .` in place of `':(top)'` turns V14 and V15 red.
VS="$TMP/vsub"; mkrepo "$VS"
( cd "$VS" && mkdir sub && echo a > sub/in.txt && echo b > out.txt && git add -A && git commit -qm base \
   && git branch -M main && git checkout -qb vs && echo a2 >> sub/in.txt && echo b2 >> out.txt \
   && git commit -qam feat ) >/dev/null 2>&1
VSB="$(git -C "$VS" rev-parse main)"; VSH="$(git -C "$VS" rev-parse HEAD)"
v14_root="$(cd "$VS" && "$HASH" main 2>/dev/null)"
v14_sub="$(cd "$VS/sub" && "$HASH" main 2>/dev/null)"
[ "${#v14_root}" -eq 64 ] && [ "$v14_sub" = "$v14_root" ] \
  && ok "V14: the diff hash taken in a subdirectory equals the one taken at the root" \
  || nok "V14: the diff hash depends on the cwd" "root=$v14_root sub=$v14_sub"
# V15: the reminder run from a subdirectory. The gate passes from sub/ (its writer runs
# there), then a commit changes a file OUTSIDE sub/. e9ab0e0 compared two hashes of sub/
# alone and allowed the push; leg 1 (the reviewed commit itself) is the positive control.
v15_run="$(cd "$VS/sub" && "$WRITE" --revoke "$VSH" 2>/dev/null | sed -n 's/^RUN_ID=//p')"
( cd "$VS/sub" && "$WRITE" main privacy "$VSB" "$VSH" "$v15_run" ) >/dev/null 2>&1
v15_1="$(pretool "$VS/sub" "git push origin HEAD")"
( cd "$VS" && echo outside >> out.txt && git commit -qam 'change outside sub' ) >/dev/null 2>&1
v15_2="$(pretool "$VS/sub" "git push origin HEAD")"
[ -z "$v15_1" ] && denies "$v15_2" \
  && case "$v15_2" in *"the current branch (vs @ "*"has not passed /forgeward:gate"*) true ;; *) false ;; esac \
  && ok "V15: from a subdirectory, a change outside it after the PASS reads not fresh" \
  || nok "V15: a subdirectory reminder missed a change outside its subtree" \
         "reviewed=${v15_1:-allowed} after=$(denies "$v15_2" && echo denied || echo allowed)"

# V16/V17: one assertion per diff setting, each against the default-config hash of the
# SAME range in the same repo. The fixture carries a shape for each setting to act on:
# a two-hunk file (context, hunk merging), blank lines (suppressBlankEmpty), a patience
# example (algorithm), an indent-heuristic example, a rename and a copy, a textconv
# driver, a subdirectory, a binary, a non-ASCII name (quotePath) and a gitlink with a
# .gitmodules entry. Every setting is repo-local and unset again after its case.
VX="$TMP/vcfg"; mkrepo "$VX"
VEXT="$TMP/vext.sh"; printf '#!/bin/sh\necho constant\n' > "$VEXT"; chmod +x "$VEXT"
( cd "$VX"
  seq 1 30 > a.txt
  printf 'one\n\ntwo\n\nthree\n\nfour\n' > blank.txt
  seq 101 140 > r.txt
  seq 201 240 > c.txt
  printf 'lower case text\n' > t.tc
  mkdir sub; echo s1 > sub/x.txt
  printf '\000\001\002bin' > bin.dat
  printf 'q\n' > "$(printf 'caf\303\251.txt')"
  printf '#include <stdio.h>\n\n// Frobs foo heartily\nint frobnitz(int foo)\n{\n    int i;\n    for(i = 0; i < 10; i++)\n    {\n        printf("Your answer is: ");\n        printf("%%d\\n", foo);\n    }\n}\n\nint fact(int n)\n{\n    if(n > 1)\n    {\n        return fact(n-1) * n;\n    }\n    return 1;\n}\n\nint main(int argc, char **argv)\n{\n    frobnitz(fact(10));\n}\n' > pat.c
  printf '1\n2\na\n\nb\n3\n4\n' > ind.c
  mkdir sm; printf '[submodule "sm"]\n\tpath = sm\n\turl = ./nowhere\n' > .gitmodules
  git add -A; git update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,sm
  git commit -qm base; git branch -M main; git checkout -qb vx
  sed -i -e '5s/.*/five/' -e '15s/.*/fifteen/' a.txt
  printf 'one\n\ntwo\n\nTHREE\n\nfour\n' > blank.txt
  git mv r.txt r2.txt
  cp c.txt c2.txt; sed -i '1s/.*/changed/' c.txt
  printf 'still lower case\n' > t.tc; printf '*.tc diff=upper\n' > .gitattributes
  echo s2 > sub/x.txt
  printf '\000\001\003bin' > bin.dat
  printf 'q2\n' > "$(printf 'caf\303\251.txt')"
  printf '#include <stdio.h>\n\nint fib(int n)\n{\n    if(n > 2)\n    {\n        return fib(n-1) + fib(n-2);\n    }\n    return 1;\n}\n\n// Frobs foo heartily\nint frobnitz(int foo)\n{\n    int i;\n    for(i = 0; i < 10; i++)\n    {\n        printf("%%d\\n", foo);\n    }\n}\n\nint main(int argc, char **argv)\n{\n    frobnitz(fib(10));\n}\n' > pat.c
  printf '1\n2\na\n\nb\na\n\nb\n3\n4\n' > ind.c
  git add -A; git update-index --cacheinfo 160000,2222222222222222222222222222222222222222,sm
  git commit -qm feat ) >/dev/null 2>&1
v17_def="$(cd "$VX" && "$HASH" main 2>/dev/null)"
v17_n=0
v17_same() { # v17_same <label> <hash>
  v17_n=$((v17_n+1))
  [ -n "$2" ] && [ "$2" = "$v17_def" ] \
    && ok "V17: $1 leaves the diff hash unchanged" \
    || nok "V17: $1 changes the diff hash" "default=$v17_def got=${2:-<none>}"
}
v17_cfg() { # v17_cfg <label> <key> <value>
  local got
  git -C "$VX" config "$2" "$3"
  got="$(cd "$VX" && "$HASH" main 2>/dev/null)"
  git -C "$VX" config --unset "$2"
  v17_same "$1" "$got"
}
v17_env() { # v17_env <VAR> <value>
  local got
  got="$(cd "$VX" && env "$1=$2" "$HASH" main 2>/dev/null)"
  v17_same "$1 in the environment" "$got"
}
v17_cfg "diff.external" diff.external "$VEXT"
v17_env GIT_EXTERNAL_DIFF "$VEXT"
v17_cfg "a diff driver's command (diff.<driver>.command)" diff.upper.command "$VEXT"
v17_cfg "a textconv driver" diff.upper.textconv 'tr a-z A-Z'
v17_cfg "diff.noprefix" diff.noprefix true
v17_cfg "diff.algorithm=patience" diff.algorithm patience
v17_cfg "diff.context=10" diff.context 10
v17_env GIT_DIFF_OPTS --unified=10
v17_cfg "diff.renames=copies" diff.renames copies
v17_cfg "diff.renames=false" diff.renames false
v17_cfg "color.diff=always" color.diff always
v17_cfg "core.abbrev=12" core.abbrev 12
v17_cfg "diff.interHunkContext=5" diff.interHunkContext 5
v17_cfg "diff.suppressBlankEmpty" diff.suppressBlankEmpty true
v17_cfg "diff.indentHeuristic=false" diff.indentHeuristic false
v17_cfg "core.quotePath=false" core.quotePath false
v17_cfg "diff.ignoreSubmodules=all" diff.ignoreSubmodules all
v17_cfg "submodule.<name>.ignore=all" submodule.sm.ignore all
v17_cfg "diff.submodule=log" diff.submodule log
# diff.relative=true, hashed from a subdirectory (B1's third case: top magic alone does
# not override it; the -c override does).
git -C "$VX" config diff.relative true
v17_rel="$(cd "$VX/sub" && "$HASH" main 2>/dev/null)"
git -C "$VX" config --unset diff.relative
v17_same "diff.relative=true, hashed from a subdirectory," "$v17_rel"
# V16: the floor. A default hash that is empty would make every case above vacuous.
[ "${#v17_def}" -eq 64 ] && [ "$v17_n" -ge 10 ] \
  && ok "V16: the diff-config battery ran $v17_n cases against a real default hash" \
  || nok "V16: the diff-config battery asserted nothing" "default=${v17_def:-<none>} cases=$v17_n"
# V17 (documented non-goal, pinned so it is corrected the day it closes): diff.orderFile
# still reorders the file sections, so a marker reads stale -- never a false PASS.
printf 'sub/*\n*\n' > "$TMP/vorder"
git -C "$VX" config diff.orderFile "$TMP/vorder"
v17_ord="$(cd "$VX" && "$HASH" main 2>/dev/null)"
git -C "$VX" config --unset diff.orderFile
[ "${#v17_ord}" -eq 64 ] && [ "$v17_ord" != "$v17_def" ] \
  && ok "V17: diff.orderFile still changes the hash (the header's stated non-goal; fails closed)" \
  || nok "V17: diff.orderFile no longer changes the hash -- correct the helper's non-goal" \
         "default=$v17_def got=${v17_ord:-<none>}"

# V18: end to end, the shape the pinning exists for. With an external differ that prints
# the same text for two contents, a binary replaced AFTER the PASS hashed the same and
# e9ab0e0 allowed the push. Leg 1 (the reviewed commit itself) is the positive control.
# Mutation-checked: dropping --no-ext-diff from the helper turns V18 red.
VE="$TMP/vextrepo"; mkrepo "$VE"
( cd "$VE" && git config forgeward.gate enabled && git config diff.external "$VEXT" \
   && printf '\000\001\002bin' > bin.dat && git add -A && git commit -qm base && git branch -M main \
   && git checkout -qb ve && printf '\000\001\003bin' > bin.dat && git commit -qam feat ) >/dev/null 2>&1
VEB="$(git -C "$VE" rev-parse main)"; VEH="$(git -C "$VE" rev-parse HEAD)"
v18_run="$(cd "$VE" && "$WRITE" --revoke "$VEH" 2>/dev/null | sed -n 's/^RUN_ID=//p')"
( cd "$VE" && "$WRITE" main privacy "$VEB" "$VEH" "$v18_run" ) >/dev/null 2>&1
v18_push() { # v18_push <sha>: the real enforcer on a push of ve at <sha>
  ( cd "$VE" && printf 'refs/heads/ve %s refs/heads/ve %s\n' "$1" 0000000000000000000000000000000000000000 \
    | FORGEWARD_SECRET_SCAN=skip "$PLUGIN/scripts/forgeward-pre-push.sh" origin /nonexistent.git 2>&1 )
}
v18_1="$(v18_push "$VEH")"; v18_1rc=$?
( cd "$VE" && printf '\000\001\004bin' > bin.dat && git commit -qam 'replace the binary' ) >/dev/null 2>&1
VEZ="$(git -C "$VE" rev-parse HEAD)"
v18_2="$(v18_push "$VEZ")"; v18_2rc=$?
[ "$v18_1rc" -eq 0 ] && [ "$v18_2rc" -eq 1 ] \
  && case "$v18_2" in *"have not passed /forgeward:gate"*"ve @ ${VEZ:0:12}"*) true ;; *) false ;; esac \
  && ok "V18: with diff.external set, a binary replaced after the PASS is refused at push" \
  || nok "V18: an external differ hid a binary change after the PASS" \
         "reviewed=$v18_1rc:$v18_1 replaced=$v18_2rc:$v18_2"

# V19: a binary file is `Binary files ... differ` plus its `index` line, and without
# --full-index that line carries ABBREVIATED blob ids. Two blobs sharing a 7-hex prefix
# take ~13k tries to find, deterministically (fixed search order). The gate passes on X1;
# the commit is amended to X2 and X1 is pruned, so git no longer lengthens the prefix to
# tell them apart -- e9ab0e0 hashed both the same and allowed the push (PRE-FIX control,
# also red with only --full-index removed). Leg 1 (the reviewed commit) is the positive
# control; the prefix check proves the fixture really collides.
VB="$TMP/vbinrepo"; mkrepo "$VB"
python3 -I - "$TMP/vbin" <<'PY'
import hashlib, sys
seen = {}
i = 0
while True:
    c = b"\x00forgeward-bin-" + str(i).encode()
    k = hashlib.sha1(b"blob %d\x00" % len(c) + c).hexdigest()[:7]
    if k in seen:
        open(sys.argv[1] + ".x1", "wb").write(seen[k])
        open(sys.argv[1] + ".x2", "wb").write(c)
        break
    seen[k] = c
    i += 1
PY
( cd "$VB" && git config forgeward.gate enabled && printf '\000base' > bin.dat && git add -A \
   && git commit -qm base && git branch -M main && git checkout -qb vb && cp "$TMP/vbin.x1" bin.dat \
   && git commit -qam x1 ) >/dev/null 2>&1
VBB="$(git -C "$VB" rev-parse main)"; VBH="$(git -C "$VB" rev-parse HEAD)"
v19_run="$(cd "$VB" && "$WRITE" --revoke "$VBH" 2>/dev/null | sed -n 's/^RUN_ID=//p')"
( cd "$VB" && "$WRITE" main privacy "$VBB" "$VBH" "$v19_run" ) >/dev/null 2>&1
v19_push() { # v19_push <sha>: the real enforcer on a push of vb at <sha>
  ( cd "$VB" && printf 'refs/heads/vb %s refs/heads/vb %s\n' "$1" 0000000000000000000000000000000000000000 \
    | FORGEWARD_SECRET_SCAN=skip "$PLUGIN/scripts/forgeward-pre-push.sh" origin /nonexistent.git 2>&1 )
}
v19_1="$(v19_push "$VBH")"; v19_1rc=$?
v19_x1="$(git -C "$VB" rev-parse "$VBH:bin.dat")"
( cd "$VB" && cp "$TMP/vbin.x2" bin.dat && git commit -q --amend -am x2 && git reflog expire --expire=now --all \
   && git gc -q --prune=now ) >/dev/null 2>&1
VBZ="$(git -C "$VB" rev-parse HEAD)"; v19_x2="$(git -C "$VB" rev-parse "$VBZ:bin.dat")"
v19_gone=1; git -C "$VB" cat-file -e "$v19_x1" 2>/dev/null && v19_gone=0
v19_2="$(v19_push "$VBZ")"; v19_2rc=$?
[ "${v19_x1:0:7}" = "${v19_x2:0:7}" ] && [ "$v19_x1" != "$v19_x2" ] && [ "$v19_gone" = 1 ] \
  && [ "$v19_1rc" -eq 0 ] && [ "$v19_2rc" -eq 1 ] \
  && case "$v19_2" in *"have not passed /forgeward:gate"*"vb @ ${VBZ:0:12}"*) true ;; *) false ;; esac \
  && ok "V19: a binary replaced after the PASS by one with the same abbreviated blob id is refused at push" \
  || nok "V19: an abbreviated index line hid a binary change after the PASS" \
         "x1=$v19_x1 x2=$v19_x2 x1-pruned=$v19_gone reviewed=$v19_1rc:$v19_1 replaced=$v19_2rc:$v19_2"

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

# D1-D12: gstack skill detection. It was built because supply-chain-reviewer deferred
# dependency CVEs to `/cso` unconditionally, so on a machine without gstack nobody checked
# CVEs and the reviewer returned PASS clean; the reviewer then probed and self-adjusted.
# 0.23.0 removed that probe — the reviewer owns the axis everywhere and branches on
# nothing. The script and these assertions stay because the /ship handoff still rides on
# it: `forgeward-detect-environment.sh` derives `gstack_ship` from this script, and Step 3
# hands off only when that reads `present`. A false positive there is the gate reporting a
# handoff it never performed, which is the same bug shape one axis over.
#
# EVERY assertion here pins a DIRECTION, not just a result. A false negative costs a
# duplicated check or a redundant disclosure; a false positive is a silently skipped step
# — the original bug. So the interesting cases below are the ones that must come back "not installed",
# and a future edit that makes detection more eager has to turn one of them red.
#
# CLAUDE_CONFIG_DIR is set on every call. Without it these would read the developer's
# REAL ~/.claude — where gstack is very likely installed — and D3 would pass by finding
# somebody's actual /cso.
DET="$PLUGIN/scripts/forgeward-detect-gstack-skill.sh"
det() { # det <config-dir> <skill> -> exit code
  ( CLAUDE_CONFIG_DIR="$1" "$DET" "$2" >/dev/null 2>&1 ); echo $?
}

# detp: like det, but returns `<rc>|<printed path>` AND neutralises the third root.
#
# `det` covers roots 1 and 3 through CLAUDE_CONFIG_DIR and leaves root 2 —
# `<git toplevel>/.claude/skills` — live, because it never leaves the suite's cwd. Today
# that is inert only because this repo ships no `.claude/skills`; plant one and D8b goes
# green against the PRE-FIX script, which is D8's original defect recurring inside D8's
# own fix. `$TMP` is outside any repo, so `git rev-parse --show-toplevel` comes back empty
# and root 2 drops out entirely — and it holds no `.claude/skills` either way.
#
# Returning the PATH is the other half. An exit status cannot say WHICH root matched, so
# an assertion on rc alone passes when the right answer arrives from the wrong place —
# CLAUDE.md: "Assert on the MESSAGE, not the exit status."
detp() { # detp <config-dir> <skill> -> "<rc>|<path>"
  local o rc
  o="$( cd "$TMP" && CLAUDE_CONFIG_DIR="$1" "$DET" "$2" 2>/dev/null )"; rc=$?
  printf '%s|%s' "$rc" "$o"
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
  || nok "detect D3" "expected 1 — a false positive reads a standalone machine as a gstack one"

# D4: a skill genuinely named `cso` that is not gstack's. The name alone must not be
# enough, or an unrelated skill is read as gstack's and the gate acts on it.
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

# D8: a plugin-cache layout one marketplace and one plugin deep — a shape nothing here uses.
# This shape has NO evidence behind it — enumerated on the author's machine, 0 directories
# at this depth against 14 at the versioned one (8 marketplaces, 8 plugins, 15 version dirs). It is searched defensively, and this assertion is what stops the glob
# being deleted as dead. Do not read a pass here as proof the layout exists.
D8="$TMP/det8"; mkskill "$D8/plugins/cache/some-marketplace/gstack/skills/cso" "$MARKER"
[ "$(det "$D8" cso)" = 0 ] \
  && ok "detect: plugin-cache install is INSTALLED" \
  || nok "detect D8" "expected 0"

# D8b: the layout that actually ships — a VERSION level between the plugin and `skills`.
# This is the positive control D8 was mistaken for. Until 0.18.0 the glob stopped one
# directory short, so this returned "not installed" for every plugin-installed gstack and
# nothing caught it: D8 passed, and D8 asserts a shape no install on this machine uses.
# A test that only builds the fixture the code already handles proves the code handles the
# fixture, which is not the same as proving it handles the world. Mirrors drift's R13.
D8B="$TMP/det8b"
mkskill "$D8B/plugins/cache/some-marketplace/gstack/1.2.3/skills/cso" "$MARKER"
[ "$(detp "$D8B" cso)" = "0|$D8B/plugins/cache/some-marketplace/gstack/1.2.3/skills/cso" ] \
  && ok "detect: a versioned plugin-cache install (<market>/<plugin>/<version>/skills) is INSTALLED" \
  || nok "detect D8b: the versioned plugin-cache layout went undetected — the arm that had never fired" \
         "expected 0|<the versioned path>, got $(detp "$D8B" cso)"

# D8c: direction. The version level must not become a wildcard that swallows depth — a
# SKILL.md sitting one level deeper still must not qualify, or the glob stops discriminating.
D8C="$TMP/det8c"
mkskill "$D8C/plugins/cache/some-marketplace/gstack/1.2.3/extra/skills/cso" "$MARKER"
[ "$(detp "$D8C" cso)" = "1|" ] \
  && ok "detect: a FOURTH level under the cache does not qualify" \
  || nok "detect D8c" "expected 1| (no match, nothing printed), got $(detp "$D8C" cso)"

# D8d: both depths present at once — the only arrangement that occurs on a machine which
# has genuinely used both. The shallow root is appended to `roots` BEFORE the deep one and
# carries no marker, so this pins that a non-matching root does not abort the search: the
# versioned skill must still be found and its path returned. Nothing else covers the
# ordering the 0.18.0 glob introduced.
D8D="$TMP/det8d"
mkdir -p "$D8D/plugins/cache/some-marketplace/gstack/skills/cso"
printf -- '---\nname: cso\ndescription: Unrelated helper, no marker.\n---\n\nBody.\n' \
  > "$D8D/plugins/cache/some-marketplace/gstack/skills/cso/SKILL.md"
mkskill "$D8D/plugins/cache/some-marketplace/gstack/1.2.3/skills/cso" "$MARKER"
[ "$(detp "$D8D" cso)" = "0|$D8D/plugins/cache/some-marketplace/gstack/1.2.3/skills/cso" ] \
  && ok "detect: a non-matching SHALLOW root does not abort the search for the versioned one" \
  || nok "detect D8d: shallow root shadowed the versioned one" "got $(detp "$D8D" cso)"

# D8e: pins a KNOWN FALSE POSITIVE, deliberately. The cache retains every version ever
# installed, so a plugin that was installed and later removed still answers `present` —
# stated in the script's own header and filed P3 in TODOS.md rather than fixed, because
# reading `~/.claude/plugins/installed_plugins.json` changes what the gate defers on every
# probe. This asserts the CURRENT, WRONG answer so the eventual fix has a red-to-green
# marker and a partial fix cannot pass as a whole one. It is not an endorsement: if you
# are here because this went red, that is the fix landing — update it, do not delete it.
D8E="$TMP/det8e"
mkskill "$D8E/plugins/cache/some-marketplace/gstack/1.0.0/skills/cso" "$MARKER"
mkskill "$D8E/plugins/cache/some-marketplace/gstack/2.0.0/skills/cso" "$MARKER"
case "$(detp "$D8E" cso)" in
  0\|*/plugins/cache/*) ok "detect: ANY cached version answers present — the documented false positive, pinned" ;;
  *) nok "detect D8e: the pinned false positive changed" "got $(detp "$D8E" cso)" ;;
esac

# D8f: the third level must look like a VERSION, not merely be a third directory. D8c pins
# arity — a fourth level does not qualify — and arity was the only thing pinned until 0.18.0,
# which left a bare `*` matching `cache/<market>/<plugin>/node_modules/skills`. Reproduced at
# exit 0 before the `[0-9]*` constraint landed. This is the direction the detector's header
# calls unaffordable: a false positive is a silently skipped check. Fails closed on a
# `v`-prefixed scheme too, which is accepted and written into the script's comment.
D8F="$TMP/det8f"
mkskill "$D8F/plugins/cache/some-marketplace/gstack/node_modules/skills/cso" "$MARKER"
[ "$(detp "$D8F" cso)" = "1|" ] \
  && ok "detect: a NON-VERSION third level (node_modules) does not qualify as a version dir" \
  || nok "detect D8f: a bare third-level wildcard is back — node_modules/skills matched" \
         "got $(detp "$D8F" cso)"

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
# reads as "not installed" to the caller, so this direction is safe either way — asserted so the
# distinction between "absent" and "you called it wrong" does not quietly disappear.
[ "$(det "$D1" 'cso/../../etc')" = 2 ] \
  && ok "detect: a path-shaped argument is a usage error, never a match" \
  || nok "detect D12" "expected 2"

# --- E1..E11: environment disclosure (Option B standalone posture) ---------------
# forgeward WAS scoped as a delta against gstack, so what a PASS covered depended on what
# else was installed. 0.8.0 made that visible instead of leaving it to a README table: the
# gate DISCLOSED an unowned axis and gated anyway. That era is over — 0.17.0 took `quality`,
# 0.19.0 took `deep-audit`, and 0.23.0 took dependency CVEs, install scripts and lockfile
# integrity, so no axis on this gate is owned by a tool that might not be installed.
#
# The probe outlives the disclosure it was written for, and these assertions are why it can
# be trusted to. Three things still read it: Step 1a takes `seo_posture`, Step 3's handoff
# takes `gstack_ship`, and forgeward-write-marker.sh's `_env_ok` regex validates the whole
# JSON shape including the two fields nothing else reads. Do not read the E-block as
# pinning a live deferral; read it as pinning a probe whose consumers moved.
#
# THE VACUITY TRAP, and it is the reason E2 exists. forgeward-detect-environment.sh is
# NOT a PATH lookup, so the suite's PATH-shim helpers do nothing to it. It resolves
# THREE roots, and simulating "no gstack" means neutralising all of them:
#   1. $CLAUDE_CONFIG_DIR/skills  (falls back to $HOME/.claude/skills if unset)
#   2. <git toplevel>/.claude/skills   <- the one that is easy to forget
#   3. $CLAUDE_CONFIG_DIR/plugins/cache/*/*/skills  and  .../*/*/*/skills (the versioned
#      layout, which is the one every real install actually uses)
# gstack is very likely installed on the machine running this suite (it is on the
# author's), so an assertion that forgets root 1 or 3 finds the REAL gstack, and one that
# forgets root 2 finds whatever the cwd repo ships. Every "absent" assertion below would
# then pass while proving nothing. E2 and E2b are the positive controls that make that
# detectable: each must come back "present" from the same harness, so a change that
# hard-wires the probe to "absent" turns one of them red instead of quietly greening E1.
# Two controls, not one, because they cover different arms — E2 the `review` arm, E2b the
# `cso` arm — and a control for one proves nothing about the other.
ENV_SH="$PLUGIN/scripts/forgeward-detect-environment.sh"
ER="$TMP/envrepo"; mkrepo "$ER"          # a repo with NO .claude/skills of its own
( cd "$ER" && echo x > x.txt && git add -A && git commit -qm init ) >/dev/null 2>&1
EMPTY_CFG="$TMP/envcfg-empty"; mkdir -p "$EMPTY_CFG"
envprobe() { # envprobe <config-dir> -> one line of JSON, run from inside $ER
  ( cd "$ER" && CLAUDE_CONFIG_DIR="$1" "$ENV_SH" 2>/dev/null )
}
jfield() { # jfield <json> <key> -> value  (string fields only; the probe emits no nesting)
  printf '%s' "$1" | sed -n 's/.*"'"$2"'":"\([^"]*\)".*/\1/p'
}
mkcfg() { mkdir -p "$ER/.forgeward"; printf '%s\n' "$1" > "$ER/.forgeward/config.yml"; }
rmcfg() { rm -rf "$ER/.forgeward"; }

# E1: nothing installed anywhere the probe looks -> all three axes read absent.
E1J="$(envprobe "$EMPTY_CFG")"
[ "$(jfield "$E1J" gstack_ship)" = absent ] \
  && [ "$(jfield "$E1J" gstack_review)" = absent ] \
  && [ "$(jfield "$E1J" gstack_cso)" = absent ] \
  && ok "env: with every root neutralised, all three gstack axes read ABSENT" \
  || nok "env E1" "got '$E1J'"

# E2: THE POSITIVE CONTROL for E1. Same harness, one skill planted -> present, and only
# that one. Without this, a probe that always printed "absent" would green E1.
E2C="$TMP/envcfg-review"; mkdir -p "$E2C/skills/review"
printf -- '---\nname: review\nversion: 1.0.0\n%s\n---\n\nBody.\n' "$MARKER" > "$E2C/skills/review/SKILL.md"
E2J="$(envprobe "$E2C")"
[ "$(jfield "$E2J" gstack_review)" = present ] && [ "$(jfield "$E2J" gstack_ship)" = absent ] \
  && ok "env: a planted /review reads PRESENT while /ship stays absent (E1 is not vacuous)" \
  || nok "env E2" "got '$E2J'"

# E2b: THE POSITIVE CONTROL FOR `gstack_cso`, and it is E2's twin rather than a duplicate of
# it. E2 controls the `review` arm; nothing controlled the `cso` arm at all, so E1's single
# "absent" assertion was the whole of its coverage. That was survivable while a reviewer
# BRANCHED on the field — a probe stuck on "absent" would have shown up as every machine
# reporting the same mode. 0.23.0 removed that consumer: `agents/supply-chain-reviewer.md`
# owns dependency CVEs, install scripts and lockfile integrity on every machine, so nothing
# reads `gstack_cso` to make a decision any more. The field survives because
# forgeward-write-marker.sh's `_env_ok` regex REQUIRES it, and a required-but-unread field
# is exactly the shape that rots silently. This is the assertion that would go red.
E2bC="$TMP/envcfg-cso"; mkdir -p "$E2bC/skills/cso"
printf -- '---\nname: cso\nversion: 1.0.0\n%s\n---\n\nBody.\n' "$MARKER" > "$E2bC/skills/cso/SKILL.md"
E2bJ="$(envprobe "$E2bC")"
[ "$(jfield "$E2bJ" gstack_cso)" = present ] && [ "$(jfield "$E2bJ" gstack_ship)" = absent ] \
  && [ "$(jfield "$E2bJ" gstack_review)" = absent ] \
  && ok "env: a planted /cso reads PRESENT while ship and review stay absent (E1's cso arm is not vacuous)" \
  || nok "env E2b" "got '$E2bJ'"

# E3: no config file at all -> absent, empty list. The common case, and it must disclose.
rmcfg
E3J="$(envprobe "$EMPTY_CFG")"
[ "$(jfield "$E3J" config)" = absent ] && [ -z "$(jfield "$E3J" substitutes)" ] \
  && ok "env: no .forgeward/config.yml -> config=absent, no substitutes" \
  || nok "env E3" "got '$E3J'"

# E4: the one shape the reader supports.
mkcfg 'standalone:
  substitutes:
    - quality
    - deep-audit'
E4J="$(envprobe "$EMPTY_CFG")"
[ "$(jfield "$E4J" config)" = present ] && [ "$(jfield "$E4J" substitutes)" = "quality,deep-audit" ] \
  && ok "env: standalone.substitutes block list parses to a CSV of axis names" \
  || nok "env E4" "got '$E4J'"

# E5: the marker is assembled by string interpolation and this is the only field whose
# content comes from a repo file. A name carrying a quote or a brace must be DROPPED, not
# escaped and not passed through — pinned here so a future "be more permissive" edit that
# would let it reach the marker turns red.
mkcfg 'standalone:
  substitutes:
    - a"b},{evil
    - quality'
E5J="$(envprobe "$EMPTY_CFG")"
[ "$(jfield "$E5J" substitutes)" = "quality" ] \
  && ok "env: a substitute name with JSON metacharacters is dropped, not interpolated" \
  || nok "env E5" "got '$E5J'"

# E6: an unreadable config must say so rather than claim an empty list. Direction matters:
# "unreadable" makes the caller disclose (a redundant paragraph), while a silent empty
# list is indistinguishable from "the user configured nothing" and hides a real gap.
# Skipped as root, where chmod 000 does not deny.
mkcfg 'standalone:
  substitutes:
    - quality'
chmod 000 "$ER/.forgeward/config.yml"
if [ "$(id -u)" = 0 ] || [ -r "$ER/.forgeward/config.yml" ]; then
  ok "env: unreadable-config case SKIPPED (running as root; chmod 000 does not deny)"
else
  E6J="$(envprobe "$EMPTY_CFG")"
  [ "$(jfield "$E6J" config)" = unreadable ] && [ -z "$(jfield "$E6J" substitutes)" ] \
    && ok "env: an unreadable config reads UNREADABLE (disclose), never present-with-no-substitutes" \
    || nok "env E6" "got '$E6J'"
fi
chmod 644 "$ER/.forgeward/config.yml"

# E7: the reader tracks a two-level path. A later top-level key with its own
# `substitutes:` list must not have it adopted.
mkcfg 'standalone:
  substitutes:
    - quality
other:
  substitutes:
    - deep-audit'
E7J="$(envprobe "$EMPTY_CFG")"
[ "$(jfield "$E7J" substitutes)" = "quality" ] \
  && ok "env: a substitutes list under a DIFFERENT top-level key is not adopted" \
  || nok "env E7" "got '$E7J'"
rmcfg

# E8: always exit 0. It is informational and feeds a sentence, not a skip — a probe that
# can fail a gate run would be a new way to block a user over a missing OPTIONAL tool.
if ( cd "$ER" && CLAUDE_CONFIG_DIR="$EMPTY_CFG" "$ENV_SH" >/dev/null 2>&1 ); then
  ok "env: probe exits 0 even with nothing installed and no config"
else
  nok "env E8" "expected exit 0"
fi

# E9: one line, and real JSON. It is interpolated into the marker, so a stray newline or
# a broken quote would corrupt a file both hooks parse.
E9J="$(envprobe "$EMPTY_CFG")"
[ "$(printf '%s\n' "$E9J" | wc -l | tr -d ' ')" = 1 ] \
  && printf '%s' "$E9J" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null \
  && ok "env: probe emits exactly one line and it parses as JSON" \
  || nok "env E9" "got '$E9J'"

# E10: the marker carries the environment, and it round-trips through the SAME dotted-path
# read the hooks use. This is provenance — nothing enforces on it — so the assertion is
# that it is readable, not that it gates anything.
#
# It names `gstack_cso` explicitly, and that is the field with no consumer left as of
# 0.23.0. What the key check buys is a SECOND CODE PATH, and only that: E1 and E2b read
# the probe's own stdout, while this reads the copy forgeward-write-marker.sh interpolated
# and `_env_ok` validated. A marker writer that stops embedding the field correctly is
# invisible to E1 and E2b.
#
# It does NOT cover the probe, and the comment here claimed it did until the reviewer
# mutation-tested the claim instead of reading it. Drop the field from the probe's printf
# and E1 goes red on its own, because `jfield` prints nothing for a missing key and the
# empty string is not `absent`. The novel coverage in this commit is E2b's — a probe
# hard-wired to a stale `absent` passes E1 and this check both, and fails only there.
EM="$TMP/envmarker"; mkrepo "$EM"
( cd "$EM" && echo a > a.txt && git add -A && git commit -qm base && git branch -M master \
   && echo b > b.txt && git add -A && git commit -qm work && git checkout -q -b feat \
   && write_marker_with "$PLUGIN/scripts/forgeward-write-marker.sh" master "security" ) >/dev/null 2>&1
EMJ="$(cd "$EM" && git rev-parse --path-format=absolute --git-common-dir)/forgeward-gate-markers/feat.json"
[ -f "$EMJ" ] \
  && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["schema"]==5 and isinstance(d["environment"],dict) and "gstack_ship" in d["environment"] and "gstack_cso" in d["environment"] and "seo_posture" in d["environment"] else 1)' "$EMJ" \
  && ok "env: the pass marker is schema 5 and carries a readable environment object" \
  || nok "env E10" "marker '$EMJ'"

# E11: the probe must never cost a PASS. If it is missing or broken, the marker is still
# written, still valid JSON, and records that provenance was unavailable. Losing the
# marker would force a full re-review; losing the provenance costs one unanswered question.
EB="$TMP/envbroken"; mkrepo "$EB"
FAKE_PLUGIN="$TMP/fakeplugin"; mkdir -p "$FAKE_PLUGIN"
cp "$PLUGIN/scripts/forgeward-write-marker.sh" "$PLUGIN/scripts/forgeward-diff-hash.sh" "$FAKE_PLUGIN/"
printf '#!/usr/bin/env bash\necho "NOT JSON {oops"\nexit 3\n' > "$FAKE_PLUGIN/forgeward-detect-environment.sh"
chmod +x "$FAKE_PLUGIN"/*.sh
( cd "$EB" && echo a > a.txt && git add -A && git commit -qm base && git branch -M master \
   && echo b > b.txt && git add -A && git commit -qm work && git checkout -q -b feat \
   && write_marker_with "$FAKE_PLUGIN/forgeward-write-marker.sh" master "security" ) >/dev/null 2>&1
EBJ="$(cd "$EB" && git rev-parse --path-format=absolute --git-common-dir)/forgeward-gate-markers/feat.json"
[ -f "$EBJ" ] \
  && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["passed"] is True and d["environment"]=={"probe":"unavailable"} else 1)' "$EBJ" \
  && ok "env: a broken probe still yields a valid marker recording probe=unavailable" \
  || nok "env E11" "marker '$EBJ'"

# --- E12..E17: the 0.8.0 security review's two findings -------------------------
# Both were found AFTER E1..E11 were green, which is the point of keeping them in their
# own block: the suite passing was never evidence that these hold. E12..E15 pin the
# config reader's input bounds (Finding 1), E16..E17 pin the marker's shape check
# (Finding 2). Every payload below is the reviewer's own proof-of-concept, not a
# paraphrase of it.
rep() { # rep <char> <n> -> n copies of char. awk, because the reader already needs it.
  awk -v c="$1" -v n="$2" 'BEGIN{s="";for(i=0;i<n;i++)s=s c;print s}'
}

# E12: SYMLINKS ARE REFUSED, NOT FOLLOWED. `[ -f ]` and `[ -r ]` both follow links, so
# before this a repo could commit `.forgeward/config.yml` as a git symlink (mode 120000)
# aimed at any file readable by whoever checks the branch out and runs the gate — and the
# review demonstrated end-to-end that its value was carried into the pass marker.
# The load-bearing half of this assertion is the SECOND clause: `config: unreadable`
# alone would also be produced by a dangling link, so the target must be proven unparsed.
rmcfg
E12T="$TMP/env-symlink-target.yml"
printf '%s\n' 'standalone:
  substitutes:
    - leakedfromoutside' > "$E12T"
mkdir -p "$ER/.forgeward"
if ln -s "$E12T" "$ER/.forgeward/config.yml" 2>/dev/null; then
  E12J="$(envprobe "$EMPTY_CFG")"
  [ "$(jfield "$E12J" config)" = unreadable ] && [ -z "$(jfield "$E12J" substitutes)" ] \
    && ok "env: a SYMLINKED config is refused (unreadable) and its target is never parsed" \
    || nok "env E12" "got '$E12J'"
else
  ok "env: symlink-refusal case SKIPPED (this filesystem cannot create symlinks)"
fi
rmcfg

# E13: bounded before awk touches it. Nothing else limits how much gets scanned, and a
# config this size is malformed by definition — the supported shape is a handful of short
# axis names. Refusing resolves to "disclose", the same fail-open direction as everything
# else here, so the cost of being wrong is one redundant paragraph.
mkdir -p "$ER/.forgeward"
{ printf '%s\n' 'standalone:' '  substitutes:' '    - quality'
  printf '# %s\n' "$(rep p 70000)"
} > "$ER/.forgeward/config.yml"
E13J="$(envprobe "$EMPTY_CFG")"
[ "$(jfield "$E13J" config)" = unreadable ] && [ -z "$(jfield "$E13J" substitutes)" ] \
  && ok "env: a config over the 64KB cap reads UNREADABLE and is not scanned" \
  || nok "env E13" "got '$E13J'"

# E14: per-item length bound, asserted on BOTH sides of the boundary so an off-by-one is
# visible. A 5000-character all-alphanumeric name passes every metacharacter check and
# lands in the marker verbatim — found by an injection probe during 0.8.0, confirmed Low
# by the review (not a forgery path), fixed because nothing else bounded it.
E14_64="$(rep a 64)"; E14_65="$(rep b 65)"
mkcfg "standalone:
  substitutes:
    - $E14_65
    - $E14_64
    - quality"
E14J="$(envprobe "$EMPTY_CFG")"
[ "$(jfield "$E14J" substitutes)" = "$E14_64,quality" ] \
  && ok "env: a name over 64 chars is dropped while a 64-char name and its siblings survive" \
  || nok "env E14" "got '$E14J'"

# E15: item-count bound. Same reasoning as E14 on the other axis — 32 is far above any
# real axis list and far below anything that makes the marker unwieldy. Counted by commas
# rather than by matching the exact string, so the assertion does not restate the cap's
# arithmetic in a second place.
{ printf '%s\n' 'standalone:' '  substitutes:'
  i=1; while [ "$i" -le 40 ]; do printf '    - axis%s\n' "$i"; i=$((i+1)); done
} > "$ER/.forgeward/config.yml"
E15J="$(envprobe "$EMPTY_CFG")"
E15N="$(jfield "$E15J" substitutes | tr ',' '\n' | grep -c .)"
[ "$E15N" = 32 ] \
  && ok "env: a list of 40 substitutes is truncated to the 32-item cap" \
  || nok "env E15" "got $E15N items from '$E15J'"
rmcfg

# --- E16..E17: the marker's environment field is validated as an exact SHAPE ------
# A CHARACTER allowlist does not constrain STRUCTURE, and the first draft of this check
# was one. Both payloads below draw only from the character set the probe itself uses,
# so both passed that draft untouched; both splice DUPLICATE top-level keys into the
# marker, where jq and python3 alike resolve last-value-wins — so the forged pair is what
# is_fresh() reads. These assert the forgery is now unrepresentable, and that the marker
# degrades to recorded-unavailable rather than being lost.
fakeprobe() { # fakeprobe <name> <line-it-prints> -> path to the resulting marker
  local d="$TMP/fp-$1" r="$TMP/fpr-$1"
  mkdir -p "$d"
  cp "$PLUGIN/scripts/forgeward-write-marker.sh" "$PLUGIN/scripts/forgeward-diff-hash.sh" "$d/"
  { printf '#!/usr/bin/env bash\n'; printf 'cat <<%s\n%s\n%s\n' "'EOFP'" "$2" "EOFP"; } \
    > "$d/forgeward-detect-environment.sh"
  chmod +x "$d"/*.sh
  mkrepo "$r"
  ( cd "$r" && echo a > a.txt && git add -A && git commit -qm base && git branch -M master \
     && echo b > b.txt && git add -A && git commit -qm work && git checkout -q -b feat \
     && write_marker_with "$d/forgeward-write-marker.sh" master "security" ) >/dev/null 2>&1
  printf '%s/forgeward-gate-markers/feat.json' \
    "$(cd "$r" && git rev-parse --path-format=absolute --git-common-dir)"
}
# Asserts the marker still authorizes truthfully: passed stays true, the diff hash is the
# one the script computed rather than one the probe supplied, and provenance is recorded
# as unavailable rather than silently forged.
notforged() { # notforged <marker-path> <string-that-must-not-appear>
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d["passed"] is True
         and sys.argv[2] not in d.get("diff_hash","")
         and d["environment"]=={"probe":"unavailable"} else 1)
PY
}

# E16: the review's proof-of-concept verbatim. Every character is in the old allowlist,
# it begins `{` and ends `}`, and splicing it yields a syntactically VALID marker whose
# second `diff_hash` and second `passed` win.
E16M="$(fakeprobe dup '{"a":"b"},"diff_hash":"FORGEDHASH","passed":false,"z":{}')"
[ -f "$E16M" ] && notforged "$E16M" FORGEDHASH \
  && ok "env: a duplicate-key splice from the probe is rejected; passed and diff_hash stand" \
  || nok "env E16" "marker '$E16M'"

# E17: the same attack through the OTHER end. Here the payload OPENS with the probe's
# genuine, fully-conformant output and appends the forgery, so it survives any check that
# is anchored only at the start — which is precisely what dropping the trailing `$` from
# the shape regex would produce. Pinned separately from E16 because that single-character
# regression is invisible to E16 and to every other assertion in this file.
#
# THE PREFIX IS DERIVED, NOT TYPED, and that is the whole of this block. E17 exercises the
# trailing anchor only while its opening bytes are a shape `_env_ok` would otherwise
# accept, so a payload that has fallen behind the probe is refused on its PREFIX instead
# and dropping the `$` stops turning it red. That was a live hazard twice — `seo_posture`
# in 0.9.0 and `config_warnings` in 0.13.0 each had to be hand-copied here — and mutation
# confirmed both times that the stale string leaves the whole suite green while the current
# one reddens. A forgotten copy retired a security assertion and reddened NOTHING, which
# made it the one leg of the probe-field obligation with no signal at all. Deriving the
# prefix from $E1J (the live probe, every root neutralised, captured at E1) deletes the
# hand-copy rather than restating the warning: a new field lands here the moment the probe
# emits it, so the payload cannot go stale and the leg is closed by construction.
#
# WHAT THIS DOES NOT COVER, stated so the derivation is not read as more than it is: it
# cannot see `_env_ok` falling behind the probe. In that direction the derived prefix is
# refused, the marker degrades to {"probe":"unavailable"}, and E17 goes green for the wrong
# reason. E10 is what reddens there — it runs the real probe through the real writer and
# requires the marker's environment to carry probe keys — so the two cover opposite
# directions and neither is sufficient alone. Do not "simplify" either into the other.
#
# The `case` is the emptiness floor this repo requires of any derived assertion (an
# assertion built on a value that can be empty asserts a property of nothing). If $E1J is
# empty or is not a probe line, E17 must go RED rather than splice a nonsense payload and
# pass on it — a broken probe would otherwise green the very assertion this block exists
# to make.
E17P="$E1J"
case "$E17P" in
  '{"gstack_ship":'*'}') ;;
  *) E17P="" ;;
esac
E17M="$(fakeprobe tail "$E17P"',"diff_hash":"TAILFORGE","passed":false,"z":{}')"
[ -n "$E17P" ] && [ -f "$E17M" ] && notforged "$E17M" TAILFORGE \
  && ok "env: a valid-prefix-plus-appendix splice is rejected (the shape match is anchored at BOTH ends)" \
  || nok "env E17" "marker '$E17M'"

# E18: a CRLF config parses identically to an LF one. Not a security case — a regression
# guard for a class this repo has already shipped twice. 0.7.6 fixed `marker_get` reading
# a trailing CR off the marker's `base`, which made a FRESH marker read as stale on
# Windows; the same shape reaches here through `.forgeward/config.yml`, which a Windows
# checkout with `core.autocrlf=true` will hand to awk with `\r` on every line.
#
# It currently works, and the reason is worth pinning rather than trusting: `\r` is in
# `[[:space:]]`, so the section header matches `standalone:\r` and the trailing-strip
# removes the CR before the charset test. That is load-bearing and entirely implicit — an
# edit that tightened either pattern to a literal space or `[ \t]` would drop every
# substitute a Windows user configured, and the failure is SILENT in the worst way: the
# config reads `present` with an empty list, which is indistinguishable from "the user
# configured nothing" and looks exactly like working software.
mkdir -p "$ER/.forgeward"
printf 'standalone:\r\n  substitutes:\r\n    - quality\r\n    - deep-audit\r\n' > "$ER/.forgeward/config.yml"
E18J="$(envprobe "$EMPTY_CFG")"
[ "$(jfield "$E18J" config)" = present ] && [ "$(jfield "$E18J" substitutes)" = "quality,deep-audit" ] \
  && ok "env: a CRLF config parses identically to LF (no CR reaches the marker, none dropped)" \
  || nok "env E18" "got '$E18J'"
rmcfg

# --- E19..E26: the shapes 0.9.0 added ------------------------------------------
# Two documented keys were prose the reader never looked at (`seo.posture`, `seo.routes`)
# and two ordinary YAML spellings read as "nothing configured" (flow sequences, quoted
# scalars). E19..E21 pin what now parses, E22..E26 pin what must NOT change while it does.
# `seo.routes` is deliberately still unread and there is no assertion for it here — a test
# would be asserting the absence of a feature the docs now say is absent.

# E19: a flow sequence is EQUIVALENT to the block form, not merely non-empty. Asserted
# against E4's exact expected value so the two spellings cannot drift apart.
mkcfg 'standalone:
  substitutes: [quality, deep-audit]'
E19J="$(envprobe "$EMPTY_CFG")"
[ "$(jfield "$E19J" config)" = present ] && [ "$(jfield "$E19J" substitutes)" = "quality,deep-audit" ] \
  && ok "env: a flow sequence parses to the same CSV as the equivalent block list" \
  || nok "env E19" "got '$E19J'"

# E20: simply-quoted scalars, both quote characters, both list spellings. The apostrophe
# is the interesting half: the reader gets it via `awk -v sq=`, because writing it inside
# the single-quoted awk program would end the quote and the usual workaround (`"\047"`)
# leans on octal escapes not every awk implements.
mkcfg "standalone:
  substitutes:
    - \"quality\"
    - 'deep-audit'"
E20J="$(envprobe "$EMPTY_CFG")"
mkcfg "standalone:
  substitutes: [\"quality\", 'deep-audit']"
E20F="$(envprobe "$EMPTY_CFG")"
[ "$(jfield "$E20J" substitutes)" = "quality,deep-audit" ] \
  && [ "$(jfield "$E20F" substitutes)" = "quality,deep-audit" ] \
  && ok "env: double- and single-quoted scalars unquote in both the block and flow forms" \
  || nok "env E20" "block '$E20J' flow '$E20F'"

# E21: `seo.posture` is read at all — the half of this lane that was pure prose. Quoted
# and bare must agree, since a user copying the value out of the posture table will write
# it either way.
mkcfg 'seo:
  posture: private-shareable'
E21A="$(envprobe "$EMPTY_CFG")"
mkcfg 'seo:
  posture: "private-closed"'
E21B="$(envprobe "$EMPTY_CFG")"
[ "$(jfield "$E21A" seo_posture)" = private-shareable ] \
  && [ "$(jfield "$E21B" seo_posture)" = private-closed ] \
  && ok "env: seo.posture is read, bare and quoted alike" \
  || nok "env E21" "bare '$E21A' quoted '$E21B'"

# E22: the posture is an ENUM, compared as whole strings, not a charset. A value the
# reviewers have no ruleset for must read as "not pinned" so classification falls back to
# detection — never reach a reviewer that would then act on it. The `substitutes` clause is
# the positive control: without it, a reader that silently failed on the whole file would
# also produce an empty posture and green this.
mkcfg 'standalone:
  substitutes: [quality]
seo:
  posture: totally-made-up'
E22J="$(envprobe "$EMPTY_CFG")"
[ -z "$(jfield "$E22J" seo_posture)" ] && [ "$(jfield "$E22J" substitutes)" = "quality" ] \
  && ok "env: an unrecognised posture is dropped, and the rest of the config still parses" \
  || nok "env E22" "got '$E22J'"

# E23: E7 for the other key. A `posture:` under a different top-level key must not be
# adopted, or any repo with an unrelated `posture` field silently pins the SEO ruleset.
mkcfg 'other:
  posture: private-closed'
E23J="$(envprobe "$EMPTY_CFG")"
[ -z "$(jfield "$E23J" seo_posture)" ] \
  && ok "env: a posture under a DIFFERENT top-level key is not adopted" \
  || nok "env E23" "got '$E23J'"

# E24: the two values come back from awk on one line separated by `|`, so a `|` reaching
# either value would shift the split and hand the posture field whatever followed it. It
# cannot: the substitute charset excludes `|` and the posture is enum-compared. Asserted
# through BOTH fields, because a shifted split is only visible in the second one.
mkcfg 'standalone:
  substitutes:
    - a|b
    - quality
seo:
  posture: private-closed'
E24J="$(envprobe "$EMPTY_CFG")"
[ "$(jfield "$E24J" substitutes)" = "quality" ] && [ "$(jfield "$E24J" seo_posture)" = private-closed ] \
  && ok "env: a '|' in config content cannot shift the field separator" \
  || nok "env E24" "got '$E24J'"

# E25: the 32-item cap is SHARED, so the new spelling cannot buy a bigger budget than the
# one E15 pins. Counted by commas for the same reason E15 is: the assertion should not
# restate the cap's arithmetic in a second place.
E25L="standalone:
  substitutes: ["
i=1; while [ "$i" -le 40 ]; do E25L="$E25L axis$i,"; i=$((i+1)); done
mkcfg "${E25L%,}]"
E25J="$(envprobe "$EMPTY_CFG")"
E25N="$(jfield "$E25J" substitutes | tr ',' '\n' | grep -c .)"
[ "$E25N" = 32 ] \
  && ok "env: a 40-item FLOW sequence is truncated to the same 32-item cap as a block list" \
  || nok "env E25" "got $E25N items from '$E25J'"

# E26: E18's CRLF guard extended to the shapes added here, and for the same reason — the
# failure is silent and looks exactly like working software. The flow sequence survives
# because the closing-bracket strip is anchored at end-of-line through `[[:space:]]*`, and
# the posture because its trailing strip is; tighten either to a literal space and every
# Windows checkout loses its config with no error anywhere.
mkdir -p "$ER/.forgeward"
printf 'standalone:\r\n  substitutes: [quality, "deep-audit"]\r\nseo:\r\n  posture: private-shareable\r\n' \
  > "$ER/.forgeward/config.yml"
E26J="$(envprobe "$EMPTY_CFG")"
[ "$(jfield "$E26J" substitutes)" = "quality,deep-audit" ] \
  && [ "$(jfield "$E26J" seo_posture)" = private-shareable ] \
  && ok "env: a CRLF config parses identically to LF for the flow and posture shapes too" \
  || nok "env E26" "got '$E26J'"

# E27: awk EXITING 0 is not awk WORKING, which is the distinction that cost 0.7.3 and
# 0.7.6. The END block always prints the `|` separator, so output without one means
# something other than this program produced it — an awk that reports success while
# emitting nothing usable. That must read UNREADABLE (disclose), never present-with-an-
# empty-list, which is indistinguishable from "the user configured nothing".
#
# The second clause is the positive control and is load-bearing: `unreadable` is also what
# a config the reader genuinely cannot open produces, so without proving the SAME config
# parses under the real awk this assertion would green on a merely-broken fixture.
mkcfg 'standalone:
  substitutes:
    - quality'
E27OK="$(envprobe "$EMPTY_CFG")"
E27SHIM="$TMP/awkshim-e27"; mkdir -p "$E27SHIM"
printf '#!/bin/sh\nprintf "no separator here\\n"\nexit 0\n' > "$E27SHIM/awk"; chmod +x "$E27SHIM/awk"
E27J="$( cd "$ER" && PATH="$E27SHIM:$PATH" CLAUDE_CONFIG_DIR="$EMPTY_CFG" "$ENV_SH" 2>/dev/null )"
[ "$(jfield "$E27J" config)" = unreadable ] && [ -z "$(jfield "$E27J" substitutes)" ] \
  && [ "$(jfield "$E27OK" substitutes)" = "quality" ] \
  && ok "env: an awk that exits 0 without the field separator reads UNREADABLE, not empty" \
  || nok "env E27" "shimmed '$E27J' real '$E27OK'"
rmcfg

# --- E28..E37: config_warnings, the count of settings read and discarded ---------
# Everything E1..E27 pins is about what the reader HONOURS. This block is about what it
# throws away, which until 0.13.0 it did in total silence — a typo'd key produced byte-
# identical output to no config at all, so the user had no way to tell a config that was
# read and understood from one that was read and discarded.
#
# THE VACUITY TRAP HERE RUNS THE OTHER WAY from E1/E2's, and E28 is the control that
# catches it. Nine of the ten assertions below want a NON-ZERO count, so a counter wired
# to return a constant 1 would green all nine while being useless. E28 is the only one
# asserting 0 on a config that is fully honoured; without it, "warns on a typo" would be
# indistinguishable from "warns always", which is the same disclosure-fatigue failure the
# gate's own "say it once, and only when it is news" rule exists to prevent.
#
# Read as a pair with E34, which is the other half: E28 proves 0 is reachable on a config
# that uses everything, E34 proves 0 survives a key that is documented as unhonoured. A
# counter that fired on `seo.routes` would be *correct* about the mechanism and *wrong*
# about the product, because README, skills/gate/SKILL.md and agents/seo-reviewer.md all
# already tell that user the key has no effect.
jnum() { # jnum <json> <key> -> value of an UNQUOTED numeric field
  printf '%s' "$1" | sed -n 's/.*"'"$2"'":\([0-9]*\).*/\1/p'
}

# E28: THE POSITIVE CONTROL. Every honoured shape at once, nothing discarded -> 0.
mkcfg 'standalone:
  substitutes: [quality, deep-audit]
seo:
  posture: private-shareable'
E28J="$(envprobe "$EMPTY_CFG")"
[ "$(jnum "$E28J" config_warnings)" = 0 ] \
  && [ "$(jfield "$E28J" substitutes)" = "quality,deep-audit" ] \
  && [ "$(jfield "$E28J" seo_posture)" = private-shareable ] \
  && ok "env: a fully-honoured config warns ZERO (the counter is not stuck on)" \
  || nok "env E28" "got '$E28J'"

# E29: the entry's own first example. A misspelled key under `standalone:` used to be
# byte-identical to no config; the second clause pins that it is still not HONOURED, so
# this is a visibility change and not a parsing one.
mkcfg 'standalone:
  substitues:
    - quality'
E29J="$(envprobe "$EMPTY_CFG")"
[ "$(jnum "$E29J" config_warnings)" = 1 ] && [ -z "$(jfield "$E29J" substitutes)" ] \
  && ok "env: a typo'd key under standalone warns once and is still not honoured" \
  || nok "env E29" "got '$E29J'"

# E30: the same class one level over, under `seo:`. Kept separate from E29 rather than
# folded in: the two sections are tracked by different state, and a counter wired only
# into the `standalone:` branch would pass E29 while missing every `seo:` typo.
mkcfg 'seo:
  postures: private-shareable'
E30J="$(envprobe "$EMPTY_CFG")"
[ "$(jnum "$E30J" config_warnings)" = 1 ] && [ -z "$(jfield "$E30J" seo_posture)" ] \
  && ok "env: a typo'd key under seo warns once and is still not honoured" \
  || nok "env E30" "got '$E30J'"

# E31: an invalid VALUE, not an invalid key — the other half of E22, which pins that such
# a posture is dropped. It stays dropped; it is now also counted.
mkcfg 'seo:
  posture: private_shareable'
E31J="$(envprobe "$EMPTY_CFG")"
[ "$(jnum "$E31J" config_warnings)" = 1 ] && [ -z "$(jfield "$E31J" seo_posture)" ] \
  && ok "env: a posture outside the six literals warns once and is still dropped" \
  || nok "env E31" "got '$E31J'"

# E32: the shape the reader's header calls out by name. An unterminated flow sequence
# matches neither the flow rule (which requires the closing bracket) nor the block header,
# so it reaches the counter as an unrecognised key under `standalone:` — which is the
# right answer for the user even though the mechanism is incidental.
mkcfg 'standalone:
  substitutes: [quality, deep-audit'
E32J="$(envprobe "$EMPTY_CFG")"
[ "$(jnum "$E32J" config_warnings)" = 1 ] && [ -z "$(jfield "$E32J" substitutes)" ] \
  && ok "env: an unterminated flow sequence warns once and adopts nothing" \
  || nok "env E32" "got '$E32J'"

# E33: a typo in a TOP-LEVEL key. Pairs with E7, which pins that such a section's list is
# not adopted — the count is what tells the user WHY nothing was adopted. Exactly one, not
# two: the indented `substitutes:` beneath it is inside no tracked section and is not a
# discarded setting, it is a line belonging to a key that does not exist.
mkcfg 'standlaone:
  substitutes:
    - quality'
E33J="$(envprobe "$EMPTY_CFG")"
[ "$(jnum "$E33J" config_warnings)" = 1 ] && [ -z "$(jfield "$E33J" substitutes)" ] \
  && ok "env: an unknown top-level key warns ONCE, not once per line beneath it" \
  || nok "env E33" "got '$E33J'"

# E34: THE MUST-NOT-FIRE CASE, and the reason the counter looks at indentation at all.
# `seo.routes` is documented in three shipped files as having no effect, so a repo that
# pins it followed the docs and must not be nagged. Its whole subtree is skipped by
# indent. The second clause is load-bearing: a `skip` that never released would also
# produce zero warnings while swallowing the `posture:` line after it.
mkcfg 'seo:
  routes:
    "/blog/*": public-indexed
    "/app/*": private-closed
  posture: private-closed'
E34J="$(envprobe "$EMPTY_CFG")"
[ "$(jnum "$E34J" config_warnings)" = 0 ] \
  && [ "$(jfield "$E34J" seo_posture)" = private-closed ] \
  && ok "env: seo.routes and its subtree warn ZERO, and the posture after it is still read" \
  || nok "env E34" "got '$E34J'"

# E34b: `pentest:` is owned by the on-demand runtime skill, not by this probe. It is
# still a known top-level section, so the gate must neither adopt its values nor call
# them discarded. The following standalone section proves the skip does not swallow a
# later gate-owned key.
mkcfg 'pentest:
  image: app:test
  command: npm run dev
  port: 3000
  health_path: /health
standalone:
  substitutes: [deep-audit]'
E34BJ="$(envprobe "$EMPTY_CFG")"
[ "$(jnum "$E34BJ" config_warnings)" = 0 ] \
  && [ "$(jfield "$E34BJ" substitutes)" = deep-audit ] \
  && ok "env: the skill-owned pentest subtree warns ZERO and does not swallow later gate config" \
  || nok "env E34b" "got '$E34BJ'"

# E35: the item-level bounds E14/E15 pin are counted PER ITEM, not once for the list —
# 40 items against a 32-item cap is 8 discarded settings. Written as the arithmetic of the
# other two caps rather than a bare 8 so this does not become a third place stating 32.
{ printf '%s\n' 'standalone:' '  substitutes:'
  i=1; while [ "$i" -le 40 ]; do printf '    - axis%s\n' "$i"; i=$((i+1)); done
} > "$ER/.forgeward/config.yml"
E35J="$(envprobe "$EMPTY_CFG")"
E35N="$(jfield "$E35J" substitutes | tr ',' '\n' | grep -c .)"
[ "$(jnum "$E35J" config_warnings)" = "$((40 - E35N))" ] && [ "$E35N" = 32 ] \
  && ok "env: items dropped by the 32-item cap are counted one apiece" \
  || nok "env E35" "got '$E35J'"

# E36: the count is bounded like every other value that reaches the marker. The 64KB size
# cap upstream still admits a file with thousands of junk lines, and this field is read on
# every push. 999 is the cap; a file with more warnings than that reports 999 and not a
# truncation flag, because a config in that state has a problem the exact number does not
# sharpen. Also guards the marker's `[0-9][0-9]?[0-9]?` arm, which a 4-digit count fails.
{ i=1; while [ "$i" -le 1010 ]; do printf 'junk%s:\n' "$i"; i=$((i+1)); done; } \
  > "$ER/.forgeward/config.yml"
E36J="$(envprobe "$EMPTY_CFG")"
[ "$(jnum "$E36J" config_warnings)" = 999 ] \
  && ok "env: the warning count is capped at 999 so the marker's digit bound cannot overflow" \
  || nok "env E36" "got '$E36J'"
rmcfg

# E37: the field survives into the marker AS A NUMBER. E10 proves the environment object
# round-trips; this proves the one non-string field is not quoted along the way, because
# `_env_ok` matches it unquoted and a probe that quoted it would degrade every marker to
# `probe: unavailable` — the silent failure the coupling comment above warns about.
E37R="$TMP/env-marker-warn"; mkrepo "$E37R"
mkdir -p "$E37R/.forgeward"
printf '%s\n' 'standalone:' '  substitues:' '    - quality' > "$E37R/.forgeward/config.yml"
( cd "$E37R" && echo a > a.txt && git add -A && git commit -qm base && git branch -M master \
   && git checkout -q -b feat && echo b > b.txt && git add -A && git commit -qm work \
   && CLAUDE_CONFIG_DIR="$EMPTY_CFG" write_marker_with "$PLUGIN/scripts/forgeward-write-marker.sh" master "security" \
) >/dev/null 2>&1
E37J="$(cd "$E37R" && git rev-parse --path-format=absolute --git-common-dir)/forgeward-gate-markers/feat.json"
[ -f "$E37J" ] \
  && python3 -I -c 'import json,sys; e=json.load(open(sys.argv[1]))["environment"]; sys.exit(0 if e.get("config_warnings")==1 and isinstance(e["config_warnings"],int) and not isinstance(e["config_warnings"],bool) else 1)' "$E37J" \
  && ok "env: config_warnings reaches the marker as a JSON number, not a quoted string" \
  || nok "env E37" "marker '$E37J'"

# =============================================================================
# R1..R7 — the ported quality rubrics' drift check.
#
# forgeward's ported reviewers (the five quality reviewers and `targeted`) are PORTS of gstack's Review Army specialist
# checklists, not runtime reads of them, so the axis works on a machine with no gstack
# at all. The cost of a port is drift: gstack can improve a checklist and nothing here
# would know. `forgeward-rubric-drift.sh` is the cheap closing of that loop — a handful of
# sha256 comparisons against files already on disk.
#
# THE VACUITY TRAP is the mirror image of E2's. This script's failure mode is not
# "reports drift that is not there", it is "prints nothing", and printing nothing is
# also what a correct clean run does AND what a machine with no gstack does. So every
# assertion below drives a SYNTHETIC gstack root through FORGEWARD_GSTACK_ROOT and
# controls the content on both sides: the real gstack on this machine is deliberately
# not used as a fixture, because whether it currently matches is upstream's business
# and a suite that asserted it would go red the day gstack shipped an improvement —
# which is the event the script exists to REPORT, not to fail on.
#
# The script derives its agents directory from its own location, so the fixture is a
# whole miniature plugin root rather than an env override. R6 is the floor that keeps
# the synthetic fixtures honest about the real one.
# =============================================================================

DRIFT_SRC="$PLUGIN/scripts/forgeward-rubric-drift.sh"
DP="$TMP/driftplugin"
mkdir -p "$DP/scripts" "$DP/agents"
cp "$DRIFT_SRC" "$DP/scripts/forgeward-rubric-drift.sh"
chmod +x "$DP/scripts/forgeward-rubric-drift.sh"
DGS="$TMP/driftgstack"
mkdir -p "$DGS/review/specialists"
printf 'Alpha checklist, v1.\n' > "$DGS/review/specialists/alpha.md"
ALPHA_SHA="$(sha256sum "$DGS/review/specialists/alpha.md" | cut -d' ' -f1)"
{ printf -- '---\nname: alpha-reviewer\n---\n\n'
  printf '<!-- PORTED RUBRIC\n     source-path:   review/specialists/alpha.md\n'
  printf '     source-sha256: %s\n-->\n\nBody.\n' "$ALPHA_SHA"
} > "$DP/agents/alpha-reviewer.md"
drift() { # drift [--verbose] -> stdout+stderr, with the synthetic gstack root
  FORGEWARD_GSTACK_ROOT="$DGS" "$DP/scripts/forgeward-rubric-drift.sh" ${1:+"$1"} 2>&1
}

# _strict_provenance <name-mode> <file>... -> sets _sp_n and _sp_bad
#
# The suite's own STRICT reader of a provenance block, deliberately not the script's
# tolerant one. R6 and R14d are its only callers and they held byte-identical copies of
# it until this change; the copies differed in nothing but how a half-recorded port is
# NAMED -- a reviewer by its filename, a skill by its directory, because every skill's
# basename is the constant string `SKILL.md` (the directory-key rule in CLAUDE.md).
# `<name-mode>` is `dir` for the second and anything else for the first.
#
# Read R6's comment before touching the regexes: their strictness is the point, and the
# fact that they are NOT the script's is what makes R14j a control rather than a
# tautology.
_strict_provenance() {
  _sp_mode="$1"; shift
  _sp_n=0; _sp_bad=""
  for _spf in "$@"; do
    [ -f "$_spf" ] || continue
    _sp_p="$(sed -n 's/^ *source-path: *\(.*[^ ]\) *$/\1/p' "$_spf" | head -1)"
    _sp_s="$(sed -n 's/^ *source-sha256: *\([0-9a-f]\{64\}\) *$/\1/p' "$_spf" | head -1)"
    if [ -n "$_sp_p" ] && [ -n "$_sp_s" ]; then
      _sp_n=$((_sp_n+1))
    elif [ -n "$_sp_p" ] || [ -n "$_sp_s" ]; then
      case "$_sp_mode" in
        dir) _sp_bad="$_sp_bad $(basename "$(dirname "$_spf")")" ;;
        *)   _sp_bad="$_sp_bad $(basename "$_spf")" ;;
      esac
    fi
  done
  return 0
}

# R1: THE CLEAN RUN IS SILENT. A gate that already prints a firing decision must not
# grow a line saying nothing happened — "say it once, and only when it is news" is the
# same rule the axis disclosures follow, and a check that speaks on every run is a check
# that gets ignored on the run that matters.
_r1="$(drift)"; _r1rc=$?
[ -z "$_r1" ] && [ "$_r1rc" -eq 0 ] \
  && ok "drift: a matching rubric prints NOTHING and exits 0 (news only)" \
  || nok "drift R1: the clean path is not silent" "rc=$_r1rc out='$_r1'"

# R2: THE POSITIVE CONTROL for R1, and the reason R1 is not vacuous. Same fixture,
# --verbose, and it must name the reviewer it checked and count it. Without this, a
# script that exited before comparing anything would green R1.
_r2="$(drift --verbose)"
case "$_r2" in
  *"ok       alpha-reviewer"*"1 ported rubric(s) parsed, 1 checked"*)
    ok "drift: --verbose names the rubric it compared and counts it (R1 is not vacuous)" ;;
  *) nok "drift R2: the clean path proves nothing" "out='$_r2'" ;;
esac

# R3: upstream CHANGED the file -> reported by name, and still exit 0. The exit status
# is the assertion that matters as much as the message: this is informational, it runs
# inside a gate, and a non-zero status from an advisory check is how a gate acquires a
# failure mode nobody asked for.
printf 'Alpha checklist, v2 — a new category was added.\n' > "$DGS/review/specialists/alpha.md"
_r3="$(drift)"; _r3rc=$?
case "$_r3" in
  *"have drifted"*"alpha-reviewer"*)
    [ "$_r3rc" -eq 0 ] \
      && ok "drift: an upstream edit is reported by name and the script still exits 0" \
      || nok "drift R3: reported the drift but exited $_r3rc" "advisory checks must not fail a gate" ;;
  *) nok "drift R3: an upstream edit went unreported" "out='$_r3'" ;;
esac

# R4: upstream REMOVED the file -> a DIFFERENT message from R3, not the same one. The
# two need distinguishing because the actions differ: drift means read a diff and
# re-port, missing means upstream renamed or dropped the rubric and drift can no longer
# be checked for it at all. Collapsing them would send the reader looking for a diff
# that does not exist.
rm -f "$DGS/review/specialists/alpha.md"
_r4="$(drift)"; _r4rc=$?
case "$_r4" in
  *"no longer exist"*"alpha-reviewer"*)
    [ "$_r4rc" -eq 0 ] && case "$_r4" in
      *"have drifted"*) nok "drift R4: a missing file is also reported as drifted" "out='$_r4'" ;;
      *) ok "drift: a rubric deleted upstream gets its own message, distinct from drift" ;;
    esac || nok "drift R4: exited $_r4rc" "out='$_r4'" ;;
  *) nok "drift R4: a rubric deleted upstream went unreported" "out='$_r4'" ;;
esac

# R5: NO GSTACK AT ALL -> silent, exit 0, and --verbose says WHY. This is the machine
# the port exists to serve, and it must not be nagged about a tool it deliberately does
# not have. It is also the script's one real ambiguity, stated as a LIMITATION in its own
# header: silence means "no drift" OR "nothing to compare", and only --verbose separates
# them. Pinned in both directions so a future edit cannot make the quiet path chatty or
# the verbose path uninformative.
_r5q="$(FORGEWARD_GSTACK_ROOT="$TMP/no-such-gstack" "$DP/scripts/forgeward-rubric-drift.sh" 2>&1)"; _r5rc=$?
_r5v="$(FORGEWARD_GSTACK_ROOT="$TMP/no-such-gstack" "$DP/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"
case "$_r5v" in
  *"no gstack rubrics at"*"nothing to compare"*)
    [ -z "$_r5q" ] && [ "$_r5rc" -eq 0 ] \
      && ok "drift: a machine with no gstack is silent and exits 0, and --verbose says why (silence has two causes)" \
      || nok "drift R5: the no-gstack path is not silent" "rc=$_r5rc out='$_r5q'" ;;
  *) nok "drift R5: --verbose cannot distinguish no-gstack from no-drift" "out='$_r5v'" ;;
esac

# R6: THE FLOOR for the `agents/` half, and one of the two assertions here that touch the
# shipped tree (R14d is the same instrument for `skills/`). Everything above runs on a
# synthetic fixture, so all six would pass unchanged if the real `agents/` directory
# carried no provenance blocks at all and the drift check covered nothing. This counts
# the real ported rubrics and requires at least six: the five quality reviewers and `targeted` — and it requires
# BOTH fields, because the script skips any reviewer missing either one and a
# half-recorded port is silently unchecked rather than loudly broken.
#
# THE COPY OF THE SCRIPT'S REGEXES STAYS, AND TODOS.md ASKED FOR IT TO GO. The entry
# (0.17.0) filed the duplication as accepted-with-exposure and named the proper fix as
# "factoring the provenance reader into something both can source". That fix is now
# REJECTED, on evidence that did not exist when it was written. R14j landed at 0.20.0
# and closes the exposure the entry names: it runs the real script over this same
# shipped tree and requires it to parse exactly the number R6 and R14d count between
# them, so a loosening of the script's regex reddens R14j today. Sourcing the script's
# reader here would make R14j compare the script's reader with itself -- a control
# turned into a tautology, REMOVING the coverage the entry wanted added. Two
# independent readers agreeing on the shipped tree is the property; one reader used
# twice is not, however much less duplicated code it is.
#
# What WAS genuinely duplicated is now factored out: R6 and R14d held byte-identical
# loops differing only in how a half-recorded port is named. `_strict_provenance` above
# is that one copy. The number of readers in play is unchanged at two -- the script's
# tolerant one and this strict one -- which is the number the property needs.
#
# Keep the copy strict on purpose -- what SHIPS should be canonical even where the
# reader tolerates what a checkout does to it on the way in. And keep it fixture-free:
# every other assertion here drives a synthetic fixture, so R6 and R14d have to read the
# SHIPPED tree with nothing in the path at all. Running the script over the real
# agents/ would need a synthetic gstack root holding copies of the real rubrics,
# which reintroduces exactly the fixture dependence they exist to escape.
_strict_provenance file "$PLUGIN"/agents/*-reviewer.md
_r6n="$_sp_n"; _r6bad="$_sp_bad"
[ "$_r6n" -ge 6 ] && [ -z "$_r6bad" ] \
  && ok "drift: all $_r6n shipped ported rubrics record BOTH source-path and a 64-hex source-sha256 (the fixtures above are not the only thing covered)" \
  || nok "drift R6: a ported rubric is not drift-checkable" "complete: $_r6n (expected >= 6) | half-recorded:${_r6bad:- none}"

# R6b: THIRD-PARTY-LICENSES.md names the same port commit as each rubric's own header. A
# re-port updates `source-commit` because the header comment says to, and the licence
# table is the one other place that names the commit. Nothing read it, so a re-port could
# leave the table pointing at the old commit indefinitely. The expected commit is DERIVED
# from each agent's header, never copied here, and the floor keeps an empty extraction
# from passing. Every file that records a `source-path` is checked, and one with no
# well-formed `source-commit` is a failure rather than a skip; the count must equal R6's,
# so a ported rubric cannot drop out of this check by losing its commit line.
#
# The audit's provenance is a sentence in its own section rather than a table row, so it
# is read separately: the skill's `source-commit` must appear in backticks between the
# `/cso` heading and the next `## `, and an empty commit or an empty section fails.
_r6b_n=0; _r6b_bad=""
for _r6b_f in "$PLUGIN"/agents/*-reviewer.md; do
  grep -q '^ *source-path:' "$_r6b_f" || continue
  _r6b_n=$((_r6b_n+1))
  _r6b_c="$(sed -n 's/^ *source-commit: *\([0-9a-f]\{40\}\) *$/\1/p' "$_r6b_f" | head -1)"
  if [ -z "$_r6b_c" ]; then
    _r6b_bad="$_r6b_bad $(basename "$_r6b_f")(no 40-hex source-commit)"
    continue
  fi
  _r6b_row="$(grep -F "| \`agents/$(basename "$_r6b_f")\` |" "$PLUGIN/THIRD-PARTY-LICENSES.md")"
  case "$_r6b_row" in
    *"\`$_r6b_c\`"*) ;;
    *) _r6b_bad="$_r6b_bad $(basename "$_r6b_f")" ;;
  esac
done
_r6b_ac="$(sed -n 's/^ *source-commit: *\([0-9a-f]\{40\}\) *$/\1/p' "$PLUGIN/skills/audit/SKILL.md" | head -1)"
_r6b_sec="$(awk -v m='## gstack — `/cso` audit phases' 'index($0,m)==1{f=1;next} f&&/^## /{exit} f' "$PLUGIN/THIRD-PARTY-LICENSES.md")"
if [ -z "$_r6b_ac" ]; then
  _r6b_bad="$_r6b_bad audit(no 40-hex source-commit)"
elif [ -z "$_r6b_sec" ]; then
  _r6b_bad="$_r6b_bad audit(no /cso section in THIRD-PARTY-LICENSES.md)"
else
  case "$_r6b_sec" in *"\`$_r6b_ac\`"*) ;; *) _r6b_bad="$_r6b_bad audit" ;; esac
fi
[ "$_r6b_n" -ge 6 ] && [ "$_r6b_n" -eq "$_r6n" ] && [ -z "$_r6b_bad" ] \
  && ok "drift: all $_r6b_n ported rubrics' and the audit's source-commit appear in THIRD-PARTY-LICENSES.md (a re-port cannot leave the licence file on the old commit)" \
  || nok "drift R6b: THIRD-PARTY-LICENSES.md disagrees with a ported file's source-commit" "checked: $_r6b_n (expected >= 6 and = R6's $_r6n) | mismatched:${_r6b_bad:- none}"

# R7: the two sha256 arms agree. CLAUDE.md's rule is one reader per shape and this
# script has two — `sha256sum` and `shasum -a 256` — allowed only because a digest has a
# single correct answer, and allowed only WITH this assertion, which is the condition
# that rule states. It skips loudly rather than passing quietly when the machine has
# only one of the tools, because a skip that reads as a pass is how the `json_get`
# divergence survived.
if command -v sha256sum >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1; then
  _r7f="$TMP/d7-digest-fixture"; printf 'one\ttwo\n\xc3\x28 binary-ish\n' > "$_r7f"
  _r7a="$(sha256sum -- "$_r7f" | cut -d' ' -f1)"
  _r7b="$(shasum -a 256 -- "$_r7f" | cut -d' ' -f1)"
  [ -n "$_r7a" ] && [ "$_r7a" = "$_r7b" ] \
    && ok "drift: sha256sum and shasum -a 256 agree byte-for-byte (the two-arm exception is verified, not assumed)" \
    || nok "drift R7: the two digest arms disagree" "sha256sum='$_r7a' shasum='$_r7b'"
else
  ok "drift: two-arm digest agreement SKIPPED (this machine has only one of sha256sum/shasum) — the arms are unverified here; R1-R5 still exercise whichever one is present"
fi

# R8: THE SECOND DIGEST ARM IS ACTUALLY REACHED. R7 proves the two digest PIPELINES
# agree, but it runs both by hand and never enters the script, so the
# `elif command -v shasum` branch is dead code on every machine that has sha256sum --
# every CI runner this repo uses. A typo in it (`-a256`, a dropped `--`) ships green and
# fails only on the macOS installs the branch exists for. V5's `$NOJQ` already owns this
# technique: build a PATH that hides the preferred tool so the fallback runs end-to-end.
#
# The fixture is restored to its ORIGINAL v1 content and compared against `$ALPHA_SHA`,
# which was computed with `sha256sum` at fixture time. That is the point: re-deriving
# the expected digest with `shasum` would make the test self-consistent and vacuous,
# which is the whole failure mode this block exists to avoid. This way the shasum arm
# has to reproduce the sha256sum arm's answer THROUGH the script or R8 goes red.
# Undo R3's edit and R4's deletion here, OUTSIDE the shasum branch below, so R9-R12
# meet the same fixture on every machine. Inside it, a box without `shasum` would skip
# the restore and leave R10 asserting against a fixture R4 had already deleted.
printf 'Alpha checklist, v1.\n' > "$DGS/review/specialists/alpha.md"
if command -v shasum >/dev/null 2>&1; then
  SHAONLY="$TMP/shasum-only-bin"; mkdir -p "$SHAONLY"
  for t in env bash shasum sed cut basename dirname head grep; do
    p="$(command -v "$t" 2>/dev/null)"; [ -n "$p" ] && ln -sf "$p" "$SHAONLY/$t"
  done
  _r8="$(FORGEWARD_GSTACK_ROOT="$DGS" PATH="$SHAONLY" \
         "$DP/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"; _r8rc=$?
  case "$_r8" in
    *"ok       alpha-reviewer"*"1 ported rubric(s) parsed, 1 checked"*)
      [ "$_r8rc" -eq 0 ] \
        && ok "drift: the shasum arm reproduces the sha256sum digest through the script (the macOS branch is not dead code)" \
        || nok "drift R8: shasum arm exited $_r8rc" "out='$_r8'" ;;
    *) nok "drift R8: the shasum-only arm did not reach a clean comparison" "out='$_r8'" ;;
  esac
else
  ok "drift: shasum arm SKIPPED (no shasum on this machine) — R7 also skips here, so the second arm is unverified, not verified"
fi

# R9: NEITHER DIGEST TOOL. The script's header promises it "says so under --verbose and
# exits 0 rather than reporting a false all-clear". That is a third cause of the silence
# R5 covers, and it was asserted nowhere: a machine with no sha256 tool and a machine
# with no drift printed byte-identical nothing.
NOSHA="$TMP/no-digest-bin"; mkdir -p "$NOSHA"
for t in env bash sed cut basename dirname head grep; do
  p="$(command -v "$t" 2>/dev/null)"; [ -n "$p" ] && ln -sf "$p" "$NOSHA/$t"
done
_r9q="$(FORGEWARD_GSTACK_ROOT="$DGS" PATH="$NOSHA" "$DP/scripts/forgeward-rubric-drift.sh" 2>&1)"; _r9rc=$?
_r9v="$(FORGEWARD_GSTACK_ROOT="$DGS" PATH="$NOSHA" "$DP/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"
case "$_r9v" in
  *"no sha256sum or shasum on PATH"*)
    [ -z "$_r9q" ] && [ "$_r9rc" -eq 0 ] \
      && ok "drift: no digest tool at all is silent, exits 0, and --verbose names the third cause of the silence" \
      || nok "drift R9: the no-digest-tool path is not silent" "rc=$_r9rc out='$_r9q'" ;;
  *) nok "drift R9: --verbose does not say the digest tool is missing" "out='$_r9v'" ;;
esac

# R10: A PROVENANCE BLOCK MISSING EITHER FIELD IS SKIPPED, SILENTLY, AND THAT IS RIGHT.
# Six shipped reviewers are not ports and carry no provenance at all, so "no block" must
# never be news. What R6 guarantees is that a HALF-recorded block cannot ship; this pins
# the runtime half of that split so a future edit cannot start counting one.
printf 'Half checklist.\n' > "$DGS/review/specialists/half.md"
{ printf -- '---\nname: half-reviewer\n---\n\n'
  printf '<!-- PORTED RUBRIC\n     source-path:   review/specialists/half.md\n-->\n'
} > "$DP/agents/half-reviewer.md"
_r10="$(drift --verbose)"
case "$_r10" in
  *"half-reviewer"*) nok "drift R10: a reviewer with no source-sha256 was treated as a port" "out='$_r10'" ;;
  *"1 ported rubric(s) parsed, 1 checked"*)
    ok "drift: a reviewer carrying only one provenance field is skipped and not counted (R6 is what stops it shipping)" ;;
  *) nok "drift R10: unexpected count with a half-recorded reviewer present" "out='$_r10'" ;;
esac
rm -f "$DP/agents/half-reviewer.md" "$DGS/review/specialists/half.md"

# R11: UNSET HOME MUST NOT CRASH THE SCRIPT. `set -u` plus `${VAR:-$HOME/...}` aborts
# with `HOME: unbound variable` and exit 1 when HOME is unset -- `env -i`, some cron and
# systemd units, and minimal CI containers all reach it. The script advertises
# always-exits-0 and skills/gate/SKILL.md calls it from inside a gate run on that basis,
# so the crash turned an advisory check into a failure mode nobody asked for. The
# sibling forgeward-detect-gstack-skill.sh already guarded the identical hazard.
_r11="$(env -u HOME -u FORGEWARD_GSTACK_ROOT bash "$DP/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"; _r11rc=$?
case "$_r11" in
  *"unbound variable"*) nok "drift R11: an unset HOME still crashes the script" "rc=$_r11rc out='$_r11'" ;;
  *) [ "$_r11rc" -eq 0 ] \
       && ok "drift: an unset HOME degrades to 'nothing to compare' and still exits 0" \
       || nok "drift R11: unset HOME exited $_r11rc" "out='$_r11'" ;;
esac

# R12: A `source-path` THAT ESCAPES THE RUBRIC TREE IS REFUSED, LOUDLY. Verified before
# the guard existed: `source-path: ../secret/private.txt` was joined onto the gstack root
# and hashed, and the script reported `ok alpha-reviewer` for a file that is not a
# rubric -- a clean run that means nothing, which is exactly the false all-clear the
# header refuses. This is NOT a security assertion and must not be cited as one: these
# files are committed and reviewed, and whoever can edit one can already rewrite the
# prompt itself. It covers the realistic case, a hand-edited or mis-ported block.
#
# THE FIXTURE'S TRAVERSAL DEPTH IS LOAD-BEARING -- ONE `..`, NOT TWO. `$DGS` is
# `$TMP/driftgstack`, so `../outside/secret.txt` resolves onto the planted file and two
# `..` segments resolve above `$TMP` onto nothing. This shipped with two, and mutation
# testing is the only thing that saw it: strip the guard and the two-dot fixture reports
# `no longer exist` (the missing branch) rather than `ok escape-reviewer`, so R12 went
# `nok` via its catch-all arm for a path-resolution accident instead of demonstrating the
# hazard the paragraph above describes. With one `..` the guarded and unguarded runs
# diverge into `escapes the rubric tree` against `ok       escape-reviewer`, which is the
# assertion actually claimed. Same class as the R6/R8 note: an assertion written beside a
# mechanism inherits its blind spot, and only an outside reader or a mutation sees past
# it. If the fixture nesting is ever moved, re-derive this depth -- do not preserve the
# literal.
#
# AND IT MUST RUN --verbose, FOR THE SAME REASON. The `ok       <name>` line the first
# case arm keys on is printed ONLY under `--verbose`; the `escapes the rubric tree` NOTE
# prints either way. Called bare, arm one is unreachable, so a stripped guard fell through
# to the catch-all and reported "went unreported" -- true, but not the failure that
# happened, and the arm written to name it never ran. R12b next door was already verbose,
# which is why it did not have the defect and why the two now match.
mkdir -p "$TMP/outside"; printf 'not a rubric\n' > "$TMP/outside/secret.txt"
OUT_SHA="$(sha256sum "$TMP/outside/secret.txt" | cut -d' ' -f1)"
{ printf -- '---\nname: escape-reviewer\n---\n\n'
  printf '<!-- PORTED RUBRIC\n     source-path:   ../outside/secret.txt\n'
  printf '     source-sha256: %s\n-->\n' "$OUT_SHA"
} > "$DP/agents/escape-reviewer.md"
_r12="$(drift --verbose)"; _r12rc=$?
case "$_r12" in
  *"ok       escape-reviewer"*) nok "drift R12: a traversing source-path was compared and passed" "out='$_r12'" ;;
  *"escapes the rubric tree"*"escape-reviewer"*)
    [ "$_r12rc" -eq 0 ] \
      && ok "drift: a source-path with a '..' segment is refused by name, not silently skipped, and still exits 0" \
      || nok "drift R12: reported the escape but exited $_r12rc" "out='$_r12'" ;;
  *) nok "drift R12: a traversing source-path went unreported" "out='$_r12'" ;;
esac
# ...and a '..' that is not a whole segment is a legal filename, not an escape.
mv "$TMP/outside/secret.txt" "$DGS/review/specialists/od..d.md"
{ printf -- '---\nname: escape-reviewer\n---\n\n'
  printf '<!-- PORTED RUBRIC\n     source-path:   review/specialists/od..d.md\n'
  printf '     source-sha256: %s\n-->\n' "$OUT_SHA"
} > "$DP/agents/escape-reviewer.md"
case "$(drift --verbose)" in
  *"ok       escape-reviewer"*) ok "drift: '..' inside a filename is not mistaken for a traversal segment" ;;
  *) nok "drift R12b: a legal filename containing '..' was refused" "out='$(drift --verbose)'" ;;
esac
rm -f "$DP/agents/escape-reviewer.md" "$DGS/review/specialists/od..d.md"

# R13: A PLUGIN-INSTALLED GSTACK IS FOUND. Every assertion above drives a synthetic root
# through FORGEWARD_GSTACK_ROOT, which is deliberate — see the vacuity note at the top of
# this block — but it means R1-R12 say nothing at all about how the script finds gstack
# when nobody hands it a path. That was the whole exposure: the lookup was one hardcoded
# `$HOME/.claude/skills/gstack`, so a gstack installed as a PLUGIN produced silence and
# exit 0, byte-identical to a clean run and to a machine with no gstack. Nothing red, no
# drift checked, nobody told. R13 is the only assertion here that exercises the search
# path, so the two globs below cannot be dropped or re-shallowed without a failing test.
#
# Run from "$TMP" rather than the repo, so the project-local `.claude/skills/gstack` root
# is skipped on a checkout that happens to have one and the plugin-cache arm is what is
# actually under test.
DPC="$TMP/driftcfg"
DPC_R="$DPC/plugins/cache/somemarket/gstack/1.2.3/skills/gstack/review/specialists"
mkdir -p "$DPC_R"
printf 'Alpha checklist, v1.\n' > "$DPC_R/alpha.md"
_r13="$(cd "$TMP" && env -u FORGEWARD_GSTACK_ROOT CLAUDE_CONFIG_DIR="$DPC" \
        bash "$DP/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"; _r13rc=$?
case "$_r13" in
  *"ok       alpha-reviewer"*)
    [ "$_r13rc" -eq 0 ] \
      && ok "drift: a gstack under plugins/cache/<market>/<plugin>/<version>/skills is found" \
      || nok "drift R13: found the plugin-cache root but exited $_r13rc" "out='$_r13'" ;;
  *"no gstack rubrics"*)
    nok "drift R13: a plugin-installed gstack went unfound — the false all-clear this script refuses" "out='$_r13'" ;;
  *) nok "drift R13: unexpected output" "out='$_r13'" ;;
esac

# ...and the shallower layout too. Nothing on the author's machine uses it — 0 directories at
# this depth against 14 at the versioned one — so it is searched defensively, not on evidence. Both this script and
# `scripts/forgeward-detect-gstack-skill.sh` search both depths as of 0.18.0; before that the
# sibling searched only the shallow one, which is why a plugin-installed gstack read as absent
# there while being found here. This half is what stops the unused-looking glob being deleted
# as dead.
DPC2="$TMP/driftcfg2"
DPC2_R="$DPC2/plugins/cache/somemarket/gstack/skills/gstack/review/specialists"
mkdir -p "$DPC2_R"
printf 'Alpha checklist, v1.\n' > "$DPC2_R/alpha.md"
_r13b="$(cd "$TMP" && env -u FORGEWARD_GSTACK_ROOT CLAUDE_CONFIG_DIR="$DPC2" \
         bash "$DP/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"
case "$_r13b" in
  *"ok       alpha-reviewer"*) ok "drift: the two-level plugin-cache layout is searched as well as the three-level one" ;;
  *) nok "drift R13b: the two-level plugin-cache layout was not searched" "out='$_r13b'" ;;
esac

# R13c: and the version level must look like a version here too. This script and
# `scripts/forgeward-detect-gstack-skill.sh` must keep agreeing on the glob — they diverged
# once and a plugin-installed gstack went undetected for ten versions — so the `[0-9]*`
# constraint added to the detector at 0.18.0 is pinned on BOTH sides. Mirrors D8f.
DPC3="$TMP/driftcfg3"
DPC3_R="$DPC3/plugins/cache/somemarket/gstack/node_modules/skills/gstack/review/specialists"
mkdir -p "$DPC3_R"
printf 'Alpha checklist, v1.\n' > "$DPC3_R/alpha.md"
_r13c="$(cd "$TMP" && env -u FORGEWARD_GSTACK_ROOT CLAUDE_CONFIG_DIR="$DPC3" \
         bash "$DP/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"
case "$_r13c" in
  *"no gstack rubrics"*) ok "drift: a NON-VERSION third level (node_modules) is not a rubric root" ;;
  *) nok "drift R13c: a bare third-level wildcard is back" "out='$_r13c'" ;;
esac

# ...and an empty CLAUDE_CONFIG_DIR with nothing installed under it still degrades to the
# quiet no-op, rather than to a crash or to a stray unmatched-glob path being hashed.
_r13c="$(cd "$TMP" && env -u FORGEWARD_GSTACK_ROOT CLAUDE_CONFIG_DIR="$TMP/driftcfg-empty" \
         bash "$DP/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"; _r13crc=$?
case "$_r13c" in
  *"no gstack rubrics at any searched root"*"nothing to compare"*)
    [ "$_r13crc" -eq 0 ] \
      && ok "drift: no gstack under any searched root is a quiet no-op that still exits 0" \
      || nok "drift R13c: reported nothing to compare but exited $_r13crc" "out='$_r13c'" ;;
  *) nok "drift R13c: an empty config dir did not degrade cleanly" "rc=$_r13crc out='$_r13c'" ;;
esac

# R14: A PORTED SKILL IS DRIFT-CHECKED, AND IT IS NAMED BY ITS DIRECTORY.
# `skills/audit/` is a port of gstack's /cso audit phases, taken the same way the
# reviewer rubrics were and carrying the same provenance block — but the loop globbed
# `agents/*-reviewer.md` and nothing else, so the largest ported artefact in the repo
# was unchecked while the script printed a confident count of everything it did check.
# That is the false all-clear the header refuses, arriving through the scan's scope
# rather than through its comparison.
#
# THE NAME IS HALF THE ASSERTION, not a cosmetic extra. A skill's basename is the
# constant `SKILL.md`, so a basename-derived key reports `SKILL` — which is not a name,
# and is the SAME key for every skill that is ever ported, so two drifting skills would
# print two identical lines. `*"ok       SKILL"*` is checked explicitly and fails the
# assertion; matching only the positive would go green on the broken naming the day
# someone reintroduces it, since `ok       beta` and `ok       SKILL` are not mutually
# exclusive outputs of a loop that could print both.
#
# Verified to FAIL against the pre-fix script: the skills glob was absent, so the run
# counted one rubric and printed no `beta` line at all, and this assertion went nok via
# its catch-all arm. Cite it as `git show ed4d0ae~1:scripts/forgeward-rubric-drift.sh`
# -- the parent of the commit that added `skills_dir`. This comment read `git show HEAD:`
# "at the time of writing" for four versions, which is honest and unusable: a reader
# following it today gets the FIXED script, reproduces a passing run, and concludes the
# control is a lie. Same trap the R18/R19 banner below names; this file held both the
# warning and an instance of it. Runs --verbose
# for the reason R12 records: the `ok       <name>` line is verbose-only.
mkdir -p "$DGS/cso/sections" "$DP/skills/beta"
printf 'Audit phases, v1.\n' > "$DGS/cso/sections/phases.md"
BETA_SHA="$(sha256sum "$DGS/cso/sections/phases.md" | cut -d' ' -f1)"
{ printf -- '---\nname: beta\n---\n\n'
  printf '<!-- PORTED PHASES\n     source-path:   cso/sections/phases.md\n'
  printf '     source-sha256: %s\n-->\n\nBody.\n' "$BETA_SHA"
} > "$DP/skills/beta/SKILL.md"
_r14="$(drift --verbose)"; _r14rc=$?
case "$_r14" in
  *"ok       SKILL"*) nok "drift R14: a ported skill is keyed by its basename, not its directory" "out='$_r14'" ;;
  *"ok       beta"*"2 ported rubric(s) parsed, 2 checked"*)
    [ "$_r14rc" -eq 0 ] \
      && ok "drift: a ported skills/<name>/SKILL.md is checked and named by its directory" \
      || nok "drift R14: found the skill but exited $_r14rc" "out='$_r14'" ;;
  *) nok "drift R14: skills/*/SKILL.md is not scanned" "out='$_r14'" ;;
esac

# R14f: A DRIFTED SKILL IS NAMED IN THE NOTE BY ITS DIRECTORY, NOT BY ITS BASENAME.
# R14 above pins the verbose `ok` line, and the NOTE is the line a reader actually acts
# on -- it is the script's only unconditional output, so for a user who never passes
# --verbose it is the ENTIRE product. Until this assertion existed the drifted branch was
# unpinned for skills: mutation-proven by rewriting the `drifted=` accumulator's `$name`
# back to `$(basename "$f" .md)`, which left the suite green while every drifting skill
# printed `SKILL`. That is the exact failure R14's own header argues matters, asserted one
# branch away from where it happens.
#
# Negative arm first, for R14's reason: `  SKILL  ` and `  beta  ` are not mutually
# exclusive outputs of a loop that could emit both.
printf 'Audit phases, v2 - a phase was added.\n' > "$DGS/cso/sections/phases.md"
_r14f="$(drift)"; _r14frc=$?
case "$_r14f" in
  *"have drifted"*"  SKILL  "*) nok "drift R14f: a drifted skill is reported as SKILL, not by its directory" "out='$_r14f'" ;;
  *"have drifted"*"  beta  "*)
    [ "$_r14frc" -eq 0 ] \
      && ok "drift: a drifted skill is named by its directory in the NOTE, not by its basename" \
      || nok "drift R14f: reported the skill drift but exited $_r14frc" "out='$_r14f'" ;;
  *) nok "drift R14f: a drifted ported skill went unreported" "out='$_r14f'" ;;
esac
printf 'Audit phases, v1.\n' > "$DGS/cso/sections/phases.md"

# R14g: SO IS A SKILL WHOSE source-path ESCAPES THE TREE. R12 is this assertion for
# `agents/`; the malformed branch derives its key from the same `case` as every other
# branch, so this is the fourth and last of the four exits a skill can take (ok, drifted,
# missing, malformed) and the only one that was still unpinned. It is here because the
# NAMING comment in the script claimed to be "pinned by R14" for exactly this branch and
# R14 does not reach it -- a comment claiming coverage it does not have is the defect,
# not merely the gap it hides.
mkdir -p "$DP/skills/gamma"
{ printf -- '---\nname: gamma\n---\n\n'
  printf '<!-- PORTED PHASES\n     source-path:   ../outside/secret.txt\n'
  printf '     source-sha256: %s\n-->\n\nBody.\n' "$BETA_SHA"
} > "$DP/skills/gamma/SKILL.md"
_r14g="$(drift)"; _r14grc=$?
case "$_r14g" in
  *"escapes the rubric tree"*"  SKILL  "*) nok "drift R14g: a traversing skill is reported as SKILL, not by its directory" "out='$_r14g'" ;;
  *"escapes the rubric tree"*"  gamma  "*)
    [ "$_r14grc" -eq 0 ] \
      && ok "drift: a skill whose source-path escapes the tree is refused loudly and named by its directory" \
      || nok "drift R14g: reported the traversal but exited $_r14grc" "out='$_r14g'" ;;
  *) nok "drift R14g: a traversing ported skill was not refused" "out='$_r14g'" ;;
esac
rm -rf "$DP/skills/gamma"

# R14b: A gstack CHECKOUT IS RECOGNISED BY `cso` AS WELL AS BY `review/specialists`.
# The landmark that qualifies a candidate root was `review/specialists` alone, which is
# where the reviewer rubrics live. The audit phases come from `cso/`, so a checkout
# holding one and not the other read as "not gstack" and the whole run degraded to the
# quiet no-op — silence that means "no drift" to anyone reading it. Drives the root
# through FORGEWARD_GSTACK_ROOT, which still goes through the landmark test.
DGS2="$TMP/driftgstack-cso-only"
mkdir -p "$DGS2/cso/sections"
printf 'Audit phases, v1.\n' > "$DGS2/cso/sections/phases.md"
_r14b="$(FORGEWARD_GSTACK_ROOT="$DGS2" "$DP/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"
case "$_r14b" in
  *"no gstack rubrics"*) nok "drift R14b: a checkout with cso/ but no review/specialists reads as no-gstack" "out='$_r14b'" ;;
  *"ok       beta"*) ok "drift: a gstack checkout is recognised by cso/ as well as by review/specialists" ;;
  *) nok "drift R14b: unexpected output from a cso-only root" "out='$_r14b'" ;;
esac

# R14c: THE FALLBACK PASS IS LANDMARK-MAJOR, NOT CANDIDATE-MAJOR.
# This pins pass 2 of the root scan — the fallback that runs when NO candidate holds
# every landmark. Candidate-major is the shorter way to write it and it is wrong: a
# `cso`-only root that sorts earlier would shadow a `review/specialists` root that sorts
# later, and every reviewer rubric would then report `no longer exist`. Nothing
# else here goes red on that, which is what makes this load-bearing rather than a
# restatement of R14b.
#
# BOTH fixture roots are partial ON PURPOSE, and the word "complete" does not belong to
# this assertion: pass 1 must not fire on either of them, and R14e is where a genuinely
# complete root is tested. Reading this one as covering partial-shadows-complete is how
# that case went unnoticed until 0.20.0 — it is a DIFFERENT pass and a different bug.
#
# `aaa-market` sorts before `zzz-market`, so the cso-only root is the one a candidate-major
# loop would select. The discriminator is which side reports `ok`: the reviewer-rubric root
# has alpha.md and no phases.md, the cso-only root the reverse.
DPC4="$TMP/driftcfg4"
mkdir -p "$DPC4/plugins/cache/aaa-market/gstack/1.0.0/skills/gstack/cso/sections"
mkdir -p "$DPC4/plugins/cache/zzz-market/gstack/1.0.0/skills/gstack/review/specialists"
printf 'Audit phases, v1.\n' > "$DPC4/plugins/cache/aaa-market/gstack/1.0.0/skills/gstack/cso/sections/phases.md"
printf 'Alpha checklist, v1.\n' > "$DPC4/plugins/cache/zzz-market/gstack/1.0.0/skills/gstack/review/specialists/alpha.md"
_r14c="$(cd "$TMP" && env -u FORGEWARD_GSTACK_ROOT CLAUDE_CONFIG_DIR="$DPC4" \
         bash "$DP/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"
case "$_r14c" in
  *"ok       beta"*) nok "drift R14c: a cso-only root shadowed a review/specialists root that sorts later" "out='$_r14c'" ;;
  *"ok       alpha-reviewer"*"no longer exist"*"  beta  "*)
    ok "drift: the fallback pass tries review/specialists across every candidate before cso is tried at all" ;;
  *) nok "drift R14c: neither root was selected" "out='$_r14c'" ;;
esac

# R14e: A CANDIDATE HOLDING EVERY LANDMARK WINS OVER A PARTIAL ONE THAT SORTS EARLIER.
# R14c pins the fallback; this pins the pass that runs BEFORE it, and it exists because
# landmark-major ordering alone is asymmetric. It stops a `cso`-only root shadowing a
# `review/specialists` one — and does nothing at all in the other direction, because pass
# 2 accepts the first candidate holding `review/specialists` and stops there, complete
# checkout on the same machine or not.
#
# That is not a hypothetical ordering: plugin-cache candidates arrive glob-sorted, and a
# marketplace or version directory sorting earlier (`1.10.0` sorts before `1.9.0`) that
# predates `cso/` is an ordinary machine, not a contrived one. Reproduced against the
# pre-fix script: it selected `aaa-market` and printed `no longer exist ... Upstream may
# have renamed or removed them` for `beta` while `zzz-market` held the file one directory
# over. A false claim about upstream is worse than this script's default silence, so the
# FIRST arm below is the negative — matching only the positive would go green on a
# regression that prints the bogus NOTE alongside a correct `ok`.
#
# The discriminator is the ROOT NAME in the summary line, not the ok-count: both roots
# can satisfy alpha-reviewer, and only the complete one can satisfy beta.
#
# R14c's pass arm above carries a FLOOR for the same reason. Its negative discriminator
# (`ok       beta` = the cso-only root won) is reachable only while `$DP/skills/beta`
# exists, and that fixture is built fifty lines earlier and torn down forty lines later;
# delete or reorder either and R14c asserts a property of nothing while still printing
# ok. Requiring the missing-beta line pins the fixture's presence in the same breath, and
# buys the `missing` branch's skill naming as a second effect.
DPC5="$TMP/driftcfg5"
mkdir -p "$DPC5/plugins/cache/aaa-market/gstack/1.0.0/skills/gstack/review/specialists"
mkdir -p "$DPC5/plugins/cache/zzz-market/gstack/1.0.0/skills/gstack/review/specialists"
mkdir -p "$DPC5/plugins/cache/zzz-market/gstack/1.0.0/skills/gstack/cso/sections"
printf 'Alpha checklist, v1.\n' > "$DPC5/plugins/cache/aaa-market/gstack/1.0.0/skills/gstack/review/specialists/alpha.md"
printf 'Alpha checklist, v1.\n' > "$DPC5/plugins/cache/zzz-market/gstack/1.0.0/skills/gstack/review/specialists/alpha.md"
printf 'Audit phases, v1.\n'    > "$DPC5/plugins/cache/zzz-market/gstack/1.0.0/skills/gstack/cso/sections/phases.md"
_r14e="$(cd "$TMP" && env -u FORGEWARD_GSTACK_ROOT CLAUDE_CONFIG_DIR="$DPC5" \
         bash "$DP/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"
case "$_r14e" in
  *"no longer exist"*) nok "drift R14e: a partial root that sorts earlier shadowed a complete gstack checkout" "out='$_r14e'" ;;
  *"ok       alpha-reviewer"*"ok       beta"*"zzz-market"*)
    ok "drift: a candidate holding every landmark wins over a partial one that sorts earlier" ;;
  *) nok "drift R14e: the complete root was not selected" "out='$_r14e'" ;;
esac
# BOTH HALVES of the skills fixture go, not just the plugin one. R10 and R12 remove the
# plugin-side and gstack-side files on the same line and this block broke that convention:
# leaving `$DGS/cso` behind makes the shared synthetic root satisfy BOTH landmarks from
# here on, so any assertion added later via `drift()` silently meets a different root
# shape than R1-R13 did.
rm -rf "$DP/skills" "$DGS/cso"

# R14h: A RUN THAT PARSES NOTHING SAYS SO, UNCONDITIONALLY. This is the assertion that
# makes every OTHER silence in this block mean something. R1 pins that a clean run is
# silent; before the vacuity guard existed, a run that found a gstack checkout and then
# read ZERO ports out of the plugin was silent in exactly the same way, on the same exit
# code, through the same no-argument invocation `skills/gate/SKILL.md` uses. The failure
# is not that a check goes missing -- it is that its absence is indistinguishable from
# its success, which is the false all-clear this whole script exists to refuse.
#
# Runs QUIET on purpose. Every other diagnostic here is verbose-only and the gate never
# passes --verbose, so a verbose-gated guard would be a guard nobody in production sees.
cp "$DP/agents/alpha-reviewer.md" "$TMP/alpha-reviewer.bak"
sed 's/source-sha256:.*/source-sha256: not-a-hash/' "$TMP/alpha-reviewer.bak" > "$DP/agents/alpha-reviewer.md"
_r14h="$(drift)"; _r14hrc=$?
case "$_r14h" in
  *"NO ported rubric could be read"*)
    [ "$_r14hrc" -eq 0 ] \
      && ok "drift: a root found but nothing parsed is reported in QUIET mode, not mistaken for a clean run" \
      || nok "drift R14h: reported the vacuous run but exited $_r14hrc" "out='$_r14h'" ;;
  "") nok "drift R14h: a run that parsed zero rubrics was silent -- indistinguishable from a clean run" "rc=$_r14hrc" ;;
  *) nok "drift R14h: unexpected output for a vacuous run" "out='$_r14h'" ;;
esac

# R14i: THE PROVENANCE READER SURVIVES A CRLF CHECKOUT AND AN UPPERCASE DIGEST. Both were
# reproduced against the strict reader and both parsed ZERO ports out of the entire plugin
# while printing nothing, which is R14h's failure arriving through the regex rather than
# through the path. Neither input is exotic: this repo ships no `.gitattributes`, so a
# clone under Git-for-Windows' default `core.autocrlf=true` produces the first, and
# PowerShell's `Get-FileHash` and GitHub's blob view both emit the second.
#
# One fixture carries BOTH deviations at once. That is deliberate and it is the weaker
# half of the assertion -- it cannot say which tolerance is doing the work, so R14h is
# what stands behind it: whichever one regresses, the run parses nothing and R14h reddens
# by name. Splitting this in two would pin the mechanism more precisely and is not done,
# because the guard that matters is the one that fires on a miss nobody anticipated.
sed -e 's/source-sha256: *\([0-9a-f]*\)/source-sha256: \U\1/' "$TMP/alpha-reviewer.bak" \
  | sed 's/$/\r/' > "$DP/agents/alpha-reviewer.md"
_r14i="$(drift)"; _r14irc=$?
_r14iv="$(drift --verbose)"
case "$_r14i$_r14iv" in
  *"NO ported rubric could be read"*) nok "drift R14i: a CRLF checkout with an uppercase digest parsed zero rubrics" "out='$_r14iv'" ;;
  *"ok       alpha-reviewer"*"1 ported rubric(s) parsed, 1 checked"*)
    [ -z "$_r14i" ] && [ "$_r14irc" -eq 0 ] \
      && ok "drift: a CRLF provenance block with an uppercase source-sha256 is read, compared and reported clean" \
      || nok "drift R14i: parsed it but the quiet path was not clean" "rc=$_r14irc quiet='$_r14i'" ;;
  *) nok "drift R14i: a CRLF/uppercase provenance block did not reach a clean comparison" "out='$_r14iv'" ;;
esac
cp "$TMP/alpha-reviewer.bak" "$DP/agents/alpha-reviewer.md"

# R14l: A SYMLINKED `scripts/` DIRECTORY STILL RESOLVES THE PLUGIN ROOT. Bash's `pwd`
# builtin is LOGICAL, so invoked through such a symlink the script's `$here/..` landed on
# the symlink's parent, `agents/` and `skills/` pointed at nothing, every file fell through
# the `[ -f ]` guard, and the run was silent with rc=0 -- the third reproduced route to the
# same silent zero R14h and R14i cover from the other two directions. Symlinking the whole
# plugin directory was always fine and stays fine; this is the one-level-in case.
#
# R14h is the backstop and this is the fix: without `pwd -P` the run is now LOUD but still
# wrong, and this assertion is what pins it being right.
mkdir -p "$TMP/r14l"
ln -sf "$DP/scripts" "$TMP/r14l/scripts"
_r14l="$(FORGEWARD_GSTACK_ROOT="$DGS" "$TMP/r14l/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"; _r14lrc=$?
case "$_r14l" in
  *"NO ported rubric could be read"*) nok "drift R14l: a symlinked scripts/ dir resolved the plugin root one level wrong and scanned nothing" "out='$_r14l'" ;;
  *"ok       alpha-reviewer"*"1 ported rubric(s) parsed, 1 checked"*)
    [ "$_r14lrc" -eq 0 ] \
      && ok "drift: the plugin root resolves physically, so a symlinked scripts/ directory scans the real agents/ and skills/" \
      || nok "drift R14l: resolved the root but exited $_r14lrc" "out='$_r14l'" ;;
  *) nok "drift R14l: unexpected output through a symlinked scripts/ directory" "out='$_r14l'" ;;
esac
rm -rf "$TMP/r14l"

# R14d: THE FLOOR FOR THE SKILLS HALF. R6 is this assertion for `agents/`, and it would
# stay green with every ported skill's provenance block deleted. Same instrument, same
# reason: R14 above runs entirely on a synthetic fixture, so without this the skills glob
# could be scanning a shipped tree that records nothing. Reads `$PLUGIN` with no fixture
# in the path, and requires the same BOTH-fields pair, because a half-recorded port is
# silently unchecked rather than loudly broken.
#
# The floor is 1, not a count of `skills/*/`: `gate` and `ci-gate` are forgeward's own
# and are not ports, so requiring every skill to carry provenance would be asserting a
# property this repo does not have. What it pins is that at least one does and that none
# is half-recorded.
#
# `dir`, not `file`: every skill's basename is the constant `SKILL.md`, so naming a
# half-recorded port by basename would report every one of them as `SKILL`. Same rule
# `forgeward-rubric-drift.sh` follows for the name it prints.
_strict_provenance dir "$PLUGIN"/skills/*/SKILL.md
_r14dn="$_sp_n"; _r14dbad="$_sp_bad"
[ "$_r14dn" -ge 1 ] && [ -z "$_r14dbad" ] \
  && ok "drift: all $_r14dn shipped ported skill(s) record BOTH source-path and a 64-hex source-sha256" \
  || nok "drift R14d: a ported skill is not drift-checkable" "complete: $_r14dn (expected >= 1) | half-recorded:${_r14dbad:- none}"

# R14j: THE TEST'S READER AND THE SCRIPT'S READER AGREE ON THE SHIPPED TREE. R6 and R14d
# above each carry a DELIBERATE copy of the script's two `sed` expressions, and R6's own
# header names the exposure that buys: "a future loosening of the script's regex would
# not show up here -- accepted". That loosening has now happened (R14i is why), so the
# exposure stopped being hypothetical and this is the control that closes it, in the shape
# CLAUDE.md asks for -- two arms of one reader must be ASSERTED to agree, not assumed to.
#
# Derived on both sides. The left is R6's and R14d's strict canonical count; the right is
# read out of the script's own summary line by RUNNING it over the shipped tree, against a
# synthetic root built from the script's own landmark list and holding no files at all, so
# every port parses, every port reports missing, and nothing depends on what gstack has on
# this machine. Divergence in either direction reddens: a script regex that accepts less
# than the canonical shape parses fewer, and one that accepts more parses more.
#
# NOT what this pins: it says the two readers agree about the shipped files, never that
# either is correct about a file that does not ship. R14i is the assertion for what a
# checkout can do to those files on the way to disk.
_r14j_root="$TMP/r14j-gsroot"
_r14j_lm="$(sed -n 's/^gs_landmarks=(\(.*\))$/\1/p' "$PLUGIN/scripts/forgeward-rubric-drift.sh")"
for _l in $_r14j_lm; do mkdir -p "$_r14j_root/$_l"; done
_r14jout="$(FORGEWARD_GSTACK_ROOT="$_r14j_root" \
            "$PLUGIN/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"
_r14jn="$(printf '%s\n' "$_r14jout" | sed -n 's/^rubric-drift: \([0-9][0-9]*\) ported rubric(s) parsed,.*/\1/p')"
_r14jexp=$((_r6n + _r14dn))
if [ -n "$_r14j_lm" ] && [ -n "$_r14jn" ] && [ "$_r14jn" -ge 1 ] && [ "$_r14jn" -eq "$_r14jexp" ]; then
  ok "drift: the script parses exactly the $_r14jn shipped port(s) R6 and R14d count (the two copies of the reader agree)"
else
  nok "drift R14j: the script's reader and the suite's copy of it disagree on the shipped tree" \
      "script parsed:'${_r14jn:-NONE}' suite counted:$_r14jexp (R6 $_r6n + R14d $_r14dn) landmarks:'${_r14j_lm:-NONE}'"
fi

# R14k: EVERY SHIPPED PORT'S source-path SITS UNDER A LANDMARK THE ROOT SCAN KNOWS.
# That correspondence IS the 0.20.0 bug: `skills/audit` was ported from `cso/` while the
# landmark list held only `review/specialists`, so a checkout carrying one subtree and not
# the other read as no-gstack and the whole run went quiet. R14b fixed the instance; this
# is the detector for the NEXT one, which the script's own header names as undetected.
#
# Both sides derived, again. The landmark list is read out of the script rather than typed
# here, and the source-paths are read out of the script's OWN missing-NOTE from the R14j
# run above -- so a port added under some third gstack subtree reddens this the day it is
# added, without anyone remembering to update a list.
_r14kbad=""
_r14kn=0
while IFS= read -r _pth; do
  [ -n "$_pth" ] || continue
  _r14kn=$((_r14kn+1)); _hit=0
  for _l in $_r14j_lm; do case "$_pth" in "$_l"/*) _hit=1 ;; esac; done
  [ "$_hit" -eq 1 ] || _r14kbad="$_r14kbad $_pth"
done <<EOF
$(printf '%s\n' "$_r14jout" | sed -n 's/^  [^ ][^ ]*  (\(.*\))$/\1/p')
EOF
[ -n "$_r14j_lm" ] && [ "$_r14kn" -ge 1 ] && [ "$_r14kn" -eq "$_r14jexp" ] && [ -z "$_r14kbad" ] \
  && ok "drift: all $_r14kn shipped source-path(s) sit under a landmark the root scan recognises ($_r14j_lm)" \
  || nok "drift R14k: a shipped port sits outside every landmark, so a checkout holding only its subtree reads as no-gstack" \
      "landmarks:'${_r14j_lm:-NONE}' paths seen:$_r14kn (expected $_r14jexp) | outside:${_r14kbad:- none}"

# =============================================================================
# R15–R19 — the three unasserted edges, and the controls for the two limits
# this branch fixes.
#
# TODOS.md carried two separate P3 entries about this script: three edges R1–R13 never
# drove (0.17.0), and three limits the review that gated 0.20.0 found and knowingly did
# not fix. R15–R17 close the edges. R18 and R19 are the controls for the two limits
# fixed on this branch; the third (a `.gitattributes` `eol=lf` pin) was already rejected
# for scope and stays rejected.
#
# THEY ARE NOT THE SAME KIND OF ASSERTION AND EACH COMMENT SAYS WHICH IT IS. R15, R16
# and R17 were green before a line of this branch was written — they pin behaviour that
# was already correct and simply untested, so they had no opinion about any bug. Only
# R18 and R19 were run against the PRE-FIX script and observed to fail there. Cite it as
# `git show d9fa699:scripts/forgeward-rubric-drift.sh` -- this branch's merge-base with
# master, which is immutable. Bare `HEAD:` is what the rest of this file used and it is
# self-referential the instant the fix commits: it then prints the FIXED script, so anyone
# following the recipe reproduces the passing number and concludes the control is a lie. An author reading five green lines cannot otherwise tell the
# difference, and CLAUDE.md's rule is that a fix needs both kinds and must label them.
# =============================================================================

# R15: A ROOT THAT EXISTS BUT IS A *FILE* DEGRADES TO THE QUIET NO-OP.
# The first of the three filed edges. Every landmark test in the root scan is `[ -d ]`,
# so a candidate that is a regular file fails both passes and the script exits 0 having
# said nothing — which is the correct outcome and was already the behaviour.
#
# CHARACTERIZATION, NOT A CONTROL: verified green against the pre-fix script, so it
# proves nothing about this branch. It pins that the file path appears in the verbose
# candidate list, so the user can see WHAT was rejected rather than only that something
# was.
#
# WHAT IT DOES NOT COVER, CORRECTED HERE: this comment used to claim the plausible future
# edit `[ -d ]` → `[ -e ]` "is what reddens on it". MEASURED: mutate both landmark tests
# to `[ -e ]` and this suite stays green end to end. The reason is that R15 is not a
# fixture for that edit at all -- its root is a regular FILE, so `[ -e "$file/review/
# specialists" ]` fails with ENOTDIR exactly as `[ -d ]` does, and the two operators are
# indistinguishable here. R15b below is the fixture that DOES separate them. A comment
# asserting coverage a green assertion does not have is worse than no comment: it is the
# reason nobody writes the assertion that would have caught the edit.
_r15f="$TMP/driftroot-is-a-file"
printf 'not a directory\n' > "$_r15f"
# Fixture guard. Every assertion below this line reads as a clean no-op if the write
# above silently failed -- a root that does not exist reaches the same nothing-to-compare
# path as one that is a file, so R15 would print `ok` while testing nothing.
[ -f "$_r15f" ] || nok "drift R15: fixture was not created, so the assertion below is vacuous" "path='$_r15f'"
_r15q="$(FORGEWARD_GSTACK_ROOT="$_r15f" "$DP/scripts/forgeward-rubric-drift.sh" 2>&1)"; _r15rc=$?
_r15v="$(FORGEWARD_GSTACK_ROOT="$_r15f" "$DP/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"
case "$_r15v" in
  *"no gstack rubrics at any searched root"*"$_r15f"*)
    [ -z "$_r15q" ] && [ "$_r15rc" -eq 0 ] \
      && ok "drift: a gstack root that exists but is a FILE is rejected by both passes, named in the verbose candidate list, and silent otherwise" \
      || nok "drift R15: a file-shaped root was not the quiet no-op" "rc=$_r15rc quiet='$_r15q'" ;;
  *) nok "drift R15: a file-shaped root did not reach the nothing-to-compare path, or was not named in the candidate list" "out='$_r15v'" ;;
esac

# R15b: A ROOT WHOSE LANDMARKS ARE REGULAR FILES IS REJECTED.  ** WRONG-FIX CONTROL **
#
# NOT a pre-fix control: the `[ -d ]` landmark tests are untouched by this branch, so this
# is green against `git show d9fa699:scripts/forgeward-rubric-drift.sh` exactly as it is
# green here. What it pins is the edit R15's comment used to claim R15 covered and does
# not: relaxing both `[ -d "$cand/$landmark" ]` tests to `[ -e ]`.
#
# The fixture is the difference. R15's root is a FILE, so both operators fail identically
# on `$file/review/specialists` (ENOTDIR) and the mutation is invisible. Here the root is
# a real DIRECTORY and the two landmarks inside it are regular FILES -- the shape a
# half-extracted archive or a `touch` typo leaves behind. `-d` rejects it and the script
# stays silent; `-e` accepts it, selects it as `gs_root`, and then every `$gs_root/review/
# specialists/<x>.md` fails `[ -f ]`, so the run reports every ported rubric as no longer
# existing upstream and tells the user upstream may have renamed or removed files that
# are sitting on their disk. That false advisory is the same class as R14e's, which is why
# the first arm pins it explicitly rather than leaving a catch-all to absorb it.
#
# VERIFIED BY MUTATION, not by reasoning: with both tests changed to `[ -e ]` this
# assertion fails on its first arm and the rest of the suite stays green, so it is the
# only thing standing between that edit and a shipped false advisory.
_r15bgs="$TMP/driftroot-landmarks-are-files"
mkdir -p "$_r15bgs/review"
printf 'a file, not the directory the landmark test expects\n' > "$_r15bgs/review/specialists"
printf 'a file, not the directory the landmark test expects\n' > "$_r15bgs/cso"
[ -f "$_r15bgs/review/specialists" ] && [ -f "$_r15bgs/cso" ] \
  || nok "drift R15b: fixture landmarks were not created as files, so the assertion below is vacuous" "root='$_r15bgs'"
_r15bq="$(FORGEWARD_GSTACK_ROOT="$_r15bgs" "$DP/scripts/forgeward-rubric-drift.sh" 2>&1)"; _r15brc=$?
_r15bv="$(FORGEWARD_GSTACK_ROOT="$_r15bgs" "$DP/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"
case "$_r15bv" in
  *"no longer exist"*)
    nok "drift R15b: a root whose landmarks are regular files was accepted as a gstack checkout, and every ported rubric was then reported as removed upstream" "out='$_r15bv'" ;;
  *"no gstack rubrics at any searched root"*)
    [ -z "$_r15bq" ] && [ "$_r15brc" -eq 0 ] \
      && ok "drift: a candidate root whose landmarks are regular FILES is rejected by both passes, so the run stays silent instead of reporting every port as removed upstream" \
      || nok "drift R15b: rejected, but the run was not the quiet no-op" "rc=$_r15brc quiet='$_r15bq'" ;;
  *) nok "drift R15b: a file-landmark root reached neither the nothing-to-compare path nor the missing-upstream report" "out='$_r15bv'" ;;
esac

# R16: A `source-path` CONTAINING SPACES IS READ WHOLE, HASHED, AND NAMED WHOLE.
# The second filed edge. The script's reader captures `\(.*[^[:space:]]\)`, so internal
# spaces survive and only trailing whitespace is trimmed; `live="$gs_root/$src_path"` is
# quoted at every use. A reader that split on whitespace would truncate this fixture's
# path to `review/specialists/alpha` and report the port as no-longer-existing upstream —
# which is why the FIRST case arm below is that specific wrong answer rather than a
# catch-all. Reporting a live file as deleted upstream is the same class of false
# advisory R14e exists for.
#
# CHARACTERIZATION, NOT A CONTROL: green against the pre-fix script.
#
# THE NEWLINE HALF OF THAT ENTRY IS NOT TESTED HERE AND CANNOT BE. A provenance block is
# line-oriented, so a `source-path:` value containing a newline is not representable in
# the format at all — `sed` would read the first line and the rest would be ordinary
# body text. The place a newline genuinely arrives is the rubric's NAME, which comes
# from a directory or filename on disk rather than from the file's own text, and that is
# R18. Splitting the entry this way is the finding, not a dodge around it.
_r16gs="$TMP/driftgstack-spaced"
mkdir -p "$_r16gs/review/specialists"
printf 'Spaced checklist, v1.\n' > "$_r16gs/review/specialists/alpha beta.md"
_r16sha="$(sha256sum -- "$_r16gs/review/specialists/alpha beta.md" | cut -d' ' -f1)"
_r16dp="$TMP/driftplugin-spaced"
mkdir -p "$_r16dp/scripts" "$_r16dp/agents"
cp "$DRIFT_SRC" "$_r16dp/scripts/forgeward-rubric-drift.sh"
chmod +x "$_r16dp/scripts/forgeward-rubric-drift.sh"
{ printf -- '---\nname: spaced-reviewer\n---\n\n'
  printf '<!-- PORTED RUBRIC\n     source-path:   review/specialists/alpha beta.md\n'
  printf '     source-sha256: %s\n-->\n\nBody.\n' "$_r16sha"
} > "$_r16dp/agents/spaced-reviewer.md"
_r16ok="$(FORGEWARD_GSTACK_ROOT="$_r16gs" "$_r16dp/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"
_r16quiet="$(FORGEWARD_GSTACK_ROOT="$_r16gs" "$_r16dp/scripts/forgeward-rubric-drift.sh" 2>&1)"
printf 'Spaced checklist, v2.\n' > "$_r16gs/review/specialists/alpha beta.md"
_r16drift="$(FORGEWARD_GSTACK_ROOT="$_r16gs" "$_r16dp/scripts/forgeward-rubric-drift.sh" 2>&1)"
case "$_r16ok$_r16drift" in
  *"no longer exist"*)
    nok "drift R16: a source-path containing a space was truncated and its live file read as deleted upstream" "clean='$_r16ok' drifted='$_r16drift'" ;;
  *"ok       spaced-reviewer"*"have drifted"*"review/specialists/alpha beta.md"*)
    [ -z "$_r16quiet" ] \
      && ok "drift: a source-path containing a space is compared against the right file and named whole in the drift NOTE" \
      || nok "drift R16: the matching run was not silent" "quiet='$_r16quiet'" ;;
  *) nok "drift R16: a spaced source-path produced neither the clean nor the drifted answer" "clean='$_r16ok' drifted='$_r16drift'" ;;
esac

# R16b: A gs_root PATH CONTAINING A BACKSLASH IS HASHED, NOT ESCAPED.  ** PRE-FIX CONTROL **
#
# R16 above tests a SPACE and read as covering "paths with metacharacters". It does not.
# A space is the one metacharacter GNU coreutils does NOT escape, so R16 is green on both
# sides of this fix and is the exact shape of a sample mistaken for a spec.
#
# GIVEN A PATH HOLDING A BACKSLASH OR A NEWLINE, `sha256sum -- FILE` ESCAPES THE WHOLE
# OUTPUT LINE: it prefixes it with a literal backslash and escapes the offending
# character. `cut -d' ' -f1` then hands back `\73cb...` where the digest is `73cb...`,
# `[ "$now" != "$src_sha" ]` can never match, and the rubric is reported as DRIFTED with
# an instruction to re-port a file that is byte-identical. Hashing through stdin removes
# the filename from the output line entirely and the class with it.
#
# THE BACKSLASH IS IN THE ROOT, NOT THE RUBRIC NAME, AND THAT IS THE SERIOUS FORM. A
# rubric name is chosen by this repo; `gs_root` comes from `HOME`, `CLAUDE_CONFIG_DIR` or
# a plugin-cache path, none of which this script chooses or can validate. One backslash
# there makes EVERY port report as drifted at once -- and `skills/gate/SKILL.md` instructs
# the gate to relay that output verbatim, so the false advisory reaches the user.
#
# RUN AGAINST THE PRE-FIX SCRIPT AND OBSERVED TO FAIL: `git show d9fa699:` reports
# `1 ported rubric(s) have drifted` for a file whose bytes are unchanged.
_r16bgs="$TMP/drift\\gsroot"
mkdir -p "$_r16bgs/review/specialists"
printf 'Backslash-root checklist, v1.\n' > "$_r16bgs/review/specialists/alpha.md"
[ -f "$_r16bgs/review/specialists/alpha.md" ] \
  || nok "drift R16b: fixture was not created under a backslash-bearing root, so the assertion below is vacuous" "root='$_r16bgs'"
# Hashed the way the FIXED script hashes -- through stdin. Spelling it `sha256sum -- FILE`
# here would reproduce the defect in the expectation as well as in the code, and the
# assertion would then be green on both sides while measuring nothing.
_r16bsha="$(sha256sum < "$_r16bgs/review/specialists/alpha.md" | cut -d' ' -f1)"
_r16bdp="$TMP/driftplugin-backslash"
mkdir -p "$_r16bdp/scripts" "$_r16bdp/agents"
cp "$DRIFT_SRC" "$_r16bdp/scripts/forgeward-rubric-drift.sh"
chmod +x "$_r16bdp/scripts/forgeward-rubric-drift.sh"
{ printf -- '---\nname: backslash-reviewer\n---\n\n'
  printf '<!-- PORTED RUBRIC\n     source-path:   review/specialists/alpha.md\n'
  printf '     source-sha256: %s\n-->\n\nBody.\n' "$_r16bsha"
} > "$_r16bdp/agents/backslash-reviewer.md"
_r16bv="$(FORGEWARD_GSTACK_ROOT="$_r16bgs" "$_r16bdp/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"; _r16brc=$?
_r16bq="$(FORGEWARD_GSTACK_ROOT="$_r16bgs" "$_r16bdp/scripts/forgeward-rubric-drift.sh" 2>&1)"
if [ -z "$_r16bsha" ]; then
  nok "drift R16b: the expected digest came back empty, so the comparison below asserts a property of nothing" "root='$_r16bgs'"
else
  case "$_r16bv" in
    *"have drifted"*)
      nok "drift R16b: a byte-identical rubric under a root whose path holds a backslash was reported as drifted, because the digest tool escaped its output line and the escape prefix was compared as part of the hash" "out='$_r16bv'" ;;
    *"ok       backslash-reviewer"*)
      [ -z "$_r16bq" ] && [ "$_r16brc" -eq 0 ] \
        && ok "drift: a rubric under a gstack root whose path contains a backslash hashes to the same digest as its provenance block, so it is reported clean rather than drifted" \
        || nok "drift R16b: matched, but the quiet run was not silent" "rc=$_r16brc quiet='$_r16bq'" ;;
    *) nok "drift R16b: a backslash-bearing root produced neither the clean nor the drifted answer" "out='$_r16bv'" ;;
  esac
fi

# R17: AN `agents/` AND `skills/` HOLDING NOTHING AT ALL STILL SAYS SO.
# The third filed edge, and the one the entry called "the vacuity trap in its purest
# form": a gstack root IS selected, so the run gets past every guard R5/R13c cover, and
# then the two globs match no file, the loop body never executes once, and `parsed`
# stays 0. Before 0.20.0 that printed nothing and was indistinguishable from a clean run.
#
# CHARACTERIZATION, NOT A CONTROL: green against the pre-fix script — the guard it
# depends on landed at 0.20.0, and the entry filed at 0.17.0 was closed by it without
# anyone noticing. Distinct from R14h all the same, and the distinction is the reason
# this is not a duplicate: R14h drives `parsed=0` through a file that EXISTS and fails
# to parse, so the loop runs and every `continue` inside it is exercised. Here the loop
# has no iterations at all, which is a different way to reach the same counter and the
# one an empty install produces.
_r17dp="$TMP/driftplugin-nothing"
mkdir -p "$_r17dp/scripts" "$_r17dp/agents" "$_r17dp/skills"
cp "$DRIFT_SRC" "$_r17dp/scripts/forgeward-rubric-drift.sh"
chmod +x "$_r17dp/scripts/forgeward-rubric-drift.sh"
_r17gs="$TMP/driftgstack-nothing"
mkdir -p "$_r17gs/review/specialists" "$_r17gs/cso"
printf 'Alpha checklist, v1.\n' > "$_r17gs/review/specialists/alpha.md"
_r17="$(FORGEWARD_GSTACK_ROOT="$_r17gs" "$_r17dp/scripts/forgeward-rubric-drift.sh" 2>&1)"; _r17rc=$?
case "$_r17" in
  *"NO ported rubric could be read"*"Drift was NOT checked"*)
    [ "$_r17rc" -eq 0 ] \
      && ok "drift: an agents/ and skills/ holding zero rubrics reports that drift was NOT checked, in QUIET mode, and still exits 0" \
      || nok "drift R17: reported the empty install but exited $_r17rc" "out='$_r17'" ;;
  "") nok "drift R17: an empty install printed nothing — indistinguishable from a clean run" "rc=$_r17rc" ;;
  *) nok "drift R17: unexpected output from an install with no ported rubrics" "rc=$_r17rc out='$_r17'" ;;
esac

# R18: THE THREE NOTE COUNTS ARE ENTRIES, NOT LINES.  ** PRE-FIX CONTROL **
# Limit 1 of the three the 0.20.0 review filed. `n_drift`, `n_miss` and `n_bad` were
# `printf '%s' "$x" | grep -c .` over the accumulated report strings, which counts LINES.
# A rubric whose name carries a newline occupies two lines for one entry, so the NOTE
# read `2 ported rubric(s) have drifted` while naming one. The name is a skill DIRECTORY
# name or a reviewer FILENAME — both are filesystem input, not something this script
# writes — so the over-count is reachable without touching any file's contents.
#
# RUN AGAINST THE PRE-FIX SCRIPT AND OBSERVED TO FAIL: `git show
# d9fa699:scripts/forgeward-rubric-drift.sh` reports 2 on this fixture where the fixed
# script reports 1. That is what makes this a pre-fix control rather than a restatement
# of the fix; the entry's own text said the change "changes no output in any reachable
# case", and this fixture is the reachable case that shows otherwise.
#
# The fixture is the whole cost of the entry and it is why the limit was carried rather
# than fixed. It is CI-safe: `.github/workflows/test.yml` runs `gate-test.sh` only in
# the `suites` job on `ubuntu-latest`, and the `windows-latest` job runs
# `windows-hooks-test.sh` alone. It still skips LOUDLY rather than silently if a
# filesystem refuses the name, because a skip that reads as a pass is the failure this
# whole block is about.
_r18nl="$(printf 'be\nta')"
_r18dp="$TMP/driftplugin-newline"
mkdir -p "$_r18dp/scripts"
cp "$DRIFT_SRC" "$_r18dp/scripts/forgeward-rubric-drift.sh"
chmod +x "$_r18dp/scripts/forgeward-rubric-drift.sh"
_r18gs="$TMP/driftgstack-newline"
mkdir -p "$_r18gs/review/specialists"
printf 'Newline-named checklist, v1.\n' > "$_r18gs/review/specialists/alpha.md"
#
# ALL THREE COUNTERS, NOT ONE. The change replaced three tail `grep -c .` subshells, so a
# fixture exercising only `n_drift` leaves two thirds of it unpinned -- and the two
# unpinned ones are reachable by the same newline. Round-3 adversarial review made
# exactly that mutation argument: `n_miss` or `n_bad` moved from `+ 1` to `+ 2` stayed
# green against the single-counter form of this assertion, while relaying a false count
# into a gate run. One fixture carries all three: a drifted rubric, one whose source-path
# names a file the gstack root does not have, and one whose source-path escapes the tree.
_r18nl2="$(printf 'ga\nmma')"
_r18nl3="$(printf 'de\nlta')"
if mkdir -p "$_r18dp/skills/$_r18nl" "$_r18dp/skills/$_r18nl2" "$_r18dp/skills/$_r18nl3" 2>/dev/null \
   && [ -d "$_r18dp/skills/$_r18nl" ] && [ -d "$_r18dp/skills/$_r18nl2" ] && [ -d "$_r18dp/skills/$_r18nl3" ]; then
  # (a) DRIFTED: the file exists and hashes to something other than the recorded digest.
  { printf -- '---\nname: newline-skill\n---\n\n'
    printf '<!-- PORTED RUBRIC\n     source-path:   review/specialists/alpha.md\n'
    printf '     source-sha256: %s\n-->\n\nBody.\n' \
      "0000000000000000000000000000000000000000000000000000000000000000"
  } > "$_r18dp/skills/$_r18nl/SKILL.md"
  # (b) MISSING: a well-formed provenance block naming a file that is not in the root.
  { printf -- '---\nname: newline-skill-2\n---\n\n'
    printf '<!-- PORTED RUBRIC\n     source-path:   review/specialists/absent.md\n'
    printf '     source-sha256: %s\n-->\n\nBody.\n' \
      "1111111111111111111111111111111111111111111111111111111111111111"
  } > "$_r18dp/skills/$_r18nl2/SKILL.md"
  # (c) MALFORMED: a `..` segment, refused by the traversal guard before any hashing.
  { printf -- '---\nname: newline-skill-3\n---\n\n'
    printf '<!-- PORTED RUBRIC\n     source-path:   review/../../etc/passwd\n'
    printf '     source-sha256: %s\n-->\n\nBody.\n' \
      "2222222222222222222222222222222222222222222222222222222222222222"
  } > "$_r18dp/skills/$_r18nl3/SKILL.md"
  _r18out="$(FORGEWARD_GSTACK_ROOT="$_r18gs" "$_r18dp/scripts/forgeward-rubric-drift.sh" 2>&1)"
  _r18n="$(printf '%s\n' "$_r18out" | sed -n 's/^NOTE: \([0-9][0-9]*\) ported rubric(s) have drifted.*/\1/p' | head -1)"
  _r18m="$(printf '%s\n' "$_r18out" | sed -n 's/^NOTE: \([0-9][0-9]*\) ported rubric(s) no longer exist.*/\1/p' | head -1)"
  _r18b="$(printf '%s\n' "$_r18out" | sed -n 's/^NOTE: \([0-9][0-9]*\) ported rubric(s) record a source-path.*/\1/p' | head -1)"
  [ "$_r18n" = "1" ] && [ "$_r18m" = "1" ] && [ "$_r18b" = "1" ] \
    && ok "drift: each of the three NOTE counts reports ONE entry for a rubric whose NAME contains a newline, not the two lines it prints on" \
    || nok "drift R18: the drift NOTE counts report LINES rather than entries" "drift='${_r18n:-NONE}' missing='${_r18m:-NONE}' malformed='${_r18b:-NONE}' (each expected 1) out='$_r18out'"
else
  # A SKIP THAT READS AS A PASS. This arm calls `ok()` on purpose -- a filesystem that
  # refuses the name is not a defect in this repo and must not redden the suite -- but
  # `ok()` increments PASS and the tally has no third figure, so the skip is invisible to
  # anyone reading `# pass N / fail 0`. That is a property of every skip in this file, not
  # of this one, and it is already filed against goal 11 (`TODOS.md`, "a `SKIP` counter and
  # a third figure in the tally"). Do not fix it here: it is one line in this assertion and
  # a suite-wide change everywhere else, and bundling the two is how the second one gets
  # reviewed as an afterthought. Reachability, so the exposure is bounded rather than
  # asserted away: ext4 and APFS both accept the name, and CI runs this file only in the
  # `suites` job on `ubuntu-latest` -- the `windows-latest` job runs `windows-hooks-test.sh`
  # alone -- so no environment that runs this assertion today is expected to take this arm.
  ok "drift R18: SKIPPED — this filesystem refused a directory name containing a newline, so the entry-vs-line count is unverified HERE; it is verified on ubuntu-latest, which is where CI runs this suite"
fi

# R19: THE VERBOSE CANDIDATE LIST SAYS WHAT IT IS.  ** PRE-FIX CONTROL **
# Limit 2 of the three. The diagnostic ended `Searched: %s`, which reads as a complete
# account of where the script looked and is not one: a plugin-cache path enters the
# candidate list only when `[ -d ]` already holds, so the cache locations that do not
# exist were never candidates and never appear — while the explicit root and the two
# fixed locations are appended unguarded and appear whether they exist or not. One word
# covered both, mixing "looked here, nothing there" with "never looked", and the person
# reading it is by definition debugging a silent run.
#
# RUN AGAINST THE PRE-FIX SCRIPT AND OBSERVED TO FAIL: `git show d9fa699:` prints
# `Searched:` and neither of the two strings asserted below. The last arm keeps the old
# word pinned as a negative so a revert reddens here rather than passing on the first
# arm's substring.
_r19absent="$TMP/driftgstack-never-existed"
_r19="$(FORGEWARD_GSTACK_ROOT="$_r19absent" "$DP/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"; _r19rc=$?
case "$_r19" in
  *"Searched:"*)
    nok "drift R19: the verbose diagnostic still calls the candidate list 'Searched', which claims coverage it does not have" "out='$_r19'" ;;
  *"candidates tested:"*"$_r19absent"*"tested, not considered"*"never tested and cannot appear"*)
    [ "$_r19rc" -eq 0 ] \
      && ok "drift: the verbose candidate list is labelled as what was TESTED and says which candidate form can be absent from it" \
      || nok "drift R19: correct wording but exited $_r19rc" "out='$_r19'" ;;
  *) nok "drift R19: the verbose diagnostic does not distinguish a candidate that was tested from one that was never a candidate" "out='$_r19'" ;;
esac

# R19b: THE CACHE GUARD THE R19 WORDING DESCRIBES.  ** WRONG-FIX CONTROL **
#
# NOT a pre-fix control, and saying which it is is the whole obligation here: the `[ -d ]`
# guard is UNCHANGED by this branch, so this assertion is green against
# `git show d9fa699:scripts/forgeward-rubric-drift.sh` exactly as it is green against the
# fixed one -- MEASURED both ways, after a first draft that was not. It has no opinion
# about the bug R19 covers. What it pins is the plausible
# WRONG fix, which the script's own comment names and rejects: making the candidate list
# uniform by dropping the `[ -d ]` guard, so that cache paths appear whether they exist or
# not. Do that and an unmatched glob puts its own literal pattern into the list, and the
# new wording -- which promises the list is what was TESTED -- becomes false while R19,
# which only reads the prose, stays green. Round-3 adversarial review made precisely that
# argument against R19, and it is right about the gap and wrong that R19 is the defect:
# R19 pins a wording change and the wording is all that changed. This is the missing half.
#
# `FORGEWARD_GSTACK_ROOT` must be OUT of the environment, not merely empty, because it
# short-circuits the whole search order -- which is why R19 above cannot reach this code
# at all. Run from `$TMP`, which is not inside a git worktree, so `--show-toplevel` fails
# and the project-local candidate never joins the list either; that leaves exactly one
# candidate and any `*` in the output can only have come from an unguarded glob.
_r19bcfg="$TMP/r19b-empty-claude-dir"
mkdir -p "$_r19bcfg"
_r19b="$(cd "$TMP" && env -u FORGEWARD_GSTACK_ROOT CLAUDE_CONFIG_DIR="$_r19bcfg" \
          "$DP/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"; _r19brc=$?
# READ BOTH WORDINGS ON PURPOSE. The first attempt matched only the new
# `candidates tested: ` prefix, and it reddened against the pre-fix script -- not because
# the guard was broken there (it was not; the guard is untouched by this branch) but
# because the pre-fix script spells the same list `Searched: `. It was failing for R19's
# reason while claiming to measure the guard, which is a check that is not there. The
# second arm below restores independence: this assertion now has an opinion about exactly
# one thing, and R19 is the only assertion with an opinion about the wording.
# THREE ARMS, ONE PER WORDING THIS LIST HAS EVER HAD, AND THAT IS THE WHOLE POINT OF THE
# BLOCK ABOVE. The fixed script prints one candidate per line under a bare
# `candidates tested:` header (arm 1); the pre-fix script spells the same list
# `nothing to compare. Searched: ` (arm 2); the intermediate form this branch shipped and
# then replaced joined the list onto a `candidates tested: ` header (arm 3). An extractor
# that reads fewer than all three makes THIS assertion fail whenever the WORDING changes,
# which is R19's and R19c's business and not its own -- measured twice now: the first
# draft knew only arm 1 and reddened against the pre-fix script, and the second knew arms
# 1 and 2 and reddened under the mutation R19c exists for. Both times it was failing for
# someone else's reason while claiming to measure the `[ -d ]` guard, which is a check
# that is not there. `head -1` is gone with the joined form: every candidate line is
# examined, so a `*` anywhere in the list is caught, not only one in the first entry.
_r19bline="$(printf '%s\n' "$_r19b" | sed -n \
  -e 's/^rubric-drift:   //p' \
  -e 's/^rubric-drift: candidates tested: //p' \
  -e 's/^.*nothing to compare\. Searched: //p')"
if [ -z "$_r19bline" ]; then
  nok "drift R19b: no candidate list was printed, so the guard is unverified" "rc=$_r19brc out='$_r19b'"
else
  case "$_r19bline" in
    *"*"*) nok "drift R19b: an unmatched plugin-cache glob put its own literal pattern into the candidate list, so the list names a path that was never tested" \
               "candidates='$_r19bline'" ;;
    *)     [ "$_r19brc" -eq 0 ] \
             && ok "drift: a plugin-cache candidate enters the tested list only when it exists, so an unmatched glob contributes nothing rather than its own pattern" \
             || nok "drift R19b: guard holds but exited $_r19brc" "out='$_r19b'" ;;
  esac
fi

# R19c: THE CANDIDATE LIST IS ONE ENTRY PER LINE.  ** MUTATION-VERIFIED CONTROL **
#
# WHAT IT IS, SAID PLAINLY: it is neither a clean pre-fix control nor a clean wrong-fix
# one, and pretending otherwise is the failure the R19b comment above documents. Against
# `git show d9fa699:` it DOES redden -- but for R19's wording reason, since the pre-fix
# script has no `candidates tested:` line at all, so its pre-fix result carries no
# information about the defect this assertion is for. Its evidence is MUTATION: restore
# `printf 'rubric-drift: candidates tested: %s\n' "${gs_roots[*]:-<none>}"` in place of the
# header-plus-per-element form and this assertion reddens on its first arm while R19 and
# R19b both stay green. That is the whole reason it exists -- and R19b stays green there
# only because its extractor was given an arm for this exact wording when this mutation
# caught it failing for R19c's reason. Two assertions reading one line of output have to
# be made independent deliberately; they are not independent by default.
#
# THE DEFECT. `${gs_roots[*]}` joins on the first character of IFS, so a candidate path
# containing a space renders as two entries and one containing a newline forges an extra
# -- in the single piece of output whose entire job is to be a precise account of which
# roots were tested, read by someone debugging a run that said nothing. A space in
# `HOME`, in `CLAUDE_CONFIG_DIR`, or in a plugin-cache path is ordinary on macOS and
# Windows, and this script chooses none of the three.
#
# Asserting the HEADER is empty after the colon is what separates the two forms: with one
# candidate the joined form and the per-line form carry identical text, and differ only
# in which line it lands on.
_r19cabsent="$TMP/drift gstack never existed"
_r19c="$(FORGEWARD_GSTACK_ROOT="$_r19cabsent" "$DP/scripts/forgeward-rubric-drift.sh" --verbose 2>&1)"; _r19crc=$?
_r19chdr="$(printf '%s\n' "$_r19c" | grep -c '^rubric-drift: candidates tested:$')"
_r19centries="$(printf '%s\n' "$_r19c" | sed -n 's/^rubric-drift:   //p')"
if [ "$_r19chdr" != "1" ]; then
  nok "drift R19c: the candidate list is joined onto the header line, so a candidate path containing a space renders as two entries in the one output that claims to enumerate exactly what was tested" "out='$_r19c'"
elif [ "$_r19centries" != "$_r19cabsent" ]; then
  nok "drift R19c: the candidate entry did not survive whole onto its own line" "got='$_r19centries' want='$_r19cabsent'"
else
  [ "$_r19crc" -eq 0 ] \
    && ok "drift: the verbose candidate list prints one entry per line under a bare header, so a candidate path containing a space is one entry rather than two" \
    || nok "drift R19c: list is correct but exited $_r19crc" "out='$_r19c'"
fi

# =============================================================================
# A25–A29 — the two repo-wide conventions, pinned.
#
# `python3 -I` and `export LC_ALL=C` were both filed in TODOS.md for six rounds as
# trivial one-line fixes, deliberately not done inline: "do it as its own change with
# its own gate run, and add an assertion per site — the precedent from rounds 2–6 is
# that an unpinned fix is a fix that quietly comes back out." These are those
# assertions. They are SOURCE pins, which is a weaker instrument than the behavioural
# ones above and is used here on purpose: the invariant is "every site has it", and no
# behavioural test enumerates sites. A26 is the exception and the reason the rest are
# worth having — it shows what one missing flag actually costs.
# =============================================================================

# A25: no direct or selected Python `-c` in shipped code without `-I`.
#
# Counted as the UNFLAGGED form, never the flagged one. "Four sites carry -I" goes green
# the day a fifth is added without it — which is the exact regression this exists to
# catch. "Zero sites lack -I" cannot.
#
# Comment lines are excluded (`^[^#]*`) because this repo argues about the flag in prose
# directly beside the code: ci/check-version-monotonic.sh has two such lines and both
# would otherwise read as violations. BLIND SPOT, stated so it is not mistaken for
# coverage — a code line carrying a TRAILING comment that mentions `python3 -c` is
# skipped by that same filter. No such line exists today and the shape is contrived, but
# this assertion cannot see it. Scoped to shipped code (`scripts/`, `ci/`); this suite's
# own `python3 -c` fixture mutations are deliberately out of scope, since they run in a
# scratch repo whose contents the test wrote.
_a25_bad="$(grep -rn --include='*.sh' -E '^[^#]*(python3|python|"\$_JSON_PY")[[:space:]]+-c' "$PLUGIN/scripts" "$PLUGIN/ci" 2>/dev/null || true)"
_a25_good="$(grep -rc --include='*.sh' -E '^[^#]*(python3|python|"\$_JSON_PY")[[:space:]]+-I[[:space:]]+-c' "$PLUGIN/scripts" "$PLUGIN/ci" 2>/dev/null \
             | awk -F: '{n+=$2} END{print n+0}')"
if [ -z "$_a25_bad" ] && [ "$_a25_good" -ge 5 ]; then
  ok "A25: every Python -c in shipped code carries -I ($_a25_good sites flagged, 0 unflagged)"
else
  nok "A25: a python3 -c in shipped code is missing -I, so the repo under review is on its sys.path" \
      "unflagged: ${_a25_bad:-none} | flagged sites: $_a25_good (expected >= 5)"
fi

# A26: `-I` is not hardening here — it is the difference between a DENY and an ALLOW.
#
# A25 says the flag is present. This says what it costs when it is not, because a flag
# with no demonstrated failure is a flag the next reader deletes as noise.
#
# json_get's python3 arm is taken whenever jq is absent or fails (A20/A21 cover both).
# `python3 -c` puts the process CWD at sys.path[0], and the hook's CWD is the repo being
# pushed — so a `json.py` sitting in that repo is imported INSTEAD of the standard
# library, and it decides what the hook believes the command was. The repo under review
# gets to configure the interpreter judging it.
#
# THREE legs, and the two controls carry as much weight as the attack:
#   1. attack against the shipped script      -> must DENY  (the guard holds)
#   2. attack against a copy with -I stripped -> must ALLOW  (the bypass is real, so
#      leg 1 is measuring the flag and not something incidental)
#   3. leg 2's script with the json.py removed -> must DENY  (the mutant is otherwise
#      healthy, so leg 2's ALLOW is the shadow rather than a script the sed broke)
#
# LIMIT: this is the no-jq arm only. With a working jq installed, json_get never reaches
# python3 and the shadow is inert — so the exposure is real but conditional, and the
# assertion says nothing about a machine with jq.
if command -v python3 >/dev/null 2>&1 && [ -n "${_nojq_path:-}" ]; then
  _A26="$TMP/a26"; mkdir -p "$_A26"
  _a26_repo="$_A26/repo"
  mkrepo "$_a26_repo" >/dev/null 2>&1
  cm "$_a26_repo" a.txt base
  ( cd "$_a26_repo" && git checkout -qb feat ) >/dev/null 2>&1
  cm "$_a26_repo" b.txt work

  _a26_pay="$(printf '{"cwd":"%s","tool_input":{"command":"git push"}}' "$_a26_repo")"
  _a26_run() { ( cd "$_a26_repo" && printf '%s' "$_a26_pay" | PATH="$_nojq_path" "$1" pretooluse ); }

  # A json module that answers every question with a benign command. Only `load` is
  # reached today; `loads`/`dumps` are provided so an unrelated import cannot make this
  # fail for a reason other than the one under test.
  #
  # COMMITTED to the branch, not merely dropped on disk, and the difference is the whole
  # threat model. TODOS.md filed this as needing "write access to the user's checkout —
  # which already defeats the local gate outright"; it does not. Python reads a file, not
  # an index, so the shadow arrives with the branch you cloned to review it.
  cat > "$_a26_repo/json.py" <<A26PY
def load(fp, *a, **k):
    return {"cwd": "$_a26_repo", "tool_input": {"command": "ls -la"}, "hook_event_name": "PreToolUse"}
def loads(s, *a, **k):
    return load(None)
def dumps(o, *a, **k):
    return "{}"
A26PY
  ( cd "$_a26_repo" && git add json.py && git commit -qm "add json.py" ) >/dev/null 2>&1

  # The whole scripts/ directory is copied, not just the one file: the hook resolves its
  # siblings relative to its own path, so a lone mutant would fail for want of a
  # neighbour and leg 3 would read that as health.
  _a26_mut="$TMP/a26-mutant"; mkdir -p "$_a26_mut"
  cp "$PLUGIN/scripts/"*.sh "$_a26_mut/"
  sed -e 's/python3 -I -c/python3 -c/g' \
      -e 's/"\$_JSON_PY" -I -c/"\$_JSON_PY" -c/g' \
      "$PLUGIN/scripts/forgeward-gate-check.sh" > "$_a26_mut/forgeward-gate-check.sh"
  chmod +x "$_a26_mut"/*.sh

  _a26_shipped="$(_a26_run "$PLUGIN/scripts/forgeward-gate-check.sh")"
  _a26_bypass="$(_a26_run "$_a26_mut/forgeward-gate-check.sh")"
  mv "$_a26_repo/json.py" "$_A26/json.py.parked"
  _a26_health="$(_a26_run "$_a26_mut/forgeward-gate-check.sh")"

  _a26_why=""
  denies "$_a26_shipped" || _a26_why="$_a26_why [the shipped hook ALLOWED a publish with a hostile json.py in the repo]"
  [ -z "$_a26_bypass" ]  || _a26_why="$_a26_why [-I stripped and the shadow still did not flip the verdict — this assertion measures nothing]"
  denies "$_a26_health"  || _a26_why="$_a26_why [the -I-stripped copy denies nothing even without json.py — the mutant is broken, not bypassed]"
  [ -z "$_a26_why" ] \
    && ok "A26: a hostile json.py in the repo under review cannot flip the hook's verdict — and the same attack ALLOWS the publish once -I is stripped" \
    || nok "A26: the CWD-on-sys.path bypass is not pinned" "$_a26_why"
else
  ok "A26: CWD-on-sys.path bypass SKIPPED (needs python3 and the jq-less PATH from A20) — the -I flag's EFFECT is unverified on this machine; A25 still pins its presence"
fi

# A27: every shipped script carries `export LC_ALL=C`.
#
# Enumerated from `git ls-files`, not from a hand-kept list, so a script added tomorrow
# without the pin fails here rather than being silently outside the convention. The
# `>= 11` floor is a non-vacuity guard, on the same reasoning as A19's non-empty check:
# an enumeration that returns nothing would otherwise assert "none of zero files are
# missing it" and pass.
#
# `test/` is excluded DELIBERATELY and it is not an oversight. The suite spawns these
# scripts as children, so a pin here would be inherited by every one of them and the
# thing A27 is checking would become untestable from inside the test that checks it.
_a27_files="$(git -C "$PLUGIN" ls-files '*.sh' 2>/dev/null | grep -v '^test/' || true)"
if [ -z "$_a27_files" ]; then
  _a27_files="$(cd "$PLUGIN" && find scripts ci live-test -name '*.sh' -type f 2>/dev/null || true)"
fi
_a27_missing=""; _a27_n=0
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  _a27_n=$((_a27_n+1))
  grep -qE '^[[:space:]]*export LC_ALL=C[[:space:]]*$' "$PLUGIN/$_f" || _a27_missing="$_a27_missing $_f"
done <<A27EOF
$_a27_files
A27EOF
if [ -z "$_a27_missing" ] && [ "$_a27_n" -ge 11 ]; then
  ok "A27: all $_a27_n shipped scripts carry export LC_ALL=C (byte-exact classes, collation, and grep over invalid UTF-8 do not move with the invoker's locale)"
else
  nok "A27: a shipped script's text handling still follows the invoker's locale" \
      "missing:${_a27_missing:- none} | enumerated: $_a27_n (expected >= 11)"
fi

# A28: exactly ONE mechanism per invariant — no inline `LC_ALL=` survives beside the pin.
#
# CLAUDE.md's rule is `export LC_ALL=C` script-wide, "never a `local LC_ALL=C` beside
# it", and the reason is not redundancy-aversion for its own sake: the two forms are not
# equivalent (a `local` assignment is not passed to a spawned child unless the name was
# already exported), so leaving both live is how the next reader trusts the weaker one.
# Both inline prefixes this repo had were REMOVED when the pin landed, not kept.
#
# Comments are excluded for the same reason as A25 — the removals are documented in
# prose at the sites they were removed from, and that prose is the point.
_a28_bad="$(grep -rn --include='*.sh' -E '^[^#]*(local[[:space:]]+LC_ALL=|LC_ALL=[A-Za-z0-9._-]+[[:space:]]+[a-z])' \
              "$PLUGIN/scripts" "$PLUGIN/ci" "$PLUGIN/live-test" 2>/dev/null || true)"
[ -z "$_a28_bad" ] \
  && ok "A28: no inline LC_ALL= prefix or local LC_ALL survives beside the script-wide pin (one mechanism, not two)" \
  || nok "A28: a second locale mechanism sits beside the pin — they are not equivalent, and the weaker one is the one that gets trusted" "$_a28_bad"

# A29: every script git records as executable IS executable in the working tree.
#
# Not theoretical. Inserting the A27 pin across eleven files with `awk > tmp && mv`
# replaced each file at the umask default, dropping all eleven from 755 to 644, and the
# whole plugin stopped running — every invocation was `Permission denied`. The suite
# caught it only because 28 unrelated assertions collapsed at once; nothing named the
# cause. This names it.
#
# Compared against git's own index mode rather than a hardcoded list, so it follows the
# repo. LIMIT: it can only run in a checkout — from an installed plugin cache there is
# no index to compare against, and it skips.
if git -C "$PLUGIN" rev-parse --git-dir >/dev/null 2>&1; then
  _a29_bad=""; _a29_n=0
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    _a29_n=$((_a29_n+1))
    [ -x "$PLUGIN/$_f" ] || _a29_bad="$_a29_bad $_f"
  done <<A29EOF
$(git -C "$PLUGIN" ls-files -s | awk '$1=="100755"{ $1=""; $2=""; $3=""; sub(/^[ \t]+/,""); print }')
A29EOF
  if [ -z "$_a29_bad" ] && [ "$_a29_n" -ge 11 ]; then
    ok "A29: all $_a29_n files git records at mode 100755 are executable in the working tree"
  else
    nok "A29: a tracked-executable file is not executable here — every invocation of it is Permission denied" \
        "not executable:${_a29_bad:- none} | enumerated: $_a29_n (expected >= 11)"
  fi
else
  ok "A29: executable-bit check SKIPPED (not a git checkout — no index mode to compare against)"
fi

# --- A30/A31: /forgeward:audit declares no code-editing tool, and the port records its source
#
# WHAT THIS PINS, stated narrowly because the wider claim is false. README,
# skills/gate/SKILL.md and the audit skill each say the audit does not write. The part
# that is checkable from the file is that its frontmatter declares an `allowed-tools`
# list holding none of `Edit`/`Write`/`NotebookEdit`/`MultiEdit`, and that is all A30
# asserts. It is NOT the same as "cannot write": the list also grants `Bash`, which
# writes arbitrarily and must, since the phases run git and scanners — and `Agent`,
# whose subagents this list does not constrain at all. Phase 14 is the proof, because it
# writes the report and no `Write` tool exists to do it with.
#
# So the audit's no-write property rests on the prompt plus two external backstops
# (`/forgeward:gate` Step 2's worktree snapshot, and forgeward-scan.sh bounding what a
# scanner may touch), and NOT on this assertion. Removing the declared writers narrows
# the surface; it does not close it, and A30 must not be cited as though it did.
#
# THE OBVIOUS TEST IS THE WRONG ONE, and this is the whole reason A30 is shaped as it is.
# `grep -q Write skills/audit/SKILL.md` returning nothing does NOT establish the property:
# a skill with NO `allowed-tools` key at all is granted every tool, so deleting the key
# makes the claim false while making the naive grep greener. The floor is therefore part
# of the assertion — the key must exist and the list must be non-empty — exactly the
# "assert the violating form, guard the enumeration against emptiness" rule in CLAUDE.md.
#
# Scoped to this one skill on purpose — but not for the reason an earlier draft of this
# comment gave, which was simply wrong about the repo. `skills/gate/SKILL.md` DOES declare
# a tool list (Bash, Read, Grep, Glob, Agent, Skill), with no writer in it, so it would
# pass a repo-wide sweep rather than fail one. The real obstacle is `skills/ci-gate`, which
# legitimately declares `Write` and `Edit` because it writes workflow files: a sweep over
# `skills/*/SKILL.md` therefore needs a per-skill expectation, not one deny-list, and a
# single deny-list would have to be relaxed until it asserted nothing. Two of the three
# shipped skills would pass one today; that is a reason to build the per-skill form later,
# not a reason to pretend the property does not generalise.
_a30_skill="$PLUGIN/skills/audit/SKILL.md"
if [ ! -f "$_a30_skill" ]; then
  nok "A30: skills/audit/SKILL.md is missing — the deep-audit axis has no owner in this tree" \
      "the gate's Step 1c names /forgeward:audit as the owner of the axis"
else
  # Frontmatter only: the body quotes tool names while describing what the phases do.
  _a30_fm="$(sed -n '2,/^---[[:cntrl:][:space:]]*$/p' "$_a30_skill")"
  # The list is a YAML block sequence under `allowed-tools:` — take the `- Item` lines
  # that follow it, stopping at the next unindented key. Each item is NORMALIZED before
  # it is judged, and that is not tidiness: `- Write ` with one trailing space, `- Write
  # # needed for the report`, `- "Write"` and `- Write(*)` are four legal spellings that
  # a whole-line `grep -x` for the bare word does not match, so before this normalization
  # existed each of them declared a writing tool and left A30 GREEN. Mutation-verified in
  # both directions: all four now redden it, and the plain `- Write` control still does.
  _a30_tools="$(printf '%s\n' "$_a30_fm" | awk -v sq="'" '
      /^allowed-tools:[[:space:]]*$/ { inlist=1; next }
      inlist && $0 ~ "^[[:space:]]*-[[:space:]]*[\"" sq "]?[A-Za-z]" {
          sub(/^[[:space:]]*-[[:space:]]*/,"")   # the sequence dash
          sub(/[[:space:]]+#.*$/,"")             # a trailing YAML comment
          gsub(/"/,""); gsub(sq,"")              # surrounding quotes, either flavour
          sub(/[[:space:]]+$/,"")                # trailing whitespace
          print; next }
      inlist && /^[^[:space:]-]/ { inlist=0 }
    ')"
  _a30_n="$(printf '%s' "$_a30_tools" | grep -c . || true)"
  # The optional `(...)` suffix is Claude Code's scoped-tool spelling (`Bash(git:*)`).
  _a30_bad="$(printf '%s\n' "$_a30_tools" | grep -xE '(Edit|Write|NotebookEdit|MultiEdit)(\(.*\))?' || true)"
  # Told apart in the failure message, because they need opposite fixes: a MISSING key
  # grants every tool and is the defect; a key written as a flow sequence
  # (`allowed-tools: [Bash, Read]`) is legal YAML this single block-sequence reader
  # deliberately does not parse — one reader per shape, per CLAUDE.md — and reddens A30
  # rather than being read as empty.
  _a30_key="$(printf '%s\n' "$_a30_fm" | grep -cE '^allowed-tools:' || true)"
  if [ "$_a30_n" -ge 3 ] && [ -z "$_a30_bad" ]; then
    # NON-GOAL, and it is the reason this message no longer says "none of them can
    # write": `Bash` is on the list and writes arbitrarily, so what is pinned here is
    # that no tool whose ONLY purpose is writing was declared. That the audit does not
    # write inside the repo it audits is a prompt-level rule in the skill plus the gate's
    # own workspace guard, and no assertion in this file covers it.
    ok "A30: /forgeward:audit declares $_a30_n allowed tools and none of Edit/Write/NotebookEdit/MultiEdit is among them (the non-empty floor is what stops a deleted key passing; Bash remains and is a stated non-goal)"
  else
    nok "A30: /forgeward:audit's declared tool list does not hold as written" \
        "writing tools:${_a30_bad:- none} | tools enumerated: $_a30_n (expected >= 3)$([ "$_a30_n" -eq 0 ] && { [ "$_a30_key" -gt 0 ] && echo ' | the allowed-tools key IS present but not as a block sequence, so this reader saw none of it' || echo ' | the allowed-tools key is ABSENT, which grants EVERY tool'; })"
  fi

  # A31: the port records where it came from. Same two fields the ported reviewers
  # carry (assertion R6's subject), for the same reason — without both, re-porting after
  # an upstream change is guesswork.
  #
  # NON-GOAL, stated because a green A31 must not be read as drift coverage: this asserts
  # the fields are WELL-FORMED, never that the recorded hash still matches upstream. R14
  # is what compares them, on a synthetic fixture, with R14d as the floor over the shipped
  # tree. A31 is what makes R14 possible — a port with no block is unpinnable — not a
  # substitute for it.
  _a31_path="$(sed -n 's/^ *source-path: *\(.*[^ ]\) *$/\1/p' "$_a30_skill" | head -1)"
  _a31_sha="$(sed -n 's/^ *source-sha256: *\([0-9a-f]\{64\}\) *$/\1/p' "$_a30_skill" | head -1)"
  _a31_commit="$(sed -n 's/^ *source-commit: *\([0-9a-f]\{40\}\) *$/\1/p' "$_a30_skill" | head -1)"
  if [ -n "$_a31_path" ] && [ -n "$_a31_sha" ] && [ -n "$_a31_commit" ]; then
    ok "A31: /forgeward:audit records source-path, a 40-hex source-commit and a 64-hex source-sha256 (re-porting after an upstream change is not guesswork)"
  else
    # One word per field. `${x:+present}${x:-MISSING}` is NOT that: when x is set the
    # second expansion yields the value, so the line printed `sha256:present<64 hex>` --
    # and that is the branch that fires, because A31 only fails when path or commit is
    # the missing one, which is exactly when the sha is present.
    _a31_shastate=MISSING; [ -n "$_a31_sha" ] && _a31_shastate=present
    nok "A31: /forgeward:audit's provenance block is incomplete — the port cannot be re-derived" \
        "path:${_a31_path:-MISSING} commit:${_a31_commit:-MISSING} sha256:$_a31_shastate"
  fi
fi

# =============================================================================
# K1..K41 — a PASS certifies the commits the reviewers were given, and only the latest
# gate run on that commit may write it (0.31.0). K33b, K39 and K41 pin the run id's marker
# field, that no write deletes a run file, and the run file's mode; F1-F12 below pin what
# the hooks do with them.
#
# The writer used to read HEAD and hash the live `<base>...HEAD` at write time, so a
# commit landing while reviewers ran was pinned to a marker nobody reviewed, and a
# failed re-run left an earlier PASS usable for the same diff. It now takes the full
# commit ids Step 0 froze -- each must resolve to itself -- and the id of the gate run
# that is writing; refuses when HEAD moved, when a pair shares no merge base, when the
# frozen pair's hash differs from the one the push hook will recompute from the base
# ref, or when a later run on that commit superseded this one; hashes the frozen pair;
# and has a `--revoke <reviewed-head>` mode the gate runs when a review starts and on
# every non-PASS. That mode records a new run id FIRST, then withdraws the marker of
# every local branch at the FROZEN commit under both spellings of its name, and on
# success prints `RUN_ID=<id>` as its last line.
#
# KIND OF CONTROL, per CLAUDE.md. K7, K8, K10 and K12 are PRE-FIX controls: against
# `git show 57c7192:scripts/forgeward-write-marker.sh` (0.30.0) they fail (it ignores the
# third and fourth arguments and has no --revoke). K9 is a WRONG-FIX control: green
# against that writer by construction, it pins that a fetch-style base advance still
# writes, which the plausible wrong fix -- refusing whenever the base ref's SHA changed
# -- would refuse. K1-K5, K11 and K13 pin the new contract, and because the contract
# itself is new they ALSO fail against 0.30.0 -- they are not bug-neutral. K6 is the
# one contract pin that is green against 0.30.0. K14-K27 came from the final review and
# each names its own kind, measured against 283c205. K28-K38 came from the pre-landing
# review and are measured against 72e9c2e. That review changed the contract itself (a
# fifth argument, and a commit for --revoke), so each K28-K33 PRE-FIX control was
# measured by running 72e9c2e's writer under ITS OWN contract (four arguments, bare
# --revoke) through the same fixture steps and watching the bug reproduce. K34 is a
# WRONG-FIX control; K35-K38 pin the new contract and have no pre-fix form. The guard
# each of K28-K38 names was also disabled in a scratch copy of the writer, and that
# assertion went red -- with one measured exception: relaxing the arity to accept four
# arguments alone leaves K35 green, because the empty-argument check refuses a missing
# run id with the same usage line; K35 reddens only when both are disabled.
#
# What the pre-landing review changed in the older assertions, which keep their numbers:
# every write now needs a run id minted by `--revoke` of the reviewed head (`krun`), and
# every revoke takes that commit. K10 and K11 pin that the last line of a successful
# revoke is `RUN_ID=<id>` (K11: the ONLY line when there is nothing to withdraw); K12
# that a failed revoke prints none; K13 that --revoke without a commit, or with more
# than one argument, is a usage error; K26 and K27 that the frozen commit, not live HEAD,
# decides what is withdrawn on a detached and on an unborn HEAD.
# =============================================================================
KR="$TMP/bind"; mkrepo "$KR"
( cd "$KR" && echo a > a.txt && git add -A && git commit -qm base && git branch -M main \
   && git checkout -qb kfeat && echo b > b.js && git add -A && git commit -qm work ) >/dev/null 2>&1
KB="$(git -C "$KR" rev-parse main)"; KH="$(git -C "$KR" rev-parse HEAD)"
KCOMMON="$(git -C "$KR" rev-parse --path-format=absolute --git-common-dir)"
KMARK="$KCOMMON/forgeward-gate-markers/kfeat.json"
kw() { kout="$(cd "$KR" && "$WRITE" "$@" 2>&1)"; kst=$?; }
kfield() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$KMARK" "$1" 2>/dev/null; }
KUSAGE='usage: forgeward-write-marker.sh <base-ref> <fired-csv> <reviewed-base> <reviewed-head> <run-id>'
# krun <commit>: mint a gate run for <commit> the way Step 2 does, into KRUN. It is a real
# revoke, so it also withdraws every marker at that commit.
krun() { KRUN="$(cd "$KR" && "$WRITE" --revoke "$1" 2>/dev/null | sed -n 's/^RUN_ID=//p')"; }
khex() { # khex <value>: 40 or 64 lowercase hex
  case "${#1}:$1" in 40:*[!0-9a-f]*|64:*[!0-9a-f]*) return 1 ;; 40:*|64:*) return 0 ;; esac
  return 1
}
klastrun() { local l="${kout##*$'\n'}"; case "$l" in RUN_ID=*) khex "${l#RUN_ID=}" ;; *) return 1 ;; esac; }
knorun() { case $'\n'"$kout" in *$'\n'RUN_ID=*) return 1 ;; esac; return 0; }
krun "$KH"

# K1-K5: the reviewed commits are REQUIRED, and anything that is not one is a usage error.
kw main privacy
[ "$kst" -eq 64 ] && case "$kout" in *"$KUSAGE"*) true ;; *) false ;; esac \
  && ok "K1: the writer refuses the old two-argument call with exit 64 and its usage line" \
  || nok "K1: two-argument call" "st=$kst out=$kout"
kw main privacy "" "$KH" "$KRUN"
[ "$kst" -eq 64 ] && case "$kout" in *"$KUSAGE"*) true ;; *) false ;; esac \
  && ok "K2: an empty reviewed-base is a usage error, not a silent default" \
  || nok "K2: empty reviewed-base" "st=$kst out=$kout"
kw main privacy "$KB"
[ "$kst" -eq 64 ] && case "$kout" in *"$KUSAGE"*) true ;; *) false ;; esac \
  && ok "K3: a missing reviewed-head is a usage error" \
  || nok "K3: missing reviewed-head" "st=$kst out=$kout"
kw main privacy "$KB" "$(git -C "$KR" rev-parse 'HEAD^{tree}')" "$KRUN"
[ "$kst" -eq 64 ] && case "$kout" in *"reviewed head"*"is not a commit"*) true ;; *) false ;; esac \
  && ok "K4: a tree object as reviewed-head is refused as not a commit" \
  || nok "K4: non-commit reviewed-head" "st=$kst out=$kout"
kw main privacy "--output=x" "$KH" "$KRUN"
[ "$kst" -eq 64 ] && case "$kout" in *"$KUSAGE"*) true ;; *) false ;; esac \
  && ok "K5: a dash-led reviewed argument is refused before git can read it as an option" \
  || nok "K5: dash-led argument" "st=$kst out=$kout"

# K6: the happy path -- the full ids Step 0 printed and the current run's id write a
# marker recording the reviewed head and the frozen pair's hash. (Abbreviated ids were
# accepted here until the final review of 0.31.0; K16 now pins that they are refused.)
rm -f "$KMARK"
krun "$KH"
kw main privacy "$KB" "$KH" "$KRUN"
K6HASH="$(cd "$KR" && "$HASH" main "$KH")"
[ "$kst" -eq 0 ] && [ -f "$KMARK" ] && [ "$(kfield reviewed_head)" = "$KH" ] \
  && [ -n "$K6HASH" ] && [ "$(kfield diff_hash)" = "$K6HASH" ] \
  && ok "K6: full reviewed ids write a marker recording the reviewed head and the frozen pair's hash" \
  || nok "K6: happy path" "st=$kst out=$kout head=$(kfield reviewed_head) want=$KH"

# K7 (PRE-FIX control): a commit lands after the review subject was frozen.
( cd "$KR" && echo c > c.js && git add -A && git commit -qm more ) >/dev/null 2>&1
K7NEW="$(git -C "$KR" rev-parse HEAD)"
rm -f "$KMARK"
kw main privacy "$KB" "$KH" "$KRUN"
[ "$kst" -eq 1 ] && [ ! -e "$KMARK" ] \
  && case "$kout" in *"HEAD moved during the gate run (${KH:0:12} -> ${K7NEW:0:12}); nothing reviewed ${K7NEW:0:12}"*) true ;; *) false ;; esac \
  && ok "K7: a commit made after Step 0 froze the subject writes no marker and says HEAD moved" \
  || nok "K7: moved HEAD" "st=$kst out=$kout"
KH="$K7NEW"

# K8 (PRE-FIX control): the base moves in a way that CHANGES the reviewed diff.
git -C "$KR" branch -f main "$KH" >/dev/null 2>&1
krun "$KH"
kw main privacy "$KB" "$KH" "$KRUN"
[ "$kst" -eq 1 ] && [ ! -e "$KMARK" ] \
  && case "$kout" in *"the base 'main' moved during the gate run in a way that changes the reviewed diff"*) true ;; *) false ;; esac \
  && ok "K8: a base move that changes the merge base writes no marker and says the base moved" \
  || nok "K8: moved base" "st=$kst out=$kout"
git -C "$KR" branch -f main "$KB" >/dev/null 2>&1

# K9 (WRONG-FIX control): a fetch-style advance of the base leaves the merge base -- and
# so the diff -- unchanged, and must still write.
( cd "$KR" && git checkout -q main && echo m > m.txt && git add -A && git commit -qm upstream \
   && git checkout -q kfeat ) >/dev/null 2>&1
kw main privacy "$KB" "$KH" "$KRUN"
[ "$kst" -eq 0 ] && [ -f "$KMARK" ] \
  && ok "K9: a base that only advanced (merge base unchanged) still writes the marker" \
  || nok "K9: fetch-style advance refused" "st=$kst out=$kout"

# K10 (PRE-FIX control): --revoke withdraws an existing marker, and its last line is the
# new run's id.
kw --revoke "$KH"
[ "$kst" -eq 0 ] && [ ! -e "$KMARK" ] && klastrun \
  && case "$kout" in *"withdrew the earlier PASS marker for 'kfeat'"*) true ;; *) false ;; esac \
  && ok "K10: --revoke removes this branch's marker, says so, and ends with RUN_ID=<id>" \
  || nok "K10: revoke existing" "st=$kst out=$kout"

# K11: nothing to withdraw prints exactly one line, the new run's id.
rm -f "$KMARK"
kw --revoke "$KH"
[ "$kst" -eq 0 ] && klastrun && case "$kout" in *$'\n'*) false ;; RUN_ID=*) true ;; *) false ;; esac \
  && ok "K11: --revoke with no marker exits 0 and prints only the RUN_ID=<id> line" \
  || nok "K11: revoke absent" "st=$kst out=$kout"

# K12 (PRE-FIX control): a marker that cannot be removed is a loud failure, never a
# silent success -- the gate stops on it because that PASS may still authorize a push --
# and prints no RUN_ID line, so the run cannot certify anything.
if [ "$(id -u)" -eq 0 ]; then
  ok "K12: # SKIP running as root -- a read-only directory does not stop root"
else
  krun "$KH"
  kw main privacy "$KB" "$KH" "$KRUN"
  chmod a-w "$(dirname "$KMARK")"
  kw --revoke "$KH"
  chmod u+w "$(dirname "$KMARK")"
  [ "$kst" -eq 1 ] && [ -f "$KMARK" ] && knorun \
    && case "$kout" in *"could not withdraw the earlier PASS for 'kfeat'"*"it may still authorize a push"*) true ;; *) false ;; esac \
    && ok "K12: an unremovable marker makes --revoke fail loudly with the marker still named, and no RUN_ID line" \
    || nok "K12: unremovable marker" "st=$kst out=$kout"
fi

# K13: --revoke takes exactly one argument, the reviewed head.
kw --revoke; k13_bare_st=$kst; k13_bare_out=$kout
kw --revoke "$KH" extra
[ "$k13_bare_st" -eq 64 ] && [ "$kst" -eq 64 ] \
  && case "$k13_bare_out" in *"$KUSAGE"*) true ;; *) false ;; esac \
  && case "$kout" in *"$KUSAGE"*) true ;; *) false ;; esac \
  && ok "K13: --revoke without the reviewed head, or with an extra argument, is a usage error" \
  || nok "K13: revoke arity" "bare=$k13_bare_st:$k13_bare_out extra=$kst:$kout"

# K14..K27 -- the final review of 0.31.0. Each says which kind of control it is; the
# pre-fix writer for these is `git show 283c205:scripts/forgeward-write-marker.sh`.
KFULLID='must be the full commit id Step 0 printed'
kfullid() { # kfullid <label> <value>: exit 64 and the message naming the arg
  [ "$kst" -eq 64 ] && [ ! -e "$KMARK" ] \
    && case "$kout" in *"forgeward: $1 '$2' $KFULLID"*) true ;; *) false ;; esac
}
rm -f "$KMARK"
krun "$KH"

# K14 (PRE-FIX control): `HEAD` as the reviewed head made the moved-HEAD check compare
# HEAD with itself; 283c205 wrote a marker for it.
kw main privacy "$KB" HEAD "$KRUN"
kfullid "reviewed head" HEAD \
  && ok "K14: HEAD as the reviewed head is refused with exit 64, naming the arg" \
  || nok "K14: symbolic reviewed head" "st=$kst out=$kout"
rm -f "$KMARK"

# K15 (PRE-FIX control): a branch as the reviewed base made the base comparison read
# one live ref twice; 283c205 wrote a marker for it.
kw main privacy main "$KH" "$KRUN"
kfullid "reviewed base" main \
  && ok "K15: a branch name as the reviewed base is refused with exit 64, naming the arg" \
  || nok "K15: symbolic reviewed base" "st=$kst out=$kout"
rm -f "$KMARK"

# K16 (PRE-FIX control): a short hex of a real commit. git resolves a short hex that
# collides with a branch name to the BRANCH, so length is part of the contract.
kw main privacy "$KB" "${KH:0:7}" "$KRUN"
kfullid "reviewed head" "${KH:0:7}" \
  && ok "K16: a 7-character hex of a real commit is refused with exit 64, naming the arg" \
  || nok "K16: short reviewed head" "st=$kst out=$kout"
rm -f "$KMARK"

# K17 (PRE-FIX control): uppercase hex of a real commit -- git accepts it, the contract
# (the exact id Step 0 printed) does not.
K17UP="$(printf '%s' "$KH" | tr 'a-f' 'A-F')"
kw main privacy "$KB" "$K17UP" "$KRUN"
kfullid "reviewed head" "$K17UP" \
  && ok "K17: an uppercase full id is refused with exit 64, naming the arg" \
  || nok "K17: uppercase reviewed head" "st=$kst out=$kout"
rm -f "$KMARK"

# K18 (WRONG-FIX control): green against 283c205 by construction. <base-ref> is a ref
# name and stays outside the full-id check, but it keeps its dash-led refusal -- the
# plausible wrong fix moves the dash check onto the reviewed args only.
kw --output=x privacy "$KB" "$KH" "$KRUN"
[ "$kst" -eq 64 ] && [ ! -e "$KMARK" ] && case "$kout" in *"$KUSAGE"*) true ;; *) false ;; esac \
  && ok "K18: a dash-led base ref is refused with exit 64 and the usage line" \
  || nok "K18: dash-led base ref" "st=$kst out=$kout"

# K19 (PIN of a guard that predates this review; green against 283c205 by construction,
# its mutation is what gives it an opinion): a base ref that resolves to nothing.
kw no-such-ref privacy "$KB" "$KH" "$KRUN"
[ "$kst" -eq 1 ] && [ ! -e "$KMARK" ] \
  && case "$kout" in *"base ref 'no-such-ref' does not resolve to a commit; nothing was written"*) true ;; *) false ;; esac \
  && ok "K19: a base ref that resolves to nothing writes no marker and says so" \
  || nok "K19: unresolvable base ref" "st=$kst out=$kout"

# K20/K21: an ORPHAN history shares no merge base with main. forgeward-diff-hash.sh used
# to hash that as the empty diff with exit 0 (V12 pins its refusal now); the writer
# refuses first, with the clearer message.
( cd "$KR" && git checkout -q --orphan korph && git rm -rqf . && echo o1 > o.txt \
   && git add o.txt && git commit -qm o1 && echo o2 > o.txt && git commit -qam o2 ) >/dev/null 2>&1
KO1="$(git -C "$KR" rev-parse korph~1)"; KO2="$(git -C "$KR" rev-parse korph)"
KOMARK="$(dirname "$KMARK")/korph.json"
# K20 (PRE-FIX control): 283c205 wrote a marker for the unrelated reviewed pair.
kw main privacy "$KB" "$KO2" "$KRUN"
[ "$kst" -eq 1 ] && [ ! -e "$KOMARK" ] \
  && case "$kout" in *"the reviewed base ${KB:0:12} and the reviewed head ${KO2:0:12} share no merge base, so the reviewed diff cannot be hashed; nothing was written"*) true ;; *) false ;; esac \
  && ok "K20: a reviewed pair with no merge base writes no marker and says why" \
  || nok "K20: unrelated reviewed pair" "st=$kst out=$kout"
# K21 (PRE-FIX control, on the message): the reviewed pair is related but the base ref is
# not. 283c205 refused with the misleading "base moved" message.
kw main privacy "$KO1" "$KO2" "$KRUN"
[ "$kst" -eq 1 ] && [ ! -e "$KOMARK" ] \
  && case "$kout" in *"the base 'main' and the reviewed head ${KO2:0:12} share no merge base, so the reviewed diff cannot be hashed; nothing was written"*) true ;; *) false ;; esac \
  && ok "K21: a base ref with no merge base with the reviewed head writes no marker and says why" \
  || nok "K21: unrelated base ref" "st=$kst out=$kout"
git -C "$KR" checkout -q kfeat >/dev/null 2>&1

# K22/K23: the push hook accepts the marker of ANY local branch at the pushed commit, so
# --revoke must withdraw every one of them -- and only them.
KMDIR="$(dirname "$KMARK")"
git -C "$KR" branch -f ksib "$KH" >/dev/null 2>&1
git -C "$KR" branch -f kother "$KB" >/dev/null 2>&1
krun "$KH"
kw main privacy "$KB" "$KH" "$KRUN"
cp "$KMARK" "$KMDIR/ksib.json"; cp "$KMARK" "$KMDIR/kother.json"
kw --revoke "$KH"
# K22 (PRE-FIX control): 283c205 removed only the current branch's marker.
[ "$kst" -eq 0 ] && [ ! -e "$KMARK" ] && [ ! -e "$KMDIR/ksib.json" ] \
  && case "$kout" in *"withdrew the earlier PASS marker for 'kfeat'"*) true ;; *) false ;; esac \
  && case "$kout" in *"withdrew the earlier PASS marker for 'ksib'"*) true ;; *) false ;; esac \
  && ok "K22: --revoke withdraws the marker of every local branch at the reviewed commit, one line each" \
  || nok "K22: sibling marker survives revoke" "st=$kst out=$kout"
# K23 (WRONG-FIX control): green against 283c205 by construction. A branch at ANOTHER
# commit belongs to another run; the plausible wrong fix withdraws every marker.
[ -f "$KMDIR/kother.json" ] \
  && case "$kout" in *"'kother'"*) false ;; *) true ;; esac \
  && ok "K23: --revoke leaves the marker of a branch at a different commit alone" \
  || nok "K23: revoke reached another commit's marker" "out=$kout"
rm -f "$KMDIR/kother.json"

# K24 (PRE-FIX control): a directory at the marker path is not a marker -- no hook can
# read one -- so revoke skips it. 283c205 tried to rm it, failed, and exited 1.
mkdir "$KMARK"
kw --revoke "$KH"
[ "$kst" -eq 0 ] && [ -d "$KMARK" ] \
  && case "$kout" in *"could not withdraw"*) false ;; *) true ;; esac \
  && ok "K24: a directory at the marker path is skipped: --revoke exits 0 and leaves it" \
  || nok "K24: directory at marker path" "st=$kst out=$kout"
rmdir "$KMARK"

# K25 (WRONG-FIX control): green against 283c205 by construction. A SYMLINK at the
# marker path is still removed even when it points at a directory; the plausible wrong
# fix tests -d before -L and skips it.
mkdir -p "$TMP/k25target"; ln -s "$TMP/k25target" "$KMARK"
kw --revoke "$KH"
[ "$kst" -eq 0 ] && [ ! -L "$KMARK" ] && [ -d "$TMP/k25target" ] \
  && case "$kout" in *"withdrew the earlier PASS marker for 'kfeat'"*) true ;; *) false ;; esac \
  && ok "K25: a symlink at the marker path is removed (the link, not its target)" \
  || nok "K25: symlink at marker path" "st=$kst out=$kout"

# K26 (PRE-FIX control): on a DETACHED HEAD at the reviewed commit, revoke withdraws the
# markers of the branches at that commit AND the literal 'HEAD' key the writer uses
# there; 283c205 looked only for the literal 'HEAD' marker.
krun "$KH"
kw main privacy "$KB" "$KH" "$KRUN"
git -C "$KR" checkout -q --detach >/dev/null 2>&1
cp "$KMARK" "$KMDIR/HEAD.json"
kw --revoke "$KH"
git -C "$KR" checkout -q kfeat >/dev/null 2>&1
[ "$kst" -eq 0 ] && [ ! -e "$KMARK" ] && [ ! -e "$KMDIR/HEAD.json" ] && klastrun \
  && case "$kout" in *"withdrew the earlier PASS marker for 'kfeat'"*) true ;; *) false ;; esac \
  && case "$kout" in *"withdrew the earlier PASS marker for 'HEAD'"*) true ;; *) false ;; esac \
  && ok "K26: --revoke on a detached HEAD withdraws the markers of branches at that commit and the 'HEAD' key" \
  || nok "K26: detached HEAD revoke" "st=$kst out=$kout"
rm -f "$KMDIR/HEAD.json"

# K27 (PRE-FIX control): an UNBORN HEAD has no commit, so the current branch is never
# withdrawn, but the branches at the frozen commit still are. 283c205 died in
# `git rev-parse --abbrev-ref HEAD` under set -e; 72e9c2e, run under its own contract
# (bare --revoke), exited 0 and withdrew nothing, because it followed live HEAD.
KUNB="$TMP/kunborn"; mkrepo "$KUNB"
( cd "$KUNB" && echo u > u.txt && git add -A && git commit -qm u && git branch -M main \
   && git checkout -q --orphan kun ) >/dev/null 2>&1
KUC="$(git -C "$KUNB" rev-parse main)"
KUDIR="$(git -C "$KUNB" rev-parse --path-format=absolute --git-common-dir)/forgeward-gate-markers"
mkdir -p "$KUDIR"; printf '{}\n' > "$KUDIR/main.json"; printf '{}\n' > "$KUDIR/kun.json"
kout="$(cd "$KUNB" && "$WRITE" --revoke "$KUC" 2>&1)"; kst=$?
[ "$kst" -eq 0 ] && [ ! -e "$KUDIR/main.json" ] && [ -f "$KUDIR/kun.json" ] && klastrun \
  && case "$kout" in "forgeward gate: withdrew the earlier PASS marker for 'main'; it can no longer authorize a push."$'\n'RUN_ID=*) true ;; *) false ;; esac \
  && ok "K27: --revoke on an unborn HEAD withdraws the branches at the frozen commit and leaves the unborn branch's key" \
  || nok "K27: unborn HEAD revoke" "st=$kst out=$kout"

# K28..K37 -- the pre-landing review of 0.31.0. PRE-FIX controls are measured against
# `git show 72e9c2e:scripts/forgeward-write-marker.sh` run under its own contract.
KSUPER="a later gate run on ${KH:0:12} superseded this one (or no run is recorded for that commit); nothing was written. Re-run /forgeward:gate."
# After the write the refusal says what is true then: the marker, if still on disk, names
# a run that is no longer current, so no hook accepts it.
KSUPERW="a later gate run on ${KH:0:12} superseded this one (or no run is recorded for that commit); nothing it wrote can authorize a push. Re-run /forgeward:gate."
K28N="$(printf 'a%.0s' $(seq 64))"
K28MSG='rather than to itself; pass the full commit id Step 0 printed.'

# K28 (PRE-FIX control, D1): the full-id check is shape-only. In this SHA-1 repo a BRANCH
# named with 64 hex characters passes it and resolves to that branch's live tip, and an
# annotated tag's 40-hex object id peels to the commit -- so the moved-HEAD check passed
# vacuously and 72e9c2e wrote a marker for each. Both must resolve to THEMSELVES.
git -C "$KR" branch -f "$K28N" "$KH" >/dev/null 2>&1
git -C "$KR" -c tag.gpgsign=false tag -a -m k28 k28tag "$KH" >/dev/null 2>&1
K28T="$(git -C "$KR" rev-parse k28tag)"
rm -f "$KMARK"; krun "$KH"
kw main privacy "$KB" "$K28N" "$KRUN"; k28n_st=$kst; k28n_out=$kout; k28n_mark=0; [ -e "$KMARK" ] && k28n_mark=1
kw main privacy "$KB" "$K28T" "$KRUN"
git -C "$KR" tag -d k28tag >/dev/null 2>&1
[ "$k28n_st" -eq 64 ] && [ "$k28n_mark" = 0 ] && [ "$kst" -eq 64 ] && [ ! -e "$KMARK" ] \
  && [ "${#K28T}" -eq 40 ] && [ "$K28T" != "$KH" ] \
  && case "$k28n_out" in *"forgeward: reviewed head '$K28N' resolves to $KH $K28MSG"*) true ;; *) false ;; esac \
  && case "$kout" in *"forgeward: reviewed head '$K28T' resolves to $KH $K28MSG"*) true ;; *) false ;; esac \
  && ok "K28: a 64-hex branch name and an annotated tag's id as the reviewed head are refused with exit 64 -- each resolves to a commit other than itself" \
  || nok "K28: hex-shaped name accepted as the reviewed head" "branch=$k28n_st:$k28n_out tag=$kst:$kout"

# K29 (PRE-FIX control, D2): a tag created after the write and named like the branch
# makes `--abbrev-ref HEAD` and `%(refname:short)` both print `heads/kfeat`; 72e9c2e then
# looked only for `heads/kfeat.json`, left `kfeat.json` -- which the push hook still
# accepts through the destination-name lookup -- and exited 0. The sibling `ksib`, at the
# same commit but not checked out, is reachable only through the enumeration's canonical
# spelling, so it pins that half; K30 pins the current branch's.
krun "$KH"; kw main privacy "$KB" "$KH" "$KRUN"; k29_written=$kst
cp "$KMARK" "$KMDIR/ksib.json"
git -C "$KR" tag kfeat "$KH" >/dev/null 2>&1; git -C "$KR" tag ksib "$KH" >/dev/null 2>&1
kw --revoke "$KH"
git -C "$KR" tag -d kfeat ksib >/dev/null 2>&1
[ "$k29_written" -eq 0 ] && [ "$kst" -eq 0 ] && [ ! -e "$KMARK" ] && [ ! -e "$KMDIR/ksib.json" ] && klastrun \
  && case "$kout" in *"withdrew the earlier PASS marker for 'kfeat';"*) true ;; *) false ;; esac \
  && case "$kout" in *"withdrew the earlier PASS marker for 'ksib';"*) true ;; *) false ;; esac \
  && ok "K29: with tags named like the branches, --revoke still withdraws each bare <branch>.json and says so" \
  || nok "K29: same-named tag hides a marker from revoke" "written=$k29_written st=$kst out=$kout"
rm -f "$KMDIR/ksib.json"

# K30 (PRE-FIX control, D3): a branch ref pointing at a missing object makes the
# `--points-at` enumeration exit non-zero; 72e9c2e swallowed that, withdrew only the
# current branch and exited 0. Now it is reported, every other path is still tried, and
# the exit is 1 with no RUN_ID line. A tag named like the branch is present too, so with
# the enumeration gone the current branch's CANONICAL spelling is the only path left to
# `kfeat.json` -- this is where that spelling is pinned.
KBROKEN="$KCOMMON/refs/heads/kbroken"
krun "$KH"; kw main privacy "$KB" "$KH" "$KRUN"; k30_written=$kst
git -C "$KR" tag kfeat "$KH" >/dev/null 2>&1
printf '%s\n' 1234567890123456789012345678901234567890 > "$KBROKEN"
kw --revoke "$KH"
rm -f "$KBROKEN"
git -C "$KR" tag -d kfeat >/dev/null 2>&1
[ "$k30_written" -eq 0 ] && [ "$kst" -eq 1 ] && [ ! -e "$KMARK" ] && knorun \
  && case "$kout" in *"could not list the local branches at ${KH:0:12}, so an earlier PASS for one of them may still authorize a push. One cause is a branch ref that points at a missing object"*) true ;; *) false ;; esac \
  && case "$kout" in *"withdrew the earlier PASS marker for 'kfeat'"*) true ;; *) false ;; esac \
  && ok "K30: an unlistable branch set makes --revoke exit 1 and say so, still withdrawing the current branch, with no RUN_ID line" \
  || nok "K30: failed branch listing swallowed" "written=$k30_written st=$kst out=$kout"

# K31 (PRE-FIX control, D4): the checkout changed after Step 0 froze the commit. 72e9c2e
# followed live HEAD: it withdrew the checked-out branch's marker and left the reviewed
# commit's. The WRONG-FIX half -- the checked-out branch, at ANOTHER commit, keeps its
# marker -- pins that the frozen commit is not merely ADDED to what live HEAD selects.
krun "$KH"; kw main privacy "$KB" "$KH" "$KRUN"; k31_written=$kst
cp "$KMARK" "$KMDIR/kother.json"
git -C "$KR" checkout -q kother >/dev/null 2>&1
k31_head="$(git -C "$KR" rev-parse HEAD)"
kw --revoke "$KH"
git -C "$KR" checkout -q kfeat >/dev/null 2>&1
k31_frozen=0; k31_other=0
[ "$kst" -eq 0 ] && [ ! -e "$KMARK" ] \
  && case "$kout" in *"withdrew the earlier PASS marker for 'kfeat'"*) k31_frozen=1 ;; esac
[ -f "$KMDIR/kother.json" ] && case "$kout" in *"'kother'"*) ;; *) k31_other=1 ;; esac
[ "$k31_written" -eq 0 ] && [ "$k31_head" = "$KB" ] && [ "$k31_frozen" = 1 ] && [ "$k31_other" = 1 ] \
  && ok "K31: --revoke <frozen head> withdraws the reviewed commit's markers, not the checked-out branch's at another commit" \
  || nok "K31: revoke followed live HEAD" "frozen-withdrawn=$k31_frozen other-kept=$k31_other st=$kst out=$kout"
rm -f "$KMDIR/kother.json"

# K32 (PRE-FIX control, D5): run A starts, then run B on the same commit. A's write must
# be refused -- B may already have failed -- and B's must succeed. 72e9c2e had no run
# identity at all: after two bare revokes the four-argument write simply succeeded.
# A tries again AFTER B wrote, and B's marker must survive: A's marker would carry the
# same bytes (no field names the run), so only the check BEFORE the write keeps A from
# overwriting B's marker and then removing it as its own. The post-write re-read alone
# would leave the first half of this green.
rm -f "$KMARK"
krun "$KH"; K32A="$KRUN"
krun "$KH"; K32B="$KRUN"
kw main privacy "$KB" "$KH" "$K32A"; k32a_st=$kst; k32a_out=$kout; k32a_mark=0; [ -e "$KMARK" ] && k32a_mark=1
kw main privacy "$KB" "$KH" "$K32B"; k32b_st=$kst; k32b_out=$kout
kw main privacy "$KB" "$KH" "$K32A"
khex "$K32A" && khex "$K32B" && [ "$K32A" != "$K32B" ] \
  && [ "$k32a_st" -eq 1 ] && [ "$k32a_mark" = 0 ] \
  && case "$k32a_out" in *"forgeward: $KSUPER"*) true ;; *) false ;; esac \
  && [ "$k32b_st" -eq 0 ] && [ "$kst" -eq 1 ] && [ -f "$KMARK" ] \
  && case "$kout" in *"forgeward: $KSUPER"*) true ;; *) false ;; esac \
  && ok "K32: once a later run on the same commit has started, the earlier run's write is refused, before and after the later run's write succeeds" \
  || nok "K32: superseded run still wrote" "a=$k32a_st:$k32a_mark:$k32a_out b=$k32b_st:$k32b_out a-again=$kst:$kout"

# K33 (PRE-FIX control, D5's post-write re-read): a later run starts AFTER this writer's
# first read of the run file. A fake environment probe -- it runs after that read and
# before the write -- starts it, by running the copied writer's own --revoke, then answers
# with the real probe's line ($E1J, derived, not copied). The write must be undone.
# 72e9c2e has no run file and wrote the marker. The run-file control below proves the
# probe really started a new run; without it a probe that never ran would leave the
# assertion green for the wrong reason.
K33P="$TMP/k33plugin"; mkdir -p "$K33P"
cp "$PLUGIN/scripts/forgeward-write-marker.sh" "$PLUGIN/scripts/forgeward-diff-hash.sh" "$K33P/"
printf '%s\n' "$E1J" > "$K33P/env.line"
cat > "$K33P/forgeward-detect-environment.sh" <<'K33EOF'
#!/usr/bin/env bash
"$(dirname "$0")/forgeward-write-marker.sh" --revoke "$(git rev-parse HEAD)" >/dev/null 2>&1
cat "$(dirname "$0")/env.line"
K33EOF
chmod +x "$K33P"/*.sh
rm -f "$KMARK"; krun "$KH"; K33RUN="$KRUN"
kout="$(cd "$KR" && "$K33P/forgeward-write-marker.sh" main privacy "$KB" "$KH" "$K33RUN" 2>&1)"; kst=$?
K33NOW="$(cat "$KCOMMON/forgeward-gate-runs/$KH" 2>/dev/null)"
[ -n "$E1J" ] && khex "$K33RUN" && khex "$K33NOW" && [ "$K33NOW" != "$K33RUN" ] \
  && [ "$kst" -eq 1 ] && [ ! -e "$KMARK" ] \
  && case "$kout" in *"forgeward: $KSUPERW"*) true ;; *) false ;; esac \
  && ok "K33: a run that starts between the writer's first read and its write makes the writer remove its marker and refuse" \
  || nok "K33: marker outlived a newer run" "st=$kst run=$K33RUN now=$K33NOW mark=$([ -e "$KMARK" ] && echo present) out=$kout"

# K34 (WRONG-FIX control): green against 72e9c2e by construction (it has no run file). A
# revoke for a DIFFERENT commit supersedes nothing; the plausible wrong fix -- one global
# run file -- would refuse this write.
rm -f "$KMARK"; krun "$KH"; K34RUN="$KRUN"
kw --revoke "$KB"; k34_rv=$kst
kw main privacy "$KB" "$KH" "$K34RUN"
[ "$k34_rv" -eq 0 ] && [ "$kst" -eq 0 ] && [ -f "$KMARK" ] \
  && ok "K34: a revoke of a different commit does not supersede a run; its write still succeeds" \
  || nok "K34: a revoke elsewhere superseded the run" "revoke=$k34_rv st=$kst out=$kout"

# K35 (contract pin): the run id is required; the four-argument form this branch used
# before the pre-landing review is a usage error.
rm -f "$KMARK"; krun "$KH"
kw main privacy "$KB" "$KH"
[ "$kst" -eq 64 ] && [ ! -e "$KMARK" ] && case "$kout" in *"$KUSAGE"*) true ;; *) false ;; esac \
  && ok "K35: a write without the run id is a usage error and writes nothing" \
  || nok "K35: write without run id" "st=$kst out=$kout"

# K36 (contract pin): a run id must be the id itself. Pasting the whole `RUN_ID=<id>` line
# is refused with exit 64 naming where the id comes from -- not as "superseded", which
# would send the user to re-run a gate that was in fact current.
kw main privacy "$KB" "$KH" "RUN_ID=$KRUN"
[ "$kst" -eq 64 ] && [ ! -e "$KMARK" ] \
  && case "$kout" in *"forgeward: run id 'RUN_ID=$KRUN' must be the id from the RUN_ID=<id> line Step 2's --revoke printed"*) true ;; *) false ;; esac \
  && ok "K36: a malformed run id is refused with exit 64, naming the RUN_ID line it must come from" \
  || nok "K36: malformed run id" "st=$kst out=$kout"

# K37 (contract pin, D1 on the revoke side): --revoke's commit must resolve to itself as
# well, and it is checked BEFORE a run is recorded -- a refused revoke supersedes nothing.
K37BEFORE="$(cat "$KCOMMON/forgeward-gate-runs/$KH" 2>/dev/null)"
kw --revoke "$K28N"
K37AFTER="$(cat "$KCOMMON/forgeward-gate-runs/$KH" 2>/dev/null)"
git -C "$KR" branch -D "$K28N" >/dev/null 2>&1
[ "$kst" -eq 64 ] && knorun && [ -n "$K37BEFORE" ] && [ "$K37BEFORE" = "$K37AFTER" ] \
  && case "$kout" in *"forgeward: reviewed head '$K28N' resolves to $KH $K28MSG"*) true ;; *) false ;; esac \
  && ok "K37: --revoke with a 64-hex branch name is refused with exit 64 before any run is recorded" \
  || nok "K37: revoke accepted a hex-shaped name" "st=$kst before=$K37BEFORE after=$K37AFTER out=$kout"

# K38 (contract pin): a run that cannot be recorded must not be able to certify: an older
# run's write could still land. A directory at the run-file path is the root-proof way to
# make the record fail (`mv` would move the new file INTO it and report success). The
# revoke still withdraws, exits 1, says why, and prints no RUN_ID line.
krun "$KH"; kw main privacy "$KB" "$KH" "$KRUN"; k38_written=$kst
rm -f "$KCOMMON/forgeward-gate-runs/$KH"; mkdir "$KCOMMON/forgeward-gate-runs/$KH"
kw --revoke "$KH"
rmdir "$KCOMMON/forgeward-gate-runs/$KH" 2>/dev/null
[ "$k38_written" -eq 0 ] && [ "$kst" -eq 1 ] && [ ! -e "$KMARK" ] && knorun \
  && case "$kout" in *"could not record this gate run for ${KH:0:12} in $KCOMMON/forgeward-gate-runs/$KH, so an older run's write on that commit could still land"*) true ;; *) false ;; esac \
  && case "$kout" in *"withdrew the earlier PASS marker for 'kfeat'"*) true ;; *) false ;; esac \
  && ok "K38: a run that cannot be recorded makes --revoke exit 1 and say so, still withdrawing, with no RUN_ID line" \
  || nok "K38: unrecorded run" "written=$k38_written st=$kst out=$kout"

# K33b (contract pin): a newer run's marker lands at the same path between this writer's
# write and its second read. It is not the bytes this process wrote -- the marker now
# names its run, so two runs never write identical bytes -- so the writer must leave it
# alone, and still refuse. The run file is read with the `read` builtin, so there is no
# external command between the write and the second read to hook. Instead the newer run is
# split in two around them: a stand-in environment probe in a scratch copy of scripts/
# (it runs after the first read and before the write) starts the newer run with a
# `--revoke`, so the second read sees a newer id; then a `cat` shim on PATH, firing on the
# writer's `cat` of the MARKER in its superseded path, lands the newer run's write first.
# The newer run's id is checked, so a hook that never fired cannot leave this green.
# Mutation-checked: removing the byte comparison (the writer then removes whatever is at
# the path) turns it red.
K33BIN="$TMP/k33bbin"; mkdir -p "$K33BIN/scripts"
K33CAT="$(command -v cat)"
cp -p "$PLUGIN"/scripts/*.sh "$K33BIN/scripts/"
cat > "$K33BIN/scripts/forgeward-detect-environment.sh" <<K33BEOF
#!/usr/bin/env bash
if [ ! -e "$K33BIN/started" ]; then
  : > "$K33BIN/started"
  "$WRITE" --revoke "$KH" 2>/dev/null | sed -n 's/^RUN_ID=//p' > "$K33BIN/newer"
fi
K33BEOF
cat > "$K33BIN/cat" <<K33BEOF
#!/usr/bin/env bash
if [ ! -e "$K33BIN/fired" ] && [ -s "$K33BIN/newer" ] && [ "\${1:-}" = "$KMARK" ]; then
  : > "$K33BIN/fired"
  "$WRITE" main privacy "$KB" "$KH" "\$("$K33CAT" "$K33BIN/newer")" >/dev/null 2>&1 \
    || : > "$K33BIN/newer-refused"
fi
exec "$K33CAT" "\$@"
K33BEOF
chmod +x "$K33BIN/cat" "$K33BIN/scripts/forgeward-detect-environment.sh"
rm -f "$KMARK"; krun "$KH"; K33BRUN="$KRUN"
kout="$(cd "$KR" && PATH="$K33BIN:$PATH" "$K33BIN/scripts/forgeward-write-marker.sh" main privacy "$KB" "$KH" "$K33BRUN" 2>&1)"; kst=$?
K33BNEW="$("$K33CAT" "$K33BIN/newer" 2>/dev/null)"
khex "$K33BRUN" && khex "$K33BNEW" && [ "$K33BNEW" != "$K33BRUN" ] \
  && [ "$kst" -eq 1 ] && [ -f "$KMARK" ] && [ "$(kfield run_id)" = "$K33BNEW" ] \
  && case "$kout" in *"forgeward: $KSUPERW"*) true ;; *) false ;; esac \
  && ok "K33b: a newer run's marker written between this writer's write and its second read survives, and the writer still refuses" \
  || nok "K33b: superseded writer removed a newer run's marker or reported a PASS" \
         "st=$kst run=$K33BRUN newer=$K33BNEW on-disk-run=$(kfield run_id) out=$kout"

# K39 (PRE-FIX control: red on e9ab0e0, which pruned run files older than 30 days on every
# write): run files are never deleted. A prune selects a file and then deletes it BY PATH,
# so a revoke that atomically replaced that file in between -- a new gate run on a commit
# last gated long ago -- lost its fresh run file, and a same-diff PASS on another commit
# then authorized that commit while its review was pending. A write with a 40-day-old run
# file for another commit present must leave it byte-identical, and the count of run files
# must not drop (floor: at least two before the write). The age is set with python3, not
# `touch -d '40 days ago'`, which is GNU-only. Mutation-checked: re-adding the prune line
# turns this red.
K39OLD="$KCOMMON/forgeward-gate-runs/$(printf 'b%.0s' $(seq 40))"
printf 'x\n' > "$K39OLD"
python3 -I -c 'import os,sys,time
t=time.time()-40*86400; os.utime(sys.argv[1],(t,t))' "$K39OLD"
cp "$K39OLD" "$TMP/k39.copy"
rm -f "$KMARK"; krun "$KH"
k39_count() { find "$KCOMMON/forgeward-gate-runs" -type f | wc -l | tr -d ' '; }
k39_before="$(k39_count)"
kw main privacy "$KB" "$KH" "$KRUN"
k39_after="$(k39_count)"
[ "$k39_before" -ge 2 ] && [ "$kst" -eq 0 ] && [ -f "$KMARK" ] \
  && [ -f "$K39OLD" ] && cmp -s "$K39OLD" "$TMP/k39.copy" && [ "$k39_after" -ge "$k39_before" ] \
  && ok "K39: a marker write deletes no run file, however old: a 40-day-old one survives byte-identical and the count does not drop" \
  || nok "K39: a marker write deleted a run file" "st=$kst before=$k39_before after=$k39_after old=$([ -e "$K39OLD" ] && echo kept || echo deleted) out=$kout"
rm -f "$K39OLD"

# K40 (contract pin; green on e9ab0e0): a marker write leaves the marker of a sibling
# branch at ANOTHER commit byte-identical. Neither the write nor its GC may touch a live
# branch's marker.
git -C "$KR" branch -f kother "$KB" >/dev/null 2>&1
printf '{"schema":5,"passed":true,"branch":"kother"}\n' > "$KMDIR/kother.json"
cp "$KMDIR/kother.json" "$TMP/k40.copy"
rm -f "$KMARK"; krun "$KH"; kw main privacy "$KB" "$KH" "$KRUN"
[ "$kst" -eq 0 ] && [ -f "$KMARK" ] && [ -f "$KMDIR/kother.json" ] && cmp -s "$KMDIR/kother.json" "$TMP/k40.copy" \
  && ok "K40: a marker write leaves a sibling branch's marker at another commit byte-identical" \
  || nok "K40: a marker write changed a sibling branch's marker" "st=$kst out=$kout"
rm -f "$KMDIR/kother.json"

# K41: a run file gets the marker's mode, which the umask decides. Under 022 it is the
# PRE-FIX control (e9ab0e0 left every run file 0600, mktemp's mode, beside a 0644 marker);
# under 077 it is the WRONG-FIX control for a fixed `chmod 644`, which would make the run
# file readable where the marker is not. Modes are read with python3 (`stat -c` is GNU-only).
# Mutation-checked: dropping the chmod from record_run turns the 022 leg red.
kmode() { python3 -I -c 'import os,sys; print("%04o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$1" 2>/dev/null; }
k41() { # k41 <umask>: a gate run (revoke, then write) under <umask>; prints "<run-mode> <marker-mode>"
  local run
  rm -f "$KMARK" "$KCOMMON/forgeward-gate-runs/$KH"
  run="$(cd "$KR" && umask "$1" && "$WRITE" --revoke "$KH" 2>/dev/null | sed -n 's/^RUN_ID=//p')"
  ( cd "$KR" && umask "$1" && "$WRITE" main privacy "$KB" "$KH" "$run" ) >/dev/null 2>&1 || return 1
  printf '%s %s\n' "$(kmode "$KCOMMON/forgeward-gate-runs/$KH")" "$(kmode "$KMARK")"
}
k41_022="$(k41 022)"; k41_077="$(k41 077)"
[ "$k41_022" = "0644 0644" ] && [ "$k41_077" = "0600 0600" ] \
  && ok "K41: a run file's mode equals its marker's: 0644 under umask 022, 0600 under 077" \
  || nok "K41: a run file's mode differs from its marker's" "022: ${k41_022:-write failed}; 077: ${k41_077:-write failed} (run marker)"

# =============================================================================
# F1..F10 -- both hooks accept a PASS only while the gate run that wrote it is still the
# latest on the commit it reviewed, and never for a pushed commit that a gate run has
# started on unless it is that commit (`run_is_current`, 0.31.0). These drive the fast
# reminder, forgeward-gate-check.sh; P30-P39 in test/pre-push-test.sh drive the enforced
# hook through the same cases. Every refusal below is built with the marker still ON
# DISK and its diff hash still matching, so what refuses it is the run file, not revoke's
# deletions (P41 in test/pre-push-test.sh pins what those still do). F3-F5 and F7-F10 are PRE-FIX controls -- 6e11899's hooks allow
# each of those pushes. F2 and F6 are positive controls and the WRONG-FIX controls for
# the plausible over-fix of refusing any pushed commit other than the reviewed one: F6 is
# the /ship flow, a VERSION-only commit after the PASS with no gate run of its own.
# Mutation-checked: with run_is_current made to always succeed, F3-F5 and F7-F10 go red
# while F2 and F6 stay green. The fast reminder consults only the checked-out branch's
# marker, so the sibling-branch case is pinned on the enforced hook only (P39).
# =============================================================================
# F1: run_is_current must stay byte-identical in both hooks, on A19's pattern -- the
# bodies compared, each required non-empty so a broken extraction fails loudly.
_rc_body() { awk '/^run_is_current\(\)/{f=1;next} f{print} f&&/^\}$/{exit}' "$1"; }
_rc_a="$(_rc_body "$PLUGIN/scripts/forgeward-gate-check.sh")"
_rc_b="$(_rc_body "$PLUGIN/scripts/forgeward-pre-push.sh")"
if [ -n "$_rc_a" ] && [ -n "$_rc_b" ] && [ "$_rc_a" = "$_rc_b" ]; then
  ok "F1: run_is_current is byte-identical in gate-check.sh and pre-push.sh"
else
  nok "F1: run_is_current has drifted between gate-check.sh and pre-push.sh" \
      "$({ [ -z "$_rc_a" ] || [ -z "$_rc_b" ]; } && echo 'extraction returned nothing -- the function shape changed' || diff <(printf '%s\n' "$_rc_a") <(printf '%s\n' "$_rc_b") | tr '\n' ' ')"
fi

FR="$TMP/fresh"; mkrepo "$FR"
( cd "$FR" && echo a > a.txt && git add -A && git commit -qm base && git branch -M main \
   && git checkout -qb ffeat && echo 'const f = 1;' > f.js && git add -A && git commit -qm work ) >/dev/null 2>&1
FB="$(git -C "$FR" rev-parse main)"; FC="$(git -C "$FR" rev-parse refs/heads/ffeat)"
FCOMMON="$(git -C "$FR" rev-parse --path-format=absolute --git-common-dir)"
FMD="$FCOMMON/forgeward-gate-markers"; FRUNS="$FCOMMON/forgeward-gate-runs"
# fgate <commit>: a gate run on <commit> from the current checkout that PASSes -- revoke
# (which mints the run; FRUN keeps its id), then the write with that id.
fgate() {
  FRUN="$(cd "$FR" && "$WRITE" --revoke "$1" 2>/dev/null | sed -n 's/^RUN_ID=//p')"
  ( cd "$FR" && "$WRITE" main privacy "$FB" "$1" "$FRUN" ) >/dev/null 2>&1
}
frevoke() { ( cd "$FR" && "$WRITE" --revoke "$1" ) >/dev/null 2>&1; }
fallowed() { fout="$(pretool "$FR" "git push origin HEAD")"; [ -z "$fout" ]; }
fdenied() { # fdenied <label>: denied, naming the branch the reminder evaluated
  fout="$(pretool "$FR" "git push origin HEAD")"
  denies "$fout" && case "$fout" in *"the current branch ($1 @ "*"has not passed /forgeward:gate"*) true ;; *) false ;; esac
}
fset() { # fset <marker> <key> [<json-value>]: rewrite one field of a fixture marker; no value deletes it
  python3 -I -c 'import json,sys
p,k=sys.argv[1],sys.argv[2]; d=json.load(open(p))
if len(sys.argv)>3: d[k]=json.loads(sys.argv[3])
else: d.pop(k,None)
open(p,"w").write(json.dumps(d,indent=2)+"\n")' "$@"
}
fout=""   # set -u: a failed fgate short-circuits before fallowed/fdenied assign it

# F2 (positive control, case j): a plain PASS from the latest run on the pushed commit.
fgate "$FC"
[ -f "$FMD/ffeat.json" ] && khex "$FRUN" && fallowed \
  && ok "F2: a PASS from the latest gate run on the checked-out commit is accepted" \
  || nok "F2: a current PASS was refused" "run=$FRUN out=$fout"

# F3 (PRE-FIX control, case a): a killed writer's marker restored after a newer run's
# revoke deleted it -- the same bytes, so the same diff hash.
cp "$FMD/ffeat.json" "$TMP/f3.json"
frevoke "$FC"; f3_deleted=0; [ -e "$FMD/ffeat.json" ] || f3_deleted=1
cp "$TMP/f3.json" "$FMD/ffeat.json"
[ "$f3_deleted" = 1 ] && fdenied ffeat \
  && ok "F3: a marker restored after a newer run started on its commit is refused" \
  || nok "F3: a superseded run's marker was accepted" "deleted=$f3_deleted out=$fout"

# F4 (PRE-FIX control, case e): a schema-4 marker, which has no run_id, while the run
# file still holds the run that wrote it -- the upgrade path costs one re-gate.
fgate "$FC"; fset "$FMD/ffeat.json" run_id; fset "$FMD/ffeat.json" schema 4
[ "$(cat "$FRUNS/$FC" 2>/dev/null)" = "$FRUN" ] && fdenied ffeat \
  && ok "F4: a schema-4 marker (no run_id) is refused even while its run is current" \
  || nok "F4: a marker without run_id was accepted" "out=$fout"

# F5 (PRE-FIX control, case f): the run file is gone, as after a by-hand delete.
fgate "$FC"; rm -f "$FRUNS/$FC"
[ -f "$FMD/ffeat.json" ] && fdenied ffeat \
  && ok "F5: a marker whose run file is missing is refused" \
  || nok "F5: a marker with no run file was accepted" "out=$fout"

# F6 (positive and WRONG-FIX control, case h): the /ship flow. A VERSION-only commit
# after the PASS has the same diff and no gate run of its own, so the PASS still holds.
fgate "$FC"
( cd "$FR" && echo 1.0.1 > VERSION && git add VERSION && git commit -qm "chore: bump version" ) >/dev/null 2>&1
FV="$(git -C "$FR" rev-parse HEAD)"
[ "$FV" != "$FC" ] && [ ! -e "$FRUNS/$FV" ] && fallowed \
  && ok "F6: a VERSION-only commit after the PASS, with no gate run of its own, is accepted (the /ship flow)" \
  || nok "F6: the /ship version bump was refused" "out=$fout"

# F7 (PRE-FIX control, case g): a malformed run_id or reviewed_head is refused, and no
# file outside forgeward-gate-runs/ is read. Each case PLANTS the file the bad value
# would name, holding the id it would need, so only the shape check stands between it
# and an accept: `../planted` names a file one level up, which holds the run id. The tip
# is F6's VERSION commit, which has no run file, so nothing else can refuse it. The
# unmodified marker in the same state is the control.
cp "$FMD/ffeat.json" "$TMP/f7.json"
fallowed; f7_ctl=$?
FUP="$(printf '%s' "$FC" | tr 'a-f' 'A-F')"; FRUP="$(printf '%s' "$FRUN" | tr 'a-f' 'A-F')"
f7_fail=""
f7() { # f7 <label> <key> <value> <plant-path> <plant-line>
  cp "$TMP/f7.json" "$FMD/ffeat.json"; fset "$FMD/ffeat.json" "$2" "\"$3\""
  printf '%s\n' "$5" > "$4"
  fdenied ffeat || f7_fail="$f7_fail $1"
  rm -f "$4"; printf '%s\n' "$FRUN" > "$FRUNS/$FC"
}
f7 head-dotdot reviewed_head ../planted "$FCOMMON/planted" "$FRUN"
f7 head-upper reviewed_head "$FUP" "$FRUNS/$FUP" "$FRUN"
f7 head-short reviewed_head "${FC:0:12}" "$FRUNS/${FC:0:12}" "$FRUN"
f7 run-upper run_id "$FRUP" "$FRUNS/$FC" "$FRUP"
f7 run-short run_id "${FRUN:0:12}" "$FRUNS/$FC" "${FRUN:0:12}"
cp "$TMP/f7.json" "$FMD/ffeat.json"
[ "$f7_ctl" = 0 ] && [ -z "$f7_fail" ] \
  && ok "F7: a run_id or reviewed_head that is not a full lowercase id is refused, even with the file it names planted" \
  || nok "F7: a malformed run_id or reviewed_head was accepted" "control=$f7_ctl accepted:$f7_fail"

# F8 (PRE-FIX control, case c): the same diff on another commit. PASS on ffeat at C1;
# C2 is C1 with a reworded message; a gate run starts on C2 (and FAILs) while ffeat is
# still at C1, then ffeat moves to C2. The C1 marker is untouched and its hash matches.
( cd "$FR" && git checkout -q main && git branch -f ffeat "$FC" && git checkout -q ffeat ) >/dev/null 2>&1
fgate "$FC"
( cd "$FR" && git checkout -qb ftmp && git commit -q --amend -m "work (reworded)" ) >/dev/null 2>&1
FC2="$(git -C "$FR" rev-parse refs/heads/ftmp)"
frevoke "$FC2"
( cd "$FR" && git branch -f ffeat "$FC2" && git checkout -q ffeat ) >/dev/null 2>&1
[ "$FC2" != "$FC" ] && [ -f "$FMD/ffeat.json" ] && [ -e "$FRUNS/$FC2" ] && fdenied ffeat \
  && ok "F8: a PASS for one commit is refused for another with the same diff once a gate run started there" \
  || nok "F8: a PASS crossed onto a commit with its own gate run" "c1=$FC c2=$FC2 out=$fout"

# F9 (PRE-FIX control, case d): a PASS written on a detached HEAD (key `HEAD`), then a
# newer run on that commit started from a branch checkout, which never visits that key.
( cd "$FR" && git checkout -qb fdet main && echo d > d.js && git add -A && git commit -qm det \
   && git checkout -q --detach ) >/dev/null 2>&1
FDC="$(git -C "$FR" rev-parse HEAD)"
fgate "$FDC"; fallowed; f9_before=$?
( cd "$FR" && git checkout -q fdet ) >/dev/null 2>&1
frevoke "$FDC"
( cd "$FR" && git checkout -q --detach ) >/dev/null 2>&1
[ "$f9_before" = 0 ] && [ -f "$FMD/HEAD.json" ] && fdenied HEAD \
  && ok "F9: a detached-HEAD PASS is refused once a newer run starts on its commit, with HEAD.json still on disk" \
  || nok "F9: a detached-HEAD PASS outlived a newer run" "before=$f9_before out=$fout"

# F10 (PRE-FIX control, case b): a branch and a same-named tag, so the PASS lands at
# heads/<name>.json; the tag is deleted, a newer run's revoke looks only under the bare
# name, and the tag comes back.
( cd "$FR" && git checkout -qb fsp main && echo s > s.js && git add -A && git commit -qm sp \
   && git tag fsp ) >/dev/null 2>&1
FSC="$(git -C "$FR" rev-parse refs/heads/fsp)"
fgate "$FSC"; fallowed; f10_before=$?
f10_written=0; [ -f "$FMD/heads/fsp.json" ] && f10_written=1
git -C "$FR" tag -d fsp >/dev/null 2>&1; frevoke "$FSC"; git -C "$FR" tag fsp "$FSC" >/dev/null 2>&1
[ "$f10_written" = 1 ] && [ "$f10_before" = 0 ] && [ -f "$FMD/heads/fsp.json" ] && fdenied heads/fsp \
  && ok "F10: a PASS under the heads/<name> spelling is refused once a newer run starts on its commit" \
  || nok "F10: the stale heads/<name> PASS was accepted" "written=$f10_written before=$f10_before out=$fout"

# F11: is_fresh and snapshot_is_fresh must stay byte-identical in both hooks, F1's
# pattern with the definition line included, so the usage comment is pinned too. Each
# extraction is required non-empty and to start with its own definition.
_fn_text() { awk -v fn="$2" 'index($0, fn "() {")==1{f=1} f{print} f&&/^\}$/{exit}' "$1"; }
f11_fail=""
for _fn in is_fresh snapshot_is_fresh; do
  _fa="$(_fn_text "$PLUGIN/scripts/forgeward-gate-check.sh" "$_fn")"
  _fb="$(_fn_text "$PLUGIN/scripts/forgeward-pre-push.sh" "$_fn")"
  case "$_fa" in "$_fn() {"*) ;; *) f11_fail="$f11_fail $_fn:extraction" ;; esac
  [ -n "$_fa" ] && [ "$_fa" = "$_fb" ] || f11_fail="$f11_fail $_fn:drift"
done
[ -z "$f11_fail" ] \
  && ok "F11: is_fresh and snapshot_is_fresh are byte-identical in gate-check.sh and pre-push.sh" \
  || nok "F11: the marker-snapshot functions drifted between the hooks" "failed:$f11_fail"

# F12: the reminder reads a marker ONCE. A scratch copy of scripts/ whose
# forgeward-diff-hash.sh FIRST moves a prepared marker over a named one, THEN execs the
# real helper, so the swap lands between the reads of .diff_hash and .run_id with no
# sleep. Fixture: PASS on ship at C (M1); a VERSION-only C2 on top, same diff; a second
# run on C makes M1's run stale; M2 is a current PASS for a DIFFERENT diff (D, on d).
# Leg 1 (M1 alone) and leg 2 (M2 in place before the check) are controls; leg 3 (M1 in
# place, M2 swapped in mid-check) is the PRE-FIX control -- e9ab0e0 takes M1's hash and
# M2's run and allows the push; leg 4 is the positive control, a current PASS swapped
# for an identical copy of itself. A `.fired` file proves each swap really ran.
# Mutation-checked: handing run_is_current the marker PATH instead of the copy turns
# leg 3 red.
SW="$TMP/swap"; mkdir -p "$SW/scripts"
cp -p "$PLUGIN"/scripts/*.sh "$SW/scripts/"
mv "$SW/scripts/forgeward-diff-hash.sh" "$SW/scripts/real-diff-hash.sh"
cat > "$SW/scripts/forgeward-diff-hash.sh" <<'SWEOF'
#!/usr/bin/env bash
if [ -n "${FORGEWARD_SWAP_FROM:-}" ] && [ -f "$FORGEWARD_SWAP_FROM" ]; then
  mv -f "$FORGEWARD_SWAP_FROM" "$FORGEWARD_SWAP_TO" && : > "$FORGEWARD_SWAP_FROM.fired"
fi
exec "$(dirname "$0")/real-diff-hash.sh" "$@"
SWEOF
chmod +x "$SW/scripts/forgeward-diff-hash.sh"
SR="$TMP/swaprepo"; mkrepo "$SR"
( cd "$SR" && echo 0.1.0 > VERSION && echo base > a.txt && git add -A && git commit -qm base \
   && git branch -M main && git checkout -qb ship && echo 'const s = 1;' > s.js && git add -A \
   && git commit -qm feat ) >/dev/null 2>&1
SB="$(git -C "$SR" rev-parse main)"; SC="$(git -C "$SR" rev-parse HEAD)"
SMD="$(git -C "$SR" rev-parse --path-format=absolute --git-common-dir)/forgeward-gate-markers"
sgate() { # sgate <commit>: a passing gate run on <commit> from the current checkout
  local run
  run="$(cd "$SR" && "$WRITE" --revoke "$1" 2>/dev/null | sed -n 's/^RUN_ID=//p')"
  ( cd "$SR" && "$WRITE" main privacy "$SB" "$1" "$run" ) >/dev/null 2>&1
}
sgate "$SC"
( cd "$SR" && echo 0.2.0 > VERSION && git commit -qam 'chore: bump version' ) >/dev/null 2>&1
cp "$SMD/ship.json" "$TMP/f12.m1"
( cd "$SR" && "$WRITE" --revoke "$SC" ) >/dev/null 2>&1
( cd "$SR" && git checkout -qb d main && echo 'const d = 1;' > d.js && git add -A && git commit -qm d ) >/dev/null 2>&1
SD="$(git -C "$SR" rev-parse HEAD)"; sgate "$SD"; cp "$SMD/d.json" "$TMP/f12.m2"
git -C "$SR" checkout -q ship >/dev/null 2>&1
spre() { # spre <swap-from> <swap-to>: the copied reminder on `git push`; stdout = decision
  printf '{"cwd":"%s","tool_input":{"command":"git push origin HEAD"}}' "$SR" \
    | FORGEWARD_SWAP_FROM="$1" FORGEWARD_SWAP_TO="$2" "$SW/scripts/forgeward-gate-check.sh" pretooluse
}
cp "$TMP/f12.m1" "$SMD/ship.json"; f12_1="$(spre "" "")"
cp "$TMP/f12.m2" "$SMD/ship.json"; f12_2="$(spre "" "")"
cp "$TMP/f12.m1" "$SMD/ship.json"; cp "$TMP/f12.m2" "$TMP/f12.swap"
f12_3="$(spre "$TMP/f12.swap" "$SMD/ship.json")"; f12_3f=0; [ -e "$TMP/f12.swap.fired" ] && f12_3f=1
git -C "$SR" checkout -q d >/dev/null 2>&1
cp "$SMD/d.json" "$TMP/f12.same"
f12_4="$(spre "$TMP/f12.same" "$SMD/d.json")"; f12_4f=0; [ -e "$TMP/f12.same.fired" ] && f12_4f=1
git -C "$SR" checkout -q ship >/dev/null 2>&1
denies "$f12_1" && denies "$f12_2" && [ "$f12_3f" = 1 ] && denies "$f12_3" \
  && case "$f12_3" in *"the current branch (ship @ "*"has not passed /forgeward:gate"*) true ;; *) false ;; esac \
  && [ "$f12_4f" = 1 ] && [ -z "$f12_4" ] \
  && ok "F12: a marker swapped in while the reminder hashes cannot lend its run to the stale PASS it replaced" \
  || nok "F12: the reminder combined two markers' fields" \
         "m1-alone=$(denies "$f12_1" && echo denied || echo allowed) m2-alone=$(denies "$f12_2" && echo denied || echo allowed) swap=$f12_3f:$(denies "$f12_3" && echo denied || echo allowed) same=$f12_4f:${f12_4:-allowed}"

echo "1..$((PASS+FAIL))"
echo "# pass $PASS / fail $FAIL"
[ "$FAIL" -eq 0 ]
