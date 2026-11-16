# Changelog

## 0.31.0 — 2026-11-16

### Upgrading

- Every marker written before 0.31.0 reads as not passed: the hooks now require the
  marker's gate run (`run_id`, schema 5), which older markers do not carry. Run
  `/forgeward:gate` once per branch you mean to push.
- An installed pre-push hook runs the enforcer at the path it was installed from: the
  installer writes that path into the hook. Where an earlier forgeward still sits at that
  path, the enforced hook keeps running it and does not check the gate run; where the
  path is gone, every push fails with exit 127. Re-run
  `scripts/forgeward-install-pre-push.sh` in every repo where it is installed.

### Fixed

- Both hooks refuse a PASS whose gate run is no longer the latest for its commit. The
  marker records its run id, and a marker is accepted only while
  `forgeward-gate-runs/<reviewed_head>` still holds that id, and never for a pushed
  commit that has a run file of its own and is not the marker's `reviewed_head`. Before,
  the only thing standing between a newer run and an older PASS was `--revoke` deleting
  the old marker by name, and that name list missed a marker under the historical
  `heads/<name>` spelling, the detached `HEAD` key, a push's destination branch, and a
  write that landed after the delete.
- Each hook reads a marker once: every field comes from one private copy, so a marker
  replaced while a push is checked can no longer lend its current run to a stale PASS
  whose diff hash matches.
- `forgeward-diff-hash.sh` exits 1 with a message when `git diff` fails (no merge base, a
  bad ref, a missing blob). It used to hash such a pair as the empty diff and exit 0, so a
  later commit on it could match that hash.

- The PASS marker now certifies the commits the reviewers were given. Step 0 freezes the
  base and head commits and every later step reviews that range; the marker writer
  refuses when `HEAD` moved or the base moved in a way that changes the diff, and hashes
  the frozen pair. Before, a commit landing while reviewers ran was certified by a marker
  nobody reviewed.
- A gate run that reaches review withdraws the earlier PASS of every local branch at the
  reviewed commit first, and again on every later outcome that ends without a marker, so
  a failed re-run no longer leaves an old PASS, on this branch or a sibling at the same
  commit, authorizing the same diff.
- The marker writer refuses a reviewed pair, or a base ref and reviewed head, that share
  no merge base (an orphan branch, a shallow clone). The diff hash of such a pair was the
  empty-diff hash, which the hooks recompute identically for any later code on it.
- A reviewed commit id must resolve to itself. In a SHA-1 repo a branch named with 64 hex
  characters passed the full-id check and resolved to that branch's live tip, and an
  annotated tag's id peeled to a commit, so the moved-HEAD check passed vacuously.
- `--revoke` withdraws each branch's marker under both its short and its canonical name.
  A tag created after the write and named like the branch hid the marker from revoke,
  while the push hook still accepted it.
- `--revoke` fails loudly (exit 1) when the branches at the commit cannot be listed, for
  example because a branch ref points at a missing object, and still withdraws every
  other marker it can. It used to withdraw only the current branch's and exit 0.
- `--revoke` withdraws the markers at the commit Step 0 froze, not at live `HEAD`, so a
  checkout change during the run no longer leaves the reviewed commit's earlier PASS
  standing through a failed re-review.
- Two gate runs on the same commit no longer race: a run whose write comes after a later
  run on that commit started (and perhaps failed) is refused, and a marker it already
  wrote is removed.

### Changed

- `forgeward-write-marker.sh` takes `<base-ref> <fired-csv> <reviewed-base>
  <reviewed-head> <run-id>`; all five are required (fired may be empty), and every usage
  error exits 64. The two reviewed arguments must be the full commit ids Step 0 printed
  (40 or 64 lowercase hex) and must resolve to themselves; `HEAD`, a branch name or a
  short hex is refused. `<run-id>` is the id `--revoke` printed.
- New `--revoke <reviewed-head>` mode. It takes the commit Step 0 froze, records a new
  gate run for it, withdraws every marker at it, and on success prints `RUN_ID=<id>` as
  its last line. Recording the run is what stales the earlier markers for that commit;
  the deletions withdraw a branch's PASS for an earlier commit with the same diff, which
  that run file does not reach, and are the only revocation an enforcer installed before
  0.31.0 sees.
- Run files (`forgeward-gate-runs/<commit>` under the common git dir) are kept, one small
  file per commit ever gated; nothing deletes them. Deleting the directory by hand makes
  every marker read stale and drops those commits' refusal of a same-diff PASS on another
  commit.
- The marker is schema 5 and carries `run_id`. The diff hash is unchanged, so a `/ship`
  version-bump commit still pushes on the PASS before it.

## 0.30.0 — 2026-10-19

### Changed

- Re-port `maintainability-reviewer` and `testing-reviewer` from gstack `47d639ab`, the
  first re-port since the 0.17.0 port: "DRY Violations" becomes "Duplicated Behavior with
  Defects", stale user-facing strings join the stale-comment checks, and the testing
  checklist gains negative assertions, low-value or implementation-coupled tests, weak-only
  coverage and regression tests with no red proof. Checklist bodies stay verbatim; a
  forgeward-owned "Reading the ported checklist" section maps gstack's pipeline vocabulary
  and keeps the blocking surface where it was.
- Re-port `/forgeward:audit` Phases 2-11 from gstack `47d639ab`: no package-manager audit
  or install on the host, chain-traced CI/CD and infrastructure judgement, OWASP API
  Security Top 10:2023, LLM/agentic/MCP guidance, OWASP Top 10:2025 with selected ASVS 5.0.0
  requirements, STRIDE per trust transition, and a new scanner-evidence section. Upstream
  changes that the unported Phase 12 still contradicts are held back and filed.
- The re-ported audit's severity rules follow the newer method: development dependencies
  and private networks no longer cap severity, an unpinned third-party action is HIGH only
  on a traced chain to a credential or write capability, and the no-fix-available
  exclusion is gone.
- `testing-reviewer`: a test that cannot fail, including a self-comparison, stays High,
  and does not replace a deleted test; a smoke check that replaces one is Medium. The new
  `gstack:test-value keep` marker and retention bar lower only the low-value grading, never
  a High, and the reviewer never repeats a marker's reason text. A copy compared with its
  original counts as a self-comparison only when it was made without the code under test,
  so a round trip through an encoder and decoder is not one.

### Fixed

- `/forgeward:audit` passes `--config /dev/null` to every trivy call, so the audited repo's
  `trivy.yaml` cannot redirect the report to a path it chooses (measured on trivy 0.74.0).
  It never opens a tracked `.env`, scanning it through redacted gitleaks instead. It gives
  each trivy subcommand only the offline flags that subcommand accepts, runs osv-scanner
  offline, runs zizmor with no GitHub token, and never fetches the ASVS standard. The
  gate's reviewers have the same trivy exposure; it is filed at P1 in `TODOS.md`.
- `/forgeward:audit` keeps commit messages out of the transcript. On gitleaks 8.30.1,
  `--redact` blanks a history finding's secret but leaves the commit message, which can
  quote the credential. Phase 2 now passes gitleaks JSON through a `jq` filter that keeps
  only the rule id, file, line, commit and entropy. Its `git log` searches print the commit
  hash instead of the subject.
- `/forgeward:audit` lists and scans tracked `.env` files in one loop that reads each name
  as data, so a committed filename holding `$(…)` cannot run there. The rule against
  pasting a name the repository chose now covers every name Phase 2 prints. The loop also
  finds `.env.*` files below the repository root, which the old pathspec missed, and
  prints each name with `%q`, so a newline in a name cannot forge a label.
- `/forgeward:audit` scans the blob the index holds, not the work-tree copy, so a file
  marked `--skip-worktree` is judged by what was committed. It scans templates too: a
  live token in `.env.example` is MEDIUM, and a template is matched by its basename.
- `/forgeward:audit` filters trivy's output down to the check id, severity, title,
  resource and line range. On trivy 0.74.0, a misconfiguration record quoted the lines it
  flagged, and printed a Terraform resource's password. trivy's log goes through an `awk`
  allow-list, because a module that failed to load logged a token from its source URL.
- `/forgeward:audit` runs its misconfiguration scan in an empty network namespace
  (`unshare -rn`). With every offline flag set, trivy still fetched the remote Terraform
  modules the scanned tree named, from hosts that tree chose. Where `unshare -rn` fails,
  the scan leaves Terraform out and says so. Every trivy call also carries
  `--skip-version-check`.
- `/forgeward:audit` locates credential-shaped matches with `git grep … | cut -d: -f1,2`,
  so a search for an inline CI secret or a connection-string password prints where it is
  and not what it is.
- `/forgeward:audit` passes forgeward's own gitleaks config and ignore file, and scans
  from the git directory, so the audited repo's `.gitleaks.toml` and `.gitleaksignore`
  cannot suppress findings about it.
- `/forgeward:audit` reads a gitleaks exit 1 as findings only when records came back,
  since a configuration gitleaks could not load also exits 1. A `--diff` base that does
  not resolve is reported as a gap, not read as a clean history. The range is two-dot, so
  the base's own commits are not reported as the branch's. Each status line is printed by
  the command it reports on, because zsh has no `PIPESTATUS`.
- `/forgeward:audit` prints trivy's "Falling back to embedded checks" as a fixed line, not
  as a withheld error, so a machine with no cached checks bundle does not fail Phase 5.
- `/forgeward:audit` scans development dependencies with trivy's `--include-dev-deps`, now
  that they no longer cap severity, and reports pnpm and other uncovered ecosystems as a
  gap.
- `/forgeward:audit` hands a secret candidate's Phase 12 verifier the filtered scanner
  record, never the file, and that record satisfies the quote rule. The verifier grades a
  tracked `.env` by Phase 2's rule. This is forgeward's own rule, not part of the upstream
  port.
- The gate's `security-reviewer` still prints the commit message from gitleaks, prints
  trivy's misconfiguration excerpts, loads the reviewed repo's gitleaks config and lets
  trivy fetch remote modules. That is filed at P1 in `TODOS.md`, not fixed here.

### Tests

- Bump the manifest version-agreement literal in `test/dual-client-test.sh` to 0.30.0.
- R6b: every reviewer with a `source-path` must carry a `source-commit` that appears in
  its row of `THIRD-PARTY-LICENSES.md`, and the audit's must appear in the `/cso` section.
- P8n: a scanner the wrapper cannot find exits 127 with exactly the stderr line
  `/forgeward:audit` tells the model to look for, quoted once in the skill.
- P8o: runs the audit's `.env` loop against hostile file names and a stub gitleaks. No
  name runs as a command, a newline cannot forge a label, every scan reads the index
  blob with the bundled config from the git directory, and a name that merely contains
  `.env` is not scanned.
- P8k: the history recipe keeps a finding and drops a key quoted in the commit message,
  with a control that shows the raw `--redact` JSON prints it.

### Docs

- Record per-file port commits in `THIRD-PARTY-LICENSES.md`, and update the gate scope table,
  README and audit description to the new checklist names.

## 0.29.0 — 2026-09-12

### Added

- Scan every pushed branch and commit-resolving tag with Gitleaks in commit-history mode,
  independently of PASS-marker freshness, and block credentials with fully redacted
  rule/file/line output.
- Add a visible, value-free logged `FORGEWARD_SECRET_SCAN=skip` escape hatch while retaining
  Git's native `--no-verify` bypass.

### Changed

- Fail open loudly when the optional Gitleaks binary is absent, but fail closed when a
  pushed range cannot resolve or an installed scanner fails or returns invalid JSON.
- Install as `pre-push.local` when gstack's managed hook owns `pre-push`, without modifying
  that wrapper or overwriting any foreign hook.
- Drop the PII/internal warning tier; the push guard reports only blocking credential
  findings and the status of missing or bypassed capability.

### Tests

- Cover new branches, hash-excluded `TODOS.md` changes after PASS, add-then-remove history,
  tags, safe fixtures, output non-disclosure, parser agreement, scanner failure, bypass
  logging, gstack chaining, foreign-hook preservation, and optional live Gitleaks controls.

## 0.28.0 — 2026-09-10

### Added

- Add explicit-only `/forgeward:pentest`: OWASP ZAP for generic DAST and nuclei for
  application-specific HTTP templates emitted with Forgeward findings.
- Add a deterministic Docker runner that refuses caller-controlled active targets and
  remote Docker contexts, starts the reviewed app and scanners on one `--internal`
  network, measures external-route isolation before boot, sanitizes the copied worktree
  and environment, publishes no port, bounds scanner time, and tears down on exit.
- Add an explicitly authorized ZAP baseline-only fallback when the active envelope cannot
  be built. The fallback never runs ZAP attack rules or nuclei.

### Changed

- Teach audit findings and Medium/Low security-review findings to emit a confined
  `{{BaseURL}}` nuclei template when the issue is reproducible over HTTP, or a concrete
  not-applicable reason otherwise.
- Recognize the skill-owned `pentest:` config subtree without letting the gate parse,
  return, or count it as discarded configuration.
- Replace plugin-wide “no runtime scanning” claims with the narrower truth: the gate and
  audit remain static, pentest is separate and local-only, and nothing inspects production.

### Tests

- Exercise confirmation refusal, internal-network construction, fixed active targeting,
  source and image-env scrubbing, custom-template execution, absolute-target rejection,
  remote-context refusal, passive-only fallback, and non-HTTP URL refusal through a mocked
  Docker boundary.

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
