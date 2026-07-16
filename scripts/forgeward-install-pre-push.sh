#!/usr/bin/env bash
# forgeward-install-pre-push.sh [repo-path]
#
# Turn on forgeward's pre-push enforcement for a repo:
#   1. mark the repo opted-in            (git config forgeward.gate enabled)
#   2. install a pre-push hook into the repo's EFFECTIVE hooks dir — the one git
#      actually uses, i.e. honoring core.hooksPath. If core.hooksPath points at a
#      shared/global dir, the hook lives there and runs for every repo, but the
#      enforcer is opt-in (step 1) so it is a NO-OP everywhere except repos that ran
#      this installer. That is why the opt-in exists.
#
# Idempotent. Refuses to clobber a foreign pre-push — prints how to chain instead.
set -euo pipefail
repo="${1:-$(pwd)}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
enforcer="$here/forgeward-pre-push.sh"
marker_line="# forgeward-pre-push enforcement"

[ -x "$enforcer" ] || { echo "error: enforcer not found/executable: $enforcer" >&2; exit 1; }
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not a git repo: $repo" >&2; exit 1; }

# resolve the EFFECTIVE pre-push path (respects core.hooksPath)
hook="$(git -C "$repo" rev-parse --path-format=absolute --git-path hooks/pre-push 2>/dev/null || true)"
if [ -z "$hook" ]; then
  hook="$(git -C "$repo" rev-parse --git-path hooks/pre-push)"
  case "$hook" in /*) ;; *) hook="$(cd "$repo" && cd "$(dirname "$hook")" && pwd)/pre-push" ;; esac
fi
mkdir -p "$(dirname "$hook")"

hooks_path_cfg="$(git -C "$repo" config --get core.hooksPath || true)"

if [ -e "$hook" ] && ! grep -qF "$marker_line" "$hook" 2>/dev/null; then
  echo "A pre-push hook already exists and is not forgeward's:" >&2
  echo "  $hook" >&2
  echo "Left it untouched (opt-in is set). To chain forgeward, add inside that hook:" >&2
  echo "  \"$enforcer\" \"\$@\" || exit 1" >&2
  exit 1
fi

cat > "$hook" <<HOOK
#!/usr/bin/env bash
$marker_line — gates every pushed ref against its /forgeward:gate marker.
# Enforces only in repos with 'git config forgeward.gate enabled'. Bypass: --no-verify
exec "$enforcer" "\$@"
HOOK
chmod +x "$hook"

# Opt in only AFTER the hook is in place, so a refused/failed install never leaves a
# repo flagged as gated without a working hook.
git -C "$repo" config forgeward.gate enabled

echo "forgeward: pre-push enforcement enabled for this repo."
echo "  opt-in:   git config forgeward.gate = enabled  (in $repo)"
echo "  hook:     $hook"
echo "  enforcer: $enforcer"
if [ -n "$hooks_path_cfg" ]; then
  echo "  NOTE: core.hooksPath is set ($hooks_path_cfg), so this hook is SHARED across"
  echo "        your repos — but it enforces ONLY where forgeward.gate is enabled, so"
  echo "        other repos are unaffected."
fi
echo
echo "  Honest limits — strong, not indestructible:"
echo "    - 'git push --no-verify' skips it (a deliberate, visible opt-out)."
echo "    - the marker is a local file; it can be forged by anyone with repo access."
echo "    - git hooks are not cloned; re-run this installer in a fresh clone, and after"
echo "      a forgeward plugin update (the enforcer path is baked into the hook above)."
echo "  For an unbypassable boundary, gate the MERGE server-side with /forgeward:ci-gate."
