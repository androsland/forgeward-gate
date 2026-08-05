# Decisions

Durable decisions for the forgeward gate, with the reasoning that produced them.
`RESOLVED` entries record a real bug, its repro, and the fix, so a future regression
is recognizable from the symptom alone.

## RESOLVED — `supply-chain-reviewer` deferred dependency CVEs to a `/cso` that need not exist

**Date:** 2026-08-05

**Symptom.** On a machine with no gstack installed, `supply-chain-reviewer` returned
`SUPPLY-CHAIN VERDICT: PASS` on a diff adding dependencies without anything having checked those
dependencies for known vulnerabilities. Found by reading, not by a report — which matters, because
the failure is invisible from the outside: the reviewer fires, produces a clean report on the two
classes it does own, and passes. There is no error and nothing missing from the output.

**Cause.** The agent carried an unconditional instruction: *"gstack's `/cso` Phase 3 already covers
dependency CVEs, install-scripts, and lockfile integrity — do NOT re-do those. You own
typosquatting/hallucination and licensing only."* forgeward is scoped as a delta against gstack —
the README reviewer table's third column is literally "why it's here (not redundant with gstack)" —
and scoping by delta means **every deferral becomes a hole when the other side is absent.** The
instruction was correct on the maintainer's machine and on no machine without gstack, which is the
entire installed base this plugin does not see.

**Relationship to the 2026-07-13 entry below.** That one reversed "delegate security to `/cso`"
because `/cso` is opt-in and manual and *was not run*. This is the same family and a rung lower:
that deferral assumed the user would RUN `/cso`, this one assumed they would HAVE it. The earlier
fix did not generalize because it was framed as being about the security axis; it was actually
about the deferral pattern. Anything that defers an axis by naming a tool now has to establish the
tool exists — which is why the detector is a general script and not an inline check.

**Decision.** Make the deferral conditional. `scripts/forgeward-detect-gstack-skill.sh <skill>`
answers "is this gstack skill installed here" deterministically; the reviewer runs it first and
declares its mode. `/cso` present → DEFERRED, unchanged prior behaviour. `/cso` absent → FULL: it
also audits dependency CVEs, install scripts, and lockfile integrity, and a Critical/High CVE in a
dependency the diff adds or upgrades is a FAIL.

**Fail-closed, deliberately asymmetric.** Every ambiguous answer is "not installed". A false
negative costs a duplicated audit; a false positive is a silently skipped check — the bug itself.
Detection requires both a directory named for the skill (bare, or behind a `[A-Za-z0-9_]+-` prefix,
since gstack's `setup` defaults to `SKILL_PREFIX=1` and names the skills-dir entry `gstack-cso`) and
the `(gstack)` marker in that `SKILL.md`'s frontmatter. The two arms are independent:
`bin/gstack-patch-names` rewrites `name:` only and never touches `description:`, so prefixing does
not disturb the marker. Both arms are pinned by mutation test — removing either turns a specific
assertion red (D2, and D4/D9 respectively), as does making the check stop following symlinks (D6),
which matters because gstack installs its skills as symlinks.

**Stated limits, because an unstated limit reads as a claim of coverage.** (1) It detects
*presence*, never diligence: gstack installed and never once invoked is indistinguishable from
gstack actively covering the axis, so exit 0 means "the tool the deferral names is here", not "the
axis was audited". (2) It cannot see a substitute — a repo covering CVEs with Dependabot, Snyk, or
a CI SAST job looks identical to one covering them with nothing; deciding what to do about that
belongs to `.forgeward/config.yml` and is tracked in `TODOS.md`. (3) The marker is a convention, not
a contract: if gstack ever drops the `(gstack)` suffix, detection reports ABSENT and callers
duplicate work — the safe direction, and preferred to matching on the bare name.

**Accepted cost.** A PASS now means slightly different things on two machines: the same Critical CVE
FAILs the gate standalone and is `/cso`'s to find when gstack is present. That variance is real and
is the price of not shipping the unconditional deferral. It is mitigated here by the mandatory
`SUPPLY-CHAIN MODE:` line in the reviewer's report, and recording the detected environment in the
pass marker — so the variance is auditable from the artifact rather than from memory — is tracked
in `TODOS.md`.

**Scope of this fix vs the evidence behind it.** The evidence is about the *pattern*: any deferral
naming an absent tool is a hole. The fix closes exactly one instance of it — the CVE deferral,
which is the only one where an axis actually goes unchecked. `security-reviewer`'s two gstack
references are positioning prose that skips nothing, and the other four reviewers name gstack zero
times, so there is no third instance to close today. The remaining gstack coupling is the gate's
`/ship` handoff, which is a convenience rather than an axis and is untested standalone. Both are in
`TODOS.md` under "Standalone posture"; this entry does not claim to have resolved them.

## RESOLVED — the publish matcher denied any command CONTAINING a publish verb

**Date:** 2026-08-02

**Symptom.** `scripts/forgeward-gate-check.sh` tested the publish verbs as a bare
substring of the whole command, so a command that merely MENTIONED one was denied as
if it issued one. It fired six times in a single session on this repo, including on
the patch script that was fixing it. A repo whose subject matter IS these commands
trips it constantly; a commit message quoting one, a `grep` for one, and a JSON test
payload containing one were all refused.

**Cause.** The test asked "does this text contain the verb", which cannot distinguish
DATA from CODE. Both are text.

**Fix.** Decide by QUOTING, which is how the shell itself encodes that distinction:
blank the quoted spans, then run the plain substring test on what remains. This needs
no model of separators, reserved words, or command prefixes — a `time`-prefixed
publish matches for the same reason a bare one does. Word boundaries on both sides
keep `git pushx` and `npm run push-docs` clear.

**Three attempts failed before this one; the failures are the useful part.**

1. and 2. Anchored the verb to a "command position" (start of text, after a
   separator, after a reserved word). Both failed review, in OPPOSITE directions:
   too narrow (`time`, `env FOO=bar`, `sudo`, `nohup`, backticks, and a
   backslash-escaped verb all evaded, every one of which the old substring caught),
   then too wide (widening the anchor class to `!` and `)` denied ordinary prose such
   as `echo 'Careful! ... will trigger CI'`). Chasing both at once means enumerating
   shell grammar with a regex, which this file's own header already calls a dead end.
   **Position was the wrong signal.**
3. Blanked the quotes with bash extglob substitution — the right idea, wrong
   mechanism. It mishandled backslash state (outside quotes an escaped quote is
   LITERAL, so a scanner that only pairs quote characters mis-pairs and blanks a
   command that really executes), and it was superlinear in quote DENSITY: 2.3s on
   1KB and 55s on 3KB of quote-dense input. Its own code comment quoted 0.006s on
   20KB, measured on quote-SPARSE input — true, and useless, because density is what
   drives the cost. Preserved on local tag `item2-wip-quote-stripping`.

**The constraint that caused attempt 3 was self-imposed.** "No fork" was assumed, not
required: `json_get` already forks `jq` or `python3` on EVERY invocation of this hook,
so a single `awk` pass was available the whole time. The fix is one awk pass tracking
quote state, backslash state, and command-substitution scope, gated behind a
`push|create` prefilter so the common path stays fork-free. Measured on WSL/gawk 5.1.0:
~7ms for the fork; the scan itself is linear and density-independent (1ms at 3KB, 10ms
at 20KB, 17ms at 60KB).

**A fourth failure mode, found in security review after the fix was already written.**
The first version of the scanner tracked quote parity FLAT across the whole command.
bash does not: each `$( … )` and each backtick span gets its own quoting scope. So a
mismatched quote type inside a substitution flipped parity for everything after it and
swallowed a later, entirely separate, entirely unquoted publish command:

```
git commit -m "$(printf '%s' "it's done")" && git push    ->  ALLOWED, and really pushed
a="$(printf '"')" git push                                ->  ALLOWED, and really pushed
```

An apostrophe in a commit message is enough. This was a REGRESSION against the old bare
substring, which caught both because it ignored quoting entirely — the exact shape the
"kept honest" disclosure existed to prevent, missed by all three disclosed bullets and
by tests A1–A7.

**Then twice more, each time in the fix for the previous one.** A scope stack was added
so each `$( … )` got its own quote scope. Round 2 found that a scope opens only on `$(`,
so a plain `(` … `)` pair inside a substitution — a subshell, the second paren of
`$(( ))`, any literal parens — popped the real scope early. Per-scope paren depth fixed
that. Round 3 found that a `case` pattern clause produces a bare `)` with no opening
paren at all, which did the same thing:

```
git commit -m "$( (true) ; git push )"        ->  ALLOWED, and really pushed
echo "$(case y in y) git push;; esac)"        ->  ALLOWED, and really pushed
```

**So the approach was wrong, not the implementations.** Three consecutive reviews, three
different desyncs, every fix correct and every one leaving another. The next version
would have modelled `case`/`in`/`esac`, and this file's own header already says where
enumerating shell grammar ends.

**The fix is to stop parsing substitutions and start distrusting them.** If the command
contains `$(` or a backtick, the blanked residue is not trusted and the RAW text is
matched instead. That cannot hide anything, and it retires the entire desync class
rather than its current instance. The scope stack, the paren depth and the backtick
tracking were all deleted; the scanner went back to quote and backslash state only,
which is all it needs for the commands it still handles.

What this buys and what it costs, precisely: commands WITHOUT a substitution — a commit
message, a grep pattern, a JSON payload, which is exactly the shape of all six original
false denials — keep the precise treatment. Commands WITH one over-deny if they mention
a verb anywhere. Nothing can be hidden by a scanner bug in between, because there is no
longer a scanner on that path.

**The generalizable lesson, and it cost three rounds to learn.** All three bugs had the
same shape: a state desync whose damage lands AFTER the construct that causes it. Every
test that put the interesting token near the verb passed, because the verb was never
where the corruption was. When a scanner carries state across a line, the test that
matters puts the trigger EARLY and the verb LATE with unrelated text between. All three
were found by executing against stubbed binaries; reading the code said it was correct
every time. And when consecutive fixes to the same mechanism each reveal a new instance,
the signal is to delete the mechanism, not to add a case to it.

This is also the argument for running the gate on a change whose whole subject is the
gate: each disclosure was honest about what it had considered, and each was still wrong.

**Method note, which is why this one held.** The expected verdicts were not derived by
reading shell grammar. Every case was executed against stubbed `git`/`gh`/`glab`
binaries to observe whether a publish ACTUALLY ran. That oracle corrected two beliefs:
a case drafted as a deny turned out to execute nothing (`\"` inside double quotes is
literal, so the command stays one argument), and a documented "blind spot" turned out
not to be a gap at all (an unterminated quote makes the command unparseable, so
nothing runs and allowing it is correct). Both are now assertions.

**A fourth review round, and the premise itself was wrong.** The comment above says
quoting encodes data-vs-code. It does not. Quoting suppresses splitting and globbing;
the shell then concatenates adjacent fragments back into one word. So a quoted COMMAND
WORD executes exactly like an unquoted one, while the scanner blanks the span and the
regex stops seeing the verb:

```
'git' push        g'i't push        git 'push'        g""it push      ->  all really push
```

This one is NOT fixed, and the reason matters more than the gap. The only thing
separating `git 'push'` (runs) from `echo 'the command is git push'` (does not) is
whether the quoted word sits in COMMAND POSITION. Any rule that catches the first
catches the second, which is precisely the over-denial this change exists to remove, and
deciding position is the grammar-enumeration dead end the file header warns about. The
old bare substring missed these too — `'git' push` does not contain the characters
`git push` either — so nothing regressed; the gap was simply never disclosed. Pinned in
A4 so it stays disclosed.

The same round found one that WAS fixable. An unquoted backslash-newline is a splice:
bash deletes both characters and the lines join with nothing between them, so
`git pu\<newline>sh` really pushes. Two things went wrong — awk saw two records and put a
space and a boundary where bash puts nothing, and the raw text contains neither "push"
nor "create", so the pre-filter exited before any scanning happened. Continuations are
now joined ABOVE the pre-filter, and A11 fails if that line is moved back below it.

**And fixing that exposed an older one, in `json_get`.** The join worked on WSL and did
nothing on Git Bash. Cause: on Windows, python3's stdout is a TEXT stream and translates
every `\n` to `\r\n`, so a multi-line command arrived carrying a CR that the shell it
describes never sees — the join looked for `\` + LF and found `\` + CRLF. The python
branch now writes bytes (`sys.stdout.buffer.write`) instead of using `print()`. This was
pre-existing and silent: every multi-line command has been mildly corrupted on Windows
since the fallback was written, harmless for single-line matching, and invisible on any
machine with `jq` — jq does not translate newlines, so the bug only exists on the
python path. Neither machine here has jq, which is the only reason it surfaced.

Worth stating as a rule rather than an anecdote: **a difference between two platforms is
only findable by running both.** Nothing about reading this code suggests a CR, and no
amount of reasoning on WSL would have produced it.

**A fifth round, and the same overclaim a third time.** The comment introduced above said
raw-text matching "cannot hide anything". It cannot hide anything QUOTING would have
hidden, which is a much smaller claim. A separator supplied at RUNTIME defeats it, in the
raw text exactly as in the residue, because the regex wants literal whitespace between
the words:

```
git${IFS}push      git$IFS'push'      gh${IFS}pr${IFS}create    ->  all really publish
```

Not fixable here for the same reason as the quoted command word — catching it means
modelling word-splitting and expansion. Disclosed and pinned in A4. Pre-existing: the old
substring missed these too. The same class can split the VERB rather than the separator:
`git pu''sh` runs, carries no literal `push`, and therefore dies at the cheap pre-filter
— a full miss where even the raw-text fallback never runs.

The same round found one that WAS fixable, on the platform this file keeps getting caught
by. On an NTFS-backed checkout the PROGRAM name resolves case-insensitively, so `Git push`
really runs a push on Git Bash — while git's own subcommand parsing stays case-sensitive,
so `GIT PUSH` does not. The verb test is now case-insensitive (`nocasematch`, scoped to
that one test and restored, since it also changes `case` semantics and the artifact guard
above depends on those). The pre-filter deliberately stays case-sensitive: a real publish
always carries a lowercase `push`/`create`, so the cheap path stays exact. Pinned by A12.

`marker_get` got the same byte-writing treatment as `json_get`. Its values are
single-line so the continuation bug never applied, but `print()`'s trailing newline still
becomes CRLF on Windows and `$(...)` strips only the LF — the surviving CR rides along on
`base`, which is then passed to `forgeward-diff-hash.sh` as a ref, fails to resolve, and
makes a genuinely fresh marker read as stale. Fail-safe (an extra gate run, never a false
PASS), but it was the untouched twin of a bug fixed two functions above it.

**Accepted loss, stated because it is real.** A publish verb inside a quoted argument
to a shell wrapper (`bash -c`, `eval`, `ssh host`, `trap ... EXIT`) is no longer
denied. The old substring caught those. Blanking the quotes is what hides them, and
un-blanking is exactly the over-denial this change removes. It is not the accidental
"I forgot to gate" shape this layer targets, and the enforcement boundary is still the
pre-push hook, which binds to resolved refs and SHAs. Pinned in `test/gate-test.sh` A4
so the disclosure cannot silently go stale.

**On completeness, which this entry has now got wrong three times.** First it said 118
oracle-checked cases meant "no command outside the list went unnoticed"; the next review
produced two that were, both inside the categories that sentence named. Then the fix for
those introduced "that cannot hide anything"; the round after falsified it with
`git${IFS}push`. The pattern is not that the individual claims were careless — each was
written directly after testing the thing it described. It is that a claim about what
CANNOT happen is not something testing can establish, and every round of this file that
tried to state one was wrong within a review.

So: the disclosed list is what has been FOUND, on bash 5.1.16 (WSL) and 4.4.23 (Git
Bash), across 118 executed cases plus five review rounds. It is not a proof of
completeness, and no sentence here should read like one. A lexical matcher over shell
text cannot be complete in principle — that is exactly why this is a reminder and the
pre-push hook, which sees resolved refs and SHAs after the shell has finished expanding
everything, is the boundary that actually holds.

Bash 5.3's value substitutions `${ cmd; }` / `${| cmd; }` run a command with neither
`$(` nor a backtick in the text, so the guard also matches `${` followed by whitespace
or `|`. Matching a bare `${` was tried first and reverted — `${VAR}` is ordinary bash,
and routing every quoted-variable command to raw text gave back a large slice of the very
over-denial this change exists to remove.

**And that arm was documented as unreachable here, which was wrong — for an instructive
reason.** The comment said neither local shell supports the syntax, on the strength of a
probe that ran `bash -c '${ git push; }'` and got "bad substitution". The probe used
`/bin/bash` (5.1.16). This script's shebang is `#!/usr/bin/env bash`, which on this
machine resolves to a linuxbrew **5.3.15** that executes it for real. The measurement was
correct and answered a question about a different interpreter than the one the hook runs
under. Round 6 caught it because the reviewer's shell resolved the same way the script's
does. The mechanism was fine — the arm denies correctly on 5.3 — but "I tested it" is
only as good as testing the thing that actually runs.

Covered by `test/gate-test.sh` A1–A12. Each assertion was mutation-tested: five go red
against the old substring matcher, two against the extglob attempt, A7 against removing
the awk-absent fallback, A8 against removing the substitution guard, A11 against moving
the continuation join back below the pre-filter, and A12 against dropping `nocasematch`.

Two of those assertions exist because a test was found to be hollow rather than wrong,
which is the same failure twice and worth naming. A9 covers the harness: `pretool()`
assembles JSON with raw `printf`, so a case containing an unescaped double quote reached
the hook as an EMPTY command and was allowed by short-circuit while appearing to exercise
the matcher — one A2 case was silently hollow that way. And A8's `allow` controls were
originally three substitutions containing no `push`/`create` at all, so the pre-filter
short-circuited every one of them before the guard they were supposed to control was ever
consulted; they now carry `push-docs` so they reach it. A test that cannot fail is not a
test, and both of these looked green the whole time.

## RESOLVED — base detection returned a stale LOCAL branch, mis-scoping the review

**Date:** 2026-07-31 · supersedes *"base detection on a direct-to-base commit"* below,
whose step-4 special case is now one instance of the general rule.

**Symptom.** `scripts/forgeward-detect-base.sh` returned a bare branch NAME (`master`),
and `skills/gate/SKILL.md` fed it straight into `git diff "<base>...HEAD"`, where a bare
name resolves to the **local** branch — which may be arbitrarily out of date with its
remote.

**Repro (verified, over-scoping).** A repo whose local `master` had never been
fast-forwarded: local `de1bbf3`, `origin/master` `5b94aac` (14 commits ahead).
`git diff --name-only master...HEAD` → **267 files**; `origin/master...HEAD` → **0**.
The gate would have dispatched six reviewers over 267 files of already-merged code.

**Repro (verified here, under-scoping — the dangerous direction).** Base branch with
unpushed commits, feature branched off them: `main...HEAD` lists only the feature file
while `origin/main...HEAD` lists the feature file **plus** the unpushed base commits the
push will publish. The gate reviews less than ships and writes a PASS marker for a
surface it never saw — a **false PASS**. Covered by `test/gate-test.sh` B6.

**Cause.** All three name-resolution arms produced a bare name, and two of them proved a
remote ref existed and then discarded it: the `origin/HEAD` arm stripped
`refs/remotes/origin/` off a ref it had just read, and the `origin/main` arm verified
`origin/main` and set `base=main`. Guaranteeing a non-empty base — the reason the script
exists — was never sufficient: it also has to be **current**.

**Fix.** Two-stage resolution. Stage A picks the branch NAME (unchanged). Stage B
resolves that name to the **publish boundary** ref: the branch's configured upstream
(`<base>@{upstream}`, so a fork tracking `upstream` and a local branch tracking a
differently-named remote branch both work), else `<remote>/<name>` for the first remote
that actually has it, else the local branch. A remote ref is adopted only when
`git rev-parse` confirms it exists — nothing is blindly prefixed with `origin/`, so a
local-only repo, an unauthenticated `gh`, and a base branch with no remote counterpart
all correctly stay local. Detached HEAD is unaffected: resolution never depends on which
branch is checked out.

**Silent correction, loud report — argued, not assumed.** Blocking on drift was rejected:
a base branch behind its remote is the normal state of a working checkout, not an error,
and a gate that refuses to run on the common case gets bypassed — a bypassed gate reviews
nothing. Silence was also rejected: "your local master is 14 commits behind" is a fact the
user acts on, and a silent re-scope makes the reviewed surface differ from what the user
would compute by hand. So the re-scope is automatic (a mis-scoped diff is a correctness
bug, not a preference) and the drift goes to **stderr**, leaving stdout exactly one clean
ref for `$(...)` capture. `SKILL.md` Step 0 requires the orchestrator to repeat the note.

**Knock-on, and it is correct.** The marker now records a remote-tracking base
(`"base": "origin/main"`), which both `forgeward-gate-check.sh` and
`forgeward-pre-push.sh` replay through `forgeward-diff-hash.sh` at push time. If a fetch
moves `origin/main` between gate and push, the publish boundary genuinely moved, the hash
flips, and the gate re-fires. Slightly more re-gating, and the alternative — pinning to a
boundary that has since shifted — is the false PASS this entry exists to remove.

**Stated blind spots** (in the script header and `SKILL.md`): it never runs `git fetch`,
so `origin/<base>` is only as current as the last fetch — the same class of error one
level up, invisible from here; and it infers the base from repo defaults, so it cannot
know a PR targets a release branch or is stacked on another feature branch.

**Coverage.** `test/gate-test.sh` B5–B13: behind-remote, ahead-of-remote (with an
assertion that the naive base misses what the push publishes), no remote at all, detached
HEAD, fork with a non-`origin` upstream, base with no remote counterpart, local branch
tracking a differently-named remote branch, single-line stdout + non-empty stderr note,
and `--name`.

## RESOLVED — a read-only reviewer wrote scanner output into the repo it was auditing

**Date:** 2026-07-31

**Symptom.** Running `agents/security-reviewer.md` created a directory named `C` +
U+F03A (bytes `43 EF 80 BA` — the private-use colon substitute MSYS/Cygwin uses) at the
**root of the repo under review**, containing a nested path tree with `semgrep.json` at
the leaf.

**Cause (confirmed, not inferred).** A scanner was given an absolute *Windows* output
path from a POSIX shell. Reproduced directly: `semgrep scan --json -o
"C:/Users/…/scratchpad/semgrep.json" a.js` creates the entire `C:/Users/…` tree inside
the current directory — semgrep's writer creates the parents itself, so no separate
`mkdir` is involved. Under a POSIX runtime `C:/…` is a **relative** path; MSYS stores the
`:` as U+F03A on NTFS, which is the byte sequence observed. Confirmed on Git Bash
(`MINGW64_NT-10.0`) that a path whose `C:` is not the first component lands as a
directory tree in the CWD with exactly that on-disk encoding.

**Why it is not cosmetic.** (1) The tree is untracked and matched by no common
`.gitignore`, so any `git add -A` commits the reviewer's scratch into the user's
repository. (2) A read-only reviewer wrote into the repo it was auditing, breaking the
contract the gate's whole design rests on and advertises.

**Why the fix is not a prompt.** It happened **twice**, the second time with a spawn
prompt that explicitly instructed the agent to write all scanner artifacts outside the
repository. An instruction is not a control.

**Fix — four layers, narrowest first, none sufficient alone.**
1. `scripts/forgeward-scan.sh` — the invocation reviewers are now told to use. Refuses
   output-file flags and drive-letter arguments, puts the report on stdout, and diffs the
   repo's untracked set across the run, reporting anything the scan left behind and naming
   the drive-letter shape specifically.

   **It reports; it does not delete — and that is not timidity.** The first draft removed
   the tree it had just watched a scanner create, which looks obviously safe. It is not:
   on Git Bash the directory is named `C` + U+F03A, MSYS maps that back to `C:`, and
   `readlink -f "C:"` there resolves to `C:/` — **the drive root** (verified on
   `MINGW64_NT-10.0`). That `rm -rf` would have targeted the user's entire C: drive on
   precisely the platform this bug occurs on. Only the `./`-prefixed form
   (`rm -rf -- "./C:"`) stays relative, so the wrapper prints that for the user to run.
   The hazard is written into the script so nobody re-adds the automatic delete.
2. `PreToolUse` deny in `forgeward-gate-check.sh` — denies a scanner command whose output
   flag targets a drive-letter path, with a reason that teaches the stdout form.
   **Verified to reach subagents** (2026-08-01): the open question was whether the harness
   routes a *subagent's* Bash calls through `PreToolUse` at all. Probed directly — a
   throwaway repo with no marker, and a harmless `echo` whose text contains `git push`.
   The main agent's call was denied; the identical call issued from inside a subagent was
   denied too, with the same reason text delivered as a tool error the agent can read, and
   the hook resolved the branch from the `cd` target inside the compound command rather
   than the session cwd. So layer 2 does cover the reviewers.
   **The real dependency is deployment, not routing:** hooks run from the INSTALLED plugin
   cache (`~/.claude/plugins/cache/forgeward-gate/forgeward/<version>/`), not from a
   working tree. Layer 2 protects nothing until this version is actually installed — which
   is exactly how the first probe of this guard came back "not denied" while the code sat
   green in the branch. Layers 1, 3 and 4 need no install to work.
3. `scripts/forgeward-artifact-dir.sh` — hands out a path that is absolute *in this
   shell* (translating a Windows `TMPDIR` via `cygpath`) and outside the repo.
4. `scripts/forgeward-workspace-guard.sh` — the gate snapshots the tree before spawning
   reviewers and diffs it after; contamination halts the handoff to `/ship`, since /ship
   stages and commits. It reports and never deletes: untracked files are the user's.

**Non-goals, stated so the absence of a limit is not read as coverage.** The hook fires
only on drive-letter paths, so a deliberate `semgrep -o report.json`, an `-o /tmp/x.json`,
and `docker run -v C:/repo:/scan …` all stay allowed. Layers 1–2 read command *text*, so
an unlisted scanner, an unusual output flag, or a path built inside a shell variable pass
them; layer 4 sees the result regardless of cause. Layer 4 in turn cannot see a write to
an already-gitignored path, a write outside the repo, or which reviewer did it. The hook
also **over**-denies: a command that merely quotes the defective shape (grepping these
very docs) is refused. That fails safe and is recoverable, and it is written into the
script rather than papered over.

**Caught by the gate reviewing itself.** The first version of layers 1–2 anchored the
drive-letter pattern to the *start* of an argv token, so the cuddled short-flag form
`-oC:/Users/…` — one token, a standard getopt convention — evaded **both**, which
directly contradicted the comment claiming "layers 2 and 3 are the net" for a flag layer
1 misses. `looks_like_path()` was inverted for the same reason: it refused only values
containing a slash or a known extension, so a bare `-o myreport` created `./myreport` in
the repo. Both are now deny-by-default — a drive-letter path is refused anywhere in a
token, and an output flag's value is treated as a destination unless it is a recognized
format word (`json`, `sarif`, `table`, …), so `-o json` still works. Regression tests
P2b, P8b–P8d. A test that cleaned up with a bare `rm -rf 'C:'` was corrected to the
`./`-prefixed form for the drive-root reason above — the suite must not depend on `mkdir`
and `rm` translating a drive-letter argument identically.

**Then the FIXES were re-reviewed, and both had over-refused.** Worth recording, because
the failure mode is the interesting one: each correction overshot in the same direction.
(1) Closing the cuddled-flag hole with a fully unanchored `*[A-Za-z]:[\/]*` also matched
any token with a letter before `:/` — `--config https://semgrep.dev/p/ci` and syft/grype
source specifiers `dir:/repo`, `oci-dir:/img`. Legitimate scanner arguments, refused. The
match is now anchored to a real path boundary (token start, after `/`, after `=`) with a
separate flag-cuddled pattern. (2) `_FORMAT_WORDS` wraps across three source lines, so
the wrap points are literal newlines; a `*" $1 "*` test against the raw string silently
dropped `yml`, `cyclonedx`, `compact` and `full`, treating them as destination paths.
Normalized before matching. Neither was exploitable — both fail closed — but friction in
a guard is not free: it is what pushes a reviewer to bypass the wrapper, which costs more
than the shape being caught. Regression tests P8e, P8f.

**Third pass returned FAIL, and it was right.** Every check accepted `=` as the
flag/value separator and nothing else, so `--output:C:/x` — the MSBuild/dotnet/PowerShell
convention — matched none of them and passed through untouched. That is worse than an
unlisted flag (a stated non-goal): it is an *enumerated* flag reached through a side
door, so the guarantee was defeated rather than merely incomplete, and layer 3 would only
have reported the write after it landed. `:` is now accepted everywhere `=` is, in all
three checks. Verified it does not repeat the overshoot: a colon-joined URL and a
registry ref with a port and tag (`localhost:5000/img:latest`) both stay allowed.
Regression test P8g, both directions.

**Fourth pass returned FAIL on a demonstrated arbitrary file write.** `looks_like_path()`
short-circuited on `-*` — "that token starts with a dash, so it is another flag, not this
flag's value." That is simply false for getopt-family parsers: pflag/Cobra, which
**gitleaks and trivy use**, consume the next token as the value unconditionally. Verified
end to end against the real binary: `forgeward-scan.sh gitleaks dir . --report-path
-evil.json` was passed through with no objection, and gitleaks wrote `-evil.json` into the
repo under review — the exact class this wrapper exists to close, through one of the four
scanners it names. The exception is now narrowed to a bare `-` (stdout, the one dash-led
value that is not a file); everything else dash-led is checked. Cost: a malformed
`--output --json` is refused rather than ignored, which fails closed on a command that
was already broken. Regression tests P8h (shapes, plus a `--` decoy and the bare-`-`
allow) and P8i (the same invocation against real gitleaks, asserting the repo stays
clean).

**Fifth pass returned FAIL: the format allowlist was tool-agnostic and should never have
been.** grype and syft OVERLOAD `-o` — `-o json` prints to stdout, `-o json=file` writes.
trivy does not: its own help reads `-o, --output string   output file name`, with
`-f/--format` separate, so `trivy -f json -o json .` writes a file literally named
`json`. semgrep and gitleaks match trivy. So the allowlist turned every format word into
a writable filename for **three of the four scanners this wrapper names** — and P8b
asserted that as correct, which is the worse half: a test was pinning the bug in place.
The exception is now keyed on the tool (`grype`, `syft` only); everywhere else an output
flag's value is a destination, full stop. Regression tests assert both directions per
tool, and that grype's own write form `-o json=out.json` is still refused.

**Sixth pass PASSED, with one Medium accepted as a documented limit.** The per-tool `-o`
exemption trusts `basename "$tool"`, so an executable *named* `grype` that is not grype
inherits it and could write a file named after one of the ~30 format words. Not closed,
deliberately: this script runs `"$tool" "$@"`, so anyone able to place that executable
already has code execution here — the write is strictly weaker than what they already
hold — and probing `--version` would not close it either, since a spoofed binary can
print anything. Written into the script header as a blind spot rather than left implied.
The half of that finding that *was* worth acting on: contamination used to exit with the
tool's own code, so a scanner that found nothing (exit 0) left the repo written-to and
still read as success. A tool exiting 0 after leaving new untracked paths now yields
exit 3; a non-zero tool exit is preserved, since the caller already knows.

**The pattern across all five failing passes is the durable finding.** Every correction to this
guard erred along the SAME axis — which token shapes count as a flag/value boundary —
first anchoring too tightly, then too loosely, then handling one separator, then trusting
a leading dash. None of it surfaced from reading the code; each took an adversarial pass
with a concrete PoC, and the last one needed a real scanner binary rather than an
argument about string shapes. Two conclusions worth keeping: a guard whose correctness is
a claim about token shapes needs its counterexamples **enumerated in tests**, not argued
in comments; and layer 1 should be understood as removing an affordance, not as a
boundary — the reason layers 3 and 4 exist is that this kind of enumeration is never
finished.

**Coverage.** `test/gate-test.sh` P1–P12: the deny fires on both slash conventions, and
does **not** fire on relative `-o`, POSIX-absolute `-o`, or a drive path in a non-scanner
command; the wrapper refuses flags and drive paths and passes stdout through; the artifact
dir is POSIX-absolute, exists, and is outside the repo; the workspace guard flags a
staged `C:` tree and stays quiet on a clean one; and a live control asks the platform
whether an unguarded drive-letter write actually lands in the repo before asserting either
way — a POSIX-only assertion would pass while the bug remained, because the bug *is* the
path translation.

## DECISION — page posture is per route group, not per site; three postures became five plus `unknown`

**Date:** 2026-07-23

**Problem.** The seo-reviewer treated "public" and "indexable" as the same thing. A site
deliberately serving `User-agent: * / Disallow: /` while carrying Open Graph tags — so a
link renders a card in chat but never appears in search — was reported as Critical/High
("a public page that can't be indexed") and hard-failed the gate. That is a legitimate,
common design: share links, unlisted deliverables, client previews, invite-only pages.
No waiver mechanism existed, and `skills/gate/SKILL.md` correctly forbids the orchestrator
from rationalizing a FAIL into a pass, so the only escape was `git push --no-verify`,
which skips **every** axis to silence one.

**Why not a waiver.** A whitelist suppresses a finding; it does not teach the reviewer what
it is looking at. The reviewer would keep being wrong and the user would keep annotating
around it. Posture is the right primitive: declare (or detect) what the page IS, and the
ruleset follows. An expiring, committed waiver file remains a reasonable last resort for
genuine one-offs, but it is not the fix for this class.

**Decision.** The reviewer classifies posture **per route group** and switches ruleset:
`public-indexed`, `private-shareable`, `private-closed`, `staging-preview`,
`authenticated-shareable`, and `unknown`. Per-route matters more than the taxonomy itself —
the single most common real shape is indexed marketing pages plus an authenticated app on
one origin, and a site-wide verdict necessarily gets one of them wrong. `unknown` reports
only what holds under every candidate posture rather than guessing; a wrong posture yields
confident findings about the wrong thing, which is worse than an acknowledged gap.

Under `private-shareable` the checklist inverts: indexability findings are the intent and
must not appear at any severity (reporting them as Low still trains the reader to ignore
the reviewer), while a broken link preview becomes High — missing or partial OG tags,
client-rendered OG tags that preview bots never execute, a relative `og:image`, or a
blanket disallow with no per-agent allowlist group.

**Privacy consequence.** These sites have no authorization boundary — the URL *is* the
credential — and every rule in the privacy-reviewer presupposed one ("visible to users who
shouldn't see it" assumes accounts). Added an unauthenticated-PII-surface section, led by
two rules: bulk PII crossing to the client for a lookup UI (a search feature must match
server-side and return only the matching record), and two paths to one data store with
different auth postures, where the credentialed path creates false confidence about the
whole feature. The gate now fires the privacy-reviewer on `private-shareable` groups even
when the diff looks like markup or config, since on such a group any new route or
client-reachable data source is a personal-data change.

**Also recorded as a limit.** `skills/gate/SKILL.md` now requires the gate to state what the
diff cannot see — externally-resolved engines, submodules, gitignored paths that committed
tooling references — because a PASS on a thin customization layer must never read as a PASS
on the system. The privacy-reviewer carries a matching blind-spot list. An unstated limit is
indistinguishable from a claim of coverage.

**Deliberately excluded.** A `paywalled`/metered posture (its own specialist rulebook;
half-implementing it is worse than not claiming it) and an "indexed but no OG tags" posture
(on an indexed site missing OG is a defect, already Medium/Low — absence of OG only reads as
intent when the site has also opted out of search). Postures are capped deliberately: each
one added is another chance to misclassify.

## RESOLVED — gate false-blocks a push from a git worktree; enforcement moved to pre-push

**Date:** 2026-07-15 (resolved 2026-07-16)

**Symptom.** Work isolated in a linked `git worktree` passes `/forgeward:gate` (all
reviewers PASS, marker written), but the subsequent `git push` / `gh pr create` is denied
anyway: *"forgeward gate not passed for HEAD …"*. The branch is committed and genuinely
gated, yet the publish stays blocked. Re-running the gate does not help. Manifests only when
the Claude Code session's cwd is a **different checkout of the same repo** (typically the
main checkout) than the worktree holding the gated branch.

**Cause.** Both halves keyed the marker off `git rev-parse --git-dir`, and the check half
also recomputed the substantive-diff hash against **its own cwd's HEAD**:
- `forgeward-write-marker.sh` ran inside the worktree → `--git-dir` = the per-worktree git
  dir → marker written *there*, pinned to the worktree HEAD.
- `forgeward-gate-check.sh` (PreToolUse) `cd`s to the hook event's `.cwd` = the **session**
  cwd (the main checkout), so `--git-dir` = the main `.git`. It looked for the marker in the
  wrong git dir AND, via `is_fresh` → `forgeward-diff-hash.sh`, recomputed `base...HEAD`
  against the main checkout's HEAD (= `origin/main` → empty diff). Two independent
  fail-closed misses. It is a cwd/worktree mismatch, not a real gate failure — and the
  auto-mode classifier correctly refuses to let an agent route around a green-looking gate,
  so the push wedges.

**Fix — part 1: the marker is worktree-safe.** Two coordinated changes, needed by every
enforcement layer:
1. `forgeward-diff-hash.sh <base> [tip]` takes an explicit tip (defaults to `HEAD`, so
   existing single-checkout behavior is byte-for-byte unchanged), so freshness can be checked
   against a specific ref/SHA rather than whatever the caller has checked out.
2. `forgeward-write-marker.sh` stores the marker **branch-keyed under the common git dir**
   (`git rev-parse --git-common-dir`), shared across all linked worktrees, so a marker written
   from a worktree is found from any checkout of the repo. Keying by branch keeps concurrent
   worktrees on different branches from clobbering one another.

**Fix — part 2: enforcement moved OFF the PreToolUse hook and onto a git `pre-push` hook.**
The first attempt made the PreToolUse hook parse the push command to learn which ref it would
send. **Four** pre-merge security reviews each found the parser failing OPEN, and the pattern
was terminal: to know what a shell command pushes you must reimplement the shell's lexer, and
each round exposed another layer — word-splitting and `git -C` (R3), quote/backslash removal
`"git" push` (R4), then variable expansion. Closing expansion would require denying every
`git … $var`, which breaks ordinary git use. **Conclusion: a PreToolUse hook reads command
TEXT and cannot be both bypass-proof and usable.** (Most of these bypasses — `git -C`,
`git  push` — also exist in the pre-0.3.0 gate; this is architectural, not a regression.) So:

- **`forgeward-gate-check.sh` reverted to a simple best-effort REMINDER**: on a publish
  command, honor a leading `cd` and check the current checkout's branch marker; deny with a
  message that says the enforced check is pre-push. It is fast UX, explicitly NOT the lock.
- **`forgeward-pre-push.sh` is the enforcement.** A git pre-push hook runs INSIDE the push:
  git hands it the exact `<local-ref> <local-sha> <remote-ref> <remote-sha>` lines on stdin,
  after the shell has already resolved `git -C`, quoting, `$vars`, `xargs`, aliases — there is
  no text left to trick. It blocks the push if ANY branch ref being pushed lacks a fresh marker.
  It keys off the ref being UPDATED on the remote (`remote_ref`) and verifies the pushed COMMIT
  (`local_sha`, matched against any local branch's marker) — so `git push origin <sha>:refs/heads/x`
  or `HEAD:refs/heads/x`, where the local side isn't a `refs/heads/*` name, can't skip the check
  (a fail-open the final review caught before merge).
- **`forgeward-install-pre-push.sh`** installs it into the repo's EFFECTIVE hooks dir
  (honoring `core.hooksPath` — a global one is common and made per-repo `.git/hooks` installs
  dead) and sets a per-repo opt-in (`git config forgeward.gate enabled`). The enforcer no-ops
  unless that opt-in is present, so a hook living in a shared/global dir never blocks unrelated
  repos.

**Honest residual (this is strong, not indestructible).** `git push --no-verify` skips the
hook; the marker is a local file that can be forged; git hooks are not cloned (re-install in a
fresh clone, and after a plugin update, since the enforcer path is baked into the hook). Any
purely-local gate has these limits. For an **unbypassable** boundary, gate the MERGE
server-side — GitHub required checks + branch protection via `/forgeward:ci-gate` (which
already does this for the deterministic scanners). This hook stops the common/accidental
ungated push, robustly, on the developer's machine.

**Coverage.**
- `test/gate-test.sh` — the PreToolUse reminder: no-marker deny, non-publish untouched, PASS
  allow, version-bump-invariance, dependency-sensitivity, stale deny, fail-open outside a repo,
  the `/ship` expansion halt, and worktree honor-cd (a `cd <worktree> && git push`, gated →
  allow, ungated → deny, single-quoted spaced path → allow), plus base-detection and the
  manifest-hooks guard.
- `test/pre-push-test.sh` — the enforcer, driven exactly as git drives it (refs on stdin):
  gated allow; ungated block (names the ref); multi-ref one-ungated block / all-gated allow;
  branch deletion allow; post-marker commit stale block; version-only bump allow; tag (non-
  branch) allow; **a marker written inside a linked worktree honored from the main checkout**
  (the original bug, now handled with no cd and no parsing); and the opt-in no-op (a repo
  without `forgeward.gate` is not blocked — safe as a global hook).
- End-to-end (manual harness): real pushes through the installed hook against a bare remote
  confirm `git -C`, `git  push`, `"git" push`, and `g\it push` are all BLOCKED while ungated;
  `--no-verify` bypasses; and a gated ref pushes.

## DECISION — add a security reviewer + CI enforcement (reversed "delegate security to /cso")

**Date:** 2026-07-13

**Prior decision.** forgeward deliberately shipped no general security reviewer, delegating the
OWASP/STRIDE/CVE axis to gstack's `/cso`, and the README documented "no SAST, no CI merge-gating —
handle those in your project's CI." The rationale was avoiding duplication of `/cso`.

**What broke it.** On a real PR (a wp-admin SQL runner executing committed `.sql` against a live
DB), the gate fired only privacy + accessibility and returned PASS. `/cso` is opt-in and manual;
it wasn't run. A commercial SAST scanner (Wiz) independently flagged **1 critical + 13 high** on
the same diff — including a SQL-injection-class finding. The delegation assumed `/cso` would be
run; in the real workflow it wasn't, so the security axis was simply absent at the moment of ship.

**Decision.** (1) Add `security-reviewer` as a sixth gate reviewer — diff-scoped, read-only, runs
a bundled framework-aware SAST rulepack (`rules/wp-security.yml`) plus injection/authz reasoning,
returns `SECURITY VERDICT: PASS|FAIL`. (2) Add `/forgeward:ci-gate` (absorbing the former
`readiness` skill) to wire real scanners (Semgrep, PHPCS/WPCS, Trivy, Gitleaks) into CI and
optionally make them required checks via branch protection. `/cso` remains the deep whole-repo
audit; the reviewer does not replace it — it stops the gate greenlighting injection.

**Scope note.** `security-reviewer` is diff-scoped and one reviewer won't match a commercial SAST
engine's recall — the `ci-gate` CI scanners are the unskippable floor; the reviewer is fast local
feedback. Verified: the bundled rulepack flags 8 dynamic-SQL sinks on the PR above (6 unprepared
`$wpdb` queries + a value interpolated into a `prepare()` format string) and stays silent on
correctly-prepared and literal queries.

## RESOLVED — base detection on a direct-to-base commit (origin/<base> fallback)

**Date:** 2026-06-22

**Symptom.** A commit made directly on the base branch (e.g. a docs edit straight to
`master`, no feature branch) could not be gated. `scripts/forgeward-detect-base.sh`
resolved to the bare base branch, so the gate's diff scope `base...HEAD` was **empty**
— local `master` equals `HEAD`, so the three-dot diff has nothing in it. The
`/forgeward:gate` skill then hit its "you're on the base branch, nothing to gate" stop,
while the `PreToolUse` push hook still (correctly) blocked the push for lack of a PASS
marker. Net result: a deadlock — a real unpushed change about to publish, but no
non-empty surface to review, so no honest marker could be written.

**Repro.** On `master`, commit a change directly. `origin/master` is now behind `HEAD`
by that commit. `git diff master...HEAD` is empty; the push hook blocks; the gate reads
"nothing to gate." First observed live while shipping the README "Security scope" note
(worked around at the time by manually scoping the marker to `origin/master`).

**Fix (SUPERSEDED 2026-07-31 — see the stale-local-branch entry at the top).** Step 4 in
`scripts/forgeward-detect-base.sh`: when `HEAD` is ON the resolved base branch AND
`origin/<base>` exists AND differs from `HEAD`, return `origin/<base>` (the publish
boundary). The diff then scopes to the real unpushed change. Guarded two ways: a base
branch in sync with its remote keeps the bare base (genuinely nothing to gate), and a
feature branch (`HEAD != base`) skips step 4 entirely, so that resolution is
byte-for-byte unchanged.

**Why it was superseded — the lesson, not just the code.** The fix was right about the
*case* and wrong about the *rule*: it special-cased "HEAD is on the base branch" instead
of recognizing that the base should ALWAYS be the publish boundary. The guard that kept
it narrow ("a feature branch skips step 4 entirely, so that resolution is byte-for-byte
unchanged") is exactly what preserved the bug on every feature branch — which is the
common path. Step 4 is now deleted; stage B resolves the remote-tracking ref for every
branch, and this case falls out of it with no special-casing.

**Coverage.** `test/gate-test.sh` B4 (assertions 22–23): a direct-to-base commit with
`origin/main` behind → detect returns `origin/main`, and the test proves meaningfulness
(the new base scopes the real changed file; the old bare-`main` diff is empty). The three
prior base-detection tests (origin/HEAD unset, origin/HEAD set, master-only fallback)
still pass unchanged.

## RESOLVED — duplicate hooks load (manifest re-referenced the auto-loaded hooks.json)

**Date:** 2026-06-22

**Symptom.** Plugin load failed on reload/reinstall: *"Hook load failed: Duplicate hooks
file detected: ./hooks/hooks.json resolves to already-loaded file …/hooks/hooks.json. The
standard hooks/hooks.json is loaded automatically, so manifest.hooks should only reference
additional hook files."* With hooks failing to load, the enforcement gate is effectively
DOWN — pushes/PRs are no longer intercepted.

**Cause.** `.claude-plugin/plugin.json` set `"hooks": "./hooks/hooks.json"`. Claude Code
auto-loads the standard `hooks/hooks.json` by convention; the explicit manifest reference
then loads the same file a second time. (Not introduced by a code change — it surfaced when
the plugin reload began enforcing the auto-load convention.)

**Fix.** Remove the `"hooks"` key from `plugin.json`. The standard `hooks/hooks.json` still
loads automatically; `manifest.hooks` is reserved for ADDITIONAL hook files, of which this
plugin has none.

**Coverage.** `test/gate-test.sh` M1 (assertion 24): static guard that `plugin.json`'s
`hooks` value does not point at the auto-loaded `hooks.json` — a re-add fails the suite.
