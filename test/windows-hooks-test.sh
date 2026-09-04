#!/usr/bin/env bash
# Native-Windows regression suite for Codex commandWindows lifecycle hooks.
set -uo pipefail

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok %d - %s\n' "$((PASS+FAIL))" "$1"; }
nok() { FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$((PASS+FAIL))" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; }

if ! command -v cmd.exe >/dev/null 2>&1; then
  printf '1..0 # SKIP native cmd.exe is unavailable; Windows hook coverage did not run\n'
  exit 0
fi
native_cmd() { MSYS2_ARG_CONV_EXCL='*' cmd.exe "$@"; }

to_windows() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -aw "$1"
  else wslpath -aw "$1"
  fi
}
to_mixed() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -am "$1"
  else wslpath -am "$1"
  fi
}
to_posix() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -au "$1"
  else wslpath -au "$1"
  fi
}

temp_candidate="${TEMP:-${TMP:-}}"
case "$temp_candidate" in
  [A-Za-z]:\\*) WINDOWS_TEMP="$temp_candidate" ;;
  /*) WINDOWS_TEMP="$(to_windows "$temp_candidate")" ;;
  *) WINDOWS_TEMP="$(native_cmd /Q /D /C set TEMP 2>/dev/null | tr -d '\r' \
       | sed -n 's/^[^=]*=\([A-Za-z]:\\.*\)$/\1/p' | tail -n 1)" ;;
esac
case "$WINDOWS_TEMP" in [A-Za-z]:\\*) ;; *) printf 'not ok 1 - native Windows TEMP could not be resolved\n'; exit 1 ;; esac
TEST_WIN="$WINDOWS_TEMP\\forgeward-win-hooks-$$"
TEST_POSIX="$(to_posix "$TEST_WIN")"
mkdir -p "$TEST_POSIX"
trap 'rm -rf "$TEST_POSIX"' EXIT

# Keep the runner path space-free so WSL's native-process argument bridge is not part
# of this test. The PLUGIN_ROOT used by the command itself deliberately contains spaces.
PLUGIN_COPY="$TEST_POSIX/plugin root with spaces"
mkdir -p "$PLUGIN_COPY"
cp -R "$PLUGIN/scripts" "$PLUGIN_COPY/"
PLUGIN_WIN="$(to_windows "$PLUGIN_COPY")"

PROMPT_COMMAND="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].commandWindows' "$PLUGIN/hooks/codex-hooks.json")"
PRETOOL_COMMAND="$(jq -r '.hooks.PreToolUse[0].hooks[0].commandWindows' "$PLUGIN/hooks/codex-hooks.json")"
LEGACY_PRETOOL_COMMAND="$(jq -r '.hooks.PreToolUse[0].hooks[0].commandWindows' "$PLUGIN/hooks/hooks.json")"
LEGACY_EXPANSION_COMMAND="$(jq -r '.hooks.UserPromptExpansion[0].hooks[0].commandWindows' "$PLUGIN/hooks/hooks.json")"
case "$PROMPT_COMMAND|$PRETOOL_COMMAND" in
  *'%PLUGIN_ROOT%\scripts\forgeward-gate-check.cmd'*prompt-submit*'%PLUGIN_ROOT%\scripts\forgeward-gate-check.cmd'*pretooluse*)
    ok "both Codex handlers declare the tracked Windows wrapper with percent-style root expansion" ;;
  *) nok "Codex commandWindows definitions" "$PROMPT_COMMAND | $PRETOOL_COMMAND" ;;
esac

codex_hook_path="$(jq -r '.hooks' "$PLUGIN/.codex-plugin/plugin.json")"
fresh_events="$(jq -r '.hooks | keys | sort | join(",")' "$PLUGIN/${codex_hook_path#./}")"
if [ "$codex_hook_path" = ./hooks/codex-hooks.json ] \
  && [ "$fresh_events" = PreToolUse,UserPromptSubmit ] \
  && case "$PROMPT_COMMAND|$PRETOOL_COMMAND" in *forgeward-gate-check.cmd*'|'*forgeward-gate-check.cmd*) true;; *) false;; esac; then
  ok "native-Windows fresh install resolves only the intended Codex lifecycle file and adapter"
else
  nok "native-Windows fresh-install routing" "path=$codex_hook_path events=$fresh_events"
fi

case "$LEGACY_EXPANSION_COMMAND|$LEGACY_PRETOOL_COMMAND" in
  *'%PLUGIN_ROOT%\scripts\forgeward-gate-check.cmd'*expansion*'|'*'%PLUGIN_ROOT%\scripts\forgeward-gate-check.cmd'*pretooluse*)
    ok "both legacy Claude hook definitions have native-Windows fallbacks for stale Codex dispatch" ;;
  *) nok "legacy stale-trust Windows fallbacks" "$LEGACY_EXPANSION_COMMAND | $LEGACY_PRETOOL_COMMAND" ;;
esac

tracked_ok=true
hook_paths="$(jq -r '.. | objects | .command? // empty, .commandWindows? // empty' \
  "$PLUGIN/hooks/hooks.json" "$PLUGIN/hooks/codex-hooks.json" \
  | grep -oE 'scripts[\\/][A-Za-z0-9._-]+' | tr '\\' '/' | sort -u)"
for referenced in $hook_paths; do
  git -C "$PLUGIN" ls-files --error-unmatch "$referenced" >/dev/null 2>&1 || tracked_ok=false
done
[ "$(printf '%s\n' "$hook_paths" | grep -c .)" -eq 2 ] && [ "$tracked_ok" = true ] \
  && ok "the Windows wrapper and every script path referenced by committed hook configuration are tracked" \
  || nok "tracked hook paths" "stage/commit the wrapper and referenced scripts"

git_root_from_executable() {
  local git_dir leaf
  git_dir="${1%\\*}"
  leaf="${git_dir##*\\}"
  case "${leaf,,}" in cmd|bin) printf '%s\n' "${git_dir%\\*}" ;; *) return 1 ;; esac
}

# Locate a working standard Git-for-Windows root from git.exe, rather than assuming
# Program Files. A root qualifies by bin/bash.exe plus the Git executable in
# either location exposed by Git for Windows distributions.
STANDARD_ROOT=""
STANDARD_GIT_PATH=""
while IFS= read -r git_win; do
  [ -n "$git_win" ] || continue
  root_win="$(git_root_from_executable "$git_win")" || continue
  root_posix="$(to_posix "$root_win")"
  if [ -f "$root_posix/bin/bash.exe" ] \
    && { [ -f "$root_posix/cmd/git.exe" ] || [ -f "$root_posix/bin/git.exe" ]; }; then
    STANDARD_ROOT="$root_win"
    STANDARD_GIT_PATH="${git_win%\\*}"
    break
  fi
done < <(native_cmd /Q /D /C where git.exe 2>/dev/null | tr -d '\r')

# GitHub's Git Bash can expose POSIX PATH entries that native `where.exe` cannot
# resolve. Derive the same installation root from the Bash running this suite,
# then locate git.exe under that root without assuming a drive or install folder.
if [ -z "$STANDARD_ROOT" ]; then
  current_bash_win="$(to_windows "$(command -v bash)")"
  bash_dir_win="${current_bash_win%\\*}"
  bash_parent_win="${bash_dir_win%\\*}"
  if [ "${bash_parent_win##*\\}" = usr ]; then
    shell_root_win="${bash_parent_win%\\*}"
  else
    shell_root_win="$bash_parent_win"
  fi
  shell_root_posix="$(to_posix "$shell_root_win")"
  if [ -f "$shell_root_posix/bin/bash.exe" ]; then
    for git_subdir in bin cmd; do
      if [ -f "$shell_root_posix/$git_subdir/git.exe" ]; then
        STANDARD_ROOT="$shell_root_win"
        STANDARD_GIT_PATH="$shell_root_win\\$git_subdir"
        break
      fi
    done
  fi
fi

# MSYS exposes its installation root as `/` even when command lookup passes
# through a release-specific internal prefix such as usr/ or mingw64/.
msys_root_win=""
if [ -z "$STANDARD_ROOT" ] && command -v cygpath >/dev/null 2>&1; then
  msys_root_win="$(cygpath -aw /)"
  STANDARD_ROOT="$msys_root_win"
  STANDARD_GIT_PATH="$msys_root_win\\bin"
fi
[ -n "$STANDARD_ROOT" ] || {
  printf 'not ok %d - no standard Git for Windows distribution was found\n' "$((PASS+FAIL+1))"
  printf '  # bash=%s msys-root=%s\n' "${current_bash_win:-unresolved}" "${msys_root_win:-unresolved}"
  exit 1
}
ok "standard Git for Windows layout is available without a hard-coded install root"

# Prefer a real second/custom distribution when one is installed. On a clean CI image,
# expose the same Git-for-Windows distribution through a Laragon-style custom root via
# a directory junction; the wrapper then receives a genuinely unrelated path layout.
CUSTOM_ROOT=""
CUSTOM_GIT_PATH=""
CUSTOM_READY=false
while IFS= read -r git_win; do
  [ -n "$git_win" ] || continue
  root_win="$(git_root_from_executable "$git_win")" || continue
  [ "${root_win,,}" = "${STANDARD_ROOT,,}" ] && continue
  root_posix="$(to_posix "$root_win")"
  if [ -f "$root_posix/bin/bash.exe" ]; then
    CUSTOM_ROOT="$root_win"
    CUSTOM_GIT_PATH="${git_win%\\*}"
    CUSTOM_READY=true
    break
  fi
done < <(native_cmd /Q /D /C where git.exe 2>/dev/null | tr -d '\r')

if [ -z "$CUSTOM_ROOT" ]; then
  CUSTOM_ROOT="$TEST_WIN\\laragon-style\\bin\\git"
  mkdir -p "$TEST_POSIX/laragon-style/bin"
  JUNCTION_RUNNER="$TEST_POSIX/make-junction.cmd"
  printf '@echo off\r\nmklink /J "%s" "%s" >nul\r\n' "$CUSTOM_ROOT" "$STANDARD_ROOT" > "$JUNCTION_RUNNER"
  if (cd "$TEST_POSIX" && native_cmd /Q /D /C "$(to_windows "$JUNCTION_RUNNER")") >/dev/null 2>&1; then
    CUSTOM_READY=true
  fi
  CUSTOM_GIT_PATH="$CUSTOM_ROOT\\bin"
fi
[ "$CUSTOM_READY" = true ] \
  && ok "custom/Laragon-style Git distribution layout is available at an unrelated root" \
  || { nok "custom Git distribution layout" "$CUSTOM_ROOT"; exit 1; }

# Force the reported parser shape: no jq, a python3.exe that is present but cannot run
# Python, and a later python.exe whose stdlib json module works.
PARSER_BIN="$TEST_POSIX/parser-bin"
mkdir -p "$PARSER_BIN"
SYSTEM_ROOT_WIN="${SystemRoot:-${SYSTEMROOT:-${WINDIR:-}}}"
if [ -z "$SYSTEM_ROOT_WIN" ]; then
  SYSTEM_ROOT_WIN="$(native_cmd /Q /D /C set SystemRoot 2>/dev/null | tr -d '\r' \
    | sed -n 's/^[^=]*=\([A-Za-z]:\\.*\)$/\1/p' | tail -n 1)"
fi
[ -n "$SYSTEM_ROOT_WIN" ] || { nok "native SystemRoot prerequisite"; exit 1; }
SYSTEM32_WIN="$SYSTEM_ROOT_WIN\\System32"
cp "$(to_posix "$SYSTEM32_WIN\\where.exe")" "$PARSER_BIN/python3.exe"

PYTHON_EXE=""
while IFS= read -r py_win; do
  [ -n "$py_win" ] || continue
  py_posix="$(to_posix "$py_win")"
  probe="$("$py_posix" -I -c 'import json,sys;sys.stdout.buffer.write(b"ok")' 2>/dev/null)" || continue
  [ "$probe" = ok ] && { PYTHON_EXE="$py_win"; break; }
done < <(native_cmd /Q /D /C where python.exe 2>/dev/null | tr -d '\r')

# GitHub's Git Bash may receive a POSIX PATH that native where.exe cannot parse.
# Fall back to the shell's Python only after proving its JSON runtime works, then
# recover the native executable path that cmd.exe can put back on PATH.
if [ -z "$PYTHON_EXE" ] && command -v python >/dev/null 2>&1; then
  shell_python="$(command -v python)"
  probe="$("$shell_python" -I -c 'import json,sys;sys.stdout.buffer.write(b"ok")' 2>/dev/null)" || probe=""
  if [ "$probe" = ok ]; then
    reported_python="$("$shell_python" -I -c 'import sys;print(sys.executable)' 2>/dev/null)"
    case "$reported_python" in [A-Za-z]:\\*) PYTHON_EXE="$reported_python" ;; *) PYTHON_EXE="$(to_windows "$shell_python")" ;; esac
  fi
fi
[ -n "$PYTHON_EXE" ] || { nok "working python.exe prerequisite"; exit 1; }
PYTHON_DIR="${PYTHON_EXE%\\python.exe}"
PARSER_WIN="$(to_windows "$PARSER_BIN")"

REPO="$TEST_POSIX/repo"
git init -q "$REPO"
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false
printf 'base\n' > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -qm base
git -C "$REPO" branch -M main
git -C "$REPO" checkout -qb feature
printf 'feature\n' >> "$REPO/app.txt"
git -C "$REPO" commit -qam feature
REPO_WIN="$(to_mixed "$REPO")"

write_runner() { # write_runner <file> <git-path-dir> <actual-commandWindows>
  local path_win
  path_win="$2;$PARSER_WIN;$PYTHON_DIR;$SYSTEM32_WIN"
  printf '@echo off\r\nset "PLUGIN_ROOT=%s"\r\nset "PATH=%s"\r\n%s\r\n' \
    "$PLUGIN_WIN" "$path_win" "$3" > "$1"
}
run_windows_hook() { # run_windows_hook <runner> <payload>
  out="$(cd "$TEST_POSIX" && printf '%s' "$2" | native_cmd /Q /D /C "$(to_windows "$1")" 2>&1)"; st=$?
  out="${out//$'\r'/}"
}

# Make the Python fallback non-vacuous before relying on guard output: under the exact
# Git Bash + PATH used by both layouts, jq is absent, python3 fails, and python succeeds.
PROBE_RUNNER="$TEST_POSIX/probe-parser.cmd"
PROBE_SCRIPT="$TEST_POSIX/probe-parser.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'command -v jq >/dev/null 2>&1 && exit 10' \
  'python3 -I -c "import json" >/dev/null 2>&1 && exit 11' \
  'python -I -c "import json" >/dev/null 2>&1 || exit 12' > "$PROBE_SCRIPT"
printf '@echo off\r\nset "PATH=%s;%s;%s;%s"\r\n"%s\\bin\\bash.exe" --noprofile --norc "%s"\r\n' \
  "$STANDARD_GIT_PATH" "$PARSER_WIN" "$PYTHON_DIR" "$SYSTEM32_WIN" "$STANDARD_ROOT" "$(to_windows "$PROBE_SCRIPT")" > "$PROBE_RUNNER"
probe_out="$(cd "$TEST_POSIX" && native_cmd /Q /D /C "$(to_windows "$PROBE_RUNNER")" 2>&1)"; probe_st=$?
[ "$probe_st" -eq 0 ] \
  && ok "python3 present-but-unusable falls through to working python.exe with jq absent" \
  || nok "controlled Python fallback environment" "probe exit=$probe_st out=${probe_out//$'\r'/}"

prompt_allow="$(printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s","prompt":"Explain the gate"}' "$REPO_WIN")"
ship_block="$(printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s","prompt":"$ship"}' "$REPO_WIN")"
pre_allow="$(printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"printf ok"}}' "$REPO_WIN")"
PUBLISH_COMMAND='git pu''sh'
pre_deny="$(printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$REPO_WIN" "$PUBLISH_COMMAND")"

for layout in standard custom; do
  if [ "$layout" = standard ]; then git_path="$STANDARD_GIT_PATH"; else git_path="$CUSTOM_GIT_PATH"; fi
  prompt_runner="$TEST_POSIX/$layout-prompt.cmd"
  pre_runner="$TEST_POSIX/$layout-pretool.cmd"
  legacy_expansion_runner="$TEST_POSIX/$layout-legacy-expansion.cmd"
  legacy_pre_runner="$TEST_POSIX/$layout-legacy-pretool.cmd"
  write_runner "$prompt_runner" "$git_path" "$PROMPT_COMMAND"
  write_runner "$pre_runner" "$git_path" "$PRETOOL_COMMAND"
  write_runner "$legacy_expansion_runner" "$git_path" "$LEGACY_EXPANSION_COMMAND"
  write_runner "$legacy_pre_runner" "$git_path" "$LEGACY_PRETOOL_COMMAND"

  run_windows_hook "$prompt_runner" "$prompt_allow"
  [ "$st" -eq 0 ] && [ -z "$out" ] \
    && ok "$layout layout: unrelated UserPromptSubmit exits 0 without output" \
    || nok "$layout unrelated prompt" "st=$st out=$out"

  run_windows_hook "$pre_runner" "$pre_allow"
  [ "$st" -eq 0 ] && [ -z "$out" ] \
    && ok "$layout layout: ordinary non-publish Bash exits 0 without output" \
    || nok "$layout ordinary Bash" "st=$st out=$out"

  run_windows_hook "$legacy_pre_runner" "$pre_allow"
  if [ "$st" -eq 0 ] && [ -z "$out" ]; then
    ok "$layout layout: stale-trust dispatch allows ordinary Bash without an error"
  else
    nok "$layout stale-trust ordinary Bash" "st=$st out=$out"
  fi

  run_windows_hook "$prompt_runner" "$ship_block"
  if [ "$st" -eq 0 ] && [ "$(printf '%s' "$out" | jq -r '.decision' 2>/dev/null)" = block ] \
    && [ -n "$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null)" ]; then
    ok "$layout layout: direct \$ship without a marker returns valid block JSON"
  else
    nok "$layout direct ship guard" "st=$st out=$out"
  fi

  run_windows_hook "$legacy_expansion_runner" "$ship_block"
  if [ "$st" -eq 2 ] && printf '%s' "$out" | grep -Fq 'forgeward gate: /ship halted'; then
    ok "$layout layout: stale-trust expansion preserves the Claude /ship block decision"
  else
    nok "$layout stale-trust expansion guard" "st=$st out=$out"
  fi

  run_windows_hook "$pre_runner" "$pre_deny"
  if [ "$st" -eq 0 ] \
    && [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" = PreToolUse ] \
    && [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ] \
    && [ -n "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)" ]; then
    ok "$layout layout: ungated publish returns valid PreToolUse deny JSON"
  else
    nok "$layout publish guard" "st=$st out=$out"
  fi

  run_windows_hook "$legacy_pre_runner" "$pre_deny"
  if [ "$st" -eq 0 ] \
    && [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" = PreToolUse ] \
    && [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ]; then
    ok "$layout layout: stale-trust dispatch preserves the publish decision"
  else
    nok "$layout stale-trust publish guard" "st=$st out=$out"
  fi
done

# With no git.exe on PATH, System32's WSL launcher may still expose bare bash.exe. The
# adapter must ignore it, emit no claim that the guard ran, and fail open for both events.
NO_GIT_PROMPT="$TEST_POSIX/no-git-prompt.cmd"
NO_GIT_PRE="$TEST_POSIX/no-git-pretool.cmd"
NO_GIT_LEGACY_EXPANSION="$TEST_POSIX/no-git-legacy-expansion.cmd"
NO_GIT_LEGACY_PRE="$TEST_POSIX/no-git-legacy-pretool.cmd"
printf '@echo off\r\nset "PLUGIN_ROOT=%s"\r\nset "PATH=%s"\r\n%s\r\n' "$PLUGIN_WIN" "$SYSTEM32_WIN" "$PROMPT_COMMAND" > "$NO_GIT_PROMPT"
printf '@echo off\r\nset "PLUGIN_ROOT=%s"\r\nset "PATH=%s"\r\n%s\r\n' "$PLUGIN_WIN" "$SYSTEM32_WIN" "$PRETOOL_COMMAND" > "$NO_GIT_PRE"
printf '@echo off\r\nset "PLUGIN_ROOT=%s"\r\nset "PATH=%s"\r\n%s\r\n' "$PLUGIN_WIN" "$SYSTEM32_WIN" "$LEGACY_EXPANSION_COMMAND" > "$NO_GIT_LEGACY_EXPANSION"
printf '@echo off\r\nset "PLUGIN_ROOT=%s"\r\nset "PATH=%s"\r\n%s\r\n' "$PLUGIN_WIN" "$SYSTEM32_WIN" "$LEGACY_PRETOOL_COMMAND" > "$NO_GIT_LEGACY_PRE"
run_windows_hook "$NO_GIT_PROMPT" "$ship_block"; no_git_prompt="$st|$out"
run_windows_hook "$NO_GIT_PRE" "$pre_deny"; no_git_pre="$st|$out"
run_windows_hook "$NO_GIT_LEGACY_EXPANSION" "$ship_block"; no_git_legacy_expansion="$st|$out"
run_windows_hook "$NO_GIT_LEGACY_PRE" "$pre_deny"; no_git_legacy_pre="$st|$out"
if [ "$no_git_prompt" = "0|" ] && [ "$no_git_pre" = "0|" ] \
  && [ "$no_git_legacy_expansion" = "0|" ] && [ "$no_git_legacy_pre" = "0|" ]; then
  ok "Codex and stale-trust routes fail open silently instead of using WSL bash"
else
  nok "no-Git-Bash fail-open contract" "prompt=$no_git_prompt pretool=$no_git_pre legacy-expansion=$no_git_legacy_expansion legacy-pretool=$no_git_legacy_pre"
fi

printf '1..%d\n' "$((PASS+FAIL))"
if [ "$FAIL" -ne 0 ]; then exit 1; fi
