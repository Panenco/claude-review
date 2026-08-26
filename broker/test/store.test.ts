import { strict as assert } from "node:assert";
import { test } from "node:test";
import { SecretManagerTokenStore, type SecretClient } from "../src/secrets.js";

// A fake Secret Manager with the version semantics that matter: versions are
// numbered from 1, `latest` is the highest ENABLED one, and a destroyed latest
// answers accessSecretVersion with FAILED_PRECONDITION.
type Version = { name: string; data: string; state: "ENABLED" | "DESTROYED"; seconds: number };

function grpcError(code: number): Error {
  return Object.assign(new Error(`grpc ${code}`), { code });
}

class FakeSecretManager {
  secrets = new Map<string, Version[]>();
  failDestroy = false;

  private versionsOf(name: string): Version[] {
    const versions = this.secrets.get(name);
    if (!versions) throw grpcError(5);
    return versions;
  }

  async getSecret({ name }: { name: string }) {
    return [{ name: this.versionsOf(name) && name }];
  }

  async createSecret({ parent, secretId }: { parent: string; secretId: string }) {
    const name = `${parent}/secrets/${secretId}`;
    if (this.secrets.has(name)) throw grpcError(6);
    this.secrets.set(name, []);
    return [{ name }];
  }

  async deleteSecret({ name }: { name: string }) {
    if (!this.secrets.delete(name)) throw grpcError(5);
    return [{}];
  }

  async addSecretVersion({ parent, payload }: { parent: string; payload: { data: Buffer } }) {
    const versions = this.versionsOf(parent);
    const version: Version = {
      name: `${parent}/versions/${versions.length + 1}`,
      data: payload.data.toString(),
      state: "ENABLED",
      seconds: 1_754_000_000 + versions.length,
    };
    versions.push(version);
    return [version];
  }

  async listSecretVersions({ parent }: { parent: string }) {
    return [this.versionsOf(parent)];
  }

  private latest(secretName: string): Version {
    const enabled = this.versionsOf(secretName).filter((v) => v.state === "ENABLED");
    const last = this.versionsOf(secretName).at(-1);
    if (!last) throw grpcError(5);
    if (enabled.length === 0 || enabled.at(-1) !== last) throw grpcError(9);
    return last;
  }

  async getSecretVersion({ name }: { name: string }) {
    const secretName = name.replace(/\/versions\/latest$/, "");
    const version = this.versionsOf(secretName).at(-1);
    if (!version) throw grpcError(5);
    return [{ state: version.state, createTime: { seconds: version.seconds } }];
  }

  async accessSecretVersion({ name }: { name: string }) {
    const version = this.latest(name.replace(/\/versions\/latest$/, ""));
    return [{ payload: { data: Buffer.from(version.data) } }];
  }

  async destroySecretVersion({ name }: { name: string }) {
    if (this.failDestroy) throw new Error("destroy failed");
    const secretName = name.replace(/\/versions\/\d+$/, "");
    const version = this.versionsOf(secretName).find((v) => v.name === name);
    if (version) version.state = "DESTROYED";
    return [{}];
  }

  states(secretName: string): string[] {
    return this.versionsOf(secretName).map((v) => v.state);
  }
}

const SECRET = "projects/panenco/secrets/claude-token-alice";

function newStore() {
  const fake = new FakeSecretManager();
  return { fake, store: new SecretManagerTokenStore("panenco", fake as unknown as SecretClient) };
}

test("a first write creates the secret and reads back", async () => {
  const { store } = newStore();
  await store.write("Alice", "sk-ant-oat-one");
  assert.equal(await store.read("alice"), "sk-ant-oat-one");
  assert.ok((await store.status("ALICE")).createdAt instanceof Date);
});

test("an unregistered developer reads as null, not an error", async () => {
  const { store } = newStore();
  assert.equal(await store.read("nobody"), null);
  assert.deepEqual(await store.status("nobody"), {});
});

test("replace leaves exactly one live version", async () => {
  const { fake, store } = newStore();
  await store.write("alice", "first");
  await store.write("alice", "second");

  assert.equal(await store.read("alice"), "second");
  // An un-destroyed prior version is still a live credential.
  assert.deepEqual(fake.states(SECRET), ["DESTROYED", "ENABLED"]);
});

test("two concurrent saves cannot destroy each other's version", async () => {
  // The bug this guards: "destroy everything but mine" run twice concurrently
  // destroys BOTH versions and leaves the developer with no token at all.
  const { fake, store } = newStore();
  await Promise.all([store.write("alice", "from-tab-a"), store.write("alice", "from-tab-b")]);

  const live = fake.states(SECRET).filter((s) => s === "ENABLED");
  assert.equal(live.length, 1);
  assert.ok(await store.read("alice"));
});

test("two concurrent first-time saves do not collide on create", async () => {
  const { store } = newStore();
  await Promise.all([store.write("bob", "one"), store.write("bob", "two")]);
  assert.ok(await store.read("bob"));
});

test("a failed destroy still completes the write", async () => {
  // Throwing here would tell the developer nothing was saved while the new
  // token is already live — the worst of both.
  const { fake, store } = newStore();
  await store.write("alice", "first");
  fake.failDestroy = true;

  await store.write("alice", "second");
  assert.equal(await store.read("alice"), "second");
});

test("remove destroys every version, and is idempotent", async () => {
  const { store } = newStore();
  await store.write("alice", "first");
  await store.write("alice", "second");

  await store.remove("alice");
  assert.equal(await store.read("alice"), null);
  await store.remove("alice");
});
