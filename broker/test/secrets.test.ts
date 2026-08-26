import { strict as assert } from "node:assert";
import { test } from "node:test";
import { secretIdFor } from "../src/secrets.js";

test("the secret id lowercases the login", () => {
  // Secret Manager IDs are case-sensitive and `actor` preserves the user's
  // casing, so this is what stops one developer owning two secrets.
  assert.equal(secretIdFor("LeslieJobse"), "claude-token-lesliejobse");
  assert.equal(secretIdFor("lesliejobse"), secretIdFor("LESLIEJOBSE"));
});

test("anything that is not a GitHub login is refused", () => {
  for (const bad of ["", "../escape", "a b", "user@example.com", "-lead", "x".repeat(40)]) {
    assert.throws(() => secretIdFor(bad), /not a valid GitHub login/);
  }
});
