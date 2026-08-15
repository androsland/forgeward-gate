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
# .claude-plugin/ produces the same SECTION LAYOUT it always did. That layout is
# still asserted (V4), but it no longer implies marker survival: the jq/python
# alignment below rewrites the canonical bytes INSIDE the sections, so every repo
# takes a one-time re-gate at this version, not just plugin repos.
#
# Fail-safe, per manifest: if it is missing/unparseable or no JSON tool (jq/python3)
# is available, hash the raw blob -> a version bump then DOES re-gate (errs
# toward safe re-gating, never toward silently excluding a dependency change).
set -uo pipefail

# Locale-pinned repo-wide, not per-effect — see CLAUDE.md. A non-interactive script
# must not have its behaviour depend on the invoker's environment: character classes,
# collation and grep's handling of invalid UTF-8 all move with the locale, and the
# last one was a complete bypass of an ambiguity guard before it was pinned.
export LC_ALL=C
base="${1:?usage: forgeward-diff-hash.sh <base-ref> [tip]}"
tip="${2:-HEAD}"

# Canonicalize a manifest: neutralize ONLY the version field the mode names, sort
# keys. jq preferred; python3 fallback; raw passthrough if neither (safe = re-gates).
#   top     -> .version            (package.json, plugin.json)
#   plugins -> .plugins[].version  (marketplace.json)
# python3 writes with sys.stdout.buffer, never print(): print() translates \n to
# \r\n on Windows, which silently changes the bytes being hashed.
#
# THE TWO BRANCHES MUST EMIT THE SAME BYTES, not merely the same semantics. They did
# not: `jq -S` pretty-prints (2-space indent, newlines) while json.dumps here uses
# compact separators, so the canonical snapshot of the SAME manifest differed between
# a machine with jq and one without. A marker written on one read as stale on the
# other and forced a spurious re-gate — fail-safe, never a false PASS, but wrong, and
# invisible until someone moved between machines. `-c` matches the compact separators
# and `-a` matches json.dumps' default ensure_ascii=True; without `-a`, jq emits raw
# UTF-8 where python emits \uXXXX, so a manifest with one accented character diverges.
#
# BLIND SPOT — number literals still diverge, and this is not fixable here. jq
# preserves a number's source text (`1.10` stays `1.10`, `1e10` prints as `1E+10`)
# while python normalizes through float (`1.1`, `10000000000.0`, and `1e-7` -> `1e-07`).
# Python cannot be made to match: json.dumps calls float.__repr__ DIRECTLY, so a float
# subclass carrying the raw text is ignored, and parse_int would turn `5` into `5.0`.
# Verified by fuzzing both branches over the shapes above, not reasoned about. The
# residue is confined to a manifest carrying a float in scientific notation or with a
# trailing zero; npm/plugin manifests carry versions as STRINGS, so in practice this is
# unreachable. Fail direction is unchanged (spurious re-gate, never a false PASS).
# Pinned by V8 so a future jq or python that closes it fails the suite instead of
# quietly outdating this paragraph.
#
# ONE-TIME COST, accepted deliberately: aligning the two changes the canonical bytes,
# so every marker written before this version reads as stale exactly once, in every
# repo — not just plugin repos. That is why this is its own release and not folded in
# with anything else. V4 asserts the CURRENT bytes; it no longer claims markers survive.
normalize_manifest() { # normalize_manifest <mode>   (json on stdin)
  if command -v jq >/dev/null 2>&1; then
    case "$1" in
      top)     jq -S -c -a '.version = "<<forgeward-gated>>"' 2>/dev/null ;;
      plugins) jq -S -c -a 'if (.plugins|type) == "array"
                      then .plugins |= map(if type == "object"
                                           then .version = "<<forgeward-gated>>"
                                           else . end)
                      else . end' 2>/dev/null ;;
      *)       cat ;;
    esac
  elif command -v python3 >/dev/null 2>&1; then
    python3 -I -c 'import json,sys
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
