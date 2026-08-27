# Third-party licenses

forgeward-gate is MIT — see [LICENSE](LICENSE), which covers this repository's own
authorship. This file covers third-party content redistributed inside it.

MIT conditions redistribution of "substantial portions" on the copyright notice and the
permission notice travelling with the copy. The provenance block inside each ported file
records repo, path, commit and sha256, which is what
[`scripts/forgeward-rubric-drift.sh`](scripts/forgeward-rubric-drift.sh) needs to detect
drift — but a source pointer is not a copyright notice, so the notice is reproduced here in
full.

## gstack — Review Army specialist checklists

**Upstream:** <https://github.com/garrytan/gstack>
**Ported at commit:** `9ca8f1d7a9386312d07ce2f40b9b89cf7f62c3e6`

The checklist body of each file below — from its `## Categories` heading to end of file —
is copied verbatim from the corresponding `review/specialists/*.md` in that repo. Each
file's own provenance comment carries the exact `source-path` and `source-sha256`.

| File in this repo | Upstream path |
|---|---|
| `agents/api-contract-reviewer.md` | `review/specialists/api-contract.md` |
| `agents/data-migration-reviewer.md` | `review/specialists/data-migration.md` |
| `agents/maintainability-reviewer.md` | `review/specialists/maintainability.md` |
| `agents/performance-reviewer.md` | `review/specialists/performance.md` |
| `agents/testing-reviewer.md` | `review/specialists/testing.md` |

Everything else in those five files — the scoping instructions, the read-only contract, the
forgeward severity floors, the verdict line, and the provenance block itself — is
forgeward's own and is covered by [LICENSE](LICENSE), not by the notice below.

```
MIT License

Copyright (c) 2026 Garry Tan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## gstack — `/cso` audit phases

**Upstream:** <https://github.com/garrytan/gstack>
**Ported at commit:** `ad8400543cd9ce8d07641362db48d44a95417e33`

| File in this repo | Upstream path |
|---|---|
| `skills/audit/SKILL.md` | `cso/sections/audit-phases.md`, and parts of `cso/SKILL.md` |

**This one is adapted, not copied verbatim, and the difference matters for what you are
reading.** Phases 2-11 of `skills/audit/SKILL.md` follow the upstream file's structure,
its severity assignments, its false-positive rules and its search patterns closely enough
to be a derivative of a substantial portion; Phases 0, 1, 12, 13 and 14 draw the same way
on `cso/SKILL.md`'s mode resolution, hard-exclusion list, precedents, findings table and
report schema. The prose is rewritten throughout, several decisions are deliberately
reversed (the report is written outside the repo, scanners route through
`forgeward-scan.sh`, and forgeward does **not** exempt its own skills from Phase 8), and
the surrounding contract — the read-only tool set, the non-goals, the gate's relationship
to it — is forgeward's own. Attribution here is not a claim about which lines are whose;
it is the notice travelling with the copy, as MIT requires, applied conservatively.

Both sections are covered by the single notice above. There is one upstream, one
copyright holder and one licence; reproducing the text twice would not add anything.

**Its provenance block is checked as of 0.20.0.** `forgeward-rubric-drift.sh` iterates
`skills/*/SKILL.md` alongside `agents/*-reviewer.md`, so the `source-sha256` in
`skills/audit/SKILL.md` is a monitored pin rather than a record. Only the Phases 2-11
source is hash-pinned at all, and that has not changed: `cso/SKILL.md` mixes the audit
method with gstack's own preamble, telemetry and learnings machinery, so a hash over it
would fire on changes that have nothing to do with this port. What is monitored is
`cso/sections/audit-phases.md`; Phases 0, 1, 12, 13 and 14 remain unpinned.

## What this file does not do

It is **not** a dependency manifest. forgeward-gate declares no runtime dependencies —
`package.json` has no `dependencies` or `devDependencies` key at all — so nothing here is
generated from a lockfile and nothing scans for it. It lists source that was **copied into
this tree**, which is the only category a lockfile cannot see.

Nothing keeps it current automatically. `forgeward-rubric-drift.sh` notices when the
*content* of a ported rubric moves — for the five files under `agents/` and for
`skills/audit/SKILL.md`. It does not notice a new port, a removed port, or an upstream
**relicensing**. Adding or dropping a ported file means editing this table by hand, in the
same commit.
