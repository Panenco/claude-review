import { SecretManagerServiceClient } from "@google-cloud/secret-manager";
import type { Config } from "./config.js";

// gRPC status codes we branch on.
const NOT_FOUND = 5;
const ALREADY_EXISTS = 6;
const FAILED_PRECONDITION = 9;

// The GitHub login IS the index — no mapping table, no database. Secret
// Manager IDs are case-sensitive and the OIDC `actor` claim preserves the
// user's chosen casing, so every read and write lowercases first or
// `LeslieJobse` and `lesliejobse` become two different credentials.
export function secretIdFor(login: string): string {
  const normalised = login.toLowerCase();
  if (!isValidLogin(normalised)) throw new Error(`"${login}" is not a valid GitHub login`);
  return `claude-token-${normalised}`;
}

export function isValidLogin(login: string): boolean {
  return /^[a-z0-9](?:[a-z0-9-]{0,38})$/.test(login.toLowerCase());
}

// `createdAt` present means registered — one source of truth, not two.
export type TokenStatus = { createdAt?: Date };

export interface TokenStore {
  read(login: string): Promise<string | null>;
  status(login: string): Promise<TokenStatus>;
  write(login: string, token: string): Promise<void>;
  remove(login: string): Promise<void>;
}

function codeOf(err: unknown): number | undefined {
  return (err as { code?: number }).code;
}

// NOT_FOUND is "never registered"; FAILED_PRECONDITION is what accessing a
// destroyed latest version returns. Both mean "no token" to every caller.
function isMissing(err: unknown): boolean {
  const code = codeOf(err);
  return code === NOT_FOUND || code === FAILED_PRECONDITION;
}

function versionNumber(name: string | null | undefined): number {
  return Number(name?.split("/").pop() ?? NaN);
}

// The subset of the Secret Manager client this store uses, so the version
// bookkeeping below can be tested against a fake instead of a real project.
export type SecretClient = Pick<
  SecretManagerServiceClient,
  | "getSecret"
  | "createSecret"
  | "deleteSecret"
  | "addSecretVersion"
  | "listSecretVersions"
  | "getSecretVersion"
  | "destroySecretVersion"
  | "accessSecretVersion"
>;

export class SecretManagerTokenStore implements TokenStore {
  constructor(
    private project: string,
    private client: SecretClient = new SecretManagerServiceClient(),
  ) {}

  private name(login: string): string {
    return `projects/${this.project}/secrets/${secretIdFor(login)}`;
  }

  async read(login: string): Promise<string | null> {
    try {
      const [version] = await this.client.accessSecretVersion({
        name: `${this.name(login)}/versions/latest`,
      });
      const data = version.payload?.data;
      return data ? Buffer.from(data as Uint8Array).toString("utf8").trim() : null;
    } catch (err) {
      if (isMissing(err)) return null;
      throw err;
    }
  }

  async status(login: string): Promise<TokenStatus> {
    try {
      const [version] = await this.client.getSecretVersion({
        name: `${this.name(login)}/versions/latest`,
      });
      if (version.state !== "ENABLED") return {};
      const seconds = Number(version.createTime?.seconds ?? 0);
      return seconds ? { createdAt: new Date(seconds * 1000) } : {};
    } catch (err) {
      if (isMissing(err)) return {};
      throw err;
    }
  }

  async write(login: string, token: string): Promise<void> {
    const name = this.name(login);
    await this.ensureSecret(login, name);

    const [created] = await this.client.addSecretVersion({
      parent: name,
      payload: { data: Buffer.from(token, "utf8") },
    });
    await this.destroyOlderThan(name, created.name);
  }

  async remove(login: string): Promise<void> {
    try {
      // Deleting the secret destroys every version with it.
      await this.client.deleteSecret({ name: this.name(login) });
    } catch (err) {
      if (codeOf(err) !== NOT_FOUND) throw err;
    }
  }

  private async ensureSecret(login: string, name: string): Promise<void> {
    try {
      await this.client.getSecret({ name });
      return;
    } catch (err) {
      if (codeOf(err) !== NOT_FOUND) throw err;
    }
    try {
      await this.client.createSecret({
        parent: `projects/${this.project}`,
        secretId: secretIdFor(login),
        secret: { replication: { automatic: {} } },
      });
    } catch (err) {
      // Two tabs saving at once: the loser just uses what the winner created.
      if (codeOf(err) !== ALREADY_EXISTS) throw err;
    }
  }

  // An enabled prior version is a live credential, so a replace that only adds
  // is a leak. Destroy strictly OLDER versions, never "everything but mine" —
  // two concurrent writers doing the latter destroy each other's version and
  // leave the developer with no token at all.
  private async destroyOlderThan(name: string, createdName: string | null | undefined): Promise<void> {
    const cutoff = versionNumber(createdName);
    if (!Number.isFinite(cutoff)) return;

    const [versions] = await this.client.listSecretVersions({ parent: name });
    for (const version of versions) {
      if (!version.name || version.state === "DESTROYED") continue;
      if (versionNumber(version.name) >= cutoff) continue;
      try {
        await this.client.destroySecretVersion({ name: version.name });
      } catch (err) {
        // The new token is already live; failing here would tell the developer
        // nothing was saved. Log the stale version so it can be cleaned up.
        console.error(`failed to destroy superseded version ${version.name}`, err);
      }
    }
  }
}

export function storeFor(config: Config): TokenStore {
  return new SecretManagerTokenStore(config.gcpProject);
}
