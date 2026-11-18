#!/usr/bin/env bash
# Focused packaging and hook-contract tests for the Claude Code + Codex plugin.
set -uo pipefail

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$PLUGIN/scripts/forgeward-gate-check.sh"
WRITE="$PLUGIN/scripts/forgeward-write-marker.sh"
# The writer takes the reviewed commits and the gate run's id since 0.31.0. Every caller
# here gates the commit it just made, so both are resolved in the caller's cwd at call
# time, and the run is minted the way Step 2 mints it: a `--revoke` of that commit, whose
# `RUN_ID=` line is taken and whose other output is kept off this helper's stdout.
write_marker() { # write_marker <base-ref> <fired-csv>
  local head run
  head="$(git rev-parse HEAD)"
  run="$("$WRITE" --revoke "$head" | sed -n 's/^RUN_ID=//p')"
  "$WRITE" "$1" "$2" "$(git rev-parse "$1")" "$head" "$run"
}
HASH="$PLUGIN/scripts/forgeward-diff-hash.sh"
PREPUSH="$PLUGIN/scripts/forgeward-pre-push.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok %d - %s\n' "$((PASS+FAIL))" "$1"; }
nok() { FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$((PASS+FAIL))" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/forgeward-dual-client.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

json_value() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }
run_hook() { # run_hook <mode> <payload> -> sets out/st
  out="$(printf '%s' "$2" | "$CHECK" "$1" 2>&1)"; st=$?
}

frontmatter_value() { # frontmatter_value <file> <key>
  awk -v key="$2" '
    NR == 1 && $0 == "---" { frontmatter = 1; next }
    frontmatter && $0 == "---" { exit }
    frontmatter && index($0, key ":") == 1 {
      sub(/^[^:]*:[[:space:]]*/, "")
      print
      exit
    }
  ' "$1"
}

frontmatter_key_count() { # frontmatter_key_count <file> <key>
  awk -v key="$2" '
    NR == 1 && $0 == "---" { frontmatter = 1; next }
    frontmatter && $0 == "---" { exit }
    frontmatter && index($0, key ":") == 1 { count++ }
    END { print count + 0 }
  ' "$1"
}

# Reviewer launch policy is split along the runtimes' native boundaries: Claude
# plugin-agent frontmatter owns Claude selection, while the Codex gate spawn owns
# Codex selection and context isolation. Enumerate the canonical agent directory so a
# newly added reviewer cannot inherit merely because this test's list went stale.
expected_reviewers="accessibility-reviewer
ai-output-reviewer
api-contract-reviewer
data-migration-reviewer
maintainability-reviewer
performance-reviewer
privacy-reviewer
security-reviewer
seo-reviewer
supply-chain-reviewer
targeted-reviewer
testing-reviewer"
actual_reviewers="$(for reviewer_file in "$PLUGIN"/agents/*-reviewer.md; do
  frontmatter_value "$reviewer_file" name
done | sort)"
[ "$actual_reviewers" = "$expected_reviewers" ] \
  && ok "reviewer inventory covers every canonical Forgeward reviewer" \
  || nok "reviewer inventory" "actual=$actual_reviewers"

claude_models_ok=true
claude_efforts_ok=true
for reviewer_file in "$PLUGIN"/agents/*-reviewer.md; do
  [ "$(frontmatter_value "$reviewer_file" model)" = sonnet ] \
    && [ "$(frontmatter_key_count "$reviewer_file" model)" -eq 1 ] \
    || claude_models_ok=false
  [ "$(frontmatter_value "$reviewer_file" effort)" = medium ] \
    && [ "$(frontmatter_key_count "$reviewer_file" effort)" -eq 1 ] \
    || claude_efforts_ok=false
done
[ "$claude_models_ok" = true ] \
  && ok "Claude reviewer agents explicitly select Sonnet instead of inheriting the parent model" \
  || nok "Claude reviewer model policy"
[ "$claude_efforts_ok" = true ] \
  && ok "Claude reviewer agents explicitly select medium effort instead of inheriting parent effort" \
  || nok "Claude reviewer effort policy"

gate_step2="$(sed -n '/^## Step 2 — Run the fired reviewers/,/^## Step 3 — Decide/p' "$PLUGIN/skills/gate/SKILL.md")"
case "$gate_step2" in
  *'model: "gpt-5.6-terra"'*'reasoning_effort: "medium"'*)
    ok "Codex reviewer launches explicitly select gpt-5.6-terra with medium reasoning" ;;
  *) nok "Codex reviewer model and reasoning policy" ;;
esac
case "$gate_step2" in
  *'fork_turns: "none"'*'gpt-5.6-sol'*'high reasoning'*'any other configuration'*)
    ok "Codex reviewer launches isolate context and cannot inherit another parent configuration" ;;
  *) nok "Codex reviewer parent isolation policy" ;;
esac

gate_reviewers_ok=true
while IFS= read -r reviewer; do
  case "$gate_step2" in *"forgeward:$reviewer"*) ;; *) gate_reviewers_ok=false ;; esac
done <<EOF
$expected_reviewers
EOF
[ "$gate_reviewers_ok" = true ] \
  && ok "Gate dispatch applies the runtime policy to every Forgeward reviewer type" \
  || nok "Gate reviewer dispatch coverage"

case "$gate_step2" in
  *'complete applicable'*'absolute repository root'*'`<base>` exactly'*'`<BASE_SHA>` and `<HEAD_SHA>`'*'<BASE_SHA>...<HEAD_SHA>'*'required verdict format'*'Do not pass'*'the parent conversation'*)
    ok "reviewer launch context keeps the complete rubric and required repository/diff instructions" ;;
  *) nok "reviewer launch context contract" ;;
esac

# 0.31.0: the gate freezes its review subject in Step 0 and certifies exactly that.
gate_step0="$(sed -n '/^## Step 0 — /,/^## Step 1 — /p' "$PLUGIN/skills/gate/SKILL.md")"
gate_step3="$(sed -n '/^## Step 3 — Decide/,/^## Rules/p' "$PLUGIN/skills/gate/SKILL.md")"
case "$gate_step0" in
  *'BASE_SHA="$(git rev-parse --verify --quiet "<base>^{commit}")"'*'HEAD_SHA="$(git rev-parse --verify --quiet "HEAD^{commit}")"'*'full names exactly as printed'*)
    ok "Step 0 freezes the review subject to two commit names before anything is scoped" ;;
  *) nok "Step 0 frozen review subject" ;;
esac
# Pin the VIOLATING form, with a floor on the right one: the symbolic range may survive
# only in the one sentence that translates rubrics written against it.
symbolic_ranges="$(grep -o '<base>\.\.\.HEAD' "$PLUGIN/skills/gate/SKILL.md" | wc -l)"
frozen_ranges="$(grep -o '<BASE_SHA>\.\.\.<HEAD_SHA>' "$PLUGIN/skills/gate/SKILL.md" | wc -l)"
[ "$symbolic_ranges" -eq 1 ] && [ "$frozen_ranges" -ge 5 ] \
  && ok "the gate reviews <BASE_SHA>...<HEAD_SHA> throughout; the symbolic range survives only where rubrics are translated" \
  || nok "frozen review range" "symbolic=$symbolic_ranges frozen=$frozen_ranges"
revoke_at="$(awk '/forgeward-write-marker\.sh" --revoke/{print NR; exit}' <<<"$gate_step2")"
snapshot_at="$(awk '/forgeward-workspace-guard\.sh" snapshot/{print NR; exit}' <<<"$gate_step2")"
[ -n "$revoke_at" ] && [ -n "$snapshot_at" ] && [ "$revoke_at" -lt "$snapshot_at" ] \
  && ok "Step 2 withdraws any earlier PASS before it snapshots or spawns anything" \
  || nok "Step 2 revoke ordering" "revoke=$revoke_at snapshot=$snapshot_at"
case "$gate_step3" in
  *'forgeward-write-marker.sh" "<base>" "<comma-separated fired reviewers>" "<BASE_SHA>" "<HEAD_SHA>" "<RUN_ID>"'*)
    ok "Step 3 hands the marker writer the commits Step 0 froze and this run's id" ;;
  *) nok "Step 3 writer arguments" ;;
esac
# Every --revoke in the skill must name the commit Step 0 froze: a bare one is a usage
# error since the pre-landing review of 0.31.0, and before that it followed live HEAD.
# Pin the VIOLATING form (bare occurrences == 0) with a floor on the right one (>= 7:
# 2a's revoke, Step 3's rows 1-5, and the refused write in row 6).
# `grep -o | wc -l` counts occurrences, not lines.
revoke_all="$(grep -o 'forgeward-write-marker\.sh" --revoke' "$PLUGIN/skills/gate/SKILL.md" | wc -l)"
revoke_frozen="$(grep -o 'forgeward-write-marker\.sh" --revoke "<HEAD_SHA>"' "$PLUGIN/skills/gate/SKILL.md" | wc -l)"
[ "$((revoke_all - revoke_frozen))" -eq 0 ] && [ "$revoke_frozen" -ge 7 ] \
  && ok "every --revoke in the gate skill names the frozen <HEAD_SHA>" \
  || nok "bare --revoke in the gate skill" "all=$revoke_all frozen=$revoke_frozen"
# Each Step 3 outcome that ends without a marker must carry its OWN revoke. A count over
# the whole step stays green when one outcome loses its revoke and another gains a
# second, so each outcome's text is cut out between its own two anchors and checked
# alone. If EITHER anchor stops matching, the section is empty and the check fails -- a
# missing end anchor must not let a section run on into the next outcome's revoke and
# pass vacuously.
between() { # between <text> <start> <end>: the text between the two, or nothing
  local t="$1"
  case "$t" in *"$2"*) ;; *) return 0 ;; esac
  t="${t#*"$2"}"
  case "$t" in *"$3"*) printf '%s' "${t%%"$3"*}" ;; esac
}
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; } # has <text> <literal>
count_in() { grep -oF -- "$2" <<<"$1" | wc -l; }            # count_in <text> <literal>

# 0.32.0: Step 3 is six numbered rows and the first match wins, so the order is part of
# the contract (a FAIL must be reported before an incomplete sibling, a changed
# workspace before either). Each label exactly once, at strictly increasing lines.
step3_rows='**1. The workspace changed**
**2. The workspace could not be checked**
**3. The review did not run to completion**
**4. A reviewer returned FAIL**
**5. A reviewer is incomplete**
**6. Every fired reviewer returned PASS**'
rows_ok=true; last_at=0; rows_seen=0
while IFS= read -r label; do
  n="$(count_in "$gate_step3" "$label")"
  at="$(awk -v l="$label" 'index($0, l) { print NR; exit }' <<<"$gate_step3")"
  if [ "$n" -ne 1 ] || [ -z "$at" ] || [ "$at" -le "$last_at" ]; then rows_ok=false; fi
  last_at="${at:-0}"; rows_seen=$((rows_seen + 1))
done <<<"$step3_rows"
[ "$rows_ok" = true ] && [ "$rows_seen" -eq 6 ] \
  && ok "Step 3's six rows appear once each, in first-match order" \
  || nok "Step 3 row order" "rows_seen=$rows_seen"
# Rows 1-5 each revoke, cut out between consecutive labels; the refused write in row 6
# revokes too.
prev=""
while IFS= read -r label; do
  if [ -n "$prev" ]; then
    section="$(between "$gate_step3" "$prev" "$label")"
    has "$section" 'forgeward-write-marker.sh" --revoke "<HEAD_SHA>"' \
      && ok "Step 3 withdraws the marker on row $prev" \
      || nok "Step 3 revoke on row $prev" "section-bytes=${#section}"
  fi
  prev="$label"
done <<<"$step3_rows"
section="$(between "$gate_step3" 'If the writer exits non-zero' 'Then hand off')"
has "$section" 'forgeward-write-marker.sh" --revoke "<HEAD_SHA>"' \
  && ok "Step 3 withdraws the marker on a refused marker write" \
  || nok "Step 3 revoke on a refused marker write" "section-bytes=${#section}"

# 0.32.0: Step 2 is four parts. Each heading exactly once and in order, so a cut between
# two of them cannot silently run to the end of the file.
SKILL_GATE="$PLUGIN/skills/gate/SKILL.md"
parts_ok=true; last_at=0
for part in '### 2a — ' '### 2b — ' '### 2c — ' '### 2d — '; do
  n="$(grep -c -- "^$part" "$SKILL_GATE")"
  at="$(awk -v l="$part" 'index($0, l) == 1 { print NR; exit }' "$SKILL_GATE")"
  if [ "$n" -ne 1 ] || [ -z "$at" ] || [ "$at" -le "$last_at" ]; then parts_ok=false; fi
  last_at="${at:-0}"
done
[ "$parts_ok" = true ] \
  && ok "Step 2's four parts appear once each, in order" \
  || nok "Step 2 part headings"
gate_2a="$(sed -n '/^### 2a — /,/^### 2b — /p' "$SKILL_GATE")"
gate_2b="$(sed -n '/^### 2b — /,/^### 2c — /p' "$SKILL_GATE")"
gate_2c="$(sed -n '/^### 2c — /,/^### 2d — /p' "$SKILL_GATE")"
gate_2d="$(sed -n '/^### 2d — /,/^## Step 3 — /p' "$SKILL_GATE")"

# The run directory is created and PRINTED in one command: a shell variable does not
# survive into a later tool call, which is how 0.31.0's `$ART/tree-before` came to name a
# file that never existed. Pin the violating form too: `$ART` may appear only where the
# run directory is made inside it, and `tree-before` nowhere.
run_dir_block='RUN_DIR="$(mktemp -d "$ART/run.XXXXXX")" || exit 1
printf '\''RUN_DIR=%s\n'\'' "$RUN_DIR"'
art_uses="$(grep -oF -- '$ART' "$SKILL_GATE" | wc -l)"
tree_before="$(grep -oF -- 'tree-before' "$SKILL_GATE" | wc -l)"
has "$gate_2a" "$run_dir_block" && [ "$art_uses" -eq 1 ] && [ "$tree_before" -eq 0 ] \
  && ok "2a creates the run directory and prints its path in the same command" \
  || nok "2a run directory" "art_uses=$art_uses tree_before=$tree_before"
has "$gate_2a" '"<forgeward-root>/scripts/forgeward-workspace-guard.sh" snapshot "<HEAD_SHA>" > "<RUN_DIR>/snapshot"' \
  && ok "2a records the workspace for the frozen commit into the run directory" \
  || nok "2a snapshot command"
checks="$(grep -oF -- 'forgeward-workspace-guard.sh" check' "$SKILL_GATE" | wc -l)"
has "$gate_2d" '"<forgeward-root>/scripts/forgeward-workspace-guard.sh" check "<RUN_DIR>/snapshot"' && [ "$checks" -eq 1 ] \
  && ok "the workspace is checked exactly once, in 2d" \
  || nok "2d check command" "checks=$checks"
# 2a's three stops, each between its own anchors.
s1="$(between "$gate_2a" '--revoke "<HEAD_SHA>"' 'Then create this run')"
s2="$(between "$gate_2a" 'Then create this run' 'Then record the workspace')"
s3="$(between "$gate_2a" 'Then record the workspace' 'These three stops')"
has "$s1" 'forgeward gate: could not start this gate run cleanly' \
  && has "$s2" "forgeward gate: could not create this run's directory outside the repo" \
  && has "$s3" 'forgeward gate: could not record the workspace before review' \
  && ok "2a's three stops each sit after the step they stop" \
  || nok "2a stop lines" "bytes=${#s1}/${#s2}/${#s3}"
# Once anything is launched, no path may stop before 2d's check: 2b and 2c carry no stop
# line, and a failed launch goes on to 2c.
if has "$gate_2b$gate_2c" 'stop with' || has "$gate_2b$gate_2c" '`forgeward gate: '; then
  nok "2b/2c carry a stop that skips the workspace check"
else
  # EXACT pin of the launch-failed paragraph, not a `go to 2c` substring: a paragraph that
  # said "go to 2c only if every launch succeeded; otherwise return immediately to the user
  # without a marker" contains the substring and skips 2d. Whitespace is collapsed so a
  # re-wrap does not redden it; any wording change does, on purpose.
  lf="$(between "$gate_2b" '**If a launch fails**' 'This is also the fallback')"
  lf="$(printf '%s' "$lf" | tr '\n' ' ' | tr -s ' ')"; lf="${lf# }"; lf="${lf% }"
  lf_want=", or the runtime cannot spawn the required reviewers with the explicit runtime policy above: stop every reviewer that did start (2c), mark the run **launch-failed**, and go to 2c. An unmeasured axis cannot return PASS, and a reviewer that did start may have written into the repo, so the run still ends at 2d's check."
  if [ -n "$lf" ] && [ "$lf" = "$lf_want" ] && [ -n "$gate_2c" ]; then
    ok "no path out of 2b or 2c skips 2d's check (the launch-failed paragraph is pinned exactly)"
  else
    nok "2b launch-failed paragraph is not the pinned text" "2b-bytes=${#gate_2b} got='$lf'"
  fi
fi
# Step 3 row 2 and 2d: a check that was denied, timed out or never ran is "could not be
# checked", not clean. Each section is cut between its own anchors, so a missing anchor
# empties the cut and fails the assertion.
row2="$(between "$gate_step3" '**2. The workspace could not be checked**' '**3. The review did not run to completion**')"
if has "$row2" 'any other non-zero' && has "$row2" 'the check did not run or report a status'; then
  ok "Step 3 row 2 covers a check that exited non-zero or did not run or report a status"
else
  nok "Step 3 row 2 wording" "row2-bytes=${#row2}"
fi
d_tail="$(between "$gate_2d" 'Exit 2, or any other non-zero' '## Step 3')"
if has "$d_tail" 'denied, timed out, or never ran or reported a status' && has "$d_tail" 'never read'; then
  ok "2d reads a denied, timed-out or never-run check as could-not-check, never as clean"
else
  nok "2d could-not-check wording" "2d-tail-bytes=${#d_tail}"
fi
c2c_ok=true
for phrase in 'Only output from an agent id recorded in 2b counts' 'A receipt is never a result' \
  'There is no deadline' 'select:TaskStop' '`wait_agent`' 'timed_out: true' '`close_agent`' \
  '`interrupt_agent`' '**cancelled**' '**not-started**' '**unconfirmed**'; do
  has "$gate_2c" "$phrase" || { c2c_ok=false; printf '  # 2c lacks: %s\n' "$phrase"; }
done
[ "$c2c_ok" = true ] \
  && ok "2c accounts for every reviewer by recorded id, with no deadline" \
  || nok "2c lifecycle phrases"
has "$gate_2d" 'forgeward gate: a reviewer may still be running; anything it writes from now on is unchecked.' \
  && ok "2d names the window an unconfirmed stop leaves open" \
  || nok "2d unconfirmed line"
# The tools 2c needs must be granted. A list is read as list items under the key, so a
# tool named only in prose elsewhere cannot satisfy it.
gate_tools="$(awk '
  NR == 1 && $0 == "---" { fm = 1; next }
  fm && $0 == "---" { exit }
  fm && $0 == "allowed-tools:" { inlist = 1; next }
  inlist && /^  - / { sub(/^  - /, ""); print; next }
  inlist { inlist = 0 }
' "$SKILL_GATE")"
tools_ok=true
for tool in Bash Agent TaskStop ToolSearch; do
  grep -qx -- "$tool" <<<"$gate_tools" || tools_ok=false
done
[ "$tools_ok" = true ] \
  && ok "the gate skill is granted TaskStop and ToolSearch" \
  || nok "gate allowed-tools" "$(printf '%s' "$gate_tools" | tr '\n' ',')"

audit_policy="$(sed -n '/^## Runtime compatibility/,/^<!-- PORTED AUDIT PHASES/p' "$PLUGIN/skills/audit/SKILL.md"; sed -n '/^\*\*Parallel verification\.\*\*/,/^\*\*Give the verifier/p' "$PLUGIN/skills/audit/SKILL.md")"
case "$audit_policy" in
  *'model: sonnet'*'effort: medium'*'model: gpt-5.6-terra'*'reasoning_effort: medium'*'fork_turns: none'*'absolute repository root'*)
    ok "Audit verifier launches share the explicit Claude and Codex runtime policy" ;;
  *) nok "Audit verifier runtime policy" ;;
esac

case "$gate_step2|$audit_policy" in
  *'fallback for any other runtime'*'self-verification fallback'*'intentionally unchanged'*)
    ok "non-Claude/Codex launch fallbacks remain explicit and unchanged" ;;
  *) nok "other-runtime fallback policy" ;;
esac

# 0.33.0: targeted-reviewer (docs/upstream-lenses-design.md §6, §7.2, §7.4). Its verdict
# rests on reads beyond the hunk, so it is the one rubric told to read the reviewed commit
# and never the working tree. Every literal below is read from the forgeward-authored part
# of the file, above the separator line that opens the ported body, so upstream's own text
# cannot satisfy an assertion here. flat() folds line wrapping, so a re-wrap of the prose
# does not redden them; a reworded rule does.
flat() { tr '\n' ' ' | tr -s ' '; }
TARGETED="$PLUGIN/agents/targeted-reviewer.md"
tr_own="$(awk '/^---$/ { c++ } c >= 3 { exit } { print }' "$TARGETED" 2>/dev/null | flat)"
[ "${#tr_own}" -ge 2000 ] && has "$tr_own" '`git show <HEAD_SHA>:<path>` reads a file' \
  && ok "targeted-reviewer reads every line it cites with git show at <HEAD_SHA>" \
  || nok "targeted reviewed-commit read instruction" "own-bytes=${#tr_own}"
has "$tr_own" 'not the working tree, inside the diff and outside it.' \
  && ok "targeted-reviewer's reviewed-commit rule covers the changed files, not only the rest of the repo" \
  || nok "targeted reviewed-commit scope"
has "$tr_own" 'no `checkout`, `switch`, `restore`, `reset`, `stash`, `worktree`, `clean` or `commit`.' \
  && ok "targeted-reviewer forbids every git command that changes state" \
  || nok "targeted forbidden git commands"
tr_override='This Severity section overrides the checklist body'"'"'s own severity sentences, its CRITICAL-floor paragraph and its Forced-CRITICAL paragraph. Do not open `review/checklist.md` or any other gstack file, even where one is installed. The Forced-CRITICAL classes are the three listed above.'
has "$tr_own" "$tr_override" \
  && ok "targeted-reviewer carries the severity override sentence word for word" \
  || nok "targeted severity override sentence"
has "$tr_own" '`TARGETED VERDICT: PASS` if zero Critical and zero High, otherwise `TARGETED VERDICT: FAIL`.' \
  && has "$tr_own" 'return `TARGETED VERDICT: FAIL`' \
  && ok "targeted-reviewer ends on one TARGETED VERDICT line, and an unreadable diff or commit is FAIL" \
  || nok "targeted verdict line"
has "$tr_own" '## Reading the ported checklist' && has "$tr_own" 'the Severity section wins.' \
  && ok "targeted-reviewer maps the ported body's vocabulary and says its own Severity section wins" \
  || nok "targeted reading-the-checklist section"
tr_ng_ok=true; tr_ng_miss=""
for needle in '`tokens.css`' '`pricing.mdx`' 'a repo'"'"'s `CLAUDE.md` or `AGENTS.md`' \
    '`MAX = 50`' '**nothing**' 'not checked out' 'gitlink'; do
  has "$tr_own" "$needle" || { tr_ng_ok=false; tr_ng_miss="$tr_ng_miss [$needle]"; }
done
[ "$tr_ng_ok" = true ] \
  && ok "targeted-reviewer writes in the must-not-fire and cannot-see non-goals" \
  || nok "targeted non-goals" "missing:$tr_ng_miss"
# The read-only paragraph is carried verbatim from an existing reviewer (§6). Derived from
# that reviewer, never copied here, with a floor so two empty extractions cannot agree.
ro_para() { awk '/^\*\*Read-only means the filesystem too/ { f = 1 } f && /^$/ { exit } f { print }' "$1"; }
ro_m="$(ro_para "$PLUGIN/agents/maintainability-reviewer.md")"
ro_t="$(ro_para "$TARGETED" 2>/dev/null)"
[ "${#ro_m}" -ge 400 ] && [ "$ro_t" = "$ro_m" ] \
  && ok "targeted-reviewer carries the read-only paragraph byte for byte from an existing reviewer" \
  || nok "targeted read-only paragraph" "maintainability-bytes=${#ro_m} targeted-bytes=${#ro_t}"
# 0.33.0: Step 1 fires targeted-reviewer from a table row and classifies the diff in
# Step 1d, which sits after Step 1c's subsections and directly before Step 2. 2b hands
# the classes to that reviewer only, and privacy's posture to privacy only; the marker and
# the PASS report carry the bare name (docs/upstream-lenses-design.md §7.1).
gate_step1="$(sed -n '/^## Step 1 — /,/^## Step 2 — /p' "$SKILL_GATE")"
gate_1d="$(sed -n '/^### Step 1d — targeted classes$/,/^## Step 2 — /p' "$SKILL_GATE")"
has "$gate_step1" '| `targeted-reviewer` |' \
  && ok "Step 1's table fires targeted-reviewer" \
  || nok "Step 1 table fires targeted-reviewer"
n1d="$(grep -c -- '^### Step 1d — targeted classes$' "$SKILL_GATE")"
at1d="$(awk 'index($0, "### Step 1d — targeted classes") == 1 { print NR; exit }' "$SKILL_GATE")"
atcfg="$(awk 'index($0, "### The config was read") == 1 { print NR; exit }' "$SKILL_GATE")"
at2="$(awk 'index($0, "## Step 2 — ") == 1 { print NR; exit }' "$SKILL_GATE")"
next_head="$(awk -v a="${at1d:-0}" 'NR > a && /^##/ { print NR; exit }' "$SKILL_GATE")"
[ "$n1d" -eq 1 ] && [ -n "$at1d" ] && [ -n "$atcfg" ] && [ -n "$at2" ] \
  && [ "$at1d" -gt "$atcfg" ] && [ "$next_head" = "$at2" ] \
  && ok "Step 1d appears once, after Step 1c's subsections and directly before Step 2" \
  || nok "Step 1d placement" "n=$n1d at=${at1d:-none} config=${atcfg:-none} next=${next_head:-none} step2=${at2:-none}"
d1_ok=true; d1_miss=""
for needle in '**added and deleted**' '- **money:**' '- **gate:**' '- **auth:**' '- **secret:**' \
    'by what it does, not by its extension' 'That exemption is from the gate class only.' \
    '`targeted(money,gate,auth,secret)`' '`targeted(money,secret)`' '**scope hint**' \
    'the bare `targeted`' '**Must NOT fire on:**' '`tokens.css`' '`pricing.mdx`' \
    '**Structurally cannot see:**' '`MAX = 50`' 'gitlink'; do
  has "$gate_1d" "$needle" || { d1_ok=false; d1_miss="$d1_miss [$needle]"; }
done
[ "$d1_ok" = true ] \
  && ok "Step 1d reads added and deleted lines, classifies by function, fails closed to all four classes, prints them, and states its non-goals" \
  || nok "Step 1d contract" "missing:$d1_miss"
fire_example="$(grep -m1 -F -- '`Surfaces: ' "$SKILL_GATE")"
has "$fire_example" 'targeted(money,secret)' \
  && ok "the Step 1 firing-decision example prints targeted with its classes" \
  || nok "firing-decision example prints targeted's classes" "line=$fire_example"
b_open="$(between "$gate_2b" 'The launch context is intentionally small.' 'For each fired reviewer' | flat)"
has "$b_open" 'The reviewer each one concerns also gets its Step 1 classification, and no other reviewer does: `privacy-reviewer` the site posture of each route group it covers (Step 1a), and `targeted-reviewer` its classes (Step 1d).' \
  && ok "2b's opening paragraph gives privacy its posture and targeted its classes, and no other reviewer either" \
  || nok "2b opening paragraph classification sentence" "bytes=${#b_open}"
b_codex="$(between "$gate_2b" 'The prompt must also carry' 'Do not paraphrase' | flat)"
has "$b_codex" 'and, for `privacy-reviewer` and `targeted-reviewer` only, that classification.' \
  && ok "2b's Codex prompt carries that classification for privacy and targeted only" \
  || nok "2b Codex must-also-carry classification" "bytes=${#b_codex}"
row6="$(between "$gate_step3" '**6. Every fired reviewer returned PASS**' 'Then hand off' | flat)"
has "$row6" 'Each entry in the fired list is a bare reviewer name, and so is each name in the PASS report below: `targeted`, never `targeted(money,secret)`' \
  && ok "Step 3 gives the marker writer and the PASS report the bare targeted, never its classes" \
  || nok "Step 3 row 6 bare targeted" "bytes=${#row6}"

# Package routing for a fresh install: the Codex manifest names only the Codex event
# file. This proves the package contract, not how Codex treats old global trust state.
claude_event="$(jq -r '.hooks | keys | sort | join(",")' "$PLUGIN/hooks/hooks.json")"
codex_event="$(jq -r '.hooks | keys | sort | join(",")' "$PLUGIN/hooks/codex-hooks.json")"
codex_hooks="$(jq -r '.hooks' "$PLUGIN/.codex-plugin/plugin.json")"
if [ "$claude_event" = "PreToolUse,UserPromptExpansion" ] \
  && [ "$codex_event" = "PreToolUse,UserPromptSubmit" ] \
  && [ "$codex_hooks" = "./hooks/codex-hooks.json" ]; then
  ok "fresh client manifests route Claude and Codex to separate lifecycle events"
else
  nok "client hook routing" "claude=$claude_event codex=$codex_event manifest=$codex_hooks"
fi

claude_commands="$(jq -r '[.hooks[][] .hooks[] | .command] | join("|")' "$PLUGIN/hooks/hooks.json")"
windows_commands="$(jq -r '.hooks[][] .hooks[] | .commandWindows' "$PLUGIN/hooks/hooks.json" "$PLUGIN/hooks/codex-hooks.json")"
windows_modes="$(printf '%s\n' "$windows_commands" | python3 -I -c 'import base64,re,sys
for line in sys.stdin:
    source=base64.b64decode(line.rsplit(None,1)[1]).decode("utf-16le")
    print(re.search(r"&\$p\s+[^a-z-]*([a-z-]+)", source).group(1))')"
windows_prefixes="$(printf '%s\n' "$windows_commands" | grep -c '^C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ')"
windows_routing_ok=true
# shellcheck disable=SC2016 # the hook variable must remain literal in the manifest
case "$claude_commands" in
  *'${CLAUDE_PLUGIN_ROOT}'*'forgeward-gate-check.sh expansion'*'forgeward-gate-check.sh pretooluse'*) ;;
  *) windows_routing_ok=false ;;
esac
expected_windows_modes="$(printf '%s\n' expansion pretooluse prompt-submit pretooluse)"
if [ "$windows_routing_ok" = true ] \
  && [ "$windows_modes" = "$expected_windows_modes" ] \
  && [ "$windows_prefixes" -eq 4 ]; then
  ok "Claude keeps its normal command while native-Windows routes use the explicit system launcher"
else
  nok "dual-client Windows command routing"
fi

compat_docs="$(sed -n '/That is a packaging contract/,/Lifecycle handlers probe/p' "$PLUGIN/README.md")"
compat_docs_ok=true
for required_text in \
  fresh \
  upgrade \
  'legitimate Claude Code configuration' \
  'cannot safely inspect or prune Codex-owned global trust records'; do
  case "$compat_docs" in *"$required_text"*) ;; *) compat_docs_ok=false ;; esac
done
if [ "$compat_docs_ok" = true ]; then
  ok "compatibility rule documents fresh installs, stale upgrades, the Claude non-match, and its trust-store blind spot"
else
  nok "documented compatibility-rule scope"
fi

# Validate the complete package edge on every platform. The native-Windows suite
# executes these paths, but it is allowed to skip when cmd.exe is unavailable.
package_paths="./hooks/hooks.json
$codex_hooks
$(jq -r '.. | objects | .command? // empty, .commandWindows? // empty' \
  "$PLUGIN/hooks/hooks.json" "$PLUGIN/hooks/codex-hooks.json" \
  | grep -oE 'scripts[\\/][A-Za-z0-9._-]+' | sed 's#\\#/#g')"
package_paths_ok=true
while IFS= read -r package_path; do
  package_path="${package_path#./}"
  [ -n "$package_path" ] || continue
  git -C "$PLUGIN" ls-files --error-unmatch "$package_path" >/dev/null 2>&1 \
    || package_paths_ok=false
done < <(printf '%s\n' "$package_paths" | sort -u)
if [ "$package_paths_ok" = true ]; then
  ok "Claude auto-discovery, the Codex manifest, and every referenced hook script are tracked"
else
  nok "tracked dual-client package paths"
fi

# Codex documents PLUGIN_ROOT for plugin hook processes, not for ordinary skill
# commands. Each skill must therefore be able to recover the plugin root from its own
# catalogued SKILL.md path without searching the versioned cache.
skill_roots_ok=true
for skill in gate audit ci-gate pentest; do
  skill_file="$PLUGIN/skills/$skill/SKILL.md"
  skill_root="$(cd "$(dirname "$skill_file")/../.." && pwd)"
  [ "$skill_root" = "$PLUGIN" ] \
    && [ -x "$skill_root/scripts/forgeward-detect-environment.sh" ] \
    || skill_roots_ok=false
done
[ "$skill_roots_ok" = true ] \
  && ok "normal Codex skills derive the installed plugin root from their SKILL.md paths" \
  || nok "normal Codex skill root derivation"

resolved_root="$(cd "$(dirname "$PLUGIN/skills/gate/SKILL.md")/../.." && pwd)"
out="$(env -u PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT "$resolved_root/scripts/forgeward-detect-environment.sh" 2>&1)"; st=$?
if [ "$st" -eq 0 ] \
  && [ "$(json_value "$out" 'has("gstack_ship")')" = true ] \
  && ! grep -R -F '${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}' "$PLUGIN/skills" >/dev/null; then
  ok "normal skill commands run without hook-only plugin-root variables"
else
  nok "normal skill runtime is independent of hook-only variables" "st=$st out=$out"
fi

# Codex ignores UserPromptSubmit matchers. Absence is intentional and handler-side
# prompt inspection is what keeps ordinary prompts out of the gate path.
if [ "$(jq -r '.hooks.UserPromptSubmit[0] | has("matcher")' "$PLUGIN/hooks/codex-hooks.json")" = false ]; then
  ok "Codex UserPromptSubmit has no ineffective matcher"
else
  nok "Codex UserPromptSubmit matcher omitted"
fi

# Scratch repo: one substantive feature commit, no marker initially.
R="$TMP/repo"
git init -q "$R"
git -C "$R" config user.email t@t.t
git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
printf '%s\n' base > "$R/app.txt"
git -C "$R" add app.txt
git -C "$R" commit -qm base
git -C "$R" branch -M main
git -C "$R" checkout -qb feature
printf '%s\n' feature >> "$R/app.txt"
git -C "$R" commit -qam feature

# Claude UserPromptExpansion: the matcher has already selected /ship, so the adapter
# reads only the event context and uses Claude's exit-2/stderr blocking contract.
claude_expansion="$(printf '{"hook_event_name":"UserPromptExpansion","cwd":"%s","command_name":"ship","prompt":"/ship"}' "$R")"
run_hook expansion "$claude_expansion"
if [ "$st" -eq 2 ] && case "$out" in *'/ship halted'*) true;; *) false;; esac; then
  ok "Claude UserPromptExpansion blocks a stale /ship with exit 2"
else
  nok "Claude UserPromptExpansion block contract" "st=$st out=$out"
fi

# Codex UserPromptSubmit: representative current payload and top-level block decision.
codex_ship="$(printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s","prompt":"$ship","session_id":"s","turn_id":"t"}' "$R")"
run_hook prompt-submit "$codex_ship"
if [ "$st" -eq 0 ] && [ "$(json_value "$out" '.decision')" = block ] && [ -n "$(json_value "$out" '.reason')" ]; then
  ok "Codex UserPromptSubmit blocks a stale direct ship invocation with JSON"
else
  nok "Codex UserPromptSubmit block contract" "st=$st out=$out"
fi

codex_prose="$(printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s","prompt":"Explain how ship hooks work"}' "$R")"
run_hook prompt-submit "$codex_prose"
[ "$st" -eq 0 ] && [ -z "$out" ] \
  && ok "Codex handler allows ordinary prompts that merely mention ship" \
  || nok "Codex ordinary prompt allow" "st=$st out=$out"

# Both clients currently deliver the same core PreToolUse keys, with different common
# metadata around them. Pin the modern deny object Codex and Claude both accept.
claude_pre="$(printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_use_id":"c1","tool_input":{"command":"git push origin feature"}}' "$R")"
codex_pre="$(printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_use_id":"x1","tool_input":{"command":"git push origin feature"},"turn_id":"t","permission_mode":"default"}' "$R")"
for pair in "Claude|$claude_pre" "Codex|$codex_pre"; do
  client="${pair%%|*}"; payload="${pair#*|}"
  run_hook pretooluse "$payload"
  if [ "$st" -eq 0 ] \
    && [ "$(json_value "$out" '.hookSpecificOutput.hookEventName')" = PreToolUse ] \
    && [ "$(json_value "$out" '.hookSpecificOutput.permissionDecision')" = deny ] \
    && [ -n "$(json_value "$out" '.hookSpecificOutput.permissionDecisionReason')" ]; then
    ok "$client PreToolUse payload receives the modern deny object"
  else
    nok "$client PreToolUse deny contract" "st=$st out=$out"
  fi
done

allow_pre="$(printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"printf ok"}}' "$R")"
run_hook pretooluse "$allow_pre"
[ "$st" -eq 0 ] && [ -z "$out" ] \
  && ok "PreToolUse allows an unrelated Bash command without output" \
  || nok "PreToolUse allow contract" "st=$st out=$out"

# Malformed input is event-sensitive: Claude expansion fails closed; the Codex hook,
# which runs on every prompt, narrows its raw fallback; PreToolUse narrows to publish.
run_hook expansion '{not-json'
[ "$st" -eq 2 ] && ok "malformed Claude expansion input blocks" \
  || nok "malformed Claude expansion" "st=$st out=$out"
run_hook prompt-submit '{"prompt":"$ship"'
[ "$st" -eq 0 ] && [ "$(json_value "$out" '.decision')" = block ] \
  && ok "malformed Codex input mentioning ship blocks" \
  || nok "malformed Codex ship input" "st=$st out=$out"
run_hook prompt-submit '{unrelated'
[ "$st" -eq 0 ] && [ -z "$out" ] \
  && ok "malformed unrelated Codex input fails open" \
  || nok "malformed unrelated Codex input" "st=$st out=$out"
run_hook pretooluse '{"tool_input":{"command":"git push"}'
[ "$st" -eq 0 ] && [ "$(json_value "$out" '.hookSpecificOutput.permissionDecision')" = deny ] \
  && ok "malformed PreToolUse input mentioning push blocks" \
  || nok "malformed publish payload" "st=$st out=$out"
run_hook pretooluse '{unrelated'
[ "$st" -eq 0 ] && [ -z "$out" ] \
  && ok "malformed unrelated PreToolUse input fails open" \
  || nok "malformed unrelated PreToolUse payload" "st=$st out=$out"

# With neither supported parser on PATH, this lifecycle guardrail deliberately fails
# open. The standalone Git hook remains the enforcement boundary.
NOPARSER="$TMP/no-parser-bin"
mkdir -p "$NOPARSER"
ln -s "$(command -v cat)" "$NOPARSER/cat"
ln -s "$(command -v dirname)" "$NOPARSER/dirname"
ln -s "$(command -v git)" "$NOPARSER/git"
out="$(printf '%s' "$codex_ship" | PATH="$NOPARSER" /bin/bash "$CHECK" prompt-submit 2>&1)"; st=$?
[ "$st" -eq 0 ] && [ -z "$out" ] \
  && ok "missing jq and Python fail open without wedging the client" \
  || nok "missing JSON parsers" "st=$st out=$out"

git -C "$R" config forgeward.gate enabled
feature_sha="$(git -C "$R" rev-parse HEAD)"
out="$(printf 'refs/heads/feature %s refs/heads/feature %040d\n' "$feature_sha" 0 | (cd "$R" && PATH="$NOPARSER" /bin/bash "$PREPUSH" origin example.invalid) 2>&1)"; st=$?
[ "$st" -eq 0 ] && case "$out" in *'no working jq/python3/python'*'gate not enforced'*) true;; *) false;; esac \
  && ok "standalone pre-push hook names its fail-open when JSON parsers are missing" \
  || nok "pre-push missing JSON parsers" "st=$st out=$out"

# Run the exact manifest commands with only the environment variable provided by the
# corresponding client. This catches accidental hard-coding of one client's root.
claude_cmd="$(jq -r '.hooks.UserPromptExpansion[0].hooks[0].command' "$PLUGIN/hooks/hooks.json")"
codex_cmd="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$PLUGIN/hooks/codex-hooks.json")"
out="$(printf '%s' "$claude_expansion" | CLAUDE_PLUGIN_ROOT="$PLUGIN" bash -c "$claude_cmd" 2>&1)"; st=$?
[ "$st" -eq 2 ] && case "$out" in *'/ship halted'*) true;; *) false;; esac \
  && ok "Claude hook command resolves CLAUDE_PLUGIN_ROOT" \
  || nok "Claude plugin root" "st=$st out=$out"
out="$(printf '%s' "$codex_ship" | PLUGIN_ROOT="$PLUGIN" bash -c "$codex_cmd" 2>&1)"; st=$?
[ "$st" -eq 0 ] && [ "$(json_value "$out" '.decision')" = block ] \
  && ok "Codex hook command resolves PLUGIN_ROOT" \
  || nok "Codex plugin root" "st=$st out=$out"

# A fresh marker allows every lifecycle path.
( cd "$R" && write_marker main dual-client >/dev/null )
run_hook expansion "$claude_expansion"
[ "$st" -eq 0 ] && [ -z "$out" ] \
  && ok "fresh marker allows Claude UserPromptExpansion" \
  || nok "fresh Claude allow" "st=$st out=$out"
run_hook prompt-submit "$codex_ship"
[ "$st" -eq 0 ] && [ -z "$out" ] \
  && ok "fresh marker allows Codex UserPromptSubmit" \
  || nok "fresh Codex allow" "st=$st out=$out"
run_hook pretooluse "$codex_pre"
[ "$st" -eq 0 ] && [ -z "$out" ] \
  && ok "fresh marker allows PreToolUse publish command" \
  || nok "fresh PreToolUse allow" "st=$st out=$out"

# Version agreement across every version-bearing manifest. The Codex marketplace has
# no version field in the current schema and points to the local plugin manifest.
versions="$(jq -r '.version' "$PLUGIN/package.json" "$PLUGIN/.claude-plugin/plugin.json" "$PLUGIN/.codex-plugin/plugin.json"; jq -r '.plugins[0].version' "$PLUGIN/.claude-plugin/marketplace.json")"
if [ "$(printf '%s\n' "$versions" | sort -u)" = 0.33.0 ] \
  && [ "$(jq -r '.plugins[0].source.path' "$PLUGIN/.agents/plugins/marketplace.json")" = './' ] \
  && [ "$(jq -r '.plugins[0].name' "$PLUGIN/.agents/plugins/marketplace.json")" = forgeward ]; then
  ok "all four version-bearing manifests agree and Codex marketplace resolves locally"
else
  nok "version and Codex marketplace agreement" "versions=$versions"
fi

# Diff-hash contract for the fourth manifest: a version-only release is neutral, but
# hook/capability changes are reviewable. Codex marketplace policy is ordinary diff.
H="$TMP/hash-repo"
git init -q "$H"
git -C "$H" config user.email t@t.t
git -C "$H" config user.name t
git -C "$H" config commit.gpgsign false
mkdir -p "$H/.claude-plugin" "$H/.codex-plugin" "$H/.agents/plugins"
printf '{"name":"p","version":"1.0.0"}\n' > "$H/package.json"
printf '{"name":"p","version":"1.0.0"}\n' > "$H/.claude-plugin/plugin.json"
printf '{"plugins":[{"name":"p","version":"1.0.0"}]}\n' > "$H/.claude-plugin/marketplace.json"
printf '{"name":"p","version":"1.0.0","hooks":"./hooks/codex-hooks.json"}\n' > "$H/.codex-plugin/plugin.json"
printf '{"name":"m","plugins":[{"name":"p","source":{"source":"local","path":"./"}}]}\n' > "$H/.agents/plugins/marketplace.json"
git -C "$H" add -A; git -C "$H" commit -qm base; git -C "$H" branch -M main
git -C "$H" checkout -qb feature
base_hash="$(cd "$H" && "$HASH" main main)"
for f in package.json .claude-plugin/plugin.json .codex-plugin/plugin.json; do
  sed -i 's/1\.0\.0/1.0.1/' "$H/$f"
done
sed -i 's/1\.0\.0/1.0.1/' "$H/.claude-plugin/marketplace.json"
git -C "$H" add -A; git -C "$H" commit -qm version
version_hash="$(cd "$H" && "$HASH" main HEAD)"
[ "$base_hash" = "$version_hash" ] \
  && ok "version-only changes across Claude and Codex manifests are diff-hash neutral" \
  || nok "version-only diff hash" "base=$base_hash version=$version_hash"
sed -i 's#codex-hooks.json#stricter-hooks.json#' "$H/.codex-plugin/plugin.json"
git -C "$H" add -A; git -C "$H" commit -qm codex-hooks
codex_hash="$(cd "$H" && "$HASH" main HEAD)"
[ "$codex_hash" != "$version_hash" ] \
  && ok "substantive Codex plugin manifest changes invalidate the marker hash" \
  || nok "substantive Codex manifest diff hash"
sed -i 's#"path":"./"#"path":"./plugin"#' "$H/.agents/plugins/marketplace.json"
git -C "$H" add -A; git -C "$H" commit -qm marketplace
market_hash="$(cd "$H" && "$HASH" main HEAD)"
[ "$market_hash" != "$codex_hash" ] \
  && ok "substantive Codex marketplace changes invalidate the marker hash" \
  || nok "substantive Codex marketplace diff hash"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
