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

git checkout -qb g   main; echo g > g.js;  git add -A; git commit -qm g;  "$WRITE" main "privacy" >/dev/null
SHA_G="$(git rev-parse refs/heads/g)"
git checkout -qb g2  main; echo g2 > g2.js; git add -A; git commit -qm g2; "$WRITE" main "privacy" >/dev/null
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
( cd "$WT"; echo w > w.js; git add -A; git commit -qm wt; "$WRITE" main "privacy" ) >/dev/null
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
  "$WRITE" main "privacy" ) >/dev/null 2>&1
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
( cd "$R" && "$WRITE" main testing >/dev/null )
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
( cd "$R" && "$WRITE" main testing >/dev/null )
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
( cd "$R" && "$WRITE" main testing >/dev/null )
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
( cd "$R" && "$WRITE" main testing >/dev/null )
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
  ( cd "$R" && "$WRITE" main testing >/dev/null )
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

[ "$CAPTURE_LEAK" = 0 ] \
  && ok "all captured hook stdout/stderr and the bypass log omit the planted credential value" \
  || nok "captured output/log credential non-disclosure" "a captured channel contained the planted value"

echo "1..$((PASS+FAIL))"
echo "# pass $PASS / fail $FAIL"
[ "$FAIL" -eq 0 ]
