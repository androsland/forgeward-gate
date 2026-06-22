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

Two ways in. **Marketplace install** is the one-liner; **local install** (clone +
`--plugin-dir`) is the no-marketplace path, handy for development or pinning to a working tree.
This repo is public, so both work today.

`<PLUGIN_DIR>` below = the absolute path to your clone of this repo (the directory containing
`.claude-plugin/`). From the repo root you can grab it with `export PLUGIN_DIR="$(pwd)"`.

### Local install (no marketplace required)

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

### Marketplace install (recommended)

This repo ships a marketplace manifest (`.claude-plugin/marketplace.json`) and is public on
GitHub, so anyone can add it as a marketplace and install in two commands. Replace
`androsland/forgeward-gate` with your `owner/repo` if you forked it:

```bash
claude plugin marketplace add androsland/forgeward-gate
claude plugin install forgeward@forgeward-gate
```

`forgeward` is the plugin name; `forgeward-gate` after the `@` is the marketplace name (the
`name` field in `marketplace.json`). Per the [Claude Code plugin docs](https://code.claude.com/docs/en/discover-plugins),
the install syntax is `plugin-name@marketplace-name` — **the `@forgeward-gate` suffix is
required, not optional.** Bare `claude plugin install forgeward` does *not* resolve.

> **Note:** `claude plugin install forgeward` (no `@marketplace`) fails with *"Plugin forgeward
> not found in any configured marketplace"* — both because it omits the required marketplace
> suffix **and** because you must run `claude plugin marketplace add androsland/forgeward-gate`
> first. Run the two commands above in order and it resolves.

### After install

The plugin is `defaultEnabled` — reviewers, the `/forgeward:gate` skill, and both hooks
activate on install with no `settings.json` edit. The enforcement hook reads JSON with
`jq` if present, else `python3` (one of which is on virtually every dev machine); if
*neither* exists it fails open — see limits.

## Validation / what's tested

**Automated suite — 21 assertions, `npm test`.** `test/gate-test.sh` is framework-free and
exercises the **real plugin scripts** in `scripts/` (not mocks or copies) against throwaway
git repos. It covers the full enforcement contract:

- **Deny when there's no fresh PASS marker** — `git push`, `gh pr create`, and
  `glab mr create` are all blocked; a typed `/ship` is halted at expansion (exit 2).
- **Allow on a fresh PASS marker** — `git push` proceeds and `/ship` expansion passes (exit 0).
- **Version-bump invariance** — a package.json **version-field-only** bump (gstack's post-gate
  Step 12) leaves the diff hash unchanged, so the marker survives and the push stays allowed.
- **Dependency change forces a re-gate** — adding a dependency flips the hash and re-denies the
  push (the supply-chain bypass this is designed to stop).
- **Stale-code re-gate** — any new source committed after the marker invalidates it.
- **Non-publish commands are never touched**, and **outside a git repo the hook fails open**
  (allows) rather than wedging your shell.
- **Ship matcher** (read from the real `hooks.json`, evaluated with JS-regex semantics) fires
  on `ship`, `gstack-ship`, and any `<prefix>-ship`, and **not** on lookalikes `shipment` /
  `airship`.
- **Base-detection fallback** — resolves `main`/`master` correctly when `origin/HEAD` is unset,
  and honors `origin/HEAD` when it is set (the regression that previously yielded an empty base).

**Live end-to-end.** Beyond the unit suite, the gate was exercised through a real Claude Code
session (see `live-test/LIVE-TEST.md`): the same `git push` was observed **denied** (no marker)
→ **succeeded** (after a PASS marker) → **denied again** once a typosquatted dependency flipped
the hash — proving the actual plugin **hook dispatched**, not just that the scripts work in
isolation. The `supply-chain-reviewer` caught the typosquat with registry evidence.

**What "validated" means here (honest boundary).** Tested means *tested-as-designed* — the
deny/allow logic and live hook dispatch behave as specified. It does **not** mean tamper-proof:
the gate is **enforced-by-default**, and (as in [limit 1](#three-honest-limits)) anyone who
disables the plugin or pushes outside Claude Code is past it. This raises the floor; it is not
a sandbox.

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

## Security scope

**Static review, not dynamic scanning.** forgeward-gate (and gstack's `/cso`, which covers the
general security axis this plugin delegates to it) provide *static* security review — code,
dependencies, secrets, and OWASP/STRIDE reasoning. They do **not** perform dynamic/runtime
scanning (DAST, e.g. OWASP ZAP), run SAST engines, scan container images, or CI-enforce
merge-gating on a security scan. Those require a deployed app and a CI pipeline — handle them in
your project's CI, not here. A gate PASS means the reviewed change is clean, not that the running
application is secure.

## Accepted design gaps (documented, not bugs)

- **Pre-push local mutations aren't gated.** gstack's version bump, CHANGELOG, and commit
  squash happen before the push. They're local and reversible, and `/ship` is
  idempotent-by-re-run, so recovery is native: after `/forgeward:gate` passes, re-run `/ship`.
- **gstack's pre-push Codex review dispatch is out of scope.** It's review, not publishing, and
  gstack has a native switch for it (limit 2). We don't hook or block it.
- **If neither `jq` nor `python3` is available, the enforcement hook fails open.** It allows
  the push rather than wedging your Bash. Virtually every dev machine has one; install `jq`
  or `python3` for the gate to enforce.

## License

MIT — see [LICENSE](LICENSE).
