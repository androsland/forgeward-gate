#!/usr/bin/env bash
# forgeward-workspace-guard.sh snapshot <HEAD_SHA> | check <snapshot-file>
#
# Prove the read-only contract instead of asserting it. The gate advertises that its
# reviewers never write to the repo they audit ("a model that fixes what it judges
# produces biased reviews"), and that claim was false: security-reviewer twice
# created a `C:` directory tree at the repo root by handing a scanner a Windows path
# from a POSIX shell. Untracked, matched by no common .gitignore — one `git add -A`
# and the reviewer's scratch tree is in the user's history.
#
#   snapshot <HEAD_SHA>  -> print a v2 manifest of the workspace on stdout. <HEAD_SHA> is
#                           the commit Step 0 froze: a full commit id that resolves to
#                           itself, or exit 64. If the live HEAD is not that commit, exit 2.
#   check <snapshot>     -> rebuild the manifest and compare the two in both directions.
#
# Exit codes, distinct on purpose: 0 unchanged; 1 changed (one line per difference, on
# stderr); 2 COULD NOT CHECK (no repository, a missing, unreadable, foreign or truncated
# snapshot, HEAD moved before `snapshot`, or git failing) — never read 2 as clean; 64 usage.
#
# Take the snapshot BEFORE launching reviewers and check AFTER every one is accounted
# for. Write the snapshot OUTSIDE the repo (the gate's run directory, from
# forgeward-artifact-dir.sh): a guard that contaminates the tree it is guarding is not
# a guard.
#
# WHY THIS IS THE BACKSTOP AND NOT THE FIX. forgeward-scan.sh refuses the known bad
# invocation and the PreToolUse hook denies the known bad command shape; both work
# from the command TEXT, so both are enumerations. This one works from the
# filesystem, so it sees any contamination regardless of which tool, flag, or path
# produced it.
#
# WHAT IT RECORDS. This list is the only maintained copy (design §5.1):
#   - HEAD: the commit, and the branch it is on or `detached`;
#   - the index: a hash of `git ls-files -s -v -z`, which carries the skip-worktree and
#     assume-unchanged tags and no stat data;
#   - refs/stash, resolved through git;
#   - every entry `git status` reports, by kind, decided before anything is opened: a
#     regular file by content; a symlink by its target text, never followed; `absent`;
#     `special` (FIFO, socket, device), never opened; a submodule or nested repository
#     by its checked-out commit, `no-commit` or `unreadable`; `dir`; `unreadable`;
#   - core.hooksPath and every file in the effective hooks directory (gstack's wrapper
#     owns `pre-push`; forgeward's enforcer is `pre-push.local` beside it);
#   - forgeward.gate, the switch the pre-push hook reads;
#   - this commit's run file, and the marker of every name `--revoke` withdraws for it.
#
# WHAT IT STRUCTURALLY CANNOT SEE (design §5.4):
#   - a write to a gitignored path, or an ignore rule added outside the tree
#     (.git/info/exclude, core.excludesFile) that hides later writes;
#   - a write OUTSIDE this repo, the run directory holding the snapshot included;
#   - a symlink's target; inside a submodule or nested repository, anything but its
#     checked-out commit; the content of `special` and `unreadable` entries, which
#     `snapshot` names on stderr every run;
#   - writes under .git/ other than those listed above: other refs, other config keys,
#     other commits' markers and run files;
#   - a change undone before `check`, or a write racing `snapshot`: two endpoints are
#     compared, and this is not a write audit;
#   - a mode or timestamp change with identical content;
#   - who made a change. A reviewer and someone working in this checkout look the same,
#     which is exactly why it only ever REPORTS — deleting untracked files is
#     destructive and is the user's decision, not this script's.
#
# BUILT FROM git, bash 3.2, sort and awk, plus plain readlink; nothing else, and no
# GNU-only flag. A gate-test.sh assertion runs it with PATH holding only those.
set -uo pipefail

# Locale-pinned repo-wide, not per-effect — see CLAUDE.md. A non-interactive script
# must not have its behaviour depend on the invoker's environment: character classes,
# collation and grep's handling of invalid UTF-8 all move with the locale, and the
# last one was a complete bypass of an ambiguity guard before it was pinned.
export LC_ALL=C

usage() {
  printf 'usage: forgeward-workspace-guard.sh snapshot <HEAD_SHA> | check <snapshot-file>\n' >&2
  exit 64
}
# cannot <why>: exit 2, "could not check". The caller must never read it as clean.
cannot() {
  printf 'forgeward-workspace-guard: %s, so the workspace cannot be checked.\n' "$1" >&2
  exit 2
}

# enc <s>: set ENC to <s> with backslash, double quote, LF, CR and TAB backslash-escaped.
# A record is one line of three tab-separated fields, so an encoded path can neither
# forge nor hide one. The same text in double quotes is a C-quoted line that
# `git hash-object --stdin-paths` reads back as the exact path. Raw, that option strips a
# trailing CR and unquotes a line starting with `"`, and so hashes a DIFFERENT file with
# status 0 (measured, git 2.34.1). Sets a global instead of printing, so a path costs no
# fork.
enc() {
  local s="$1" out="" c i=0
  case "$s" in
    *\\*|*\"*|*$'\n'*|*$'\r'*|*$'\t'*) ;;
    *) ENC="$s"; return 0 ;;
  esac
  while [ "$i" -lt "${#s}" ]; do
    c="${s:$i:1}"
    case "$c" in
      \\) out="$out\\\\" ;;
      \") out="$out\\\"" ;;
      $'\n') out="$out\\n" ;;
      $'\r') out="$out\\r" ;;
      $'\t') out="$out\\t" ;;
      *) out="$out$c" ;;
    esac
    i=$((i+1))
  done
  ENC="$out"
}

# The regular files waiting to be hashed: QP[i] is the C-quoted path, QR[i] the record
# prefix its hash completes. flush_files hashes the whole queue in ONE git process.
NQ=0
queue_file() { QR[NQ]="$1"; QP[NQ]="\"$2\""; NQ=$((NQ+1)); } # queue_file <prefix> <encoded path>
flush_files() {
  local hashes h i=0
  [ "$NQ" -gt 0 ] || return 0
  hashes="$(while [ "$i" -lt "$NQ" ]; do printf '%s\n' "${QP[i]}"; i=$((i+1)); done \
            | git hash-object --no-filters --stdin-paths)" || return 1
  i=0
  while IFS= read -r h; do
    [ "$i" -lt "$NQ" ] || return 1
    printf '%sfile:%s\n' "${QR[i]}" "$h"
    i=$((i+1))
  done <<EOF
$hashes
EOF
  [ "$i" -eq "$NQ" ] || return 1
  NQ=0
}

# classify <path>: KIND=file when the path is a readable regular file the caller queues;
# otherwise KIND=val and VAL holds the record value. The kind is decided with [ -L ],
# [ -e ], [ -d ] and [ -f ] before anything is opened, so a FIFO is never read and a
# symlink is never followed. Returns 1 only when git or readlink fails.
classify() {
  local p="$1" want sub
  KIND='val'
  if [ -L "$p" ]; then
    # The target text exactly, without readlink's newline: the blob git stores for a link.
    VAL="link:$(readlink -- "$p" | awk 'NR > 1 { printf "\n" } { printf "%s", $0 }' \
                | git hash-object --stdin)" || return 1
  elif [ ! -e "$p" ]; then
    VAL=absent
  elif [ -d "$p" ]; then
    if [ -e "$p/.git" ]; then
      case "$p" in /*) want="$p" ;; *) want="$TOP/$p" ;; esac
      if sub="$(git -C "$p" rev-parse --show-toplevel 2>/dev/null)" && [ "$sub" = "$want" ]; then
        VAL="repo:$(git -C "$p" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || printf no-commit)"
      else
        VAL=repo:unreadable
      fi
    else
      VAL=dir
    fi
  elif [ -f "$p" ]; then
    if [ -r "$p" ]; then KIND='file'; else VAL=unreadable; fi
  else
    VAL=special
  fi
}

# entry <type> <encoded key> <path>: one record for a file outside the status set.
entry() {
  classify "$3" || return 1
  if [ "$KIND" = file ]; then
    enc "$3"; queue_file "$1"$'\t'"$2"$'\t' "$ENC"
  else
    printf '%s\t%s\t%s\n' "$1" "$2" "$VAL"
  fi
}

# revoke_names <commit>: every name a marker for <commit> can be under, one per line,
# sorted, each once. That is every local branch at <commit>, by the push hook's own
# `for-each-ref --points-at` expression, under both spellings: the short name (what the
# hook enumerates and the writer keys on) and the canonical name minus refs/heads/ (what
# the hook's destination-name lookup uses). One call emits both as consecutive lines, and
# ref names cannot hold a newline, so the pairs cannot drift. Plus the current branch
# under both spellings, ONLY when HEAD is at <commit>: a branch at another commit belongs
# to another run. On a detached HEAD there it is the literal `HEAD` key the writer uses;
# an unborn HEAD has no commit. Returns 1 when the branch listing fails, after printing
# the names it could still find.
# BYTE-IDENTICAL in forgeward-write-marker.sh (which withdraws these markers) and
# forgeward-workspace-guard.sh (which records them). gate-test.sh pins the bytes, and also
# derives one list from the other, because the writer runs under `set -e` and the guard
# does not, so identical text is not proof of identical behaviour.
revoke_names() {
  local c="$1" listing="" names="" short full here cur canonical rc=0
  if listing="$(git for-each-ref --format='%(refname:short)%0a%(refname)' --points-at "$c" refs/heads/ 2>/dev/null)"; then
    while IFS= read -r short && IFS= read -r full; do
      names="$names$short"$'\n'"${full#refs/heads/}"$'\n'
    done <<EOF
$listing
EOF
  else
    rc=1
  fi
  here="$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" || here=""
  if [ -n "$here" ] && [ "$here" = "$c" ]; then
    cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" \
      || cur="$(git symbolic-ref --short -q HEAD 2>/dev/null)" || cur=""
    names="$names$cur"$'\n'
    canonical="$(git symbolic-ref -q HEAD 2>/dev/null)" || canonical=""
    case "$canonical" in refs/heads/?*) names="$names${canonical#refs/heads/}"$'\n' ;; esac
  fi
  printf '%s' "$names" | sort -u || rc=1
  return "$rc"
}

# state_records <HEAD_SHA> <common-dir>: HEAD, the index, the stash, the hooks, the
# switch, this commit's run file, and the markers revoke withdraws for it.
state_records() {
  local sha="$1" common="$2" c b v rc hooks f names n
  NQ=0
  c="$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" || c=none
  b="$(git symbolic-ref -q HEAD 2>/dev/null)"; rc=$?
  case "$rc" in 0) ;; 1) b=detached ;; *) return 1 ;; esac
  enc "$b"; printf 'head\t-\t%s %s\n' "$c" "$ENC"
  v="$(git ls-files -s -v -z | git hash-object --stdin)" || return 1
  printf 'index\t-\t%s\n' "$v"
  v="$(git rev-parse --verify --quiet refs/stash 2>/dev/null)" || v=absent
  printf 'stash\t-\t%s\n' "$v"
  v="$(git config --get core.hooksPath)"; rc=$?
  case "$rc" in 0) enc "$v"; v="$ENC" ;; 1) v='unset' ;; *) return 1 ;; esac
  printf 'hookspath\t-\t%s\n' "$v"
  v="$(git config --get forgeward.gate)"; rc=$?
  case "$rc" in 0) enc "$v"; v="$ENC" ;; 1) v=absent ;; *) return 1 ;; esac
  printf 'switch\t-\t%s\n' "$v"
  hooks="$(git rev-parse --git-path hooks)" || return 1
  for f in "$hooks"/* "$hooks"/.[!.]* "$hooks"/..?*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    enc "${f##*/}"; entry hook "$ENC" "$f" || return 1
  done
  f="$common/forgeward-gate-runs/$sha"
  if [ -e "$f" ] || [ -L "$f" ]; then entry runfile - "$f" || return 1
  else printf 'runfile\t-\tabsent\n'; fi
  names="$(revoke_names "$sha")" || return 1
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    f="$common/forgeward-gate-markers/$n.json"
    [ -e "$f" ] || [ -L "$f" ] || continue
    enc "$n"; entry marker "$ENC" "$f" || return 1
  done <<EOF
$names
EOF
  flush_files
}

# path_records: read `git status --porcelain -z` entries on stdin and print one record
# per entry: path <TAB> <encoded path> <TAB> <XY> <value>. NUL-delimited input is read
# with `read -d ''` and never captured into a variable, which would drop the NULs.
path_records() {
  local rec xy p
  NQ=0
  while IFS= read -r -d '' rec; do
    xy="${rec:0:2}"; p="${rec:3}"
    enc "$p"
    classify "${p%/}" || return 1
    if [ "$KIND" = file ]; then
      queue_file "path"$'\t'"$ENC"$'\t'"$xy " "$ENC"
    else
      printf 'path\t%s\t%s %s\n' "$ENC" "$xy" "$VAL"
    fi
  done
  flush_files
}

# manifest <HEAD_SHA>: print the whole v2 manifest, or nothing and status 1. It RETURNS,
# never exits: every caller runs it inside a command substitution and checks the status
# there (CLAUDE.md, the swallowed-exit bullet).
manifest() {
  local recs common n=0
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in /*|[A-Za-z]:/*) ;; *) common="$TOP/$common" ;; esac
  # --no-optional-locks: without it `git status` refreshes and REWRITES the index.
  recs="$( { state_records "$1" "$common" \
             && git --no-optional-locks status --porcelain -z --no-renames \
                  --untracked-files=all --ignore-submodules=none | path_records
           } | sort)" || return 1
  while IFS= read -r _; do n=$((n+1)); done <<EOF
$recs
EOF
  printf 'forgeward-workspace-guard v2 %s\n%s\nend %d\n' "$1" "$recs" "$n"
}

# The comparison. Both manifests are keyed by type and key; every difference is one line.
# shellcheck disable=SC2016  # an awk program, not a shell expansion
COMPARE='
function who() { return " — by a reviewer, or someone working in this checkout" }
function bare(v) { sub(/:.*/, "", v); return v }
function report(t, k, o, n) {
  if (t == "path") {
    if (o == "" && substr(n, 1, 2) == "??") { print "  new path: " k who(); newp = 1 }
    else if (o == "") print "  changed: " k " (was clean, now \047" substr(n, 1, 2) "\047)" who()
    else if (n == "") print "  left the dirty set: " k " (a commit, checkout, stash, reset or delete took it)" who()
    else if (bare(o) == bare(n)) { print "  changed content: " k who(); dirty = 1 }
    else { print "  changed: " k " (was " bare(o) ", now " bare(n) ")" who(); dirty = 1 }
  }
  else if (t == "head") print "  HEAD moved or switched branch (was " o ", now " n ")" who()
  else if (t == "index") print "  the index changed (git add, git rm, or a skip-worktree or assume-unchanged flag)" who()
  else if (t == "stash") print "  the stash changed" who()
  else if (t == "hookspath") print "  core.hooksPath changed (was " o ", now " n ")" who()
  else if (t == "switch") print "  forgeward.gate changed (was " o ", now " n ")" who()
  else if (t == "hook") {
    if (o == "") print "  new hook file: " k who()
    else if (n == "") print "  hook file removed: " k who()
    else print "  hook file changed: " k who()
  }
  else if (t == "runfile") print "  this commit'"'"'s gate run file changed" who() ". The gate revokes next."
  else if (t == "marker") {
    if (o == "") print "  a PASS marker appeared for " k who() ". The gate revokes next."
    else if (n == "") print "  the PASS marker for " k " went away" who()
    else print "  the PASS marker for " k " changed" who() ". The gate revokes next."
  }
  else print "  " t " changed: " k who()
}
FNR == NR { if (FNR > 1 && $0 !~ /^end /) { key = $1 FS $2; old[key] = $3; order[++m] = key } next }
FNR == 1 || /^end / { next }
{ key = $1 FS $2
  if (key in old) { if (old[key] != $3) report($1, $2, old[key], $3); delete old[key] }
  else report($1, $2, "", $3) }
END {
  for (i = 1; i <= m; i++) if (order[i] in old) { split(order[i], p, FS); report(p[1], p[2], old[order[i]], "") }
  if (newp) print "Only you can confirm where a new path came from, so the gate deletes nothing. Remove one with a ./-prefixed path, for example rm -rf -- \"./C:\" (a bare C: is the drive root under Git Bash). Until then, git add -A would commit it."
  if (dirty) print "A file that already had uncommitted changes was edited: git diff shows what is there now, and the gate cannot restore the earlier content."
}'

# The snapshot's shape: a v2 header, records of three tab-separated fields, and an `end`
# line whose count matches. Prints `ok <HEAD_SHA>`, `header` or `end`.
# shellcheck disable=SC2016  # an awk program, not a shell expansion
VALIDATE='
NR == 1 { sha = $0
          if (sub(/^forgeward-workspace-guard v2 /, "", sha) != 1 || sha ~ /[^0-9a-f]/ \
              || (length(sha) != 40 && length(sha) != 64)) { bad = "header"; exit }
          next }
{ if (last != "" && split(last, f, "\t") != 3) { bad = "end"; exit }
  last = $0; n++ }
END { if (bad == "" && NR == 0) bad = "header"
      if (bad == "" && (last !~ /^end [0-9]+$/ || substr(last, 5) + 0 != n - 1)) bad = "end"
      print (bad == "" ? "ok " sha : bad) }'

mode="${1:-}"
case "$mode" in snapshot|check) ;; *) usage ;; esac
[ "$#" -eq 2 ] && [ -n "$2" ] || usage

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || TOP=""
[ -n "$TOP" ] || cannot 'this is not a git repository'
file="$2"
case "$file" in /*|[A-Za-z]:[\\/]*) ;; *) file="$PWD/$file" ;; esac
# Every collection runs from the worktree root: from a subdirectory `git status` still
# prints root-relative paths, while a relative [ -e ] would resolve against the subdirectory.
cd "$TOP" 2>/dev/null || cannot "the worktree root $TOP could not be entered"

case "$mode" in
  snapshot)
    sha="$2"
    case "${#sha}" in 40|64) ;; *) sha="" ;; esac
    case "$sha" in *[!0-9a-f]*) sha="" ;; esac
    if [ -z "$sha" ] || [ "$(git rev-parse --verify --quiet "$sha^{commit}" 2>/dev/null)" != "$sha" ]; then
      printf "forgeward-workspace-guard: '%s' is not a full commit id that resolves to itself; pass the <HEAD_SHA> Step 0 printed.\n" "$2" >&2
      exit 64
    fi
    live="$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" || live=""
    if [ "$live" != "$sha" ]; then
      printf 'forgeward-workspace-guard: HEAD moved since Step 0 (it is %s, not %s), so the workspace cannot be checked. Nothing was recorded.\n' \
        "${live:-unborn}" "$sha" >&2
      exit 2
    fi
    out="$(manifest "$sha")" || cannot 'git failed while the workspace was being recorded'
    printf '%s\n' "$out"
    printf '%s\n' "$out" | awk -F'\t' 'NR > 1 && NF == 3 && $3 ~ /(^| )(special|unreadable|repo:unreadable)$/ {
      printf "forgeward-workspace-guard: recorded without its content, so a change inside it is not seen: %s (%s)\n", $2, $3 }' >&2
    exit 0
    ;;
  check)
    [ -f "$file" ] && [ -r "$file" ] || cannot "the snapshot $2 is missing or unreadable"
    v="$(awk "$VALIDATE" "$file")" || cannot "the snapshot $2 could not be read"
    case "$v" in
      'ok '*) sha="${v#ok }" ;;
      header) cannot "$2 is not a v2 workspace snapshot (its header is wrong or missing)" ;;
      end) cannot "the snapshot $2 is truncated or corrupt (its end line is missing or its count is wrong)" ;;
      *) cannot "the snapshot $2 could not be read" ;;
    esac
    now="$(manifest "$sha")" || cannot 'git failed while the workspace was being recorded'
    diffs="$(printf '%s\n' "$now" | awk -F'\t' "$COMPARE" "$file" -)" \
      || cannot 'the two manifests could not be compared'
    [ -n "$diffs" ] || exit 0
    printf 'forgeward: the workspace changed while the reviewers ran:\n%s\n' "$diffs" >&2
    exit 1
    ;;
esac
