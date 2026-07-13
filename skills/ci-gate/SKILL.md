---
name: ci-gate
description: Detect a repo's real stack, draft the CI it's missing (test/lint/e2e AND security scanning), flag what can't yet run green, then — the part that actually protects prod — offer to make those checks required via branch protection. Drafting is advisory (files you review and commit); enforcement is one explicit, confirmed step. Absorbs the old readiness drafter and adds security scanning + enforcement. GitHub Actions is the canonical path; other providers are adapted. Writes files; changes branch protection only on an explicit yes.
argument-hint: "[optional path — defaults to the repo root]"
disable-model-invocation: true
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - AskUserQuestion
---

# /forgeward:ci-gate — draft the CI, then enforce it

The old `readiness` skill drafted a CI file and walked away — it "gated nothing, blocked
nothing." That is where a SQL-injection-class change reaches prod on a green PR. `ci-gate`
keeps the half of `readiness` that was real engineering — evidence-based stack detection
and **green-on-arrival** drafting (never emit a step that would fail in CI) — and adds the
half it was missing: it drafts the **security** pipeline too, and it offers to make the
checks **required** so a red scan blocks the merge for everyone.

Two phases, clearly separated:
- **Draft (advisory, default).** Detect the stack, write the CI that's missing, report the
  gaps. You review and commit the files.
- **Enforce (explicit, confirmed).** Turn the checks into required status checks via branch
  protection. This changes shared repo settings, so it is **never automatic** — always a
  confirmed yes, even with admin.

## Core rules (read before doing anything)

1. **Evidence AND runnability — green-on-arrival.** Emit a step only if the command both
   **exists** as a real script (cited `file:line`, the lockfile decides the package manager)
   AND **can plausibly run green in clean CI as-drafted**. A real script that would fail in CI
   (lint with no ESLint config; a test/e2e step needing a DB, secrets, or a booted backend) is
   flagged **`[Owner]`, never emitted red.** A green-looking workflow that's red on arrival is
   worse than no CI — that is the bug this skill exists to kill.
2. **Enforcement is confirmed, never silent.** Having admin means you *can* set branch
   protection, not that you may do it without an explicit yes.
3. **Never clobber existing CI.** A workflow that already runs the project's checks on push/PR
   is CI — mark it Covered, offer a supplement as a diff, never overwrite.
4. **Detect, don't impose.** Secrets manager, build step, non-Node runtimes, provider — surface
   them as decisions; don't force a tool the repo doesn't use.

**Scope:** `$ARGUMENTS` if a path was given, else the repo root. State it in one line.

## Step 0 — Detect the real default branch

A workflow with `branches: [main]` on a `master` repo silently never runs on push.

```bash
DEF=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
[ -z "$DEF" ] && git show-ref --verify --quiet refs/heads/main   && DEF=main
[ -z "$DEF" ] && git show-ref --verify --quiet refs/heads/master && DEF=master
[ -z "$DEF" ] && DEF=$(git symbolic-ref --short HEAD 2>/dev/null)
echo "DEFAULT_BRANCH:${DEF:-main}"
```

Call it `<default-branch>` — the workflow's `push:` trigger and the branch enforcement gates.
`pull_request:` stays unfiltered. Record the evidence for the report.

## Step 1 — Detect the CI provider

| Marker in repo root / remote | Provider | Files this skill manages |
|------------------------------|----------|--------------------------|
| `.github/` or github.com remote | GitHub Actions (canonical) | `.github/workflows/ci.yml`, `.github/workflows/forgeward-security.yml` |
| `.gitlab-ci.yml` / gitlab remote | GitLab CI | jobs merged into `.gitlab-ci.yml` |
| `bitbucket-pipelines.yml` | Bitbucket | steps in `bitbucket-pipelines.yml` |
| `.circleci/config.yml` | CircleCI | jobs in `.circleci/config.yml` |
| `azure-pipelines.yml` | Azure | stages in `azure-pipelines.yml` |

GitHub Actions is fully templated below. For any other provider, generate the equivalent from
the same commands and say it's adapted — ask the user to check runner image and cache. If NO
provider is found, offer the Step 7 local-hook fallback and say plainly it's skippable.

## Step 2 — Detect the real stack (evidence only, never template defaults)

### 2a. Package manager — the lockfile decides

```bash
ls pnpm-lock.yaml bun.lockb bun.lock yarn.lock package-lock.json 2>/dev/null
```

| Lockfile | PM | setup | install | run | playwright |
|----------|----|-------|---------|-----|-----------|
| `pnpm-lock.yaml` | pnpm | `pnpm/action-setup@v4` **before** setup-node, `cache: pnpm` | `pnpm install --frozen-lockfile` | `pnpm run <s>` | `pnpm exec playwright install --with-deps` |
| `bun.lock(b)` | bun | `oven-sh/setup-bun@v2` | `bun install --frozen-lockfile` | `bun run <s>` | `bunx playwright install --with-deps` |
| `yarn.lock` | yarn | setup-node `cache: yarn` | `yarn install --frozen-lockfile` | `yarn <s>` | `yarn playwright install --with-deps` |
| `package-lock.json` | npm | setup-node `cache: npm` | `npm ci` | `npm run <s>` | `npx playwright install --with-deps` |
| none | npm (note it) | setup-node | `npm install` | `npm run <s>` | `npx playwright install --with-deps` |

No `package.json` at all → not a Node/TS project: emit a labeled skeleton for the detected
runtime (Gemfile→Ruby, `pyproject.toml`/`requirements.txt`→Python, `go.mod`→Go, `Cargo.toml`→Rust)
and flag "fill the install/test steps." Do not guess that runtime's commands.

### 2b. pnpm needs a version — a bare `pnpm/action-setup@v4` FAILS (`No pnpm version is specified`)

```bash
grep -nE '"packageManager"|"pnpm"' package.json; head -1 pnpm-lock.yaml
```

Resolve in order: (1) `packageManager: "pnpm@X.Y.Z"` present → emit the action **bare** (it reads
the field; a disagreeing `version:` errors). (2) only `engines.pnpm` → `with: { version: <highest
concrete major> }` + an `[Owner]` line to add `packageManager`. (3) only lock `lockfileVersion` →
pin a compatible major (e.g. `version: 10`) + same `[Owner]`. (4) nothing → pin a recent major
with a visible note. Never emit a bare action-setup on a repo lacking `packageManager`.

### 2c. Node version

`engines.node` → `.nvmrc`/`.node-version` → fallback. Pick a concrete **currently-maintained LTS**
the range allows (mid-2026: prefer **22**; **20** is maintenance). If a pin is near/past EOL, honor
it but flag "Node `<v>` nearing EOL — bump when you can." Record which source decided it.

### 2d. Commands — read the REAL scripts (the bug-killer)

Authoritative order: (1) `CLAUDE.md` `## Testing` section if it names commands, (2) `package.json`
`scripts{}`.

```bash
[ -f CLAUDE.md ] && sed -n '/## Testing/,/^## /p' CLAUDE.md
cat package.json
```

A script is a **candidate** only if its key exists, and must pass the runnability gate (2e):
- **typecheck** — key `typecheck`/`type-check` or a `tsc`-only script (no runtime env → emit when present).
- **lint** — key `lint`; subject to the ESLint-config gate.
- **unit test** — prefer `test:int`/`test:unit`, else `test`; subject to the test-env gate.
- **e2e** — `test:e2e`/`e2e`/`test:playwright`; subject to the e2e gate (2e).

Quote each chosen script's value as a trailing comment on the `run:` line so the real command shows.

### 2e. Runnability gate — would this candidate pass in clean CI?

Emit only if it can run green as-drafted; otherwise **do not emit — add `[Owner]` with the exact blocker.**

- **lint → needs an ESLint config** (`.eslintrc*`, `eslint.config.*`, or `eslintConfig` in package.json).
  A `next lint`/`turbo lint` with no config triggers an interactive prompt and fails in CI →
  `[Owner: add an ESLint config before lint can run in CI]`.
- **unit/integration → check it doesn't need a backend.** Pure unit (jsdom, no DB) emits fine. An
  integration suite (`*.int.*`/`integration`, hits API routes, needs a DB, doppler-wrapped without a
  token) is red without env → `[Owner: integration tests need a test DB/env in CI]`.
- **e2e / Playwright → three-way decision** (read deps/env **and the e2e config's own wiring** —
  inspect by KEY/PATTERN name only; never read real `.env`/`.env.local` or echo a secret value):
  ```bash
  grep -nE 'DATABASE_URL|DATABASE_URI|MONGO|POSTGRES|PAYLOAD_SECRET|PRISMA' .env.example 2>/dev/null
  grep -nE '@payloadcms|prisma|drizzle|typeorm|mongoose|"pg"' package.json 2>/dev/null
  grep -nE 'webServer|command:|process\.env\.[A-Z_]+|SERVICE_ROLE|localhost|127\.0\.0\.1|throw|mailpit|MAILPIT|supabase (start|up)|globalSetup|storageState' playwright.config.* cypress.config.* 2>/dev/null
  ```
  1. **Runs green as-is** (no boot, or boots with no required env, or a test-env is committed) → emit a plain e2e job.
  2. **Needs env a repo Variable/Secret can supply** (boots against a *hosted* service via URL+key, or just app config) → emit a **gated, self-skipping** e2e job (2e.1).
  3. **Needs infra CI can't provide** → **hard-flag `[Owner]`, emit nothing.** Triggers: a real DB the
     app boots against (`DATABASE_URL` + a DB adapter, or a seeded non-prod DB); OR the e2e config
     **unconditionally** demands local infra (a top-level throw unless the URL is `localhost`, a
     `*_SERVICE_ROLE_KEY` required to boot for all specs, a hard `globalSetup`/mailpit/`supabase start`).
     A local-infra requirement **gated** behind an auth/mode flag with a public default suite is case 2,
     not 3. When you can't tell conditional-vs-unconditional, **don't silently gate** — report what you
     found, ask, and default to hard-flag. The test that splits 2 from 3: *can a settable Variable/Secret
     make e2e pass with no extra infra?* Yes → gate; a connection string or unconditional local stack → hard-flag.

#### 2e.1. The gated self-skipping e2e job (case 2)

Skips (not fails) until the activating Variable is set, so CI is green-by-default and runs the moment it's configured:

```yaml
  e2e:
    runs-on: ubuntu-latest
    if: ${{ vars.<ACTIVATING_KEY> != '' }}          # green-by-default: skips until set
    env:
      <PUBLIC_KEY>: ${{ vars.<PUBLIC_KEY> }}         # public-by-design (URL, anon/publishable key)
      <SECRET_KEY>: ${{ secrets.<SECRET_KEY> }}      # real secret (token, service key)
    steps:
      - uses: actions/checkout@v4
      # <PM setup per 2a/2b>  (+ dopplerhq/cli-action@v3 if doppler — see 2f)
      - run: <install>
      - run: <pm> exec playwright install --with-deps
      - run: <pm> run test:e2e
```

Gate on the single value whose presence means "this is wired" (usually the URL); public values
(`NEXT_PUBLIC_*`, anon keys) from `vars.*`, real secrets from `secrets.*`. Report the exact
Variables/Secrets to set. Case 3 → emit nothing; a gated job whose var can't make e2e pass is dead config.

### 2f. Secrets manager — detect, never impose (Doppler guard)

```bash
ls doppler.yaml .doppler 2>/dev/null; grep -lE '"[^"]*":\s*"[^"]*doppler' package.json 2>/dev/null; [ -f CLAUDE.md ] && grep -i doppler CLAUDE.md | head -1
```

- **Script self-wraps** (`"test:int": "doppler run -- vitest run"`) → do NOT add another `doppler run --`
  (double-wraps). Run as-is; add `env: { DOPPLER_TOKEN: ${{ secrets.DOPPLER_TOKEN }} }` to **only** those steps.
- **Detected but scripts bare** → prefix only test/e2e run commands with `doppler run --` + the token; leave lint/typecheck bare.
- **In every job that runs a doppler step, install the CLI first** — `- uses: dopplerhq/cli-action@v3` (not preinstalled on ubuntu-latest).
- Add an `[Owner]` line: add `DOPPLER_TOKEN` to Actions secrets. **Not detected → emit nothing about secrets.**

## Step 3 — Draft the general CI pipeline (test / lint / e2e)

Don't-clobber guard first — detect CI by intent, not a keyword allowlist:

```bash
for wf in .github/workflows/*.y*ml; do
  [ -f "$wf" ] || continue
  grep -qE 'pull_request|push' "$wf" || continue
  grep -qE 'run:.*(pnpm|npm |npx|yarn|bun |make|turbo|nx |just |task |bazel|cargo|go (test|build)|mvn|gradle|composer|bundle|rake)' "$wf" \
    && echo "CI-DETECTED:$wf"
done
```

Any workflow that triggers on push/PR and runs the project → mark `ci-workflow` **Covered**, cite it,
offer a supplement as a diff, never overwrite. Never overwrite `.github/workflows/ci.yml` regardless.
When uncertain, treat as Covered (a false-Covered is recoverable; a false-absent overwrites hand-tuned work).

Only when NO workflow runs the project's scripts (and no `ci.yml` exists) → assemble it:

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
      # <PM setup per 2a>
      - run: <install>
      # one run: per emitted script (typecheck? lint? unit) — each commented with the real command
  # e2e job only per the 2e decision (plain, or gated self-skipping); split e2e into its own job after
  # a browser-install step when playwright/cypress config exists.
```

Print the full file inline regardless of whether it was written.

## Step 4 — Draft the security pipeline (this is the part readiness deferred)

Security scanning is now **in scope**, not deferred. CI runners have no forgeward install, so vendor the rulepack into the repo:

```bash
mkdir -p .forgeward/rules
cp "${CLAUDE_PLUGIN_ROOT}/rules/wp-security.yml" .forgeward/rules/wp-security.yml
```

Pick the scanner set from the stack (base set every repo; WPCS added for WordPress/PHP), then write
`.github/workflows/forgeward-security.yml` (never overwrite an existing security workflow — supplement instead):

```yaml
name: forgeward-security
on:
  pull_request:
  push: { branches: [<default-branch>] }
permissions: { contents: read }
jobs:
  sast:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Semgrep (forgeward rulepack + security-audit)
        uses: returntocorp/semgrep-action@v1
        with:
          config: >-
            .forgeward/rules/wp-security.yml
            p/security-audit
            <p/php | p/javascript | p/python | p/golang — match the stack>
      # WordPress/PHP only — the WP-native SAST (unprepared $wpdb, nonce, sanitize, escape):
      - name: PHPCS + WordPress Coding Standards
        run: |
          composer global require --no-interaction squizlabs/php_codesniffer wp-coding-standards/wpcs phpcsstandards/phpcsutils dealerdirect/phpcodesniffer-composer-installer
          export PATH="$PATH:$HOME/.composer/vendor/bin"
          phpcs --standard=WordPress-Extra,WordPress.Security --extensions=php --report=full .
  secrets-deps:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - name: Gitleaks
        uses: gitleaks/gitleaks-action@v2
      - name: Trivy (vuln + secret + misconfig)
        uses: aquasecurity/trivy-action@master
        with: { scan-type: fs, scanners: vuln,secret,misconfig, severity: HIGH,CRITICAL, exit-code: "1" }
```

Drop the PHPCS job for non-PHP stacks; pin action SHAs if the repo's other workflows do. Show the full
file and get approval (AskUserQuestion) before writing.

## Step 5 — Report (Covered / Missing / Deferred / [Owner])

Print inline by default; write a file only if the user asks (`forgeward/reports/…` if `forgeward/`
exists, else `ci-gate-report.md`). Buckets:

```markdown
# CI gate pass
Scope: <scope>  ·  Default branch: <default-branch> (<evidence>)  ·  Provider: <provider>

## Covered      — <check> already in place (<file:line>)
## Missing      — drafted: ci.yml (steps: <list>), forgeward-security.yml (scanners: <list>)
## Deferred     — conscious skips (e.g. build step)
## [Owner]      — real-but-not-yet-runnable, flagged not emitted (lint needs config; e2e needs a DB;
                  add DOPPLER_TOKEN; **enable branch protection — offered in Step 6**)
## Detected facts (evidence table): default branch, PM, node, each script → file:line
```

## Step 6 — Enforce: make the checks required (the part that actually blocks prod)

A workflow that runs is not a workflow that blocks. To gate prod, the checks must be **required** on
`<default-branch>` via branch protection. This changes shared repo settings — everyone's merges start
blocking on a red check the moment it lands — so it is **always confirmed, never automatic**, even
with admin.

1. Read current protection so you can show the delta and preserve what exists:
   `gh api repos/{owner}/{repo}/branches/<default-branch>/protection` (404 = none yet).
2. Show the user the exact change: which branch, the contexts to require
   (`forgeward-security / sast`, `forgeward-security / secrets-deps`, and the CI job contexts if `ci.yml`
   was drafted), and every existing rule you'll keep. Then ask via AskUserQuestion. Get an explicit yes.
3. **Only on yes, and only if the user has admin**, merge (don't replace) the required checks:

```bash
gh api -X PUT "repos/{owner}/{repo}/branches/<default-branch>/protection" --input - <<'JSON'
{ "required_status_checks": { "strict": true, "contexts": ["forgeward-security / sast", "forgeward-security / secrets-deps"] },
  "enforce_admins": false, "required_pull_request_reviews": null, "restrictions": null }
JSON
```

   Carry forward every rule the step-1 read returned — never blow away existing protection.

If the user declines or lacks admin, do NOT call the API — print the exact Settings → Branches steps
and the context names. Handing it over as a manual step is a fine outcome; flipping team-wide settings
without a yes is not.

## Step 7 — No-CI fallback + commit

- **No provider (Step 1):** offer a `.git/hooks/pre-push` running the same scanner commands, blocking on
  High/Critical. Say plainly it's bypassable (`--no-verify`, a fresh clone) — a stopgap, not the guarantee real CI branch protection gives.
- **Commit:** summarize what was drafted, scanned, and whether enforcement succeeded or needs the user's
  admin action. Then ask (AskUserQuestion) whether to commit, on a `chore/…` branch — never straight to
  `<default-branch>`. Commit only on approval; never push unless asked.

## Rules

- **Draft advisory, enforce confirmed.** Files are drafts you review; branch protection is a
  confirmed yes every time (even with admin). If declined or not admin, hand over the manual steps.
- **Green-on-arrival.** A step ships only if it exists AND runs green as-drafted; everything else is `[Owner]`, never red.
- **Never clobber existing CI**; the lockfile decides the PM; detect don't impose; works on a bare repo.
- **Vendor the rulepack** — CI has no plugin install, so the rules live in the repo.
- **Provider honesty** — GitHub Actions is canonical; other providers are adapted, tell the user to verify runner/cache.
