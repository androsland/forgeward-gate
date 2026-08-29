# Changelog

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
