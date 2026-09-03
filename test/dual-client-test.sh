#!/usr/bin/env bash
# Focused packaging and hook-contract tests for the Claude Code + Codex plugin.
set -uo pipefail

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$PLUGIN/scripts/forgeward-gate-check.sh"
WRITE="$PLUGIN/scripts/forgeward-write-marker.sh"
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
  *'complete applicable'*'absolute repository root'*'`<base>` exactly'*'`HEAD` plus `$HEAD_SHA`'*'<base>...HEAD'*'required verdict format'*'Do not pass'*'the parent conversation'*)
    ok "reviewer launch context keeps the complete rubric and required repository/diff instructions" ;;
  *) nok "reviewer launch context contract" ;;
esac

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

# Package routing: Codex must not consume the Claude-only event definitions.
claude_event="$(jq -r '.hooks | keys | sort | join(",")' "$PLUGIN/hooks/hooks.json")"
codex_event="$(jq -r '.hooks | keys | sort | join(",")' "$PLUGIN/hooks/codex-hooks.json")"
codex_hooks="$(jq -r '.hooks' "$PLUGIN/.codex-plugin/plugin.json")"
if [ "$claude_event" = "PreToolUse,UserPromptExpansion" ] \
  && [ "$codex_event" = "PreToolUse,UserPromptSubmit" ] \
  && [ "$codex_hooks" = "./hooks/codex-hooks.json" ]; then
  ok "client manifests route Claude and Codex to separate lifecycle events"
else
  nok "client hook routing" "claude=$claude_event codex=$codex_event manifest=$codex_hooks"
fi

# Codex documents PLUGIN_ROOT for plugin hook processes, not for ordinary skill
# commands. Each skill must therefore be able to recover the plugin root from its own
# catalogued SKILL.md path without searching the versioned cache.
skill_roots_ok=true
for skill in gate audit ci-gate; do
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
( cd "$R" && "$WRITE" main dual-client >/dev/null )
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
if [ "$(printf '%s\n' "$versions" | sort -u)" = 0.27.0 ] \
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
