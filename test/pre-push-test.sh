#!/usr/bin/env bash
# Regression suite for the forgeward pre-push ENFORCER (scripts/forgeward-pre-push.sh).
#
# Drives it exactly as git does: argv = `<remote> <url>`, and on stdin one line per
# ref being pushed: `<local-ref> <local-sha> <remote-ref> <remote-sha>`. Because git
# supplies concrete refs+SHAs, this layer needs no command parsing — the shell-text
# bypasses that plagued the PreToolUse hook simply don't exist here. Framework-free.
set -uo pipefail
PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREPUSH="$PLUGIN/scripts/forgeward-pre-push.sh"
INSTALL="$PLUGIN/scripts/forgeward-install-pre-push.sh"
WRITE="$PLUGIN/scripts/forgeward-write-marker.sh"
# The writer takes the reviewed commits and the gate run's id since 0.31.0. Every caller
# here gates the commit it just made, so both are resolved in the caller's cwd at call
# time, and the run is minted the way Step 2 mints it: a `--revoke` of that commit, whose
# `RUN_ID=` line is taken and whose other output is kept off this helper's stdout. That
# revoke withdraws the marker of every branch at the commit (see P29).
write_marker() { # write_marker <base-ref> <fired-csv>
  local head run
  head="$(git rev-parse HEAD)"
  run="$("$WRITE" --revoke "$head" | sed -n 's/^RUN_ID=//p')"
  "$WRITE" "$1" "$2" "$(git rev-parse "$1")" "$head" "$run"
}
ZERO='0000000000000000000000000000000000000000'
RSHA='1111111111111111111111111111111111111111'   # arbitrary "remote" sha (hook ignores it)
ORIGINAL_PATH="$PATH"

PASS=0; FAIL=0; CAPTURE_LEAK=0
ok()  { PASS=$((PASS+1)); printf 'ok %d - %s\n' "$((PASS+FAIL))" "$1"; }
nok() { FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$((PASS+FAIL))" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; }

# run the enforcer from <cwd> with <stdin-lines>; sets RC (exit) and OUT (merged output)
pp_remote() { # pp_remote <cwd> <stdin-lines> <remote-name>
  OUT="$( cd "$1" && printf '%s' "$2" | "$PREPUSH" "$3" /nonexistent.git 2>&1 )"; RC=$?
  if [ -n "${PAT:-}" ]; then
    case "$OUT" in *"$PAT"*) CAPTURE_LEAK=1 ;; esac
  fi
}
pp() { pp_remote "$1" "$2" origin; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forgeward-prepush.XXXXXX")" || {
  echo "pre-push-test: mktemp failed" >&2
  exit 1
}
[ -n "$TMP" ] || { echo "pre-push-test: mktemp returned an empty path" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# Deterministic Gitleaks stand-in for the hook orchestration tests. It examines the
# commit patches named by --log-opts (not the tip's net tree), emits only redacted JSON,
# and validates the safety flags. The real binary gets a separate positive-control leg
# below when it is installed. Secret-shaped fixture values are generated only under
# $TMP; none is committed to this repository.
MOCK_BIN="$TMP/mock-bin"; mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/gitleaks" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
log_opts=""; have_redact=0; have_config=0; have_ignore=0; have_stdout=0; target=""
for arg in "$@"; do
  target="$arg"
  case "$arg" in
    --log-opts=*) log_opts="${arg#*=}" ;;
    --redact) have_redact=1 ;;
    --config=*) have_config=1 ;;
    --gitleaks-ignore-path=*) have_ignore=1 ;;
    --report-path=-) have_stdout=1 ;;
  esac
done
[ -n "$log_opts" ] && [ "$have_redact" = 1 ] && [ "$have_config" = 1 ] \
  && [ "$have_ignore" = 1 ] && [ "$have_stdout" = 1 ] || exit 9
[ "$target" != "." ] && [ -d "$target" ] \
  && git -C "$target" rev-parse --git-dir >/dev/null 2>&1 || exit 9
[ "${MOCK_GITLEAKS_CRASH:-}" != 1 ] || exit 7
if git log -p --format= "$log_opts" 2>/dev/null \
  | /usr/bin/grep -E '^\+.*ghp_[A-Za-z0-9]{36}' >/dev/null; then
  file="src/token.txt"
  if git log --format= --name-only "$log_opts" 2>/dev/null \
    | /usr/bin/grep -F 'TODOS.md' >/dev/null; then
    file="TODOS.md"
  fi
  printf '[{"RuleID":"github-pat","File":"%s","StartLine":1,"Secret":"REDACTED","Match":"REDACTED"}]\n' "$file"
  exit 1
fi
printf '[]\n'
MOCK
chmod +x "$MOCK_BIN/gitleaks"
PATH="$MOCK_BIN:$PATH"
export PATH

R="$TMP/repo"; git init -q "$R"; cd "$R"
git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
git config forgeward.gate enabled   # opt in (the enforcer no-ops without this)
printf '{\n  "name":"u","version":"1.0.0","dependencies":{"express":"^4.19.2"}\n}\n' > package.json
echo ok > src.js; git add -A; git commit -qm base; git branch -M main
git update-ref refs/remotes/origin/main "$(git rev-parse main)"
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

git checkout -qb g   main; echo g > g.js;  git add -A; git commit -qm g;  write_marker main "privacy" >/dev/null
SHA_G="$(git rev-parse refs/heads/g)"
git checkout -qb g2  main; echo g2 > g2.js; git add -A; git commit -qm g2; write_marker main "privacy" >/dev/null
SHA_G2="$(git rev-parse refs/heads/g2)"
git checkout -qb bad main; echo b > b.js;  git add -A; git commit -qm bad          # no marker
SHA_BAD="$(git rev-parse refs/heads/bad)"
git checkout -q main

# P1: gated ref -> allowed
pp "$R" "refs/heads/g $SHA_G refs/heads/g $RSHA"$'\n'
[ "$RC" = 0 ] && ok "gated ref -> push ALLOWED (exit 0)" || nok "gated allowed" "rc=$RC out=$OUT"

# P2: ungated ref -> blocked, and the message names it
pp "$R" "refs/heads/bad $SHA_BAD refs/heads/bad $RSHA"$'\n'
# `case`, not `printf | grep -q`: with the `set -o pipefail` above, grep -q exits on
# first match and printf takes SIGPIPE, so the pipeline reports failure on input it
# just matched. Same defect this suite's sibling carried; see denies() in gate-test.sh.
{ [ "$RC" = 1 ] && case "$OUT" in *bad*) true ;; *) false ;; esac; } \
  && ok "ungated ref -> push BLOCKED (exit 1, names the ref)" || nok "ungated blocked" "rc=$RC out=$OUT"

# P3: multi-ref, one ungated -> the whole push is blocked (git enumerates the refs for us)
pp "$R" "refs/heads/g $SHA_G refs/heads/g $RSHA"$'\n'"refs/heads/bad $SHA_BAD refs/heads/bad $RSHA"$'\n'
[ "$RC" = 1 ] && ok "multi-ref with an ungated ref -> push BLOCKED" || nok "multi-ref blocked" "rc=$RC out=$OUT"

# P4: multi-ref, every ref gated -> allowed
pp "$R" "refs/heads/g $SHA_G refs/heads/g $RSHA"$'\n'"refs/heads/g2 $SHA_G2 refs/heads/g2 $RSHA"$'\n'
[ "$RC" = 0 ] && ok "multi-ref, every ref gated -> ALLOWED" || nok "multi-ref allowed" "rc=$RC out=$OUT"

# P5: branch deletion (zero local sha) -> allowed (publishes no code)
pp "$R" "(delete) $ZERO refs/heads/bad $RSHA"$'\n'
[ "$RC" = 0 ] && ok "branch deletion (zero sha) -> ALLOWED" || nok "deletion allowed" "rc=$RC out=$OUT"

# P6: a NEW commit on g after the marker -> stale -> blocked
git checkout -q g; echo more >> g.js; git add -A; git commit -qm "post-gate code"
SHA_G_STALE="$(git rev-parse refs/heads/g)"; git checkout -q main; git branch -f g "$SHA_G"
pp "$R" "refs/heads/g $SHA_G_STALE refs/heads/g $RSHA"$'\n'
[ "$RC" = 1 ] && ok "post-marker commit -> stale -> BLOCKED" || nok "stale blocked" "rc=$RC out=$OUT"

# P7: version-only bump on g -> hash invariant -> still allowed
git checkout -q g
python3 -c "import json;d=json.load(open('package.json'));d['version']='1.0.1.0';open('package.json','w').write(json.dumps(d,indent=2)+chr(10))"
git add -A; git commit -qm "chore: bump version"
SHA_G_BUMP="$(git rev-parse refs/heads/g)"; git checkout -q main; git branch -f g "$SHA_G"
pp "$R" "refs/heads/g $SHA_G_BUMP refs/heads/g $RSHA"$'\n'
[ "$RC" = 0 ] && ok "version-only bump on a gated ref -> still ALLOWED (marker survives)" || nok "version bump allowed" "rc=$RC out=$OUT"

# P8: a non-branch ref (tag) -> not branch-gated here -> allowed
pp "$R" "refs/tags/v1 $SHA_BAD refs/tags/v1 $RSHA"$'\n'
[ "$RC" = 0 ] && ok "non-branch ref (tag) -> ALLOWED (not branch-gated)" || nok "tag allowed" "rc=$RC out=$OUT"

# P9 (the original worktree bug, now handled robustly): a marker written INSIDE a
# linked worktree is honored when the push is evaluated from the MAIN checkout. No cd,
# no parsing — git hands the exact ref+sha on stdin and the marker is found under the
# shared common git dir.
WT="$TMP/wt"; git -C "$R" worktree add -q -b wt "$WT" main >/dev/null 2>&1
( cd "$WT"; echo w > w.js; git add -A; git commit -qm wt; write_marker main "privacy" ) >/dev/null
SHA_WT="$(git -C "$R" rev-parse refs/heads/wt)"
pp "$R" "refs/heads/wt $SHA_WT refs/heads/wt $RSHA"$'\n'
[ "$RC" = 0 ] && ok "worktree: marker from a linked worktree honored from the main checkout (exact ref on stdin)" \
  || nok "worktree pre-push allow" "rc=$RC out=$OUT"

# P11: publish a GATED commit to a remote branch via a bare-SHA source
# (`git push origin <sha>:refs/heads/main`) — local_ref is the SHA, not refs/heads/*.
# Gating must key off the REMOTE ref + the commit, not the local side. ALLOWED.
pp "$R" "$SHA_G $SHA_G refs/heads/main $RSHA"$'\n'
[ "$RC" = 0 ] && ok "bare-SHA source of a gated commit -> ALLOWED (keys off remote ref + commit)" \
  || nok "sha-source gated allowed" "rc=$RC out=$OUT"

# P12: publish an UNGATED commit via a bare-SHA source -> BLOCKED. The old code keyed off
# local_ref, saw a non-refs/heads value, and SKIPPED the line — a silent fail-open.
pp "$R" "$SHA_BAD $SHA_BAD refs/heads/main $RSHA"$'\n'
[ "$RC" = 1 ] && ok "bare-SHA source of an ungated commit -> BLOCKED (fail-open fixed)" \
  || nok "sha-source ungated blocked" "rc=$RC out=$OUT"

# P13: HEAD source (`git push origin HEAD:refs/heads/main`) — local_ref is 'HEAD'.
pp "$R" "HEAD $SHA_G refs/heads/main $RSHA"$'\n'
[ "$RC" = 0 ] && ok "HEAD source of a gated commit -> ALLOWED" || nok "HEAD-source gated allowed" "rc=$RC out=$OUT"
pp "$R" "HEAD $SHA_BAD refs/heads/main $RSHA"$'\n'
[ "$RC" = 1 ] && ok "HEAD source of an ungated commit -> BLOCKED" || nok "HEAD-source ungated blocked" "rc=$RC out=$OUT"

# P29 (PRE-FIX control, end to end): this hook accepts the marker of ANY local branch at
# the pushed commit, so the writer's --revoke must withdraw a sibling branch's marker
# too. Against `git show 283c205:scripts/forgeward-write-marker.sh` the sibling's PASS
# survived the revoke and its push was still ALLOWED. The first leg is the control that
# the sibling's marker really authorized the push before the revoke. Since the run id,
# write_marker's own revoke on rv2 already withdraws rv1's marker (rv1 is at the same
# commit); that is the behaviour under test, and nothing below reads rv1's marker. The
# revoke is run from rv1 and names the frozen commit, as Step 2 does.
git checkout -qb rv1 main; echo rv > rv.js; git add -A; git commit -qm rv; write_marker main "privacy" >/dev/null
git checkout -qb rv2; write_marker main "privacy" >/dev/null
SHA_RV="$(git rev-parse refs/heads/rv2)"
pp "$R" "refs/heads/rv2 $SHA_RV refs/heads/rv2 $RSHA"$'\n'; P29_BEFORE="$RC"
git checkout -q rv1; "$WRITE" --revoke "$SHA_RV" >/dev/null
pp "$R" "refs/heads/rv2 $SHA_RV refs/heads/rv2 $RSHA"$'\n'
git checkout -q main
{ [ "$P29_BEFORE" = 0 ] && [ "$RC" = 1 ] && case "$OUT" in *"rv2"*) true ;; *) false ;; esac; } \
  && ok "revoke from one branch withdraws a sibling's PASS at the same commit -> the sibling's push is BLOCKED" \
  || nok "sibling PASS survives revoke" "before=$P29_BEFORE rc=$RC out=$OUT"

# P14: marker_get must trust jq's EXIT STATUS, not just its output.
#
# This copy of marker_get had drifted from gate-check.sh's in two ways at once: it
# discarded jq's exit status, and it still used print() instead of sys.stdout.buffer.write
# (DECISIONS.md recorded that second fix as landed; it had only ever landed next door).
#
# The exit-status half is what this pins. `command -v jq` succeeding means jq is
# INSTALLED, not that it RUNS; while it was installed-and-broken, every marker read came
# back empty, is_fresh() returned 1, and EVERY push was refused with the python3 fallback
# sitting one branch away and unreachable. Fail-closed, so nothing shipped ungated — but
# a hook that blocks every push regardless of the marker is not enforcing anything.
#
# The print() half is NOT observable on POSIX: print() appends "\n" and `$( )` strips it,
# so both forms produce identical bytes here. It only diverges on Windows, where Python
# translates that "\n" to "\r\n" in text mode and `$( )` strips only the LF — the stray
# CR then rides on `base`, fails to resolve as a ref, and a fresh marker reads as stale.
# Stated rather than asserted, because faking a CRLF stdout would test the fake. What
# catches it instead is A19 in gate-test.sh, which pins the two copies byte-identical.
#
# Own repo, deliberately WITHOUT any version-bearing manifest: forgeward-diff-hash.sh
# consults jq only to canonicalize those, so this leaves marker_get as the one jq
# consumer on the path and a red result has one cause.
R3="$TMP/repo-markerget"; git init -q "$R3"
( cd "$R3"; git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  git config forgeward.gate enabled
  echo base > a.txt; git add -A; git commit -qm base; git branch -M main
  git checkout -qb ungated; echo u > u.txt; git add -A; git commit -qm ungated
  git checkout -qb gated main; echo w > w.txt; git add -A; git commit -qm work
  write_marker main "privacy" ) >/dev/null 2>&1
SHA_MG="$(git -C "$R3" rev-parse refs/heads/gated)"
SHA_MGU="$(git -C "$R3" rev-parse refs/heads/ungated)"

JQFAIL="$TMP/shadow-jq"; mkdir -p "$JQFAIL"
printf '#!/bin/sh\nexit 1\n' > "$JQFAIL/jq"; chmod +x "$JQFAIL/jq"
ppjq() { OUT="$( cd "$1" && printf '%s' "$2" | PATH="$JQFAIL:$PATH" "$PREPUSH" origin /nonexistent.git 2>&1 )"; RC=$?; }

pp   "$R3" "refs/heads/gated $SHA_MG refs/heads/gated $RSHA"$'\n';   RC_HEALTHY=$RC
ppjq "$R3" "refs/heads/gated $SHA_MG refs/heads/gated $RSHA"$'\n';   RC_BROKEN=$RC
# The control that makes this non-vacuous: exit 0 also means "the hook bailed early"
# (missing tooling and a non-git cwd both fail OPEN by design). Under the SAME broken jq
# an ungated ref must still be BLOCKED, which proves the enforcer actually ran.
ppjq "$R3" "refs/heads/ungated $SHA_MGU refs/heads/ungated $RSHA"$'\n'; RC_CONTROL=$RC

{ [ "$RC_HEALTHY" = 0 ] && [ "$RC_BROKEN" = 0 ] && [ "$RC_CONTROL" = 1 ]; } \
  && ok "jq present but exiting 1 -> a valid marker is still READ (python3 answers; gated ref allowed, ungated still blocked)" \
  || nok "marker_get discards jq's exit status (a broken jq refuses every push, gated or not)" \
         "healthy=$RC_HEALTHY broken=$RC_BROKEN control=$RC_CONTROL (want 0/0/1)"

# P15: interpreter discovery must probe, not merely find, python3. This mirrors the
# native-Windows Microsoft Store alias shape with a deterministic shim: jq and python3
# are both present but unusable, while `python` is a working interpreter. Exercise both
# verdict directions so an early fail-open cannot satisfy the fresh-marker control.
PYFALLBACK="$TMP/python-fallback"; mkdir -p "$PYFALLBACK"
printf '#!/bin/sh\nexit 1\n' > "$PYFALLBACK/jq"
printf '#!/bin/sh\nexit 1\n' > "$PYFALLBACK/python3"
ln -s "$(command -v python3)" "$PYFALLBACK/python"
chmod +x "$PYFALLBACK/jq" "$PYFALLBACK/python3"
pppy() { OUT="$( cd "$1" && printf '%s' "$2" | PATH="$PYFALLBACK:$PATH" "$PREPUSH" origin /nonexistent.git 2>&1 )"; RC=$?; }

pppy "$R3" "refs/heads/gated $SHA_MG refs/heads/gated $RSHA"$'\n';       RC_PY_GATED=$RC
pppy "$R3" "refs/heads/ungated $SHA_MGU refs/heads/ungated $RSHA"$'\n'; RC_PY_UNGATED=$RC
{ [ "$RC_PY_GATED" = 0 ] && [ "$RC_PY_UNGATED" = 1 ]; } \
  && ok "unusable python3 falls through to working python (gated allowed, ungated blocked)" \
  || nok "pre-push functional Python fallback" "gated=$RC_PY_GATED ungated=$RC_PY_UNGATED (want 0/1)"

# P10 (opt-in safety): a repo that never enabled the gate is a NO-OP, even for an
# ungated ref — so a shared/global pre-push hook can't block unrelated repos.
R2="$TMP/repo2"; git init -q "$R2"
( cd "$R2"; git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  echo x > f; git add -A; git commit -qm base ) >/dev/null   # NOTE: no forgeward.gate config
SHA_R2="$(git -C "$R2" rev-parse HEAD)"
pp "$R2" "refs/heads/master $SHA_R2 refs/heads/master $RSHA"$'\n'
[ "$RC" = 0 ] && ok "opt-in: a repo without forgeward.gate is a NO-OP (safe as a global hook)" \
  || nok "opt-in no-op" "rc=$RC out=$OUT"

# P16: a GitHub PAT on a new branch is caught. Build the value at runtime so the
# test suite itself never becomes a permanent scanner fixture.
PAT="ghp_$(printf 'aB3dE5fG7hJ9kL2mN4pQ6rS8tV0wX1yZ2cD4')"
git -C "$R" checkout -qb secret-new main
mkdir -p "$R/src"; printf '%s\n' "$PAT" > "$R/src/token.txt"
git -C "$R" add src/token.txt; git -C "$R" commit -qm "secret new branch"
SHA_SECRET_NEW="$(git -C "$R" rev-parse HEAD)"
( cd "$R" && write_marker main testing >/dev/null )
pp "$R" "refs/heads/secret-new $SHA_SECRET_NEW refs/heads/secret-new $ZERO"$'\n'
{ [ "$RC" = 1 ] \
  && { case "$OUT" in *github-pat*src/token.txt:1*'preview=[REDACTED]'*) true ;; *) false ;; esac; } \
  && { case "$OUT" in *"$PAT"*) false ;; *) true ;; esac; }; } \
  && ok "credential on a new branch -> BLOCKED with rule, file:line and fully masked preview" \
  || nok "new-branch credential scan" "rc=$RC output-shape-wrong-or-secret-leaked"

# The same new content with an unavailable non-zero remote object must take the
# merge-base fallback instead of trying an unresolvable remote..local range.
pp "$R" "refs/heads/secret-new $SHA_SECRET_NEW refs/heads/secret-new $RSHA"$'\n'
{ [ "$RC" = 1 ] \
  && { case "$OUT" in *github-pat*src/token.txt:1*) true ;; *) false ;; esac; }; } \
  && ok "remote object absent locally -> merge-base fallback still scans and BLOCKS" \
  || nok "missing-remote-object fallback" "rc=$RC output-shape-wrong"

# P17: TODOS.md is omitted from the marker hash. Write the marker first, then add the
# credential there: the marker stays fresh, so a block proves the independent scan ran.
git -C "$R" checkout -qb secret-todo main
( cd "$R" && write_marker main testing >/dev/null )
printf '%s\n' "$PAT" > "$R/TODOS.md"
git -C "$R" add TODOS.md; git -C "$R" commit -qm "deferred secret fixture"
SHA_SECRET_TODO="$(git -C "$R" rev-parse HEAD)"
pp "$R" "refs/heads/secret-todo $SHA_SECRET_TODO refs/heads/secret-todo $(git -C "$R" rev-parse main)"$'\n'
{ [ "$RC" = 1 ] \
  && { case "$OUT" in *github-pat*TODOS.md:1*) true ;; *) false ;; esac; } \
  && { case "$OUT" in *'have not passed /forgeward:gate'*) false ;; *"$PAT"*) false ;; *) true ;; esac; }; } \
  && ok "credential committed to TODOS.md after PASS -> marker stays fresh but scan BLOCKS" \
  || nok "TODOS credential independent of marker" "rc=$RC output-shape-wrong-marker-stale-or-secret-leaked"

# P18: commit-history mode sees an addition even when a later pushed commit removes it.
git -C "$R" checkout -qb secret-removed main
mkdir -p "$R/src"; printf '%s\n' "$PAT" > "$R/src/token.txt"
git -C "$R" add src/token.txt; git -C "$R" commit -qm "add transient credential"
git -C "$R" rm -q src/token.txt; git -C "$R" commit -qm "remove transient credential"
SHA_SECRET_REMOVED="$(git -C "$R" rev-parse HEAD)"
( cd "$R" && write_marker main testing >/dev/null )
pp "$R" "refs/heads/secret-removed $SHA_SECRET_REMOVED refs/heads/secret-removed $(git -C "$R" rev-parse main)"$'\n'
{ [ "$RC" = 1 ] \
  && { case "$OUT" in *github-pat*) true ;; *) false ;; esac; } \
  && { case "$OUT" in *"$PAT"*) false ;; *) true ;; esac; }; } \
  && ok "credential added then removed inside one push -> BLOCKED (commit-wise scan)" \
  || nok "transient-history credential scan" "rc=$RC output-shape-wrong-or-secret-leaked"

# P19: the PII false positives and documented placeholders stay silent. The mock owns
# only the orchestration assertion; the optional real-Gitleaks leg below owns engine
# behavior on this exact generated fixture.
PHONE_A="+35799""000003"; PHONE_B="+357 99 ""000 003"
BYTES="161061""2736"; CLOCK="1757""000000"
OAUTH="1234567890""-testclient.apps.googleusercontent.com"
AWS_EXAMPLE="AKIAIOSFODNN7""EXAMPLE"
git -C "$R" checkout -qb benign-fixtures main
{
  printf '%s\n' "$PHONE_A" "$PHONE_B" "$BYTES" "$CLOCK" "$OAUTH" "$AWS_EXAMPLE"
  printf '%s\n' 'TOKEN=REDACTED' 'API_KEY=' 'SECRET_KEY='
} > "$R/benign.txt"
printf 'API_KEY=\nSECRET_KEY=\n' > "$R/.env.example"
git -C "$R" add benign.txt .env.example; git -C "$R" commit -qm "benign scanner fixtures"
SHA_BENIGN="$(git -C "$R" rev-parse HEAD)"
( cd "$R" && write_marker main testing >/dev/null )
pp "$R" "refs/heads/benign-fixtures $SHA_BENIGN refs/heads/benign-fixtures $(git -C "$R" rev-parse main)"$'\n'
[ "$RC" = 0 ] && [ -z "$OUT" ] \
  && ok "PII-shaped values, AWS example, empty .env.example and REDACTED placeholder -> ALLOWED silently" \
  || nok "benign credential fixtures" "rc=$RC out=$OUT"

# P20: a tag that resolves to a commit is scanned too; tag updates do not need markers.
git -C "$R" tag secret-tag "$SHA_SECRET_NEW"
pp "$R" "refs/tags/secret-tag $SHA_SECRET_NEW refs/tags/secret-tag $ZERO"$'\n'
{ [ "$RC" = 1 ] \
  && { case "$OUT" in *github-pat*refs/tags/secret-tag*) true ;; *) false ;; esac; } \
  && { case "$OUT" in *"$PAT"*) false ;; *) true ;; esac; }; } \
  && ok "new tag resolving to a credential-bearing commit -> BLOCKED" \
  || nok "tag credential scan" "rc=$RC output-shape-wrong-or-secret-leaked"

# The default branch must belong to the remote being pushed. If origin already has the
# credential-bearing commit but a new upstream remote does not, falling back to
# origin/HEAD would produce an empty range and miss what upstream is about to receive.
git -C "$R" update-ref refs/remotes/origin/main "$SHA_SECRET_NEW"
pp_remote "$R" "refs/tags/upstream-secret $SHA_SECRET_NEW refs/tags/upstream-secret $ZERO"$'\n' upstream
git -C "$R" update-ref refs/remotes/origin/main "$(git -C "$R" rev-parse main)"
{ [ "$RC" = 1 ] \
  && { case "$OUT" in *github-pat*refs/tags/upstream-secret*) true ;; *) false ;; esac; }; } \
  && ok "new ref on another remote -> that remote's boundary used, not origin/HEAD" \
  || nok "pushed-remote-specific range" "rc=$RC output-shape-wrong"

# P21: a non-commit tag cannot produce a commit range, so the scan fails closed.
BLOB="$(printf harmless | git -C "$R" hash-object -w --stdin)"
pp "$R" "refs/tags/blob-tag $BLOB refs/tags/blob-tag $ZERO"$'\n'
{ [ "$RC" = 1 ] \
  && { case "$OUT" in *'pushed range could not be resolved'*) true ;; *) false ;; esac; }; } \
  && ok "tag not resolving to a commit -> BLOCKED (unresolvable range fails closed)" \
  || nok "non-commit tag range failure" "rc=$RC out=$OUT"

# No remote default and no merge-base: scan every commit reachable from the local tip,
# including the root diff (the commit-wise empty-tree fallback).
RE="$TMP/empty-tree"; git init -q "$RE"
git -C "$RE" config user.email t@t.t; git -C "$RE" config user.name t
git -C "$RE" config forgeward.gate enabled
mkdir -p "$RE/src"; printf '%s\n' "$PAT" > "$RE/src/token.txt"
git -C "$RE" add src/token.txt; git -C "$RE" commit -qm "root credential"
SHA_EMPTY="$(git -C "$RE" rev-parse HEAD)"
pp "$RE" "refs/tags/root-secret $SHA_EMPTY refs/tags/root-secret $ZERO"$'\n'
{ [ "$RC" = 1 ] \
  && { case "$OUT" in *github-pat*refs/tags/root-secret*) true ;; *) false ;; esac; }; } \
  && ok "no merge-base -> all reachable commits/root diff scanned and credential BLOCKS" \
  || nok "commit-wise empty-tree fallback" "rc=$RC output-shape-wrong"

# P22/P23: jq and Python must render byte-identical safe fields from the same scanner
# JSON. Run the same finding once normally, then with a failing jq shim so Python answers.
pp "$R" "refs/tags/secret-tag $SHA_SECRET_NEW refs/tags/secret-tag $ZERO"$'\n'; OUT_JQ="$OUT"; RC_JQ=$RC
JQ_DOWN="$TMP/jq-down"; mkdir -p "$JQ_DOWN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$JQ_DOWN/jq"; chmod +x "$JQ_DOWN/jq"
PATH="$JQ_DOWN:$PATH" pp "$R" "refs/tags/secret-tag $SHA_SECRET_NEW refs/tags/secret-tag $ZERO"$'\n'
OUT_PY="$OUT"; RC_PY=$RC
{ [ "$RC_JQ" = 1 ] && [ "$RC_PY" = 1 ] && [ "$OUT_JQ" = "$OUT_PY" ]; } \
  && ok "Gitleaks finding parser: jq and Python output agree byte-for-byte" \
  || nok "Gitleaks parser agreement" "jq_rc=$RC_JQ py_rc=$RC_PY jq=${OUT_JQ//$PAT/[LEAK-REMOVED]} python=${OUT_PY//$PAT/[LEAK-REMOVED]}"

# P24: scanner failure is distinct from absence and fails closed without relaying raw
# scanner output. The mock emits nothing on this path; the hook supplies a fixed message.
export MOCK_GITLEAKS_CRASH=1
pp "$R" "refs/heads/benign-fixtures $SHA_BENIGN refs/heads/benign-fixtures $(git -C "$R" rev-parse main)"$'\n'
unset MOCK_GITLEAKS_CRASH
{ [ "$RC" = 1 ] \
  && { case "$OUT" in *'gitleaks failed or returned invalid output'*) true ;; *) false ;; esac; }; } \
  && ok "Gitleaks crash -> BLOCKED with fixed, non-secret-bearing error" \
  || nok "scanner crash fails closed" "rc=$RC out=$OUT"

# P25: the narrow bypass remains visible and writes only fixed metadata under the common
# git dir. The marker is fresh because the credential lives in hash-excluded TODOS.md.
export FORGEWARD_SECRET_SCAN=skip
pp "$R" "refs/heads/secret-todo $SHA_SECRET_TODO refs/heads/secret-todo $(git -C "$R" rev-parse main)"$'\n'
unset FORGEWARD_SECRET_SCAN
SKIP_LOG="$(git -C "$R" rev-parse --path-format=absolute --git-common-dir)/forgeward-security/prepush-skip.jsonl"
SKIP_BODY="$(sed -n '1,20p' "$SKIP_LOG" 2>/dev/null)"
case "$SKIP_BODY" in *"$PAT"*) CAPTURE_LEAK=1 ;; esac
{ [ "$RC" = 0 ] \
  && { case "$OUT" in *'credential scan skipped'*logged*) true ;; *) false ;; esac; } \
  && { case "$OUT$SKIP_BODY" in *"$PAT"*) false ;; *) true ;; esac; } \
  && { case "$SKIP_BODY" in *'FORGEWARD_SECRET_SCAN=skip'*) true ;; *) false ;; esac; }; } \
  && ok "FORGEWARD_SECRET_SCAN=skip -> visible, logged without refs or values, marker still enforced" \
  || nok "visible logged scan bypass" "rc=$RC output-or-log-shape-wrong-or-secret-leaked"

# P26/P27: install beside gstack without touching its managed wrapper, and refuse a
# foreign hook in either installation slot. The wrapper leg drives stdin through the
# installed pre-push.local and proves the requested composition works end to end.
RI="$TMP/install-gstack"; git init -q "$RI"
git -C "$RI" config user.email t@t.t; git -C "$RI" config user.name t
echo base > "$RI/base"; git -C "$RI" add base; git -C "$RI" commit -qm base
cat > "$RI/.git/hooks/pre-push" <<'GSTACK'
#!/usr/bin/env bash
# gstack-redact pre-push (managed)
set -uo pipefail
input="$(cat)"
local_hook="$(git rev-parse --git-path hooks/pre-push.local)"
if [ -x "$local_hook" ]; then printf '%s' "$input" | "$local_hook" "$@" || exit $?; fi
GSTACK
chmod +x "$RI/.git/hooks/pre-push"
GSTACK_BEFORE="$(git hash-object "$RI/.git/hooks/pre-push")"
INSTALL_OUT="$("$INSTALL" "$RI" 2>&1)"; INSTALL_RC=$?
GSTACK_AFTER="$(git hash-object "$RI/.git/hooks/pre-push")"
SHA_RI="$(git -C "$RI" rev-parse HEAD)"
HOOK_OUT="$(cd "$RI" && printf 'refs/heads/master %s refs/heads/master %s\n' "$SHA_RI" "$RSHA" \
  | .git/hooks/pre-push origin /nonexistent.git 2>&1)"; HOOK_RC=$?
{ [ "$INSTALL_RC" = 0 ] && [ "$GSTACK_BEFORE" = "$GSTACK_AFTER" ] \
  && [ -x "$RI/.git/hooks/pre-push.local" ] && [ "$HOOK_RC" = 1 ] \
  && { case "$INSTALL_OUT" in *pre-push.local*chained*) true ;; *) false ;; esac; }; } \
  && ok "installer: gstack managed hook preserved, forgeward installed as executable pre-push.local and receives stdin" \
  || nok "gstack pre-push.local installation" "install_rc=$INSTALL_RC hook_rc=$HOOK_RC wrapper_changed=$([ "$GSTACK_BEFORE" = "$GSTACK_AFTER" ] && echo no || echo yes)"

RF="$TMP/install-foreign"; git init -q "$RF"
printf '#!/usr/bin/env bash\necho foreign\n' > "$RF/.git/hooks/pre-push"; chmod +x "$RF/.git/hooks/pre-push"
FOREIGN_BEFORE="$(git hash-object "$RF/.git/hooks/pre-push")"
FOREIGN_OUT="$("$INSTALL" "$RF" 2>&1)"; FOREIGN_RC=$?
FOREIGN_AFTER="$(git hash-object "$RF/.git/hooks/pre-push")"
{ [ "$FOREIGN_RC" = 1 ] && [ "$FOREIGN_BEFORE" = "$FOREIGN_AFTER" ] \
  && [ -z "$(git -C "$RF" config --get forgeward.gate 2>/dev/null || true)" ] \
  && { case "$FOREIGN_OUT" in *'Left it untouched'*) true ;; *) false ;; esac; }; } \
  && ok "installer: foreign pre-push is untouched and repo is not opted in" \
  || nok "foreign hook refusal" "rc=$FOREIGN_RC changed=$([ "$FOREIGN_BEFORE" = "$FOREIGN_AFTER" ] && echo no || echo yes)"

# P28/P29: real-engine positive and negative controls when Gitleaks is installed. This
# is intentionally optional because Gitleaks remains a user-machine optional dependency;
# the mock assertions above keep CI deterministic and non-vacuous when it is absent.
REAL_GITLEAKS="$(PATH="$ORIGINAL_PATH" command -v gitleaks 2>/dev/null || true)"
if [ -n "$REAL_GITLEAKS" ]; then
  PATH="$ORIGINAL_PATH" pp "$R" "refs/heads/secret-new $SHA_SECRET_NEW refs/heads/secret-new $ZERO"$'\n'
  { [ "$RC" = 1 ] \
    && { case "$OUT" in *github-pat*'preview=[REDACTED]'*) true ;; *) false ;; esac; } \
    && { case "$OUT" in *"$PAT"*) false ;; *) true ;; esac; }; } \
    && ok "real Gitleaks: generated GitHub PAT fixture -> BLOCKED without value disclosure" \
    || nok "real Gitleaks positive control" "rc=$RC output-shape-wrong-or-secret-leaked"

  PATH="$ORIGINAL_PATH" pp "$R" "refs/heads/benign-fixtures $SHA_BENIGN refs/heads/benign-fixtures $(git -C "$R" rev-parse main)"$'\n'
  [ "$RC" = 0 ] && [ -z "$OUT" ] \
    && ok "real Gitleaks: required benign fixtures -> ALLOWED silently" \
    || nok "real Gitleaks benign fixtures" "rc=$RC out=$OUT"

  # A repository .gitleaksignore can suppress the raw scanner and must not suppress
  # Forgeward's independent guard. The raw leg proves the fingerprint is effective;
  # without it, a malformed ignore fixture would make the Forgeward assertion vacuous.
  git -C "$R" checkout -qb repo-suppression main
  mkdir -p "$R/src"; printf '%s\n' "$PAT" > "$R/src/token.txt"
  git -C "$R" add src/token.txt; git -C "$R" commit -qm "credential before repo ignore"
  SUPPRESSED_COMMIT="$(git -C "$R" rev-parse HEAD)"
  printf '%s:src/token.txt:github-pat:1\n' "$SUPPRESSED_COMMIT" > "$R/.gitleaksignore"
  git -C "$R" add .gitleaksignore; git -C "$R" commit -qm "repository scanner suppression"
  SHA_SUPPRESSION="$(git -C "$R" rev-parse HEAD)"
  ( cd "$R" && write_marker main testing >/dev/null )
  RAW_SUPPRESSION="$(cd "$R" && "$REAL_GITLEAKS" git \
    --log-opts="main..$SHA_SUPPRESSION" --no-banner --redact \
    --report-format=json --report-path=- . 2>&1)"; RAW_SUPPRESSION_RC=$?
  case "$RAW_SUPPRESSION" in *"$PAT"*) CAPTURE_LEAK=1 ;; esac
  PATH="$ORIGINAL_PATH" pp "$R" "refs/heads/repo-suppression $SHA_SUPPRESSION refs/heads/repo-suppression $(git -C "$R" rev-parse main)"$'\n'
  { [ "$RAW_SUPPRESSION_RC" = 0 ] && [ "$RC" = 1 ] \
    && { case "$OUT" in *github-pat*src/token.txt:1*) true ;; *) false ;; esac; }; } \
    && ok "real Gitleaks: repository .gitleaksignore suppresses raw scan but cannot suppress Forgeward" \
    || nok "independent Gitleaks ignore path" "raw_rc=$RAW_SUPPRESSION_RC hook_rc=$RC output-shape-wrong"
else
  ok "real Gitleaks positive control SKIPPED (optional scanner not installed; mock integration assertions ran)"
  ok "real Gitleaks benign fixtures SKIPPED (optional scanner not installed; mock integration assertions ran)"
  ok "real Gitleaks repository-ignore control SKIPPED (optional scanner not installed; explicit ignore argv still asserted by mock)"
fi

# P30..P39 -- a PASS is accepted only while the gate run that wrote it is still the latest
# on the commit it reviewed, and never for a pushed commit that a gate run has started on
# unless it is that commit (`run_is_current`, 0.31.0). The same cases as F2-F10 in
# test/gate-test.sh, driven through this, the enforced hook. Every refusal is built with
# the marker still ON DISK and its diff hash still matching, so what refuses it is the
# run file. P31-P37 are PRE-FIX controls: 6e11899's hook allows each push. P30, P38 and
# P39 are positive controls, and P38/P39 the WRONG-FIX controls for refusing any pushed
# commit other than the reviewed one. Mutation-checked: with run_is_current made to
# always succeed, P31-P37 go red while P30, P38 and P39 stay green.
RX="$TMP/repo-run"; git init -q "$RX"
( cd "$RX"; git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  git config forgeward.gate enabled
  echo base > a.txt; git add -A; git commit -qm base; git branch -M main
  git checkout -qb x; echo 'const x = 1;' > x.js; git add -A; git commit -qm x ) >/dev/null 2>&1
XB="$(git -C "$RX" rev-parse main)"; XC="$(git -C "$RX" rev-parse refs/heads/x)"
XCOMMON="$(git -C "$RX" rev-parse --path-format=absolute --git-common-dir)"
XMD="$XCOMMON/forgeward-gate-markers"; XRUNS="$XCOMMON/forgeward-gate-runs"
# xgate <commit>: a gate run on <commit> from the current checkout that PASSes -- revoke
# (which mints the run; XRUN keeps its id), then the write with that id.
xgate() {
  XRUN="$(cd "$RX" && "$WRITE" --revoke "$1" 2>/dev/null | sed -n 's/^RUN_ID=//p')"
  ( cd "$RX" && "$WRITE" main privacy "$XB" "$1" "$XRUN" ) >/dev/null 2>&1
}
xrevoke() { ( cd "$RX" && "$WRITE" --revoke "$1" ) >/dev/null 2>&1; }
xpush() { pp "$RX" "refs/heads/$1 $2 refs/heads/$1 $RSHA"$'\n'; }   # xpush <remote-branch> <sha>
xblocked() { # xblocked <remote-branch> <sha>: refused as ungated, naming the ref
  [ "$RC" = 1 ] && case "$OUT" in *"have not passed /forgeward:gate"*"  - $1 @ ${2:0:12}"*) true ;; *) false ;; esac
}
xset() { # xset <marker> <key> [<json-value>]: rewrite one field of a fixture marker; no value deletes it
  python3 -I -c 'import json,sys
p,k=sys.argv[1],sys.argv[2]; d=json.load(open(p))
if len(sys.argv)>3: d[k]=json.loads(sys.argv[3])
else: d.pop(k,None)
open(p,"w").write(json.dumps(d,indent=2)+"\n")' "$@"
}

# P30 (positive control, case j): a plain PASS from the latest run on the pushed commit.
xgate "$XC"; xpush x "$XC"
[ "$RC" = 0 ] && [ -f "$XMD/x.json" ] \
  && ok "P30: a PASS from the latest gate run on the pushed commit -> ALLOWED" \
  || nok "P30: a current PASS was refused" "rc=$RC out=$OUT"

# P31 (PRE-FIX control, case a): a killed writer's marker restored after a newer run's
# revoke deleted it -- the same bytes, so the same diff hash.
cp "$XMD/x.json" "$TMP/p31.json"; xrevoke "$XC"
p31_deleted=0; [ -e "$XMD/x.json" ] || p31_deleted=1
cp "$TMP/p31.json" "$XMD/x.json"; xpush x "$XC"
[ "$p31_deleted" = 1 ] && xblocked x "$XC" \
  && ok "P31: a marker restored after a newer run started on its commit -> BLOCKED" \
  || nok "P31: a superseded run's marker authorized the push" "deleted=$p31_deleted rc=$RC out=$OUT"

# P35 (PRE-FIX control, case e): a schema-4 marker has no run_id; refused even while the
# run that wrote it is current -- the upgrade path costs one re-gate.
xgate "$XC"; xset "$XMD/x.json" run_id; xset "$XMD/x.json" schema 4; xpush x "$XC"
[ "$(cat "$XRUNS/$XC" 2>/dev/null)" = "$XRUN" ] && xblocked x "$XC" \
  && ok "P35: a schema-4 marker (no run_id) -> BLOCKED" \
  || nok "P35: a marker without run_id authorized the push" "rc=$RC out=$OUT"

# P36 (PRE-FIX control, case f): the run file is gone, as after a by-hand delete.
xgate "$XC"; rm -f "$XRUNS/$XC"; xpush x "$XC"
[ -f "$XMD/x.json" ] && xblocked x "$XC" \
  && ok "P36: a marker whose run file is missing -> BLOCKED" \
  || nok "P36: a marker with no run file authorized the push" "rc=$RC out=$OUT"

# P38 (positive and WRONG-FIX control, case h): the /ship flow. A VERSION-only commit
# after the PASS has the same diff and no gate run of its own, so the PASS still holds.
xgate "$XC"
( cd "$RX" && echo 1.0.1 > VERSION && git add VERSION && git commit -qm "chore: bump version" ) >/dev/null 2>&1
XV="$(git -C "$RX" rev-parse HEAD)"; xpush x "$XV"
[ "$XV" != "$XC" ] && [ ! -e "$XRUNS/$XV" ] && [ "$RC" = 0 ] \
  && ok "P38: a VERSION-only commit after the PASS, with no gate run of its own -> ALLOWED (the /ship flow)" \
  || nok "P38: the /ship version bump was refused" "rc=$RC out=$OUT"

# P37 (PRE-FIX control, case g): a malformed run_id or reviewed_head is refused, and no
# file outside forgeward-gate-runs/ is read. Each case PLANTS the file the bad value
# would name, holding the id it would need, so only the shape check stands between it
# and an accept; `../planted` names a file one level up. The tip is P38's VERSION commit,
# which has no run file, so nothing else can refuse it. The unmodified marker is the
# control.
cp "$XMD/x.json" "$TMP/p37.json"
xpush x "$XV"; p37_ctl=$RC
XUP="$(printf '%s' "$XC" | tr 'a-f' 'A-F')"; XRUP="$(printf '%s' "$XRUN" | tr 'a-f' 'A-F')"
p37_fail=""
p37() { # p37 <label> <key> <value> <plant-path> <plant-line>
  cp "$TMP/p37.json" "$XMD/x.json"; xset "$XMD/x.json" "$2" "\"$3\""
  printf '%s\n' "$5" > "$4"
  xpush x "$XV"; xblocked x "$XV" || p37_fail="$p37_fail $1"
  rm -f "$4"; printf '%s\n' "$XRUN" > "$XRUNS/$XC"
}
p37 head-dotdot reviewed_head ../planted "$XCOMMON/planted" "$XRUN"
p37 head-upper reviewed_head "$XUP" "$XRUNS/$XUP" "$XRUN"
p37 head-short reviewed_head "${XC:0:12}" "$XRUNS/${XC:0:12}" "$XRUN"
p37 run-upper run_id "$XRUP" "$XRUNS/$XC" "$XRUP"
p37 run-short run_id "${XRUN:0:12}" "$XRUNS/$XC" "${XRUN:0:12}"
cp "$TMP/p37.json" "$XMD/x.json"
[ "$p37_ctl" = 0 ] && [ -z "$p37_fail" ] \
  && ok "P37: a run_id or reviewed_head that is not a full lowercase id -> BLOCKED, even with the file it names planted" \
  || nok "P37: a malformed run_id or reviewed_head authorized the push" "control=$p37_ctl accepted:$p37_fail"

# P33 (PRE-FIX control, case c): the same diff on another commit. PASS on x at C1; C2 is
# C1 with a reworded message. Pushed to remote `x`, C2 is first authorized by x's marker
# through the destination-name lookup (the control); a gate run then starts on C2 (and
# FAILs) while x is still at C1, which never visits x.json; then x moves to C2.
( cd "$RX" && git checkout -q main && git branch -f x "$XC" && git checkout -q x ) >/dev/null 2>&1
xgate "$XC"
( cd "$RX" && git checkout -qb x2 && git commit -q --amend -m "x (reworded)" ) >/dev/null 2>&1
XC2="$(git -C "$RX" rev-parse refs/heads/x2)"
xpush x "$XC2"; p33_before=$RC
xrevoke "$XC2"; xpush x "$XC2"; p33_dest=$RC; p33_dest_out=$OUT
git -C "$RX" branch -f x "$XC2" >/dev/null 2>&1; xpush x "$XC2"
[ "$XC2" != "$XC" ] && [ "$p33_before" = 0 ] && [ "$p33_dest" = 1 ] && [ -f "$XMD/x.json" ] \
  && case "$p33_dest_out" in *"  - x @ ${XC2:0:12}"*) true ;; *) false ;; esac \
  && xblocked x "$XC2" \
  && ok "P33: a PASS for one commit no longer authorizes another with the same diff once a gate run started there, by either name" \
  || nok "P33: a PASS crossed onto a commit with its own gate run" "before=$p33_before dest=$p33_dest rc=$RC out=$OUT"

# P34 (PRE-FIX control, case d): a PASS written on a detached HEAD (key `HEAD`), which
# this hook reads for a push to a branch named `HEAD`; then a newer run on that commit
# started from a branch checkout, which never visits that key.
( cd "$RX" && git checkout -qb dx main && echo d > d.js && git add -A && git commit -qm d \
   && git checkout -q --detach ) >/dev/null 2>&1
XDC="$(git -C "$RX" rev-parse HEAD)"
xgate "$XDC"; xpush HEAD "$XDC"; p34_before=$RC
( cd "$RX" && git checkout -q dx ) >/dev/null 2>&1
xrevoke "$XDC"; xpush HEAD "$XDC"
[ "$p34_before" = 0 ] && [ -f "$XMD/HEAD.json" ] && xblocked HEAD "$XDC" \
  && ok "P34: a detached-HEAD PASS is BLOCKED once a newer run starts on its commit, with HEAD.json still on disk" \
  || nok "P34: a detached-HEAD PASS outlived a newer run" "before=$p34_before rc=$RC out=$OUT"

# P32 (PRE-FIX control, case b): a branch and a same-named tag, so the PASS lands at
# heads/<name>.json, the spelling this hook enumerates; the tag is deleted, a newer run's
# revoke looks only under the bare name, and the tag comes back.
( cd "$RX" && git checkout -qb feature main && echo f > f.js && git add -A && git commit -qm feature \
   && git tag feature ) >/dev/null 2>&1
XFC="$(git -C "$RX" rev-parse refs/heads/feature)"
xgate "$XFC"; xpush feature "$XFC"; p32_before=$RC
p32_written=0; [ -f "$XMD/heads/feature.json" ] && p32_written=1
git -C "$RX" tag -d feature >/dev/null 2>&1; xrevoke "$XFC"; git -C "$RX" tag feature "$XFC" >/dev/null 2>&1
xpush feature "$XFC"
[ "$p32_written" = 1 ] && [ "$p32_before" = 0 ] && [ -f "$XMD/heads/feature.json" ] && xblocked feature "$XFC" \
  && ok "P32: a PASS under the heads/<name> spelling is BLOCKED once a newer run starts on its commit" \
  || nok "P32: the stale heads/<name> PASS authorized the push" "written=$p32_written before=$p32_before rc=$RC out=$OUT"

# P39 (positive and WRONG-FIX control, case i): a sibling branch at the same commit as a
# current PASS, with no marker of its own.
( cd "$RX" && git checkout -qb s1 main && echo s > s.js && git add -A && git commit -qm s ) >/dev/null 2>&1
XSC="$(git -C "$RX" rev-parse refs/heads/s1)"
xgate "$XSC"; git -C "$RX" branch s2 "$XSC" >/dev/null 2>&1; xpush s2 "$XSC"
[ "$RC" = 0 ] && [ ! -e "$XMD/s2.json" ] \
  && ok "P39: a sibling branch at the same commit as a current PASS -> ALLOWED" \
  || nok "P39: a sibling of a current PASS was refused" "rc=$RC out=$OUT"
git -C "$RX" checkout -q main >/dev/null 2>&1

# P40: the enforced hook reads a marker ONCE (F12 in test/gate-test.sh drives the
# reminder through the same fixture). A scratch copy of scripts/ whose
# forgeward-diff-hash.sh FIRST moves a prepared marker over a named one, THEN execs the
# real helper, so the swap lands between the reads of .diff_hash and .run_id with no
# sleep. PASS on ship at C (M1); a VERSION-only C2 on top, same diff; a second run on C
# makes M1's run stale; M2 is a current PASS for a DIFFERENT diff (D, on d). Leg 1 (M1
# alone) and leg 2 (M2 in place before the push) are controls; leg 3 (M1 in place, M2
# swapped in mid-check) is the PRE-FIX control -- e9ab0e0's hook takes M1's hash and M2's
# run and ALLOWS the push; leg 4 is the positive control, a current PASS swapped for an
# identical copy of itself. A `.fired` file proves each swap really ran. Mutation-checked:
# handing run_is_current the marker PATH instead of the copy turns leg 3 red.
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
SR="$TMP/swaprepo"; git init -q "$SR"
( cd "$SR"; git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  git config forgeward.gate enabled
  echo 0.1.0 > VERSION; echo base > a.txt; git add -A; git commit -qm base; git branch -M main
  git checkout -qb ship; echo 'const s = 1;' > s.js; git add -A; git commit -qm feat ) >/dev/null 2>&1
SB="$(git -C "$SR" rev-parse main)"; SC="$(git -C "$SR" rev-parse HEAD)"
SMD="$(git -C "$SR" rev-parse --path-format=absolute --git-common-dir)/forgeward-gate-markers"
sgate() { # sgate <commit>: a passing gate run on <commit> from the current checkout
  local run
  run="$(cd "$SR" && "$WRITE" --revoke "$1" 2>/dev/null | sed -n 's/^RUN_ID=//p')"
  ( cd "$SR" && "$WRITE" main privacy "$SB" "$1" "$run" ) >/dev/null 2>&1
}
sgate "$SC"
( cd "$SR" && echo 0.2.0 > VERSION && git commit -qam 'chore: bump version' ) >/dev/null 2>&1
SC2="$(git -C "$SR" rev-parse HEAD)"
cp "$SMD/ship.json" "$TMP/p40.m1"
( cd "$SR" && "$WRITE" --revoke "$SC" ) >/dev/null 2>&1
( cd "$SR" && git checkout -qb d main && echo 'const d = 1;' > d.js && git add -A && git commit -qm d ) >/dev/null 2>&1
SD="$(git -C "$SR" rev-parse HEAD)"; sgate "$SD"; cp "$SMD/d.json" "$TMP/p40.m2"
git -C "$SR" checkout -q ship >/dev/null 2>&1
spush() { # spush <branch> <sha> <swap-from> <swap-to>: the copied enforcer; sets RC and OUT
  OUT="$(cd "$SR" && printf 'refs/heads/%s %s refs/heads/%s %s\n' "$1" "$2" "$1" "$RSHA" \
    | FORGEWARD_SECRET_SCAN=skip FORGEWARD_SWAP_FROM="$3" FORGEWARD_SWAP_TO="$4" \
      "$SW/scripts/forgeward-pre-push.sh" origin /nonexistent.git 2>&1)"; RC=$?
}
cp "$TMP/p40.m1" "$SMD/ship.json"; spush ship "$SC2" "" ""; p40_1=$RC; p40_1o=$OUT
cp "$TMP/p40.m2" "$SMD/ship.json"; spush ship "$SC2" "" ""; p40_2=$RC
cp "$TMP/p40.m1" "$SMD/ship.json"; cp "$TMP/p40.m2" "$TMP/p40.swap"
spush ship "$SC2" "$TMP/p40.swap" "$SMD/ship.json"; p40_3=$RC; p40_3o=$OUT
p40_3f=0; [ -e "$TMP/p40.swap.fired" ] && p40_3f=1
cp "$SMD/d.json" "$TMP/p40.same"
spush d "$SD" "$TMP/p40.same" "$SMD/d.json"; p40_4=$RC
p40_4f=0; [ -e "$TMP/p40.same.fired" ] && p40_4f=1
[ "$p40_1" = 1 ] && case "$p40_1o" in *"  - ship @ ${SC2:0:12}"*) true ;; *) false ;; esac \
  && [ "$p40_2" = 1 ] && [ "$p40_3f" = 1 ] && [ "$p40_3" = 1 ] \
  && case "$p40_3o" in *"have not passed /forgeward:gate"*"  - ship @ ${SC2:0:12}"*) true ;; *) false ;; esac \
  && [ "$p40_4f" = 1 ] && [ "$p40_4" = 0 ] \
  && ok "P40: a marker swapped in while the enforcer hashes cannot lend its run to the stale PASS it replaced -> BLOCKED" \
  || nok "P40: the enforcer combined two markers' fields" \
         "m1-alone=$p40_1 m2-alone=$p40_2 swap=$p40_3f:$p40_3 same=$p40_4f:$p40_4 out=$p40_3o"

# P41 (WRONG-FIX control for dropping revoke's deletion loop; green on e9ab0e0 by
# construction): the deletions narrow the per-diff residual for the branch's own
# follow-up commits. PASS on C1 on branch b; C2 on b changes only VERSION (same diff);
# a gate run starts on C2 and FAILs -- its revoke deletes b's marker, because b is at C2,
# while C1's run stays current; then C3 on b changes only CHANGELOG.md, with no run file.
# Had the deletion been skipped, C3 would push on C1's PASS. The first leg is the control
# that the PASS covered C2's diff before the revoke. Mutation-checked: skipping the
# deletions turns this red.
( cd "$RX" && git checkout -qb rb main && echo 'const rb = 1;' > rb.js && git add -A \
   && git commit -qm rb ) >/dev/null 2>&1
XR1="$(git -C "$RX" rev-parse HEAD)"; xgate "$XR1"
( cd "$RX" && echo 2.0.0 > VERSION && git add VERSION && git commit -qm 'chore: bump version' ) >/dev/null 2>&1
XR2="$(git -C "$RX" rev-parse HEAD)"; xpush rb "$XR2"; p41_before=$RC
xrevoke "$XR2"
( cd "$RX" && echo '# log' > CHANGELOG.md && git add CHANGELOG.md && git commit -qm 'docs: changelog' ) >/dev/null 2>&1
XR3="$(git -C "$RX" rev-parse HEAD)"; xpush rb "$XR3"
[ "$p41_before" = 0 ] && [ ! -e "$XMD/rb.json" ] && [ ! -e "$XRUNS/$XR3" ] && xblocked rb "$XR3" \
  && ok "P41: after a FAIL on a same-diff follow-up commit, a later commit on that branch with no run file -> BLOCKED" \
  || nok "P41: a follow-up commit pushed on the PASS a failed run withdrew" "before=$p41_before rc=$RC out=$OUT"

# P42 (contract pin of run_is_current's -L arm; green on e9ab0e0): a DANGLING SYMLINK at
# the pushed commit's run-file path counts as a run file of its own (`[ -e ]` alone is
# false for it). The positive control is the same push with that path absent. A VERSION-
# only commit after a PASS is the shape that is otherwise accepted (P38). Mutation-
# checked: dropping `|| [ -L ... ]` turns this red.
( cd "$RX" && git checkout -qb sl main && echo 'const sl = 1;' > sl.js && git add -A \
   && git commit -qm sl ) >/dev/null 2>&1
XSL="$(git -C "$RX" rev-parse HEAD)"; xgate "$XSL"
( cd "$RX" && echo 3.0.0 > VERSION && git add VERSION && git commit -qm 'chore: bump version' ) >/dev/null 2>&1
XSLV="$(git -C "$RX" rev-parse HEAD)"; xpush sl "$XSLV"; p42_absent=$RC
ln -s "$XRUNS/no-such-target" "$XRUNS/$XSLV"
xpush sl "$XSLV"; p42_link=$RC
rm -f "$XRUNS/$XSLV"
[ "$p42_absent" = 0 ] && [ "$p42_link" = 1 ] && xblocked sl "$XSLV" \
  && ok "P42: a dangling symlink at the pushed commit's run-file path -> BLOCKED; with the path absent -> ALLOWED" \
  || nok "P42: a dangling run-file symlink was not counted" "absent=$p42_absent link=$p42_link out=$OUT"

# P43: the writer and this hook read a run file the same way -- its FIRST line. Leg A, a
# run file holding the run id and then another line: both accept (PRE-FIX control:
# e9ab0e0's writer read the whole file with `cat` and refused while the hook accepted).
# Leg B, the run id on the SECOND line: both refuse (WRONG-FIX control for reading the
# last line or matching the id on any line; green on e9ab0e0). Leg B's marker is a valid
# PASS written before the run file is rewritten, so only the run file refuses it.
# Mutation-checked: restoring `cat` in the writer's current_run turns leg A red.
P43SUP='superseded this one (or no run is recorded for that commit); nothing was written.'
( cd "$RX" && git checkout -qb tl main && echo 'const tl = 1;' > tl.js && git add -A \
   && git commit -qm tl ) >/dev/null 2>&1
XTL="$(git -C "$RX" rev-parse HEAD)"
XRUN="$(cd "$RX" && "$WRITE" --revoke "$XTL" 2>/dev/null | sed -n 's/^RUN_ID=//p')"
printf '%s\nsecond line\n' "$XRUN" > "$XRUNS/$XTL"
p43_aw="$(cd "$RX" && "$WRITE" main privacy "$XB" "$XTL" "$XRUN" 2>&1)"; p43_awrc=$?
xpush tl "$XTL"; p43_arc=$RC; p43_aout=$OUT
xgate "$XTL"
printf '%s\n%s\n' "$(printf 'c%.0s' $(seq 40))" "$XRUN" > "$XRUNS/$XTL"
xpush tl "$XTL"
p43_bw="$(cd "$RX" && "$WRITE" main privacy "$XB" "$XTL" "$XRUN" 2>&1)"; p43_bwrc=$?
[ "$p43_awrc" = 0 ] && [ "$p43_arc" = 0 ] && [ "$p43_bwrc" = 1 ] && xblocked tl "$XTL" \
  && case "$p43_bw" in *"$P43SUP"*) true ;; *) false ;; esac \
  && ok "P43: run id on the first line -> the writer and the hook both accept; on the second line -> both refuse" \
  || nok "P43: the writer and the hook disagree on a two-line run file" \
         "A: write=$p43_awrc push=$p43_arc ($p43_aw / $p43_aout) B: write=$p43_bwrc push=$RC ($p43_bw / $OUT)"
git -C "$RX" checkout -q main >/dev/null 2>&1

[ "$CAPTURE_LEAK" = 0 ] \
  && ok "all captured hook stdout/stderr and the bypass log omit the planted credential value" \
  || nok "captured output/log credential non-disclosure" "a captured channel contained the planted value"

echo "1..$((PASS+FAIL))"
echo "# pass $PASS / fail $FAIL"
[ "$FAIL" -eq 0 ]
