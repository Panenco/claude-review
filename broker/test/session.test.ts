import { strict as assert } from "node:assert";
import { test } from "node:test";
import {
  SESSION_TTL_SECONDS,
  issueSession,
  isSameOrigin,
  parseCookies,
  readSession,
  stateFor,
  verifyState,
} from "../src/session.js";

const KEY = "test-session-key";

test("a session round-trips", () => {
  const cookie = issueSession(KEY, "LeslieJobse");
  assert.equal(readSession(KEY, cookie)?.login, "LeslieJobse");
});

test("a tampered payload is rejected", () => {
  const cookie = issueSession(KEY, "alice");
  const forged = Buffer.from(JSON.stringify({ login: "bob", exp: 9e9 })).toString("base64url");
  const [, signature] = cookie.split(".");
  assert.equal(readSession(KEY, `${forged}.${signature}`), null);
});

test("a session signed with another key is rejected", () => {
  assert.equal(readSession(KEY, issueSession("other-key", "alice")), null);
});

test("an expired session is rejected", () => {
  const issued = issueSession(KEY, "alice", 0);
  assert.equal(readSession(KEY, issued, (SESSION_TTL_SECONDS + 1) * 1000), null);
});

test("garbage cookies are rejected, not thrown on", () => {
  for (const value of ["", "nodot", "..", "a.b", "$$$.###"]) {
    assert.equal(readSession(KEY, value), null);
  }
});

test("oauth state only verifies against its own nonce", () => {
  const nonce = "abc123";
  assert.equal(verifyState(KEY, nonce, stateFor(KEY, nonce)), true);
  assert.equal(verifyState(KEY, "other", stateFor(KEY, nonce)), false);
  assert.equal(verifyState(KEY, nonce, "forged"), false);
  assert.equal(verifyState(KEY, "", stateFor(KEY, nonce)), false);
});

test("origin check accepts only the broker's own origin", () => {
  const broker = "https://broker-123.europe-west1.run.app";
  assert.equal(isSameOrigin(broker, broker), true);
  assert.equal(isSameOrigin(broker, `${broker}/`), true);
  assert.equal(isSameOrigin(broker, "https://evil.example"), false);
  assert.equal(isSameOrigin(broker, "null"), false);
  assert.equal(isSameOrigin(broker, undefined), false);
});

test("cookies parse into a map", () => {
  const parsed = parseCookies("a=1; broker_session=x.y; empty=");
  assert.equal(parsed.a, "1");
  assert.equal(parsed.broker_session, "x.y");
});
