---
name: gate
description: Run forgeward's enforced, read-only conformance gate before shipping. Detects which surfaces the diff touches (personal data, UI, LLM/paid-AI calls, public pages, dependency manifests, code security), fires only the relevant read-only reviewers, and on all-PASS writes the pass marker and invokes gstack's /ship in one motion. On any FAIL it reports findings and ships nothing. Use this instead of calling /ship directly.
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Agent
  - Skill
---

# /forgeward:gate — the enforced conformance gate

You are running forgeward's gate. It is the **read-only** quality gate that gstack
structurally lacks: the relevant reviewers must each return `VERDICT: PASS` before
code ships. You ORCHESTRATE reviewers and decide; **you never edit code yourself**
(read-only is the whole point — a model that fixes what it judges produces biased
reviews). If a reviewer finds problems, you report them and stop; the user fixes and
re-runs the gate.

The two enforcement hooks (`UserPromptExpansion` on `/ship`, `PreToolUse` on the
push/PR) are the backstop for someone who skips this skill. This skill is the
intended happy path: review once, then ship in the same motion with no double cost.

## Step 0 — Detect the base branch

Detect the branch this work targets (the same way /ship does). Base detection lives
in a tested script so it ALWAYS resolves to a real branch — never an empty string
(an empty base would mis-scope the diff and review the wrong surface):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/forgeward-detect-base.sh"
```

It resolves in order: GitHub default branch → `origin/HEAD` target (only when set) →
`origin/main` → local `main` → `master`. Call the result `<base>`. If you are on
`<base>` itself, stop: "Nothing to gate — you're on the base branch."

## Step 1 — Scope the diff (which surfaces does it touch?)

Get the changed files and the diff content:

```bash
git diff --name-only "<base>...HEAD"
git diff "<base>...HEAD"
```

Decide which reviewers to fire. Fire a reviewer when its surface is present; otherwise
skip it and say so explicitly (conditional firing — no blanket runs). Each reviewer
ALSO self-skips if its surface turns out absent, so when unsure, fire it.

| Reviewer | Fire when the diff touches… | Signals to look for |
|----------|------------------------------|---------------------|
| `privacy-reviewer` | personal data — **or** any change to a `private-shareable` site (see below) | forms/fields for name/email/phone/address, logging of user data, analytics/Sentry/3rd-party sends, PII in URLs; on a `private-shareable` site also: any new route, lookup/search UI, data-source URL reaching the client, third-party embed, or OG tag change |
| `accessibility-reviewer` | UI | `.tsx/.jsx/.vue/.svelte/.html` components/templates, markup, styles |
| `ai-output-reviewer` | an LLM / paid-AI call | `openai`, `anthropic`, `@anthropic-ai`, `chat.completions`, `messages.create`, `generateText`, model SDK calls |
| `seo-reviewer` | any publicly reachable page — indexed **or** deliberately unindexed-but-shareable | marketing/landing/public routes, `<head>`/meta, `sitemap`, `robots.txt`, OG/Twitter Card tags — NOT behind-auth app pages. It detects the posture itself and switches ruleset |
| `supply-chain-reviewer` | a dependency manifest | `package.json`, lockfiles, `*.csproj`/`packages.lock.json`, `composer.json`, `requirements.txt`, `go.mod`, `Cargo.toml` |
| `security-reviewer` | executable code (the broad surface — fire on any code that could carry a vuln) | DB queries (`$wpdb->`, raw SQL, string-built queries), request/AJAX/route handlers, auth/capability/nonce logic, `exec`/`eval`/shell, deserialization, file paths built from input, network fetch from input, `.sql` files, template/HTML output of dynamic data |

Print the firing decision, e.g.:
`Surfaces: UI=yes, personal-data=yes, llm=no, public-pages=no, deps=no, code-security=yes → firing: accessibility, privacy, security`.

### Step 1a — classify posture per route group (it changes which reviewers fire and how)

Posture is a property of a **route group, not a repo**. One repo commonly holds
several — the usual shape is indexed marketing pages plus an authenticated app on
the same origin. Group the changed pages by route prefix / directory / layout and
classify each from `robots.txt`, per-route `noindex`, auth guards, deploy config,
and whether Open Graph tags are present. The seo-reviewer does this in detail; you
need enough to route the work.

The postures are `public-indexed`, `private-shareable`, `private-closed`,
`staging-preview`, `authenticated-shareable`, and `unknown`. A repo may pin them in
`.forgeward/config.yml` (`seo.posture`, or `seo.routes` per prefix); a pin wins.

Two of these change firing:

- **`private-shareable`** — reachable without a login, deliberately unindexed, OG
  tags on purpose. There is no auth boundary: the URL is the credential. **Fire the
  privacy-reviewer even when the diff looks like markup or config**, and tell it the
  posture. On such a group, every new route and every data source that reaches the
  browser is a personal-data change.
- **`staging-preview`** — a non-production deploy. Fire the privacy-reviewer if any
  seed or fixture data could be real records.

`Disallow: /` together with OG tags is a legitimate, deliberate design, NOT a
misconfiguration — never treat it as one. If posture is `unknown`, say so in the
firing decision and fire the superset of plausibly-relevant reviewers rather than
guessing a narrow one.

### Step 1b — say what the diff cannot see

Before firing, check whether the repo is a thin layer over code it does not contain:
a vendored or externally-located engine, a git submodule, a framework core resolved
at runtime, or gitignored directories that committed tooling references. Look at the
entry point, `.gitignore`, and any path in config that escapes the repo root.

If so, **say it explicitly in the firing decision** — e.g. `NOTE: request handling
lives in <engine>, resolved at runtime and absent from this repo; privacy/security
coverage here is limited to configuration and client assets.` The reviewers cannot
audit what is not in the diff, and a PASS on a thin customization layer must never
read as a PASS on the system. Recommend gating the engine repo separately.

This is also a finding in its own right: if committed tooling references a path that
is untracked, the security-reviewer should hear about it.

## Step 2 — Run the fired reviewers (read-only, in parallel)

For each fired reviewer, spawn it with the **Agent** tool (one message, multiple Agent
calls, so they run in parallel). Use the matching `subagent_type`
(`forgeward:privacy-reviewer`, `forgeward:accessibility-reviewer`,
`forgeward:ai-output-reviewer`, `forgeward:seo-reviewer`,
`forgeward:supply-chain-reviewer`, `forgeward:security-reviewer`). Tell each to review
the diff of `<base>...HEAD`.

Each reviewer returns findings and ends with one line: `<AXIS> VERDICT: PASS|FAIL`.
Collect every verdict line. Do not edit any code in response to findings.

## Step 3 — Decide

- **If every fired reviewer returned `VERDICT: PASS`** (and any self-skipped reviewer counts as PASS): write the pass marker, then ship.

  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/forgeward-write-marker.sh" "<base>" "<comma-separated fired reviewers>"
  ```

  Then invoke gstack's ship in the same motion:
  - Invoke the `ship` skill via the **Skill** tool (this model-initiated invocation is
    not a user-typed expansion, so the `UserPromptExpansion` halt does not fire; the
    `PreToolUse` push hook will find the fresh marker and allow the push).

  Report: `forgeward gate: PASS (fired: …). Marker written. Handing off to /ship.`

- **If any fired reviewer returned `VERDICT: FAIL`**: do NOT write a marker and do NOT
  invoke /ship. Print each failing reviewer's Critical/High findings (severity,
  `file:line`, issue, fix) grouped by axis, then stop with:
  `forgeward gate: FAIL — fix the Critical/High findings above and re-run /forgeward:gate. Nothing was shipped.`

## Rules

- **Read-only.** You never Edit/Write code here. You dispatch reviewers and report.
- **Conditional.** Only fire reviewers whose surface the diff touches; say which you skipped and why.
- **The marker is only written on all-PASS.** No marker ⇒ the push hook blocks /ship. That is the gate.
- **Never lower the bar.** If a reviewer fails, the gate fails. Do not rationalize a FAIL into a pass.
