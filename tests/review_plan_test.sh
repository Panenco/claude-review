#!/usr/bin/env bash
set -uo pipefail

# review_plan_test.sh — fixture test for scripts/review-plan.sh.
#
# The gate is a pure function: (changed files + base/head refs + labels) → a
# review plan, with no network or LLM. We feed inputs via env and assert the
# emitted plan as "review_level run_functional gate". No gh / no LLM key required.
#
# review_level: full | light | skip   ·   run_functional: true | false
# gate: normal | nonruntime | oversized | promotion | label | small

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/review-plan.sh"
fail=0

# summary_of KEY=VAL... → "<review_level> <run_functional> <gate>"
summary_of() {
  env "$@" bash "$SCRIPT" | awk -F= '
    /^review_level=/ {lvl=$2}
    /^run_functional=/{fn=$2}
    /^gate=/         {g=$2}
    END {print lvl, fn, g}'
}

assert_plan() {
  local label="$1" want="$2"; shift 2
  local got; got=$(summary_of "$@")
  if [ "$got" = "$want" ]; then
    echo "OK:   $label → $got"
  else
    echo "FAIL: $label — want '$want' got '$got'"
    fail=$((fail + 1))
  fi
}

# A 65-file runtime diff (over the default 60-file ceiling), reused below.
BIG_FILES=$(for i in $(seq 1 65); do printf 'src/f%d.ts\t10\t10\n' "$i"; done)

# ── label → skip (highest precedence) ──
assert_plan "skip-review label" "skip false label" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_LABELS=$'enhancement\nskip-review' \
  GATE_FILES_TSV=$'src/app.ts\t40\t5'
assert_plan "label beats oversized" "skip false label" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_LABELS=$'skip-review' GATE_FILES_TSV="$BIG_FILES"
assert_plan "unrelated label only → normal (large diff)" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_LABELS=$'enhancement' GATE_FILES_TSV=$'src/app.ts\t250\t100'

# ── promotion → light (no functional) ──
assert_plan "staging → main" "light false promotion" \
  GATE_BASE_REF=main GATE_HEAD_REF=staging GATE_FILES_TSV=$'apps/web/x.ts\t10\t2'
assert_plan "release/* → production" "light false promotion" \
  GATE_BASE_REF=production GATE_HEAD_REF=release/2026-06 GATE_FILES_TSV=$'a.ts\t5\t5'
assert_plan "huge release PR (size irrelevant)" "light false promotion" \
  GATE_BASE_REF=main GATE_HEAD_REF=staging GATE_FILES_TSV="$BIG_FILES"
assert_plan "feature → main is NOT a promotion (large diff)" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'src/app.ts\t250\t100'

# ── oversized → light (functional smoke stays on) ──
assert_plan "65 runtime files" "light true oversized" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV="$BIG_FILES"
assert_plan "2600 changed lines" "light true oversized" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'src/big.ts\t1800\t800'
assert_plan "2100 changed lines is no longer oversized (ceiling raised to 2500)" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'src/big.ts\t1500\t600'
assert_plan "huge lockfile ALONE → not oversized (generated excluded)" "full false nonruntime" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'pnpm-lock.yaml\t9000\t9000'

# ── all non-runtime → full review, no functional ──
assert_plan "test-only migration" "full false nonruntime" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'apps/web/e2e/trajectories.cy.ts\t89\t52'
assert_plan "docs-only" "full false nonruntime" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'README.md\t10\t0'
assert_plan "CI workflow only" "full false nonruntime" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'.github/workflows/deploy.yml\t6\t0'

# ── normal → full + functional (substantial runtime, incl. ambiguous cases) ──
assert_plan "runtime source (large)" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'apps/web/src/page.tsx\t250\t100'
assert_plan "mixed test + runtime (large)" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'src/page.tsx\t250\t100\nsrc/page.test.ts\t20\t0'

# ── small runtime change → light/small (single judge, quick functional) [NEW] ──
assert_plan "small runtime source" "light true small" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'src/util.ts\t40\t5'
assert_plan "tsconfig (ambiguous → runtime, small)" "light true small" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'tsconfig.json\t3\t1'
assert_plan "exactly at the 300 ceiling → still small" "light true small" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'src/a.ts\t200\t100'
assert_plan "one line over the ceiling (301) → normal" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'src/a.ts\t200\t101'
assert_plan "generated lines don't count toward the ceiling → small" "light true small" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'src/a.ts\t50\t10\npnpm-lock.yaml\t5000\t5000'
# An all-generated diff has no reviewable (non-generated) source → NOT small.
assert_plan "all-generated bundle → normal, not small" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'dist/app.min.js\t50\t10'

# ── sensitive paths force a full review even when small [NEW] ──
assert_plan "auth.* file → full" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'src/services/auth.service.ts\t10\t2'
assert_plan "authentication/ dir → full" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'src/authentication/jwt.ts\t8\t1'
assert_plan "oauth/ dir → full" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'src/oauth/google-callback.ts\t12\t0'
assert_plan "small payments/ change → full" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'apps/api/src/payments/charge.ts\t8\t1'
assert_plan "small DB migration → full" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'apps/api/database/migrations/2026_06_03_fk.php\t12\t0'
# Sensitivity is checked on every path, generated or not — a sensitive generated
# file forces full even when the only non-generated change is small.
assert_plan "sensitive path in a GENERATED file still forces full" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'src/util.ts\t10\t2\nsrc/payments/api.generated.ts\t30\t0'
# A bare auth/ dir is a route group (views/auth/ = the signed-in area), NOT auth logic
# — it must NOT be force-full by default, else every frontend PR pays for it.
assert_plan "bare views/auth/ route group → small (not sensitive)" "light true small" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'apps/web/src/views/auth/dossier/inpress.vue\t10\t2'
assert_plan "'author.ts' is NOT sensitive (no false match)" "light true small" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_FILES_TSV=$'src/models/author.ts\t10\t2'
# A repo whose auth/ holds real logic can opt it back in (and the env var overrides the default).
assert_plan "opt-in '*/auth/*' via GATE_SENSITIVE_GLOBS → full" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_SENSITIVE_GLOBS='*/auth/*' \
  GATE_FILES_TSV=$'apps/web/src/views/auth/dossier/inpress.vue\t10\t2'

# ── deep-review label forces full (overrides the light downgrades) [NEW] ──
assert_plan "deep-review on a small PR → full" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_LABELS=$'deep-review' GATE_FILES_TSV=$'src/util.ts\t10\t2'
assert_plan "deep-review on a promotion → full" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=staging GATE_LABELS=$'deep-review' GATE_FILES_TSV=$'apps/web/x.ts\t10\t2'
assert_plan "deep-review on an oversized PR → full" "full true normal" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_LABELS=$'deep-review' GATE_FILES_TSV="$BIG_FILES"
assert_plan "deep-review on docs → still nonruntime (functional NOT forced)" "full false nonruntime" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_LABELS=$'deep-review' GATE_FILES_TSV=$'README.md\t10\t0'
assert_plan "skip-review beats deep-review" "skip false label" \
  GATE_BASE_REF=main GATE_HEAD_REF=feat/x GATE_LABELS=$'deep-review\nskip-review' GATE_FILES_TSV=$'src/util.ts\t10\t2'

if [ "$fail" -eq 0 ]; then
  echo
  echo "All review-plan tests passed."
  exit 0
else
  echo
  echo "$fail review-plan test assertion(s) failed."
  exit 1
fi
