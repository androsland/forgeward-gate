# forgeward gate

> gstack ships fast. forgeward-gate makes sure it ships clean — an enforced, read-only review
> gate that blocks the push until privacy, accessibility, AI-output, SEO, supply-chain, and
> security checks pass.

An **enforced, read-only conformance gate** for [gstack](https://github.com/garrytan/gstack).

This plugin has **two distinct parts**:
- **The gate (enforced)** — read-only reviewers, a fast in-editor reminder, and a `pre-push`
  hook that blocks an un-gated push. Everything below describes it.
- **`/forgeward:ci-gate`** — an on-demand skill that detects your repo's real stack, drafts the
  CI it's missing (tests/lint **and** security scanning), and offers to make those checks
  required via branch protection. Drafting is advisory; enforcement is one explicit, confirmed
  step. See [its section](#forgewardci-gate--draft-the-ci-then-enforce-it).

gstack covers think → plan → build → review → test → ship. The one thing it lacks is a
*blocking* gate: its `/ship` is fully automated and never refuses to publish. This plugin
adds the reviewers gstack has no equivalent for and makes them **block `/ship` until every
fired reviewer returns `VERDICT: PASS`.** It touches zero gstack files.

## What it adds (and what it deliberately doesn't)

Six read-only reviewers, each firing **only** when the diff touches its surface:

| Reviewer | Fires when the diff touches | Why it's here (not redundant with gstack) |
|----------|------------------------------|-------------------------------------------|
| `privacy-reviewer` | personal data | gstack's `/cso` is intrusion-security, not lawful data handling |
| `accessibility-reviewer` | UI | gstack's design reviews are taste/AI-slop, not WCAG 2.1 AA conformance |
| `ai-output-reviewer` | an LLM / paid-AI call | gstack covers prompt-injection for *its* browser, not *your* LLM output reliability/cost |
| `seo-reviewer` | public, indexable pages | no SEO/crawlability/metadata coverage anywhere in gstack |
| `supply-chain-reviewer` | a dependency manifest | gstack's `/cso` Phase 3 covers CVEs/install-scripts/lockfiles but **not** typosquatted/hallucinated packages or copyleft-license conflicts |
| `security-reviewer` | executable code (queries, handlers, auth, file/shell/network I/O, `.sql`) | gstack's `/cso` covers this axis but is **opt-in and manual** — see below |

**Why a security reviewer now (this reversed a prior decision).** forgeward used to delegate the
general security axis to gstack's `/cso`, reasoning that `/cso` already covers OWASP + STRIDE +
CVEs. In practice `/cso` is **opt-in and manual** — on a real PR it simply wasn't run: the gate
fired only privacy + accessibility, returned PASS, and a **critical SQL-injection-class change
shipped on a green marker** (a commercial SAST scanner independently flagged 1 critical + 13 high
on the same diff). `security-reviewer` closes that — it fires automatically in the gate,
diff-scoped, running a bundled framework-aware SAST rulepack plus injection/authz reasoning. It
does **not** replace `/cso` for a deep whole-repo audit, and one reviewer won't match a commercial
SAST engine's recall; for an unskippable floor, `/forgeward:ci-gate` wires real scanners into CI.

**Still not included on purpose:** a code-quality reviewer — gstack's `/review` covers it.

## How it works

- **Happy path:** run `/forgeward:gate`. It detects which surfaces the diff touches, fires
  only the relevant reviewers (read-only — `Read, Grep, Glob, Bash`, no edits), and on
  all-PASS writes a pass marker and hands off to gstack's `/ship` in one motion.
- **Enforcement — fast feedback in Claude Code, and the real lock at `pre-push`:**
  1. `UserPromptExpansion` on a typed ship command → halts immediately if there's no fresh PASS
     for the current code, before any work runs. The matcher is `^([A-Za-z0-9_]+-)?ship$`, so it
     fires on `ship` **and** any prefixed variant (`gstack-ship` and any custom gstack `--prefix`),
     and not on lookalikes (`shipment`, `airship`).
  2. `PreToolUse` on `Bash` → a **best-effort reminder**: on a `git push` / `gh pr create` /
     `glab mr create`, it denies when the current checkout's branch has no fresh marker. It reads
     command *text*, so it is leaky by design — `git -C`, quoting, a script file, an alias all
     slip past. Treat it as fast feedback, **not** the boundary. (Four security reviews confirmed
     no text-matching hook can be both bypass-proof and usable.)
  3. **`pre-push` hook — the enforcement.** `scripts/forgeward-pre-push.sh`, installed per repo
     with `scripts/forgeward-install-pre-push.sh`. Git runs it *inside* the push and hands it the
     exact refs + SHAs on stdin, after the shell has resolved `git -C` / quoting / `$vars` /
     `xargs` — so none of those can evade it. It blocks the push if any branch ref being pushed
     lacks a fresh marker. It is **opt-in per repo** (`git config forgeward.gate enabled`, set by
     the installer), so it is safe to live in a shared/global `core.hooksPath` dir — a no-op
     everywhere except repos that opted in.

**Honest limits — strong, not indestructible.** `git push --no-verify` skips the pre-push hook;
the marker is a local file that can be forged; git hooks are not cloned (re-install in a fresh
clone, and after a plugin update — the enforcer path is baked into the installed hook). No
purely-local gate escapes these. For an **unbypassable** boundary, gate the MERGE server-side
with `/forgeward:ci-gate` (required checks + branch protection). Hooks 1–2 match the *publish
command*, not the skill name, so they are prefix-independent across gstack install variants.

The marker pins a hash of the **reviewed code and dependencies** (`base...HEAD`), excluding
only gstack's cosmetic post-gate writes (`VERSION`, `CHANGELOG*`, `TODOS.md`) and a
package.json **version-field-only** bump. Any change to source **or dependencies** after the
gate flips the hash and forces a re-gate — a dependency added between gate and push does
**not** sail through.

## `/forgeward:ci-gate` — draft the CI, then enforce it

The gate above enforces locally, before a push. `/forgeward:ci-gate` extends that into CI, so a
red check blocks the merge for **everyone** — not just whoever ran the local gate. It replaces
the old advisory `readiness` drafter: same evidence-based engine, now with teeth.

**Two phases, clearly separated:**

- **Draft (advisory, default).** Detects the real stack — package manager from the **lockfile**
  (pnpm/npm/yarn/bun), the real `test`/`lint`/`typecheck` commands from `package.json` `scripts`
  (and `CLAUDE.md` if it names them), Node from `engines`/`.nvmrc`, e2e framework from
  `playwright.config`/`cypress.config`, and Doppler **only if the repo uses it** — then drafts the
  CI it's missing: `.github/workflows/ci.yml` (typecheck/lint/test/e2e) **and**
  `.github/workflows/forgeward-security.yml` (the bundled SAST rulepack + Semgrep security packs,
  plus PHPCS/WPCS for WordPress, Trivy, and Gitleaks). It writes the files for you to review and
  commit, and prints a covered / missing / deferred / [Owner] report inline.
- **Enforce (explicit, confirmed).** Offers to make those checks **required** on your real default
  branch via branch protection — the step that actually blocks prod. This changes shared repo
  settings, so it is **never automatic**: always a confirmed yes, even with admin. Decline (or lack
  admin) and it hands you the exact manual steps instead.

For e2e specifically it makes a **three-way** call: runs-green-as-is → emit a plain job; needs env
a repo **Variable/Secret** can supply (a hosted backend reachable by URL+key) → emit a **gated,
self-skipping** job (`if: ${{ vars.<KEY> != '' }}`) that stays green-by-default and activates when
you set the Variable; needs **infrastructure that doesn't exist in CI** (a real database the app
boots against — Payload/Prisma/etc.) → **hard-flag `[Owner]`, emit nothing** (a gate that can never
make e2e pass is dead config). *(The gated-e2e pattern is **proven to activate-and-run-green on a real Actions run**; one generate-on-a-fresh-repo caveat remains — see Validation.)*

**The core guarantee — evidence AND runnability.** A step is emitted only if it passes both
tests: the command **exists** as a real script (no `typecheck` script → no typecheck step; the
**lockfile** decides the package manager, so a pnpm repo never gets a guessed `npm ci`), **and**
it can **run green in a clean CI environment as-drafted**. A real script that would fail in CI —
`lint` with no ESLint config (interactive setup prompt), or a `test`/`e2e` step that boots the
app or needs env/secrets/a live backend CI can't supply — is **flagged `[Owner]` with the exact
blocker, never emitted red.** A green-looking workflow that's red on arrival is worse than no CI;
this skill exists to never produce one.

**Validation.** Exercised against **7 real repositories** — of which **4 were drafted a new
`ci.yml`** (the repos that had no test CI), **1 was correctly *not* drafted** (no `scripts` block
— the guard fired, a report instead of a fabricated `npm test`), and **2 were left byte-for-byte
untouched** (they already had hand-tuned CI, marked Covered). A synthetic fixture covered the one
Doppler path no real repo exercised. "7 repositories" means *exercised across 7*, not *7 workflows
generated*. Together they cover:

| Dimension | Covered |
|-----------|---------|
| Package manager | **pnpm** and **npm** (lockfile-driven: `pnpm install --frozen-lockfile` vs `npm ci`) |
| Default branch | **main** and **master** (detected — a `master` repo gets `branches: [master]`, not a workflow that silently never fires on push) |
| `typecheck` | **present** (step emitted) and **absent** (no step invented) |
| Doppler | **self-wrapping** scripts (token only, no double-wrap) and **bare** scripts (prefixed `doppler run --`), both with the `dopplerhq/cli-action` install step |
| No scripts | **guard** — a repo with no `scripts` block gets a report, not a fabricated `npm test` |
| Existing CI | **don't-clobber** — detects CI by *intent* (any workflow that runs the project's scripts on push/PR), not a test-runner keyword list. Covers hand-tuned suites, **typecheck/lint-only** workflows, and the skill's **own** drafted output; biased to treat the uncertain case as Covered. Verified it leaves real hand-tuned workflows byte-for-byte untouched and re-recognizes its own lint-only `ci.yml` instead of overwriting it |
| Runnability | a `lint` with no ESLint config, or an `e2e`/`test` step that boots the app or needs env/secrets, is **flagged `[Owner]`, not emitted red** (so a drafted workflow goes green on first run, not red-on-arrival) |
| Gated e2e *(verified — one caveat below)* | **Verified on all three legs.** (1) **Gate pattern proven in real CI**: a merged hand-tuned workflow runs green-by-default (e2e self-skips until the public Variable is set). (2) **The skill generates that exact pattern** — its emitted `if: ${{ vars.<KEY> != '' }}` gate + `vars.*` wiring is equivalence-verified byte-for-byte against that merged job. (3) **Activate-and-run-green confirmed on a real Actions run**: with the two public Variables set, the e2e job flipped **Skipped → Running (1m45s, not a skip) → green**, 14 public specs passed and the 7 authed specs correctly self-skipped (no `E2E_AUTHED`). **Remaining caveat:** the full *generate-on-a-fresh-case-2-repo → that generated file runs green* chain hasn't been done in one continuous run — no fresh case-2 repo exists in the fleet (the only hosted-public repo, nutriloop, was hand-tuned). So: gate pattern + skill-generation + activate-and-run-green are each proven; only the end-to-end "skill emits the job on a never-touched case-2 repo and it goes green" remains, awaiting such a repo |
| e2e case-2/3 classification | distinguishes **gatable** e2e (boots on a hosted URL+anon-key the public suite uses → gated job) from **hard-flag** e2e (needs infra no Variable conjures → emit nothing). Reads both deps/`.env.example` (DB adapters/connection NAMES) **and the playwright config's wiring**; a Supabase repo with an **unconditional** local-URL/service-role/mailpit requirement is case 3 (linkids), while the same requirement **gated behind an `E2E_AUTHED`-style flag with a public default** stays case 2 (nutriloop). Ambiguous → defers to the user, biased to hard-flag (a dead gated job is worse than a missing one) |

This validation covers `ci-gate`'s **drafting** engine (inherited from the former `readiness`
skill); it is **additive** to the gate's own validation below and has no bearing on the
enforcement contract. `ci-gate`'s branch-protection step is separate and always confirmed. The
gate's 24-assertion suite, security scope, and honest limits are unchanged.

## Install

Two ways in. **Marketplace install** is the one-liner; **local install** (clone +
`--plugin-dir`) is the no-marketplace path, handy for development or pinning to a working tree.
This repo is public, so both work today.

`<PLUGIN_DIR>` below = the absolute path to your clone of this repo (the directory containing
`.claude-plugin/`). From the repo root you can grab it with `export PLUGIN_DIR="$(pwd)"`.

### Local install (no marketplace required)

```bash
git clone https://github.com/androsland/forgeward-gate.git
cd forgeward-gate
```

Then either load it for one session:

```bash
claude --plugin-dir <PLUGIN_DIR>
```

…or install it persistently under your skills dir (loads automatically next session):

```bash
cp -R <PLUGIN_DIR> ~/.claude/skills/forgeward-gate
```

### Marketplace install (recommended)

This repo ships a marketplace manifest (`.claude-plugin/marketplace.json`) and is public on
GitHub, so anyone can add it as a marketplace and install in two commands. Replace
`androsland/forgeward-gate` with your `owner/repo` if you forked it:

```bash
claude plugin marketplace add androsland/forgeward-gate
claude plugin install forgeward@forgeward-gate
```

`forgeward` is the plugin name; `forgeward-gate` after the `@` is the marketplace name (the
`name` field in `marketplace.json`). Per the [Claude Code plugin docs](https://code.claude.com/docs/en/discover-plugins),
the install syntax is `plugin-name@marketplace-name` — **the `@forgeward-gate` suffix is
required, not optional.** Bare `claude plugin install forgeward` does *not* resolve.

> **Note:** `claude plugin install forgeward` (no `@marketplace`) fails with *"Plugin forgeward
> not found in any configured marketplace"* — both because it omits the required marketplace
> suffix **and** because you must run `claude plugin marketplace add androsland/forgeward-gate`
> first. Run the two commands above in order and it resolves.

### After install

The plugin is `defaultEnabled` — reviewers, the `/forgeward:gate` skill, and the two
in-editor hooks (the `/ship` halt and the `PreToolUse` reminder) activate on install with no
`settings.json` edit. The **enforcement** hook (`pre-push`) is **not** auto-registered — run
`scripts/forgeward-install-pre-push.sh` once per repo to turn it on (it sets
`git config forgeward.gate enabled` and installs the hook into the repo's effective hooks
dir). The hooks read JSON with `jq` if present, else `python3`; if *neither* exists they fail
open — see limits.

## Validation / what's tested

**Automated suites — `npm test`.** Both are framework-free and exercise the **real plugin
scripts** in `scripts/` (not mocks or copies) against throwaway git repos.

`test/gate-test.sh` (27 assertions) — the in-editor layer:
- **Deny when there's no fresh PASS marker** — `git push`, `gh pr create`, and
  `glab mr create` are all reminded; a typed `/ship` is halted at expansion (exit 2).
- **Allow on a fresh PASS marker**; **version-bump invariance** (a version-field-only bump keeps
  the marker); **dependency change** and **stale code** force a re-gate.
- **Non-publish commands are never touched**; **outside a git repo it fails open**.
- **Worktree honor-cd** — `cd <worktree> && git push` is evaluated in that worktree (gated →
  allow, ungated → deny), including a single-quoted spaced path.
- **Ship matcher** and **base-detection fallback**.

`test/pre-push-test.sh` (10 assertions) — the enforcement layer, driven exactly as git drives
it (refs on stdin, so no command parsing):
- gated ref allowed; ungated ref blocked (names it); multi-ref one-ungated blocked / all-gated
  allowed; branch deletion allowed; stale blocked; version-only bump allowed; tag allowed; **a
  marker written inside a linked worktree honored from the main checkout** (the original bug);
  and the **opt-in no-op** (a repo without `forgeward.gate` is never blocked — safe as a global
  hook). An end-to-end harness additionally confirms real pushes via `git -C`, `git  push`,
  `"git" push`, and `g\it push` are all blocked while ungated, and `--no-verify` bypasses.

**Live end-to-end.** Beyond the unit suite, the gate was exercised through a real Claude Code
session (see `live-test/LIVE-TEST.md`): the same `git push` was observed **denied** (no marker)
→ **succeeded** (after a PASS marker) → **denied again** once a typosquatted dependency flipped
the hash — proving the actual plugin **hook dispatched**, not just that the scripts work in
isolation. The `supply-chain-reviewer` caught the typosquat with registry evidence.

**What "validated" means here (honest boundary).** Tested means *tested-as-designed* — the
deny/allow logic behaves as specified, and real pushes through the installed `pre-push` hook
are blocked/allowed as expected. It does **not** mean tamper-proof (see limit 1). This raises
the floor; it is not a sandbox.

## Three honest limits

1. **Strong, not tamper-proof — and local, not server-side.** The `pre-push` hook enforces on
   any `git push` from that machine (Claude Code *or* a plain terminal), immune to command-text
   tricks. But it is still client-side: `git push --no-verify` skips it, the marker is a local
   file that can be forged, git hooks aren't cloned (re-install per clone / after a plugin
   update), and disabling the plugin removes the reviewers. No purely-local gate escapes these —
   for an **unbypassable** boundary, gate the MERGE server-side with `/forgeward:ci-gate`
   (required checks + branch protection). The in-editor `PreToolUse` hook is only a best-effort
   reminder and is leaky by design.

2. **gstack's Codex review is a separate privacy exposure this gate does not cover.** gstack's
   `/ship` and `/review` send your work to OpenAI's Codex for a second opinion by launching
   `codex` with **read access to your whole working tree** (not just the diff), and gstack's
   redaction guard does **not** scrub what Codex reads. If that matters to you, turn it off
   with `gstack-config set codex_reviews disabled`. forgeward's gate works fully either way —
   this is a gstack setting, not a forgeward one.

3. **No mandatory paid-OpenAI dependency.** gstack's Codex steps degrade to Claude when no
   OpenAI key is present, so the stack underneath this plugin runs fully on Claude alone. The
   only paid dependency is the Claude access you already need to run Claude Code.

## Security scope

**What forgeward covers.** The gate's `security-reviewer` fires on any code change and runs a
bundled framework-aware SAST rulepack (e.g. unprepared `$wpdb` queries that generic Semgrep packs
miss) plus injection/authz reasoning, diff-scoped. `/forgeward:ci-gate` wires **real scanners**
(Semgrep, PHPCS/WPCS, Trivy, Gitleaks) into CI and can make them a **required, merge-blocking**
check via branch protection. Between them, forgeward does static security review **and**
CI-enforced SAST merge-gating.

**Honest boundaries.** This is still *static* review — no dynamic/runtime scanning (DAST, e.g.
OWASP ZAP) and no container-image scanning. The gate's `security-reviewer` is **diff-scoped**: it
reviews the change, not the whole repo, and one LLM reviewer won't match a dedicated commercial
SAST engine's recall. Run gstack's `/cso` for a deep whole-repo audit, and treat the `ci-gate` CI
scanners as your unskippable floor. A gate PASS means the reviewed change is clean, not that the
running application is secure.

## Accepted design gaps (documented, not bugs)

- **Pre-push local mutations aren't gated.** gstack's version bump, CHANGELOG, and commit
  squash happen before the push. They're local and reversible, and `/ship` is
  idempotent-by-re-run, so recovery is native: after `/forgeward:gate` passes, re-run `/ship`.
- **gstack's pre-push Codex review dispatch is out of scope.** It's review, not publishing, and
  gstack has a native switch for it (limit 2). We don't hook or block it.
- **If neither `jq` nor `python3` is available, the enforcement hook fails open.** It allows
  the push rather than wedging your Bash. Virtually every dev machine has one; install `jq`
  or `python3` for the gate to enforce.

## License

MIT — see [LICENSE](LICENSE).
