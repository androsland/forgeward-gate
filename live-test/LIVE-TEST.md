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
- `/plugin` → `forgeward` is enabled and its detail view lists 11 reviewer agents (five of them the ported quality reviewers §5c exercises), the `gate`, `audit` and `ci-gate` skills, and hooks.
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
- The gate writes the marker, then branches on whether gstack's `/ship` is installed: with
  gstack it hands off in the same motion; without it, it reports that `/ship` is not installed
  and that you should commit, push and open the PR yourself. Either way the marker is written
  first, so the push hook allows the push. (Until 0.8.0 this line promised a graceful
  standalone branch that did not exist — the handoff was unconditional, so with no gstack the
  gate reported a handoff that never happened.)
- Verify the marker and that the push now goes through:
  ```bash
  # one file per branch; there is no single `.git/forgeward-gate-marker.json`
  cat "$(git rev-parse --git-common-dir)"/forgeward-gate-markers/"$(git branch --show-current)".json
  # shows passed:true, base, diff_hash, reviewed_head
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

## 5b. Test C — `.forgeward/config.yml` is honoured, and says what it does not honour

The probe is covered by E1–E27 in the suite. What no test can reach is the half executed by
a model: whether the gate *acts* on the config it is handed. That is this section's only job.

```bash
# in ~/forgeward-live-test/app
mkdir -p .forgeward
cat > .forgeward/config.yml <<'YAML'
standalone:
  substitutes: ["deep-audit"]
seo:
  posture: private-shareable
  routes: {"/app/*": private-closed}
YAML
"$PLUGIN_DIR/scripts/forgeward-detect-environment.sh"
```

The probe must print `"substitutes":"deep-audit","seo_posture":"private-shareable"` — note the
flow sequence and the quoted scalar, both of which read as *nothing configured* before 0.9.0.
It must also print **`"config_warnings":0`**: every key here is either honoured or, in
`seo.routes`' case, documented as unhonoured, and the count must not fire on a config that
followed the docs. This is the negative half of the 0.13.0 check and the easier one to get
wrong — a counter that warned here would be correct about the mechanism and wrong about the
product.

Now run `/forgeward:gate` on a change that touches a public page. Expected, in the firing
decision:
- **No `deep-audit` clause of any kind** — the substitute answered it. Read what this
  fixture is keyed on now, because it has moved twice and the assertion looks the same
  after each move while testing something different. Until 0.17.0 it named `quality`,
  which became unusable when forgeward took that axis over: `quality` prints no
  disclosure whether or not it is substituted, so an assertion built on it would pass
  with the substitutes reader deleted. `deep-audit` replaced it as the last
  gstack-deferred axis — and 0.19.0 ended that too, porting `/cso`'s phases into
  `/forgeward:audit`. The clause survives the port because it was re-keyed on **"not run
  by this gate"**, a fact about scope that no install can change, and `substitutes` still
  silences it. So this step now checks the substitutes reader against a clause that is
  printed unconditionally — which is a *stronger* fixture than the one it replaced, since
  `/cso`'s absence can no longer be what produces the silence.
- **The one-axis fixture cannot show the other half.** With a single axis in the list, "a
  gate that silences everything" and "a gate that silences the right thing" look identical.
  To see both, run the section a second time with an empty `substitutes:` and confirm the
  `deep-audit` clause *does* appear. Until 0.17.0 the two axes covered each other here
  for free; they no longer do, and nothing about the fixture makes that visible.
- **There is no deferred axis left to substitute, so nothing in this file exercises the
  absence path any more.** Every axis forgeward discloses is now owned by forgeward. That
  is the intended end state, and it costs this suite a case: an axis whose disclosure is
  conditioned on a *missing partner tool* can no longer be tested here, because none
  exists. Do not read a green §5 as covering that mechanism.
- **No quality disclosure of any kind**, and no instruction to run `/review` — not in the
  firing decision and not in the PASS report. Five quality reviewers should be *in* the
  firing list instead. This is the assertion that catches a stale skill file more directly
  than any probe check can.
- The posture is reported as pinned, e.g.
  `Postures: all = private-shareable (pinned in .forgeward/config.yml)`, and the
  privacy-reviewer fires on that group even if the diff is only markup.
- **`seo.routes` is called out as having no effect.** It is documented and unread; the gate
  must say so rather than silently classifying by detection as though the pin were honoured.

Then break it and confirm the failure is loud in the right direction:
```bash
printf 'seo:\n  posture: not-a-real-posture\n' > .forgeward/config.yml
"$PLUGIN_DIR/scripts/forgeward-detect-environment.sh"     # seo_posture EMPTY, config_warnings 1
printf 'standalone:\n  substitues:\n    - quality\n' > .forgeward/config.yml
"$PLUGIN_DIR/scripts/forgeward-detect-environment.sh"     # a typo'd key: config_warnings 1
ln -sf /etc/hostname .forgeward/config.yml                # a symlink is refused, not followed
"$PLUGIN_DIR/scripts/forgeward-detect-environment.sh"     # config "unreadable", warnings 0
rm -rf .forgeward
```

On the typo'd-key run, `/forgeward:gate` must print the one-line note naming the path and the
count — and must still gate normally, writing the marker on all-PASS. **The symlink run is the
`0` that is not a clean bill**: the count is `0` because nothing was read at all, and only
`config: unreadable` says so. A gate that reports "no config problems" there has read the
wrong field.

**TESTED — 2026-08-06, plugin 0.9.0 installed from cache.** Every assertion above held,
including the three that only a model can satisfy: the seo-reviewer reported
`Postures: all = private-shareable (pinned in .forgeward/config.yml)` after running the
probe itself, and called `seo.routes` out as unread *unprompted*; the privacy-reviewer
fired on a markup-only diff and reasoned from the pin rather than the diff shape. Both
negative checks behaved (invalid posture → empty, symlink → `unreadable`), reviewers left
the repo byte-identical, and the FAIL wrote no marker.

Two caveats on how it was run, so the next person does not over-read this:

- It used a purpose-built fixture in a scratch directory, not the §2 repo — the §2 scaffold
  has no public page to touch, and this section needs one.
- **The `substitutes` half was verified against a *simulated* gstack-absent machine**
  (`CLAUDE_CONFIG_DIR` pointed at an empty directory). On a box where gstack is installed,
  the disclosure would be absent whether or not the substitute worked, so the assertion is
  vacuous there. If you re-run this on a genuinely gstack-free machine, that is the stronger
  test and worth preferring.
- **The `substitutes` half's stamp does NOT carry to the current fixture.** It was taken on
  `substitutes: ["quality"]`, and 0.17.0 changed the fixture to `["deep-audit"]` because the
  old one became unfalsifiable. The reader is identical and E4/E19/E20 pin it on both
  spellings, so this is very likely fine — but "very likely fine" is what an unstamped
  assertion is, and the whole point of these stamps is not to launder one into a stamp.
  Neither the `deep-audit` substitute nor the new quality assertions have been run live.
- **The `config_warnings` assertions above are NOT covered by that stamp** — they were added
  in 0.13.0, after it. The probe's own numbers were verified directly against these exact
  fixtures and are pinned by E28–E37 in `test/gate-test.sh`; what remains unverified live is
  the half only a model can satisfy, namely that the gate actually prints the one-line note
  and still writes the marker. Re-run this section to close that.

---

## 5c. The five ported quality reviewers, on a real diff

0.17.0 ported gstack's five Review Army specialists — `maintainability`, `testing`,
`performance`, `api-contract`, `data-migration` — and forgeward has owned the `quality`
axis outright ever since. `test/gate-test.sh` verifies the *port* (provenance recorded,
drift detected, rubrics present); nothing in any suite has ever verified the *reviewers*,
because what they do is a model judgement and no assertion can see it. This section is
the only instrument for three questions a suite structurally cannot answer:

1. **Do the per-axis severity floors hold?** Only Critical and High fail a gate. THREE of
   the five — `maintainability`, `testing` and `api-contract` — say Critical is *never*
   correct for their axis, and each names a short list for High. The other two are not
   oversights and must not be read as one: `data-migration` reserves Critical for
   irreversible data loss with no deprecation period and no stated backup, and
   `performance` states no never-clause at all. So the floor being checked here is
   per-axis, not one rule applied five times. A maintainability observation reported as High would start blocking pushes
   on ordinary debt — the failure the floors exist to prevent, and the one that would
   make people switch the gate off.
2. **What does always-on cost?** `maintainability` and `testing` fire on *any* code diff,
   so every gate run now spawns at least two more reviewers than it did before 0.17.0.
   Whether that is tolerable on a large diff is a wall-clock fact, not a design opinion.
3. **Do five more reviewers repeat each other?** If the same defect comes back from three
   axes, Step 3 needs deduplication. If it does not, it must not grow one.

### Build the fixture (a purpose-built scratch repo, not the §2 scaffold)

The §2 scaffold has no HTTP surface and no migration, and this section needs both.

<!-- No `export PLUGIN_DIR` here on purpose. This section never reads it -- the uses are
     all in 5b, above -- and pasting the line verbatim would overwrite a PLUGIN_DIR the
     reader correctly set at the top of this file with the literal string `<PLUGIN_DIR>`,
     which then breaks 5b if they go back to it. Set it once, at the top, as 0 says. -->

```bash
export Q=~/forgeward-quality-test
rm -rf "$Q" && mkdir -p "$Q" && cd "$Q"
git init -q && git config user.email t@example.com && git config user.name Test

mkdir -p src migrations test
cat > src/tiers.js <<'EOF'
const TIERS = ["quick", "lfg", "mega"];
module.exports = { TIERS };
EOF
git add -A && git commit -qm "base"
git branch -M master
# A base the gate can resolve as the publish boundary. No remote: forgeward-detect-base.sh
# falls back to the local branch, which is correct for a repo that has never been pushed.
git checkout -qb feat/quality-fixture
```

Now the diff. Every item below is deliberately placed at a KNOWN severity, and the
placement is what this section tests — each one is a thing its axis must report **without**
promoting it to High:

```bash
# maintainability: a magic number, a stale comment, and dead code that is NOT load-bearing.
cat > src/pricing.js <<'EOF'
const { TIERS } = require("./tiers");

// Returns the price in cents. (Stale: it has returned dollars since the rewrite.)
function price(tier) {
  return TIERS.indexOf(tier) * 4900;
}

// Nothing calls this. It reads no live state and guards nothing.
function legacyPrice(tier) {
  return TIERS.indexOf(tier) * 3900;
}

module.exports = { price, legacyPrice };
EOF

# performance: an O(n*m) lookup over a BOUNDED, hard-coded array. Not user-driven,
# not a query, no new index implied.
cat > src/report.js <<'EOF'
const { TIERS } = require("./tiers");
function summarise(rows) {
  return TIERS.map((t) => ({ tier: t, n: rows.filter((r) => r.tier === t).length }));
}
module.exports = { summarise };
EOF

# api-contract: a BRAND-NEW endpoint with an error shape unlike the rest of the app.
# New means no existing consumers, which is exactly what keeps it off the High list.
cat > src/routes.js <<'EOF'
const { price } = require("./pricing");
module.exports = function register(app) {
  app.get("/api/v1/price/:tier", (req, res) => {
    const p = price(req.params.tier);
    if (p < 0) return res.status(400).send("bad tier");   // string, not the {error} shape
    res.json({ price: p });
  });
};
EOF

# testing: a thin happy-path test and nothing else. No deleted test, no assertion-free test.
cat > test/pricing.test.js <<'EOF'
const { price } = require("../src/pricing");
test("price of quick", () => { expect(price("quick")).toBe(0); });
EOF

git add -A && git commit -qm "feat: pricing endpoint, report summary, one test"
```

### Run A — the floors leg

In Claude Code, in `$Q`, type **`/forgeward:gate`**.

- The firing decision must **account for all five** ported reviewers, and must name four
  of them — `maintainability`, `testing`, `performance`, `api-contract` — as FIRED.
  `maintainability` and `testing` are always-on: a firing line that omits either is
  describing a run that did not happen.
- **`data-migration` has no surface in Run A, and that is the point of checking it here.**
  The fixture commits JavaScript and no DDL; `mkdir -p migrations` leaves an EMPTY
  directory, which git does not track, so nothing under `migrations/` reaches the diff.
  Per the Step 1 table that reviewer is therefore correctly skipped. Two outcomes are
  right — an explicit skip on the firing line, or fired-and-self-skipped (the table says
  "when unsure, fire it", and the reviewer's own rubric returns PASS on an absent
  surface). A run that mentions it **nowhere** is the finding. Its real leg is Run B.
  Do not read "four PASSes" as a defect: five would mean the surface test is not running.
- **Every reviewer that fired must return PASS.** Every item in the fixture is real and
  every one is below the blocking bar. A FAIL here is the finding — record which axis
  promoted what, and against which of its own High bullets it claimed to be acting.
- **No quality disclosure of any kind.** No `NOT COVERED: quality`, no naming gstack as
  the axis owner, no suggestion to run `/review` before merging. All three were correct
  before 0.17.0 and all three are now false.
- **`deep-audit` gets exactly one clause** on that same firing line, keyed on *not run by
  this gate* — never on whether anything is installed.
- The marker is written, and the tree is byte-identical afterwards
  (`git status --porcelain` empty). It is one file per branch at
  `"$(git rev-parse --git-common-dir)"/forgeward-gate-markers/<branch>.json` — **not**
  the single `.git/forgeward-gate-marker.json` three places in this document named until
  0.27.0, which the writer has never written and which is therefore absent on a correct
  run and a broken one alike. Record its `reviewed_head`: Run B is checked against it.

The floors, quoted from the shipped rubrics so a reviewer's own words can be held against
its verdict. Anything not on a High list is Medium or Low **by definition of the axis**,
not by the reviewer's sense of how bad it sounds:

| axis | Critical | High is ONLY | this fixture's item |
|---|---|---|---|
| `maintainability` | **never** | dead code that is still load-bearing — a commented-out or unreachable guard a live path depends on, an exported handler with authorization removed, a stale constant a running path reads | `legacyPrice` is dead and guards nothing; the stale comment and `4900` are Medium/Low |
| `testing` | **never** | an auth / authz / payment / destructive-data change shipping with **no test at all**; a test deleted with nothing replacing it; a test that asserts nothing | one thin happy-path test on a non-auth path — Medium at most, and a regenerated snapshot would be **Low** |
| `performance` | an unbounded query or in-memory read whose size is driven by **user input** on a request path | a new N+1 over a user-growing collection; a new query filtering or joining on an unindexed column; a new list endpoint with no pagination and no cap | `summarise` is O(n·m) over a 3-element constant — bounded, so Medium/Low |
| `api-contract` | **never** | a breaking change to an endpoint that **already has consumers**, with no version bump, no alias and no sunset path | a brand-new route, so no consumers exist to break; the error-shape inconsistency is Medium/Low |
| `data-migration` | irreversible data loss with no deprecation and no stated backup | lock-taking DDL with no `CONCURRENTLY` on a plausibly-large table; an unbatched backfill; a schema change that breaks running code with no multi-phase plan | *nothing in Run A* — that is Run B |

Two things the rubrics say that a verdict must not quietly drop: `performance` must not
grade on a benchmark it did not run (it grades **one level down** instead), and both
`testing` and `api-contract` must **not FAIL** on something they could not establish — an
untested path they cannot prove untested, an endpoint they cannot prove published.

### Run B — the positive control

Run A is an assertion that five reviewers stayed quiet, and a reviewer that never fires is
also quiet. Run B is what separates the two.

```bash
cat > migrations/002_add_currency.sql <<'EOF'
ALTER TABLE orders ADD COLUMN currency text NOT NULL DEFAULT 'USD';
CREATE INDEX idx_orders_currency ON orders (currency);
EOF
git add -A && git commit -qm "feat: currency column"
```

Run **`/forgeward:gate`** again.

- `data-migration` must **FAIL**, and at **High**: lock-taking DDL with no `CONCURRENTLY`
  on a table whose size it cannot see. Its own rubric says table size is the fact it
  usually cannot establish, and that the answer there is High rather than Critical — so a
  Critical verdict here is a floor violation in the other direction and is equally a
  finding.
- The gate must report the FAIL and **write no marker for this commit**. The check is
  emphatically NOT "no marker file exists": Run A already wrote one for this branch, a
  failed gate does not delete it, and the marker is per-branch rather than per-commit. An
  absence test here passes whatever happens and proves nothing. Confirm instead that the
  marker still pins **Run A's** commit:

  ```bash
  M="$(git rev-parse --git-common-dir)/forgeward-gate-markers/$(git branch --show-current).json"
  grep -o '"reviewed_head": *"[0-9a-f]*"' "$M"   # must still be Run A's HEAD
  git rev-parse HEAD                              # must NOT equal it
  ```

  If `reviewed_head` has advanced to Run B's commit, the gate wrote a marker for a run it
  failed, and that is the most serious finding this section can produce.
- The other four must be unaffected. If `performance` or `api-contract` also turns red on
  the migration commit, that is a scope leak worth recording.

If Run B passes cleanly, Run A's five PASSes mean nothing and the section is void — say
so rather than stamping it.

### The two measurements this section exists to take

Neither is a pass/fail. Write the numbers down; there is nowhere else they can come from.

- **Cost.** Wall-clock from the firing decision to the last verdict, and the number of
  reviewers spawned in the batch. Compare Run A against the same fixture with
  `src/routes.js` and `migrations/` removed (which drops `api-contract` and
  `data-migration` but keeps the two always-on ones). The question is whether always-on
  `maintainability` + `testing` is felt on a diff of this size, and whether it would be on
  a 2 000-line one.
- **Overlap.** List every finding by axis. `legacyPrice` is the deliberate bait: it is
  legitimately visible to `maintainability` (dead code) and to `testing` (untested). If
  three or more axes return substantially the same finding, Step 3 needs deduplication and
  that is a filing. If they do not, it must not grow one.

**NOT TESTED YET**

Three caveats on what this section can and cannot establish, so a future stamp is not
over-read:

- **It cannot be run by CI and never will be.** Every assertion is about a model's
  judgement, so it needs a human running `/forgeward:gate` in a real session and reading
  the verdicts. A green `npm test` says nothing about any of it.
- **A stamp here is one model, one runtime, one day.** Reviewer model and effort are
  properties of the runtime launch — Claude Code pins `model: sonnet` / `effort: medium`
  in the agent frontmatter, Codex Gate spawns pin `gpt-5.6-terra` / `medium`. A stamp
  taken on one of those does not carry to the other, and re-running on both is the
  stronger test.
- **The fixture is JavaScript.** Three of the five rubrics are language-agnostic prose;
  the other two are the two this fixture starves. `data-migration` reads SQL DDL and
  `performance` reasons about queries it will not find here. A stamp on this fixture does not carry to a Rails or Django repo, where those two
  axes have far more to look at.

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
| Marker written but push still denied | git-dir mismatch (worktree) or hash recompute differs | Run the manual check; compare the `diff_hash` in `"$(git rev-parse --git-common-dir)"/forgeward-gate-markers/<branch>.json` with `scripts/forgeward-diff-hash.sh <base>`. |

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
cd <PLUGIN_DIR> && npm test    # every suite should pass; the tally is printed, not pinned here
```
