---
name: readiness
description: Advisory baseline-conformance helper, CI-first. Detects the project's REAL stack from package.json scripts + the lockfile (never template defaults), then DRAFTS a GitHub Actions CI workflow using the real commands and the repo's real default branch, and prints a covered/missing/deferred/[Owner] report inline (writes a file only on request). Advisory — it drafts for you to review and commit. It gates nothing, blocks nothing, and runs no reviewers — enforcement stays in the gate. Use to bring an existing or bare repo toward the baseline, starting with CI.
argument-hint: "[optional path — defaults to the repo root]"
disable-model-invocation: true
allowed-tools:
  - Read
  - Grep
  - Glob
  - Write
  - Bash(git *)
  - Bash(ls *)
  - Bash(cat *)
  - Bash(find *)
  - Bash(date *)
  - Bash(mkdir *)
  - Bash(test *)
  - Bash(head *)
---

Run a **baseline conformance pass** over the repo and report where it stands against the
project standard (`PRODUCTION-READINESS.md` / the baseline in `CLAUDE.md`). **Scope:**
`$ARGUMENTS` if a path was given, otherwise the repo root. State the scope in one line.

This is **advisory**, not a gate. By default you write exactly **one** file — the **draft CI
workflow** — and print the report **inline**; you write a `readiness-report.md` only if the
user asks (Step 1). You do **not** edit application code, you do **not** run the reviewer
subagents, and you do **not** call `/ship` or block anything. Enforcement lives in the gate
(`/forgeward:gate` + its push hook); this skill only *prepares* conformance, it never enforces.

The report header reads **"Baseline conformance pass (CI-first)"**. Phase 1 ships one rich
check — `ci-workflow` — plus the report harness. The check registry (Step 2) is built so
later checks slot in as new rows without touching this one.

## Core rule: evidence AND runnability

Two tests must both pass before a step is emitted:

1. **Evidence** — the command is a real script that exists. Every detected fact is backed by a
   real file, cited `file:line`. No `typecheck` script → no typecheck step. The lockfile decides
   the package manager; a guessed `npm ci` on a pnpm repo is the bug this skill kills.
2. **Runnability** — the command can plausibly **run green in a clean CI environment
   as-drafted**. A real script that would fail in CI — `lint` with no ESLint config (interactive
   setup prompt), or a `test`/`e2e` step that boots the app or needs env/secrets/a live backend
   CI can't provide — is **flagged `[Owner]`, never emitted red.**

A step that fails test 1 → omit silently (nothing to run). A step that passes test 1 but fails
test 2 → **flag it `[Owner]` with the precise blocker; do not emit it.** A green-looking
workflow that's red on arrival is *worse than no CI* — the exact outcome this skill exists to
prevent. When a fact can't be proven, mark it **Missing** or **[Owner]** — never template-fill.

## Step 0 — Detect the real default branch

A workflow with `branches: [main]` on a `master` repo silently never runs on push. Detect it:

```bash
DEF=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
[ -z "$DEF" ] && git show-ref --verify --quiet refs/heads/main   && DEF=main
[ -z "$DEF" ] && git show-ref --verify --quiet refs/heads/master && DEF=master
[ -z "$DEF" ] && DEF=$(git symbolic-ref --short HEAD 2>/dev/null)
echo "DEFAULT_BRANCH:${DEF:-main}"
```

Call the result `<default-branch>`. Use it in the workflow's `push:` trigger. `pull_request:`
stays unfiltered (it fires for PRs targeting any base). Record the evidence (`origin/HEAD`, or
which local head matched) for the report.

## Step 1 — Report output: inline by default, file only on request

**Default: print the full report inline in your reply and write NO file.** The report is
advisory and regenerable by re-running the skill; writing a `readiness-report.md` into every
repo root just creates cleanup on every run. Keep repos clean by default.

**Only write a report file when the user explicitly asks** (e.g. "save the report",
"write the readiness report", a `--write-report` style request). When asked:

```bash
if [ -d forgeward ]; then mkdir -p forgeward/reports; echo "REPORT:forgeward/reports/readiness-$(date +%F).md"; else echo "REPORT:readiness-report.md"; fi
```

→ `forgeward/reports/readiness-<date>.md` if `forgeward/` already exists, else
`readiness-report.md` at the repo root. Never scaffold a `forgeward/` directory the repo
didn't already have.

This is output-only: it does **not** change detection or drafting. The drafted
`.github/workflows/ci.yml` is the real artifact and is still written to disk per Step 3
(unless CI already exists) regardless of the report mode.

## Step 2 — The check registry

| id | baseline layer | status values | automatable? | drafts |
|----|----------------|---------------|--------------|--------|
| `ci-workflow` | L7 CI/CD | covered / missing / deferred | **yes** | `.github/workflows/ci.yml` |
| *— phase 2 (not built; do not run) —* | | | | |
| `claude-md-present` | standards | covered / missing | no (flag) | — |
| `forgeward-gate-installed` | gate | covered / missing | no (flag) | — |
| `error-tracking-wired` | L12 | covered / missing / [Owner] | partial | — |
| `env-not-committed` | secrets | covered / missing | no (flag) | — |
| `healthcheck-endpoint` | observability | covered / missing / [Owner] | partial | — |

Phase 1 runs **only** `ci-workflow`. The phase-2 rows are the extension surface: each is a
self-contained `detect()` + optional `draft()` that appends a row to the same report buckets.
Adding them later does not modify the `ci-workflow` procedure or the report harness.

## Step 3 — Run the `ci-workflow` check

### 3a. Already have CI? (don't-clobber — detect by intent, bias to safe)

The guard's only job: **never overwrite a workflow that is already this project's CI.** Detect CI
by what a workflow *does* — runs the project's checks on push/PR — **not** by a keyword allowlist.
A test-runner allowlist (`test|vitest|jest|playwright|…`) is wrong: it misses a typecheck/lint-only
workflow, `make ci`, `turbo run check`, or any custom script name — and it fails to recognize this
skill's *own* lint-only output, so a re-run would clobber the workflow it just drafted.

```bash
ls .github/workflows/*.y*ml 2>/dev/null
```

**The principle: a workflow that runs this project's scripts/build on push or PR is CI — leave it
alone.** Concretely, treat a workflow as existing CI when it both triggers on `push`/`pull_request`
and runs the project via a package manager or task runner:

```bash
for wf in .github/workflows/*.y*ml; do
  [ -f "$wf" ] || continue
  grep -qE 'pull_request|push' "$wf" || continue
  grep -qE 'run:.*(pnpm|npm |npx|yarn|bun |make|turbo|nx |just |task |bazel|cargo|go (test|build)|mvn|gradle|composer|bundle|rake)' "$wf" \
    && echo "CI-DETECTED:$wf"
done
```

- **Any workflow detected → mark `ci-workflow` Covered**, cite the file(s), and **never
  overwrite**. In the report, say what it runs and offer to *supplement* missing checks as a diff
  the user applies by hand — do not write `ci.yml`.
- **Hard no-overwrite (belt and suspenders).** Never write over an existing workflow file. If
  `.github/workflows/ci.yml` already exists, it is off-limits regardless of classification —
  treat it as Covered, never overwrite the path.
- **Safe bias when uncertain.** If `.github/workflows/` holds a workflow that triggers on push/PR
  and runs *any* command you can't confidently classify → treat it as **Covered** (decline to
  draft), not absent. Under-detecting CI is the dangerous direction: a false-Covered just means
  the user drafts manually (recoverable); a false-absent overwrites hand-tuned work (destructive).
  When in doubt, don't clobber.
- **Only when NO workflow runs the project's scripts on push/PR** (and no `ci.yml` exists) →
  continue and draft a fresh `ci.yml`.

Because detection keys on "runs the project" (`pnpm run lint` matches `pnpm`), the skill now
recognizes its **own** trimmed lint-only / typecheck-only output as Covered — a re-run never
clobbers it.

### 3b. Package manager — the lockfile decides

```bash
ls pnpm-lock.yaml bun.lockb bun.lock yarn.lock package-lock.json 2>/dev/null
```

| Lockfile | PM | setup | install | run | playwright browsers |
|----------|----|-------|---------|-----|---------------------|
| `pnpm-lock.yaml` | pnpm | `pnpm/action-setup@v4` **before** setup-node, `cache: pnpm` | `pnpm install --frozen-lockfile` | `pnpm run <s>` | `pnpm exec playwright install --with-deps` |
| `bun.lock(b)` | bun | `oven-sh/setup-bun@v2` | `bun install --frozen-lockfile` | `bun run <s>` | `bunx playwright install --with-deps` |
| `yarn.lock` | yarn | setup-node `cache: yarn` | `yarn install --frozen-lockfile` | `yarn <s>` | `yarn playwright install --with-deps` |
| `package-lock.json` | npm | setup-node `cache: npm` | `npm ci` | `npm run <s>` | `npx playwright install --with-deps` |
| none | npm (note it) | setup-node | `npm install` | `npm run <s>` | `npx playwright install --with-deps` |

If no `package.json` at all, this is not a Node/TS project: emit a **labeled skeleton +
flag** for the detected runtime (Gemfile→Ruby, `pyproject.toml`/`requirements.txt`→Python,
`go.mod`→Go, `Cargo.toml`→Rust) and note "Phase 1 fully supports the Node/TS family; this
runtime gets a skeleton — fill the install/test steps." Do not guess that runtime's commands.

### 3c. Commands — read the REAL scripts (the bug-killer)

Authoritative order: (1) `CLAUDE.md` `## Testing` section if it names commands, (2) the
`scripts` block of `package.json`.

```bash
[ -f CLAUDE.md ] && sed -n '/## Testing/,/^## /p' CLAUDE.md
cat package.json
```

From `package.json` `scripts{}`, a step is a **candidate** only if its key exists. Each
candidate then passes the **runnability gate (3c.5)** before it's emitted:

- **typecheck** — key `typecheck` or `type-check` (or a `tsc`-only script). Absent → no step.
  `tsc`/`turbo typecheck` need no runtime env → emit when present.
- **lint** — key `lint`. Absent → no step. Subject to the ESLint-config gate (3c.5).
- **unit test** — prefer `test:int` / `test:unit`; else `test`. Subject to the test-env gate (3c.5).
- **e2e** — key `test:e2e` / `e2e` / `test:playwright`. Subject to the e2e-env gate (3c.5 + 3e).

Quote each chosen script's value as the proof (e.g. `"lint": "eslint ."`) and put it as a
trailing comment on the generated `run:` line, so the real command is visible in the YAML.

### 3c.5. Runnability gate — would this candidate pass in clean CI?

Before emitting any candidate, check it can run green as-drafted. If not, **do not emit it —
add an `[Owner]` line naming the exact blocker.**

- **lint → needs an ESLint config.** Emit `lint` only if a config exists: `.eslintrc*`,
  `eslint.config.*`, or an `eslintConfig` key in `package.json`.
  ```bash
  ls .eslintrc* eslint.config.* 2>/dev/null; grep -l '"eslintConfig"' package.json 2>/dev/null
  ```
  If the `lint` script is `next lint` (or `turbo lint` → `next lint`) and **no config exists**,
  `next lint` triggers an interactive setup prompt and **fails non-interactively in CI**. Do
  NOT emit the step → `[Owner: add an ESLint config before lint can run in CI]`.

- **e2e / Playwright → needs a runnable target + env.** Emit the e2e job only if it can run
  headless without secrets CI can't supply. Treat it as **NOT runnable** (flag, don't emit) when:
  ```bash
  grep -nE 'webServer|baseURL.*localhost|process\.env|SUPABASE|DATABASE' playwright.config.* cypress.config.* 2>/dev/null
  ls .env.test* .env.ci 2>/dev/null
  ```
  - the config has a `webServer` that boots the app (`dev`/`start`) **and** the app needs env
    (a populated `.env.example`, env-validation, Supabase/DB) **and** no committed test-env
    (`.env.test*`, `.env.ci`) or guaranteed secret provides it → `[Owner: e2e needs a booted
    backend + test env/secrets wired]`.
  - the e2e script needs secrets (doppler-wrapped, or references `SUPABASE_*`/`DATABASE_*`) with
    no token guaranteed → same flag.
  Only emit the e2e job when it would actually go green (e.g. a static target, a test-env is
  committed, or the suite needs no app boot).

- **unit / integration test → check it doesn't need a backend.** A pure unit suite (jsdom, no
  DB) emits fine. But an **integration** suite (files named `*.int.*`/`integration`, hits API
  routes, needs Supabase/DB, or is doppler-wrapped with no token) is red without env → flag
  `[Owner: integration tests need a test DB/env in CI]` instead of emitting it red. When genuinely
  unsure whether a unit step is self-contained, prefer emitting it but say so in the report
  ("unit tests assumed self-contained; remove if they need env").

**Net effect:** the drafted workflow contains only steps that should pass on first run.
Everything real-but-not-yet-runnable lands in `[Owner]` with the precise fix, so the user sees
the gap instead of a red check.

**Build:** Phase 1 targets the baseline's `typecheck + lint + test` exactly. If a `build`
script exists, do **not** add a build step automatically (it often needs env/secrets) — list
it in the report as a **Deferred** option ("add a build step to catch build breakage").

### 3d. Node version

`engines.node` in `package.json` → `.nvmrc` / `.node-version` → fallback. Pick a concrete
major that satisfies the declared range (prefer the highest LTS named; default **20** if only
a fallback). Record which source decided it.

### 3e. E2E browsers and job split

If `playwright.config.*` or `cypress.config.*` exists, e2e needs a browser install step, so:

1. **Granular unit script exists** (`test:int`/`test:unit`) → put typecheck/lint/unit in a
   `test` job; put e2e in its **own** `e2e` job that first runs the browser-install command.
2. **Only a bundled `test`** that itself invokes e2e → run the whole `test` inside the `e2e`
   job (after browser install), so it never fails on missing browsers. Note this in the report.
3. **No e2e config** → a single `test` job running typecheck/lint/`test`.

### 3f. Secrets manager — detect, never impose (the Doppler guard)

```bash
ls doppler.yaml .doppler 2>/dev/null; grep -lE '"[^"]*":\s*"[^"]*doppler' package.json 2>/dev/null; [ -f CLAUDE.md ] && grep -i doppler CLAUDE.md | head -1
```

- **Detected AND the script self-wraps** (the chosen script's value already contains
  `doppler run --`, e.g. `"test:int": "doppler run -- vitest run"`) → do **NOT** prefix
  another `doppler run --` (that double-wraps to `doppler run -- doppler run -- …`). Run the
  script as-is and add `env: { DOPPLER_TOKEN: ${{ secrets.DOPPLER_TOKEN }} }` to **only** the
  steps whose script embeds doppler — so the embedded `doppler run` can authenticate. Leave
  lint/typecheck steps (which don't touch doppler) without the token.
- **Detected but scripts do NOT self-wrap** (doppler.yaml/`.doppler`/CLAUDE.md names it, but
  the test scripts are bare) → prefix **only the test/e2e** run commands (the ones that
  plausibly need runtime secrets) as `doppler run -- <cmd>` and add `DOPPLER_TOKEN` env to
  those steps. Leave static steps (`lint`, `typecheck`) bare and tokenless — consistent with
  the self-wrap rule of tokening only where doppler actually runs.
- **In every job that runs a doppler-wrapped step, install the Doppler CLI first** — add
  `- uses: dopplerhq/cli-action@v3` after `setup-node`/before install. `doppler` is **not**
  preinstalled on `ubuntu-latest`, so without this the embedded/prefixed `doppler run` fails
  with `doppler: command not found`. (Confirmed against a real hand-tuned workflow.)
- Either way, add an **[Owner]** report line: add `DOPPLER_TOKEN` to the repo's Actions secrets.
- **Not detected** → emit nothing about secrets. Do **not** add a secrets manager the repo
  doesn't run. If `.env.example` shows the tests likely need env but no manager is present,
  flag it as **[Owner]** ("CI may need secrets — wire your secrets manager") instead of guessing.

### 3g. Assemble and write the workflow

Build `.github/workflows/ci.yml` from the detected facts:

```yaml
name: CI
on:
  push: { branches: [<default-branch>] }
  pull_request:
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # <PM setup block per 3b>
      - run: <install>
      # one run: per detected script from 3c (typecheck? lint? unit), each commented with the real command
  # e2e job only if 3e says so:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # <PM setup block>
      - run: <install>
      - run: <browser install>
      - run: <e2e run>
```

Write it only if 3a found no existing CI **and** no `.github/workflows/ci.yml` already exists
(never overwrite that path). Otherwise mark Covered and offer a supplement. Print the full file
inline regardless.

## Step 4 — Produce the report (inline by default; file only if asked — Step 1)

Group findings into four buckets and **print them inline**. Write a file only when the user
asked (Step 1). Phase 1 populates the buckets from `ci-workflow`; phase-2 checks append rows
here unchanged.

```markdown
# Baseline conformance pass (CI-first)
Scope: <scope>   ·   Default branch: <default-branch> (evidence: <origin/HEAD | local head>)
Date: <YYYY-MM-DD>

## Covered
- <check> — <what's already in place> (<file:line>)

## Missing  (drafted / flagged)
- **ci-workflow** — no CI ran the test suite → drafted `.github/workflows/ci.yml`.
  Detected: PM=<pm> (<lockfile>); node=<v> (<source>); steps: <list>, each from a real script.

## Deferred  (conscious decision, valid to skip for MVP)
- <e.g. build step; security-scanning CI per IDEAS.md>

## [Owner]  (real scripts that can't yet run green in CI — flagged, NOT emitted red)
- <e.g. lint: `next lint` has no ESLint config → add one before lint can run in CI>
- <e.g. e2e: Playwright boots `pnpm dev` needing Supabase env → wire a test env/secrets first>
- <e.g. enable branch protection requiring the CI checks; add DOPPLER_TOKEN if applicable>

## Detected facts (evidence)
| Fact | Value | Evidence |
|------|-------|----------|
| Default branch | <v> | <ref> |
| Package manager | <pm> | <lockfile> |
| Node version | <v> | <source> |
| test (unit) | <cmd> | package.json:<line> |
| e2e | <cmd> | package.json:<line> |
| typecheck | present? | package.json:<line> or "absent — no step emitted" |
```

End with a one-line tally and the next action (review the drafted `ci.yml`, then commit it).

## Rules

- **Advisory.** Default is one write — the draft `ci.yml`; the report prints inline and
  becomes a file only on request (Step 1). No code edits, no reviewers, no `/ship`, no gating.
- **Evidence AND runnability.** Emit a step only if the command both **exists** as a real
  script AND **can run green in CI as-drafted**. A real script that would fail in clean CI
  (lint with no config; a test/e2e step needing env, secrets, or a booted backend) is flagged
  `[Owner]`, never emitted red. A green-looking workflow that's red on arrival is worse than none.
- **The lockfile decides the package manager.** Never guess the PM.
- **Detect, don't impose.** Secrets manager, build step, non-Node runtimes — surface them as
  conscious decisions; don't force a provider or command the repo doesn't use.
- **Never clobber existing CI.** If a workflow already runs tests, mark Covered and offer a
  supplement, don't overwrite.
- **Works on a bare repo.** No assumption that `forgeward/` or `CLAUDE.md` exists.
