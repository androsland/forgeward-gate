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
# Its own repo, and deliberately WITHOUT any of the three version-bearing manifests:
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
  "$WRITE" main "privacy" ) >/dev/null 2>&1

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
else
  ok "forgeward-scan gitleaks untracked-.env exposure: SKIPPED (gitleaks not installed)"
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
# here, and the one-time re-gate is the accepted cost stated in the script header.
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
# is FULL mode for the caller, so this direction is safe either way — asserted so the
# distinction between "absent" and "you called it wrong" does not quietly disappear.
[ "$(det "$D1" 'cso/../../etc')" = 2 ] \
  && ok "detect: a path-shaped argument is a usage error, never a match" \
  || nok "detect D12" "expected 2"

# --- E1..E11: environment disclosure (Option B standalone posture) ---------------
# forgeward is scoped as a DELTA against gstack, so what a PASS covers depends on what
# else is installed. 0.8.0 makes that visible instead of leaving it to a README table:
# the gate DISCLOSES an unowned axis and gates anyway. These pin the probe that decision
# reads from.
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
# then pass while proving nothing. E2 is the positive control that makes that detectable:
# it must come back "present" from the same harness, so a change that hard-wires the
# probe to "absent" turns E2 red instead of quietly greening E1.
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
EM="$TMP/envmarker"; mkrepo "$EM"
( cd "$EM" && echo a > a.txt && git add -A && git commit -qm base && git branch -M master \
   && echo b > b.txt && git add -A && git commit -qm work && git checkout -q -b feat \
   && "$PLUGIN/scripts/forgeward-write-marker.sh" master "security" ) >/dev/null 2>&1
EMJ="$(cd "$EM" && git rev-parse --path-format=absolute --git-common-dir)/forgeward-gate-markers/feat.json"
[ -f "$EMJ" ] \
  && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["schema"]==4 and isinstance(d["environment"],dict) and "gstack_ship" in d["environment"] and "seo_posture" in d["environment"] else 1)' "$EMJ" \
  && ok "env: the pass marker is schema 4 and carries a readable environment object" \
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
   && "$FAKE_PLUGIN/forgeward-write-marker.sh" master "security" ) >/dev/null 2>&1
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
     && "$d/forgeward-write-marker.sh" master "security" ) >/dev/null 2>&1
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
   && CLAUDE_CONFIG_DIR="$EMPTY_CFG" "$PLUGIN/scripts/forgeward-write-marker.sh" master "security" \
) >/dev/null 2>&1
E37J="$(cd "$E37R" && git rev-parse --path-format=absolute --git-common-dir)/forgeward-gate-markers/feat.json"
[ -f "$E37J" ] \
  && python3 -I -c 'import json,sys; e=json.load(open(sys.argv[1]))["environment"]; sys.exit(0 if e.get("config_warnings")==1 and isinstance(e["config_warnings"],int) and not isinstance(e["config_warnings"],bool) else 1)' "$E37J" \
  && ok "env: config_warnings reaches the marker as a JSON number, not a quoted string" \
  || nok "env E37" "marker '$E37J'"

# =============================================================================
# R1..R7 — the ported quality rubrics' drift check.
#
# forgeward's five quality reviewers are PORTS of gstack's Review Army specialist
# checklists, not runtime reads of them, so the axis works on a machine with no gstack
# at all. The cost of a port is drift: gstack can improve a checklist and nothing here
# would know. `forgeward-rubric-drift.sh` is the cheap closing of that loop — five
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
  *"ok       alpha-reviewer"*"1 ported rubric(s) checked"*)
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

# R6: THE FLOOR, and the only assertion here that touches the shipped tree. Everything
# above runs on a synthetic fixture, so all six would pass unchanged if the real
# `agents/` directory carried no provenance blocks at all and the drift check covered
# nothing. This counts the real ported rubrics and requires all five — and it requires
# BOTH fields, because the script skips any reviewer missing either one and a
# half-recorded port is silently unchecked rather than loudly broken.
#
# The two sed expressions below are a DELIBERATE copy of the script's own, not a call
# into it, and the duplication is the cost of what R6 is for: every other assertion
# here drives a synthetic fixture, so R6 has to read the SHIPPED tree with no fixture
# in the path at all. Running the script over the real agents/ would need a synthetic
# gstack root holding copies of the five real rubrics, which reintroduces exactly the
# fixture dependence R6 exists to escape. The exposure is that a future loosening of
# the script's regex would not show up here -- accepted, and named rather than left
# for the next reader to discover.
_r6n=0; _r6bad=""
for _f in "$PLUGIN"/agents/*-reviewer.md; do
  [ -f "$_f" ] || continue
  _has_p="$(sed -n 's/^ *source-path: *\(.*[^ ]\) *$/\1/p' "$_f" | head -1)"
  _has_s="$(sed -n 's/^ *source-sha256: *\([0-9a-f]\{64\}\) *$/\1/p' "$_f" | head -1)"
  if [ -n "$_has_p" ] && [ -n "$_has_s" ]; then
    _r6n=$((_r6n+1))
  elif [ -n "$_has_p" ] || [ -n "$_has_s" ]; then
    _r6bad="$_r6bad $(basename "$_f")"
  fi
done
[ "$_r6n" -ge 5 ] && [ -z "$_r6bad" ] \
  && ok "drift: all $_r6n shipped ported rubrics record BOTH source-path and a 64-hex source-sha256 (the fixtures above are not the only thing covered)" \
  || nok "drift R6: a ported rubric is not drift-checkable" "complete: $_r6n (expected >= 5) | half-recorded:${_r6bad:- none}"

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
    *"ok       alpha-reviewer"*"1 ported rubric(s) checked"*)
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
  *"1 ported rubric(s) checked"*)
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

# A25: no `python3 -c` in shipped code without `-I`.
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
_a25_bad="$(grep -rn --include='*.sh' -E '^[^#]*python3 -c' "$PLUGIN/scripts" "$PLUGIN/ci" 2>/dev/null || true)"
_a25_good="$(grep -rc --include='*.sh' -E '^[^#]*python3 -I -c' "$PLUGIN/scripts" "$PLUGIN/ci" 2>/dev/null \
             | awk -F: '{n+=$2} END{print n+0}')"
if [ -z "$_a25_bad" ] && [ "$_a25_good" -ge 5 ]; then
  ok "A25: every python3 -c in shipped code carries -I ($_a25_good sites flagged, 0 unflagged)"
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
  sed 's/python3 -I -c/python3 -c/g' "$PLUGIN/scripts/forgeward-gate-check.sh" > "$_a26_mut/forgeward-gate-check.sh"
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

# --- A30/A31: /forgeward:audit's read-only contract is STRUCTURAL, so pin the structure --
#
# README, skills/gate/SKILL.md and the audit skill itself all claim the same thing: the
# audit cannot write, because its frontmatter declares an `allowed-tools` list holding
# neither `Edit` nor `Write`. That claim is load-bearing in two places at once — it is why
# the gate says the audit could survive Step 2's workspace guard (unlike `/review`), and it
# is why the skill can be pointed at someone else's repository at all.
#
# THE OBVIOUS TEST IS THE WRONG ONE, and this is the whole reason A30 is shaped as it is.
# `grep -q Write skills/audit/SKILL.md` returning nothing does NOT establish the property:
# a skill with NO `allowed-tools` key at all is granted every tool, so deleting the key
# makes the claim false while making the naive grep greener. The floor is therefore part
# of the assertion — the key must exist and the list must be non-empty — exactly the
# "assert the violating form, guard the enumeration against emptiness" rule in CLAUDE.md.
#
# Scoped to this one skill on purpose. `skills/ci-gate` legitimately writes workflow files
# and `skills/gate` declares no tool list, so there is no repo-wide property here to
# enumerate; a sweep over `skills/*/SKILL.md` would either fail on correct files or be
# relaxed until it asserted nothing.
_a30_skill="$PLUGIN/skills/audit/SKILL.md"
if [ ! -f "$_a30_skill" ]; then
  nok "A30: skills/audit/SKILL.md is missing — the deep-audit axis has no owner in this tree" \
      "the gate's Step 1c names /forgeward:audit as the owner of the axis"
else
  # Frontmatter only: the body quotes tool names while describing what the phases do.
  _a30_fm="$(sed -n '2,/^---[[:cntrl:][:space:]]*$/p' "$_a30_skill")"
  # The list is a YAML block sequence under `allowed-tools:` — take the `- Item` lines
  # that follow it, stopping at the next unindented key.
  _a30_tools="$(printf '%s\n' "$_a30_fm" | awk '
      /^allowed-tools:[[:space:]]*$/ { inlist=1; next }
      inlist && /^[[:space:]]*-[[:space:]]*[A-Za-z]/ { sub(/^[[:space:]]*-[[:space:]]*/,""); print; next }
      inlist && /^[^[:space:]-]/ { inlist=0 }
    ')"
  _a30_n="$(printf '%s' "$_a30_tools" | grep -c . || true)"
  _a30_bad="$(printf '%s\n' "$_a30_tools" | grep -xE 'Edit|Write|NotebookEdit|MultiEdit' || true)"
  if [ "$_a30_n" -ge 3 ] && [ -z "$_a30_bad" ]; then
    ok "A30: /forgeward:audit declares $_a30_n allowed tools and none of them can write (the read-only claim is structural, and the non-empty floor is what stops a deleted key passing)"
  else
    nok "A30: /forgeward:audit's read-only contract does not hold as written" \
        "writing tools:${_a30_bad:- none} | tools enumerated: $_a30_n (expected >= 3; 0 means the allowed-tools key is absent, which grants EVERY tool)"
  fi

  # A31: the port records where it came from. Same two fields the five ported reviewers
  # carry (assertion R6's subject), for the same reason — without both, re-porting after
  # an upstream change is guesswork.
  #
  # NON-GOAL, stated because a green A31 must not be read as drift coverage:
  # scripts/forgeward-rubric-drift.sh iterates `agents/*-reviewer.md` and nothing else, so
  # these two fields are RECORDED and UNCHECKED. Extending the drift check to `skills/` is
  # filed in TODOS.md; this assertion is what makes that extension possible, not a
  # substitute for it.
  _a31_path="$(sed -n 's/^ *source-path: *\(.*[^ ]\) *$/\1/p' "$_a30_skill" | head -1)"
  _a31_sha="$(sed -n 's/^ *source-sha256: *\([0-9a-f]\{64\}\) *$/\1/p' "$_a30_skill" | head -1)"
  _a31_commit="$(sed -n 's/^ *source-commit: *\([0-9a-f]\{40\}\) *$/\1/p' "$_a30_skill" | head -1)"
  if [ -n "$_a31_path" ] && [ -n "$_a31_sha" ] && [ -n "$_a31_commit" ]; then
    ok "A31: /forgeward:audit records source-path, a 40-hex source-commit and a 64-hex source-sha256 (re-porting after an upstream change is not guesswork)"
  else
    nok "A31: /forgeward:audit's provenance block is incomplete — the port cannot be re-derived" \
        "path:${_a31_path:-MISSING} commit:${_a31_commit:-MISSING} sha256:${_a31_sha:+present}${_a31_sha:-MISSING}"
  fi
fi

echo "1..$((PASS+FAIL))"
echo "# pass $PASS / fail $FAIL"
[ "$FAIL" -eq 0 ]
