#!/usr/bin/env bash
# Regression suite for the bundled Semgrep rulepack in rules/env-config.yml.
#
# Framework-free, like the rest of test/: bash + semgrep + (jq or python3). Fixtures are
# generated into a scratch directory at run time and never written into the repo — the
# plugin's own artifact contract applies to its own tests, and a `.ts` fixture committed
# under test/ would also be scanned by forgeward's gate on every subsequent PR.
#
# WHAT THIS ASSERTS, in three classes:
#   1. POSITIVES — each shape the rule exists to catch fires. One per line, so a
#      regression names the shape it broke.
#   2. NEGATIVES — each legitimate configuration the rule must NOT fire on stays silent.
#      This is the half that matters for a rulepack third parties install: a rule that
#      fires on `process.env.X || 'default'` — the very fix it recommends — is worse than
#      no rule, because it teaches people to switch the pack off.
#   3. BLIND SPOTS — each limit documented in rules/env-config.yml is pinned as silent.
#      These are NOT desired behaviour; they are stated limits, and pinning them means a
#      future semgrep that closes one fails this suite and forces the doc to be corrected
#      rather than quietly becoming a lie. An unstated limit reads as a claim of coverage.
#
# STATED LIMITS OF THIS SUITE:
#   - With semgrep absent it SKIPS rather than fails, so a run that prints SKIP has
#     verified nothing. That matches the plugin's rule that a missing scanner never fails
#     a gate, and it is why the skip is printed loudly instead of folded into the pass count.
#   - It pins BEHAVIOUR, not the pack's internals. Mutation-tested at authoring time by
#     deleting single pattern lines from rules/env-config.yml: 5 of 6 deletions were
#     caught. The one that was not — dropping either anonymous function-scope exclusion —
#     is genuinely redundant under semgrep 1.169, which normalises function forms; that
#     redundancy is recorded in the pack rather than hidden by deleting a line the engine
#     might stop covering. No suite can pin a pattern that changes no result.
#   - Semgrep version drift is uncovered. These expectations were established against
#     1.169.0; a future engine could legitimately close one of the blind spots below, and
#     the correct response is to update the pack's stated limits, not to weaken the test.
#   - The extension sweep asserts the extensions semgrep DOES scan. It deliberately does
#     NOT assert that `.mts`/`.cts` stay unscanned, even though they are (measured, and
#     recorded in the pack header): pinning an engine gap as expected behaviour would turn
#     a future semgrep that fixes it into a red suite. So this suite will not tell you when
#     that hole closes — re-measure by hand on upgrade.
set -uo pipefail

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACK="$PLUGIN/rules/env-config.yml"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok %d - %s\n' "$((PASS+FAIL))" "$1"; }
nok() { FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$((PASS+FAIL))" "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; }

[ -f "$PACK" ] || { printf 'not ok 1 - rules/env-config.yml exists\n'; exit 1; }

if ! command -v semgrep >/dev/null 2>&1; then
  printf '1..0 # SKIP semgrep is not installed — the env-config rulepack was NOT verified.\n'
  printf '# Install it (pipx install semgrep) and re-run; this suite is the only thing\n'
  printf '# that checks the pack does not fire on the pattern it recommends as the fix.\n'
  exit 0
fi

# Guard the mktemp, do not assume it. This script runs under `set -uo pipefail` and
# deliberately NOT `-e`, so a failing `mktemp -d` (unwritable or nonexistent `$TMPDIR`, a
# full `/tmp`) would yield an empty `$TMP` and execution would carry on — at which point
# `$TMP/fixtures` is the ABSOLUTE path `/fixtures`, and the fixture heredocs below write
# outside the sandbox this file's header promises they stay inside. As an unprivileged
# user that fails with EACCES, but a root-run CI container has a writable `/`, which is
# where it would silently succeed. `-d` rather than `-n`: a non-empty string that is not a
# directory is just as unusable.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/forgeward-rules-test.XXXXXX")"
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  printf 'not ok 1 - mktemp -d succeeded (TMPDIR=%s)\n' "${TMPDIR:-/tmp}"
  printf '1..1\n# pass 0  fail 1\n'
  exit 1
fi
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
FIX="$TMP/fixtures"
mkdir -p "$FIX"

# --- fixtures. Line numbers are load-bearing: every assertion below cites file:line, so
# --- inserting a line into one of these heredocs shifts the expectations with it.

cat > "$FIX/r1-positive.ts" <<'EOF'
// rule 1 positives — every shape the rule must serve, one per line.
export const server = process.env.POLAR_SERVER ?? 'sandbox';
export const level = process.env['LOG_LEVEL'] ?? 'info';
export const dsn = import.meta.env.VITE_SENTRY_DSN ?? 'https://sentry.invalid/1';
export const region = Deno.env.get('REGION') ?? 'us-east-1';
export function inner(): string {
  return process.env.CACHE_DIR ?? '/var/cache/app';
}
EOF

cat > "$FIX/r1-negative.ts" <<'EOF'
// rule 1 negatives — legitimate configurations that must stay silent.
export const a = process.env.POLAR_SERVER || 'sandbox';
export const b = process.env['LOG_LEVEL'] || 'info';
export const c = someConfig.env.THING ?? 'x';
export const d = process.env.MAYBE ?? undefined;
export const e = process.env.MAYBE ?? null;
export const f = process.env.MAYBE ?? "";
export const g = process.env.MAYBE ?? '';
EOF

cat > "$FIX/r2-positive.ts" <<'EOF'
// rule 2 positives — module-scope construction that evaluates at import time.
export const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
export const redis = new Redis({ url: process.env.REDIS_URL, token: process.env.REDIS_TOKEN });
export const kv = new Deno.Kv(Deno.env.get('KV_URL'));
export const clients = { stripe: new Stripe(process.env.OTHER_KEY) };
export let conditional;
if (process.env.NODE_ENV === 'production') {
  conditional = new Stripe(process.env.PROD_KEY);
}
EOF

cat > "$FIX/r2-negative.ts" <<'EOF'
// rule 2 negatives — deferred construction, and a client that cannot fail on an unset var.
export function getStripe() {
  return new Stripe(process.env.STRIPE_SECRET_KEY);
}
export const getRedis = () => new Redis({ url: process.env.REDIS_URL });
export const logger = new Logger({ level: process.env.LOG_LEVEL || 'info' });
export const plain = new Foo({ retries: 3 });
export class Svc {
  client = new Stripe(process.env.STRIPE_SECRET_KEY);
}
EOF

cat > "$FIX/blind-spots.ts" <<'EOF'
// Documented blind spots. Each MUST stay silent. If one starts firing, the limits
// stated in rules/env-config.yml are out of date — correct the pack's message, then
// move the line into the positive fixture. Do not just delete the assertion.
const { DESTRUCTURED = 'd' } = process.env;
const raw = process.env.SPLIT_READ;
const split = raw ?? 'd';
const wrapped = env('WRAPPED') ?? 'd';
export const iife = (() => new Stripe(process.env.IIFE_KEY))();
export const viaConfig = new Stripe(cfg.key);
export const viaFactory = createStripe(process.env.FACTORY_KEY);
export const mixed = new Redis({ url: process.env.BARE_URL, token: process.env.TOK || '' });
export { DESTRUCTURED, split, wrapped };
EOF

# Extension coverage. `languages: [javascript, typescript]` is a claim about which files
# the pack actually reaches; these check it rather than trusting the label.
for ext in mjs cjs jsx tsx; do
  cat > "$FIX/ext.$ext" <<EOF
// extension coverage: .$ext
export const a = process.env.EXT_ONE ?? 'x';
export const b = new Redis(process.env.EXT_TWO);
EOF
done

# --- run the pack once, normalise to "<rule>|<basename>:<line>" -----------------------
#
# No --error: this pack is advisory, so a finding must not look like a scan failure.
# --disable-version-check keeps semgrep's upgrade notice out of stdout, which would
# otherwise append non-JSON after the report and break a strict parser.
RAW="$TMP/semgrep.json"
semgrep scan --config "$PACK" --metrics=off --disable-version-check --json "$FIX" >"$RAW" 2>"$TMP/semgrep.err"
SCAN_RC=$?

# One parser, two queries — `results` for the assertions, `errors` for the trust check.
# jq first, python3 as the fallback: the repo's stated footprint is "jq-or-python3".
sg() { # sg results|errors
  if command -v jq >/dev/null 2>&1; then
    case "$1" in
      results) jq -r '.results[] | "\(.check_id | split(".") | last)|\(.path | split("/") | last):\(.start.line)"' "$RAW" ;;
      errors)  jq -r '.errors | length' "$RAW" ;;
    esac
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$RAW" "$1" <<'PY'
import json,sys
with open(sys.argv[1]) as fh: d=json.load(fh)
if sys.argv[2] == "results":
    for r in d["results"]:
        print("%s|%s:%d" % (r["check_id"].split(".")[-1], r["path"].split("/")[-1], r["start"]["line"]))
else:
    print(len(d.get("errors", [])))
PY
  else
    printf 'rules-test: needs jq or python3 to parse semgrep JSON\n' >&2; return 1
  fi
}
FOUND="$(sg results | sort)" || { printf 'not ok 1 - could not parse semgrep output\n'; exit 1; }

# THE TRUST CHECK, and it runs first for a reason. A fixture semgrep cannot parse yields
# zero findings for that file, which turns every `expect_silent` on it green — the suite
# would report a clean pass while having verified nothing. A non-empty `errors` array
# invalidates the negative half of this run, so it is a hard failure, not a warning.
ERRC="$(sg errors)"
[ "${ERRC:-1}" = "0" ] \
  && ok "semgrep parsed every fixture (errors: 0)" \
  || nok "semgrep parsed every fixture" "errors: ${ERRC} — every SILENT assertion below is vacuous until this is fixed; see $RAW"

[ "$SCAN_RC" = "0" ] \
  && ok "advisory pack exits 0 with findings present (no --error)" \
  || nok "advisory pack exits 0 with findings present" "rc=$SCAN_RC — a findings exit code would read as a scan failure"

fired() { case "$FOUND" in *"$1|$2"*) return 0 ;; *) return 1 ;; esac; }
# any rule at this location
fired_any() { case "$FOUND" in *"|$1"*) return 0 ;; *) return 1 ;; esac; }

expect_fire() { # expect_fire <rule> <file:line> <what>
  fired "$1" "$2" && ok "FIRES  $2 — $3" || nok "FIRES  $2 — $3" "no $1 finding at $2"
}
expect_silent() { # expect_silent <file:line> <what>
  fired_any "$1" && nok "SILENT $1 — $2" "a rule fired at $1; found: $FOUND" || ok "SILENT $1 — $2"
}

R1=forgeward-env-nullish-fallback
R2=forgeward-env-client-at-module-scope

# --- rule 1: positives ----------------------------------------------------------------
expect_fire "$R1" r1-positive.ts:2 "process.env.X ?? 'default' (the Vercel/Polar build outage shape)"
expect_fire "$R1" r1-positive.ts:3 "process.env['X'] ?? 'default' (bracket access)"
expect_fire "$R1" r1-positive.ts:4 "import.meta.env.X ?? 'default' (Vite/bundler ecosystem)"
expect_fire "$R1" r1-positive.ts:5 "Deno.env.get('X') ?? 'default' (Deno/edge ecosystem)"
expect_fire "$R1" r1-positive.ts:7 "inside a function body — the bug is not scope-dependent"

# --- rule 1: negatives ----------------------------------------------------------------
expect_silent r1-negative.ts:2 "|| 'default' — the pattern this rule RECOMMENDS"
expect_silent r1-negative.ts:3 "|| 'default' with bracket access"
expect_silent r1-negative.ts:4 "a non-process .env property on some other object"
expect_silent r1-negative.ts:5 "?? undefined — no default is being lost"
expect_silent r1-negative.ts:6 "?? null — no default is being lost"
expect_silent r1-negative.ts:7 '?? "" — identical behaviour to || for a string-or-undefined value'
expect_silent r1-negative.ts:8 "?? '' — identical behaviour to || for a string-or-undefined value"

# --- rule 2: positives ----------------------------------------------------------------
expect_fire "$R2" r2-positive.ts:2 "module-scope client from a bare env read (Next.js/Stripe shape)"
expect_fire "$R2" r2-positive.ts:3 "env reads nested in an options object"
expect_fire "$R2" r2-positive.ts:4 "Deno.env.get inside a module-scope constructor"
expect_fire "$R2" r2-positive.ts:5 "construction nested in a module-scope object literal"
expect_fire "$R2" r2-positive.ts:8 "construction inside a module-scope if block"

# --- rule 2: negatives ----------------------------------------------------------------
expect_silent r2-negative.ts:3 "constructed inside a function — the recommended fix"
expect_silent r2-negative.ts:5 "constructed inside an arrow-function factory"
expect_silent r2-negative.ts:6 "every env read already defaulted — cannot fail on an unset var"
expect_silent r2-negative.ts:7 "literal arguments only, no env dependency"
expect_silent r2-negative.ts:9 "class field initialiser — runs at construction, not at import"

# --- documented blind spots (see the header: these pin the LIMITS, not the behaviour) --
expect_silent blind-spots.ts:4  "BLIND SPOT: destructuring default — same bug, unmatched"
expect_silent blind-spots.ts:6  "BLIND SPOT: fallback split across statements"
expect_silent blind-spots.ts:7  "BLIND SPOT: a wrapper hides the process.env token"
expect_silent blind-spots.ts:8  "BLIND SPOT: module-scope IIFE — immediate, but indistinguishable from a lazy getter"
expect_silent blind-spots.ts:9  "BLIND SPOT: value arrives via an imported config object"
expect_silent blind-spots.ts:10 "BLIND SPOT: a factory call rather than a new"
expect_silent blind-spots.ts:11 "OVER-SUPPRESSION: one defaulted read suppresses a sibling bare read"

# --- extension coverage ---------------------------------------------------------------
for ext in mjs cjs jsx tsx; do
  expect_fire "$R1" "ext.$ext:2" "rule 1 reaches .$ext"
  expect_fire "$R2" "ext.$ext:3" "rule 2 reaches .$ext"
done

printf '\n1..%d\n# pass %d  fail %d\n' "$((PASS+FAIL))" "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
