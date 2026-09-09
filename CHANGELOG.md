# Changelog

## 0.27.1 — 2026-09-09

### Fixed

- Launch native-Windows lifecycle hooks when Codex supplies `PLUGIN_ROOT` as a normal drive or
  UNC path, or with Win32's `\\?\` drive or `\\?\UNC\` prefix. The hook calls
  `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` explicitly, and the tracked
  launcher normalizes the root before invoking Git Bash.
- Preserve literal percent signs, spaces, and parentheses in plugin paths, and translate UNC
  script paths to Git Bash's `//server/share` spelling.
- Fail open silently when the tracked guard adapter is absent or no compatible Git Bash can be
  proven runnable.

### Tests

- Execute committed Windows hook definitions through Codex 0.153.4's `COMSPEC /C` raw-command
  boundary for all four root spellings, exact allow/block/deny behavior, both supported Git
  layouts, and both fail-open routes.
- Retain the pre-fix direct-batch command as a negative control and assert its native exit code
  and stderr.

## 0.27.0 — 2026-09-04

### Changed

- Re-land the supply-chain reviewer's scanner-coverage procedure, lost when PR #55 was
  merged into a base branch that had itself already merged
  (`agents/supply-chain-reviewer.md`, 149 to 840 lines).
- Read a scanner's stdout as a findings record and its stderr as the coverage record.
  Four `osv-scanner` stderr checks, an exit-code table, and the `osv-scanner.toml` /
  `.trivyignore` config-suppression bypasses, each keyed on the `Loaded filter from`
  line at the default `info` verbosity.
- Pin `trivy fs` to one positional path with `--ignorefile /dev/null` and an explicit
  severity, skip, ignore-policy and pkg-relationships set, so a config file sitting
  beside the target cannot suppress a finding without saying so.
- Require single quotes and a `--` on every diff-derived string interpolated into a
  shell command — the trivy invocation, the `osv-scanner` substitute, and the registry
  existence probes — and report a manifest path carrying shell-active bytes as a
  finding rather than merely quoting it safely.
- Validate a package name against the ecosystem's own name grammar in both directions,
  so a name inside the allowlist that abuses the grammar is still caught.

### Docs

- Record in `live-test/LIVE-TEST.md` that the scanner-coverage protocol and the
  shell-quoting / package-name defence are exercised by no scenario there and by
  nothing in `npm test`.

## 0.26.0 — 2026-08-29

### Changed

- Pin every Claude Code reviewer agent to Sonnet with medium effort in native agent
  frontmatter.
- Pin every Codex reviewer spawn to `gpt-5.6-terra` with medium reasoning and no parent
  conversation fork.
- Apply the same runtime-specific selection to `/forgeward:audit` verifier subagents.
- Bound Gate reviewer prompts to the complete rubric, repository/plugin roots, exact
  base/head diff context, read-only instruction, and verdict format.

### Tests

- Enumerate all canonical reviewers and prove that none can inherit a parent model,
  effort, reasoning setting, or conversation context.
- Preserve and test Gate's fail-closed unknown-runtime behavior and Audit's labeled
  self-verification fallback.
