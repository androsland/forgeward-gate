---
name: gate
description: Run forgeward's enforced, read-only conformance gate before shipping. Detects which surfaces the diff touches (personal data, UI, LLM/paid-AI calls, public pages, dependency manifests, code security), fires only the relevant read-only reviewers, and on all-PASS writes the pass marker, then invokes gstack's /ship in one motion when /ship is installed or hands back for a manual push when it is not. Names the whole-repo deep-audit axis it deliberately does not run (that is /forgeward:audit). On any FAIL it reports findings and ships nothing. Use this instead of calling /ship directly.
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Agent
  - Skill
  - TaskStop
  - ToolSearch
---

# /forgeward:gate — the enforced conformance gate

You are running forgeward's gate. It is the **read-only** quality gate that gstack
structurally lacks: the relevant reviewers must each return `VERDICT: PASS` before
code ships. You ORCHESTRATE reviewers and decide; **you never edit code yourself**
(read-only is the whole point — a model that fixes what it judges produces biased
reviews). If a reviewer finds problems, you report them and stop; the user fixes and
re-runs the gate.

## Runtime compatibility

This skill is shared by Claude Code and Codex. Resolve `<forgeward-root>` once before
running any bundled command:

- If `PLUGIN_ROOT` or `CLAUDE_PLUGIN_ROOT` is non-empty, use that value.
- Otherwise, in Codex, derive it from the exact absolute path of this loaded `SKILL.md`
  shown in Codex's available-skills catalog. This file is
  `<forgeward-root>/skills/gate/SKILL.md`, so remove that exact suffix and canonicalize
  the result. This is deterministic path derivation from the selected skill, not a
  search of or guess about Codex's plugin cache.

Verify that the result contains `.codex-plugin/plugin.json` or
`.claude-plugin/plugin.json` and the required `scripts/` and `agents/` entries. If it
does not, stop and report the resolved path and failed check. Use the resolved absolute
path literally wherever `<forgeward-root>` appears below; do not assume a shell export
will persist across tool calls. `PLUGIN_ROOT` is guaranteed for Codex plugin **hook
processes**, but ordinary skill shell commands do not inherit that hook-only environment.

Claude Code registers the Markdown files under `agents/` as plugin subagent types.
Codex keeps those same files in the installed plugin and uses them as the authoritative
rubrics for spawned subagents. The Step 2 instructions below select the correct path
without requiring the user to edit the plugin. Forgeward currently supports these two
reviewer runtimes. An unrecognised runtime follows the existing cannot-spawn halt in
Step 2; never guess a model alias or silently fall back to parent-session settings.

The two lifecycle guardrails are selected by the installing client: Claude Code uses
`UserPromptExpansion` plus `PreToolUse`; Codex uses `UserPromptSubmit` plus
`PreToolUse`. They are fast feedback for someone who skips this skill. The installed
Git `pre-push` hook remains the enforcement boundary.

## Step 0 — Detect the base ref (the publish boundary)

Detect what this work will be published against. Base detection lives in a tested
script so it always resolves to a real, CURRENT ref:

```bash
"<forgeward-root>/scripts/forgeward-detect-base.sh"
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

**Freeze the review subject.** Resolve both ends of the review to commit names once,
here, and print them:

```bash
BASE_SHA="$(git rev-parse --verify --quiet "<base>^{commit}")"; echo "BASE_SHA=$BASE_SHA"
HEAD_SHA="$(git rev-parse --verify --quiet "HEAD^{commit}")"; echo "HEAD_SHA=$HEAD_SHA"
```

If either is empty, stop: `forgeward gate: could not resolve <base> or HEAD to a commit. Nothing was reviewed.`
Shell variables do not survive between tool calls, so from here on write the two
**full names exactly as printed** wherever this skill says `<BASE_SHA>` or
`<HEAD_SHA>`. Every later step reviews `<BASE_SHA>...<HEAD_SHA>`, never a symbolic
`HEAD`: a commit landing while the gate runs would otherwise be reviewed by reviewers
chosen for the commit before it, and the marker would certify code nobody saw.
`<base>` stays the name the user reads and the marker records.

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
`git diff --name-only "<BASE_SHA>...<HEAD_SHA>"` is empty, stop: "Nothing to gate — HEAD matches
the publish boundary `<base>`." Being *on* the base branch is not that condition: a base
branch with unpushed commits resolves `<base>` to `origin/<base>`, and those unpushed
commits are exactly what needs reviewing.

## Step 1 — Scope the diff (which surfaces does it touch?)

Get the changed files and the diff content:

```bash
git diff --name-only "<BASE_SHA>...<HEAD_SHA>"
git diff "<BASE_SHA>...<HEAD_SHA>"
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
| `targeted-reviewer` | money, gate, auth or secret code: classified by what a file does, on added **and** deleted lines (Step 1d) | paid calls, spend caps and billing; CI conditions, thresholds, verdict and marker logic, test skips, reviewer prompts and rule files; login, session and permission checks; secret env reads, credential files, logging and redaction |
| `maintainability-reviewer` | **any code at all** (always-on) | dead code, magic numbers, stale comments/docstrings, duplicated behaviour with defects, conditional side effects, module-boundary leaks |
| `testing-reviewer` | **any code or test at all** (always-on) | negative paths, edge cases, negative assertions, test isolation, flaky patterns, security-enforcement coverage, deleted or assertion-free tests, low-value tests |
| `performance-reviewer` | backend or frontend code | N+1 queries, missing indexes on new filters/joins, unbounded queries or reads, missing pagination, bundle size, blocking work in async contexts |
| `api-contract-reviewer` | an HTTP/RPC/GraphQL surface | route definitions, serializers/DTOs, response shapes, status codes, auth requirements on existing endpoints, OpenAPI/Swagger specs |
| `data-migration-reviewer` | a schema migration, backfill, or DDL | `migrations/`, `db/migrate/`, `*.sql` DDL, Prisma/Alembic/Rails/Laravel migration files, backfill scripts and rake tasks |

Print the firing decision, e.g.:
`Surfaces: UI=yes, personal-data=yes, llm=no, public-pages=no, deps=no, code-security=yes, api=no, migrations=no, targeted=yes → firing: accessibility, privacy, security, targeted(money,secret), maintainability, testing`.

`maintainability` and `testing` are in that example because they are in **every** example:
both fire on any diff that changes code, so a firing line that omits them is describing a
run that did not happen. The example is the thing people copy, and it shipped for one
version listing only the conditional three.

`targeted(money,secret)` is how `targeted` always appears on the firing line: with the
classes Step 1d found, in parentheses. They reach the reviewer in Step 2b's launch context.
The marker and the PASS report carry the bare `targeted` (Step 3).

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
exist (it owns them outright as of 0.23.0, with no probe left); `quality` deferred to
`/review` (five ported reviewers own it outright as of 0.17.0); and `deep-audit` deferred
to `/cso` (0.19.0 ships `/forgeward:audit`). **No axis on this gate is owned by a tool
that might not be installed.**

Run the probe anyway — Step 1a needs its `seo_posture`, Step 3's marker validates its
full JSON shape, and Step 3's handoff needs `gstack_ship`:

```bash
"<forgeward-root>/scripts/forgeward-detect-environment.sh"
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
`Edit` and no `Write`, so unlike `/review` it has no *sanctioned* reason to touch the
tree and is far likelier to survive Step 2's workspace guard. Not guaranteed to: it holds
`Bash`, and a single redirect writes a file, so the guard stays the check rather than a
formality. The reason it is excluded is scope and cost: this gate resolves a publish boundary and reviews a
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
source commit and a sha256 recorded in each `agents/*-reviewer.md`. So is
`targeted-reviewer`'s, which sits outside this axis: it owns money, gate, auth and secret
code. A port is a fork, so it drifts. Run the drift check — it is a handful of sha256
comparisons against files already on disk (the ported reviewers and `/forgeward:audit`),
it prints nothing when there is no news, and it always exits 0:

```bash
"<forgeward-root>/scripts/forgeward-rubric-drift.sh"
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

The same snapshot property applies to `/forgeward:audit`, and since 0.20.0 with the same
cover: `forgeward-rubric-drift.sh` iterates `skills/*/SKILL.md` too, so the audit port's
`source-sha256` is monitored on the run you just made. Two of its limits matter enough to
state here — only Phases 2-11 are hash-pinned at all, and the check is blind on a machine
with no gstack checkout, which is the machine the port exists to serve. **That is not the
whole list, and this sentence deliberately no longer claims to be**: the script's own
header carries the non-goals, it is the only copy anyone maintains, and a closed count in
a second file goes stale the first time one is added.

One silence it no longer keeps: when a gstack checkout IS found and not one ported rubric
could be read, the script now says so unconditionally, on stdout, and still exits 0. Relay
that line like any other — it means drift was **not** checked on this run, which before
0.20.0 was indistinguishable from a clean one.

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

### Step 1d — targeted classes

`targeted-reviewer` fires when the diff touches **money**, **gate**, **auth** or **secret**
code, the four classes where one miss costs most. Decide which of them apply, and read
**added and deleted** lines alike: a removed cap, check or redaction is the change. The
signals are adapted to prose from gstack's lists in `lib/review-risk.ts` and
`lib/review-targeted.ts`.

- **money:** a paid call (model SDK constructors and `.messages.create` /
  `.chat.completions.create` shapes, cloud-VM or paid-search APIs); spend caps, budgets,
  quotas and ledgers; billing, pricing, invoice, fee, charge, credit and metering code;
  `*_usd` or cents fields; a retry, loop or fan-out around any of these.
- **gate:** CI workflow conditions and `continue-on-error`; required checks; thresholds,
  allowlists and ratchets; hook or middleware allow and deny decisions; verdict, marker and
  pass/fail logic; rule hashes and pins; test skips (`.skip`, `xit`, `@pytest.mark.skip`,
  `t.Skip`).
- **auth:** login, session, token, JWT and OAuth code; role, permission and capability
  checks; guard middleware; callback `state` handling.
- **secret:** reads of env names matching `*_KEY`, `*SECRET*`, `*TOKEN*`, `*PASSWORD*` or
  `*CREDENTIAL*`; credential files (`.env*` other than example, sample or template,
  `*.pem`, `*.key`, `id_*`, `.netrc`); keychain and credential helpers; logging, redaction,
  masking and file-mode code.

**Classify a file by what it does, not by its extension.** Three kinds of file are gate
code whatever their extension:

- a **test** whose change skips, deletes or weakens an assertion on an enforcement path
  (authorization, a cap, a redaction, a verdict). A tests-only diff fires the gate class
  when it does this.
- a **file a tool executes as instructions**: a reviewer or agent prompt, a skill or gate
  procedure, a lint or scanner rule file, including its allowlist or ignore file. In
  forgeward's own repository that is `agents/*.md`, `skills/*/SKILL.md` and everything
  under `rules/`: the two Semgrep packs (`*.yml`) and the push-time Gitleaks config and
  ignore file (`gitleaks-pre-push.toml`, `gitleaks-pre-push.ignore`). An entry added to
  that ignore file is an allowlist change.
- **CI configuration, its mute lists, and the hook registrations that wire a check into a
  runtime.** In forgeward's own repository that is `.github/workflows/*.yml`;
  `ci/relanded-prs.txt`, the acknowledgement list `ci/check-merged-prs-landed.sh` skips;
  `hooks/hooks.json` and `hooks/codex-hooks.json`; and the `hooks` key in
  `.codex-plugin/plugin.json` that points Codex at the second file. Dropping a hook entry
  or its pointer removes an allow-or-deny decision without touching the script that makes
  it.

Ordinary documentation does not fire the gate class, and neither do tests that only add
inert fixtures or new cases. **That exemption is from the gate class only.** A fixture that
holds a credential, or a test that makes a paid call, fires secret or money exactly as any
other file does. A repo's `CLAUDE.md` or `AGENTS.md` counts as documentation here: it
instructs whoever next edits the repo, and no gate or check reads it as instructions.

**When you fire `targeted` but cannot tell which class applies, pass all four**, as
`targeted(money,gate,auth,secret)`. That is "when unsure, fire it" applied to the classes,
and upstream's classifier fails closed the same way: on any input it cannot read, it
returns all four.

**Print the classes in the firing decision**, as `targeted(money,secret)`, and pass them
to `targeted-reviewer` in Step 2b's launch context as a **scope hint**, to that reviewer
only. A scope hint is a classification, like privacy's site posture, not a finding. The
reviewer reviews the named classes in full, also reviews any other class it finds the diff
touching, and passes itself with one sentence if none applies. The classes are not part of
its name: Step 3's marker writer and the PASS report carry the bare `targeted`, like every
other entry.

**Non-goals, stated so they are not read as coverage.**

**Must NOT fire on:**

- a stylesheet of design tokens, `tokens.css`;
- marketing copy on a pricing page, `pricing.mdx`;
- README or CHANGELOG prose, and a repo's `CLAUDE.md` or `AGENTS.md`;
- a tests-only diff adding inert fixtures or new cases, for the gate class only. A new case
  that makes a paid call, reads a secret or checks an identity is money, secret or auth
  code like any other, and a fixture holding a credential is not inert.

**Structurally cannot see:**

- money, auth, gate or secret logic expressed with none of the vocabulary above, for
  example a cap as `MAX = 50` in a generic `limits.ts` with its call site elsewhere. Step 1
  is model judgement, and the reviewer's self-skip cannot recover a missed classification,
  because the reviewer never ran. What backstops a missed classification differs by class:
  - auth and secret logic: `security-reviewer`'s broader firing;
  - spend on an LLM call: `ai-output-reviewer`;
  - non-LLM spend (a cloud VM, a paid search) and gate logic: **nothing**.
    `security-reviewer` carries no spend-cap rule, and `ai-output-reviewer` fires only on
    an LLM call.
- a procedure whose instructions live where nothing recognizes them as one, such as a wiki
  page a CI job fetches.
- a control in a submodule that is not checked out. `git grep --recurse-submodules` finds
  nothing there, so the reviewer reports a control not found: High, or Critical for spend.
- a diff that only bumps a gitlink. It shows two commit ids and none of the submodule's
  lines, so this step cannot classify it, and it fires `targeted` only when something else
  in the diff does. Where `targeted` fires and the submodule's objects are present, the
  reviewer reads the range (`git -C <path> diff <old> <new>`). Where they are not, it says
  so, and that range is outside what it reviewed. Step 1b's submodule disclosure is the
  user's notice.

## Step 2 — Run the fired reviewers (read-only, in parallel)

Step 2 has four parts: **2a** starts the run, **2b** launches the reviewers, **2c**
accounts for every one of them, and **2d** checks the workspace once. Step 3 decides on
what they produce. Every path through Step 2 that gets past 2a's snapshot, and is not
interrupted, ends at 2d's check: a reviewer that started may have written into the repo,
and only that check can see it.

### 2a — Start the run

**First, start this run on the reviewed commit.** `--revoke` records a new run id for
`<HEAD_SHA>`, and both push hooks accept a marker only while its run id is the one
recorded for the commit it reviewed, so every earlier PASS for this commit, under any
branch name, stops reading fresh; it also deletes the markers of the local branches at
this commit. From the moment this run commits to reviewing, no earlier run's PASS for
this commit may authorize a push. A re-run that fails must not leave the previous PASS
usable for the same diff, and neither may a run that is interrupted:

```bash
"<forgeward-root>/scripts/forgeward-write-marker.sh" --revoke "<HEAD_SHA>"
```

On exit 0 its last line is `RUN_ID=<id>`. Record that id exactly; wherever this skill
says `<RUN_ID>`, write it, and Step 3 passes it to the writer. A later gate run on the
same commit supersedes this one: its revoke records a new run id, and this run's write
is then refused, so only the latest run's outcome can stand.

Non-zero means a marker exists and could not be removed, the branches at this commit
could not be listed, or this run could not be recorded; the writer says which, and prints
no `RUN_ID`. Print its message verbatim and stop with
`forgeward gate: could not start this gate run cleanly (the reason is above), so an earlier PASS may still authorize a push. Nothing was reviewed.`

**Then create this run's directory**, outside the repo, and print its path in the same
command. A shell variable does not survive into a later command (see Runtime
compatibility), so every later command writes the printed path literally:

```bash
ART="$("<forgeward-root>/scripts/forgeward-artifact-dir.sh")" || exit 1
RUN_DIR="$(mktemp -d "$ART/run.XXXXXX")" || exit 1
printf 'RUN_DIR=%s\n' "$RUN_DIR"
```

Record the printed path exactly; wherever this skill says `<RUN_DIR>`, write it. **Never
give `<RUN_DIR>` to a reviewer:** it holds the baseline 2d compares against, and a
reviewer holding Bash could rewrite it. Non-zero, or no `RUN_DIR=` line: print the
message and stop with
`forgeward gate: could not create this run's directory outside the repo (the reason is above). Nothing was reviewed; the earlier PASS for this commit was already withdrawn.`

**Then record the workspace**, before anything is launched:

```bash
"<forgeward-root>/scripts/forgeward-workspace-guard.sh" snapshot "<HEAD_SHA>" > "<RUN_DIR>/snapshot"
```

Print anything it writes to stderr: a coverage note names each entry it recorded without
its content. Non-zero (2 when `HEAD` moved since Step 0 or git failed, 64 for an id that
is not a full commit id): print its message and stop with
`forgeward gate: could not record the workspace before review (the reason is above). Nothing was reviewed; the earlier PASS for this commit was already withdrawn.`

These three stops, and an interrupt, are the only ways out of Step 2 that skip the
check. Nothing has been launched yet, so there is nothing to check for.

Resolve the repository root once as well (Step 0 already froze the commits). A shell
variable does not survive into a later tool call, so print it and record the path it
prints exactly as `<REPOSITORY_ROOT>`:

```bash
git rev-parse --show-toplevel
```

### 2b — Launch

The launch context is intentionally small. Every reviewer gets its complete applicable
rubric, the absolute repository root, the resolved forgeward root when the rubric needs
it, `<base>` exactly as Step 0 returned it, `<BASE_SHA>` and `<HEAD_SHA>` exactly as
Step 0 printed them, the review range `<BASE_SHA>...<HEAD_SHA>`, the read-only
instruction, and the required verdict format. The reviewer each one concerns also gets
its Step 1 classification, and no other reviewer does: `privacy-reviewer` the site
posture of each route group it covers (Step 1a), and `targeted-reviewer` its classes
(Step 1d). Do not pass the parent conversation, implementation discussion, suspected
findings, or a summary of the rubric. Those add anchoring and cost without adding review
evidence.

For each fired reviewer, spawn it in parallel. Select the runtime path automatically:

- **Claude Code:** use the **Agent** tool (one message, multiple Agent calls). Every
  plugin agent definition under `agents/` declares `model: sonnet` and `effort: medium`;
  those native frontmatter fields are mandatory and prevent inheritance from the parent
  session. Use the matching `subagent_type` (`forgeward:privacy-reviewer`,
  `forgeward:accessibility-reviewer`,
`forgeward:ai-output-reviewer`, `forgeward:seo-reviewer`,
`forgeward:supply-chain-reviewer`, `forgeward:security-reviewer`,
`forgeward:targeted-reviewer`,
`forgeward:maintainability-reviewer`, `forgeward:testing-reviewer`,
`forgeward:performance-reviewer`, `forgeward:api-contract-reviewer`,
`forgeward:data-migration-reviewer`). The selected plugin agent supplies the complete
  rubric as its agent definition. Give the Agent only the launch context listed above.
- **Codex:** use its subagent/collaboration facility. Every reviewer spawn call MUST
  explicitly pass `model: "gpt-5.6-terra"`, `reasoning_effort: "medium"`, and
  `fork_turns: "none"`. These are per-launch settings: do not omit them even when the
  parent already uses Terra/medium, and do not translate them from a parent running
  `gpt-5.6-sol`, high reasoning, or any other configuration. For each reviewer, tell the
  isolated subagent to read the complete authoritative rubric at
  `<forgeward-root>/agents/<reviewer>.md`. Pass the resolved absolute
  `<forgeward-root>` in the prompt and tell the reviewer to substitute it literally for
  any plugin-root expression in the rubric; normal Codex shell commands do not inherit
  the plugin hook environment. The prompt must also carry `<REPOSITORY_ROOT>`, `<base>`,
  `<BASE_SHA>`, `<HEAD_SHA>`, `<BASE_SHA>...<HEAD_SHA>`, the read-only instruction, the
  rubric's verdict format, and, for `privacy-reviewer` and `targeted-reviewer` only, that
  classification. Do not paraphrase or copy only part of the rubric into the prompt.

In either runtime, tell each reviewer to review the diff of `<BASE_SHA>...<HEAD_SHA>`,
and that wherever its rubric names the range `<base>...HEAD` it means that frozen range;
pass `<base>` exactly as Step 0 produced it. Never pass `<RUN_DIR>`.

**Record every agent id the runtime returns.** Only output from a recorded id counts (2c).

- **Claude Code** launches the whole batch in one message, so every launch in it has
  already run. Record the id from each launch receipt.
- **Codex** launches one at a time. After a failed launch, launch no more; the reviewers
  left unlaunched are **not-started**.

**If a launch fails**, or the runtime cannot spawn the required reviewers with the
explicit runtime policy above: stop every reviewer that did start (2c), mark the run
**launch-failed**, and go to 2c. An unmeasured axis cannot return PASS, and a reviewer
that did start may have written into the repo, so the run still ends at 2d's check.
This is also the fallback for any other runtime, preserving the existing fail-closed
reviewer-launch behavior.

`maintainability` and `testing` are always-on, so on any diff carrying code the parallel
batch is at least three reviewers wide. That is the intended cost: the quality axis used
to be free because nothing ran it.

### 2c — Account for every reviewer

Each fired reviewer ends in exactly one state:

| State | Meaning |
|---|---|
| **returned** | its final output arrived |
| **errored** | the runtime reported that it failed, or that it timed out and has ended |
| **stopped** | the gate stopped it, and the runtime confirmed the stop |
| **unconfirmed** | the gate asked for a stop, and the runtime did not confirm it |
| **not-started** | Codex only: never launched, because an earlier launch failed |

Go on to 2d once every fired reviewer is in one of these states.

**Only output from an agent id recorded in 2b counts.** A completion notice from any
other id is ignored, and the report names it. An earlier gate run that was interrupted
can leave its reviewers running, and a verdict line carries no run identity: without
this rule, an earlier run's `SECURITY VERDICT: PASS` arriving now would be counted as
this run's.

**The gate stops reviewers on two paths only**, and on either it stops every pending
reviewer and goes to 2d:

- **launch-failed**, from 2b;
- **cancelled**: the user asks the gate to stop while reviewers are pending.

While reviewers are pending, answer any other user message with one line saying the gate
is waiting for its reviewers and can be cancelled; that never changes the outcome.
**There is no deadline.** The gate never starts a stop on its own clock: a reviewer that
hangs holds the gate until the user cancels or interrupts it.

Per runtime:

- **Claude Code.** A launch reply that carries an agent id instead of the reviewer's
  output is a launch receipt. **A receipt is never a result.** Wait for that agent's
  completion notice; its output is the reviewer's output. Never infer, predict or
  summarise a pending reviewer's result. To stop one, call **TaskStop** with its agent
  id; the stop is confirmed only when TaskStop reports success. TaskStop may be a
  deferred tool that must be loaded first: **ToolSearch** with `select:TaskStop`.
- **Codex.** Wait with `wait_agent` on the recorded ids until each has a final status. A
  return with `timed_out: true` carries no final status, so wait again. To stop one, use
  the session's close or interrupt call — `close_agent` where it is exposed, otherwise
  `interrupt_agent` — and the stop is confirmed when `list_agents` or `wait_agent` no
  longer reports it running. Which of these a session exposes is a runtime property, so
  the names are examples of the capability, not a fixed list.

Each reviewer returns findings and ends with one line: `<AXIS> VERDICT: PASS|FAIL`. **A
valid verdict** is exactly one such line naming the reviewer's own axis. Anything else
is **incomplete**: no such line, two such lines, another axis or another word, or a
reviewer that errored, was stopped, is unconfirmed or never started. So every fired
reviewer is exactly one of PASS, FAIL or incomplete. Do not edit any code in response to
findings.

### 2d — Check the workspace

Once every fired reviewer is accounted for, check the workspace, exactly once, on every
path that got past 2a's snapshot:

```bash
"<forgeward-root>/scripts/forgeward-workspace-guard.sh" check "<RUN_DIR>/snapshot"
```

Record its exit status and print its output. If any reviewer is **unconfirmed**, print
right after it:
`forgeward gate: a reviewer may still be running; anything it writes from now on is unchecked.`

Exit 1 means the workspace changed while the reviewers ran: a new or changed path, the
index, `HEAD`, the stash, a hook, the `forgeward.gate` switch, this commit's run file or
one of its markers. The guard names each change and cannot tell a reviewer's from the
user's. A reviewer writing into the repo has happened: a scanner handed a Windows path
from a POSIX shell created a `C:` directory tree at the repo root — untracked, matched
by no common `.gitignore`, and committed by any `git add -A`. **Do not delete the paths
yourself** — they are untracked files whose provenance only the user can confirm, and
the drive-letter shape is actively dangerous to remove: under Git Bash `C:` without a
leading `./` resolves to the **drive root**, so an `rm -rf` there is a far worse bug
than the one it cleans up. Print the paths and let the user run `rm -rf -- "./C:"`
themselves.

Exit 2, or any other non-zero, means the workspace could not be checked, and so does a
check that was denied, timed out, or never ran or reported a status. That is never read
as clean.

## Step 3 — Decide

Decide on 2c's states and 2d's exit status. **The first row that matches wins.** Under
every row, print the verdicts of the reviewers that did return: contamination, or an
incomplete sibling, does not invalidate a security finding. Every row but the last ends
with no marker and **revokes again**, so any marker for the reviewed commit, under any
name, stops reading fresh: a new run id is recorded for that commit, and markers for
other commits are not staled. If that revoke exits non-zero, print its message verbatim
and say that the earlier PASS it names may still authorize a push.

- **1. The workspace changed** (2d exited 1): HALT, whatever the verdicts were. /ship
  stages and commits, so handing off now is how a reviewer's artifact lands in the
  user's history. Revoke:

  ```bash
  "<forgeward-root>/scripts/forgeward-write-marker.sh" --revoke "<HEAD_SHA>"
  ```

  Then stop with:
  `forgeward gate: the workspace changed while the reviewers ran (the changes are above). Check them, delete anything a reviewer left, and re-run. Nothing was shipped.`
  This is a halt, not a FAIL: no marker is written, and none of the reported paths is
  deleted.

- **2. The workspace could not be checked** (2d exited 2 or any other non-zero, or the check did not run or report a status): HALT.
  It is never read as clean. Revoke:

  ```bash
  "<forgeward-root>/scripts/forgeward-write-marker.sh" --revoke "<HEAD_SHA>"
  ```

  Then stop with:
  `forgeward gate: the workspace could not be checked after review (the reason is above), so nothing can be certified. Nothing was shipped.`

- **3. The review did not run to completion** (launch-failed or cancelled): no marker.
  Revoke:

  ```bash
  "<forgeward-root>/scripts/forgeward-write-marker.sh" --revoke "<HEAD_SHA>"
  ```

  Then stop with
  `forgeward gate: not every reviewer could be launched, so the review did not run to completion. Nothing was shipped.`
  or, when the user cancelled,
  `forgeward gate: cancelled before every reviewer finished. Nothing was shipped.`

- **4. A reviewer returned FAIL**: do NOT write a marker and do NOT invoke /ship.
  Revoke:

  ```bash
  "<forgeward-root>/scripts/forgeward-write-marker.sh" --revoke "<HEAD_SHA>"
  ```

  Then print each failing reviewer's Critical/High findings (severity, `file:line`,
  issue, fix) grouped by axis, list any incomplete axes as well, and stop with:
  `forgeward gate: FAIL — fix the Critical/High findings above and re-run /forgeward:gate. Nothing was shipped.`
  FAIL is decided before incomplete so that a measured Critical gets this line, which
  asks for a fix, not a re-run.

- **5. A reviewer is incomplete** (no valid verdict, 2c): no marker. An unmeasured axis
  cannot return PASS, and it is reported apart from findings, never labelled FAIL.
  Revoke:

  ```bash
  "<forgeward-root>/scripts/forgeward-write-marker.sh" --revoke "<HEAD_SHA>"
  ```

  Then name each incomplete axis and why (no verdict line, two, another axis, errored,
  stopped, unconfirmed, not started), and stop with:
  `forgeward gate: incomplete — the axes above returned no valid verdict, so nothing was measured there. Re-run /forgeward:gate. Nothing was shipped.`

- **6. Every fired reviewer returned PASS** (and any self-skipped reviewer counts as PASS): write the pass marker, then ship.

  ```bash
  "<forgeward-root>/scripts/forgeward-write-marker.sh" "<base>" "<comma-separated fired reviewers>" "<BASE_SHA>" "<HEAD_SHA>" "<RUN_ID>"
  ```

  Pass the two full names Step 0 printed and the id 2a's revoke printed, literally.
  Each entry in the fired list is a bare reviewer name, and so is each name in the PASS
  report below: `targeted`, never `targeted(money,secret)`, whose comma would split it
  into two entries that name no reviewer.
  If the writer exits non-zero, nothing was certified: run
  `"<forgeward-root>/scripts/forgeward-write-marker.sh" --revoke "<HEAD_SHA>"`, print
  the writer's message, and stop with no handoff. If that `--revoke` also exits non-zero,
  print its message verbatim too and say that the earlier PASS it names may still
  authorize a push. The usual cause of the refusal is that `HEAD` or the base moved while
  reviewers ran, so the PASS was for code that is no longer what would be pushed, or
  that a later gate run on the same commit superseded this one.

  Then hand off — **but only if there is something to hand off to.** Use
  `gstack_ship` from the Step 1c probe (re-run it if you skipped Step 1c):

  - **Claude Code with `gstack_ship: present`** → invoke the `ship` skill via the
    **Skill** tool. This
    model-initiated invocation is not a user-typed expansion, so the
    `UserPromptExpansion` halt does not fire; the `PreToolUse` push hook will find the
    fresh marker and allow the push.
    Report: `forgeward gate: PASS (fired: …). Marker written. Handing off to /ship.`

  - **Codex, or Claude Code with `gstack_ship: absent`** → **do not attempt a
    Claude Skill call.** Stop here and report:
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

## Rules

- **Read-only.** You never Edit/Write code here. You dispatch reviewers and report.
- **Read-only covers the filesystem, not just the code.** The repo must be
  byte-identical when the gate finishes — no scanner reports, no scratch files.
  Reviewers run scanners through `scripts/forgeward-scan.sh` (report on stdout, output
  flags refused) and take any scratch directory from `scripts/forgeward-artifact-dir.sh`.
  A `PreToolUse` deny and the workspace guard back that up, because the same reviewer
  broke this contract twice — the second time with a spawn prompt that explicitly
  forbade it. Do not treat an instruction as a control, and do not treat the guard as
  complete either: it does not see a gitignored write, an empty directory, or a write made
  after its check, so the instruction still binds. The guard records more than
  paths: the index, `HEAD`, the stash, the hooks, the `forgeward.gate` switch, and this
  commit's run file and markers, so a change to any of them while reviewers ran halts the
  run too.
- **Conditional.** Only fire reviewers whose surface the diff touches; say which you skipped and why.
- **The marker is only written on all-PASS, and only for the commits Step 0 froze.** Every
  run that reaches Step 2 records a new run on the reviewed commit before it reviews
  anything, which stales every earlier PASS for that commit, and every later outcome that
  ends without a written marker revokes again. A write is refused once a later run on
  that commit has started or failed, so only the latest run's outcome can stand. A run
  that stops before Step 2 reviews nothing and leaves an earlier marker in place, still
  bound to its own diff hash and run. A `--revoke` that exits non-zero is reported
  verbatim and stops the gate, because an earlier PASS may still authorize a push. No
  fresh marker ⇒ the push hook blocks /ship. That is the gate.
- **Never lower the bar.** If a reviewer fails, the gate fails. Do not rationalize a FAIL into a pass.
  An incomplete reviewer is not a PASS either, and a launch receipt is never a result.
