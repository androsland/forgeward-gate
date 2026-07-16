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
# package.json is NOT excluded. gstack's version bump (bin/gstack-version-bump
# writePkgVersion) sets ONLY .version then re-serializes the whole file. We hash
# a canonical snapshot with the version field neutralized and keys sorted, so a
# pure version bump is invisible but ANY dependency / script / other change flips
# the hash. Lockfiles + source stay fully hashed, so a typosquatted/hallucinated
# dependency added between gate and push re-gates.
#
# Fail-safe: if package.json is missing/unparseable or no JSON tool (jq/python3)
# is available, hash the raw blob -> a version bump then DOES re-gate (errs
# toward safe re-gating, never toward silently excluding a dependency change).
set -uo pipefail
base="${1:?usage: forgeward-diff-hash.sh <base-ref> [tip]}"
tip="${2:-HEAD}"

# Canonicalize package.json: neutralize ONLY the version field, sort keys.
# jq preferred; python3 fallback; raw passthrough if neither (safe = re-gates).
normalize_pkg() {
  if command -v jq >/dev/null 2>&1; then
    jq -S '.version = "<<forgeward-gated>>"' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); d["version"]="<<forgeward-gated>>"
    sys.stdout.write(json.dumps(d,sort_keys=True,separators=(",",":")))
except Exception:
    sys.exit(1)'
  else
    cat
  fi
}

# Part 1 — diff of everything reviewable except root package.json and the
# cosmetic bookkeeping files. Lockfiles, source, nested package.json included.
diff_part="$(git diff "${base}...${tip}" -- . \
  ':(exclude)VERSION' \
  ':(exclude)CHANGELOG.md' \
  ':(exclude)CHANGELOG' \
  ':(exclude)TODOS.md' \
  ':(exclude)package.json' \
  2>/dev/null)"

# Part 2 — canonical snapshot of root package.json at <tip>, version neutralized.
pkg_part=""
if git cat-file -e "${tip}:package.json" 2>/dev/null; then
  raw="$(git show "${tip}:package.json" 2>/dev/null)"
  pkg_part="$(printf '%s' "$raw" | normalize_pkg 2>/dev/null)" || pkg_part=""
  [ -z "$pkg_part" ] && pkg_part="$raw"   # parse failed -> raw -> version bump re-gates
fi

printf '%s\n--FORGEWARD-PKG--\n%s\n' "$diff_part" "$pkg_part" | sha256sum | awk '{print $1}'
