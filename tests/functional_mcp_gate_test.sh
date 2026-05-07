#!/usr/bin/env bash
set -uo pipefail

# functional_mcp_gate_test.sh — fixture test for the FUNCTIONAL_MCP_BROKEN
# gate in build-review.sh.
#
# Background. Earlier the functional-tester subagent silently fell back to
# curl/psql when Playwright MCP wasn't available and reported the failure
# only as a footnote in functional_meta.uncertain_observations: "Playwright
# MCP tools were not available in this test context; all testing was done
# via curl/psql." A backend-only PR like seaters#457 then produced PASS,
# review verdict was COMMENT/APPROVE, and the developer never saw the gap.
#
# After this PR, two layers protect against the same hole:
#   - skill-level: review-functional-tester.md "MCP smoke-check failure"
#     forces overall=CRASH on a Turn-1 mcp__playwright__browser_navigate
#     failure, with summary containing "Playwright MCP unavailable".
#   - script-level (this test): build-review.sh's FUNCTIONAL_MCP_BROKEN
#     gate triggers in two ways:
#       a) overall == CRASH AND summary matches "Playwright MCP unavailable"
#       b) strategy == "functional" AND any uncertain_observations entry
#          matches the historical silent-fallback strings (defence-in-depth
#          if a future skill regression re-introduces curl-only).
#     Either signal flips the verdict to COMMENT and sets
#     requires_human_review=true with a clear reason.

cd "$(dirname "$0")/.."

fail=0
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    echo "FAIL: $label — want '$want', got '$got'"
    fail=$((fail + 1))
  else
    echo "OK:   $label"
  fi
}

# Inline the gate so the test doesn't have to source build-review.sh
# (which would run the entire review pipeline). The expression here MUST
# stay byte-identical to the one in scripts/build-review.sh; if you change
# one, change the other and re-run this test.
gate_for() {
  local meta="$1" strategy="$2" overall="$3"
  local crash_match
  crash_match=$(echo "$meta" | jq -e '(.summary // "") | test("Playwright MCP unavailable"; "i")' >/dev/null 2>&1 && echo true || echo false)
  local obs_match
  obs_match=$(echo "$meta" | jq -e '[(.uncertain_observations // [])[] | select(test("Playwright MCP.*not.*avail|MCP.*unavailable|fall.*back to curl|all testing was done via curl"; "i"))] | length > 0' >/dev/null 2>&1 && echo true || echo false)
  if [ "$overall" = "CRASH" ] && [ "$crash_match" = "true" ]; then
    echo "true"
  elif { [ "$strategy" = "functional" ] || [ "$strategy" = "quick" ]; } && [ "$obs_match" = "true" ]; then
    echo "true"
  else
    echo "false"
  fi
}

# ── Case A: skill-level loud fail (overall=CRASH + summary match). ──
META_A=$(jq -n '{
  strategy: "functional",
  overall: "CRASH",
  summary: "Playwright MCP unavailable — UI testing skipped. Subagent failed to start.",
  screenshots: [],
  areas_tested: [],
  uncertain_observations: ["Playwright MCP smoke check failed on Turn 1"]
}')
assert_eq "A: skill loud-fail (CRASH + summary) → broken=true" "true" "$(gate_for "$META_A" functional CRASH)"

# ── Case B: defence-in-depth (silent-fallback string in uncertain_observations). ──
# The historical bug shape from PR #457 round 1 — strategy=functional, overall=PASS,
# but the tester admitted MCP was unavailable in uncertain_observations.
META_B=$(jq -n '{
  strategy: "functional",
  overall: "PASS",
  summary: "Tested via curl + psql.",
  screenshots: [],
  areas_tested: ["scenario-1", "scenario-2"],
  uncertain_observations: [
    "Some other unrelated note.",
    "Playwright MCP tools were not available in this test context; all testing was done via curl/psql."
  ]
}')
assert_eq "B: silent-fallback string in observations → broken=true" "true" "$(gate_for "$META_B" functional PASS)"

# ── Case C: legitimate skip (no functional run) — must NOT trigger. ──
META_C=$(jq -n '{
  strategy: "skip",
  overall: "PASS",
  summary: "Functional testing skipped.",
  screenshots: [],
  areas_tested: [],
  uncertain_observations: []
}')
assert_eq "C: legitimate skip → broken=false" "false" "$(gate_for "$META_C" skip PASS)"

# ── Case D: real PASS (screenshots present, no MCP-broken string). ──
META_D=$(jq -n '{
  strategy: "functional",
  overall: "PASS",
  summary: "Tested 4 scenarios via Playwright. All passed.",
  screenshots: [
    {file: "/tmp/screenshots/01-list.png", description: "List page", area: "list"}
  ],
  areas_tested: ["scenario-1"],
  uncertain_observations: ["Auth path is OAuth-only — verified the redirect path."]
}')
assert_eq "D: healthy functional PASS → broken=false" "false" "$(gate_for "$META_D" functional PASS)"

# ── Case E: pipeline-self-test (deterministic; tests/*.sh, no MCP). ──
# Must not trigger even though strategy != "skip".
META_E=$(jq -n '{
  strategy: "pipeline-self-test",
  overall: "PASS",
  summary: "Ran 11 bash test scripts; all passed.",
  pass: 11, fail: 0, total: 11,
  uncertain_observations: []
}')
assert_eq "E: pipeline-self-test → broken=false" "false" "$(gate_for "$META_E" pipeline-self-test PASS)"

# ── Case F: CRASH with non-MCP summary (e.g. tester ran out of turns). ──
# overall=CRASH alone is NOT enough — summary must mention MCP unavailability.
# (A turn-budget crash still produced UI evidence; treating it as MCP-broken
# would over-flag.)
META_F=$(jq -n '{
  strategy: "functional",
  overall: "CRASH",
  summary: "Functional tester agent did not complete; max turns hit.",
  screenshots: [],
  areas_tested: [],
  uncertain_observations: []
}')
assert_eq "F: turn-budget crash (no MCP signal) → broken=false" "false" "$(gate_for "$META_F" functional CRASH)"

# ── Case G: future regression — overall=PASS but observations contain
# "MCP unavailable" (caught by the second-arm regex). ──
META_G=$(jq -n '{
  strategy: "functional",
  overall: "PASS",
  summary: "Tested everything.",
  screenshots: [],
  areas_tested: ["scenario-1"],
  uncertain_observations: ["MCP unavailable mid-run; switched to fetch."]
}')
assert_eq "G: post-launch MCP loss observation → broken=true" "true" "$(gate_for "$META_G" functional PASS)"

# ── Case G2: same fallback string under strategy=quick. The orchestrator
# dispatches the functional tester for both `functional` AND `quick`
# strategies; an earlier version of the gate checked only `functional`
# and would have let quick-strategy curl-fallback runs through silently. ──
META_G2=$(jq -n '{
  strategy: "quick",
  overall: "PASS",
  summary: "Quick smoke.",
  screenshots: [],
  areas_tested: ["smoke"],
  uncertain_observations: ["Playwright MCP tools were not available; ran curl smoke instead."]
}')
assert_eq "G2: quick-strategy fallback observation → broken=true" "true" "$(gate_for "$META_G2" quick PASS)"

# ── Case H: empty meta (no strategy / no overall) — must NOT crash. ──
META_H='{}'
assert_eq "H: empty meta → broken=false (no crash)" "false" "$(gate_for "$META_H" '' '')"

if [ "$fail" -eq 0 ]; then
  echo
  echo "All functional-MCP-gate tests passed."
  exit 0
else
  echo
  echo "$fail functional-MCP-gate test assertion(s) failed."
  exit 1
fi
