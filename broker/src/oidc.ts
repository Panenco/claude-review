import { createRemoteJWKSet, jwtVerify, type JWTPayload } from "jose";
import { GITHUB_ISSUER, WORKFLOW_REF_PREFIX, isAllowedOrg, type Config } from "./config.js";

// Caches keys and refetches on an unknown `kid`, so rotation needs no redeploy.
const jwks = createRemoteJWKSet(new URL(`${GITHUB_ISSUER}/.well-known/jwks`));

export type RunClaims = {
  actor: string;
  repository: string;
  runId: string;
};

export class ClaimError extends Error {}

// Pure, so the claim rules are testable without minting real GitHub tokens.
export function checkClaims(config: Config, payload: JWTPayload): RunClaims {
  const owner = typeof payload.repository_owner === "string" ? payload.repository_owner : "";
  if (!owner || !isAllowedOrg(config, owner)) {
    throw new ClaimError(`repository_owner "${owner}" is not an allowed org`);
  }

  // GitHub emits the owner's canonical casing ("Panenco/claude-review"), which
  // is not what a hand-written prefix looks like. Names are case-insensitively
  // unique, so fold before comparing — a mismatch here is an opaque 403.
  const ref = typeof payload.job_workflow_ref === "string" ? payload.job_workflow_ref : "";
  if (!ref.toLowerCase().startsWith(WORKFLOW_REF_PREFIX)) {
    throw new ClaimError(`job_workflow_ref "${ref}" is not the reviewer workflow`);
  }

  const actor = typeof payload.actor === "string" ? payload.actor : "";
  if (!actor) throw new ClaimError("token carries no actor claim");

  return {
    actor,
    repository: typeof payload.repository === "string" ? payload.repository : "",
    runId: typeof payload.run_id === "string" ? payload.run_id : String(payload.run_id ?? ""),
  };
}

// Throws ClaimError on any failure; callers answer 403.
export async function verifyRunToken(config: Config, token: string): Promise<RunClaims> {
  let payload: JWTPayload;
  try {
    ({ payload } = await jwtVerify(token, jwks, {
      issuer: GITHUB_ISSUER,
      audience: config.brokerUrl,
      algorithms: ["RS256"],
      requiredClaims: ["exp"],
    }));
  } catch (err) {
    throw new ClaimError(`OIDC token failed verification: ${(err as Error).message}`);
  }
  return checkClaims(config, payload);
}
