# forgeward gate — live-install verification kit

This is the test the automated proof could **not** run: confirming Claude Code actually
loads the plugin and **dispatches the real PreToolUse hook** on a real `git push`. The
earlier proof bridged the decision logic through a git `pre-push` shim; this kit removes
that shim entirely so a block can only come from the plugin.

Do not treat the plugin as verified end-to-end until you have run this yourself.

---

## 0. Avoid the false positive (READ FIRST)

The automated proof left a repo at `pstack/demo-app/` that has a git `pre-push` **shim**
in `.git/hooks/pre-push`. **Do not test there** — a block in that repo could be the shim,
not the plugin. Always use a fresh repo from `setup.sh` (step 2), which installs no hooks
and prints a check confirming `.git/hooks/` is clean.

Prereqs: Claude Code v2.1.x+, and `jq` **or** `python3` on PATH (`command -v jq python3`).
If both are missing the hook fails open (allows) by design.

---

## 1. Install the plugin

> **`<PLUGIN_DIR>` below = the absolute path to your clone of this repo** (the directory
> containing `.claude-plugin/`). Replace every `<PLUGIN_DIR>` with that path, e.g.
> `export PLUGIN_DIR="$(pwd)"` from the repo root, then paste `$PLUGIN_DIR` into the commands.

**Validate first:**
```bash
claude plugin validate <PLUGIN_DIR> --strict
```
Expect: no errors (warnings about unrecognized fields are fine).

**Option A — session-scoped (simplest, recommended for this test):** launch Claude Code
with the plugin loaded for the session:
```bash
claude --plugin-dir <PLUGIN_DIR>
```

**Option B — persistent (skills-dir install):** copy the plugin under your skills dir, then
restart Claude Code:
```bash
cp -R <PLUGIN_DIR> ~/.claude/skills/forgeward-gate
# next session it loads as forgeward@skills-dir
```

**Verify it actually loaded (all four):**
- `/plugin` → `forgeward` is enabled and its detail view lists 5 agents, the `gate` skill, and hooks.
- `claude plugin list` → shows `forgeward`.
- `claude plugin details forgeward` → lists a **PreToolUse / Bash** hook and a **UserPromptExpansion / ship** hook.
- Type `/forgeward:gate` → it autocompletes.

If you changed plugin files mid-session, run `/reload-plugins` (hooks don't hot-reload otherwise).

---

## 2. Scaffold a clean test repo (no shim)

```bash
bash <PLUGIN_DIR>/live-test/setup.sh ~/forgeward-live-test
```
Expect the tail to say `OK: no .git/hooks/pre-push present.` and `active (non-sample) hooks: (none — good)`.

Then open Claude Code **in that repo** (carry the `--plugin-dir` flag if you used Option A):
```bash
cd ~/forgeward-live-test/app
claude --plugin-dir <PLUGIN_DIR>
```

---

## 3. Test A — the gate blocks a real push (no gstack required)

The PreToolUse hook matches the `git push` Bash call regardless of who issues it, so this
isolates plugin-hook dispatch from gstack.

### 3a. Reviewer fires conditionally, others self-skip
Tell Claude: **"run /forgeward:gate"**.

Expected:
- It scopes the diff (`signup.js` only) and prints a firing decision like:
  `Surfaces: personal-data=yes, UI=no, llm=no, public-pages=no, deps=no → firing: privacy`
- It spawns **only** `forgeward:privacy-reviewer`. The accessibility / ai-output / seo /
  supply-chain reviewers are **not fired** (or, if fired, self-skip with an immediate PASS).
- privacy-reviewer returns Critical findings (plaintext password + SSN in logs) and ends
  `PRIVACY VERDICT: FAIL`.
- The gate prints the findings, writes **no marker**, and stops. It does **not** invoke /ship.

**Result**
```
❯ run /forgeward:gate

● Skill(forgeward:gate)
Successfully loaded skill · 6 tools allowed
Allowed by auto mode classifier

I'll run the forgeward conformance gate. Let me start by detecting the base branch and scoping the diff.

  Ran 2 shell commands

Base branch is main. Now scoping the diff.

  Ran 1 shell command

Surfaces: personal-data=yes (email, phone, password, ssn collected + logged), UI=no, llm=no, public-pages=no, deps=no → firing: privacy

Skipping accessibility (no UI/components), ai-output (no LLM calls), seo (no public pages), supply-chain (no dependency manifest).

Firing the privacy reviewer (read-only) on main...HEAD.

● forgeward:privacy-reviewer(Privacy review of diff)
Backgrounded agent (↓ to manage · ctrl+o to expand)
Allowed by auto mode classifier

The privacy reviewer is running in the background. I'll wait for its verdict before deciding.

✻ Waiting for 1 background agent to finish

● Agent "Privacy review of diff" came to rest · 35s

The privacy reviewer returned FAIL. Per the gate rules, no marker is written and nothing ships. Here are the Critical/High findings to fix:

forgeward gate: FAIL

Fired: privacy · Skipped: accessibility (no UI), ai-output (no LLM calls), seo (no public pages), supply-chain (no dependency manifest)

Privacy — Critical/High findings

┌─────┬──────────┬───────────────┬────────────────────────────────────────────────────────────────────────────────────┬───────────────────────────────────────────────────────────────────┐
│  #  │ Severity │   Location    │                                       Issue                                        │                                Fix                                │
├─────┼──────────┼───────────────┼────────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────┤
│ 1   │ Critical │ signup.js:4   │ password logged in plaintext via console.log — credential exposure to any log sink │ Remove password from the log call entirely. Never log             │
│     │          │               │  (stdout, aggregators, archives). Violates SOC 2 / PCI-DSS / GDPR Art. 32.         │ credentials.                                                      │
├─────┼──────────┼───────────────┼────────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────┤
│     │          │               │ ssn logged in plaintext — special-category US government identifier (GLBA, state   │ Remove ssn from the log call. Flag SSN collection for legal       │
│ 2   │ Critical │ signup.js:4   │ breach statutes; GDPR). Immediate data-breach risk.                                │ review (lawful basis, encryption-at-rest, retention, breach       │
│     │          │               │                                                                                    │ obligations).                                                     │
├─────┼──────────┼───────────────┼────────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────┤
│     │          │               │ email and phone (direct identifiers) logged on every signup → flow into log infra  │ Remove from the log call. If an audit trail is needed, log a hash │
│ 3   │ High     │ signup.js:4   │ indefinitely. Purpose-limitation / data-minimisation failure (GDPR Art.            │  or the post-creation user ID — never raw values.                 │
│     │          │               │ 5(1)(b),(c)).                                                                      │                                                                   │
├─────┼──────────┼───────────────┼────────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────┤
│     │          │               │ Route collects email/phone/password/ssn but does no hashing, encryption,           │ Before shipping: hash passwords (bcrypt/argon2), encrypt SSN at   │
│ 4   │ High     │ signup.js:3-5 │ validation, or persistence story — no retention or erasure path (GDPR Art. 17 /    │ rest, document retention, provide an erasure path.                │
│     │          │               │ CCPA gap).                                                                         │                                                                   │
└─────┴──────────┴───────────────┴────────────────────────────────────────────────────────────────────────────────────┴───────────────────────────────────────────────────────────────────┘

The single console.log on line 4 is the root cause of both Criticals and Finding 3. (Medium finding: reconsider whether SSN is needed at signup at all — over-collection risk.)

---
forgeward gate: FAIL — fix the Critical/High findings above and re-run /forgeward:gate. Nothing was shipped.
```

### 3b. The real push is DENIED by the plugin hook
Tell Claude: **"push this branch to origin"** (or run `git push -u origin feature/signup` yourself via Claude).

Expected — **this is the plugin deny, and here is how to tell it apart from a generic git error:**
- The `git push` tool call is **blocked before it runs**. Claude reports it was denied with the
  reason: **`forgeward gate not passed for HEAD <sha>. This publish ... has not returned VERDICT: PASS ... Run /forgeward:gate`.**
- That exact `forgeward gate not passed` wording comes from the plugin's
  `permissionDecisionReason`. **A generic git failure looks different** — it would *run* and
  print `error: failed to push some refs` with no "forgeward" text. If you see the forgeward
  sentence, the **plugin hook** fired.

**Result**
```
❯ push this branch to origin

I'll push this branch to origin.

  Ran 1 shell command

The push is blocked by the forgeward gate hook. I need to run the gate first, which reviews the diff and ships on all-PASS.

● Skill(forgeward:gate)
Successfully loaded skill · 6 tools allowed
Allowed by auto mode classifier

I'll run the forgeward gate. Let me start by detecting the base branch and scoping the diff.

  Ran 2 shell commands

Base detection returned empty (likely no GitHub remote configured). The diff vs main shows one file: signup.js. Let me confirm the base and see the diff.

  Ran 1 shell command

Base is main. The diff adds signup.js — a server-side signup route that collects and logs personal data (email, phone, password, SSN).

Surfaces: personal-data=yes, UI=no, llm=no, public-pages=no, deps=no → firing: privacy

Firing the privacy reviewer.

● forgeward:privacy-reviewer(Privacy review of signup diff)
Backgrounded agent (↓ to manage · ctrl+o to expand)
Allowed by auto mode classifier

I've launched the privacy reviewer in the background. Waiting for its verdict before deciding whether to write the pass marker and ship.

I'll wait for the privacy reviewer to complete and then decide.

✻ Waiting for 1 background agent to finish

● Agent "Privacy review of signup diff" came to rest · 28s

The privacy reviewer returned VERDICT: FAIL. No marker is written and nothing ships. Here are the Critical/High findings you need to fix:

forgeward gate: FAIL — privacy

Critical
- signup.js:4 — Plaintext password logged to console. Logged credentials flow into log aggregators in cleartext, an immediate credential-theft risk. Fix: remove password from the log entirely; never log it at any level.
- signup.js:4 — SSN logged in plaintext. SSNs are special-category data; logging them is incompatible with CCPA/GLBA/breach-notification laws. Fix: remove ssn from the log immediately, and get legal sign-off before collecting it at all.

High
- signup.js:4 — Email and phone logged. Direct personal identifiers flowing into log infrastructure = unnecessary PII exposure. Fix: drop email and phone from the log; if a signup event log is needed, log only a generated non-PII user ID.
- signup.js:3-5 — SSN collected with no lawful basis, encryption, or deletion path. Fix: document legal basis + purpose, encrypt at rest, add a deletion/export path, and get legal sign-off — or drop the field (data minimization).

There were also Medium findings (password not hashed on receipt; no retention/deletion story for collected fields).

---
The most important fix is line 4 — that single console.log("NEW SIGNUP", { email, phone, password, ssn }) leaks a password and SSN in cleartext.

Fix the Critical/High findings, then re-run /forgeward:gate. Nothing was pushed. I'm read-only in the gate, so I won't edit signup.js myself — but say the word and I'll make the changes (outside the gate), after which you can re-run the gate to ship.
```
---

## 4. Fix → PASS → push ALLOWED

Replace `signup.js` with a privacy-clean version (no PII in logs, password hashed with a
**stored** salt, SSN dropped) — or just tell Claude to fix the privacy findings. A known-good
version:

```js
const crypto = require("crypto");
const app = require("./server");
app.post("/signup", (req, res) => {
  const { email, password } = req.body;
  const salt = crypto.randomBytes(16).toString("hex");
  const hash = crypto.scryptSync(password, salt, 64).toString("hex");
  const passwordHash = `${salt}:${hash}`; // salt stored with hash
  console.log("NEW SIGNUP", { correlationId: crypto.randomUUID() }); // no PII
  void passwordHash; void email;
  res.json({ ok: true });
});
```
Commit it, then run **`/forgeward:gate`** again.

Expected:
- privacy-reviewer now ends `PRIVACY VERDICT: PASS`; the other surfaces still self-skip.
- The gate writes the marker and hands off to `/ship` (or, with no gstack, tells you it would).
- Verify the marker and that the push now goes through:
  ```bash
  cat .git/forgeward-gate-marker.json          # shows passed:true, base, diff_hash
  ```
  Ask Claude to push → it now **succeeds**; `git ls-remote --heads origin` shows `feature/signup`.

**Result A**

Fixed file manually with suggested code above
```
❯ /forgeward:gate

I'll run forgeward's gate. Let me start by detecting the base branch and scoping the diff.

  Ran 3 shell commands

Base is main. Now scoping the diff.

  Ran 2 shell commands

Surfaces: personal-data=yes (email/password in signup route), UI=no (backend .js route, no markup), llm=no, public-pages=no, deps=no (no manifest changed) → firing: privacy

Firing the privacy reviewer (read-only) on the main...HEAD diff.

● forgeward:privacy-reviewer(Privacy review of signup diff)
Backgrounded agent (↓ to manage · ctrl+o to expand)
Allowed by auto mode classifier

I've launched the privacy-reviewer (the only reviewer whose surface this diff touches). It's reviewing the signup.js route for personal-data handling. I'll report its verdict when it completes.

✻ Waiting for 1 background agent to finish

● Agent "Privacy review of signup diff" came to rest · 1m 7s

forgeward gate: FAIL — the privacy reviewer returned VERDICT: FAIL. No marker was written and nothing was shipped.

Surfaces fired: privacy (personal data). Skipped: accessibility (no UI), ai-output (no LLM call), seo (no public pages), supply-chain (no manifest change).

Privacy — Critical/High findings

[High] signup.js:8 (commit 8530100, permanent in git history) — plaintext PII in logs
The intermediate commit logs { email, phone, password, ssn } to console.log. The final state fixes this, but the commit is permanent in branch history. If this branch was pushed to any remote, email + plaintext password + SSN (a government identifier) are already exposed to anyone with repo/CI/log access.
Fix: Treat as a potential exposure event if pushed. Rebase to squash/amend 8530100 out before merge and force-push. Have counsel assess whether the SSN exposure is a notifiable breach.

[High] signup.js:8-9 (final) — over-collection / no processing purpose
email and the computed passwordHash are both discarded with void. The route accepts an email and password but never persists or uses them — collecting personal data that fulfills no purpose, with no storage layer to audit a deletion path against.
Fix: Either complete persistence to a store with a documented deletion path, or don't accept/destructure the PII until that store exists.

[High] signup.js (final) — no retention/deletion/export path
No DB write, schema, or erasure/export mechanism (GDPR Art. 17/20, CCPA). Any future persistence wired to this route inherits the gap.
Fix: Design and document deletion + export paths (row-level deletion keyed on user identity) before wiring persistence.

Medium findings also raised (not gating, worth addressing): no input validation on email/password (scrypt DoS + malformed-email erasure issues), no consent capture, and a non-configurable scrypt work factor.

---
forgeward gate: FAIL — fix the Critical/High findings above and re-run /forgeward:gate. Nothing was shipped.

The most actionable next step is the git-history one (Finding 1): the SSN/password/plaintext-PII commit needs to be squashed out before this branch merges, regardless of the final-state fixes. Want me to help you plan that history rewrite, or wire up the persistence + deletion path?
```

**Result B**

Undid the commit, restored the file, rerun /forgeward:gate and asked it to fix the file itself. commited and rerun /forgeward:gate
```
❯ /forgeward:gate

I'll run forgeward's conformance gate. Starting with base branch detection and diff scoping.

  Ran 3 shell commands

Base branch is main. Now scoping the diff.

  Ran 2 shell commands

Surfaces: personal-data=yes (email + password collection in signup.js), UI=no, llm=no, public-pages=no, deps=no → firing: privacy-reviewer.

Skipping accessibility (no UI/markup), ai-output (no LLM calls), seo (no public pages), and supply-chain (no dependency manifest changes — package.json/lockfiles untouched).

Firing the privacy reviewer on main...HEAD.

● forgeward:privacy-reviewer(Privacy review of signup diff)
Backgrounded agent (↓ to manage · ctrl+o to expand)
Allowed by auto mode classifier

I've launched the privacy reviewer (the only reviewer whose surface this diff touches). Waiting for its verdict before deciding whether to write the pass marker and ship.

The privacy reviewer is running in the background. I'll wait for its verdict — I'll be notified automatically when it completes, then I'll decide on the marker and ship.

✻ Waiting for 1 background agent to finish

● Agent "Privacy review of signup diff" came to rest · 1m 1s

forgeward gate: FAIL

Only the privacy reviewer fired (the diff collects email + password in signup.js). It returned VERDICT: FAIL. No marker was written and nothing was shipped.

Privacy — Critical/High findings

[High] signup.js:31 — log line sits one keystroke away from leaking credentials
console.log("NEW SIGNUP", { correlationId }) is placed immediately after email/password are destructured into scope, with no guardrail. Compounding this, express.json() was added globally and unconditionally at server.js:3 with no body-scrubbing layer — a later maintainer adding request-logging middleware (e.g. morgan) would silently log raw req.body (email + password) for every POST.
Fix: route the log through a structured helper with an explicit loggable-field allowlist (correlation ID, timestamp, route), and/or add a lint rule (no-restricted-syntax) flagging any console.log referencing email/password in the handler; add a body-scrubbing stub for /signup so future access logs can't capture credentials.

[High] signup.js:33-37 — personal data path with no deletion/export mechanism
Email + passwordHash are processed but the persistence TODO leaves no GDPR Art. 17/20 (and CCPA) erasure/export path. The moment any store is wired in — even a test insert — there's PII with no compliant deletion route.
Fix: before this reaches any environment that can touch a real store, land (a) a documented user-record schema keyed by user ID, (b) a deletion path that removes all rows by user ID, (c) an export path. Convert the TODO to a tracked blocker issue, not a code comment.

Also flagged (Medium/Low — not gate-blocking, worth addressing)

- [Med] signup.js:18/server.js:3 — global express.json() has no size limit or field allowlist; reject bodies with fields beyond email/password (or use a .strict() schema) to avoid over-collection.
- [Med] signup.js — no consent version/timestamp captured for the email collection's lawful basis.
- [Low] signup.js:9 — set explicit scrypt params ({ N, r, p }) + a version tag stored with the hash.
- [Low] signup.js:20-21 — keep error message/timing identical across missing vs. malformed (and later, already-registered) email to avoid account enumeration.

---
forgeward gate: FAIL — fix the two High findings above and re-run /forgeward:gate. Nothing was shipped.

The gate is read-only, so I haven't touched any code. Want me to draft the fixes for the two High findings so you can re-run the gate?
```
---

## 5. Test B — supply-chain re-gate after PASS (2d)

With a fresh PASS marker, add a typosquatted dependency:
```bash
# in ~/forgeward-live-test/app, on the PASSED commit
python3 -c "import json;d=json.load(open('package.json'));d['dependencies']['expresss']='^4.0.0';open('package.json','w').write(json.dumps(d,indent=2)+chr(10))"
git add -A && git commit -m "feat: add expresss dep"
```
Ask Claude to **push** again.

Expected:
- The push is **DENIED** — the dependency change flipped the reviewed-state hash, so the marker
  is stale: `forgeward gate not passed for HEAD <sha>`.
- Run `/forgeward:gate` → now the **supply-chain-reviewer fires** (a manifest changed), flags
  `expresss` as a typosquat of `express`, and ends `SUPPLY-CHAIN VERDICT: FAIL`. No marker; push
  stays blocked. (This is the gap gstack's `/cso` does not cover.)

**NOT TESTED YET**
---

## 6. Optional — real gstack `/ship` integration (only if gstack is installed)

The hook gates `/ship`'s actual publish commands (`ship/SKILL.md:1247` `git push`,
`pr-body.md:187` `gh pr create`). To confirm against the real flow:
- With **no** marker, type **`/ship`** (or **`/gstack-ship`** if you installed gstack with
  `--prefix` — the matcher `^([A-Za-z0-9_]+-)?ship$` covers prefixed variants). The
  `UserPromptExpansion` hook should halt it immediately: `forgeward gate: /ship halted ... Run
  /forgeward:gate first`.
- Or let `/ship` run; when it reaches its push step, the PreToolUse hook denies it with the same
  reason. (gstack does its local version bump/commit first — see README "accepted gaps"; nothing
  reaches the remote.)

**NOT TESTED YET**

---

## 7. If it FAILS — diagnose, don't guess (2e)

| Symptom | Likely cause | Confirm / fix |
|---|---|---|
| Push **succeeded**, no "forgeward" text, no marker existed | Hook not registered | `claude plugin details forgeward` must list a PreToolUse/Bash hook. If missing: plugin not enabled (`claude plugin enable forgeward`) or hooks not reloaded (`/reload-plugins` or restart). |
| Push ran and failed with only git's `failed to push` (no forgeward reason) | That's a **git** error, not the gate | The gate denies *before* the command runs. A git-level failure means the hook didn't deny — see row above. |
| Hook seems present but push proceeded | Matcher didn't match the command | Confirm the push went through the **Bash** tool as `git push` (not an MCP git tool, which surfaces as `mcp__*`). Run the manual isolation check below. |
| Everything allowed regardless of marker | `jq` **and** `python3` both missing → fail-open | `command -v jq python3`; install one. |
| `/forgeward:gate` not found | Skill not loaded | `claude plugin list`; ensure `forgeward` enabled; `/reload-plugins`. |
| Marker written but push still denied | git-dir mismatch (worktree) or hash recompute differs | Run the manual check; compare `cat .git/forgeward-gate-marker.json` `diff_hash` with `scripts/forgeward-diff-hash.sh <base>`. |

**The key isolation test — separates "plugin didn't dispatch" from "script logic broke":**
```bash
printf '{"cwd":"'"$PWD"'","tool_input":{"command":"git push"}}' \
  | <PLUGIN_DIR>/scripts/forgeward-gate-check.sh pretooluse
```
- Prints a `permissionDecision: "deny"` JSON, **but** Claude's real push isn't blocked → the
  **script works; the problem is plugin hook dispatch** (registration/reload — section 1).
- Prints **nothing** when you expected a deny → the **script/marker logic** is the issue, not
  dispatch (e.g. a stale or wrong-path marker, or `jq`/`python3` missing).

Run the suite any time to confirm the decision logic itself is intact:
```bash
cd <PLUGIN_DIR> && npm test    # 21 assertions, all should pass
```
