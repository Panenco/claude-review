import { strict as assert } from "node:assert";
import { test } from "node:test";
import { checkClaims } from "../src/oidc.js";
import { WORKFLOW_REF_PREFIX, type Config } from "../src/config.js";

const config = { allowedOrgs: ["panenco", "curewiki"] } as Config;

const valid = {
  repository_owner: "Panenco",
  job_workflow_ref: `${WORKFLOW_REF_PREFIX}refs/tags/v3`,
  actor: "LeslieJobse",
  repository: "Panenco/app",
  run_id: "42",
};

test("a reviewer run from an allowed org passes", () => {
  const claims = checkClaims(config, valid);
  assert.equal(claims.actor, "LeslieJobse");
  assert.equal(claims.repository, "Panenco/app");
  assert.equal(claims.runId, "42");
});

test("the dogfood ref shape passes too", () => {
  assert.doesNotThrow(() =>
    checkClaims(config, { ...valid, job_workflow_ref: `${WORKFLOW_REF_PREFIX}refs/heads/main` }),
  );
});

test("an org outside the list is rejected", () => {
  assert.throws(() => checkClaims(config, { ...valid, repository_owner: "attacker" }), /not an allowed org/);
  assert.throws(() => checkClaims(config, { ...valid, repository_owner: undefined }), /not an allowed org/);
});

test("a run from any other workflow is rejected", () => {
  assert.throws(
    () => checkClaims(config, { ...valid, job_workflow_ref: "panenco/other/.github/workflows/ci.yml@refs/heads/main" }),
    /not the reviewer workflow/,
  );
  // A near-miss path must not slip past a prefix check.
  assert.throws(
    () => checkClaims(config, { ...valid, job_workflow_ref: "evil/panenco/claude-review/.github/workflows/pr-review.yml@x" }),
    /not the reviewer workflow/,
  );
});

test("a token with no actor is rejected", () => {
  assert.throws(() => checkClaims(config, { ...valid, actor: "" }), /no actor claim/);
});
