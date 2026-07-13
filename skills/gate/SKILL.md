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
| `privacy-reviewer` | personal data | forms/fields for name/email/phone/address, logging of user data, analytics/Sentry/3rd-party sends, PII in URLs |
| `accessibility-reviewer` | UI | `.tsx/.jsx/.vue/.svelte/.html` components/templates, markup, styles |
| `ai-output-reviewer` | an LLM / paid-AI call | `openai`, `anthropic`, `@anthropic-ai`, `chat.completions`, `messages.create`, `generateText`, model SDK calls |
| `seo-reviewer` | public, indexable pages | marketing/landing/public routes, `<head>`/meta, `sitemap`, `robots.txt` — NOT behind-auth app pages |
| `supply-chain-reviewer` | a dependency manifest | `package.json`, lockfiles, `*.csproj`/`packages.lock.json`, `composer.json`, `requirements.txt`, `go.mod`, `Cargo.toml` |
| `security-reviewer` | executable code (the broad surface — fire on any code that could carry a vuln) | DB queries (`$wpdb->`, raw SQL, string-built queries), request/AJAX/route handlers, auth/capability/nonce logic, `exec`/`eval`/shell, deserialization, file paths built from input, network fetch from input, `.sql` files, template/HTML output of dynamic data |

Print the firing decision, e.g.:
`Surfaces: UI=yes, personal-data=yes, llm=no, public-pages=no, deps=no, code-security=yes → firing: accessibility, privacy, security`.

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
