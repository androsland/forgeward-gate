# forgeward gate

> An enforced, read-only review gate that blocks the push until privacy, accessibility,
> AI-output, SEO, supply-chain, security and code-quality checks pass. It runs on any repo,
> and hands off to gstack's `/ship` where that is installed.

An **enforced, read-only conformance gate**. Nothing else has to be installed for it to
work; where [gstack](https://github.com/garrytan/gstack) is present it integrates with it
rather than duplicating it.

The same checkout is packaged for **Claude Code and Codex**. Each client selects its own
manifest and lifecycle-hook file automatically; the skills, reviewer rubrics, scripts, marker,
and standalone Git enforcement hook are shared.

### Reviewer runtime policy

Reviewer selection is explicit per runtime so a costly parent session cannot silently
raise the cost of every parallel review. Under Claude Code, all eleven plugin agents pin
`model: sonnet` and `effort: medium` in their native frontmatter. Under Codex, every
reviewer spawn pins `model: gpt-5.6-terra`, `reasoning_effort: medium`, and
`fork_turns: none`. Audit's independent finding verifiers use the same selections.

The isolation is deliberate: a Gate reviewer receives its complete authoritative rubric,
the absolute repository and Forgeward roots, the exact base ref, `HEAD` and its resolved
commit, the `<base>...HEAD` range, and the read-only/verdict instructions—nothing from the
parent conversation. In concrete terms, a Claude agent definition contains:

```yaml
model: sonnet
effort: medium
```

and the equivalent Codex spawn explicitly supplies:

```text
model: gpt-5.6-terra
reasoning_effort: medium
fork_turns: none
```

Claude Code and Codex are the supported reviewer runtimes. If Forgeward cannot launch a
reviewer with the explicit policy, Gate keeps its existing fail-closed behavior: it writes
no marker. Audit keeps its existing labeled self-verification fallback when no subagent
facility is available.

This plugin has **three distinct parts**:
- **The gate (enforced)** — read-only reviewers, a fast in-editor reminder, and a `pre-push`
  hook that blocks an un-gated push. Everything below describes it.
- **`/forgeward:ci-gate`** — an on-demand skill that detects your repo's real stack, drafts the
  CI it's missing (tests/lint **and** security scanning), and offers to make those checks
  required via branch protection. Drafting is advisory; enforcement is one explicit, confirmed
  step. See [its section](#forgewardci-gate--draft-the-ci-then-enforce-it).
- **`/forgeward:audit`** — an on-demand, read-only whole-repo security audit: git-history
  secrets, dependency supply chain, CI/CD, infrastructure, integrations, LLM security, skill
  supply chain, OWASP, STRIDE. The gate is diff-scoped and deliberately does not fire it; you
  run it before a release, after an incident, or on a schedule. Nothing enforces that it ran.

The gate fires only the reviewers a diff's surfaces call for and **blocks the push until
every fired reviewer returns `VERDICT: PASS`.** That refusal is the part most tooling leaves
out: automation that reviews and then publishes regardless is not a gate.

forgeward was built alongside gstack — which covers think → plan → build → review → test →
ship, and whose `/ship` is fully automated and never refuses to publish — and it still
integrates there, blocking `/ship` exactly as it blocks an ungated push, touching zero
gstack files. It no longer *depends* on it. Each of the three axes forgeward once deferred
to gstack is now covered here on any machine: dependency CVEs (`supply-chain-reviewer`
owns them outright as of 0.23.0), code quality (five ported reviewers, 0.17.0), and the
whole-repo audit (`/forgeward:audit`, 0.19.0). The gate's own
Step 1c states the consequence in one line — *no axis on this gate is owned by a tool that
might not be installed.*

## What it adds (and what it deliberately doesn't)

Eleven read-only reviewers, each firing **only** when the diff touches its surface:

| Reviewer | Fires when the diff touches | Why it's here (not redundant with gstack) |
|----------|------------------------------|-------------------------------------------|
| `privacy-reviewer` | personal data | gstack's `/cso` is intrusion-security, not lawful data handling |
| `accessibility-reviewer` | UI | gstack's design reviews are taste/AI-slop, not WCAG 2.1 AA conformance |
| `ai-output-reviewer` | an LLM / paid-AI call | gstack covers prompt-injection for *its* browser, not *your* LLM output reliability/cost |
| `seo-reviewer` | public, indexable pages | no SEO/crawlability/metadata coverage anywhere in gstack |
| `supply-chain-reviewer` | a dependency manifest | typosquatted/hallucinated packages and copyleft-license conflicts, which gstack's `/cso` does not cover — **plus** CVEs/install-scripts/lockfiles, which it now owns unconditionally rather than deferring |
| `security-reviewer` | executable code (queries, handlers, auth, file/shell/network I/O, `.sql`) | gstack's `/cso` covers this axis but is **opt-in and manual** — see below |
| `maintainability-reviewer` | any code (always-on) | ported from gstack's Review Army — see below |
| `testing-reviewer` | any code or test (always-on) | ported from gstack's Review Army — see below |
| `performance-reviewer` | backend or frontend code | ported from gstack's Review Army — see below |
| `api-contract-reviewer` | an HTTP/RPC/GraphQL surface | ported from gstack's Review Army — see below |
| `data-migration-reviewer` | a migration, backfill, or DDL | ported from gstack's Review Army — see below |

**Why a security reviewer now (this reversed a prior decision).** forgeward used to delegate the
general security axis to gstack's `/cso`, reasoning that `/cso` already covers OWASP + STRIDE +
CVEs. In practice `/cso` is **opt-in and manual** — on a real PR it simply wasn't run: the gate
fired only privacy + accessibility, returned PASS, and a **critical SQL-injection-class change
shipped on a green marker** (a commercial SAST scanner independently flagged 1 critical + 13 high
on the same diff). `security-reviewer` closes that — it fires automatically in the gate,
diff-scoped, running a bundled framework-aware SAST rulepack plus injection/authz reasoning. It
does **not** replace a whole-repo audit, and one reviewer won't match a commercial
SAST engine's recall; for an unskippable floor, `/forgeward:ci-gate` wires real scanners into CI,
and for the whole-repo audit `/forgeward:audit` is now forgeward's own (see below).

**The five quality reviewers are ports, and the port was the point.** `quality` was
forgeward's last axis deferred to gstack: the gate disclosed that `/review` owned it and
moved on, which meant that on a machine without gstack — or, far more often, on the common
workflow of gate then push-and-PR by hand, where the `/ship` handoff that runs `/review` is
never taken — nothing reviewed code quality at all. The five checklists are ported from
gstack's Review Army specialists under MIT, with the source commit and a sha256 recorded in
each `agents/*-reviewer.md` and gstack's copyright notice reproduced in
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md). They were chosen because they are the stable part of that
tool: gstack cut **17** releases between v1.60.1.0 and v1.69.0.0, **7** of them touched
`review/`, and across the whole span `review/specialists/` changed by **zero lines**. (An
earlier draft of this sentence said "seven of those nine". Nine was the count of minor
*families* less one — there are ten, 1.60 through 1.69 — used as if it were the count of
releases. The two numbers beside it were right, which is what made it read as checked.)

Reading gstack's copies at runtime instead was considered and rejected. It keeps them
auto-updating, but it puts the axis straight back behind "is gstack installed", and the
rubrics turn out to be less reachable than they look: `forgeward-detect-gstack-skill.sh`
resolves `/review` to `~/.claude/skills/review`, which holds `SKILL.md` and nothing else —
the checklists live only in gstack's own checkout, reached by an absolute path hardcoded
in gstack's `SKILL.md`. A port trades that for drift, and drift is *reported*:
`scripts/forgeward-rubric-drift.sh` compares the recorded hashes against the installed
gstack copy, prints only when something moved, and always exits 0. On a machine with no
gstack it prints nothing, which is the whole point. Since 0.20.0 it iterates
`skills/*/SKILL.md` as well, so `/forgeward:audit` — which carries the same provenance
block — is monitored on the same instrument. Neither glob is a claim of completeness: a
ported artefact placed outside both is unchecked with nobody told, which is stated as a
non-goal in the script's header.

**No reviewer here defers to gstack any more.** The table's third column is a *delta* — it says
what each reviewer adds that gstack does not. Scoping by delta means every deferral becomes a hole
when the other side is absent, and one of them shipped that way: `supply-chain-reviewer` was told
unconditionally that `/cso` Phase 3 covers dependency CVEs, so on a machine with no gstack nobody
checked them and the reviewer returned PASS clean. The 2026-08-05 fix made the deferral
*conditional* — the reviewer probed for `/cso` and announced a `DEFERRED` or a `FULL` mode.
**0.23.0 removes the probe entirely**, and the reviewer owns CVEs, install scripts and lockfile
integrity everywhere. The intermediate step was right for its moment and stopped being right at
0.19.0: once `/forgeward:audit` closed the last axis, whether `/cso` is installed decided only
which tool did the work, never whether the work was in scope. It was also keyed on the wrong fact
throughout — detection sees *presence*, never diligence. It cannot tell
gstack-installed-and-never-run from gstack-actively-covering-the-axis, so "installed" never meant
"audited", and it cannot see that you cover the axis with Dependabot or a CI job instead. The
detector (`scripts/forgeward-detect-gstack-skill.sh`) is still here and still **fails closed**;
the `/ship` handoff reads it through the environment probe. No reviewer does.

**Code quality used to be on this list and no longer is.** Until 0.17.0 the answer was
"forgeward does not review code quality" — and the deferral turned out to run both ways: in one
repo's review log `/review` skipped its `maintainability` specialist with
`reason: "covered-by-forgeward-and-coverage-audit"` and `security` with `"covered-by-forgeward"`,
while this README pointed back at `/review`. Two tools each deferring to the other means the axis
runs nowhere, and nothing fires, because both are installed. Naming an owner instead of claiming
coverage was the honest version of that, but it was still a hole. The five ported reviewers close
it: quality is reviewed here, on every machine, whether gstack is installed or not.

**Plus one skill that is not a reviewer: `/forgeward:audit` (0.19.0).** The deep whole-repo
security audit — secrets archaeology through git history, dependency supply chain, CI/CD pipeline
security, infrastructure and IaC, webhook and integration tracing, LLM/AI security, skill supply
chain, OWASP Top 10, STRIDE, data classification. It is a port of gstack's `/cso` audit phases
under MIT (see [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md)) and it closes the third and
last axis forgeward deferred to a tool that need not be installed. It declares no `Edit` and no `Write`, so no code-editing tool is available to it, and its
report is written outside the repository under audit. That narrows the write surface rather
than closing it — `Bash` is on its tool list and must be, since the phases run git and
scanners — so "read-only" here is a discipline the prompt asserts, backed by the gate's
worktree snapshot and by `forgeward-scan.sh`, not a capability the tool list forbids.

**The gate does not fire it, and that is not an oversight.** `/forgeward:gate` resolves a publish
boundary and reviews a diff; the audit reads the whole repository and its history, on findings that
move over months, so wiring it in would make every push pay for it. The gate therefore prints one
clause naming the axis as *not run by this gate* — keyed on that, never on whether the skill is
installed, because a presence-keyed check would now read `present` everywhere and say nothing while
nothing verifies the audit was ever run. Run it deliberately: before a release, after an incident,
when you inherit a repo. Put `deep-audit` in `standalone.substitutes` to silence the clause.

**Still not covered by anything here:** the running system. Every reviewer and the audit read the
repository, so platform environment variables, secret-manager contents, WAF and gateway rules, the
IAM policy actually attached in the cloud account, and whether a branch protection rule is really
required in GitHub are all outside what a PASS can mean. `/forgeward:ci-gate` moves part of the
floor server-side; nothing here inspects production. Pin `standalone.substitutes` in
`.forgeward/config.yml` to silence an axis you cover another way — a disclosure that repeats after
being answered is nagging, and nagging is how gates get switched off. (A stale `quality` entry
there is harmless and suppresses nothing, because there is no longer a quality disclosure to
suppress.)

### `.forgeward/config.yml`

Optional, and everything works without it. **Exactly two keys are honoured:**

```yaml
standalone:
  substitutes: [quality, deep-audit]   # or a block list; axes you cover another way
seo:
  posture: private-shareable           # one of the six postures, for the whole repo
```

- **`seo.routes` is documented in the skill and agent files but is NOT read.** A per-route
  mapping with glob keys would need a real YAML parser; until one exists, a repo that pins it
  is classified by detection instead. Stated here so the pin's absence of effect is not
  discovered from behaviour.
- **It is a reader, not a YAML parser.** Block sequences, flow sequences (`[a, b]`) and
  simply-quoted scalars work; anchors, aliases, multi-document streams, escapes inside quotes
  and an indented `standalone:`/`seo:` do not. Anything it does not understand reads as *not
  configured*, so the cost of a shape it refuses is a disclosure you have already answered —
  never a silently skipped check.
- **A discarded setting is counted and reported, since 0.13.0.** The gate prints one line —
  `N setting(s) were read and discarded` — when the reader was addressed by something it
  could not use: an unknown key under `standalone:` or `seo:`, an unknown top-level key, a
  `posture:` outside the six literals, an item dropped by the charset or the caps, an
  unterminated flow sequence. Before this, a typo'd `substitues:` produced byte-identical
  output to having no config at all. It is a **count, not a list**: the value is interpolated
  into the pass marker, and an integer is the only shape with no quote or brace to splice.
  Three deliberate limits — a `0` is not a clean bill (a config that could not be opened also
  reports `0`; the separate `config` field is what distinguishes those), `seo.routes` is
  **not** counted because it is documented as unhonoured and warning on it would fire on a
  configuration that followed the docs, and on a file using anchors or multi-document streams
  the number is counted over lines that were never keys and nothing detects that.
- **A symlink at this path is refused, not followed** — it reads as unreadable and the
  disclosure still fires. This knowingly breaks a monorepo that symlinks the file to a shared
  config elsewhere in the tree; such a repo must use a regular file. `[ -f ]` and `[ -r ]` both
  follow links, and the 0.8.0 security review demonstrated a committed link carrying an
  outside file's contents into the pass marker.
- Values are bounded and sanitised on the way out (64 chars and 32 items for substitutes,
  `[A-Za-z0-9_-]` only; the posture is compared against the six literal values). The marker is
  assembled by string interpolation and this file is the only repo-controlled input to it.

## How it works

- **Happy path:** run `/forgeward:gate`. It detects which surfaces the diff touches, fires
  only the relevant reviewers (read-only — `Read, Grep, Glob, Bash`, no edits, and no
  writes into the repo at all: scanners run through `scripts/forgeward-scan.sh`, which
  keeps reports on stdout, and the gate diffs the working tree before/after to prove it), and on
  all-PASS writes a pass marker — then hands off to gstack's `/ship` in one motion if `/ship`
  is installed, or tells you to push and open the PR yourself if it is not. The marker is
  written either way, so the push hook allows the push regardless.
- **Enforcement — client-specific fast feedback, and the real lock at `pre-push`:**
  1. Claude Code loads `hooks/hooks.json`. Its `UserPromptExpansion` matcher selects a typed
     ship command and blocks with exit 2 when the current code lacks a fresh PASS. The matcher
     is `^([A-Za-z0-9_]+-)?ship$`, covering `ship`, `gstack-ship`, and custom prefixes without
     catching `shipment` or `airship`.
  2. Codex loads `hooks/codex-hooks.json` through `.codex-plugin/plugin.json`. Codex ignores
     matchers for `UserPromptSubmit`, so the shared handler inspects `.prompt` itself and only
     blocks a direct `/ship` or `$ship`-style invocation. It returns Codex's
     `{"decision":"block","reason":"…"}` object; ordinary prompts are untouched.
  3. Both clients run `PreToolUse` for `Bash`. The handler accepts each client's current
     `tool_name` / `tool_input.command` payload and returns the modern `hookSpecificOutput`
     deny object. It provides two guardrails. A **best-effort reminder**: on a `git push` /
     `gh pr create` / `glab mr create`, it denies when the current checkout's branch has no fresh
     marker. A push that can only **delete** remote refs is exempt — `git push origin --delete
     <branch>` and `git push origin :<branch>` publish no code, so no reviewer could ever have
     reviewed them and no marker could attest to them; the `pre-push` hook already skips them
     for the same reason. The exemption is narrow on purpose: any second command, any shell
     metacharacter, a `sudo`/`time` prefix, or a `--delete` that is quoted or built from a
     variable all keep denying. And an **artifact guard**: it denies a scanner invoked with a drive-letter output
     path (`semgrep … -o C:/Users/…`), which in a POSIX shell is a *relative* path and writes a
     `C:` directory tree into the repo under review — untracked, matched by no common
     `.gitignore`, and committed by any `git add -A`. That guard is deliberately narrow: a
     developer's own `-o report.json` is never blocked. It reads
     command *text*, so it is leaky by design — `git -C`, quoting, a script file, an alias all
     slip past. Treat it as fast feedback, **not** the boundary. (Four security reviews confirmed
     no text-matching hook can be both bypass-proof and usable.)
  4. **`pre-push` hook — the enforcement.** `scripts/forgeward-pre-push.sh`, installed per repo
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
with the CI-gate skill (required checks + branch protection). Lifecycle hooks are intentionally
fast feedback, not a complete policy boundary: Codex does not expose every hosted tool through
`PreToolUse`, and neither client can reliably infer resolved Git refs from shell command text.

The marker pins a hash of the **reviewed code and dependencies** (`base...HEAD`), excluding
only gstack's cosmetic post-gate writes (`VERSION`, `CHANGELOG*`, `TODOS.md`) and exact
version-field-only bumps in the four version-bearing package/client manifests. Any other
manifest change, and any change to source **or dependencies** after the
gate flips the hash and forces a re-gate — a dependency added between gate and push does
**not** sail through.

## Turn on enforcement (one command per repo)

Installing or updating the plugin activates the reviewers and the in-editor **reminder** — but
that reminder is best-effort and leaky by design (see above). To actually **block** an ungated
push, install the `pre-push` hook once in each repo you want gated. From inside the repo:

```bash
export FORGEWARD_PLUGIN_DIR="/absolute/path/to/forgeward-gate"
bash "$FORGEWARD_PLUGIN_DIR/scripts/forgeward-install-pre-push.sh" .
```

Pass a path instead of `.` to gate a repo you're not in:

```bash
bash "$FORGEWARD_PLUGIN_DIR/scripts/forgeward-install-pre-push.sh" /path/to/repo
```

(The script lives in the plugin's `scripts/` dir — adjust the path if your plugins live
elsewhere.) It sets the per-repo opt-in (`git config forgeward.gate enabled`) and installs the
hook into the repo's effective hooks dir (honoring `core.hooksPath`). From then on, **any**
`git push` from that repo — Claude Code, Codex, or a plain terminal — is blocked unless the branch
has passed the Forgeward gate. Re-run it in a fresh clone and after a plugin update (git hooks aren't
cloned, and the enforcer path is baked into the installed hook).

Turn it back **off** for a repo (leaves any shared hook in place; just no-ops there):

```bash
git config --unset forgeward.gate
```

### Which layer do you want?

The three layers stack — pick per repo:

| You want… | Do this | Still bypassable by |
|---|---|---|
| A heads-up in Claude Code before an ungated push | install the plugin | anything (it's only a reminder) |
| A heads-up in Codex before an ungated push | install the plugin and trust its hooks with `/hooks` | anything (it's only a reminder) |
| Ungated pushes **blocked** on your machine | run the installer above (per repo) | `git push --no-verify`, or forging the local marker |
| An **unbypassable** gate for everyone, any machine | `/forgeward:ci-gate` → GitHub required check + branch protection | only a deliberate repo-admin override |

Rows 1–2 are local convenience and honest-mistake protection. The server-side check (row 3) is
the only *hard* guarantee — that's where enforcement lives when it must not be skippable.

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
gate's own suite, security scope, and honest limits are unchanged. (This sentence used to
carry an assertion count. It said 24 against a suite that is now 182 — a number whose only
job is to say "unchanged" is a number nobody re-measures, so the counts live in one place,
below.)

## Install

Clone once for local development or to install the standalone Git hook:

```bash
git clone https://github.com/androsland/forgeward-gate.git
cd forgeward-gate
export FORGEWARD_PLUGIN_DIR="$PWD"
```

### Claude Code

Load the checkout for one session:

```bash
claude --plugin-dir "$FORGEWARD_PLUGIN_DIR"
```

Or install it from the Claude marketplace:

```bash
claude plugin marketplace add androsland/forgeward-gate
claude plugin install forgeward@forgeward-gate
```

Claude reads `.claude-plugin/plugin.json`, auto-discovers `hooks/hooks.json`, registers the
namespaced skills (`/forgeward:gate`, `/forgeward:audit`, `/forgeward:ci-gate`), and registers
the reviewer definitions under `agents/`.

### Codex

Install the current checkout through an isolated/local marketplace:

```bash
codex plugin marketplace add "$FORGEWARD_PLUGIN_DIR"
codex plugin add forgeward@forgeward-gate
```

After this dual-client package has been published to the repository named in its manifests,
the remote marketplace form is:

```bash
codex plugin marketplace add androsland/forgeward-gate
codex plugin add forgeward@forgeward-gate
```

Codex reads `.agents/plugins/marketplace.json`, then `.codex-plugin/plugin.json`. That manifest
points to `hooks/codex-hooks.json`, so Codex never consumes Claude's
`UserPromptExpansion` definition. Shared skills are available through Codex's skill UI and
`$gate`, `$audit`, and `$ci-gate` invocation forms.

Codex supplies `PLUGIN_ROOT` to the plugin's lifecycle **hook processes**. Ordinary shell
commands issued while following a skill do not inherit that hook environment. Forgeward's
skills therefore derive the installed root from the exact `SKILL.md` path Codex includes in
its skills catalog, verify the plugin layout, and use that absolute path for bundled scripts.
They do not search for or pin a versioned cache directory.

### Codex hook trust

Codex does not execute newly installed non-managed hooks until you explicitly trust their exact
definitions. Start a Codex session, run `/hooks`, review Forgeward's two command hooks and approve
them. If the hook definitions change, their hash changes and Codex asks for trust again. The
one-off `--dangerously-bypass-hook-trust` flag is not the recommended setup.

Claude Code does not use this separate Codex hook-trust store; its normal plugin installation
approval applies. In either client, the **standalone `pre-push` enforcement hook is not installed
automatically**. Install it per repository as described in
[Turn on enforcement](#turn-on-enforcement-one-command-per-repo).

Lifecycle handlers read JSON with `jq` if present, then `python3`; if neither exists they fail
open so a broken feedback hook cannot wedge the client. The Git `pre-push` hook independently
checks the resolved refs and marker at push time, but it also fails open with an explicit warning
if neither JSON parser or its diff-hash helper is available.

## Validation / what's tested

**Automated suites — `npm test`.** Six suites, all framework-free, all exercising the
**real plugin scripts** in `scripts/` and `ci/` (not mocks or copies) against throwaway git
repos: `gate-test.sh` (234), `pre-push-test.sh` (15), `version-check-test.sh` (51),
`dual-client-test.sh` (35), `rules-test.sh` (39), `transcript-audit-test.sh` (37) — 411
assertions. Every suite prints
its own count on its last line, so these are re-measurable rather than taken on trust; the
numbers here were last re-measured against a full run at 0.26.0, and `package.json`'s `test`
script, not this paragraph, is the roster.

**External tools, stated because `npm test` is not self-contained.** `python3` is a hard
requirement of `ci/check-version-monotonic.sh`: it reads the four version-bearing manifests with the stdlib
`json` module and has **no `jq` fallback by design**, because two readers of the same JSON
that can disagree is a divergence this repo shipped once already (`DECISIONS.md`). A box
without it gets a named failure, never a quiet skip. `semgrep` is optional — without it
`rules-test.sh` prints `1..0 # SKIP` and says the rulepack was **not** verified, which is a
green run that checked less than it appears to. Both differ from the **hooks**, which read
JSON with `jq` *or* `python3` and fail open when neither exists: for the hooks `python3` is
optional, for the version check it is not.

`test/gate-test.sh` (234 assertions) — the in-editor layer:
- **Deny when there's no fresh PASS marker** — `git push`, `gh pr create`, and
  `glab mr create` are all reminded; a typed `/ship` is halted at expansion (exit 2).
- **A delete-only push is allowed, and only that** — `--delete`, `-d` and `:refspec` forms pass;
  `git push origin :x main` and `git push --tags origin :x` still deny, because both were
  observed publishing alongside the deletion. Compound commands (`… --delete x && git push`),
  prefixes, quoted flags, and `$`-built arguments all deny, and the exemption is refused
  outright when the residue is untrusted (broken `awk`, or a command bearing `$(`). A
  command containing any `'`, `"` or `\` is refused too: the quote-blanking scanner
  substitutes a space rather than deleting, so it can hand the classifier a word boundary
  bash never had — `git push /pub/repo'':x.git` is one repository argument, and the gap
  let it publish. And every argument token must match `^[A-Za-z0-9_.:/@+=-]+$` — an
  allowlist, because `read -ra` does not glob, so `git push [os]* :newcode` is one token
  to the matcher and several words to bash (it published a branch the text never named).
  Both were found by this branch's own security review and reproduced against a real
  remote, which is why the token test fails closed on constructs nobody has thought of yet.
- **Allow on a fresh PASS marker**; **version-bump invariance** (a version-field-only bump keeps
  the marker); **dependency change** and **stale code** force a re-gate.
- **Non-publish commands are never touched**; **outside a git repo it fails open**.
- **Worktree honor-cd** — `cd <worktree> && git push` is evaluated in that worktree (gated →
  allow, ungated → deny), including a single-quoted spaced path.
- **Ship matcher**.
- **Base detection resolves the publish boundary, not a local branch name** — behind-remote
  (over-scoping), ahead-of-remote (the false-PASS direction: a bare base hides unpushed base
  commits the push will publish), no remote at all, detached HEAD, a fork tracking a non-`origin`
  upstream, a base with no remote counterpart, a local branch tracking a differently-named remote
  branch, one-line stdout with the drift note on stderr, and `--name`.
- **Reviewers cannot write into the repo they audit** — a scanner invoked with a drive-letter
  output path is denied (`C:/…` is *relative* in a POSIX shell, so it lands as a directory tree at
  the repo root); a deliberate `-o report.json`, `-o /tmp/x.json`, or a drive path in a non-scanner
  command stay allowed; the scan wrapper refuses output flags and reports (never deletes —
  under Git Bash `rm -rf "C:"` resolves to the **drive root**) anything a scan leaves behind; the
  workspace guard catches whatever the text-level guards can't see. The live control asks the
  platform whether the contamination is even stageable before asserting — a POSIX-only test would
  pass while the bug remained, because the bug *is* the path translation.
- **A ported file's provenance and a skill's declared tool list are checked from the file** —
  `/forgeward:audit` must enumerate at least three `allowed-tools` and none of them may be a
  code-editing tool, and it must record a `source-path`, a 40-hex `source-commit` and a 64-hex
  `source-sha256`. The non-empty floor is the assertion, not decoration: a *missing*
  `allowed-tools` key grants every tool, so `grep -q Write` alone passes on the worst case.
  Each item is normalized before it is judged, because `- Write `, `- Write  # note`,
  `- "Write"` and `- Write(*)` are four legal spellings a whole-line match misses — all four
  are mutation-tested. What this does **not** establish is that the audit cannot write:
  `Bash` remains on the list, so the no-write property rests on the prompt and on the gate's
  worktree snapshot, and this assertion must not be cited as covering it.

`test/pre-push-test.sh` (15 assertions) — the enforcement layer, driven exactly as git drives
it (refs on stdin, so no command parsing):
- gated ref allowed; ungated ref blocked (names it); multi-ref one-ungated blocked / all-gated
  allowed; branch deletion allowed; stale blocked; version-only bump allowed; tag allowed; **a
  marker written inside a linked worktree honored from the main checkout** (the original bug);
  and the **opt-in no-op** (a repo without `forgeward.gate` is never blocked — safe as a global
  hook). An end-to-end harness additionally confirms real pushes via `git -C`, `git  push`,
  `"git" push`, and `g\it push` are all blocked while ungated, and `--no-verify` bypasses.

`test/version-check-test.sh` (51 assertions) — `ci/check-version-monotonic.sh`, the CI
direction check. What it pins is a **comparator**, and a comparator's failure mode is
answering the wrong way rather than crashing, so the suite is built in pairs: for each rule,
the case that must FAIL beside the neighbouring case that must PASS. An assertion that only
ever checks the fail side cannot tell a working comparator from one that refuses everything,
and a green "refuses everything" is how a required check gets deleted a week later.

`test/dual-client-test.sh` (35 assertions) — the package split, reviewer runtime policy,
and current hook contracts. It enumerates every canonical reviewer, pins Claude's
Sonnet/medium frontmatter and Codex's Terra/medium isolated spawn contract, verifies the
minimal complete-rubric/repository/diff launch context and preserves the non-native
fallbacks. It also covers Claude `UserPromptExpansion`, Codex `UserPromptSubmit` prompt inspection, representative Claude
and Codex `PreToolUse` payloads, deny/allow objects, malformed events, missing parsers, both
plugin-root variables, normal Codex skill execution without those hook-only variables,
fresh-marker allowance, four-manifest version agreement, version-only diff-hash neutrality,
and substantive Codex manifest/marketplace invalidation.

`test/rules-test.sh` (39 assertions) — the bundled Semgrep rulepack in `rules/env-config.yml`,
in three classes: **positives** (each shape the rule exists to catch fires, one per line, so a
regression names the shape it broke), **negatives** (each legitimate configuration it must
*not* fire on stays silent — the half that matters for a pack third parties install, since a
rule that fires on `process.env.X || 'default'`, the very fix it recommends, teaches people to
switch the pack off), and **blind spots** (each limit documented in the rulepack, pinned as
silent). Fixtures are generated into a scratch directory at run time and never written into
the repo: the plugin's own artifact contract applies to its own tests, and a committed `.ts`
fixture would be scanned by forgeward's gate on every subsequent PR.

`test/transcript-audit-test.sh` (37 assertions) — `scripts/forgeward-transcript-audit.sh`,
whose property under test is unusual: it must FIND credential shapes and then NOT show them.
Nearly every failure mode is an assertion about absence, and an absence assertion passes for
free on a script that crashed, printed nothing, or searched the wrong directory — so the
suite opens with a **trust check** that proves the leak assertion can fail, and every silence
check is paired with a positive control. Fixtures plant one needle in all three known
persistence channels plus an undocumented fourth, so a refactor that reintroduces a channel
list fails here rather than in someone's transcripts. It also pins the precision boundary
(`AKIA` + 15 characters must *not* match), the four exit codes, the presence of the words
UNVERIFIABLE and "rotate regardless" in a run that found nothing, and — with a deliberately
broken `stat` on `PATH` — that a platform without GNU `stat` reports its permissions count as
`UNAVAILABLE` rather than as a confident `0`.

**Live end-to-end.** Beyond the unit suite, the gate was exercised through a real Claude Code
session (see `live-test/LIVE-TEST.md`): the same `git push` was observed **denied** (no marker)
→ **succeeded** (after a PASS marker) → **denied again** once a typosquatted dependency flipped
the hash — proving the actual plugin **hook dispatched**, not just that the scripts work in
isolation. The `supply-chain-reviewer` caught the typosquat with registry evidence.

Packaging is also validated with the installed Claude CLI and with a real Codex marketplace
install under an isolated temporary `CODEX_HOME`; the cache inventory is checked for the shared
skills, hooks, scripts, reviewer definitions, and both client manifests before that directory is
removed.

**What "validated" means here (honest boundary).** Tested means *tested-as-designed* — the
deny/allow logic behaves as specified, and real pushes through the installed `pre-push` hook
are blocked/allowed as expected. It does **not** mean tamper-proof (see limit 1). This raises
the floor; it is not a sandbox.

## Three honest limits

1. **Strong, not tamper-proof — and local, not server-side.** The `pre-push` hook enforces on
   any `git push` from that machine (Claude Code, Codex, or a plain terminal), immune to command-text
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

3. **No cross-client subscription dependency.** The Claude package needs Claude Code access;
   the Codex package needs Codex access. Forgeward itself adds no paid API dependency. Optional
   gstack Codex review steps remain governed by gstack's own configuration.

## Security scope

**What forgeward covers.** The gate's `security-reviewer` fires on any code change and runs a
bundled framework-aware SAST rulepack (e.g. unprepared `$wpdb` queries that generic Semgrep packs
miss) plus injection/authz reasoning, diff-scoped. `/forgeward:ci-gate` wires **real scanners**
(Semgrep, PHPCS/WPCS, Trivy, Gitleaks) into CI and can make them a **required, merge-blocking**
check via branch protection. Between them, forgeward does static security review **and**
CI-enforced SAST merge-gating.

**One bundled pack is deliberately not security.** `rules/env-config.yml` catches two JS/TS
build-safety shapes — `??` used as an env-var fallback (it doesn't fall back on a
blank-but-present variable, the routine output of a secrets sync), and an env-dependent SDK
client built at module scope (one unset variable fails the whole build instead of one route).
`security-reviewer` runs it because it is the only component with the Semgrep plumbing and
JS/TS diff scope, and reports every finding at **Low**, tagged defense-in-depth. Low never
fails a gate on its own, so this widens what the gate *reports* and not what it *blocks*. It
is also **not** vendored into the `ci-gate` workflow: those findings are advisory, and turning
CI red on advice would break ci-gate's green-on-arrival rule.

**Honest boundaries.** This is still *static* review — no dynamic/runtime scanning (DAST, e.g.
OWASP ZAP) and no container-image scanning. The gate's `security-reviewer` is **diff-scoped**: it
reviews the change, not the whole repo, and one LLM reviewer won't match a dedicated commercial
SAST engine's recall. (One narrow exception: when the diff *redefines* an existing callable it
reads the prior definition to establish a baseline — but the finding must still land on a changed
line, and the baseline comes from source/migration history, which is a proxy for the deployed
definition rather than proof of it.) Run `/forgeward:audit` for a deep whole-repo audit — it ships
here as of 0.19.0 and needs no gstack, and `supply-chain-reviewer` owns the CVE axis itself on
every machine. Note what that does and does not buy: the audit is guaranteed present
on every machine, and **nothing verifies it was run** — no marker, no state, no check. It
is a skill you invoke, not a gate you pass. The gate's final `/ship` handoff is established standalone as of
0.8.0: with no gstack it writes the marker and hands back for a manual push instead of reporting
a handoff that did not happen. Treat the `ci-gate` CI scanners as your unskippable floor. A gate
PASS means the reviewed change is clean, not that the running application is secure.

### 0.9.2 — if you ran the gate before this release, check for exposed secrets

**Affects 0.2.0 through 0.9.1** (the line was introduced with `security-reviewer` on
2026-07-13 and never changed until now). **Fixed in 0.9.2.**

`security-reviewer`'s documented Gitleaks invocation passed the whole changed-path list to
`gitleaks dir`, which takes exactly **one** positional path. Given any other number it does
not error — it silently scans the **current directory** instead. So a scan that read as
"these two changed files" was a walk of your entire working tree, including untracked,
gitignored files. If your repo has a local `.env` or any other untracked credential file,
its plaintext values may have been read and written into the reviewer subagent's
**persisted transcript**.

**Where to look.** Those transcripts live outside your repo, so nothing in git, in
forgeward, or in any cleanup this plugin performs has touched them. **Claude Code's own
cleanup does** — read "an empty result can also mean the evidence is already gone" below
before you take a search that finds nothing as reassurance.

There are **at least three** persistence channels, and that count is a floor rather than a
total — the third was found by running the audit script below over a real machine, after two
revisions of this notice had confidently enumerated two:

```
~/.claude/projects/<project-slug>/<session-uuid>/subagents/agent-*.jsonl
~/.claude/projects/<project-slug>/<session-uuid>/tool-results/<id>.txt
~/.claude/projects/<project-slug>/<session-uuid>.jsonl          <- the parent session itself
```

Measured on one machine, over the ten prefixed shapes below: **20 hits — 14 under
`subagents/`, 1 under `tool-results/`, 5 at the top level**. A quarter of them sat outside
both channels this notice used to name. (A `memory/` directory exists alongside these and
held no hit in that run, which is not evidence that it cannot.)

The rule that survives the correction is the one already stated above and below: **scope by
path, never by channel.** `grep -r` from `~/.claude/projects/` finds all three precisely
because it was never told about any of them. A channel list is a filter wearing a different
hat, and it fails the same way — silently, on the channel nobody has thought of yet.

A large tool result is **truncated in the JSONL at 30 000 characters** and written in full
to `tool-results/`, with the transcript keeping only a `persistedOutputPath` pointer. The
`.txt` copy can therefore hold key material the `.jsonl` copy does not — measured on the
machine this was found on: 277 such files, two matching the pattern set below, and one of
those holding a private key absent from the truncated JSONL beside it. They also carry
weaker permissions: on that machine **279 of 279** `tool-results/*.txt` were mode 0644,
against **1878 of 1879** transcripts at 0600 — the lone exception being a transcript that
was itself 0644. So the copy easiest to miss is, as a rule, also the copy any local account
can read. Those are counts from one machine, not a guarantee about yours.

Every command below therefore searches `~/.claude/projects/` with **no `--include` filter**
— the path does the scoping, and an extension list is exactly the narrowing that turns a
real hit into an empty result. Revisions of this notice before 0.10.1 carried
`--include='*.jsonl'` and could not match a `.txt` at all; if you ran one of those commands,
run these again.

Note the **session-uuid** level — a glob that omits it (`projects/*/subagents/`) matches
nothing and exits `No such file or directory`, which reads exactly like "clean". Search
recursively from `projects/` instead and let the depth take care of itself.

**This repo ships the whole procedure as a script**, so you do not have to paste the
commands below:

```bash
scripts/forgeward-transcript-audit.sh          # every project on the machine
scripts/forgeward-transcript-audit.sh --urls   # add the connection-URL pass
```

It searches every project by default rather than the one you are standing in, because the
slug is keyed to the session's **launch directory** and the repo you care about may have no
slug of its own — measured on the machine this was written on, **none of 26 slugs contained
`forgeward`**, so a repo-scoped audit would have reported the repo shipping this script
clean. It prints filenames and counts only, never a matched value; it reports how many files
and session directories it searched, so an empty result has a denominator; and it ends with a
block naming what the run did **not** establish. Exit `1` means a prefixed shape matched, `0`
means none did, `2` means there was nothing to search. Read its header before trusting a
clean run — the limits are the point of it.

What follows is the same procedure by hand, kept because a security notice whose only remedy
is "run our script" is not much of a notice, and because the script is one more thing that
can be wrong.

**Redact the filenames before you paste them anywhere** — this applies to every command
below just as much as to the script, because they print the same paths. They are not the
credential, but a project slug is a directory path with the punctuation flattened, so it
carries a home-directory name and repo or client names; and the natural next move after a hit
is pasting the list into an issue, a chat, or a prompt, each of which publishes that to
someone who was not going to see it. The script prints this reminder next to each list it
emits. A command you paste into your own terminal cannot, so it is said once here, before any
of them.

(On Windows: `%USERPROFILE%\.claude\projects\…`.) `-l` prints filenames only, so this does
not put a value back on your screen:

```bash
grep -rlE \
  -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
  -e 'AKIA[0-9A-Z]{16}' \
  -e 'ghp_[A-Za-z0-9]{36}' -e 'github_pat_[A-Za-z0-9_]{20,}' \
  -e 'sk-ant-[A-Za-z0-9_-]{20,}' \
  -e 'sk-proj-[A-Za-z0-9_-]{20,}' \
  -e '[sr]k_(live|test)_[A-Za-z0-9]{20,}' \
  -e 'AIza[0-9A-Za-z_-]{35}' \
  -e 'npm_[A-Za-z0-9]{36}' \
  -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
  ~/.claude/projects/ 2>/dev/null
```

That output is a list of paths carrying your directory names — see the redaction note above
before it leaves your terminal. The same goes for each command that follows.

Then, **separately**, credentials with no distinctive prefix — a password inside a
connection URL. This is kept out of the command above on purpose: on the machine this
defect was found on it matched 201 files against 15 for all the prefixed shapes combined,
and folding it in buries the three private-key hits in two hundred `https://user:pass@`
strings from documentation. Run it second, expecting to skim:

```bash
grep -rlE -e '://[^:/@[:space:]]+:[^@/[:space:]]+@' \
  ~/.claude/projects/ 2>/dev/null
```

Every pattern is passed with `-e`, and for the PEM one that is load-bearing rather than
stylistic: it begins with `-`, so without `-e` grep parses it as a flag and errors out.

**This list is not exhaustive, and an empty result does not mean the transcripts are
clean.** It covers AWS, PEM private keys, GitHub, Anthropic, OpenAI, Stripe, Google, npm,
Slack, and passwords embedded in connection URLs. Any credential type not on that list —
and any bearer token with no distinctive prefix — will not match. Treat a clean result as
"none of *these ten* shapes", never as "nothing was exposed", and add a pattern for
whatever your own stack issues.

**An empty result can also mean the evidence is already gone.** Claude Code expires its own
transcripts: `cleanupPeriodDays` defaults to **30**, and session files older than that are
deleted at startup. The unit it reaps is the **session directory**, aged by the parent's
recency rather than by each file — so a subagent transcript can outlive the window whenever
its session stays in use, while a short-lived session's evidence is gone inside the month.
Measured on one machine: of 247 top-level session transcripts, none survived past 30 days;
of 1574 subagent transcripts, **20** were older than 30 days, alive only because their
parent session had been touched more recently. That is not hypothetical — a transcript
identified here as holding an AWS-key-shaped value was deleted the next day, at age 31,
before it could be re-examined, and the question it raised can no longer be answered.

So an empty result means **unverifiable**, not **safe**. If you ran 0.2.0 through 0.9.1 in a
repo that held an untracked credential file, rotate regardless of what these searches
return. *Blind spots in that measurement:* one machine, one Claude Code version (2.1.232),
and `cleanupPeriodDays` is user-configurable — 30 is a default, not a guarantee. None of it
was checked on Windows.

Those match credential **value** shapes. A word-based net — `SECRET`, `TOKEN`,
`PASSWORD` — is the obvious third pass, and it is published here in full for the same
reason as the other two, so that nobody hand-rolls one and drops the `-l`. But run it
**inside one project directory, not across the whole archive**:

```bash
grep -rliE -e 'SECRET|TOKEN|PASSWORD|PRIVATE_KEY|CREDENTIAL' \
  ~/.claude/projects/<project-slug>/ 2>/dev/null
```

**Get the slug from `ls ~/.claude/projects/`. Do not derive it.** It looks like the repo
path with the punctuation flattened to `-`, and that resemblance is what makes deriving it
dangerous: the slug is keyed to the directory the Claude Code **session was launched
from**, not the repo you are in. Launch from a workspace parent and every repo underneath
shares the parent's slug: run Claude Code from `~/work` and a session inside
`~/work/some-repo` writes its transcripts to `-home-you-work`, not `-home-you-work-some-repo`.
This notice was written in a repo one level below its session's launch directory, and the
derived-by-formula slug did not exist. The flattening eats dots as well, so a worktree
under `.claude/` carries a doubled dash.

That matters because **this is the one command here that can print nothing simply because
the path does not exist** — with the placeholder left in, or with a plausible slug you
constructed yourself. It exits 2, `2>/dev/null` swallows the message, and the result is
indistinguishable from a clean scan. The other four target `~/.claude/projects/` itself,
which exists as soon as Claude Code has run once, so an empty result from those is at least
a real *search* — subject to the expiry caveat above, which no command here can see around.
If this one prints nothing, check the slug against `ls` before believing it — and
if nothing in that listing matches what you expected, fall back to the four unscoped
commands, which need no slug at all.

The `-i` is not optional: without it the net is case-*sensitive*, and a transcript holding
`const dbPassword = process.env.password` does not match, while the shouty env-var form
does. Transcripts capture source and JSON, where the lowercase form is the common one — so
the case-sensitive version misses the realistic case and returns nothing, which reads as
clean. That is this notice's own original defect in a third costume.

With `-i` the net stops being a filter. Pointed at the whole of `~/.claude/projects/` on
the machine this was found on it returned **1751 of 1756** transcripts — 99.7%, because
these words appear in any conversation that so much as discusses authentication. That is
the reason for the scoped path above: this pass is only useful once you already suspect a
particular project, and even then it is a reading list rather than a result.

Scoped, though, it is still worth running, and that number is not a reason to skip it —
it is the only pass here that can catch a credential with no recognisable vendor prefix,
which is exactly the gap the ten shapes admit to. Run the value shapes for signal (15
files, fewer genuinely actionable) and this one, narrowed to the project you actually ran
the gate in, for the shapes they cannot see.

Expect false positives from all of them — test fixtures, example keys, and JWTs that are
public by design (a Supabase anon key is not a leak). The paths they print are the start
of a triage, not a verdict.

**Triage without ever rendering the value.** Every command here is `-l` on purpose, and
that property has to survive the step *after* it. Do not `cat` or `less` a matched
transcript, and do not reach for `grep -o` — `-o` prints the matched substring, and the
matched substring is the credential. Narrow by **type** instead: re-run the block above
one `-e` pattern at a time, and the filename tells you which shape matched without
rendering it — in full, for the same reason the others are in full:

```bash
grep -rlE -e 'AIza[0-9A-Za-z_-]{35}' \
  ~/.claude/projects/ 2>/dev/null
```

Keep the `-l` when you swap the pattern. Dropping it is worse than the `-o` warned against
above, not better: plain `grep` prints the **entire matching line**, so a transcript entry
comes back with the credential embedded in its surrounding context.

Check the surrounding context the same way — with another filenames-only grep against that
one file, never by opening it:

```bash
grep -liE -e 'firebase|apiKey|NEXT_PUBLIC_|measurementId' <the matched file>
```

A hit there says the `AIza…` is a browser-side key that was never secret. No hit does not
prove the opposite; it just means this shortcut did not settle it, and at that point
rotate.

Narrowing by type is normally enough to decide — `AIza…` in a file that also mentions
`firebase` or `NEXT_PUBLIC_` is a browser-side key that was never secret, while a PEM
header is not ambiguous. When it is still unclear, **rotate anyway**: rotating a
credential that turns out to be public costs a few minutes, and reading the file to avoid
that puts the value on your screen, in your scrollback, and in anything recording either.

**What to do.** **Rotate anything that appears.** Deleting the transcript afterwards is
housekeeping, not remediation — a credential that was written to disk is exposed, and only
rotation undoes that.

**What changed in 0.9.2.** The reviewer now scans the **commit range**
(`gitleaks git --log-opts="<base>...HEAD" --redact`), so untracked files are structurally
out of scope, and `forgeward-scan.sh` refuses a `gitleaks dir` target that is a directory,
a path list, or an untracked file. A **committed** `.env` is still a finding and still
fires — the line is tracked vs untracked, not the filename.

## Accepted design gaps (documented, not bugs)

- **Pre-push local mutations aren't gated.** gstack's version bump, CHANGELOG, and commit
  squash happen before the push. They're local and reversible, and `/ship` is
  idempotent-by-re-run, so recovery is native: after `/forgeward:gate` passes, re-run `/ship`.
- **gstack's pre-push Codex review dispatch is out of scope.** It's review, not publishing, and
  gstack has a native switch for it (limit 2). We don't hook or block it.
- **If neither `jq` nor `python3` is available, lifecycle and Git hooks fail open.** They allow
  the client action or push rather than wedging Claude Code, Codex, or Git; the Git hook prints
  that enforcement is unavailable. Install `jq` or `python3`. With a parser present, the
  standalone Git `pre-push` hook is the client-independent enforcement boundary and validates
  resolved refs rather than shell text.

## License

MIT — see [LICENSE](LICENSE).

Five of the quality reviewers embed checklist text copied verbatim from gstack, and
`/forgeward:audit` adapts gstack's `/cso` audit phases. gstack is separately MIT and
separately copyrighted. MIT wants its notice to travel with a substantial copy, and a
`source-commit` pointer is not a notice, so gstack's is
reproduced in full in [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md) alongside the
list of which files carry it. Nothing generates that file and nothing checks it: it
covers source copied *into* this tree, which is the one category a lockfile cannot
see, so adding or dropping a ported rubric means editing it by hand in the same
commit.
