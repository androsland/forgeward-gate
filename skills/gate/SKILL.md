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
| `maintainability-reviewer` | **any code at all** (always-on) | dead code, magic numbers, stale comments/docstrings, DRY violations, conditional side effects, module-boundary leaks |
| `testing-reviewer` | **any code or test at all** (always-on) | negative paths, edge cases, test isolation, flaky patterns, security-enforcement coverage, deleted or assertion-free tests |
| `performance-reviewer` | backend or frontend code | N+1 queries, missing indexes on new filters/joins, unbounded queries or reads, missing pagination, bundle size, blocking work in async contexts |
| `api-contract-reviewer` | an HTTP/RPC/GraphQL surface | route definitions, serializers/DTOs, response shapes, status codes, auth requirements on existing endpoints, OpenAPI/Swagger specs |
| `data-migration-reviewer` | a schema migration, backfill, or DDL | `migrations/`, `db/migrate/`, `*.sql` DDL, Prisma/Alembic/Rails/Laravel migration files, backfill scripts and rake tasks |

Print the firing decision, e.g.:
`Surfaces: UI=yes, personal-data=yes, llm=no, public-pages=no, deps=no, code-security=yes, api=no, migrations=no → firing: accessibility, privacy, security, maintainability, testing`.

`maintainability` and `testing` are in that example because they are in **every** example:
both fire on any diff that changes code, so a firing line that omits them is describing a
run that did not happen. The example is the thing people copy, and it shipped for one
version listing only the conditional three.

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

forgeward's reviewer table began as a **delta against gstack** — its third column says
what each reviewer adds that gstack does not. Scoping by delta means every deferral
becomes a hole the moment the other side is absent, and this repo has now closed all
three of them: `supply-chain-reviewer` deferred dependency CVEs to a `/cso` that need not
exist (it detects and self-adjusts); `quality` deferred to `/review` (five ported
reviewers own it outright as of 0.17.0); and `deep-audit` deferred to `/cso` (0.19.0
ships `/forgeward:audit`). **No axis on this gate is owned by a tool that might not be
installed.**

Run the probe anyway — Step 1a needs its `seo_posture`, Step 3's marker validates its
full JSON shape, and Step 3's handoff needs `gstack_ship`:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/forgeward-detect-environment.sh"
```

It prints one line of JSON and always exits 0 — it is informational, and must never stop
a gate run. Read `seo_posture`, `substitutes`, `config`, `config_warnings` and
`gstack_ship`. `gstack_review` and `gstack_cso` are still emitted and **nothing in this
step reads either one** — that is the change: neither quality nor deep-audit is a
question about what is installed any more.

### `deep-audit` is forgeward's axis now — and it still gets ONE line

0.19.0 ports gstack's `/cso` audit phases into `/forgeward:audit`, so the axis is
guaranteed present and version-matched on every machine. That closes half of the hole and
you must not let it read as the whole one: **this gate does not fire it.**

| axis | owner | run by | what to say |
|------|-------|--------|-------------|
| `deep-audit` | forgeward `/forgeward:audit` | **not this gate** — the user runs it deliberately | `deep-audit: owned by /forgeward:audit (whole-repo, read-only). NOT run by this gate, which is diff-scoped — run it before a release, after an incident, or on a schedule.` |

**Key that line on "not run by this gate", never on whether a tool is installed**, and
that is the whole reason it survives the port. A presence-keyed check would now read
`present` on every machine and print nothing, reporting the axis as owned while nothing
verifies it was ever run — the exact bug the 0.17.0 quality work exists to avoid
repeating, and the limit `scripts/forgeward-detect-gstack-skill.sh` states about itself
under *presence, not diligence*. Nothing here can see whether `/forgeward:audit` has run.

**Why not simply fire it here?** Not the `/review` reason — `/forgeward:audit` holds no
`Edit` and no `Write`, so unlike `/review` it would survive Step 2's workspace guard
intact. The reason is scope and cost: this gate resolves a publish boundary and reviews a
diff, while the audit reads the whole repository and its history, on findings that move
over months. Wiring it in would make every push pay for it. Do not add it to Step 2.

Print it as **one clause on the firing decision you already print**, not a paragraph, and
say nothing at all if `substitutes` names `deep-audit` — the user has answered.

### `quality` is forgeward's own axis now — say nothing about it

There is no quality disclosure to print, because there is no quality deferral. Five
read-only reviewers — `maintainability`, `testing`, `performance`, `api-contract`,
`data-migration` — fire from the Step 1 table like any other, and their verdicts bind
the gate like any other. **Do not print a `NOT COVERED: quality` line, do not name
gstack as the owner of this axis, and do not tell the user to run `/review` before
merging.** All three were correct until this release and all three are now false.

Their checklists are ports of gstack's Review Army specialists, taken under MIT with the
source commit and a sha256 recorded in each `agents/*-reviewer.md`. That is a fork, so it
drifts. Run the drift check — it is five sha256 comparisons against files already on
disk, it prints nothing when there is no news, and it always exits 0:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/forgeward-rubric-drift.sh"
```

If it prints, **relay it verbatim and carry on gating.** Drift means gstack improved a
checklist we have not re-ported; it does not mean this run's verdicts are wrong, and it
must never delay a gate. On a machine with no gstack it prints nothing at all, which is
the whole point of having ported them.

> **Never invoke `/review` from inside this gate, and this is not a gap waiting to be
> filled — it is why the rubrics were ported instead.** Its `allowed-tools` include
> `Edit` and `Write`; forgeward's gate is read-only and proves it in Step 2 by
> snapshotting the tree and diffing it after. A reviewer that may legitimately edit code
> cannot run inside that envelope without either making the workspace guard fire on
> correct behaviour or gutting the guarantee it exists to give. Its scope also differs:
> `/review` resolves its own base branch, while Step 0 resolves the **publish boundary**,
> and the two are not the same ref. The checklists carry none of that — they are prose,
> and prose has no tools — so porting them takes the judgment without the envelope
> problem. Running `/review` separately, before the gate, remains a perfectly good thing
> for a user to do; it is simply no longer something this axis depends on.

**What the port does not buy.** The reviewers own the axis on every machine, but they are
a snapshot: an improvement gstack makes tomorrow reaches this gate only when someone
re-ports it. The drift check tells you that happened; nothing makes it happen. And a
`quality` entry in `standalone.substitutes` no longer suppresses anything, because there
is no longer a disclosure to suppress — a stale one in a repo's config is harmless and
you should not mention it.

The same snapshot property applies to `/forgeward:audit`, and with **less** cover: as of
0.19.0 `forgeward-rubric-drift.sh` iterates `agents/*-reviewer.md` and nothing else, so
the audit port's provenance block is recorded and unchecked. Do not read the drift
check's silence as covering it. Filed in `TODOS.md`.

Then **carry on and gate normally**, whatever any of the above printed. Everything in
Step 1c is disclosure, not refusal, and the distinction is the whole design
(`docs/axis-proposals.md` §3): forgeward is fully operational standalone, and a gate that
stopped over a scope note would trade a disclosed gap for a blocked user. Never FAIL,
never withhold the marker, and never re-fire a reviewer to compensate — a security
reviewer asked to also judge whole-repo audit scope does neither job well.

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

**State presence, never diligence.** The probe sees that a skill is *installed*. It has
never been able to tell installed-and-never-run from actively-covering-the-axis, which is
why no disclosure in this step keys on presence any more. If `config` reads `unreadable`,
disclose anyway and say the config could not be read — being wrong in that direction
costs a redundant paragraph; the other direction hides a real gap.

That distinction is why `quality` stopped being a disclosure at all. Until 0.17.0 it was
the one axis where `present` also had to be disclosed, because the deferral turned out to
run both ways: in one repo's review log gstack's `/review` skipped its `maintainability`
specialist with `reason: "covered-by-forgeward-and-coverage-audit"` while forgeward
deferred quality straight back to `/review`. Two tools pointing at each other meant
nobody reviewed quality, and nothing fired, because presence was all the probe could see.
Porting the checklists ended that class of bug for that axis rather than describing it
better, and 0.19.0 did the same for `deep-audit`. **What survives the port is a smaller
and more honest claim:** the axis has an owner that is always here, and nothing checks
that the owner ran. The `deep-audit` clause above says exactly that and nothing more.

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
`forgeward:supply-chain-reviewer`, `forgeward:security-reviewer`,
`forgeward:maintainability-reviewer`, `forgeward:testing-reviewer`,
`forgeward:performance-reviewer`, `forgeward:api-contract-reviewer`,
`forgeward:data-migration-reviewer`). Tell each to review
the diff of `<base>...HEAD`, passing `<base>` exactly as Step 0 produced it.

`maintainability` and `testing` are always-on, so on any diff carrying code the parallel
batch is at least three reviewers wide. That is the intended cost: the quality axis used
to be free because nothing ran it.

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
    **Add nothing about quality here.** Until 0.17.0 this branch carried a second line
    telling the user to run `/review` before merging, because taking no handoff meant the
    quality axis went unrun. It no longer does: the quality reviewers fired in Step 2 and
    their verdicts are part of the PASS being reported. Repeating the old line would send
    someone to re-run a review the gate has already done.

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
