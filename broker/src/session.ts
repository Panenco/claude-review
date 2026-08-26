import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

// `__Host-` is load-bearing, not cosmetic. The broker lives at
// <service>-<projectnum>.<region>.run.app, and only `run.app` is a public
// suffix — `<region>.run.app` is not. Without the prefix, any Cloud Run
// service in the same region could set our cookie with a Domain attribute and
// pin a victim's browser to its own session. The prefix forbids Domain.
export const SESSION_COOKIE = "__Host-broker_session";
export const NONCE_COOKIE = "__Host-broker_oauth_nonce";
export const SESSION_TTL_SECONDS = 12 * 60 * 60;
const NONCE_TTL_SECONDS = 10 * 60;

export type Session = { login: string; exp: number };

export function sign(key: string, value: string): string {
  return createHmac("sha256", key).update(value).digest("base64url");
}

export function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}

export function newNonce(): string {
  return randomBytes(32).toString("hex");
}

export function stateFor(key: string, nonce: string): string {
  return sign(key, `state:${nonce}`);
}

export function verifyState(key: string, nonce: string, state: string): boolean {
  if (!nonce || !state) return false;
  return safeEqual(stateFor(key, nonce), state);
}

export function issueSession(key: string, login: string, now = Date.now()): string {
  const payload: Session = { login, exp: Math.floor(now / 1000) + SESSION_TTL_SECONDS };
  const encoded = Buffer.from(JSON.stringify(payload)).toString("base64url");
  return `${encoded}.${sign(key, encoded)}`;
}

// Null for anything that isn't a live, correctly-signed session.
export function readSession(key: string, cookie: string | undefined, now = Date.now()): Session | null {
  if (!cookie) return null;
  const dot = cookie.lastIndexOf(".");
  if (dot <= 0) return null;
  const encoded = cookie.slice(0, dot);
  if (!safeEqual(sign(key, encoded), cookie.slice(dot + 1))) return null;

  try {
    const parsed = JSON.parse(Buffer.from(encoded, "base64url").toString()) as Session;
    if (typeof parsed.login !== "string" || typeof parsed.exp !== "number") return null;
    if (parsed.exp * 1000 <= now) return null;
    return parsed;
  } catch (err) {
    console.warn("session payload was signed but unparseable", err);
    return null;
  }
}

export function parseCookies(header: string | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (!header) return out;

  for (const part of header.split(";")) {
    const eq = part.indexOf("=");
    if (eq <= 0) continue;
    const name = part.slice(0, eq).trim();
    // Browsers send the more specific cookie first, so first wins. A bad
    // percent-escape must not throw: one junk cookie would 500 every route.
    if (name in out) continue;
    const raw = part.slice(eq + 1).trim();
    try {
      out[name] = decodeURIComponent(raw);
    } catch {
      out[name] = raw;
    }
  }
  return out;
}

// SameSite=Lax, not Strict: the `::error::` link in an Actions log is a
// cross-site navigation, and Strict would drop the cookie on arrival.
function cookie(name: string, value: string, maxAge: number): string {
  return `${name}=${value}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=${maxAge}`;
}

export function sessionCookie(value: string, maxAge: number): string {
  return cookie(SESSION_COOKIE, value, maxAge);
}

export function nonceCookie(value: string, maxAge = NONCE_TTL_SECONDS): string {
  return cookie(NONCE_COOKIE, value, maxAge);
}

// Every browser sends Origin on POST, so a missing header is rejected too.
export function isSameOrigin(brokerUrl: string, origin: string | undefined): boolean {
  if (!origin) return false;
  try {
    return new URL(origin).origin === new URL(brokerUrl).origin;
  } catch {
    return false;
  }
}
