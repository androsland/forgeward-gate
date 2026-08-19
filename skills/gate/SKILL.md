---
name: gate
description: Run forgeward's enforced, read-only conformance gate before shipping. Detects which surfaces the diff touches (personal data, UI, LLM/paid-AI calls, public pages, dependency manifests, code security), fires only the relevant read-only reviewers, and on all-PASS writes the pass marker, then invokes gstack's /ship in one motion when /ship is installed or hands back for a manual push when it is not. Discloses any axis no installed tool owns. On any FAIL it reports findings and ships nothing. Use this instead of calling /ship directly.
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
`staging-preview`, `authenticated-shareable`, and `unknown`.

A repo may pin one posture for the whole repo as `seo.posture` in
`.forgeward/config.yml`. Read it from the `seo_posture` field of the Step 1c probe
below (one run answers both steps) — a non-empty value wins over detection for every
route group and you say so in the firing decision. `seo.routes`, the per-prefix form,
is **documented but not honoured**: it is read by nothing, so a repo that pins it is
classified by detection regardless. Say so if you see one rather than acting on it.

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

### Step 1c — say what this INSTALL cannot cover

Step 1b is about the blind spot of the *diff*. This is the blind spot of the *machine*.

forgeward's reviewer table is scoped as a **delta against gstack** — its third column
says what each reviewer adds that gstack does not. Scoping by delta means every
deferral becomes a hole the moment the other side is absent, and one already shipped
that way (`supply-chain-reviewer` deferred dependency CVEs to a `/cso` that need not
exist; it now detects and self-adjusts). Two axes are still owned by a partner tool:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/forgeward-detect-environment.sh"
```

It prints one line of JSON and always exits 0 — it is informational, and must never
stop a gate run. It also carries `seo_posture` for Step 1a, so one run serves both
steps. Read `gstack_review`, `gstack_cso`, `gstack_ship`, and `substitutes`:

| axis | owner | run by | when it will not run |
|------|-------|--------|----------------------|
| `quality` | gstack `/review` (`gstack_review`) | the Step 3 handoff — `/ship` Step 9 dispatches the pre-landing review and its specialists | Nothing on this machine reviews code quality or design. No forgeward reviewer picks it up. |
| `deep-audit` | gstack `/cso` (`gstack_cso`) | nothing here; the user runs it | `security-reviewer` still runs, diff-scoped — it does **not** replace a whole-repo audit. `/forgeward:ci-gate` is the closest standing substitute. |

**`quality` keys on `gstack_ship`, NOT on `gstack_review`, and the difference is a real
hole rather than a nicety.** The gate never invokes `/review` itself (see the box below
for why it must not), so the axis is covered only when the Step 3 handoff reaches
`/ship`, whose Step 9 runs it. Four cases, and the second is the one a
`gstack_review`-keyed check gets wrong:

- **`gstack_ship: present`** — say so, once: `quality — deferred to /ship Step 9, which
  runs it after this gate passes.` The user needs this to know it is coming and not to
  run `/review` a second time by hand.
- **`gstack_ship: absent` and `gstack_review: present`** — the skill exists and nothing
  will run it, because the handoff that would have is not there. Say:
  `NOT COVERED this pass: quality — /review is installed but nothing here invokes it; gstack /ship is absent, and the handoff is what runs it. Run /review yourself before merging.`
  Keying this on `gstack_review` reports the axis as owned while it goes unreviewed.
- **`gstack_ship: present` but the user does not take the handoff** — you cannot detect
  this and must not pretend to. It is the *common* case, not an edge one:
  `docs/axis-proposals.md` records gate → push-and-PR-by-hand as forgeward's own most
  frequent workflow, chosen deliberately because `/ship` would re-bump the version. The
  first bullet's wording is therefore "deferred to /ship Step 9, **which runs it after
  this gate passes**" — a statement about where the axis is owed, not a claim that it
  was paid.
- **both absent** — `NOT COVERED: quality — gstack /review is not installed and no forgeward reviewer owns this axis.`

> **Never invoke `/review` from inside this gate, and this is not a gap waiting to be
> filled.** Its `allowed-tools` include `Edit` and `Write`; forgeward's gate is read-only
> and proves it in Step 2 by snapshotting the tree and diffing it after. A reviewer that
> may legitimately edit code cannot run inside that envelope without either making the
> workspace guard fire on correct behaviour or gutting the guarantee it exists to give.
> Its scope also differs: `/review` resolves its own base branch, while Step 0 resolves
> the **publish boundary**, and the two are not the same ref. Running it before the gate
> (which the handoff effectively does, in the other order) keeps both contracts intact.

If an axis's owner is absent AND its name is not in `substitutes`, add the matching line
above to the firing decision.

Then **carry on and gate normally**. This is disclosure, not refusal, and the
distinction is the whole design (`docs/axis-proposals.md` §3): forgeward is fully
operational standalone, and refusing to gate because a *different* tool is missing
would trade a disclosed gap for a blocked user. Never FAIL, never withhold the marker,
and never re-fire a reviewer to compensate — a security reviewer asked to also judge
quality does neither job well.

**Say it once, and only when it is news.** If `substitutes` names the axis, the user
has already answered and you say nothing at all. A disclosure that repeats after being
answered is nagging, and nagging is how gates get switched off.

### The config was read — say whether it was understood

The probe also returns `config_warnings`, an integer count of settings in
`.forgeward/config.yml` that it was addressed by and could not use: an unknown key under
`standalone:` or `seo:`, an unknown top-level key, a `posture:` outside the six literals,
an item dropped by the substitutes charset or caps, an unterminated flow sequence.

**If `config_warnings` is greater than 0, print exactly one line** — the count and the
path, nothing more:
`NOTE: .forgeward/config.yml — 2 setting(s) were read and discarded (unknown key, or a value outside the accepted set). Everything else applied normally.`

Then **carry on and gate normally.** Discarding is the correct, deliberate behaviour: the
reader refuses shapes it cannot honour so a misconfiguration costs a redundant disclosure
rather than a silently skipped check. What was missing until 0.13.0 was any way for the
user to tell a config that was *read and understood* from one that was *read and
discarded* — the two produced byte-identical output, so a typo'd `substitues:` looked
exactly like no config at all. This line closes that and nothing else. Never FAIL on it,
never withhold the marker, never re-fire a reviewer.

**Do not name the offending keys** — the probe deliberately returns a count and no
strings, because its output is interpolated into the pass marker and an integer is the
only shape with nothing to splice. You do not have the key names and must not guess them;
the line's job is to send someone to their own file.

**Three things this count does not mean, and you must not imply otherwise.** `0` is not a
clean bill — a config the probe could not open at all also reports `0`, and `config` is
the field that separates those, so read both and prefer `config`'s answer when it says
`unreadable` or `absent`. It says nothing about `seo.routes`, which is documented as
unhonoured in three shipped files and is deliberately **not** counted, so a repo pinning it
gets no line here and the separate Step 1a note about it still applies. And the reader is
not a YAML parser: on a file using anchors, aliases, multi-document streams or block
scalars the number is counted over lines that were never keys, and nothing detects that
case — so treat a large count as "look at your config", never as a defect tally.

**`quality` is the one axis where PRESENT is also a disclosure, and it is a different
sentence from the absent case.** The deferral is reciprocal, and that was observed rather
than theorised: in one repo's review log gstack's `/review` skipped its `maintainability`
specialist with `reason: "covered-by-forgeward-and-coverage-audit"` and `security` with
`"covered-by-forgeward"` — while forgeward defers quality to `/review`. Two tools each
pointing at the other means nobody reviews quality, and no `NOT COVERED` line fires,
because `gstack_review` reads `present` and presence is all the probe can see.

So when `gstack_review: present` and `quality` is not in `substitutes`, name the axis in
the firing decision as an OWNER and never as a coverage claim — one clause on the line
you already print, not a paragraph:
`quality: owned by gstack /review (installed; forgeward has no quality reviewer and does not check that /review ran)`

Its limits are the point. Forgeward cannot see whether `/review` ran, cannot read its
skip reasons, and cannot change what it does; the other half of the loop has to be fixed
in gstack. What forgeward can stop doing is *asserting coverage on another tool's
behalf*, and that is all this line is. Silence it like any other axis by putting
`quality` in `standalone.substitutes`.

**State presence, never diligence.** The probe sees that a skill is *installed*. It
cannot tell gstack-installed-and-never-run from gstack-actively-covering-the-axis, so
`gstack_review: present` licenses "the tool is here", never "quality was reviewed".
If `config` reads `unreadable`, disclose anyway and say the config could not be read —
being wrong in that direction costs a redundant paragraph; the other direction hides
a real gap.

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

  Then hand off — **but only if there is something to hand off to.** Use
  `gstack_ship` from the Step 1c probe (re-run it if you skipped Step 1c):

  - **`gstack_ship: present`** → invoke the `ship` skill via the **Skill** tool. This
    model-initiated invocation is not a user-typed expansion, so the
    `UserPromptExpansion` halt does not fire; the `PreToolUse` push hook will find the
    fresh marker and allow the push.
    Report: `forgeward gate: PASS (fired: …). Marker written. Handing off to /ship.`

  - **`gstack_ship: absent`** → **do not attempt the Skill call.** Stop here and report:
    `forgeward gate: PASS (fired: …). Marker written. gstack /ship is not installed — commit, push and open the PR yourself; the marker is already in place, so the push hook will allow it.`
    If `gstack_review: present`, add the second line, because this is the branch where
    the quality axis silently goes unrun (Step 1c):
    `Quality was not reviewed — /ship Step 9 is what runs /review, and /ship is absent. Run /review before merging.`

  The handoff is a **convenience, not part of the gate**. The gate is the review and
  the marker, and both are complete before this branch is reached — so a missing
  `/ship` costs the user two commands, never a re-review.

  Getting this wrong is worse than it looks, which is why it is spelled out. The marker
  is written *above*, before this step: an unconditional Skill call on a machine with no
  gstack does not block anything and does not lose the PASS — it produces a **false
  success report**, telling the user their work shipped when nothing was pushed. A gate
  that lies about what it did is worse than one that stops. Report only what happened.

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
