# TODOS — completed

Completed work archived out of [`TODOS.md`](TODOS.md), newest first. It lives here
because `TODOS.md` is read in full on every pre-commit sweep, and finished work can
never be acted on by a sweep.

**Ordering is by MERGE ORDER, not by the `Fixed` date printed in an entry** — several
entries carry the same date, and #26 merged 39 minutes *after* #27 despite the lower
number, so both a date sort and a number sort get this file wrong. Resolve with
`git log --first-parent` before inserting anything.

**And "merge order" means when the work reached `master`, which is not what
`gh pr view --json mergedAt` reports.** That timestamp is when the PR merged into *its
own base*, and a stacked PR's base is another branch. Pass 6 hit both directions of this
in one batch: #49 reports `2026-08-27T05:10:01Z`, but its base was #48's branch, so its
content reached `master` at `05:13:51Z` inside #48's merge commit — the two are one
landing and are filed here as a tie, in version order, because nothing separates them.
And #55 reports a merge that reached `master` at no time at all. Resolve a stacked PR by
finding the first `--first-parent` commit of `master` that contains it, never by its
`mergedAt`.

Six passes so far: 12 entries at 0.10.0 (#27), 4 more at 0.12.0, 1 on 2026-08-17,
4 on 2026-08-18, 4 on 2026-08-19 and **14 on 2026-09-03**. Each pass is relief, never a
fix — `TODOS.md` was over the ~50KB threshold after all six. **Keeping "the 5 most recent" bounds
the entry COUNT, not the byte count**, and the four passes that measured
themselves show what that is worth: pass 3 archived **6,883 bytes** and wrote
**5,491** back as the `## Completed` entry for the newly-merged work, a net
**−1,392 on an 85,990-byte file**; pass 4 had eight entries to bring back to five,
archived **18,863** and wrote **4,086** back, a net **−15,032 on a 117,273-byte
file**; pass 5 had nine, archived **24,149** and wrote **10,335** back across three
entries — two of them for work that had merged with no entry at all — a net
**−12,608 on a 112,018-byte file** — smaller than 24,149 − 10,335 because the same
commit also stamped #38 and wrote a trigger re-check into the open half, which is
the general case: a pass's net is never just its cut minus its write-back. **Pass 6 is
the outlier, and it is an outlier for a reason the convention does not cover.** It found
`## Completed` at eight, wrote four more for six merged PRs that had left no entry —
twelve — then moved one of those four straight back out when the tree contradicted it,
and archived six. Separately it archived **eight entries that had been struck in place
and left sitting in live sections**, where a sweep reads them in full every time.
Fourteen entries out: **49,978 bytes** archived against **14,404** written back, a net
**−35,574 on a 206,250-byte file**. That is 49,978 against **49,895** for passes 3, 4
and 5 combined — a margin of 83 bytes, which is a coincidence and not a trend. None of
it came from the convention working better: **eight of the fourteen were never in
`## Completed` at all**, and nothing in the convention says anything about them. The
relief scales with how far the section drifted past five, not with the convention —
run against a section already at five, a pass cuts one, adds one and moves almost
nothing. Anyone expecting this convention to shrink `TODOS.md` should stop
expecting it; what it buys is that a sweep reads five current entries instead of
forty-one stale ones. If the byte count is ever
the actual problem, the lever is the open half (**156,631 bytes across 13 topic
sections, 91.8% of the file — up from 80% at pass 5, and rising as a share every time
only the completed half is cut**), not this one. Pass 6 archived 24% of the file and
took 17% off it net, and the open half's *share* still rose by twelve points — which is
the clearest statement of this paragraph there is going to be.

Nothing was pruned. These entries carry the reversed decisions, the deliberate
non-goals and the "we shipped the narrow fix on purpose, here is what it does not
cover" that a later change needs before it re-opens the same ground. The rules worth
obeying were lifted into [`CLAUDE.md`](CLAUDE.md) on the way out, and this file is
their provenance — grep here before overriding one of them.

`DECISIONS.md` remains the source of truth for *why* a design is the way it is. This
file records what was done and what it deliberately left undone.

- **CLOSED 2026-08-27 — `trivy fs`'s one-path arity is now verified against a BINARY,
  on a pinned tag.** The source read stands: per `pkg/commands/app.go`, `filesystem`'s
  `PreRunE` calls `validateArgs`, which errors when `len(args) > 1`. Confirmed empirically
  on **trivy 0.74.0**: `trivy fs dirA dirB` prints `Usage: trivy filesystem [flags] PATH`
  and exits **1** — it fails loudly where gitleaks silently rescoped to the cwd. The
  second claim in the same block was confirmed too: trivy's `-o` really is a filename,
  and `trivy fs -f json -o json dirA` created a 233-byte file literally named `json`.
  The earlier caveat — unconfirmed against a running binary, version read was `main`
  rather than a pinned tag — no longer applies. gitleaks 8.30.1 and semgrep were already
  confirmed empirically (semgrep genuinely takes many paths: two given, two in
  `paths.scanned`). Kept as reference data, not open work.
  (gitleaks untracked-.env fix, 2026-08-10; verified 2026-08-27) **Priority:** —
- **CLOSED 2026-08-27 — the four unverified per-tool arities are all measured, and
  every documented claim held.** The gitleaks defect was a documented plural where the
  tool takes one, and it survived three releases because nobody ran the check; the same
  pass has now been run on each of the four, against two distinguishable fixture
  directories:

  | tool | version | positional arity | evidence |
  |---|---|---|---|
  | `phpcs` | 4.0.4 | **many** | both files returned their own `FILE:` header and finding count |
  | `osv-scanner` | 2.5.1 | **many** | `dirA/requirements.txt` and `dirB/requirements.txt` both appear as distinct `source.path` values in one run |
  | `grype` | 0.117.0 | **one** | `accepts at most 1 arg(s), received 2`, exit 1 |
  | `syft` | 1.51.0 | **one** | `accepts at most 1 arg(s), received 2`, exit 1 |

  **No scanner forgeward invokes has the gitleaks failure mode.** grype and syft are
  anchore Cobra CLIs and refuse a second path loudly, exactly as trivy does; phpcs and
  osv-scanner genuinely take many. Nothing in `agents/*.md` or `forgeward-scan.sh`
  needed correcting — that is the finding, and it is the reason this closed with no
  code change.

  **Two facts that were not previously written down.** `syft` takes one path, which no
  prompt documents because no reviewer invokes syft — it appears only in the `-o`
  exemption list. And `osv-scanner` takes many, which makes
  `agents/supply-chain-reviewer.md`'s "equivalent substitute" phrasing an understatement
  on the one axis this entry cares about. The correction to that prompt shipped in its
  OWN PR, not this one: `agents/*.md` is a reviewer prompt, and the executable-behaviour
  rule keeps a five-line prompt edit out of a two-hundred-line prose-and-test diff. **That
  PR was #55, and splitting it out is what exposed it** — it merged into a base branch that
  had already merged, so the correction sat on a ref `master` cannot reach until it was
  re-landed at 0.27.0 (2026-09-04). The rule was right and the stack it created was not.
  (gitleaks untracked-.env fix, 2026-08-10; verified 2026-08-27; re-land noted 2026-09-04)
  **Priority:** —

- **✅ FIXED (0.19.0, 2026-08-26) — `deep-audit` is forgeward's own axis now.**
  `/forgeward:audit` ports gstack's `/cso` audit phases as a skill rather than a reviewer,
  and the gate's Step 1c no longer defers the axis to anything. The entry's premise — that
  orchestration cannot be ported — turned out to be false in the direction that mattered:
  `/cso` is orchestration expressed entirely in prose, and prose ports. What it is **not**
  is a reviewer, so it does not join the Step 1 table and the gate does not fire it; the
  gate stays diff-scoped and the audit stays whole-repo, which is the distinction that made
  the deferral look necessary in the first place. The disclosure survives in a smaller and
  more honest form — keyed on *not run by this gate*, never on whether a tool is installed,
  because after the port a presence probe reads `present` on every machine and would
  license a claim nobody checked. Read-only is structural: the skill declares
  `allowed-tools` without `Edit` or `Write`, and A30 asserts a non-empty floor because a
  *missing* key grants every tool.
  *Original text follows, unedited apart from this lead.* Explicitly scoped OUT of the port: `/cso` is a
  whole-repo audit, not a checklist, so there is nothing to port — it is orchestration, and
  the delta-scoping hole is therefore real and unfixed. What is worth checking before
  filing more work against it: unlike `quality`, this deferral is *disclosed* rather than
  silently assumed, `security-reviewer` still runs diff-scoped so it is not a total gap,
  and `/forgeward:ci-gate` is a standing substitute. That is a materially better position
  than quality was in, which is why it did not ride along with this PR. **Priority:** P3

- **✅ FIXED (0.20.0, 2026-08-26) — `forgeward-rubric-drift.sh` now iterates
  `skills/*/SKILL.md` as well, so `/forgeward:audit`'s `source-sha256` is compared on
  every gate run.** Shipped with four assertions, and only two of them are controls
  against the *pre-fix* script: R14 (a ported skill is scanned, and keyed by its
  DIRECTORY — the basename is the constant `SKILL.md`, so a basename key reported every
  skill as `SKILL`, and the assertion checks the broken form explicitly because
  `ok       beta` and `ok       SKILL` are not mutually exclusive outputs) and R14b (a
  gstack checkout is recognised by `cso/` as well as by `review/specialists/` — the
  audit phases live under `cso/`, so a checkout holding one and not the other read as
  no-gstack and the whole run went quiet). Both verified to fail against
  `git show HEAD:scripts/forgeward-rubric-drift.sh`. **R14c and R14d are green against
  the pre-fix script by construction and are controls against the plausible WRONG fix**,
  which is the distinction worth carrying: R14c pins that the fallback scan is
  landmark-major rather than candidate-major (candidate-major is shorter and lets a
  `cso`-only root shadow a `review/specialists` root that sorts later, which nothing else
  here would redden — verified by mutation), and R14d is R6's floor for the skills half,
  reading the shipped tree with no fixture in the path.

  **A fifth assertion, R14e, was added by the review that gated this branch, and the
  finding it pins is the one worth remembering.** Landmark-major ordering is asymmetric:
  it stops a `cso`-only root shadowing a `review/specialists` one and does nothing in the
  other direction, because the first candidate holding `review/specialists` won outright.
  A plugin-cache directory sorting earlier (`1.10.0` sorts before `1.9.0`) that predates
  `cso/` was therefore selected over a complete checkout on the same machine, and the run
  printed `no longer exist ... Upstream may have renamed or removed them` for the audit
  port while the file it names sat one directory over — an advisory asserting something
  false about upstream, which is strictly worse than this script's default silence.
  Reproduced against the shipped script before fixing. A completeness pass now runs
  first and takes the first candidate holding EVERY landmark, with the landmark-major
  scan kept as the fallback for a genuinely partial machine. Two things made it survive
  the first pass and both are the lesson: the code comment claimed the ordering stopped
  "a partial checkout shadow[ing] a complete one" without naming the direction it does
  not cover, and **R14c called one of its two partial fixture roots "complete"** — so the
  case read as already tested by an assertion that never built it. Found independently by
  the maintainability specialist and by `codex review`; neither the suite nor the author's
  own critical pass caught it. The entry's twelve-site snapshot was wrong in both
  directions. Two sites it missed were `README.md`'s no-gstack paragraph and
  `THIRD-PARTY-LICENSES.md`'s "what this file does not do" paragraph, both of which
  stated the old scope in prose the `\*-reviewer\.md` grep does not match — which is the
  snapshot's own stated failure mode arriving on schedule. It also over-counted by two in
  the other direction: `README.md`'s provenance paragraph and `test/gate-test.sh`'s R6
  loop scope themselves to the five reviewers ON PURPOSE and are still correct, so they
  were left alone (R14d is R6's counterpart for `skills/`, not a widening of it). No
  replacement total is quoted here — it would rot the same way. **What it still does not
  buy, unchanged:** the script is blind on a machine with no gstack checkout, which is
  the machine the port exists to serve, and Phases 0/1/12/13/14 are not hash-pinned at
  all (below). Original entry follows. (0.19.0,
  2026-08-26) The loop is `for f in "$agents_dir"/*-reviewer.md`. `skills/audit/SKILL.md`
  carries the same provenance block shape — `source-path`, `source-commit`, `source-sha256`
  against `cso/sections/audit-phases.md` — and nothing compares it to the live gstack file,
  so gstack can rewrite the audit phases and this repo is told nothing. A31 asserts the
  block is *well-formed*; it says nothing about whether the hash still matches anything.
  **The fix is one glob and its positive control**: extend the loop to `skills/*/SKILL.md`
  and add an R14 built the way R13 builds one — a synthetic gstack root plus a fixture skill
  whose recorded hash is deliberately wrong, so the assertion fails against the pre-fix
  script. It did not ride along with the port because the positive control's fixture is the
  file the port creates, so the two cannot land in one PR without the test asserting against
  a file that does not exist on its own base. **Twelve sites describe the current scope and
  every one of them is part of the change** — a glob that lands while the prose still says
  `agents/*-reviewer.md` is the doc-lag failure `CLAUDE.md` records under *a doc that
  describes gate behaviour is part of the gate's surface*. By symbol, not by line:
  `scripts/forgeward-rubric-drift.sh` in three places (its header comment, the `for f in
  "$agents_dir"/*-reviewer.md` loop, and the comment below the loop reasoning from
  "committed, reviewed files"); `README.md` twice (the provenance paragraph and the
  no-gstack paragraph); `skills/gate/SKILL.md` twice (the fork paragraph and the 0.19.0
  drift paragraph); `DECISIONS.md`, `THIRD-PARTY-LICENSES.md` and `skills/audit/SKILL.md`
  once each; and `test/gate-test.sh` twice (the `agents/*-reviewer.md` provenance loop and
  the comment stating the script's scope). **This list is a snapshot and nothing keeps it
  current** — re-run `grep -rn '\*-reviewer\.md'` before starting, because a site added
  after 2026-08-26 will not be here — and it under-counted by two for exactly that reason.
  **What it still would not buy:** the script is
  blind on a machine with no gstack checkout, which is the machine the port exists to serve,
  and the audit's Phases 0/1/12/13/14 are not hash-pinned at all (below), so even a green
  extended run covers less than the skill's provenance block appears to promise.
  **Priority:** P2

- **✅ FIXED (0.18.0, 2026-08-26) — `forgeward-detect-gstack-skill.sh`'s plugin-cache glob
  was one directory too shallow, so a plugin-installed gstack had never been detected.**
  The precondition this entry set — *"whether the two-level shape is a real layout
  anywhere"* — was answered by enumeration rather than sample before the fix landed:
  `find ~/.claude/plugins/cache -maxdepth 4 -name skills -type d` returns **14 versioned
  paths across 8 marketplaces and zero two-level ones**. So the shallow depth has no
  positive evidence behind it and is **kept anyway**, on the drift script's defensive
  footing, with D8 rewritten to say so — a passing D8 is not proof that layout exists.
  D8b is the positive control the entry asked for, built the way R13 builds one, and it was
  verified to FAIL against the pre-fix script before being accepted: `git show HEAD:` of the
  old script exits 1 on a versioned fixture where the new one exits 0. D8c pins the
  direction, so a future widening that swallows a fourth level turns red. The drift script's
  "THE SIBLING IS STILL WRONG" paragraph is retired in the same commit, per the rule that a
  doc describing gate behaviour changes with the code.
  *Original text follows, unedited apart from this lead.* It globs
  `"$claude_dir"/plugins/cache/*/*/skills`; measured on the author's machine that matches
  **nothing**, while `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills`
  exists for both installed plugins — the real layout carries a **version** level the glob
  does not account for. Found while giving `forgeward-rubric-drift.sh` a multi-root lookup;
  the drift script searches **both** depths and says in its own comment that it is
  deliberately not copying this one. **Not fixed here on purpose:** this script answers "is
  this gstack skill installed", which drives `supply-chain-reviewer`'s `/cso` deferral and
  the Step 3 `/ship` handoff, so changing it changes what the gate defers and where it hands
  off — a different blast radius from a drift advisory, and the standing rule is that a
  change to executable behaviour gets its own PR. **What to check before fixing:** whether
  the two-level shape is a real layout anywhere (the drift script searches it defensively,
  not from evidence) — and note that E2's positive control passes today because gstack is
  **skills**-installed here, so this arm has no positive control at all and a fix needs one
  built the way R13 builds it. **Priority:** P2

- **✅ DONE (0.17.0) — The gate cannot tell whether the handoff it offered was actually
  taken, so the `quality` disclosure is a statement about what is owed, not what ran.**
  (filed with 0.15.0, 2026-08-19; closed 2026-08-26)
  **Closed by removing the question, not by answering it.** The five quality reviewers are
  ported into `agents/` and fire from the Step 1 table, so the axis is reviewed inside the
  gate on every machine and there is no longer a deferral whose payment needs observing.
  The `review-ran` check specced below is dead along with it — see that entry. What the
  original filing got right is preserved in `DECISIONS.md` at 0.17.0: the configuration it
  named (handoff offered, never taken) is forgeward's own default workflow, which is why
  "owed but never paid" was the common case rather than an edge one.
  *Original text follows, with the match key annotated inline where later measurement
  falsified it — the annotation is marked by an em-dash aside, everything else is verbatim.*
  Step 3 invokes `/ship` via the Skill tool and reports
  `Handing off to /ship`; nothing afterwards observes whether Step 9 reached the review
  army, whether the user interrupted, or whether they took the far more common route of
  gate → push-and-PR by hand (which forgeward itself does, because `/ship` re-bumps the
  version). So on the `gstack_ship: present` branch the axis is reported as deferred and
  may simply never run. **The tractable check is the one `docs/axis-proposals.md`
  already specced and shelved** — though not in the shape it was specced in: the three
  corrections at the end of this section retire `commit` and specialists-dispatched from
  the match key, and retire `via` as the *rejector* of forgeward's own gate runs. Treating
  a missing `via` as standalone survives untouched — it was never a match-key component in
  the first place, it is gstack's own documented semantics, and
  `docs/axis-proposals.md` §5 says so explicitly. A second mechanism surfaced while measuring it, and it is already
  installed: forgeward's own `hooks/hooks.json` registers a `UserPromptExpansion` hook on
  `^([A-Za-z0-9_]+-)?ship$`, so the same shape keyed on `gate` could say "quality has not
  been reviewed on this branch" as the user types the command, with the gate reading nothing
  at run time. Either way it cannot block on
  a first version, because its input is absent for runs that legitimately happened. Worth
  reviving now that the disclosure is keyed correctly and the gap is the only thing left
  between "owed" and "paid". **Priority:** P3

- **✅ DONE (0.17.0, 2026-08-26) — gstack's `/review` and forgeward defer the quality axis
  to each other, and it runs nowhere.** Struck on the lead to match the two entries beside
  it: 0.17.0 wrote the closure into the body of this entry but left the lead in open form,
  so every count that reads leads — this file's own, and todokeeper's — reported it as
  live. *Original text follows.* On commit `04a04fb` the review log records `maintainability` skipped with
  `reason: "covered-by-forgeward-and-coverage-audit"` and `security` with
  `"covered-by-forgeward"`, while forgeward's README skips code-quality because
  `/review` covers it. Same shape as the `/cso` reversal. Scope: 2 of 22 review entries —
  an existence proof, not a measured rate. (2026-08-05) **Priority:** P3 — downgraded at
  0.12.0 because forgeward's half is closed. Not because the rest is another repo's ticket:
  the correction below shows there is no code on either side to change.

  **Half-narrowed by 0.8.0, and forgeward's half closed at 0.12.0.** Option B made the
  *gstack-absent* half explicit — the gate discloses `quality` as unowned. 0.12.0 closed
  the other side of forgeward's contribution: the README no longer says `/review` covers
  quality, and `skills/gate/SKILL.md` now prints a PRESENT-case clause naming what the
  probe can and cannot see (`quality: owned by gstack /review (installed; forgeward has
  no quality reviewer and does not check that /review ran)`). So a user with both tools
  installed is no longer told the axis is handled.
  **What is left is not fixable from here.** Nothing in forgeward can read `/review`'s
  skip reasons, change them, or detect that a review ran; the entry stays because the
  *measurement* lives here and would otherwise be lost.
  (0.8.0, 2026-08-06; forgeward half closed 0.12.0, 2026-08-16)

  **Correction, 2026-08-26 — there is no other-repo fix, because there is no other-repo
  code.** This entry was filed as gstack's ticket, on the assumption that gstack's skill
  *contains* the deferral and the remedy is gstack dropping it. It does not: `grep -rn 'covered-by-forgeward'` over
  `~/.claude/skills/` returns **0**, and **0** files anywhere under
  `~/.claude/skills/gstack/` mention forgeward at all. `review/SKILL.md`'s own documented
  skip reasons are `"scope"`, `"gated"`, the under-50-line bail and `[GATE_CANDIDATE]`.
  The strings this entry quotes were **improvised by the model at run time** and written
  into the log — twice, in
  `~/.gstack/projects/thimisou/fixtimed-events-followups-reviews.jsonl` (2026-07-29) and
  again on 2026-08-26 in `androsland-claude-video`, the second phrased freehand as
  "forgeward security-reviewer PASSed this exact range". So the loop is a *runtime*
  behaviour with no code on either side to change, which makes it strictly harder to fix
  than filed and not, as recorded, someone else's ticket.

  **✅ DONE (0.17.0, 2026-08-26) — the loop is broken from this side, and gstack's half
  stopped being wrong without gstack changing anything.** `/review` skipping
  `maintainability` as `covered-by-forgeward-and-coverage-audit` was a false claim when it
  was logged and is now simply **true**: forgeward has a maintainability reviewer, and it
  fires. The entry closes because the defect was "the axis runs nowhere", and it now runs
  here. Two things this does not mean: gstack's skip reason is still model-improvised prose
  with no code behind it on either side, so it can say anything on any run; and `security`
  skipped as `covered-by-forgeward` was always true and is untouched by this.

- **❌ DROPPED (0.17.0, 2026-08-26) — The review-ran check — warn-only, never blocking on
  a first version.** Superseded rather than shipped: it exists to check up on a delegated
  quality pass, and there is no longer a delegation. Dropping it also retires the two
  cross-repo dependencies it carried (gstack's two `gstack-review-log` call sites and the
  `via`-key shape), plus the `"via":"standalone"` change it wanted filed against gstack.
  That last one was measured before it was dropped, and the number is the reason it was
  never worth much: across 85 `*-reviews.jsonl` files under `~/.gstack/projects/`, exactly
  **one** of 122 lines carries no `via`, and it is a genuine standalone run. So the field's
  absence was the only available signal, one sample wide, and indistinguishable from a
  truncated write or an older template — the change would have shrunk the `unknown` bucket
  without ever making it empty, and would have done nothing for lines already written.
  **Kept rather than deleted** because its analysis is the strongest single argument for
  the port: a check that must treat a missing field as "probably ran" and can never block,
  because a real review can leave no trace, is a check whose input the gate does not
  control. That is the property that made owning the axis the cheaper option.
  *Original text follows.* Gate on
  whether a quality pass ran rather than reimplementing quality. Match `skill:"review"` +
  `commit` + specialists dispatched, and **treat a missing `via` as standalone** — a
  standalone `/review` reaches the `gstack-review-log` call in `review/SKILL.md` with no
  `via` key, while `/ship` reaches the one in `ship/sections/review-army.md` with
  `"via":"ship"`. Both re-verified 2026-08-16. These are **cross-repo** references into
  gstack, which this repo neither controls nor can keep current, so grep for the
  `gstack-review-log` invocation before acting on either. Keying on
  `via:"ship"` would fail exactly the people who ran `/review` correctly. Cannot block,
  because both call sites are model-executed prompt steps: a review that happened can
  leave no entry, which under-counts a measurement but manufactures false FAILs in an
  enforcement. **Priority:** P3

  **Three corrections to this design, measured 2026-08-26 before building it.** Census:
  85 `*-reviews.jsonl` files under `~/.gstack/projects/`, 122 unique lines, 23 carrying
  `skill:"review"` across **6 distinct key-shapes**.

  (1) **It must reject forgeward's own gate runs — and `via` cannot be what rejects them.**
  Two live log lines record forgeward's reviewers under `skill:"review"`:
  `finrecruits/featcandidate-job-alerts-reviews.jsonl`, with `"note":"4 axes
  (privacy/a11y/security/seo) x 3 rounds"` and `via:"forgeward-gate"`, and the 2026-08-26
  `androsland-claude-video` line, whose `passes.skipped.security` reads "forgeward
  security-reviewer PASSed this exact range" and which carries no `via` at all. So a check
  keyed on `skill:"review"` alone reads forgeward's gate as the quality pass it exists to
  disclose the absence of — and the obvious guard, rejecting `via:"forgeward-gate"`, catches
  only the first: that record is the **oldest** of the six shapes, and the newest shape has
  no `via` to reject. Key the rejection on a field the current shape carries
  (`read_only:true`, or a `passes.skipped.*` reason naming forgeward), and test it against a
  gate record in the *new* shape, not only the 2026-07 one.

  **That key was proposed with no negative control, and re-measuring on 2026-08-26 shows
  why that matters.** The `androsland-claude-video` / `fix/gate-findings` record — the one
  correction (2) below calls "still a real `/review` run", and the only standalone run in
  the census at the time — carries `read_only: true` *and* a
  `passes.skipped.security` reading "forgeward security-reviewer PASSed this exact range".
  Both proposed keys match it, so the check would have printed the false accusation
  correction (3) forbids, against its own sole positive example. It is not
  zero-separating-power: a second standalone row logged since (this branch's own review,
  under `androsland-forgeward-gate`) carries neither key and would pass. The defect is that
  the discriminator was written from a population with exactly one positive and no negative,
  which is the same one-sample error corrections (1)–(3) are each about. It strengthens the
  DEAD verdict rather than weakening it, and is recorded here for that reason.

  (2) **`commit` cannot be in the match key, and neither can the rest of the template.**
  `commit`, `specialists`, `quality_score` and per-finding `fingerprint`/`severity`/`action`
  all come from `/review`'s Step 5.8 template, and the newest record on this machine carries
  **none of them** — it carries `passes`/`counts`/`headline`/`workspace_guard`/`read_only`
  instead. The shape this design was written against is the oldest of the six. Note what
  this does *not* license: that record is still a real `/review` run (see the measurement
  entry above), so a check keyed on the template's fields would have called a genuine
  standalone pass unreviewed.

  (3) **`unknown` must cover lookup failure, not only parse failure.** With `commit` gone,
  the branch-derived filename is the only key left — and it drifts: **17 branch names on
  this machine resolve to two different files** (`feat-dashboard-i18n-reviews.jsonl` and
  `featdashboard-i18n-reviews.jsonl` are one branch), 4 logs sit under the literal branch
  name `unknown`, and 3 sit one directory deeper because the branch name contains a slash.
  Zero candidate files, more than one, or a record whose provenance is not readable is
  `unknown`. The check must **never** degrade to `not reviewed` — that turns gstack's schema
  churn into forgeward printing a false accusation.

- **`forgeward-transcript-audit.sh`: the P2 filed with the gitleaks fix is now shipped, and
  its first real run corrected the README that specified it.** Shipped 2026-08-19 as
  **0.16.0** — `scripts/forgeward-transcript-audit.sh` (755) plus
  `test/transcript-audit-test.sh` (37 assertions), registered in `package.json`'s roster,
  which is the single source of truth for the suite list.

  **THE FINDING THAT CHANGED THE DESIGN.** README 0.10.1 settled that the audit surface is
  "**two** channels" — `subagents/*.jsonl` and `tool-results/*.txt` — and the filed entry
  said a script would inherit that. The script's first run over the real
  `~/.claude/projects/` tree (3536 files, 194 session directories, 19.7s) returned **20
  prefixed hits: 14 under `subagents/`, 1 under `tool-results/`, and 5 at the top level**,
  `<project-slug>/<session-uuid>.jsonl` — a quarter of the hits outside both documented
  channels. A `memory/` directory sits beside them too. Three is now written as a **floor**,
  not a total. The rule extracted to CLAUDE.md is that a channel list is an `--include`
  filter in different clothes; `grep -r` from `projects/` found all three because it was
  told about none of them.

  **SCOPE, ALSO CORRECTED BY MEASUREMENT.** The entry specified "its own project's
  transcripts". A slug is keyed to the session's LAUNCH directory, and **0 of 26** slugs on
  this machine contain `forgeward` — so the specified design would have reported the repo
  shipping the script clean, while being the one repo certain to have been discussed.
  Default scope is every project; `--project SLUG` narrows; nothing derives a slug from a
  repo path.

  **WHAT IT REPORTS.** Filenames and counts, never a value — the run above deliberately
  opened none of the 20 matching files, since reading one pulls a live credential into a
  fresh transcript and re-commits the exposure the audit is about. It prints
  `files N across M session directories` so a clean result has a denominator, a per-shape
  breakdown, a count of group/other-readable `tool-results` files (267 here), and a
  mandatory "WHAT THIS RUN DID NOT ESTABLISH" block carrying UNVERIFIABLE and
  rotate-regardless. Exit `1` prefixed match, `0` none, `2` nothing to search, `64` usage.
  The URL pattern stays advisory and never sets `1` — 195 hits against 20, the same
  signal-to-noise split the README already measured at 201-vs-15.

  **TWO HARNESS TRAPS, BOTH WRITTEN INTO THE SUITE'S HEADER.** (1) `set -o pipefail` plus
  `CMD | grep -q` is a false-negative generator: `grep -q` exits on first match, `CMD` takes
  SIGPIPE and dies 141, and pipefail hands the pipeline that 141 — so a *successful* match
  reads as a failed test. Five assertions failed that way before the cause was found. (2) A
  bare `grep -qF "$PEM_NEEDLE"` errors "unrecognized option" because the needle starts with
  `-`, exiting 2 — which is non-zero, so a *silence* assertion passes without ever reading
  the output. Found while writing the suite; `-e` is load-bearing in the test for exactly
  the reason the README already gives for the search. The suite's first assertion is a trust
  check that proves the leak assertion can fail.

  **THE GATE FOUND THREE THINGS ACROSS TWO ROUNDS AND ALL THREE ARE FIXED IN THE SAME
  PR**, which is the shape a read-only gate is for — and the third is the interesting one,
  because it was a gap in the fix for the first. Privacy (Medium): the printed filename list is itself identifying —
  a slug is a flattened directory path, so it carries a home-directory name and repo/client
  names, and the natural next move after a hit is pasting it into an issue. The script now
  says REDACT BEFORE PASTING beside the list, and two assertions pin that it fires on a run
  with hits and stays quiet on one without. Security (Low): `stat -c` is GNU-only, so on BSD
  and macOS every call fails and the loop would have printed a confident `0` world-readable
  files — a false clean produced by the very script that argues against false cleans. It now
  probes once and prints `UNAVAILABLE`, tested with a deliberately broken `stat` on `PATH`.
  Supply-chain self-skipped: no dependency moved.

  Round two, privacy (Medium): the warning had been added under the prefixed-shape list
  only, while `--urls` printed a **second** list of the same slug-bearing paths with no
  warning at all. One list warned and one not is worse than neither, because it reads as a
  considered distinction. The note is now a function called after every filename list, and
  two more assertions pin it on the `--urls` path in both directions. This is the
  own-fix-undershoots-own-evidence shape from CLAUDE.md, caught by a reviewer rather than by
  me: the evidence was "printed paths are identifying" and the remedy covered one of the two
  places paths are printed.

  Round three, privacy (Low): the same reasoning applied to the README. The redaction note
  was written next to the *script's* paragraph, while the four hand-run `grep` blocks below
  it print the identical slug-bearing lists and the README explicitly anticipates people
  jumping straight to a command block. Moved so it sits between the shared explanation and
  the first command, reworded to cover both routes, with a pointer after the first block.
  Three rounds, and each round's finding was that the previous round's remedy stopped one
  printer short of its own evidence.

  Deferred, both filed above: `test/` is still outside CI's shellcheck, and the pattern list
  is duplicated between script and README with nothing checking they agree.

- **Archive pass 5: the currency check caught the section stale by two again, and a tool
  did the measuring for the first time.** Shipped 2026-08-19, docs only — no code, no
  version bump (0.15.0 unchanged).

  **CURRENCY — stale by two, and the check has now caught staleness in three of the four
  passes known to have run it** (2, 3 and 5; pass 4 came back clean). `## Completed`
  stopped at #38. **#39** (`032e8df`, 0.14.0) and **#41** (`4c7207b`, 0.15.0) merged under
  three minutes apart on 2026-08-19 and neither carried an entry; both are written up from
  their commit bodies, before anything was moved. Pass 4's clean result reads differently
  in that light — one clean run in four, not a change of regime — and the mechanism pass 3
  named is unchanged: the entry describing a PR can only be written once that PR merges, by
  which time the branch that would have carried it is gone.

  **#40 is not a hole in the numbering, and that was checked rather than assumed.** It was
  the same change as #41, opened against `fix/a11y-severity-wrong-name-and-contrast`
  because 0.15.0 was stacked on 0.14.0 and the monotonic rule forbids merging them in the
  other order. Squash-merging #39 rewrote that base out of existence, so #40 was closed and
  the work re-opened against `master` as #41. Nothing merged as #40 and nothing is owed an
  entry for it. **A gap in the PR numbers is evidence of nothing until you look** — the
  currency check enumerates merged PRs, and a closed one has to be read to be dismissed.

  **MEASURED BY A TOOL for the first time, and it changed no decision here.** `todokeeper`'s
  `measure.mjs` read `TODOS.md` at **112,018 B, completed mass 33,302 B = 29.7% of the file
  across 6 entries, 61 live entries, over the 50,000 B threshold**. That is the first pass
  where the numbers came from a command rather than from a reading. The file was obviously
  over the threshold and the cut size is arithmetic — nine entries back to five — so the
  tool confirmed rather than decided. The reason to run it anyway is the one its own docs
  give: a maintainer eyeballed another repo's completed mass at 1.6% when it was 12.4%, and
  that estimate was the argument for leaving the file alone.

  **MERGE ORDER — checked, and the one inversion in range does not touch the cut.**
  `git log --first-parent` puts #33 < #32 < #34 < #35 < #36 < #37 < #38 < #39 < #41. The
  inversion is #32 merging 19 seconds *behind* #33 despite the higher number, and it is
  inert here because #32 never had an entry of its own — it is folded into #33's. Among the
  four entries being cut, number order and merge order agree.

  **CUT — four entries, `24,149` bytes, to `TODOS-DONE.md` newest-first at the top, in the
  same commit that removed them:** #36 (`e250ec8`, 0.13.0), #35 (`840d936`, 0.12.1), #34
  (`f0ac18e`, archive pass 3) and #33 (`8baee22`). Nine entries back to five — six standing,
  three written by this pass, four out.

  **EXTRACTION — five rules lifted, against pass 4's three.** Most of what these four
  entries produced was already in `CLAUDE.md` — the whole substitution-swallowed-`exit`
  property, its five mechanisms and its non-goals shipped with `0.12.1` itself. What was
  not yet written down, and is now:

  - **Prefer deleting a weightless detail to correcting it** — from `0.12.1`, where each
    amend's prose about the last correction became the next round's failure surface.
  - **A number in a doc is re-derived from what merged, against a FIXED range** — from
    `0.12.1`'s branch-diff hash and pass 3's headline count, two shapes of the same defect.
  - **A tool whose absence turns a suite green is still a dependency** — from #33's
    `semgrep`/`1..0 # SKIP` finding.
  - **An automation nobody has watched run is a claim, not a control** — from #33's
    Dependabot close.
  - **A count the gate prints must not fire on a configuration the docs endorse** — from
    0.13.0's `seo.routes` non-fire, carried with its `0`-is-not-a-clean-bill exception.

  **MEASURED, because pass 3's entry says to.** `TODOS.md` went **112,018 → 99,410
  bytes**, a net **−12,608** after writing three entries back — against pass 4's −15,032 on
  117,273 and pass 3's −1,392 on 85,990. Still **just under 2×** the ~50KB threshold, and
  the reason is the one every pass has recorded: the open half is **79,316 bytes, 80% of
  the file** (`awk '/^## Gate — publish matcher/{f=1} /^## Completed/{exit} f' TODOS.md |
  wc -c`), up from 72% at pass 4 — it rises as a share every time only the completed half
  is cut, and this pass does not touch it.

  **What this pass did NOT do, and the difference from pass 4 is that it is now due.** It
  expired nothing in the open half. Pass 4 recorded that triage as a different job with a
  different risk; its own entry sets the trigger as a batch of merged work large enough that
  several entries are plausibly stale, and that trigger was **checked and not met on
  2026-08-17**. Seven PRs and five releases later it **is** met, `stale.mjs` puts **24 of 61
  entries in SUSPECT** against **5 cold**, and the entry now says so with the full
  distribution and what each bucket is not. The triage itself is the next unit of work,
  not this one — a title needing an "and" is two PRs.

- **The `quality` axis was disclosed as owned by reading whether `/review` is INSTALLED,
  which is not what runs it.** Shipped on `feat/gate-quality-axis-keys-on-handoff` as
  **PR #41, merged `4c7207b`, 2026-08-19** (0.15.0), +75/−13 across 6 files. Written up by
  archive pass 5 from the commit body, because the entry did not ship with the work.

  **The failing configuration is `/review` present, `/ship` absent.** The gate never invokes
  `/review`; the axis is run only by the Step 3 handoff, through `/ship` Step 9. So a
  `gstack_review`-keyed table reported the axis as covered in the exact configuration where
  nothing will ever run it, and said nothing at all, because the variable it read was
  satisfied. `docs/axis-proposals.md` had recorded, under the quality-axis question and
  since before the table said otherwise, that the handoff to `/ship` is the only thing that
  runs quality — **the repo contradicted its own doc, and the doc was right.**

  **Four cases, including the one that cannot be detected.** `/ship` present → the axis is
  deferred to Step 9, said plainly so nobody runs `/review` a second time by hand. `/ship`
  absent, `/review` present → NOT COVERED this pass, naming the command. `/ship` present but
  the handoff not taken → undetectable, and stated to be — **it is the common path, not an
  edge**, since forgeward's own workflow is gate → push-and-PR by hand precisely because
  `/ship` would re-bump the version. Both absent → unchanged. The first bullet is therefore
  worded as where the axis is *owed*, never as a claim it was paid.

  **Why the gate must not simply invoke `/review`, pinned so it does not read as a gap
  waiting to be filled.** `/review`'s `allowed-tools` include `Edit` and `Write`, and Step 2
  snapshots the tree and diffs it afterwards to prove the gate is read-only — a reviewer that
  may legitimately edit code cannot run inside that envelope without either firing the
  workspace guard on correct behaviour or gutting the guarantee. The scopes differ too:
  `/review` resolves its own base branch, Step 0 resolves the publish boundary.

  **Residue filed, not waved off:** nothing observes whether the offered handoff was taken.
  `axis-proposals` already specced that check — match a dashboard entry on `skill:"review"` +
  `commit` + specialists-dispatched, a missing `via` meaning standalone — and shelved it. It
  is now the only thing standing between "owed" and "paid".

- **A11y read a WRONG accessible name, and text below AA, as polish.** Shipped on
  `fix/a11y-severity-wrong-name-and-contrast` as **PR #39, merged `032e8df`, 2026-08-19**
  (0.14.0), +79/−4 across 6 files. Written up by archive pass 5 from the commit body.

  **A wrong name blocks nobody, which is exactly why the old rubric got it wrong.** The bar
  was "a real barrier that blocks a user from completing a task… polish is Low". A
  screen-reader user given a wrong name completes the task and is told something untrue on
  the way, so it landed at Low and the gate passed — backwards from the missing-name case
  sitting beside it. A missing name is discoverable: the reader announces "button" and the
  user knows something is absent. A wrong one announces something plausible and gives no
  signal to doubt it. `aria-label` REPLACES the element's contents in the buffer, so a
  hand-written one silently deletes every field it omits and goes stale the next time one is
  added.

  **"Failing contrast on key text" had the same shape.** "Key" has no definition, so it
  resolves to whatever the reviewer already believes is important, and a whole family of
  secondary labels sits under the floor for months while each one individually reads as
  unimportant. Any text below 4.5:1 normal / 3:1 large is now High, unqualified.

  **This widens what the gate BLOCKS, not what it prints, and it is the one place this repo
  has done that deliberately** — recorded as an exception in `CLAUDE.md` beside the rule it
  is an exception to. Both non-goals are written into the reviewer prompt rather than left
  implied: a terse-but-accurate name is a pass (`aria-label="Κλείσιμο"` on an `×` is correct,
  because the test is whether the name is TRUE, never whether it is long, and `alt=""` is the
  correct marking for decoration), and runtime-composed contrast — a theme token, an
  `opacity-*` utility over an unknown backdrop, a UA stylesheet — is not computable from a
  diff and must be reported as "unmeasured, needs a rendered check". **A vendor's documented
  value is not evidence there:** one shipped UA rule for disabled input text predicts ~2.0:1
  where the engine paints 7.57:1.

  **Two gaps filed rather than closed.** No test reads `agents/*.md` at all, so every
  reviewer's blocking surface is prose no CI job checks — 299 assertions stay green through
  any rubric edit. And an "unmeasured" report still returns PASS, so a known-unknown is
  indistinguishable from a clean run in the marker.

- **A security assertion was pinned by a hand-copied literal, and forgetting to update it
  was the one failure in this repo with no red anywhere.** Shipped on
  `fix/e17-derive-payload` as **PR #38, merged `678a4fc`, 2026-08-19** (0.13.1). Written in
  the same commit as the work, so the PR was current the moment it opened and the number was
  not knowable then; stamped by archive pass 5, as the placeholder that stood here asked for.

  **The defect is the absence of a signal, not a wrong answer.** E17 asserts that
  `_env_ok` is anchored at *both* ends by handing `forgeward-write-marker.sh` the probe's
  genuine output with a forgery appended. For that to test the trailing anchor, the opening
  bytes must be a shape `_env_ok` accepts — and they were typed by hand, with nothing
  comparing them to the probe. Add a field to the probe, leave the copy alone, and the
  payload is refused on its **prefix** instead: `notforged` still returns true, E17 still
  prints `ok`, and dropping the trailing `$` — the exact one-character regression E17 exists
  to catch — reddens nothing at all.

  **It read as handled precisely because it had always been handled.** The copy moved twice
  and both times correctly (`seo_posture` 0.9.0, `config_warnings` 0.13.0). The obligation
  was written in three places and honoured on both occasions. What kept E17 honest was a
  person remembering; the failure mode of forgetting was silent, while the other two legs of
  the same obligation are loud (a stale `_env_ok` reddens E10 and degrades every marker to
  `{"probe":"unavailable"}`).

  **The fix deletes the copy rather than warning about it harder.** E17 derives its prefix
  from `$E1J` — the live probe captured at E1 with all three roots neutralised — so a new
  field is in the payload the moment the probe emits it. `grep` confirms no literal copy of
  the probe's output line remains anywhere in the suite. A probe field is a **two**-file
  edit again, stated at the `printf` itself.

  **Non-goals, in the test and in `DECISIONS.md` rather than left implied.** It cannot see
  `_env_ok` falling behind the probe — that direction refuses the derived prefix, degrades
  the marker, and greens E17 for the wrong reason; **E10 reddens there**, and neither
  assertion is sufficient alone. It does not decouple the probe from the marker writer; that
  coupling is a separate open P2 whose price this dropped from three files to two. The
  emptiness floor checks that `$E1J` *looks like* a probe line, not that it is correct — E1,
  E2 and E9 own that.

  **The P2's revisit trigger was re-evaluated, not actioned.** The probe is past "a handful
  of fields", so the trigger is met — but the remedy the entry named ("take the parser
  dependency") is refused by `CLAUDE.md`'s one-reader-per-shape rule and by
  `forgeward-write-marker.sh` sitting on the **push-authorizing** path, where an interpreter
  present on the author's box and absent on an installer's decides whether a marker is
  written. Recorded in the entry so the trigger is not re-derived every pass; the entry
  stays open.

  **MUTATION — both directions, and the decisive leg is the last pair.**
  Every mutated leg printed a verification line confirming its mutation was actually present
  before the suite ran — a green from a mutation that silently failed to apply proves nothing.

  | mutation | gate suite | E17 |
  |---|---|---|
  | base (unmutated) | 194/0 | `ok` |
  | drop the `$` from `_env_ok`, nothing else | 193/1 | **RED, and only E17** |
  | 8th probe field + `_env_ok` updated (the correct two-file edit) | 194/0 | `ok` — no test edit needed |
  | …that field addition **plus** the dropped `$`, with this commit's E17 | 193/1 | **RED** |
  | …the same, with **master's** E17 | 194/0 | **GREEN** |

  The last two legs are byte-identical apart from which `test/gate-test.sh` runs. Master's
  leg prints *"a valid-prefix-plus-appendix splice is rejected (the shape match is anchored
  at BOTH ends)"* — its own unchanged wording — while the anchor it names is gone.

  Isolated outside the harness, same scripts, anchor dropped: the derived payload writes a
  marker carrying `diff_hash=TAILFORGE` — the forgery lands, `notforged` fails, E17 reddens.
  Master's stale 7-field payload writes a marker carrying the **real** diff hash: refused on
  its prefix, `notforged` returns true, E17 greens.

- **Archive pass 4: the currency check came back CLEAN for the first time, and the cut
  arithmetic was wrong until it was written down.** Shipped 2026-08-18, docs only — no code,
  no version bump. Clears the deferral the 0.13.0 entry recorded, which held this split back
  on purpose so a four-figure prose diff would not bury a script change.

  **CURRENCY — clean, and that is news.** Passes 2 and 3 both caught `## Completed` stale,
  and pass 3's entry called two-of-two "a pattern, not an accident". This pass enumerated
  every merged PR with `gh pr list` and mapped it against the section rather than eyeballing
  the newest date: 8 entries covering **#28–#36**, with **#32** (the `actions/checkout`
  bump) folded into #33's entry rather than carrying one of its own, and nothing merged
  after #36. No gap. The check still had to run to establish that — a clean result and an
  unrun check are indistinguishable from the page.

  **MERGE ORDER — the trap did not fire this time, and the check still ran.** `git log` on
  all eight merge commits put #28 < #29 < #30 < #31 < #33 < #34 < #35 < #36, so PR-number
  order and merge order agreed and any sort would have produced the same cut. Pass 3 hit the
  inversion (#26 merged 39 minutes *after* #27) and `CLAUDE.md` now carries the rule; this is
  what it looks like when a rule costs one command and buys nothing on a given day.

  **CUT — four entries, not three, and the first plan said three.** Landing at "the 5 most
  recent" means cutting **four** when the pass writes its own entry back, and the first
  boundary drawn here was three, which would have left six. Caught by re-deriving the
  arithmetic before the cut rather than after. Archived #31 (`9cddc11`, 0.12.0), #30
  (`5144a37`, 0.11.0), #29 (`2844886`, 0.10.1) and #28 (`ce69eb5`) to `TODOS-DONE.md`,
  newest-first at the top: **18,863 bytes**, in the same commit that removed them.

  **EXTRACTION — three rules lifted, and the thinness is the evidence the ratchet works.**
  Most of what these four entries produced was already in `CLAUDE.md`: the `python3 -I` rule
  with its no-jq scope limit, the `export LC_ALL=C` pin with its deliberate `test/`
  exception, "pin the VIOLATING form and guard the enumeration against emptiness", the
  merge-order cut rule, and "a filing-only PR still gets a `## Completed` entry" all landed
  in pass 3. What was *not* yet written down, and is now:

  - **Rewriting a tracked script in place must preserve its mode.** `awk … > tmp && mv`
    recreates at the umask default and silently de-executed eleven scripts when the
    `LC_ALL` pin landed. A29 pins it; the rule was only ever in the archived entry.
  - **When a filter caused the miss, delete the filter — do not extend it.** From the
    rotation notice's `--include='*.jsonl'`, which could not see `tool-results/*.txt`.
  - **A search over evidence that expires must report an empty result as UNVERIFIABLE.**
    From the `cleanupPeriodDays` measurement, and it binds the filed
    `forgeward-transcript-audit.sh` before that script exists.

  **MEASURED, because pass 3's entry says to.** `TODOS.md` went **117,273 → 102,241
  bytes**, a net **−15,032** after writing this entry back — against pass 3's net
  −1,392 on 85,990. Four entries out instead of one is the whole difference; the convention
  bounds the entry COUNT, and the byte count follows only from how many you cut. It is still
  roughly **2× the ~50KB threshold**, and the reason is unchanged and structural: the open
  half is **73,484 bytes across 10 topic sections, 72% of the file**, and nothing in this
  pass touches it.

  **What this pass did NOT do, stated so the numbers are not read as health:** it expired
  nothing. A stale-but-open entry and a live one are indistinguishable to an archive pass,
  and the open half grew as a share of the file (63% → 72%) precisely because only the
  completed half was cut. Triaging the open half is a different job with a different risk —
  archiving is reversible and pruning is not — and it remains undone.

- **P2: `.forgeward/config.yml` said nothing when it was read and discarded.** Shipped on
  `feat/config-warnings` as **PR #36, merged `e250ec8`, 2026-08-18** (0.13.0). Stamped by
  this sweep; the entry was written in the same commit as the work, so the PR was current
  the moment it opened and the number was not knowable then.

  The probe gained `config_warnings`, an integer count of settings it was addressed by and
  could not use, and the gate renders one line when it is non-zero. **Visibility only — every
  rule in the reader accepts and rejects exactly what it did before**, verified by the whole
  pre-existing E1–E27 block staying green unchanged. The counters are appended after every
  existing rule precisely so they cannot shadow one.

  **Two deliberate non-fires, and the second is the load-bearing one.** An empty item
  (`substitutes: []`, a trailing comma) names nothing, so nothing was discarded. And
  `seo.routes` plus its whole subtree is skipped by indent, because it is documented as
  unhonoured in README, `skills/gate/SKILL.md` and `agents/seo-reviewer.md` — a count that
  fires on a configuration that followed the docs trains the reader to ignore the count.
  That is the one place this reader treats indentation as structure.

  **`0` is not a clean bill, and this is now written in three shipped files** because it is
  the trap the field creates: a config the probe could not open at all also reports `0`, and
  only the separate `config` field distinguishes them. The live-test's symlink step is
  written as exactly that trap.

  **The vacuity direction here is the reverse of E1/E2's.** Nine of the ten new assertions
  want a non-zero count, so a counter stuck on `1` would green all nine while being useless;
  E28 (a fully-honoured config) and E34 (`seo.routes` plus subtree) are the only two
  asserting `0` and exist as that control. Confirmed by mutation: `warn()` as a no-op reddens
  exactly E29–E33 and E35–E37, flooring the count at `1` reddens exactly E28 and E34, and
  neither touches anything outside the block.

  **The three-file obligation was exercised for the second time and both failure modes
  re-measured rather than quoted** — see the entry under `## Standalone posture`. Suites at
  HEAD: gate 194/0, pre-push 15/0, rules 39/0, version-check 51/0.

- **P3: the two-arm unknown-mode divergence closed, and the fix's own guard turned out not
  to halt.** Shipped on `fix/normalize-manifest-mode-divergence` as **PR #35, merged
  `840d936`, 2026-08-18** — stamped by this sweep, as the placeholder that stood here asked
  for.

  **The fix is structural, not behavioural, and that was the choice.** The entry named
  aligning the two arms as the remedy; aligning them leaves two implementations that can
  drift again, which is precisely how this bug was born from the `top`/`plugins` alignment
  that preceded it. Instead the unknown-mode question is now asked **once, above the
  interpreter split**, and the `jq` arm's `*) cat ;;` — the arm that used to answer it —
  was deleted rather than mirrored. A second answer sitting beside the first is what
  invites someone to "fix" one branch to match the other. Raw passthrough is the answer
  because it matches the no-tool `else` arm: an unhandled manifest is hashed whole, so a
  version bump re-gates.

  **`exit 1` inside `$( )` kills the subshell, not the script — and this was found by
  running the fix, not by reading it.** `snapshot_manifest` gained a mode guard ending in
  `exit 1`; every call site is a command substitution, so the first version printed the
  guard's message to stderr, assigned an empty part, and emitted **a perfectly ordinary
  hash with status 0** — a louder version of the silence the guard was added to break.
  Fixed with `|| exit 1` on all three calls. `set -uo pipefail` does not catch it — there
  is no `-e`.

  **`-e` is not the reason, and three separate drafts of that claim were wrong — the
  errors are the part worth keeping.** Draft one asserted, without measuring, that `-e`
  "does not, reliably, across shells" catch an assignment from a substitution; measured,
  it **does** halt this exact shape on bash 5.1.16 and bash 5.3.15, and the `&&`-guarded
  appends survive it because a failing left operand is exempt. Draft two added dash to
  that list on the strength of a non-zero exit; that exit was `rc=2` from `Illegal option
  -o pipefail` at the `set` line, so the script never ran — **a non-zero exit is not
  evidence of the mechanism you are testing for.** Draft three, written *inside* the
  correction to draft one, said `-e` "changes the error semantics of every other command
  in the file"; enumerated, the only statement that changes is the unguarded
  `diff_part="$(git diff …)"` assignment. The real argument for `|| exit 1` is scope and
  locality over **one** line, not correctness over a file. That last claim is a universal
  in a bullet already wrong three times, so it is measured twice: `grep` finds exactly one
  unguarded assignment-from-substitution in the file, and an eight-case failure battery
  (bad base, bad tip, dash-led base, non-repo cwd, no jq, no python3, empty base,
  baseline) halts at that same statement in every divergent case and is byte-identical in
  the other four.

  **The repo sweep that shipped with this was wrong three times, and the method matters
  more than the list.** It filed `check_root` as exit-bearing — it is not; it returns 0/1
  and the `exit 0` sits at its *call site*. It missed `deny` entirely, because the `sed`
  range used to read function bodies ends at `/^}/` and `deny` emits a JSON heredoc whose
  closing brace is in column 0, so the range stopped short of its `exit`. And it had **no
  transitive tier at all**, so it read as complete while omitting three functions that
  exit by calling one that does — caught in round 3, where the reviewer flagged
  `_gl_target_guard` and re-enumerating turned up `require_blob` as well.

  Corrected and verified both directions: **direct** exits are `die`, `reject`, `deny`,
  `snapshot_manifest`; **transitive** are `out_reject` and `_gl_target_guard` (→ `reject`)
  and `require_blob` (→ `die`); and among the functions invoked inside a command
  substitution, `snapshot_manifest` is the only one that can exit. The rest return — and
  where one sits near an `exit`, that `exit` is at top level, after the body. That is
  precisely the trap `check_root` fell into.

  **Then a fourth draft was wrong too, and that is what settled the shape of the fix.**
  Round 4 caught the replacement asserting "thirteen functions are invoked inside a
  substitution" when a pattern that also matches pipe tails finds fifteen — and fifteen is
  not asserted as final either, it is just what the better method saw. Matching `$(fn`
  catches only a substitution's *first* stage, so `normalize_manifest` and `read_version`,
  both at the tail of a pipe inside `$( )`, were invisible. Four drafts, five distinct
  mechanisms once they were separated properly, one shape:

  | mechanism | effect | victim |
  |---|---|---|
  | `sed` range ends at `/^}/` | truncates at a heredoc's column-0 brace | `deny` |
  | same range vs. a one-liner def | overruns into a genuinely later function | `warn` (span 146) |
  | last def in file — no terminator | body runs to EOF, swallowing the call site | `check_root`, `snap` (×2) |
  | pattern anchored to `$(fn` | misses a pipe's tail stage | `normalize_manifest`, `read_version` |
  | `grep exit` counts comments | false positive | `read_version` |

  All five fail silently. **So the count was removed rather than corrected to fifteen** —
  a closed census that has been wrong every time it was asserted is the wrong shape for a
  shipped doc, and the safety property never depended on it. `CLAUDE.md` now states the
  property and the method, plus explicit non-goals. The property itself survived every one
  of these errors untouched; only the prose around it kept breaking.

  **And then the table above was wrong twice, which is the fifth iteration and the one
  that justifies the whole approach.** Round 5's reviewer caught the first: the one-liner
  row cited `honor_cd`, which is a four-line function at `forgeward-gate-check.sh:186-189`
  and has never been one line. Pushing on its second note — that it could not verify
  `check_root` as the one-liner-overrun victim — found the other, and the reviewer was
  right to doubt it: `check_root` closes at a column-0 `}` at
  `forgeward-detect-gstack-skill.sh:127` like any ordinary block, so that mechanism cannot
  be what misfiled it. The real one is that it is the **last** definition in its file, so
  an attributor with no closing-brace tracking runs its body to EOF and charges it with
  `check_root … && exit 0` at `:146` — its own call site — and `exit 1` at `:149`. Both
  rows are now corrected above. **A table explaining four bad scans was itself a bad scan**;
  prose describing a sweep is a sweep, and nothing re-runs it.

  **And then it was wrong a third time, in the same row, caught by round 7.** The
  one-liner-overrun row also cited `snap` in `forgeward-scan.sh` and
  `forgeward-workspace-guard.sh`. It is not that mechanism either: `snap` is the **last**
  definition in both files (`:321` of 358, `:48` of 71) and neither file has a later
  column-0 `}` at all, so the range runs to true EOF — the same mechanism as `check_root`,
  one row down. Moving it leaves `warn` as the overrun row's only instance in `scripts/`,
  and `warn` genuinely is one: defined at `forgeward-detect-base.sh:97`, next column-0 `}`
  at `:242`, so the range crosses into a later function's body. **Three corrections, two
  of them in the same row, all found by a reviewer rather than by me.** The row that keeps
  breaking is always the one asserting *which function* illustrates a mechanism — never
  the mechanism itself, never the safety property.

  **And the correction to that row introduced the next error, which is what finally
  identified the generator.** The rewritten text listed which `exit`s each `snap` range
  swallows, joining an exhaustive list for one file to an incomplete one for the other
  with "respectively" — so the incomplete half read as complete. It was caught in the very
  next round, in text written by the round before it. The verification pattern I used is
  what produced it: anchored to `exit` at a line start or right after a separator, it
  silently skipped the indented ones. **Each amend adds prose about the last correction,
  and that new prose is the next round's failure surface — so correcting sustains the
  loop rather than ending it.** The move that actually terminates is a **subtractive**
  edit: the itemized list was deleted, not completed, and replaced with the
  non-exhaustive phrasing the row above already used. Which `exit`s get swallowed was
  never load-bearing; the mechanism is that the range reaches EOF at all. **Prefer
  deleting a detail to correcting it, whenever the detail carries no weight** — a
  completed enumeration is still an enumeration, and it can rot the moment either file
  changes.

  **The units were inconsistent too, and that is the smaller finding with the longer
  reach.** "Up to 145 lines" for `warn` counted the span minus the definition line, while
  63/384/179 for the `test/` trio counted the raw span — two conventions in one document,
  presented as directly comparable. Both are now the raw span that
  `sed -n '/^fn()/,/^}/p' FILE | wc -l` returns, and `CLAUDE.md` now quotes that command
  next to the numbers. A figure without the command that produced it is not checkable, and
  an uncheckable figure in a doc about verification is the thing this entry is about.

  **Non-goals, now quantified rather than directional.** The sweep covers **12 of the 21
  tracked shell files**: 11 in `scripts/`, 1 in `ci/`. The 9 in `test/` and `live-test/`
  are excluded on purpose — a substitution-swallowed `exit` in a harness corrupts a test
  result, not a marker, so it cannot produce a false PASS. That is a blast-radius
  judgement, not a claim they are clean, and spot-checking proves the distinction matters:
  **three of the five mechanisms reproduce** in files no sweep has ever read, with one
  example each rather than three of one —

  | mechanism | reproduced in `test/` |
  |---|---|
  | one-liner overrun | `denies`, `gl`, `_hook_path` in `gate-test.sh` — spans 63, 384, 179 |
  | comment/string false positive | `expansion:26`, `det:2169` — both `-> exit code` in the def-line comment; `pre-push-test.sh` past `:144` — one comment, two message strings |
  | last def → body runs to EOF | `rules-test.sh:204` last def, top-level `exit 1` at `:257` |

  The first draft of this paragraph cited only the three one-liners and still said "three
  of the five mechanisms" — a true claim carrying evidence for a third of itself, which is
  the same shape as everything else in this entry. Verified the population is complete
  rather than sampled: no tracked file carries a shell shebang without a `.sh` extension,
  and `hooks/` holds only `hooks.json`.

  **Row 3 lost half its evidence in round 7, and the way it lost it is the entry's thesis
  in miniature.** It originally read `pre-push-test.sh:144`, `rules-test.sh:204`, "each
  with a top-level `exit` after". True of `rules-test.sh`. False of `pre-push-test.sh`:
  `ppjq()` at `:144` is genuinely its last definition, but **no executed `exit` follows it
  at all** — the file terminates on the bare status of `[ "$FAIL" -eq 0 ]`, and the three
  lines after `:144` carrying the word are the comment at `:148` and the `ok`/`nok`
  strings at `:154`/`:155`. So it was never an EOF instance; it is a **fourth instance of
  the comment/string false positive**, and it has been moved to row 2. A citation for the
  comment-false-positive mechanism was itself produced by the comment false positive.

  **Both new assertions were proven red on the old code before being wired in.** V9 (the
  two arms agree on an unrecognised mode) fails on `origin/master` with
  `jq='{"b":2,"a":1,…}'` against `py='{"a":1,"b":2,…}'` — the divergence itself, visible in
  the key order. V10 (a bad mode at a call site halts with no hash) fails on old code with
  `rc=0` and a legitimate-looking hash. A test that has never been observed to fail is a
  claim about the code, not evidence about it. Suites after: gate-test 184/0, pre-push
  15/0, rules 39/0, version-check 51/0.

  **No marker churn, and this was checked rather than assumed.** Running the old and the
  new script over the same input gives identical canonical bytes on both the `jq` path and
  the python3-only path, so no repo takes a re-gate for this. That mattered enough to verify
  because the script header records a prior alignment whose byte change cost a release of
  its own — the one-time cost is paid when the *reachable* modes move, and these did not.

  Quoted against a **fixed** range, `origin/master~1..origin/master`: all four combinations
  — {old script, new script} × {jq, no jq} — give `33751462a160ba83df171dfe`. **The fixed
  range is load-bearing.** This paragraph previously quoted the hash of
  `origin/master...HEAD`, which is a hash of the branch's *own diff* and so changes with
  every amend; it was stale before anyone could read it. A number that the act of committing
  invalidates is worse than no number, because it looks verifiable. It also survived one
  round longer than the same error in the commit message and the PR body, both of which were
  corrected while this file was not — two tracked files disagreeing inside one commit, which
  is a failure this very entry records happening earlier on the same branch.

  The first attempt at the no-jq arm compared two **empty** strings and reported a match:
  the shim `PATH` was hand-listed and missing tools the script needs, so both sides failed
  identically. That is the green-on-an-empty-set failure the `nok` arms added to V9/V10 in
  this same commit exist to prevent, committed while verifying the commit that argues for
  them. Redone by mirroring the whole real `PATH` minus `jq` and asserting non-emptiness
  before comparing.

  **The residue is filed, not waved off:** both guards sit on paths no call site reaches,
  so V9/V10 are the entire detection surface and both are text-coupled to the script. That
  is an open P4 under `## Gate — base detection and freshness`, not a closed question.

- **Archive pass 3: the currency check caught staleness for the second consecutive pass, and
  the PR's own headline count was wrong.** Shipped 2026-08-17 as #34 (`f0ac18e`), docs only —
  `CLAUDE.md`, `TODOS.md`, `TODOS-DONE.md`, +385/−100. No version bump (0.12.0 unchanged).

  **CURRENCY.** `## Completed` was stale by two merged PRs — #33 (`8baee22`) and #32
  (`11af421`), nineteen seconds apart — both written up from their commit bodies before
  anything moved. Pass 2 found it stale by three, pass 3 by two. **Two for two is the
  mechanism, not luck:** the entry describing a PR can only be written after that PR
  merges, and by then the branch that would have carried it is gone. The convention's
  *cut* step is still unverified by anything; only the extraction was ever named.

  **CUT.** One entry archived: #26 (`41324b0`, 0.10.0). Inserted at the TOP of
  `TODOS-DONE.md` rather than below #27, because #26 merged 39 minutes *after* #27 despite
  the lower number — established with `git log --first-parent`, not from the number or the
  date, which is what that file's header tells the next reader to do.

  **EXTRACTION — and the count in the title is wrong.** The squash title says seven rules,
  the commit body says six, and the merged diff adds **eight** bullets to `CLAUDE.md`
  (`git show f0ac18e -- CLAUDE.md | grep -c '^+- \*\*'`), none of them a move: zero bullets
  were removed, and neither `An interpreter dependency's posture…` nor `Pin a blind spot as
  expected-silent…` existed at `f0ac18e^`. The body's six was true when the first commit was
  written; two more landed in later commits on the same branch and neither the body nor the
  title was re-derived. **A count written before the branch finished is a claim about a
  draft, not about what merged** — the only moment it can be true is after the last commit.
  Recorded rather than silently corrected because the drift is the finding: the same PR that
  lifted "state only what you actually checked" into `CLAUDE.md` shipped a headline number
  that had gone stale inside its own branch.

- **P3 ×4 + P4: four entries were closed by going and measuring them, and three of the four
  measurements contradicted the entry.** Shipped 2026-08-17 as #33 (`8baee22`), docs and CI
  config only — no executable code, no version bump (0.12.0 unchanged; the monotonic rule is
  never-backward, not always-bump). `#32` (`11af421`, `actions/checkout` 4.4.0 → 7.0.1)
  merged 19 seconds behind it.

  **Dependabot stopped being an unverified automation.** The entry led with "configured but
  has never been observed to run, and an unverified automation reads as coverage", and that
  closed the same day it was written: #32 opened at 20:14 UTC, ~4 hours after
  `.github/dependabot.yml` merged, and merged 2026-08-17. Service enabled, schedule fires
  with nothing switched on in Settings, `actions` group name resolves. **The prediction the
  entry recorded held exactly** — it said to expect a *major* bump needing reading rather
  than merging on the tick, and a three-major jump arrived. The bounded-not-open claim was
  confirmed from #32's own rollup rather than assumed: `suites`, `shell`, `monotonic` all
  SUCCESS, four `sweep` entries correctly SKIPPED. **The lesson that outlives it: an
  automation nobody has watched run is a claim, not a control**, and the check that settles
  it is one glance at the PR list.

  **The flake sweep ran clean and still does not settle its question.** `workflow_dispatch`
  run `31970233140` on `master`: 25 runs, clean=25, `s7_fail_open=0`, `other_failures=0`,
  `harness_rc=0`, at `FORGEWARD_S7_LOAD=4`. First in-CI measurement of the load-sensitivity
  claim. Zero failures in 25 runs puts the 95% one-sided upper bound on the per-run flake
  rate at **11.3%** — and an 11% flake on a required check is precisely the failure the entry
  was opened to avoid, so **a clean sweep at n=25 is consistent with the outcome it was meant
  to rule out**. 25 is the harness default, not the number that answers the question. Costed
  the decisive version (n≈300 → 1.0%, ~2h of free runner time) and set the revisit trigger at
  n≥100 with zero flakes, which `test.yml` accrues passively for nothing.

  **The attribution entry undercounted its own scope, and sweeping is what showed it.** It
  named "the three merged PR bodies", which reads as the complete set; the bylines were
  stripped from #1/#2/#3 and re-read back from GitHub to confirm. Sweeping *every* PR, issue
  and commit then found **14 commits on `master` carrying an AI co-author trailer and one
  carrying a session permalink, out of 47** — invisible to an entry that only looked at PR
  bodies. Deliberately not actioned: it means rewriting 15 commits and force-pushing a
  **public** `master`, which is the owner's call. One apparent hit (#26) is a false positive —
  prose *about* a rejected attribution check — and **that got demonstrated live**: the global
  pre-PR hook blocked #33's own body, because the body quoted the byline while explaining it
  had been removed. A substring match cannot distinguish the check from the thing checked
  for. The prediction was paid within the hour of being written.

  **The python3 entry overstated its own scope.** It called python3 "the only external tool
  any script in this repo needs"; `test/rules-test.sh` needs `semgrep`, which degrades to a
  loud `1..0 # SKIP` rather than failing — precisely why it read as not-a-dependency. **A
  tool whose absence turns a suite green is still a dependency.** README now names both and
  states the distinction most likely to mislead: hooks read JSON with `jq` *or* `python3` and
  fail open, while `ci/check-version-monotonic.sh` requires it and fails closed.

  **Two shipped files disagreed about a fact they shipped together.** `.github/dependabot.yml`
  non-goal 3 said a version pinned inside a script does not exist here "today";
  `.github/workflows/shellcheck.yml`, same release, pins `SHELLCHECK_VERSION` in `env:` and
  downloads it in `run:` — and its own header states that limit from the other side. Also
  "across three workflows" where four carry a `uses:` site. Both corrected with the original
  wording quoted, so the correction is legible rather than silent.

  **README's Validation section was stale in three places**, all found by re-running rather
  than re-reading: "**Both** are framework-free" over **four** suites; `gate-test.sh` "(173
  assertions)" against a measured **182**; and a sentence whose entire job was to say the
  suite is "unchanged" carrying a count of 24. Counts now live in one place and the two
  previously undocumented suites (version-check 51, rules 39) are described. **A number
  nobody re-measures is a number that rots** — the one that existed only to say "unchanged"
  is gone.

  **Two cross-repo line citations into gstack became symbol references** and are labelled as
  pointers into a repo this one neither controls nor can keep current. Both were verified
  correct first: the claim was right, the citation *form* is what `CLAUDE.md` forbids. A
  third apparent stale citation was deliberately left alone — it sits inside a `## Completed`
  entry that is itself narrating that citation going stale, so it is quoted provenance, not a
  live reference. And the wip-tag decision got the fact it turns on: `item2-wip-quote-stripping`
  is local-only and `c7e56d0b` is not an ancestor of `origin/master`, so "keep it as an
  archaeological record" was never the status quo — the status quo is *ephemeral*.

- **P2 ×4 + P3 ×3: the suites reached CI, the quality axis stopped being claimed, and the
  open half was triaged for the first time.** 0.11.0 → 0.12.0, 2026-08-16. Three batches of
  deferred work that shared no code but shared a failure mode: **each was a place where this
  repo asserted more coverage than it had.**

  **CI — three workflows, one question each, because a green tick is read as an answer to
  whatever question the reader had.** `test.yml` runs all four suites (gate 182, pre-push 15,
  version-check 51, rules 39) on every PR and on `master`; its header says in capitals not to
  make it a required check yet, because passing once is not evidence of non-flakiness.
  `shellcheck.yml` runs `scripts/ ci/ live-test/` with **no exclusion flags** — the five
  deliberate findings (SC2016 ×5, SC1003, SC2034 ×2, all verified against `HEAD` rather than
  recalled) now carry inline `disable=` directives naming their reason at the site, so the
  baseline is zero and a genuinely-wrong SC2016 still fires. It installs a **checksum-verified
  v0.11.0** rather than using the runner's: it shipped unpinned in this same PR, went red on
  the first run against `ubuntu-latest`'s 0.9.0 over three SC2015 false positives, and the
  pin was the fix — suppressing them would have blinded three sites to satisfy a linter older
  than the code. `test/*.sh` is out of scope, 241 findings at that pin, stated in the workflow
  header so the tick is not over-read. `flake-sweep.yml`
  owns the load-sensitivity question `test.yml` deliberately does not: `workflow_dispatch`
  or the `flake-sweep` label, 25 runs at load 4 by default, driving the existing
  `test/s7-flake-loop.sh`.

  **The sweep workflow would have swallowed its own evidence, and that is the part worth
  keeping.** The default runner shell is `bash -eo pipefail`, so a non-zero harness aborts
  the step *before* the summary prints — losing exactly the output the workflow exists to
  collect. The status is captured (`|| rc=$?`) and folded into the verdict instead. Second
  fix in the same shape: an **unparseable** tally now fails rather than passing, because
  defaulting an absent `done:` line to zero is how "died on run 1" reports as "ran 25 times
  and found nothing".

  **`.github/dependabot.yml`** settles the SHA-pin refresh question at the standard answer
  (`github-actions`, monthly, grouped, limit 3) rather than the manual `ls-remote`. Three
  non-goals are in its header: it does not judge the new code (a pin buys immutability, not
  trust); **no npm entry deliberately**, since `package.json` is `private: true` with zero
  dependencies and no lockfile, and the day a real dependency lands, forgeward's own
  `supply-chain-reviewer` starts firing on it; and it sees `uses:` in workflow files only.

  **The error-path fold: measured, then folded, and the losing half of the rule recorded.**
  The pre-committed decision rule was ≥1 true High per 5 PRs → build a seventh reviewer,
  below that → fold. It measured 0, so rules 1 (discarded failure signal) and 3 (unchecked
  conditional-write result) went into `security-reviewer` Step 3 and no reviewer was built.
  Rules 2 and 4 fired zero times anywhere and were **not** folded — adding prompt weight to
  every security review in exchange for a rule that has never fired is a cost with no
  measured return. The precondition this needed first is also done: Step 3 now defines
  fail-open and fail-closed, requires a finding to **name the direction and what a caller
  then believes that is not true**, and requires a stated failure consequence to reach High —
  an unnarratable High is unfalsifiable, and a gate that FAILs on findings nobody can check
  gets switched off.

  **The quality axis: forgeward stopped asserting another tool's coverage.** The measured
  finding was reciprocal deferral — on `04a04fb`, gstack's `/review` skipped `maintainability`
  as `covered-by-forgeward-and-coverage-audit` while forgeward's README skipped quality
  because `/review` covers it, so both installed still meant nobody reviewed it. Scope stated
  as 2 of 22 entries, an existence proof rather than a rate. `README.md` now says forgeward
  does not review code quality and no longer claims gstack does it for you;
  `skills/gate/SKILL.md` prints a PRESENT-case clause naming what the probe can and cannot
  see; `DECISIONS.md` carries the entry either way, generalised to **a deferral may name an
  owner; it may never assert coverage**. `docs/axis-proposals.md` Q2 is marked SUPERSEDED
  rather than edited into agreement. The gstack half is another repo's code and stays open.

  **Docs: the archive convention was applied to itself.** `## Completed` was stale by three
  merged PRs, so #26 and #28 were reconstructed into it and #27 into `TODOS-DONE.md` from
  their commit bodies **before** any cut — and the cut order was resolved with
  `git log --first-parent`, which changed the answer: **#26 merged 39 minutes after #27
  despite the lower number**, so both a date sort and a number sort would have archived the
  wrong entry. 275 lines moved out, six rules lifted into `CLAUDE.md` on the way (parsing
  structured documents, an option that sends refs the argument list never names, a new
  `## Running other people's tools` section, five test rules, three docs rules). Then the
  first-ever triage of the open half, counted rather than described: **four entries deleted
  outright** (the fold decision and its precondition, the `DECISIONS.md`-entry-either-way,
  and the stale-`## Completed` finding), **two replaced by narrower successors** (the SHA-pin
  refresh policy → Dependabot-configured-but-unobserved; open-half-untriaged → nothing
  expires an entry), **three narrowed in place** (quality axis, shellcheck, suites-in-CI),
  and one empty section heading removed. Also repaired: two `see ## Completed` pointers that
  went stale when their targets were archived, one entry carrying **two contradicting
  `**Priority:**` markers** (headline P2, appended paragraph P3), and a suite roster wrong
  since 2026-08-06 (three suites and gate 171; it is four and 182).

  **Not done, deliberately:** the sweep has **not been run**, so the load-sensitivity claim
  is still unmeasured in CI and only the instrument is new; `test.yml` is not a required
  check; Dependabot is configured but unobserved, and a config file is not evidence the
  service is enabled. All three are filed above rather than implied by the workflows'
  existence.

- **P2 ×2 + P3: the two repo-wide interpreter/locale conventions were written down but only
  partially applied, and neither was pinned by anything.** Fixed 2026-08-15. Closes the
  four-`python3 -c`-sites item, the "locale pinning should be repo-wide" item, and the
  `awk`/`wc -c` asymmetry P3 in one lane.

  `python3 -I` now sits at all five shipped sites (`forgeward-diff-hash.sh`,
  `forgeward-gate-check.sh` ×2, `forgeward-pre-push.sh`, and the CI check that already had
  it), and `export LC_ALL=C` at the top of all **13** tracked `*.sh` outside `test/` — the
  11 in `scripts/`, `ci/check-version-monotonic.sh`, and `live-test/setup.sh`. Both inline
  `LC_ALL=C` command prefixes were **removed** rather than kept beside the pin, on the
  standing one-mechanism-per-invariant rule; the sites carry a comment saying so, because a
  reader who finds the prefix gone needs to know it was replaced and not simply dropped.

  **The `-I` entry's threat model was wrong and the correction is the substantive part of
  this commit.** It read: "reaching it at all requires write access to the user's checkout —
  which `TODOS.md` already discloses as defeating the local gate outright", concluding "a
  hardening item, not a live bypass". It is a live bypass. Python imports a *file*, not an
  index, so the shadowing `json.py` arrives with the branch you cloned in order to review it
  — no local write access, and the fork-author escalation the entry reserved for the CI check
  applies here too. Demonstrated end to end, not argued: with `jq` off the PATH and a
  `json.py` committed to the branch, an `-I`-stripped `forgeward-gate-check.sh` **ALLOWS** a
  publish that the shipped one denies. That is A26, and it carries both controls — the
  bypass leg must ALLOW or the assertion is measuring nothing, and the same mutant without
  the `json.py` must still DENY or it is merely broken.

  **Scope limit, stated because the demonstration is narrower than the flag:** the bypass is
  the no-jq arm only. With a working `jq` installed, `json_get` never reaches `python3` and
  the shadow is inert. The exposure is real and conditional, and A26 says nothing about a
  machine with jq.

  Pinned by A25–A29 in `test/gate-test.sh` (177 → 182 assertions), each mutation-checked:
  strip `-I` from any shipped site → A25 red; strip it from the hook → A25 and A26 red;
  delete one script's pin → A27 red; put an inline `LC_ALL=` back → A28 red; `chmod -x` a
  tracked-755 script → A29 red. A25 and A27 are deliberately counted as the **violating**
  form and enumerated from `git ls-files`, so a *new* site added without the flag fails —
  "five sites carry `-I`" would go green the day a sixth arrived without it.

  A29 exists because this commit nearly shipped without it. Inserting the pin across eleven
  files with `awk > tmp && mv` replaced each at the umask default, dropping all eleven from
  755 to 644; every invocation became `Permission denied` and the plugin was completely
  broken. The suite caught it only as 28 unrelated assertions collapsing at once — nothing
  named the cause. A29 names it.

  `test/` is excluded from A27 **deliberately**: the suite spawns these scripts as children,
  so a pin there would be inherited by every one of them and the property A27 checks would
  become untestable from inside the test that checks it. Note also what the pin bought the
  E-series for free — E18 previously asserted "the config reader works under the *test
  runner's* locale", because it could not pin what the script did not pin; the script now
  pins itself, so E18 asserts behaviour under `LC_ALL=C`.

  **Two stale line references were corrected on the way out, and the correction is to stop
  citing lines at all.** The locale entry cited `forgeward-detect-environment.sh:103` for the
  `LC_ALL=C wc -c` and `:112` for the bare `awk`; by the time it was read they were at `:131`
  and `:150`, and inserting the pin moved them again to `:140` and `:159` — drifting twice,
  the second time inside the very commit that was fixing the citation. Both now read as "the
  `config_state` block", per `CLAUDE.md`'s cite-by-symbol rule, which is the only form that
  survives its own fix.

  **The predicted rotation collision landed and was resolved by rebase, and the prediction
  named the wrong entry to cut.** This branch and #29 were cut from the same `master` and each
  archived the 0.8.0 `/ship`-handoff entry while adding its own, so the second to merge
  conflicted. `TODOS-DONE.md` needed no decision — both sides made the byte-identical
  insertion, so git took one copy and the file came out equal to master's. `TODOS.md` kept
  both new entries, leaving six. The filed plan said to cut "the version-monotonicity entry,
  2026-08-06"; the entry actually cut is the config-keys one, because **both carry the same
  `Fixed 2026-08-06` line and only the merge order separates them** — config-keys is #20
  (`246a715`, 2026-08-06) and monotonicity is #22 (`c057dc9`, 2026-08-07), which the prose
  dates cannot show. An oldest-out cut decided from the date printed in the entry would have
  archived the newer of the two. Checked with `git log`, not read off the page.

- **P1 + P2: the 0.9.2 rotation notice searched one persistence channel of two, and read
  its own empty result as clean.** Fixed 2026-08-15, shipped in 0.10.1. Both halves were
  filed 2026-08-14 as follow-ups to the notice itself; both are wording and flags, no code.

  **The missed channel.** A large tool result is truncated in the JSONL at 30 000
  characters and written in full to `tool-results/<id>.txt`, the transcript keeping only a
  `persistedOutputPath` pointer. Every command in the notice carried `--include='*.jsonl'`,
  so none of them could match a `.txt`. Measured on one machine: 277 such files, two
  matching the notice's own pattern set, and one holding a private key the truncated JSONL
  did not contain. So the copy the notice could not see was simultaneously the copy with the
  weaker permissions and the copy with more in it.

  **The permissions claim was tightened after the gate reviewer re-measured it**, and the
  correction is the entry's own lesson applied to itself. The first draft said the `.txt`
  files are 0644 "where the transcripts are 0600" — a universal read off a sample. The
  reviewer's independent count was 279 of 279 at 0644 against **1878 of 1879** at 0600, the
  exception being a transcript that was itself 0644. The direction of the finding is
  unchanged and the outlier makes the exposure marginally worse rather than better, but
  "all transcripts are 0600" was not a thing either of us had established. The README now
  carries the counts instead of the quantifier.

  `--include` was **dropped** rather than widened to two extensions. Widening is the
  smaller diff and the worse fix: an extension list is the same shape of narrowing that
  caused the defect, and it would miss a third channel exactly as silently. The path does
  the scoping now.

  **The false-clean read.** Claude Code expires its own transcripts — `cleanupPeriodDays`
  defaults to 30 — and the unit it reaps is the **session directory**, aged by the parent's
  recency rather than per file. Measured: 0 of 247 top-level session transcripts survive
  past 30 days, while **20 of 1574** subagent transcripts do, alive only because their
  parent session stayed in use. So the leak channel this notice is about is precisely the
  one that outlives the window, and a short-lived session's evidence is gone inside the
  month. Both directions mislead, and this was hit for real: a transcript identified as
  holding an AKIA-shaped value on 2026-08-13 was gone on 2026-08-14 at age 31, before it
  could be re-examined, so that finding is now permanently unresolvable. The notice now
  says an empty result means **unverifiable**, not **safe**, and tells anyone who ran
  0.2.0–0.9.1 in a repo with an untracked credential file to rotate regardless.

  This is the same false-clean shape as the 0.9.3 path bug, arriving by two further routes
  — which is the reason the notice now states its own limits at every command rather than
  once at the top. **Blind spots, stated rather than papered over:** one machine, one Claude
  Code version (2.1.232); `cleanupPeriodDays` is user-configurable, so 30 is a default and
  not a guarantee; whether the 30 000-character threshold or the 0644 mode is stable across
  versions was not checked; and none of it was checked on Windows.

  Untested by construction: this is prose in `README.md`, and no suite in this repo asserts
  anything about it. The surviving P2 above — a possible `forgeward-transcript-audit.sh` —
  is where these two facts would become executable rather than documentary.

- **P1 + P2 FILED, not fixed (the fix is the entry above): the rotation notice's two
  unstated assumptions, measured.** #28 (`ce69eb5`), 2026-08-14 — one file, `TODOS.md`, no
  code and no version bump. Recorded here because a filing-only PR leaves nothing behind in
  the tree, and this one is the entire evidence base 0.10.1 was written from.

  Both entries were filed *beneath* "Nothing in forgeward can scrub a subagent transcript",
  which is correctly scoped — no cleanup this plugin performs touches one — and that correct
  scoping is exactly what hid the two assumptions sitting behind it: that the evidence is
  still on disk, and that the transcript is where it lives.

  **Expiry (P2).** `cleanupPeriodDays` defaults to 30, and the unit reaped is the SESSION
  DIRECTORY, aged by the parent's recency rather than per file. One machine, 2026-08-14,
  Claude Code 2.1.232, setting unset: **0 of 247** top-level session transcripts older than
  30 days, **0 of 207** orphaned `subagents/` directories, and **20 of 1574** subagent
  transcripts older than 30 days — alive only because their parent session stayed in use. So
  the leak channel the notice is about is the one that outlives the window, while a
  short-lived session's evidence is gone inside the month. Both directions break the notice.

  **`tool-results/` (P1).** A tool result over 30 000 characters is truncated in the JSONL
  and written in full to `tool-results/<id>.txt`, the transcript keeping a
  `persistedOutputPath` pointer; every command in the notice carried `--include='*.jsonl'`.
  Same machine, same day: **277** such files, all `.txt`, all mode 0644 beside 0600
  transcripts. Two matched the notice's own pattern set, and in one a private key was
  present in the persisted file and **absent from the truncated JSONL copy**.

  **What those two files actually held is the part worth keeping, and it is not what the
  headline suggests.** Both were local Supabase CLI Docker output, carrying two different
  classes of key that were harmless for two different reasons:

  - the PEM private key is **baked into the `supabase/kong:2.8.1` image** — byte-identical
    across two unrelated projects captured three weeks apart and the live container. Public
    by construction.
  - the `pgsodium_root.key` value is **not** public: absent from the `supabase/postgres`
    image layer, different between two local projects, and unchanged in the affected project
    from the Aug 4 capture to that day. It is inert for an unrelated reason — `pgsodium` is
    not an installed extension in that database (`pgcrypto` only) and it carries zero
    `pgsodium` security labels, so no column is encrypted under it, and a local container's
    key has no bearing on the hosted project.

  A notice written off the first reason alone under-reports the second class entirely. That
  is why 0.10.1's wording says an empty result means **unverifiable**, not **safe**.

  **Blind spots, carried forward unchanged:** one machine, one Claude Code version;
  `cleanupPeriodDays` is user-configurable, so 30 is a default and not a guarantee; whether
  the 30 000-character threshold or the 0644 mode is stable across versions, or on Windows,
  was not checked. The gate fired **no reviewers** on this diff — one prose file, every
  surface absent — which is correct, and is also why nothing above was independently
  re-measured until the 0.10.1 branch, where the reviewer's own count corrected the
  permissions claim from a quantifier to a ratio.
- **P2 + P3: three rules that lived as prose in a personal `CLAUDE.md` became gate checks.**
  Shipped 2026-08-14 as #26 (`41324b0`), 0.9.3 → 0.10.0. Full reasoning in `DECISIONS.md`.
  Prose only fires if the model happens to recall it, it rots silently, and it does nothing
  at all for anyone else who installs the plugin.

  **The SQL vault-secret bullet** (`agents/security-reviewer.md` Step 3) covers three shapes
  that the generic Secrets bullet and Semgrep `p/secrets` both miss, because **none of them
  looks like a high-entropy literal**: a credential in a plaintext config table; a secret
  leaking into **derived storage at execution time** (`cron.schedule(..., format(...))`
  baking a token into `cron.job.command`, structurally invisible to any diff scanner because
  the migration text may hold only a *reference* that gets resolved); and a generic
  `get_secret(name text)` `GRANT`ed to `authenticated`/`anon`, which turns the vault into a
  lookup API so one broken-authz path reaches *every* secret.
  **Must NOT fire on** non-secret configuration in exactly such a table — URLs, feature
  flags, publishable/anon keys designed to be public — nor on a row holding a secret's
  *name*, which is the pattern being recommended. **Cannot see** the live database, so a
  credential inserted by hand in `psql` or by a seed outside the diff is invisible; and it
  cannot tell whether the platform *has* a vault, so on a plain Postgres the remedy is
  "encrypt at rest / move it out of SQL", not "use the vault".

  **`rules/env-config.yml`**, a second bundled Semgrep pack, wired into Step 2 the way
  `wp-security.yml` already was but deliberately **without `--error`**: (1) `??` as an
  env-var fallback, which only falls back on `null`/`undefined`, so a blank-but-present
  variable — the routine output of a secrets sync and of most CI secret injection — reaches
  the consumer as `''` and the default is silently discarded (observed in production:
  `process.env.POLAR_SERVER ?? 'sandbox'` produced `new URL('')` and took down a Vercel
  build at page-data collection); and (2) an env-dependent SDK client at module scope, which
  evaluates at import time and so fails the whole build rather than the one route that
  needed the credential. **Noise-checked against a 237-file production codebase before
  shipping**, which is what surfaced the real false-positive class: `?? ""` is behaviourally
  identical to `|| ""` for a string-or-undefined value and was 8 of 16 hits. Excluded.

  **The placement decision is the substantive part, and it was a real choice rather than a
  formality** — neither rule is a security finding; both are build safety. Chosen: ship in
  the security pack and report **every** finding at Low, tagged defense-in-depth. The reason
  generalizes and is worth keeping: **what a reviewer BLOCKS is the remit that matters, not
  what it prints.** Critical/High is the only bar that fails a gate, so pinning the pack at
  Low widens the reporting surface and leaves the blocking surface bit-for-bit unchanged —
  which answers "don't widen security's remit" structurally rather than by intention. The
  rejected alternative — disclose `build-config` as an axis no installed tool owns — is
  incoherent while the detection exists: announcing "nothing covers build-config" in the
  same run that just scanned for it and found two is a worse lie than the silence it
  replaces. Enforced in three places that are supposed to agree: the rule's
  `metadata.forgeward-report-severity: low`, the pack header prose, and the Step 2
  instruction to report at Low *regardless of what the JSON says*, with an explicit "do not
  promote one because the consequence sounds severe".

  **`test/rules-test.sh` — 39 assertions**, house style, wired into `npm test`, in three
  classes: positives, negatives (every legitimate configuration the rules must not fire on),
  and **blind spots pinned as silent**, so a future semgrep that closes one fails the suite
  and forces the doc to be corrected rather than quietly becoming a lie. Fixtures are
  generated into a scratch dir and **never committed** — a `.ts` fixture under `test/` would
  itself be scanned by forgeward's gate on every later PR. A **trust check runs first**: a
  fixture semgrep cannot parse turns every silence-assertion green, so a non-empty `errors`
  array is a hard failure, not a warning. Not hypothetical — a fixture syntax error masked
  results during development, and later a botched mutation truncated a file by 141 lines and
  the check caught it. Skips loudly when semgrep is absent (`1..0 # SKIP`).

  **The gate found a real bug in this branch's own tests, and it was fixed rather than
  deferred.** Under `set -uo pipefail` without `-e`, a failing `mktemp -d` yields an empty
  `$TMP`, so `$TMP/fixtures` becomes the **absolute** path `/fixtures` and the heredocs write
  outside the sandbox the file's own header promises they stay inside. Unprivileged that
  fails with `EACCES`; a root-run CI container has a writable `/` and it succeeds silently.
  Medium never fails a gate — fixed anyway, because it was two lines and it contradicted the
  file's own stated invariant. Verified by pointing `TMPDIR` at a nonexistent directory.

  **Measured, not assumed.** Mutation testing (exact single-line deletions from the pack)
  caught **5 of 6**; the sixth is genuinely redundant under semgrep 1.169, which normalises
  function forms — that redundancy is now *recorded in the pack* rather than hidden by
  deleting a line the engine might stop covering. It also caught a **wrong causal claim in a
  shipped artifact**: rule 2's message attributed an IIFE blind spot to the arrow-function
  exclusion specifically, when the function-scope exclusions cause it collectively.
  Extension coverage, measured with byte-identical content: `.js .mjs .cjs .jsx .ts .tsx`
  scan; **`.mts` and `.cts` do not** — zero findings *and* zero errors, so the miss looks
  exactly like a clean file. Recorded in the pack header, and deliberately **not** pinned as
  expected behaviour in the suite, since that assertion would go red the day a future
  semgrep fixes it. Step 1's extension list gained `.mjs`/`.cjs`, previously dropped before
  the pack could see them.

  **Deliberately not done, both with revisit conditions rather than left silent:** not
  vendored into `ci-gate` — advisory WARNINGs turning a required check red is exactly the
  green-on-arrival failure `ci-gate`'s first core rule forbids; and **no AI-attribution /
  `Co-Authored-By` check**, considered and rejected. `/gate` handing off to `/ship` is
  structurally a perfect chokepoint, but forgeward is a plugin other people install and
  plenty of them legitimately want a co-author trailer. If it is ever added it is an opt-in
  config key defaulting to off — a separate decision.

- **P3: the completed half of `TODOS.md` was pure carrying cost on every sweep — 12 entries
  archived, 12 rules lifted.** Shipped 2026-08-14 as #27 (`f148a6a`), docs only. This file,
  `CLAUDE.md`, and the convention both implement are what that PR produced, so this is the
  entry that describes the archive you are reading.

  `TODOS.md` is read in full on every pre-commit sweep and re-read from cache on every
  request after, while completed work is the one thing a sweep can never act on. The 12
  oldest completed entries moved here; the 5 most recent stayed, because those are the ones
  a sweep actually consults ("did I already do this?"). **One commit, not two** — an entry
  deleted from `TODOS.md` that never lands in the archive is invisible across two diffs and
  obvious inside one.

  **Nothing was pruned, and archiving alone would have made things worse.** These entries
  carry the reversed decisions and the deliberate non-goals, so moving them out of the swept
  read path makes that precedent *less* findable, not more. Twelve rules were lifted into a
  new root `CLAUDE.md` on the way out, with this file and `DECISIONS.md` as their provenance,
  cited **by symbol, never by line**: `TODOS.md` already carried one stale line reference,
  and the extracted file is meant to outlive line numbers.

  **Two things this pass found rather than moved.** `## Completed` was **stale by two
  releases** — the 0.9.2 secrets-scanner fix (#24) and its 0.9.3 follow-up (#25) had no entry
  at all, so "the 5 most recent" silently meant five older ones, and splitting on that would
  have mis-dated the archive permanently; the entry was written from the two commit bodies
  *before* the split, including the four gaps that shipped disclosed-not-fixed. And
  `DECISIONS.md` was newest-first for 15 sections with the 16th at the bottom — 2026-08-10,
  the newest of the lot, appended below a 2026-06-22 entry — so a top-down reader concluded
  2026-08-07 was the latest decision. Moved to the top, and the ordering is now stated in
  that file's header, since it broke for want of ever being written down. Verified as a pure
  move: the 228-line section is byte-identical at its new position.

  **The `-I` rule was extracted WITH its exception, deliberately.** At the time,
  `ci/check-version-monotonic.sh` was the only site carrying `python3 -I`;
  `forgeward-diff-hash.sh`, `forgeward-gate-check.sh` (×2) and `forgeward-pre-push.sh` did
  not, and that gap was already filed as a P3. Extracting the rule without the exception
  would have converted a filed hole into a false claim of coverage, so `CLAUDE.md` named the
  four sites and said not to read the rule as coverage. (Closed the next day by #30, which
  put `-I` at every site and pinned it with A25/A26 — the rule in `CLAUDE.md` now reads as
  coverage because it finally is.)

  **Filed, not fixed**, in a new `## Docs hygiene` section. The load-bearing one: **nothing
  verifies the rule-extraction step this convention depends on** — a pass that archives
  without lifting rules is a silent regression on precedent retrieval, and the archive named
  four pieces of reasoning that did not become rules. Also: the open half was still ~70KB and
  untriaged (the completed half was only 22% of the file, so a split is relief and never a
  fix), and `CLAUDE.md` now ships to plugin installers — inert in the cache, but keep it free
  of anything machine-specific.

  **Gated:** privacy fired and returned PASS; UI, LLM, public-pages, deps and code-security
  all skipped, the diff being four Markdown files. The elevated risk was specific — the new
  entry and the moved `DECISIONS.md` section both narrate a real incident in which a scanner
  read a developer's untracked `.env` into a persisted transcript — so the reviewer swept both
  files for credential shapes and found only the detection patterns themselves and an
  illustrative `://user:pass@`. It also re-derived the split arithmetic independently (16 + 1
  = 17, 5 kept, 12 archived, the archived block byte-identical to the original lines) and
  verified the `-I` count in **both** directions. One Low, fixed in place: the entry had dated
  the 0.9.3 docs correction 2026-08-10, which is the *security* fix's authored date; both of
  #25's dates are 2026-08-12.

- **P0: the secrets scanner read a developer's untracked, gitignored dotenv file
  during a real gate run, and the values landed in a persisted subagent
  transcript.** Authored 2026-08-10 and merged 2026-08-12 as #24
  (`60a067a`, 0.9.2); the rotation notice's path was corrected 2026-08-12 as #25
  (`acbdc12`, 0.9.3). Full reasoning in
  `DECISIONS.md`. *(This entry was missing from this list until 2026-08-14 — the
  deferrals it produced were filed in the open half at the time, but the
  completion itself never was, which made `## Completed` read as stale by two
  releases.)*

  Two defects, and the first hid the second. The documented Gitleaks invocation
  passed the whole changed-path list to a command that takes ONE path; read from
  `cmd/directory.go` (v8.30.1) rather than inferred, there is no cobra `Args`
  validator, so a second positional is not an error — `len(args) != 1` leaves
  `source = "."`, the cwd. The extra path is neither rejected nor
  dropped-with-the-first-honoured: the whole target is silently replaced.
  Verified against the binary — one path scanned 15 bytes, two scanned 176,
  identical to `dir .`. And `dir` mode is a filesystem walk regardless, so
  fixing the first alone leaves any directory in the changed-path list
  re-triggering it.

  The fix makes the scanner structurally unable to see anything outside the
  reviewed diff. The primary shape is the commit range
  (`gitleaks git --log-opts="<base>...HEAD" --redact -f json -r -`), with
  per-file `dir` only where working-tree state is genuinely needed.
  `forgeward-scan.sh` gained layer 4: for the `dir`/`file`/`directory` family the
  target must be exactly one existing regular file that git tracks — zero paths,
  two paths, a directory, and an untracked file are all refused. The subcommand
  is matched against an enumerated set and anything else refused, so an unlisted
  value-taking flag placed BEFORE it (`gitleaks --unlisted V dir .`, where `V`
  looks like the subcommand) cannot slip a directory scan past the guard. That
  also covers `detect --no-git` and `protect`, HIDDEN in 8.30.1 — absent from
  `gitleaks --help` but still live, the same walk under older names, and verified
  to read the untracked file before the guard refused all three shapes.
  `--redact` is now unconditional, which closes the value half while layer 4
  closes the read half; neither is sufficient alone. Trivy lost `secret` from
  `--scanners` for the same reason, short `-r` was closed for gitleaks (only the
  long form had been enumerated, so `-r evil.json` reached the write the long
  form exists to refuse), and supply-chain-reviewer's `trivy fs <paths>` was
  corrected to one path.

  Deliberately **not** a filename exclusion: a committed credential file is a
  genuine finding and must keep being reported.

  Four gaps were found while verifying this and **disclosed rather than fixed**,
  so their absence is not read as coverage — each is in the script's NON-GOALS
  block, in `DECISIONS.md`, and as a P3 above. Layer 1 matches flag TOKENS and
  cannot see inside a flag's VALUE, so `--log-opts="--output=x"` forwards
  `--output` to `git log` and writes the file, using the very flag this change
  starts recommending; layer 3 contains it (the run exits 3 with the path named)
  and P8l pins it as accepted-and-contained, asserting it stays LOUD rather than
  asserting a refusal that was not built. The target check is TOCTOU, accepted
  because that attacker already has local write access. The tracked check needs a
  work tree, not live since the reviewer always runs inside the repo under
  review. And `stdin` mode has no path token to check, so piping untracked
  content in by hand is held only by prose — an argv wrapper cannot see a pipe.

  Coverage: `gate-test.sh` P8i/P8j/P8k/P8l, including an end-to-end fixture on
  the observed shape with a **control leg** that bypasses the wrapper and asserts
  the raw scan DOES leak — without it the assertions pass with the guard removed,
  since `--no-banner` alone prints no values. Mutation-verified twice: layer 4
  disabled → P8j and P8k fail; the unrecognized-subcommand branch softened to
  `return 0` → P8j fails. 177/15/51 assertions green.

  The 0.9.3 follow-up: the rotation notice told users to look in
  `~/.claude/projects/<project>/subagents/*.jsonl`, a path that does not exist —
  the real layout has a session-uuid level in between. The published grep
  therefore exits `No such file or directory`, which reads as "nothing matched",
  i.e. clean. A user following the notice exactly concludes they were unaffected
  and does not rotate, and the notice has then retired their suspicion as well.
  For a rotation notice that is the worst available failure mode.

- **P3: `git push origin --delete <branch>` was denied when the current branch had no
  marker, even though the enforced pre-push hook already allows it.** Fixed 2026-08-07.
  Full reasoning in `DECISIONS.md`.

  The finding was the asymmetry, not the friction. `forgeward-pre-push.sh` skips any ref
  whose local SHA is all-zero — verified against real git, which writes
  `(delete) 0000000… refs/heads/x <remote-sha>` on the hook's stdin for BOTH the
  `--delete` and `:refspec` forms — while the PreToolUse matcher went straight to `deny`
  without asking what was being pushed. The layer whose own header calls itself "a fast
  best-effort reminder" was stricter than the thing it reminds you about, and its advice
  ("run the gate") was unactionable: a deletion publishes no code, so no reviewer could
  review it and no marker could ever attest to it.

  Shipped: `_is_delete_only()` in `scripts/forgeward-gate-check.sh`, taken only on a
  TRUSTED residue (quoted spans already blanked), only on ONE simple command, only when
  `git push` is the literal command word, matching flags as whole argv tokens. Plus
  `_residue_trusted`, which records which scan path answered — the verb test is fail-safe
  either way, but this is the one decision here that can turn a deny into an allow. Tests
  A23 (31 cases) and A24 (degrades closed when `awk` is unavailable) in `test/gate-test.sh`.

  **Three real pushes at a real remote wrote the design; reading git-push(1) would not
  have.** `--delete y z` deletes both (so `--delete` alone settles it); `:q newcode`
  deletes `q` and PUBLISHES `newcode` (so the colon form additionally caps plain tokens at
  one — the remote); and `--tags origin :d2` deletes `d2` and PUBLISHES a tag on an
  unpublished commit (so unrecognised options DENY instead of being skipped, which the
  first draft got wrong). An option can send refs the argument list never names.

  **The branch's own security review found a real bypass in the first draft.** `strip_quoted`
  BLANKS a quote or backslash to a space instead of deleting it, so an empty quote pair inside
  one real argv token splits it into two tokens bash never produced: `git push /pub/repo'':x.git`
  is ONE repository argument, the classifier saw plain=1 colon=1, exempted it, and it really
  published `refs/heads/main`. `_is_delete_only` was the first consumer of that residue to depend
  on exact token boundaries rather than on "does this word appear". Closed by refusing the
  exemption on any `'`, `"` or `\` — a complete cover, since blanking can only ever ADD a
  boundary and every path that adds one needs one of those three characters.

  **The re-gate then found the same shape again through globbing, which is what turned the
  token test into an allowlist.** `read -ra` does not glob, so `git push [os]* :newcode` is
  one token to the classifier and several words to bash — reproduced against a real remote,
  where it deleted `newcode` and PUBLISHED `secretbranch`. Two misses of the same kind in
  one branch is the argument for inverting the test: every token must now match
  `^[A-Za-z0-9_.:/@+=-]+$`, so the construct nobody thought of fails closed.

  **Mutation testing changed the code twice, and one of the two was a fail-OPEN.** Every
  deny case was already green before the fix — the old matcher denied everything — so the
  deny half proves nothing on its own. The command-word check was two lines and *neither
  could be killed alone*, because `_pub_re` already guarantees `git push` adjacent; they
  were collapsed into one regex. And the newline refusal was unpinned: without it
  `read -ra` sees only the first line, so `--delete x\ngit push origin main` would have
  been ALLOWED. Found by mutation, not by review.

- **P2: nothing checked that a merge moved the version FORWARD, so merge order was
  load-bearing whenever two version-bumping PRs were open.** Fixed 2026-08-06. Full
  reasoning in `DECISIONS.md`.

  The live instance — #17 to 0.7.5 and #18 to 0.7.6, where merging #17 second walks the
  marketplace manifest backward — was avoided by merging #17 first, by hand. Nothing was
  keeping three manifests monotonic except whoever was paying attention at merge time.

  Shipped: `ci/check-version-monotonic.sh` (never-backward across all three manifests, plus
  a head-side agreement check, runnable by hand), `.github/workflows/version-check.yml` (the
  repo's first CI workflow, PR-only — on a push to master the base ref *is* the commit being
  checked, so the comparison would be against itself and green vacuously), and
  `test/version-check-test.sh` (R1–R25c, 51 assertions, wired into `npm test`).

  Three comparator traps are pinned rather than merely avoided. `major*1000000 +
  minor*1000 + patch` ties `1.0.1000` with `1.1.0` (R6/R6b); a string comparison calls
  `0.10.0` behind `0.9.0`, which this repo hits on its next minor (R5/R5b); and the
  component-wise `$((10#$x))` that replaced both **wrapped at 2^63**, which this branch's own
  security review demonstrated end to end — base `18446744073709551617.0.0`, head reverted to
  `1.0.0`, `ok ... not behind`, exit 0 (R13/R13b). The comparator now uses no arithmetic at
  all. And the version validator's first draft was `printf | grep -qx` — the P1
  SIGPIPE/pipefail defect already paid for once here — now a fork-free `[[ =~ ]]` with a
  comment at the line saying why the tempting edit is wrong.

  **The 2^63 wrap is the entry to re-read before writing the next comparator.** R6 pinned the
  10^3 ceiling and stayed green throughout, because it was written against the comparator
  already chosen — it could only see the ceiling that had been thought about. Same shape as
  V5/V6 passing while the jq/python3 divergence shipped underneath them. The comment above the
  fix asserted "no such ceiling" and was simply false; the assertion beside it could not tell.

  **It happened a second time in the same file, which is what makes it a pattern rather than an
  anecdote.** Round 2 of the security review found the ambiguity guard counting with a bare
  `grep -c` — matching *lines*, not *occurrences* — so two version keys on one line counted as
  1 and skipped the guard entirely. R8 was green throughout, because R8's fixture puts the two
  keys on separate lines: the one arrangement `grep -c` gets right. The input still failed
  closed, one check later and citing the wrong reason, so an assertion reading only the exit
  status would also have stayed green. R8b pins the one-line arrangement and asserts on the
  *message*. Generalized: an assertion written alongside a mechanism inherits that mechanism's
  blind spot, and only an outside reader — or a mutation — sees past it.

  **And a third time, as a High.** Round 3 found that under a UTF-8 locale GNU grep will not
  match `[^"]*` across invalid UTF-8 and silently drops the line, so a fork PR author could
  commit a clean forward *decoy* `"version"` key plus a poisoned real one and the poisoned key
  became invisible to the script while every JSON parser took it (duplicate keys are last-wins).
  Base 0.9.0, decoy 0.9.1, poisoned 0.1.0 → `ok: version 0.9.1, not behind master`, exit 0. A
  complete bypass of the file's whole purpose from a one-line hex edit. Fixed at the time with a
  script-wide `export LC_ALL=C`.

  **A fourth round, and it is the one that changed the design.** JSON `\uXXXX` escapes are legal
  in **key names**: `{"version":"0.9.1","version":"0.1.0"}` contains exactly one literal
  `"version"` byte sequence, so the guard counted 1 and passed while every parser decoded two
  keys and took the second. Same bypass, same one-line edit, and `LC_ALL=C` is irrelevant to an
  escape that is pure ASCII — verified end to end: `ok: version 0.9.1, not behind master`, exit
  0, while `node` and `python3` both read `0.1.0`.

  **Rounds 2, 3 and 4 defeated the same textual reader by three unrelated mechanisms, so the
  reader was deleted rather than patched a third time.** Versions are now read by `python3`'s
  stdlib `json` with `object_pairs_hook` refusing duplicate keys by name. Three independent
  evasions of one approach is not three bugs — the class is *text tools do not parse JSON*, its
  members cannot be enumerated, and a fourth patch would only have been the third demonstration
  that patching does not converge. The repo's two earlier declines of "just use jq or python3"
  both stand and neither reaches here: PyYAML is not stdlib (`json` is), and the marker writer
  runs on arbitrary user machines (this runs on `ubuntu-latest`). Their shared principle — one
  arm everybody gets beats a better arm some people get — is why there is a **single** python3
  arm and no `jq` fallback: two readers that can disagree is the diff-hash divergence rebuilt on
  purpose. Absent python3 is a named FAIL, never a skip (R18/R18b).

  **A fifth round, and it is the round-4 fix looked at from the other end.** Round 4 piped the
  manifest to the parser on **stdin** so the bytes arrived unaltered, and wrote a comment there
  naming both transforms a command substitution performs. The parser's *answer* still came back
  through `out="$(python3 …)"`, which performs both: `$(...)` **deletes NUL bytes** (warning on
  stderr, exit status untouched) and **strips trailing newlines**, and both are legal inside a
  JSON string. So the `X.Y.Z` check validated a value the file did not contain. Committed
  `"version":"1\u00009.0.0"`; python3 and node both read a version with an embedded NUL; the check printed
  `ok: version 19.0.0, not behind master` and exited 0. Fixed the way round 4 was fixed — close
  the channel, not the instance: the shape check moved *inside* the parser, so only digits and
  dots ever cross. `re.fullmatch`, not `re.match(…$)`, because Python's `$` also matches before a
  single trailing newline and the anchored form would have rebuilt half the bypass inside its own
  fix. A `RecursionError` escaping `except ValueError` was the same round's Low.

  Round 6 went one layer below all of that: `python3 -c` puts the **current working directory**
  on `sys.path`, and this script runs from the root of the checkout it is judging — so
  `import json` resolved against repo content, and a fork author's five-line `json.py` at the
  repo root made `json.loads` return whatever they liked. Reproduced with base `9.0.0` and head
  manifests genuinely `1.0.0`: `ok: version 999.999.999, not behind master`, exit 0. Rounds 2–5
  hardened how the manifest is *parsed*; this replaced the *parser*, so every earlier guard was
  intact and irrelevant. Fixed with `python3 -I`, chosen over a `sys.path` edit because the CWD
  entry is one of four channels the audited repo has into the interpreter — `-I` also implies
  `-E` (PYTHONPATH and friends) and `-s` (user site-packages, hence `usercustomize`) — and
  patching one channel at a time is exactly how rounds 2 through 5 went. R22/R22b/R22c pin one
  channel each; R22d is the positive control.

  Round 7 went out one layer instead of down: the head side read each manifest off the
  **filesystem** (`read_version "$f" < "$f"` — a plain `open(2)`, which follows symlinks) while
  the base side read it out of the **object store** via `git show`, which returns a symlink's
  target text and never dereferences it. Git tracks symlinks as mode `120000`, so a fork PR
  author commits the three manifests as links to a file outside the checkout and gets
  `ok: version 13.37.0, not behind master (3 manifest(s) compared, all three agree)`, exit 0 —
  a pass asserted about a commit containing no version field at all. The asymmetry was written
  down in the script's own header as a neutral implementation detail. Both sides now go through
  one `require_blob` and one object-store read, so the bytes parsed are the blob in the commit
  by construction; reading HEAD rather than the worktree also means a hand-run ignores
  uncommitted edits, which is stated as blind spot 10 and mitigated by a stderr note naming the
  files (R24b).

  Round 8 was the first PASS: five distinct attempts on round 7's fix (non-canonical tree modes,
  clean/smudge filter divergence, `core.symlinks=false`, replace-refs, ref-name injection through
  `github.base_ref`) all failed closed for the reason the code claims, so that round checked the
  comments against the machine rather than against themselves. Its one Low was a channel slip —
  the base-side "manifest absent" note went to stdout while its sibling went to stderr — invisible
  to all 47 assertions because `run()` folds the streams, which is the suite's blind spot in
  miniature and is now pinned by R25. It also surfaced, as a *safe* case, a second pre-round-7
  bypass worth an assertion: `.claude-plugin` itself committed as a symlink to an external
  directory (R23f).

  Seven rounds produced seven defects, each in the layer the previous round had just hardened —
  the operative lesson is that **an adversarial reader found all seven and the test suite found
  none of them**, which is an argument about how much review a comparator is worth, not about the
  tests being bad. Every new assertion from round 3 on reads the **message** rather than the exit
  status, because two of them failed closed for an unrelated reason and would have passed an
  exit-status check.

  **`export`, not `local`, and this is the part most likely to be got wrong later.** A `local
  LC_ALL=C` is not passed to a spawned child unless the name was already exported — verified
  directly: `local` gives the child `<unset>`, a command prefix and `export` both give `C`. It
  works for a bash builtin like `[[ x < y ]]` and does nothing for `grep`. `num_lt`'s own `local`
  was removed rather than kept beside the export, because the redundant mechanism was precisely
  the ineffective one.

  **Verifying a claim about a tool means invoking the binary the code invokes.** The first attempt
  to check round 3's finding appeared to refute it. That was wrong: `grep` at an interactive
  prompt here is a shell function shimming to **ugrep 7.5.0**, while a script gets `/usr/bin/grep`
  = **GNU grep 3.7**, and shell functions are not inherited by a non-interactive child. The ad-hoc
  check and the code under test were different programs with different invalid-byte behaviour.
  Use `type -a` and an absolute path.

  **Mutation testing earned its place and should not be skipped on the next one like it:** the
  zero-comparison floor reddened *nothing* until R12 was written for it, so a guard that read
  as covered was in fact unpinned. Twenty of twenty-one mutations reddened exactly the
  assertions naming them; the exception is the `LC_ALL=C` *collation* effect, filed above as
  unobservable — though round 3 showed that label covers only the effect that was measured, not
  the pin, and round 4 then made the measured effect moot, which is the same trap twice.

  **Four "vacuous" results, none of them a coverage gap, and they split into two causes.** Three
  were harness artifacts that never applied — `M6`, the `grep -c` revert, and the walk-recursion
  mutation — reddening R11, R8b and thirteen assertions respectively once applied properly. The
  fourth, `M21`, **applied cleanly and was still a no-op**: it added an `ok:*)` arm after the
  real one, and `case` takes the first match, so the mutant was unreachable. An `assert count ==
  1` on the anchor (now the harness's standing shape) catches the first cause and structurally
  cannot catch the second. A mutation reporting nothing is a claim to verify, not a finding to
  accept — accepting any of the four would have added a test for a guard that was already pinned.

- **P2 ×2: two documented config keys were parsed by nothing, and the reader refused the
  shapes real users write.** Fixed 2026-08-06, shipped in 0.9.0. Full reasoning in
  `DECISIONS.md`.

  0.8.0 gave `.forgeward/config.yml` its first reader, for `standalone.substitutes` alone —
  which made the gap *harder* to see, not smaller: a file where one key genuinely works is a
  stronger claim that the others do than a file where none do.

  Shipped: flow sequences (`[a, b]`) and simply-quoted scalars now parse in both list forms;
  `seo.posture` is read and validated against the six postures by whole-string comparison, so
  an unrecognised value returns the reviewer to detection rather than reaching it; marker
  schema 4 carries `seo_posture`; README gained a `.forgeward/config.yml` section naming the
  honoured keys and the limits.

  **The python3-YAML arm this file previously recommended was declined, and the reason
  overturns the recommendation rather than deferring it:** PyYAML is not in the standard
  library (verified — no `yaml` in `sys.stdlib_module_names`), so `python3` present says
  nothing about `import yaml` working. That arm would be selected by what happens to be
  installed and would parse *different shapes* from the fallback — the 0.7.5 divergence, which
  V7 exists to catch. Extended the single awk instead, verified identical under gawk, mawk and
  busybox awk.

  E19–E27, all eight mutation-tested. E27 is the one worth remembering: it pins that an awk
  which *exits 0* while printing nothing usable reads `unreadable` rather than
  present-with-an-empty-list, and its second clause is a positive control, because
  `unreadable` is also what a genuinely broken fixture produces. E17 had to be updated in the
  same commit or it would have silently become vacuous — see the coupling item above, which
  that discovery extended.

- **P2: the gate reported a `/ship` handoff it never performed when gstack was absent.**
  Fixed 2026-08-06, shipped in 0.8.0. Closes the Option B decision, the README quality
  claim, the marker-environment item, and the "untested handoff" item in one lane.

  The handoff had been flagged as "untested — likely-broken", guessing a hard failure. It
  was not a hard failure, and the reality was worse: the marker is written *before* the
  handoff, so the PASS was never at risk and the user was never blocked — the gate simply
  announced "Handing off to /ship" on a machine where nothing shipped. Same class as the
  0.7.4–0.7.6 error-path work: the failure surface is identical to the success surface.

  Shipped: `scripts/forgeward-detect-environment.sh` (probes `ship`/`review`/`cso`, reads
  `standalone.substitutes`, always exits 0, fails toward disclosure); gate Step 1c naming
  any axis whose owner is absent and then gating normally; Step 3 branching on
  `gstack_ship`; marker schema 3 carrying the environment. README line **57** (not 45 —
  the number in this file and in `docs/axis-proposals.md` was wrong, and is corrected in
  both) now qualifies the quality claim.

  Three documents were also describing behaviour the code did not have, which is how the
  gap survived: `live-test/LIVE-TEST.md` told testers the gate "tells you it would" hand
  off standalone; `docs/axis-proposals.md` said "forgeward refuses the `/ship` handoff",
  conflating this repo's own dev workflow with plugin behaviour; and
  `forgeward-gate-check.sh`'s halt message promised it "ships in one motion". All three
  corrected in place. Full reasoning in `DECISIONS.md`.

  E1–E18, each mutation-tested in both directions where a direction exists. E2 is E1's
  positive control and is load-bearing: gstack is installed on the author's machine and
  the probe is not a PATH lookup, so an assertion that forgets any of its three roots
  finds the real gstack and greens vacuously. E12–E17 were added *after* E1–E11 were
  green, for the two Medium findings of the 0.8.0 security review (a followed config
  symlink; a character allowlist mistaken for structural validation) — a reminder that
  a passing suite is evidence about the assertions in it and nothing else. E18 pins that
  a CRLF config parses identically to an LF one — not a security case, a regression guard
  for the trailing-CR class that already shipped once in 0.7.6. Suites: gate 162/162,
  pre-push 15/15.

- **P1: unparseable hook input was ALLOWED through the PreToolUse gate — and the #11 fix
  that was supposed to prevent it had been silently cancelled by the branch it fell
  through to.** Fixed 2026-08-06, shipped in 0.7.6.

  `json_get`'s python3 arm wrapped `json.load` and the field traversal in one
  `except Exception: pass`, so "this is not JSON" and "that field is absent" both came back
  empty with status 0. #11 had made the **jq** arm check its status and fall through to
  python3; on malformed input that fall-through fired exactly as designed and handed control
  to a branch carrying the same defect. Net effect, measured on both paths: a truncated
  payload containing a real publish verb was allowed, with jq present *and* with jq absent.
  A13/A14 could not see it — with a broken jq and no marker the hook denies for an unrelated
  reason, so the arm looked covered.

  Fix: split the parse from the traversal (parse failure → exit 1, absent field → exit 0 with
  empty stdout), and on unreadable input decide from the **raw bytes** — deny if they contain
  a publish verb, allow otherwise. Narrow on purpose: this hook fires on every Bash tool call,
  so denying on any unreadable payload would wedge the session the moment the JSON tool broke.
  Pinned by A20 (denies on both arms) and A21 (does not over-deny ordinary Bash). Both
  mutation-tested.

  Surfaced by the quality-axis base-rate measurement, as a lead — verified here before it was
  acted on, and it turned out broader than reported: the agent described it as reachable only
  via the python arm, and it is reachable with jq present too.

  Two things this took with it. `test/gate-test.sh`'s A4 case `g""it push` had been passing for
  the wrong reason since it was written — `pretool()` assembles JSON with raw `printf`, so the
  unescaped quotes made the payload invalid and the verdict came from the empty-command
  short-circuit rather than from the matcher. It is now `g\"\"it push`, decodes correctly, and
  still allows, so the disclosure stands and is finally earned. And the first draft of A20's
  jq-less PATH shim was a hand-written tool list that omitted `dirname`; the script died on its
  second line, emitted nothing, and "no output" reads as ALLOW — a green assertion proving
  nothing. The shim now mirrors the real PATH minus jq, and both shims carry a positive control.

  The gate's own security review of this branch then found the **expansion** path still carried
  the fail-open: it computed `_unreadable` and never read it. Rated Low as an unused variable; it
  is not. On that path an empty `cwd` means no `cd` happened, so `is_fresh()` answers for whatever
  directory the hook process inherited — a fresh marker in an unrelated repo lets the `/ship`
  through. Closed by halting unconditionally there, with no raw-text narrowing, because that path
  fires only on a typed `/ship` and a false halt costs one retry. Pinned by A22, whose **first
  draft was vacuous and was caught by mutation testing**: it ran the probe from the harness's own
  cwd, which has no marker, so removing the guard entirely still produced exit 2. It now runs the
  hook process from inside the gated repo, which is the only arrangement where the inherited-marker
  fail-open is reachable at all.

- **P3: `marker_get` discarded jq's exit status, in both copies, and one of them still used
  `print()`.** Fixed 2026-08-06, shipped in 0.7.6.

  The third instance of the error-path class (after `json_get` and `strip_quoted`, #11). It
  fails CLOSED, which is why it was deliberately left alone at 0.7.3 — and that reasoning was
  wrong twice: fail-closed here means *every* push on a box with a broken-but-installed jq is
  refused permanently, with the python3 fallback beside it unreachable, which is not a hook
  erring safe but a hook that has stopped enforcing and started blocking. `command -v jq`
  succeeding means jq is INSTALLED, not that it RUNS.

  `pre-push.sh`'s copy carried a second defect: it still used `print()`, whose trailing newline
  becomes CRLF on Windows while `$( )` strips only the LF — the surviving CR rides on `base`,
  fails to resolve as a ref, and a fresh marker reads as stale. `DECISIONS.md` had recorded that
  fix as landed since 2026-08-02; it had only ever landed in `gate-check.sh`. That paragraph is
  now corrected in place.

  Fix: both copies capture jq's output, check its status, and fall through to python3 — and
  **A19 asserts the two function bodies are byte-identical**, which is the part that matters.
  The duplication is deliberate (separate entry points, no shared library), so drift is its
  standing cost, and a note in a decisions file demonstrably does not contain it. Pinned by A18
  (gate-check) and P14 (pre-push), both with an ungated-branch control so an early-exiting hook
  cannot read as a pass. All mutation-tested: reverting either copy reddens exactly the
  assertions that name it, and nothing else.

  Known blind spot, disclosed rather than papered over: the `print()` half is **not observable on
  POSIX** — `$( )` strips the LF, so both forms produce identical bytes on Linux and macOS. It is
  covered only indirectly, by A19's byte-parity check.

- **P2: `forgeward-diff-hash.sh` produced a DIFFERENT hash under `jq` than under the
  `python3` fallback.** Fixed 2026-08-06, shipped in 0.7.5. Full entry in `DECISIONS.md`.

  `jq -S` pretty-prints while `json.dumps` used compact separators, so the canonical
  snapshot of the same manifest was different bytes on a machine with jq and one without,
  and a marker written on either read as stale on the other. A second divergence sat behind
  it: without `-a`, jq emits raw UTF-8 where `json.dumps` defaults to `ensure_ascii=True`.
  Fix is `jq -S -c -a` on both invocations, verified by fuzzing the two branches against
  each other rather than reading the flag docs.

  Two things worth carrying forward. First, V5/V6 pinned that the fallback has the same
  *semantics* and passed throughout, because each compared a branch only against itself —
  the new V7 compares them to EACH OTHER, and mutation-testing confirms V5/V6 stay green
  under the reverted fix while V7 goes red. Second, the accepted cost: every marker in every
  repo re-gates once at this version, not just plugin repos, which is why it shipped alone
  and why V4 was reframed from a back-compat assertion to a payload-assembly one rather than
  having its expected value quietly updated.

  Not fixed, disclosed instead: number literals still diverge (`jq` preserves source text,
  python normalizes through float) and cannot be aligned, because `json.dumps` calls
  `float.__repr__` directly and ignores a subclass. Unreachable for manifests that carry
  versions as strings. Pinned by V8 as a known divergence.

- **P1: `supply-chain-reviewer` returned PASS without ever checking dependency CVEs when
  gstack was absent.** Fixed 2026-08-05, shipped in 0.7.4.

  The agent deferred by name — *"gstack's `/cso` Phase 3 already covers dependency CVEs,
  install-scripts, and lockfile integrity — do NOT re-do those"* — unconditionally, so on
  a machine with no `/cso` nobody checked them and the reviewer returned clean. Live
  coverage hole in shipped code, not a proposal.

  Fix: `scripts/forgeward-detect-gstack-skill.sh <skill>` answers "is this gstack skill
  installed here?" deterministically and fails closed — exit 0 only for a directory named
  `<skill>` or `<prefix>-<skill>` holding a `SKILL.md` whose *frontmatter* carries the
  `(gstack)` marker. `supply-chain-reviewer` now runs it before reading the diff and
  declares `SUPPLY-CHAIN MODE: DEFERRED` or `FULL` on its first output line; FULL adds
  CVEs, install/lifecycle scripts, and lockfile integrity, scoped to dependencies the
  diff adds or version-changes. A script rather than a prompt instruction because an LLM
  judging "is gstack installed?" per run fails silently in the permissive direction —
  the exact fail-open shape `json_get`, `strip_quoted` and `marker_get` were each burned
  by. Pinned by D1–D12 in `test/gate-test.sh` (137 pass), and the three arms were
  mutation-tested: dropping the marker check reddens D4/D9, dropping the prefix arm
  reddens D2, refusing symlinks reddens D6.

  What this did NOT fix, stated because the evidence is broader than the remedy: the
  evidence is about the *deferral pattern*, the fix closes exactly one instance of it.
  The Option B posture statement and the untested standalone `/ship` handoff are still
  open above. Detection sees presence, never diligence — gstack installed and never
  invoked is indistinguishable from gstack covering the axis — and it cannot see a
  substitute such as Dependabot or a CI SAST job. Accepted cost: the same diff can FAIL
  standalone and PASS with gstack present.

- **P1: the intermittent "fail-open" reproduces from a false negative in the test
  harness's own `denies()` helper, not from the gate.** Fixed 2026-08-03.

  Scope of the claim, stated precisely because the whole item was a lesson in this:
  the harness defect is PROVEN and it produces exactly the observed symptom. The two
  original 0.7.2 sightings were not instrumented, so they cannot be retroactively
  attributed with certainty — what can be said is that every detail recorded about
  them fits this mechanism, and no evidence now points at the gate. The S7 forensics
  block stays in the suite precisely so a genuine gate fail-open, if one ever occurs,
  is identified in one run instead of costing another investigation.

  `denies()` was `printf '%s' "$1" | grep -q '...'` under this suite's `set -o
  pipefail`. `grep -q` exits the instant it matches, closing the read end while printf
  may still be writing; printf takes SIGPIPE and exits 141; pipefail promotes that to
  the pipeline's status. The helper reports NO-DENY on output it just matched. Every
  deny assertion in the file ran through it, so a scheduling hiccup surfaced as an
  intermittent GATE fail-open — which is why staring at the gate never explained it.

  Observed, not inferred: `PIPESTATUS=(141 0)` (printf killed, grep MATCHED) 7 times in
  20000 under fork pressure and 0 times on a quiet box — `test/denies-race-probe.sh`.
  A 3000-iteration run of `test/matcher-flake-probe.sh --load 16` reproduced 4 "fail
  opens" whose captured hook output was a perfectly well-formed DENY; that captured
  output is what redirected the investigation away from the gate.

  It fits every recorded data point: the fail direction; two sightings inside one
  ~5-minute window (a load spike); the isolated S5→S7 replay clean 15/15 on a quiet
  box; 17/17 and 22+ clean runs likewise; and the companion `dependency added -> hash
  CHANGED` assertion passing both times, because that one is a pure bash string
  comparison with no pipe in it. The earlier estimate of a "~8% rate" was measuring
  machine load, not the gate.

  Fix: `case` glob, which forks nothing and so can neither lose the race nor fail to
  exec. Applied to `denies()` in `test/gate-test.sh`, the same shape in the P2
  assertion of `test/pre-push-test.sh`, and both new probes. (References here are by
  symbol, not by line: the `test/gate-test.sh:398` in the original entry was stale
  before it was ever acted on.) A repo-wide sweep found no other
  instance; product code's one `grep -q` reads a FILE, not a pipe. The general rule:
  only an EARLY-EXIT reader (`grep -q`, `head`) can orphan its writer — `jq` and
  `python3` drain to EOF, so those pipelines are unaffected.

  Verification: the replacement measured 0 misses in 20000 under the same load that
  produced 7 with the old form. The full suite then ran 40 times under 12 fork-pressure
  workers (sustained loadavg ~20, ~4900 assertions) with zero failures — a harsher
  condition than the one that produced the single pre-fix failure, which landed on a
  comparatively quiet box. Record the load, not just the run count: a clean sweep on an
  idle machine is the weak version of this experiment, which is why
  `test/s7-flake-loop.sh` now takes `FORGEWARD_S7_LOAD`. (2026-08-03)

- **The gate DID have a real fail-open, found while chasing the above, and it is not
  the one that was being chased.** Two silent `exit 0` paths in
  `forgeward-gate-check.sh`, both deterministic under a helper that FAILS AT RUNTIME:

  1. `json_get` ran `jq -r ... 2>/dev/null` with stderr AND exit status discarded, so
     "jq failed to run" and "the field is absent" were the same observation. The empty
     command died at the pre-filter and the hook exited 0 without ever reading a
     marker. `command -v jq` still succeeded, so the python3 branch was never reached:
     being INSTALLED was treated as being FUNCTIONAL. Now the status is checked and a
     failed jq falls through to python3.
  2. The `strip_quoted` residue guard rescued only a COMPLETELY EMPTY result, so a
     TRUNCATED one was scanned as though whole and the verb could fall off the end of
     it. A7 pins awk MISSING (exit 127 → empty → rescued); nothing pinned awk
     truncating. Now the residue is trusted only if it is at least as long as the
     input, which the one-for-one substitution in `strip_quoted` guarantees.

  Never observed in the wild — found by reading, then demonstrated deterministically
  with `test/helper-failure-probe.sh` (three shapes, all ALLOW before, all DENY after).
  Pinned by A13/A14/A15.

  The length guard in (2) carries its own risk in the opposite direction: if
  `strip_quoted` ever stops substituting one-for-one, the fallback fires on ordinary
  commands and merely-MENTIONED verbs start denying. A16 pins that, covering the
  multi-line and trailing-newline shapes most likely to break the assumption and not
  covered anywhere else. A trailing newline survives the round trip only because the
  command substitution that EXTRACTS the command strips it too, so both sides shorten
  together — asserted rather than reasoned about, since that symmetry could quietly
  change.

  A16 was mutation-tested rather than merely observed passing: relaxing the guard to
  `-le` (always fall back to raw text) turns it red along with A2/A4/A5/A10/A11/A12,
  so the invariant is pinned from several directions and the new test is not vacuous.

  The guard's comment originally claimed `strip_quoted` "substitutes one-for-one,
  nothing is ever dropped". The 0.7.3 security review fuzzed that (600k+ trials,
  gawk/mawk/busybox) and FALSIFIED it: two shapes return a LONGER residue — a dangling
  backslash ending an unterminated double-quote, and multi-byte UTF-8 inside quotes
  under a byte-oriented awk (17 out of 15). Nothing returns a SHORTER one except real
  awk failure. The guard only ever needed NEVER-SHORTER, so it stands; the comment now
  states that property instead of the false stronger one, and A17 pins the
  byte-oriented-awk behaviour (skipped when neither mawk nor busybox is installed, so
  the suite's "no extra test runtime" footprint is unchanged).
  Suite 125/125, pre-push 14/14. (2026-08-03)

- **`forgeward-detect-base.sh` paid a `gh repo view` network call on every run.**
  Fixed in 0.7.2: step 1 is guarded on a remote carrying a network URL, so scratch
  repos with no remote or a filesystem-path remote skip it. A short-circuit, not a
  reorder — with a real remote the call still fires first and still wins. Suite time
  on the same 104 assertions, three runs each: unguarded 114s / 201s / 93s, guarded
  29s / 33s / 37s. B14's five assertions pin both directions, including the positive
  control that a networked remote still reaches `gh`, and the suite makes no real
  network call at all now (a stub `gh` answers). (2026-08-03)
- **`forgeward-diff-hash.sh` neutralized the version field in root `package.json`
  only, so every plugin release forced a spurious re-gate.** Fixed in 0.7.2: the
  canonical-snapshot treatment now covers `.claude-plugin/plugin.json` (top-level
  `.version`) and `.claude-plugin/marketplace.json` (nested `.plugins[].version`),
  in both the `jq` and `python3` branches. Neutralization is targeted, never
  recursive, so an npm `overrides` entry nesting a `{"version": ...}` object cannot
  hide a dependency pin change. The extra payload sections are appended only when
  the files exist, so a repo with no `.claude-plugin/` hashes byte-identically to
  before and its markers survive the upgrade (pinned by V4). (2026-08-03)
- **Publish matcher over-denied on merely-mentioned commands.** Deferred explicitly
  in PR #6, PR #7 and PR #8 before landing. Fixed in PR #9 (0.7.1) by deciding
  MENTIONED vs ISSUED by quoting rather than substring: quoted spans are blanked
  and the plain test runs on the remainder. Four earlier attempts failed; the
  fourth's three consecutive command-substitution desyncs are why substitutions are
  now distrusted rather than parsed. 94 gate + 14 pre-push green on WSL and Windows
  Git Bash. (2026-08-02)
- **Gate markers accumulated forever, one per branch ever gated.** Fixed in PR #8
  (0.7.0): pruned on marker write, checked against `refs/heads` under the common git
  dir so a branch live in another worktree keeps its marker. 11s → 238ms on 1000
  dead markers. (2026-08-01)
- **Orphaned marker `fix/publish-matcher-quoting.json` pruned by hand.** `gc_markers`
  runs only on the marker-*write* path, so an orphan on a clean `master` never
  self-clears — there is no gate run to trigger it. (2026-08-03)

  What was completed here was the *instance*, not the condition, and the condition
  recurred on 2026-08-05 with `fix/supply-chain-cve-deferral.json` — costing a second
  investigation that ended at the same diagnosis. The behaviour is intended and stays:
  the orphan is harmless, self-clears on the next gate of any branch, and the
  alternative (sweeping from `gate-check` or `pre-push`) means deleting files during a
  push on a path that must fail open. What was missing was a statement of it where a
  reader would hit it, so it is now the fifth entry in the `BLIND SPOTS` list above
  `gc_markers()` in `scripts/forgeward-write-marker.sh`. Expect orphans; do not debug
  the sweep. (2026-08-05)
- **Two stale remote branches deleted** — `feat/route-posture-classification` and
  `feat/security-reviewer-redefinition-toctou`. Both squash-merged (as #5 and #4),
  patch-ids identical to their master twins, zero unique content. Deleted via
  `gh api`; SHAs `6cfdea6` and `31ca190` recorded in case either is ever needed.
  (2026-08-03)
