#!/usr/bin/env bash
# forgeward-diff-hash.sh <base-ref> [tip]
#
# Stable sha256 over the REVIEWED STATE of <tip> vs <base-ref>. <tip> defaults to
# HEAD (unchanged from the single-checkout behavior); the PreToolUse hook passes
# the branch actually being pushed so the hash is recomputed against THAT ref, not
# whatever the hook's cwd happens to have checked out — which is what makes the
# gate worktree-safe (a push evaluated from a different checkout still hashes the
# right branch). The marker stores this; the PreToolUse hook recomputes it at push
# time. Contract:
#   - MUST change when reviewable code OR DEPENDENCIES change  -> forces re-gate
#   - MUST NOT change for gstack's cosmetic post-gate bookkeeping (version bump,
#     changelog, todos) -> otherwise /ship Step 12-14 writes block the happy path
#
# Excluded (cosmetic, no reviewable content): VERSION, CHANGELOG*, TODOS.md.
#
# VERSION-BEARING MANIFESTS are not excluded either — they are hashed as canonical
# snapshots with ONLY the version field neutralized, so a pure version bump is
# invisible while ANY other change to the same file still flips the hash. Three are
# handled, because a Claude Code plugin carries its version in three places and a
# release bumps all of them together:
#
#   package.json                      .version              (mode: top)
#   .claude-plugin/plugin.json        .version              (mode: top)
#   .claude-plugin/marketplace.json   .plugins[].version    (mode: plugins)
#
# gstack's version bump (bin/gstack-version-bump writePkgVersion) sets ONLY
# .version then re-serializes the whole file, which is why the canonical snapshot
# works. Lockfiles + source stay fully hashed, so a typosquatted/hallucinated
# dependency added between gate and push re-gates.
#
# Before this, only package.json was neutralized, so every release of a PLUGIN
# repo flipped the hash on the other two manifests and forced a spurious re-gate —
# the "cosmetic bookkeeping stays invisible" contract at line 12 held for ordinary
# repos but not for a plugin, i.e. not for this repo itself.
#
# NEUTRALIZATION IS TARGETED, NEVER RECURSIVE. Blanking every key named "version"
# anywhere in the document would be one expression instead of two, and would be a
# real loosening: npm `overrides` / `resolutions` / pnpm entries can nest a
# `{"version": "..."}` object, so a recursive blank could hide a dependency PIN
# change. Each manifest names the exact path its version lives at.
#
# The extra sections are APPENDED ONLY WHEN THE FILE EXISTS, so a repo with no
# .claude-plugin/ hashes byte-identically to before this change. Existing markers
# in ordinary repos stay fresh; only plugin repos take a one-time re-gate.
#
# Fail-safe, per manifest: if it is missing/unparseable or no JSON tool (jq/python3)
# is available, hash the raw blob -> a version bump then DOES re-gate (errs
# toward safe re-gating, never toward silently excluding a dependency change).
set -uo pipefail
base="${1:?usage: forgeward-diff-hash.sh <base-ref> [tip]}"
tip="${2:-HEAD}"

# Canonicalize a manifest: neutralize ONLY the version field the mode names, sort
# keys. jq preferred; python3 fallback; raw passthrough if neither (safe = re-gates).
#   top     -> .version            (package.json, plugin.json)
#   plugins -> .plugins[].version  (marketplace.json)
# python3 writes with sys.stdout.buffer, never print(): print() translates \n to
# \r\n on Windows, which silently changes the bytes being hashed.
normalize_manifest() { # normalize_manifest <mode>   (json on stdin)
  if command -v jq >/dev/null 2>&1; then
    case "$1" in
      top)     jq -S '.version = "<<forgeward-gated>>"' 2>/dev/null ;;
      plugins) jq -S 'if (.plugins|type) == "array"
                      then .plugins |= map(if type == "object"
                                           then .version = "<<forgeward-gated>>"
                                           else . end)
                      else . end' 2>/dev/null ;;
      *)       cat ;;
    esac
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys
try:
    mode=sys.argv[1]; d=json.load(sys.stdin)
    if mode=="top":
        d["version"]="<<forgeward-gated>>"
    elif mode=="plugins":
        ps=d.get("plugins")
        if isinstance(ps,list):
            for p in ps:
                if isinstance(p,dict): p["version"]="<<forgeward-gated>>"
    sys.stdout.buffer.write(json.dumps(d,sort_keys=True,separators=(",",":")).encode())
except Exception:
    sys.exit(1)' "$1"
  else
    cat
  fi
}

# Canonical snapshot of one manifest at <tip>. Empty when the path does not exist
# there, which is what keeps the payload byte-identical for repos without it.
snapshot_manifest() { # snapshot_manifest <path> <mode>
  local raw out
  git cat-file -e "${tip}:${1}" 2>/dev/null || return 0
  raw="$(git show "${tip}:${1}" 2>/dev/null)"
  out="$(printf '%s' "$raw" | normalize_manifest "$2" 2>/dev/null)" || out=""
  [ -z "$out" ] && out="$raw"   # parse failed -> raw -> version bump re-gates
  printf '%s' "$out"
}

# Part 1 — diff of everything reviewable except the version-bearing manifests and
# the cosmetic bookkeeping files. These pathspecs have no wildcard, so they match
# those exact paths only: lockfiles, source, and a NESTED package.json all stay in.
diff_part="$(git diff "${base}...${tip}" -- . \
  ':(exclude)VERSION' \
  ':(exclude)CHANGELOG.md' \
  ':(exclude)CHANGELOG' \
  ':(exclude)TODOS.md' \
  ':(exclude)package.json' \
  ':(exclude).claude-plugin/plugin.json' \
  ':(exclude).claude-plugin/marketplace.json' \
  2>/dev/null)"

# Part 2 — canonical snapshots at <tip>, version neutralized per manifest.
pkg_part="$(snapshot_manifest package.json top)"
plugin_part="$(snapshot_manifest .claude-plugin/plugin.json top)"
market_part="$(snapshot_manifest .claude-plugin/marketplace.json plugins)"

# Assembled so that a repo with neither plugin manifest produces the EXACT bytes
# this script produced before they were handled — same sections, same separators,
# same trailing newline — so its markers do not all go stale on upgrade.
payload="${diff_part}"$'\n''--FORGEWARD-PKG--'$'\n'"${pkg_part}"
[ -n "$plugin_part" ] && payload="${payload}"$'\n''--FORGEWARD-PLUGIN--'$'\n'"${plugin_part}"
[ -n "$market_part" ] && payload="${payload}"$'\n''--FORGEWARD-MARKET--'$'\n'"${market_part}"

printf '%s\n' "$payload" | sha256sum | awk '{print $1}'
