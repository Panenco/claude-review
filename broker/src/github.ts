import { isAllowedOrg, type Config } from "./config.js";

// Reuses the reviewer App: GitHub OAuth Apps cannot be created via API, so a
// second App would mean a second manual bootstrap.

export function authorizeUrl(config: Config, state: string): string {
  const url = new URL("https://github.com/login/oauth/authorize");
  url.searchParams.set("client_id", config.githubClientId);
  url.searchParams.set("redirect_uri", new URL("/callback", config.brokerUrl).toString());
  url.searchParams.set("state", state);
  return url.toString();
}

export async function exchangeCode(config: Config, code: string): Promise<string> {
  const response = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      client_id: config.githubClientId,
      client_secret: config.githubClientSecret,
      code,
      redirect_uri: new URL("/callback", config.brokerUrl).toString(),
    }),
  });
  if (!response.ok) {
    throw new Error(`GitHub token exchange failed with ${response.status}`);
  }
  const body = (await response.json()) as { access_token?: string; error?: string };
  if (!body.access_token) {
    throw new Error(`GitHub token exchange returned no token: ${body.error ?? "unknown error"}`);
  }
  return body.access_token;
}

async function githubGet(token: string, path: string): Promise<Response> {
  return fetch(`https://api.github.com${path}`, {
    headers: {
      authorization: `Bearer ${token}`,
      accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28",
      "user-agent": "claude-token-broker",
    },
  });
}

export async function currentLogin(token: string): Promise<string> {
  const response = await githubGet(token, "/user");
  if (!response.ok) throw new Error(`GET /user failed with ${response.status}`);
  const body = (await response.json()) as { login?: string };
  if (!body.login) throw new Error("GET /user returned no login");
  return body.login;
}

// A user-to-server token only reads memberships where the App is INSTALLED, so
// an allowed org without the reviewer App silently fails all of its members.
export async function hasAllowedMembership(config: Config, token: string): Promise<boolean> {
  for (const org of config.allowedOrgs) {
    const response = await githubGet(token, `/user/memberships/orgs/${encodeURIComponent(org)}`);
    if (response.status === 401) {
      console.warn("membership check got 401 — the user token was revoked or expired");
      return false;
    }
    if (response.status === 404 || response.status === 403) continue;
    if (!response.ok) {
      console.warn(`membership check for ${org} returned ${response.status}`);
      continue;
    }
    const body = (await response.json()) as { state?: string; organization?: { login?: string } };
    if (body.state === "active" && isAllowedOrg(config, body.organization?.login ?? org)) {
      return true;
    }
  }
  return false;
}
