// Everything here is required at boot: a broker that starts without its client
// secret serves a login page that 500s on callback.

export type Config = {
  brokerUrl: string;
  allowedOrgs: string[];
  githubClientId: string;
  githubClientSecret: string;
  sessionKey: string;
  gcpProject: string;
  port: number;
};

// Not configurable: this prefix is the only binding between a signed token
// request and the workflow allowed to make one.
export const WORKFLOW_REF_PREFIX =
  "panenco/claude-review/.github/workflows/pr-review.yml@";

export const GITHUB_ISSUER = "https://token.actions.githubusercontent.com";

function required(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name];
  if (!value) throw new Error(`${name} is required but not set`);
  return value;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const allowedOrgs = required(env, "ALLOWED_ORGS")
    .split(",")
    .map((o) => o.trim().toLowerCase())
    .filter(Boolean);
  if (allowedOrgs.length === 0) throw new Error("ALLOWED_ORGS is empty");

  return {
    // Verbatim OIDC audience — a trailing slash mismatch is a silent 403.
    brokerUrl: required(env, "BROKER_URL"),
    allowedOrgs,
    githubClientId: required(env, "GITHUB_CLIENT_ID"),
    githubClientSecret: required(env, "GITHUB_CLIENT_SECRET"),
    sessionKey: required(env, "SESSION_KEY"),
    gcpProject: required(env, "GCP_PROJECT"),
    port: Number(env.PORT ?? 8080),
  };
}

export function isAllowedOrg(config: Config, org: string): boolean {
  return config.allowedOrgs.includes(org.toLowerCase());
}
