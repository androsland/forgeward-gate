#!/usr/bin/env bash
# forgeward gate — live-install test scaffold.
#
# Builds a CLEAN throwaway repo + bare remote with a single PII-logging change
# (privacy FAIL surface; no UI / LLM / public-page / dependency surface, so you
# can watch the other reviewers self-skip). Installs NO git hooks — so when a
# push is blocked during the live test, it can ONLY be Claude Code's plugin
# PreToolUse hook, never a residual shim.
#
# Usage:  bash setup.sh [target-dir]   (default: ./forgeward-live-test)
set -euo pipefail
TARGET="${1:-$PWD/forgeward-live-test}"

if [ -e "$TARGET" ]; then
  echo "Refusing to overwrite existing path: $TARGET" >&2
  echo "Remove it yourself or pass a different target dir." >&2
  exit 1
fi

mkdir -p "$TARGET"
git init -q --bare "$TARGET/remote.git"
git init -q "$TARGET/app"
cd "$TARGET/app"
git config user.email you@example.com
git config user.name "You"
git config commit.gpgsign false
git remote add origin ../remote.git

# baseline on main
cat > package.json <<'JSON'
{ "name": "live-test-app", "version": "1.0.0", "private": true,
  "dependencies": { "express": "^4.19.2" } }
JSON
cat > server.js <<'JS'
const express = require("express");
const app = express();
app.get("/health", (req, res) => res.json({ ok: true }));
module.exports = app;
JS
git add -A; git commit -qm "init: baseline" >/dev/null
git branch -M main
git push -q origin main

# feature branch: signup route that LOGS PII (privacy FAIL; nothing else fires)
git checkout -q -b feature/signup
cat > signup.js <<'JS'
const app = require("./server");
app.post("/signup", (req, res) => {
  const { email, phone, password, ssn } = req.body;
  console.log("NEW SIGNUP", { email, phone, password, ssn }); // logs PII + plaintext password + SSN
  res.json({ ok: true });
});
JS
git add -A; git commit -qm "feat: add signup route" >/dev/null

echo
echo "=== scaffold ready at: $TARGET/app ==="
echo "branch        : $(git rev-parse --abbrev-ref HEAD)"
echo "diff vs main  : $(git diff --name-only main...HEAD | tr '\n' ' ')"
echo "marker present: $([ -f .git/forgeward-gate-marker.json ] && echo yes || echo NO)"
echo
echo "--- CRITICAL: confirm there is NO git push hook (a block must be the PLUGIN, not a shim) ---"
if [ -f .git/hooks/pre-push ]; then
  echo "!! .git/hooks/pre-push EXISTS — remove it, or a block could be the shim, not the plugin."
else
  echo "OK: no .git/hooks/pre-push present."
fi
echo "active (non-sample) hooks in .git/hooks/:"
( ls .git/hooks/ 2>/dev/null | grep -v '\.sample$' || true ) | sed 's/^/    /' ; \
  [ -z "$(ls .git/hooks/ 2>/dev/null | grep -v '\.sample$')" ] && echo "    (none — good)"
echo
echo "Next: open Claude Code in $TARGET/app and follow live-test/LIVE-TEST.md"
