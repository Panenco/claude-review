import type { IncomingMessage, ServerResponse } from "node:http";
import type { Config } from "./config.js";
import { authorizeUrl, currentLogin, exchangeCode, hasAllowedMembership } from "./github.js";
import { ClaimError, verifyRunToken, type RunClaims } from "./oidc.js";
import { isValidLogin, type TokenStore } from "./secrets.js";
import { signInPage, statusPage, type Notice } from "./html.js";
import {
  NONCE_COOKIE,
  SESSION_COOKIE,
  SESSION_TTL_SECONDS,
  issueSession,
  isSameOrigin,
  newNonce,
  nonceCookie,
  parseCookies,
  readSession,
  sessionCookie,
  stateFor,
  verifyState,
} from "./session.js";

const MAX_BODY_BYTES = 8 * 1024;
const MIN_TOKEN_LENGTH = 20;

function send(res: ServerResponse, status: number, body: string, headers: Record<string, string | string[]> = {}): void {
  res.writeHead(status, {
    "cache-control": "no-store",
    // Same-region Cloud Run services are same-site with us, so a sibling could
    // frame the authenticated page and overlay a click on Remove.
    "content-security-policy": "frame-ancestors 'none'",
    ...headers,
  });
  res.end(body);
}

function text(res: ServerResponse, status: number, body: string): void {
  send(res, status, body, { "content-type": "text/plain; charset=utf-8" });
}

function html(res: ServerResponse, body: string): void {
  send(res, 200, body, { "content-type": "text/html; charset=utf-8" });
}

function redirect(res: ServerResponse, location: string, headers: Record<string, string | string[]> = {}): void {
  send(res, 302, "", { location, ...headers });
}

// Non-members and unauthenticated machine callers get the same bare line: no
// login echoed, no org named, no route listing.
function forbidden(res: ServerResponse): void {
  text(res, 403, "Forbidden");
}

class BodyTooLarge extends Error {}

async function readBody(req: IncomingMessage): Promise<URLSearchParams> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > MAX_BODY_BYTES) throw new BodyTooLarge();
    chunks.push(chunk as Buffer);
  }
  return new URLSearchParams(Buffer.concat(chunks).toString("utf8"));
}

function sessionLogin(config: Config, req: IncomingMessage): string | null {
  const cookies = parseCookies(req.headers.cookie);
  return readSession(config.sessionKey, cookies[SESSION_COOKIE])?.login ?? null;
}

function handleLogin(config: Config, res: ServerResponse): void {
  const nonce = newNonce();
  redirect(res, authorizeUrl(config, stateFor(config.sessionKey, nonce)), {
    "set-cookie": nonceCookie(nonce),
  });
}

async function handleCallback(config: Config, req: IncomingMessage, res: ServerResponse, url: URL): Promise<void> {
  const nonce = parseCookies(req.headers.cookie)[NONCE_COOKIE] ?? "";
  const state = url.searchParams.get("state") ?? "";
  const code = url.searchParams.get("code") ?? "";

  // Login CSRF: without this an attacker walks a victim's browser through the
  // callback with the attacker's code, pinning the browser to the attacker's
  // account — and the victim then pastes their token into it.
  if (!code || !verifyState(config.sessionKey, nonce, state)) {
    forbidden(res);
    return;
  }

  const userToken = await exchangeCode(config, code);
  const login = await currentLogin(userToken);
  if (!(await hasAllowedMembership(config, userToken))) {
    forbidden(res);
    return;
  }

  redirect(res, "/", {
    "set-cookie": [
      sessionCookie(issueSession(config.sessionKey, login), SESSION_TTL_SECONDS),
      nonceCookie("", 0),
    ],
  });
}

async function handleStatus(config: Config, store: TokenStore, req: IncomingMessage, res: ServerResponse, url: URL): Promise<void> {
  const login = sessionLogin(config, req);
  if (!login) {
    html(res, signInPage());
    return;
  }
  const error = url.searchParams.get("error");
  const notice: Notice = error === "malformed" ? error : null;
  const { createdAt } = await store.status(login);
  html(res, statusPage(login, createdAt, notice));
}

async function handleSave(config: Config, store: TokenStore, req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (!isSameOrigin(config.brokerUrl, req.headers.origin)) {
    forbidden(res);
    return;
  }
  const login = sessionLogin(config, req);
  if (!login) {
    forbidden(res);
    return;
  }

  // The credential is NOT verified against Anthropic. A `setup-token` value is
  // only accepted by the API under the Claude Code identity prompt, so a probe
  // here would reject perfectly good tokens. Shape is all we can honestly
  // check; a wrong-but-well-formed token surfaces at the next review.
  const token = (await readBody(req)).get("token")?.trim() ?? "";
  if (token.length < MIN_TOKEN_LENGTH || /\s/.test(token)) {
    redirect(res, "/?error=malformed");
    return;
  }

  await store.write(login, token);
  console.log(JSON.stringify({ event: "token_registered", login }));
  redirect(res, "/");
}

async function handleDelete(config: Config, store: TokenStore, req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (!isSameOrigin(config.brokerUrl, req.headers.origin)) {
    forbidden(res);
    return;
  }
  const login = sessionLogin(config, req);
  if (!login) {
    forbidden(res);
    return;
  }
  await readBody(req);
  await store.remove(login);
  console.log(JSON.stringify({ event: "token_removed", login }));
  redirect(res, "/");
}

function sendToken(req: IncomingMessage, res: ServerResponse, token: string | null): void {
  if (!token) {
    // The workflow's "no token registered for @actor" path keys off 404.
    text(res, 404, req.method === "HEAD" ? "" : "no token registered");
    return;
  }
  // HEAD answers "is one registered?" with no body, so the workflow can fail
  // fast on an unregistered developer without pulling the credential early.
  text(res, 200, req.method === "HEAD" ? "" : token);
}

// The machine route. Cookies are ignored here and OIDC is ignored on the
// browser routes, so neither auth mode can be reached by the other's method.
async function handleApiToken(config: Config, store: TokenStore, deps: Deps, req: IncomingMessage, res: ServerResponse): Promise<void> {
  const header = req.headers.authorization ?? "";
  const bearer = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (!bearer) {
    forbidden(res);
    return;
  }

  let claims: RunClaims;
  try {
    claims = await deps.verify(config, bearer);
  } catch (err) {
    if (!(err instanceof ClaimError)) throw err;
    console.warn(JSON.stringify({ event: "token_rejected", reason: err.message }));
    forbidden(res);
    return;
  }

  // With no database, the request log is the only accountability record.
  console.log(
    JSON.stringify({
      event: "token_requested",
      actor: claims.actor,
      repository: claims.repository,
      run_id: claims.runId,
      method: req.method,
    }),
  );

  // A bracketed actor (`dependabot[bot]`) can never have registered one, and
  // must not 500 — the workflow retries 5xx and reports the wrong failure.
  sendToken(req, res, isValidLogin(claims.actor) ? await store.read(claims.actor) : null);
}

// The one call that leaves the process, injected so the routes are testable
// without a GitHub OIDC token.
export type Deps = {
  verify: (config: Config, token: string) => Promise<RunClaims>;
};

export function createApp(config: Config, store: TokenStore, deps: Deps = { verify: verifyRunToken }) {
  return async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    let route = `${req.method} ?`;
    try {
      // Inside the try: a malformed request target throws here, and an
      // unhandled rejection in an async handler exits the process.
      const url = new URL(req.url ?? "/", config.brokerUrl);
      route = `${req.method} ${url.pathname}`;

      if (route === "GET /api/token" || route === "HEAD /api/token") {
        await handleApiToken(config, store, deps, req, res);
      } else if (route === "GET /login") {
        handleLogin(config, res);
      } else if (route === "GET /callback") {
        await handleCallback(config, req, res, url);
      } else if (route === "GET /") {
        await handleStatus(config, store, req, res, url);
      } else if (route === "POST /token") {
        await handleSave(config, store, req, res);
      } else if (route === "POST /token/delete") {
        await handleDelete(config, store, req, res);
      } else {
        text(res, 404, "Not found");
      }
    } catch (err) {
      // Log the detail, return none of it: this service is reachable by anyone.
      console.error(`unhandled error on ${route}:`, err);
      if (res.headersSent) return;
      if (err instanceof BodyTooLarge) {
        text(res, 413, "Request too large");
      } else if (err instanceof TypeError) {
        text(res, 400, "Bad request");
      } else {
        text(res, 500, "Something went wrong");
      }
      // The request stream may be mid-flight; without this the connection
      // hangs after the response headers on a keep-alive socket.
      req.destroy();
    }
  };
}
