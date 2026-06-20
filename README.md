# forgeward gate

> gstack ships fast. forgeward-gate makes sure it ships clean — an enforced, read-only review
> gate that blocks the push until privacy, accessibility, AI-output, SEO, and supply-chain
> checks pass.

An **enforced, read-only conformance gate** for [gstack](https://github.com/garrytan/gstack).

gstack covers think → plan → build → review → test → ship. The one thing it lacks is a
*blocking* gate: its `/ship` is fully automated and never refuses to publish. This plugin
adds the reviewers gstack has no equivalent for and makes them **block `/ship` until every
fired reviewer returns `VERDICT: PASS`.** It touches zero gstack files.

## What it adds (and what it deliberately doesn't)

Five read-only reviewers, each firing **only** when the diff touches its surface:

| Reviewer | Fires when the diff touches | Why it's here (not redundant with gstack) |
|----------|------------------------------|-------------------------------------------|
| `privacy-reviewer` | personal data | gstack's `/cso` is intrusion-security, not lawful data handling |
| `accessibility-reviewer` | UI | gstack's design reviews are taste/AI-slop, not WCAG 2.1 AA conformance |
| `ai-output-reviewer` | an LLM / paid-AI call | gstack covers prompt-injection for *its* browser, not *your* LLM output reliability/cost |
| `seo-reviewer` | public, indexable pages | no SEO/crawlability/metadata coverage anywhere in gstack |
| `supply-chain-reviewer` | a dependency manifest | gstack's `/cso` Phase 3 covers CVEs/install-scripts/lockfiles but **not** typosquatted/hallucinated packages or copyleft-license conflicts |

**Not included on purpose:** a code-quality reviewer (gstack's `/review` covers it) and a
general security reviewer (gstack's `/cso` covers OWASP + STRIDE + dependency CVEs). We
ported only the verified `/cso` gap into `supply-chain-reviewer`.

## How it works

- **Happy path:** run `/forgeward:gate`. It detects which surfaces the diff touches, fires
  only the relevant reviewers (read-only — `Read, Grep, Glob, Bash`, no edits), and on
  all-PASS writes a pass marker and hands off to gstack's `/ship` in one motion.
- **Enforcement (two hooks, shipped in the plugin, auto-registered on install):**
  1. `UserPromptExpansion` on a typed ship command → halts immediately if there's no fresh PASS
     for the current code, before any work runs. The matcher is `^([A-Za-z0-9_]+-)?ship$`, so it
     fires on `ship` **and** any prefixed variant (`gstack-ship` and any custom gstack `--prefix`),
     and not on lookalikes (`shipment`, `airship`).
  2. `PreToolUse` on `Bash` → denies `git push` / `gh pr create` / `glab mr create` unless a
     fresh PASS marker matches the current code. This is the floor; it fires no matter how
     `/ship` was triggered.

**Enforcement holds for every gstack install variant.** The floor (hook 2) matches the *publish
command*, not the skill name, so it is completely prefix-independent — whether gstack is installed
plain, with `--prefix`, or under a custom prefix, an un-gated push is blocked. Hook 1 (the fast
early halt) covers `ship` and any `[A-Za-z0-9_]+-ship` prefix; only an exotic prefix containing
characters outside `[A-Za-z0-9_]` would slip past the *early* halt (the floor still catches it). To
cover such a prefix, add it to the alternation in `hooks/hooks.json` → `UserPromptExpansion.matcher`
(e.g. `^(my.weird.prefix-)?ship$`) and run `/reload-plugins`.

The marker pins a hash of the **reviewed code and dependencies** (`base...HEAD`), excluding
only gstack's cosmetic post-gate writes (`VERSION`, `CHANGELOG*`, `TODOS.md`) and a
package.json **version-field-only** bump. Any change to source **or dependencies** after the
gate flips the hash and forces a re-gate — a dependency added between gate and push does
**not** sail through.

## Install

Two ways in. **Local install works today** with nothing published; the **marketplace
install** is the one-liner for everyone else once this repo is public.

`<PLUGIN_DIR>` below = the absolute path to your clone of this repo (the directory containing
`.claude-plugin/`). From the repo root you can grab it with `export PLUGIN_DIR="$(pwd)"`.

### Local install (works today — no marketplace required)

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

### Marketplace install (once this repo is published)

This repo ships a marketplace manifest (`.claude-plugin/marketplace.json`), so once it's
public on GitHub anyone can add it as a marketplace and install in two commands. Replace
`androsland/forgeward-gate` with your `owner/repo` if you forked it:

```bash
claude plugin marketplace add androsland/forgeward-gate
claude plugin install forgeward@forgeward-gate
```

`forgeward` is the plugin name; `forgeward-gate` after the `@` is the marketplace name (the
`name` field in `marketplace.json`). The `@forgeward-gate` suffix disambiguates when you have
multiple marketplaces added.

> **Note:** `claude plugin install forgeward` on its own fails with *"Plugin forgeward not
> found in any configured marketplace"* until you've run `claude plugin marketplace add` first
> (or until this repo is published and added). If you haven't published yet, use the local
> install above.

### After install

The plugin is `defaultEnabled` — reviewers, the `/forgeward:gate` skill, and both hooks
activate on install with no `settings.json` edit. The enforcement hook reads JSON with
`jq` if present, else `python3` (one of which is on virtually every dev machine); if
*neither* exists it fails open — see limits.

## Three honest limits

1. **Enforced by default, not tamper-proof.** A normal user can't accidentally skip the gate
   and configures nothing. But anyone can disable the plugin (`claude plugin disable
   forgeward`) or push outside Claude Code entirely, and the gate is gone. No plugin can stop
   a user who removes the plugin. This raises the floor; it is not a sandbox.

2. **gstack's Codex review is a separate privacy exposure this gate does not cover.** gstack's
   `/ship` and `/review` send your work to OpenAI's Codex for a second opinion by launching
   `codex` with **read access to your whole working tree** (not just the diff), and gstack's
   redaction guard does **not** scrub what Codex reads. If that matters to you, turn it off
   with `gstack-config set codex_reviews disabled`. forgeward's gate works fully either way —
   this is a gstack setting, not a forgeward one.

3. **No mandatory paid-OpenAI dependency.** gstack's Codex steps degrade to Claude when no
   OpenAI key is present, so the stack underneath this plugin runs fully on Claude alone. The
   only paid dependency is the Claude access you already need to run Claude Code.

## Accepted design gaps (documented, not bugs)

- **Pre-push local mutations aren't gated.** gstack's version bump, CHANGELOG, and commit
  squash happen before the push. They're local and reversible, and `/ship` is
  idempotent-by-re-run, so recovery is native: after `/forgeward:gate` passes, re-run `/ship`.
- **gstack's pre-push Codex review dispatch is out of scope.** It's review, not publishing, and
  gstack has a native switch for it (limit 2). We don't hook or block it.
- **If neither `jq` nor `python3` is available, the enforcement hook fails open.** It allows
  the push rather than wedging your Bash. Virtually every dev machine has one; install `jq`
  or `python3` for the gate to enforce.
