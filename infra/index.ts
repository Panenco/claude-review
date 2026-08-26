import * as path from "path";
import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";
import * as docker from "@pulumi/docker-build";

// Deploys the broker into the EXISTING Panenco GCP project. No new project, no
// database, no load balancer, no domain mapping: the run.app URL is both the
// address developers visit and the OIDC audience the service verifies.
//
// The image ships with the infra — `pulumi up` builds broker/ locally and
// pushes it — so redeploying the broker is a deliberate act, decoupled from
// cutting a pipeline release.

const config = new pulumi.Config();
const projectId = config.require("project");
const region = config.get("region") ?? "europe-west1";
const serviceName = config.get("serviceName") ?? "claude-token-broker";
// e.g. "Panenco,Curewiki" — governs BOTH who may sign in and which repos'
// runs may request a token. Adding an org is config plus a redeploy.
const allowedOrgs = config.require("allowedOrgs");
const githubClientId = config.require("githubClientId");
const githubClientSecret = config.requireSecret("githubClientSecret");
const sessionKey = config.requireSecret("sessionKey");
// Ingress is public, so unauthenticated requests start containers. This is the
// cost ceiling, not a capacity plan.
const maxInstances = config.getNumber("maxInstances") ?? 5;

const project = gcp.organizations.getProjectOutput({ projectId });
const projectNumber = project.number;

// THE `aud` CHICKEN-AND-EGG. The service must verify an audience equal to its
// own URL, but an env var referencing its own URI is a dependency cycle.
// New-format Cloud Run URLs are deterministic, so compute it instead. (The
// older `<service>-<hash>` form is NOT computable — if the deployed URL does
// not match this, the runbook's first-deploy check catches it.)
const brokerUrl = pulumi.interpolate`https://${serviceName}-${projectNumber}.${region}.run.app`;

const registry = new gcp.artifactregistry.Repository("broker", {
  project: projectId,
  location: region,
  repositoryId: serviceName,
  format: "DOCKER",
  description: "Claude token broker container images",
  cleanupPolicies: [
    {
      id: "drop-untagged",
      action: "DELETE",
      condition: { tagState: "UNTAGGED", olderThan: "604800s" },
    },
  ],
});

const imageTag = pulumi.interpolate`${region}-docker.pkg.dev/${projectId}/${registry.repositoryId}/${serviceName}:latest`;

const image = new docker.Image("broker", {
  tags: [imageTag],
  context: { location: path.join(__dirname, "..", "broker") },
  dockerfile: { location: path.join(__dirname, "..", "broker", "Dockerfile") },
  platforms: ["linux/amd64"],
  push: true,
});

const serviceAccount = new gcp.serviceaccount.Account("broker", {
  project: projectId,
  accountId: `${serviceName}-sa`,
  displayName: "Claude token broker",
});
const member = pulumi.interpolate`serviceAccount:${serviceAccount.email}`;

// ── Config secrets ────────────────────────────────────────────────────────
// Mounted as env vars at deploy. The per-developer `claude-token-<login>`
// secrets are created by the broker at runtime and are NOT modelled here.

// Returns every resource, not just the Secret: Cloud Run validates secret
// refs when it creates a revision, so the service must wait for the VERSION
// and the accessor binding too. Depending on the Secret alone lets Pulumi
// build them in parallel and fail the first deploy on "version not found" or
// "permission denied" — which a re-run then papers over.
function configSecret(name: string, secretId: string, value: pulumi.Output<string>) {
  const secret = new gcp.secretmanager.Secret(name, {
    project: projectId,
    secretId,
    replication: { auto: {} },
  });
  const version = new gcp.secretmanager.SecretVersion(name, { secret: secret.id, secretData: value });
  const iam = new gcp.secretmanager.SecretIamMember(`${name}-access`, {
    project: projectId,
    secretId: secret.secretId,
    role: "roles/secretmanager.secretAccessor",
    member,
  });
  return { secret, version, iam };
}

const clientSecret = configSecret("client-secret", "github-app-client-secret", githubClientSecret);
const sessionSecret = configSecret("session-key", "broker-session-key", sessionKey);

// ── IAM for the per-developer token secrets ───────────────────────────────
// Two bindings instead of project-wide secretmanager.admin, which would let a
// compromised broker read every unrelated secret in the Panenco project.
//
// Creation cannot be scoped by name: an IAM condition on `resource.name`
// evaluates against the PARENT for a create request, so a startsWith on the
// new secret's name would reject every create. A create-only custom role is
// the narrow half of the trade — a secret the broker can create but cannot
// read is inert.
const createOnly = new gcp.projects.IAMCustomRole("broker-secret-create", {
  project: projectId,
  roleId: "claudeTokenBrokerSecretCreate",
  title: "Claude token broker — create secrets",
  description: "Create secrets only; read/modify is granted separately and scoped by name.",
  permissions: ["secretmanager.secrets.create"],
});

new gcp.projects.IAMMember("broker-secret-create", {
  project: projectId,
  role: createOnly.name,
  member,
});

// Everything destructive or readable is scoped by name prefix, so the broker
// reaches `claude-token-*` and nothing else.
new gcp.projects.IAMMember("broker-token-admin", {
  project: projectId,
  role: "roles/secretmanager.admin",
  member,
  condition: {
    title: "claude-token secrets only",
    description: "Restricts the broker to the per-developer review tokens.",
    expression: pulumi.interpolate`resource.name.startsWith("projects/${projectNumber}/secrets/claude-token-")`,
  },
});

// ── The service ───────────────────────────────────────────────────────────

const service = new gcp.cloudrunv2.Service(
  "broker",
  {
    project: projectId,
    location: region,
    name: serviceName,
    // Public: both runners and browsers reach it, so every route authorises
    // in-app. There is no network-level gate to lean on.
    ingress: "INGRESS_TRAFFIC_ALL",
    deletionProtection: false,
    template: {
      serviceAccount: serviceAccount.email,
      maxInstanceRequestConcurrency: 40,
      scaling: { minInstanceCount: 0, maxInstanceCount: maxInstances },
      containers: [
        {
          image: image.ref,
          ports: { containerPort: 8080 },
          envs: [
            { name: "BROKER_URL", value: brokerUrl },
            { name: "ALLOWED_ORGS", value: allowedOrgs },
            { name: "GITHUB_CLIENT_ID", value: githubClientId },
            { name: "GCP_PROJECT", value: projectId },
            {
              name: "GITHUB_CLIENT_SECRET",
              valueSource: { secretKeyRef: { secret: clientSecret.secret.secretId, version: "latest" } },
            },
            {
              name: "SESSION_KEY",
              valueSource: { secretKeyRef: { secret: sessionSecret.secret.secretId, version: "latest" } },
            },
          ],
          resources: { limits: { cpu: "1", memory: "512Mi" } },
        },
      ],
    },
  },
  {
    dependsOn: [
      image,
      clientSecret.version,
      clientSecret.iam,
      sessionSecret.version,
      sessionSecret.iam,
    ],
  },
);

new gcp.cloudrunv2.ServiceIamMember("broker-public", {
  project: projectId,
  location: region,
  name: service.name,
  role: "roles/run.invoker",
  member: "allUsers",
});

// `url` is what the workflow's `broker_url` default must equal, exactly.
// Cloud Run serves a service on SEVERAL URLs (the deterministic one and a
// hash-based one), so the runbook checks membership of `deployedUrls` — not
// equality with `uri`, which can name the other form on a working deploy.
export const url = brokerUrl;
export const deployedUrls = service.urls;
export const imageRef = image.ref;
export const serviceAccountEmail = serviceAccount.email;
