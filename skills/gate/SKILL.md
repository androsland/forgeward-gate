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

## Step 0 — Detect the base ref (the publish boundary)

Detect what this work will be published against. Base detection lives in a tested
script so it always resolves to a real, CURRENT ref:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/forgeward-detect-base.sh"
```

Call the result `<base>` and use it **verbatim** — it is a REF, and it is often a
remote-tracking ref like `origin/main`. Do not strip the remote prefix, and do not
substitute the bare branch name. A bare name resolves to the LOCAL branch, which is
only as current as the last time the user touched it, and it mis-scopes the review in
both directions:

- local **behind** the remote → reviewers audit already-merged code (one real repo:
  267 files instead of 0). Wasted budget, and a FAIL can land on someone else's code.
- local **ahead** of the remote (unpushed commits on the base branch) → the diff is
  **smaller than what the push publishes**, so the gate writes a PASS marker for code
  it never saw. That is a false PASS, and it is the reason this must not be
  hand-rolled.

Resolution is: GitHub default branch → `origin/HEAD` target (only when set) →
`origin/main` → local `main` → `master` for the branch NAME; then that branch's
configured upstream → an existing `<remote>/<name>` ref → the local branch, for the
REF. A remote ref is used only when it exists, so a local-only repo, an
unauthenticated `gh`, or a base branch never pushed all correctly stay local.

If you need the bare branch name (e.g. to pass `gh pr create --base <name>`), ask for
it explicitly: `forgeward-detect-base.sh --name`.

**Surface the script's stderr.** When the local base branch has drifted from the
publish boundary, the script re-scopes automatically and prints a note like
`local 'master' is 14 commit(s) behind and 0 ahead of 'origin/master'`. Repeat that
note in your firing decision. The re-scope is automatic because a mis-scoped diff is a
correctness bug rather than a user preference; the note is mandatory because a stale
checkout is a fact the user acts on, and a silent correction would make the reviewed
surface differ from what they'd compute by hand.

**Two things this cannot see — say so if they might apply:**
- **Fetch staleness.** The script never runs `git fetch`, so `origin/<base>` is only
  as current as the user's last fetch. If the remote moved since, the publish boundary
  is stale and the review is scoped against old ground. Suggest `git fetch` when the
  drift note appears.
- **The real PR target.** It infers the base from repo defaults. A PR aimed at a
  release branch or stacked on another feature branch has a different base, and
  nothing here can tell. If you know the target differs, scope the diff by hand and
  say you did.

Decide "nothing to gate" from the **diff**, never from branch names. If
`git diff --name-only "<base>...HEAD"` is empty, stop: "Nothing to gate — HEAD matches
the publish boundary `<base>`." Being *on* the base branch is not that condition: a base
branch with unpushed commits resolves `<base>` to `origin/<base>`, and those unpushed
commits are exactly what needs reviewing.

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

**Before spawning anything**, snapshot the working tree so the read-only contract can
be checked rather than assumed. Keep the snapshot OUTSIDE the repo:

```bash
ART="$("${CLAUDE_PLUGIN_ROOT}/scripts/forgeward-artifact-dir.sh")"
"${CLAUDE_PLUGIN_ROOT}/scripts/forgeward-workspace-guard.sh" snapshot > "$ART/tree-before.txt"
```

For each fired reviewer, spawn it with the **Agent** tool (one message, multiple Agent
calls, so they run in parallel). Use the matching `subagent_type`
(`forgeward:privacy-reviewer`, `forgeward:accessibility-reviewer`,
`forgeward:ai-output-reviewer`, `forgeward:seo-reviewer`,
`forgeward:supply-chain-reviewer`, `forgeward:security-reviewer`). Tell each to review
the diff of `<base>...HEAD`, passing `<base>` exactly as Step 0 produced it.

Each reviewer returns findings and ends with one line: `<AXIS> VERDICT: PASS|FAIL`.
Collect every verdict line. Do not edit any code in response to findings.

**Then check the contract held:**

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/forgeward-workspace-guard.sh" check "$ART/tree-before.txt"
```

Non-zero means a reviewer wrote into the repo it was auditing. That has happened: a
scanner handed a Windows path from a POSIX shell created a `C:` directory tree at the
repo root — untracked, matched by no common `.gitignore`, and committed by any
`git add -A`. Handle it in Step 3; never ignore it, and **do not delete the paths
yourself** — they are untracked files whose provenance only the user can confirm, and
the drive-letter shape is actively dangerous to remove: under Git Bash `C:` without a
leading `./` resolves to the **drive root**, so an `rm -rf` there is a far worse bug
than the one it cleans up. Print the paths and let the user run
`rm -rf -- "./C:"` themselves.

## Step 3 — Decide

- **If the workspace guard reported new paths**: HALT before shipping, whatever the
  verdicts were. Print the paths and stop with:
  `forgeward gate: reviewers left files in your repo — delete them and re-run. Nothing was shipped.`
  The verdicts still stand (contamination does not invalidate a security finding), but
  /ship stages and commits, so handing off now is how the artifact lands in the user's
  history. This is a halt, not a FAIL: no marker is written and nothing is deleted.

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
- **Read-only covers the filesystem, not just the code.** The repo must be
  byte-identical when the gate finishes — no scanner reports, no scratch files.
  Reviewers run scanners through `scripts/forgeward-scan.sh` (report on stdout, output
  flags refused) and take any scratch directory from `scripts/forgeward-artifact-dir.sh`.
  A `PreToolUse` deny and the workspace guard back that up, because the same reviewer
  broke this contract twice — the second time with a spawn prompt that explicitly
  forbade it. Do not treat an instruction as a control.
- **Conditional.** Only fire reviewers whose surface the diff touches; say which you skipped and why.
- **The marker is only written on all-PASS.** No marker ⇒ the push hook blocks /ship. That is the gate.
- **Never lower the bar.** If a reviewer fails, the gate fails. Do not rationalize a FAIL into a pass.
