import { strict as assert } from "node:assert";
import { after, test } from "node:test";
import { connect } from "node:net";
import { createServer, type Server } from "node:http";
import { createApp, type Deps } from "../src/app.js";
import { WORKFLOW_REF_PREFIX, type Config } from "../src/config.js";
import { ClaimError } from "../src/oidc.js";
import type { TokenStatus, TokenStore } from "../src/secrets.js";
import { SESSION_COOKIE, issueSession, stateFor } from "../src/session.js";

const BROKER = "https://broker-1.europe-west1.run.app";
const KEY = "test-session-key";

const config: Config = {
  brokerUrl: BROKER,
  allowedOrgs: ["panenco"],
  githubClientId: "Iv1.test",
  githubClientSecret: "secret",
  sessionKey: KEY,
  gcpProject: "panenco",
  port: 0,
};

class FakeStore implements TokenStore {
  tokens = new Map<string, string>();
  async read(login: string) {
    return this.tokens.get(login.toLowerCase()) ?? null;
  }
  async status(login: string): Promise<TokenStatus> {
    return this.tokens.has(login.toLowerCase()) ? { createdAt: new Date("2026-08-12T00:00:00Z") } : {};
  }
  async write(login: string, token: string) {
    this.tokens.set(login.toLowerCase(), token);
  }
  async remove(login: string) {
    this.tokens.delete(login.toLowerCase());
  }
}

const servers: Server[] = [];
after(() => servers.forEach((s) => s.close()));

function withApp(store: TokenStore, deps: Partial<Deps> = {}): Promise<string> {
  const full: Deps = {
    verify: async () => {
      throw new ClaimError("no verifier configured");
    },
    ...deps,
  };
  const server = createServer(createApp(config, store, full));
  servers.push(server);
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      resolve(`http://127.0.0.1:${typeof address === "object" && address ? address.port : 0}`);
    });
  });
}

const session = (login: string) => ({ cookie: `${SESSION_COOKIE}=${issueSession(KEY, login)}` });
const form = { "content-type": "application/x-www-form-urlencoded" };

function post(url: string, path: string, body: string, headers: Record<string, string>) {
  return fetch(`${url}${path}`, { method: "POST", headers: { ...form, ...headers }, body, redirect: "manual" });
}

// Raw socket: fetch() discards HEAD bodies, so an assertion on `.text()`
// passes even when the server wrongly sends the token.
function raw(url: string, request: string): Promise<string> {
  const { port } = new URL(url);
  return new Promise((resolve, reject) => {
    const socket = connect(Number(port), "127.0.0.1", () => socket.write(request));
    let data = "";
    socket.setTimeout(3000, () => {
      socket.destroy();
      resolve(data || "TIMEOUT");
    });
    socket.on("data", (c) => (data += c));
    socket.on("end", () => resolve(data));
    socket.on("error", reject);
  });
}

test("the root page is the sign-in page when signed out", async () => {
  const url = await withApp(new FakeStore());
  const response = await fetch(url, { redirect: "manual" });
  assert.equal(response.status, 200);
  assert.match(await response.text(), /Sign in with GitHub/);
  assert.equal(response.headers.get("content-security-policy"), "frame-ancestors 'none'");
});

test("the root page shows registration status when signed in", async () => {
  const store = new FakeStore();
  const url = await withApp(store);

  assert.match(await (await fetch(url, { headers: session("alice") })).text(), /No token registered/);
  await store.write("alice", "sk-ant-oat-x");
  assert.match(await (await fetch(url, { headers: session("alice") })).text(), /Token registered/);
});

test("a malformed paste is reported, and the notice clears", async () => {
  const url = await withApp(new FakeStore());
  const bad = await fetch(`${url}/?error=malformed`, { headers: session("alice") });
  assert.match(await bad.text(), /doesn't look like a token/);

  const clean = await fetch(url, { headers: session("alice") });
  assert.doesNotMatch(await clean.text(), /doesn't look like a token/);
});

test("login sets a nonce cookie and a state that is its HMAC", async () => {
  const url = await withApp(new FakeStore());
  const response = await fetch(`${url}/login`, { redirect: "manual" });

  const setCookie = response.headers.get("set-cookie") ?? "";
  const nonce = /__Host-broker_oauth_nonce=([a-f0-9]+)/.exec(setCookie)?.[1] ?? "";
  assert.ok(nonce, "expected a nonce cookie");
  // Without a Domain attribute a sibling Cloud Run service cannot plant this.
  assert.match(setCookie, /HttpOnly; Secure; SameSite=Lax; Path=\//);
  assert.doesNotMatch(setCookie, /Domain=/);

  const state = new URL(response.headers.get("location") ?? "").searchParams.get("state");
  assert.equal(state, stateFor(KEY, nonce));
});

test("the callback rejects a state that does not match its nonce", async () => {
  const url = await withApp(new FakeStore());
  const response = await fetch(`${url}/callback?code=abc&state=forged`, {
    headers: { cookie: "__Host-broker_oauth_nonce=n1" },
    redirect: "manual",
  });
  assert.equal(response.status, 403);
});

test("a junk cookie does not lock the user out of every route", async () => {
  // decodeURIComponent throws on a bad escape; an unguarded throw 500s the UI.
  const url = await withApp(new FakeStore());
  const response = await fetch(url, { headers: { cookie: "junk=%E0%A4%A; other=1" } });
  assert.equal(response.status, 200);
});

test("the first of duplicate session cookies wins", async () => {
  const store = new FakeStore();
  const url = await withApp(store);
  const good = issueSession(KEY, "alice");
  const response = await fetch(url, { headers: { cookie: `${SESSION_COOKIE}=${good}; ${SESSION_COOKIE}=garbage` } });
  assert.match(await response.text(), /Signed in as/);
});

test("saving requires both a session and a same-origin POST", async () => {
  const store = new FakeStore();
  const url = await withApp(store);

  const crossSite = await post(url, "/token", "token=stolen-token-value", { ...session("alice"), origin: "https://evil.example" });
  assert.equal(crossSite.status, 403);

  const noSession = await post(url, "/token", "token=stolen-token-value", { origin: BROKER });
  assert.equal(noSession.status, 403);
  assert.equal(store.tokens.size, 0);
});

test("a well-formed paste is stored under the lowercased login", async () => {
  const store = new FakeStore();
  const url = await withApp(store);

  const response = await post(url, "/token", "token=sk-ant-oat-a-real-looking-value", { ...session("Alice"), origin: BROKER });
  assert.equal(response.status, 302);
  assert.equal(await store.read("alice"), "sk-ant-oat-a-real-looking-value");
});

test("an empty or truncated paste is refused before it is stored", async () => {
  const store = new FakeStore();
  const url = await withApp(store);

  for (const body of ["token=", "token=short", "token=has%20a%20space%20in%20it%20somewhere"]) {
    const response = await post(url, "/token", body, { ...session("alice"), origin: BROKER });
    assert.equal(response.headers.get("location"), "/?error=malformed");
  }
  assert.equal(store.tokens.size, 0);
});

test("an oversized body is refused with 413, not left hanging", async () => {
  const url = await withApp(new FakeStore());
  const response = await post(url, "/token", `token=${"x".repeat(20_000)}`, { ...session("alice"), origin: BROKER });
  assert.equal(response.status, 413);
});

test("a malformed request target does not take the process down", async () => {
  const url = await withApp(new FakeStore());
  const response = await raw(url, "GET http://[ HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n");
  assert.match(response, /^HTTP\/1\.1 400/);

  // The server is still answering afterwards — the point of the test.
  assert.equal((await fetch(url)).status, 200);
});

test("delete removes only the caller's own token", async () => {
  const store = new FakeStore();
  await store.write("alice", "a");
  await store.write("bob", "b");
  const url = await withApp(store);

  await post(url, "/token/delete", "", { ...session("alice"), origin: BROKER });
  assert.equal(await store.read("alice"), null);
  assert.equal(await store.read("bob"), "b");
});

test("an unknown route 404s without listing anything", async () => {
  const url = await withApp(new FakeStore());
  const response = await fetch(`${url}/admin`);
  assert.equal(response.status, 404);
  assert.equal(await response.text(), "Not found");
});

const claims = { actor: "Alice", repository: "Panenco/app", runId: "42" };

test("the machine route ignores cookies and demands a bearer token", async () => {
  const store = new FakeStore();
  await store.write("alice", "sk-ant-oat-x");
  const url = await withApp(store, { verify: async () => claims });

  assert.equal((await fetch(`${url}/api/token`, { headers: session("alice") })).status, 403);
});

test("a verified run gets the actor's token, case-insensitively", async () => {
  const store = new FakeStore();
  await store.write("alice", "sk-ant-oat-x");
  const url = await withApp(store, { verify: async () => claims });

  const response = await fetch(`${url}/api/token`, { headers: { authorization: "Bearer jwt" } });
  assert.equal(response.status, 200);
  assert.equal(await response.text(), "sk-ant-oat-x");
});

test("HEAD answers registered/not and never sends the token", async () => {
  const store = new FakeStore();
  const url = await withApp(store, { verify: async () => claims });

  const head = (u: string) => raw(u, "HEAD /api/token HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer jwt\r\nConnection: close\r\n\r\n");

  assert.match(await head(url), /^HTTP\/1\.1 404/);
  await store.write("alice", "sk-ant-oat-x");
  const present = await head(url);
  assert.match(present, /^HTTP\/1\.1 200/);
  assert.doesNotMatch(present, /sk-ant-oat-x/);
});

test("a bot actor gets 404, not a 500 the workflow would retry", async () => {
  const url = await withApp(new FakeStore(), {
    verify: async () => ({ ...claims, actor: "dependabot[bot]" }),
  });
  assert.equal((await fetch(`${url}/api/token`, { headers: { authorization: "Bearer jwt" } })).status, 404);
});

test("a token failing claim checks gets a bare 403", async () => {
  const store = new FakeStore();
  await store.write("alice", "sk-ant-oat-x");
  const url = await withApp(store, {
    verify: async () => {
      throw new ClaimError(`job_workflow_ref "${WORKFLOW_REF_PREFIX}" is not the reviewer workflow`);
    },
  });

  const response = await fetch(`${url}/api/token`, { headers: { authorization: "Bearer jwt" } });
  assert.equal(response.status, 403);
  assert.equal(await response.text(), "Forbidden");
});
