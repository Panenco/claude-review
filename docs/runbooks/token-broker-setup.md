# Token broker — deploy from nothing

Everything Pulumi cannot do, in order. Written to be **executed by Claude Code**:
every step is labelled `AUTO` (run the command as written) or `MANUAL` (a human
clicks through a UI that has no API), and every step ends with a verification
you can run.

The whole file is **idempotent** — safe to re-run from the top. A step that is
already done reports so and changes nothing.

Code: `broker/` (the service), `infra/` (the Pulumi program).

**Named config used throughout.** Set these once in your shell; nothing below
contains a placeholder that isn't one of them.

```bash
export PROJECT_ID=panenco            # the EXISTING Panenco GCP project
export REGION=europe-west1
export SERVICE=claude-token-broker
export ALLOWED_ORGS=Panenco          # comma-separated, e.g. Panenco,Curewiki
export PULUMI_STACK=prod
export REPO_ROOT=$(git -C . rev-parse --show-toplevel)   # this repo's checkout
```

> **Phase boundary.** Sections 1–5 are deployable and verifiable on their own —
> that is PR 1. Section 6 (the `/api/token` smoke test) needs a review run that
> requests the broker audience, which only exists once PR 2 lands. Do sections
> 1–5 first; come back for 6.

---

## 1. GCP bootstrap

The broker goes into the existing **`panenco-actions`** project (number
187583468130) — the org's GitHub Actions infrastructure project, which is what
the broker serves. Nothing here creates a project.

> The spec named the `panenco` project. That one has **no billing account**
> linked, and linking it needs a Billing Account Administrator nobody on the
> team currently is. `panenco-actions` is already billed, already has Artifact
> Registry enabled, and holds no secrets — so the deploy service account's
> project-wide powers sit next to nothing sensitive.

> **Fast path — `AUTO`.** `infra/bootstrap.sh` does every step in this section
> plus the deploy plumbing (Pulumi state bucket, KMS key, deploy service
> account, Workload Identity Federation), idempotently, and prints the exact
> `gh variable set` commands and first-deploy sequence at the end:
>
> ```bash
> gcloud auth login && gcloud auth application-default login
> PROJECT_ID=panenco-actions bash infra/bootstrap.sh
> ```
>
> Read on only if you want to do it by hand or to understand what it changed.

**1a. Sign in — `MANUAL`.** Both commands open a browser and wait for a human;
run them yourself rather than expecting an agent to complete them.

```bash
gcloud auth login
gcloud auth application-default login
```

**Verify** — both credentials resolve:

```bash
gcloud auth print-access-token >/dev/null && echo "user creds ok"
gcloud auth application-default print-access-token >/dev/null && echo "ADC ok"
```

**1b. Enable APIs — `AUTO`.**

```bash
gcloud config set project "$PROJECT_ID"
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com
```

```bash
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
```

**Verify** — asserts all five are present rather than grepping a stream where
`iam` also matches `iamcredentials` and `run` matches half the catalogue:

```bash
for api in run artifactregistry secretmanager iam cloudresourcemanager; do
  gcloud services list --enabled --project="$PROJECT_ID" \
    --filter="config.name=${api}.googleapis.com" --format='value(config.name)' \
    | grep -q . && echo "OK   ${api}" || echo "MISSING ${api}"
done
```

**1c. Pulumi backend — `AUTO`.** Without this, section 3 drops into an
interactive backend picker and stalls. Pick one:

```bash
# Pulumi Cloud (needs PULUMI_ACCESS_TOKEN in the environment):
pulumi login

# Or self-managed state in a GCS bucket — no Pulumi account, state stays in our org:
gcloud storage buckets create "gs://${PROJECT_ID}-pulumi-state" \
  --project="$PROJECT_ID" --location="$REGION" 2>/dev/null || true
pulumi login "gs://${PROJECT_ID}-pulumi-state"
```

Do **not** use `pulumi login file://.` — that writes state containing the
encrypted client secret into the working tree, and this repo is public.

**Verify**:

```bash
pulumi whoami --verbose
```

### 1d. Public invoker must be permitted — `AUTO` (then a human judgement call)

Cloud Run ingress is public by design, so section 4 binds `allUsers` to
`roles/run.invoker`. An org policy that restricts domain-shared IAM
(`constraints/iam.allowedPolicyMemberDomains`) blocks that binding and
`pulumi up` fails on it.

**Verify** — if this prints nothing, no project-level restriction applies and
you are fine. If it prints a policy with `allowedValues` (Cloud Identity
customer IDs, not the string `allUsers`), public invoker is blocked: ask a GCP
org admin to exempt this project *before* section 4.

```bash
gcloud resource-manager org-policies describe \
  constraints/iam.allowedPolicyMemberDomains --project="$PROJECT_ID" 2>/dev/null \
  || echo "no project-level policy — inherited default applies"
```

---

## 2. Reviewer GitHub App — `MANUAL`

There is no API for GitHub App settings, so this is a hand-off. We reuse the
**existing reviewer App** rather than creating a second one — OAuth Apps cannot
be created via API at all, so every extra App is another manual bootstrap.

The broker URL is deterministic. Compute it now, because step 2a needs it:

```bash
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
export BROKER_URL="https://${SERVICE}-${PROJECT_NUMBER}.${REGION}.run.app"
echo "$BROKER_URL"
```

**2a. Add the callback URL.**
Go to <https://github.com/settings/apps> → the reviewer App → **General**.
Under *Identifying and authorizing users*, set **Callback URL** to:

```
<BROKER_URL>/callback
```

Leave *Request user authorization (OAuth) during installation* off. Leave
*Expire user authorization tokens* at its default. Click **Save changes**.

**2b. Generate a client secret.**
Same page, *Client secrets* → **Generate a new client secret**. Copy the value
immediately — GitHub shows it once. Copy the **Client ID** from the top of the
page too.

**2c. Confirm the App has Members: Read and is installed on every allowed org.**
Under **Permissions & events → Organization permissions**, *Members* must be
**Read-only**. Then under **Install App**, confirm an installation exists for
every org in `ALLOWED_ORGS`.

> This one bites silently. A user-to-server token only reads memberships for
> orgs where the App is **installed**. An allowed org with no installation
> fails every one of its members at the login gate, with a bare 403 and no
> explanation.

**Verify** — `MANUAL`, and it has to be manual: GitHub validates
`redirect_uri` only *after* sign-in, so an unauthenticated `curl` to
`/login/oauth/authorize` always redirects to `/login` whether or not 2a was
saved. There is no request that can tell you from outside.

Record the values, then confirm the App page itself:

```bash
export GITHUB_CLIENT_ID=<from step 2b>
export GITHUB_CLIENT_SECRET=<from step 2b>
echo "callback must read: ${BROKER_URL}/callback"
```

Re-open the App's **General** page and check the Callback URL field matches
that line character for character. The real end-to-end proof is the sign-in in
section 5; a wrong value fails there with *"The redirect_uri MUST match"*.

---

## 3. Pulumi config — `AUTO`

Stack config is **git-ignored** (`infra/Pulumi.*.yaml`): this repo is public,
and there is no reason to publish even encrypted secrets from it. That makes
this section the source of truth for what a stack must contain.

```bash
cd "$REPO_ROOT/infra"
npm install
pulumi stack select "$PULUMI_STACK" || pulumi stack init "$PULUMI_STACK"

pulumi config set project        "$PROJECT_ID"
pulumi config set region         "$REGION"
pulumi config set serviceName    "$SERVICE"
pulumi config set allowedOrgs    "$ALLOWED_ORGS"
pulumi config set githubClientId "$GITHUB_CLIENT_ID"
pulumi config set --secret githubClientSecret "$GITHUB_CLIENT_SECRET"
# The HMAC key for session cookies and the OAuth `state`. Generated here and
# never seen again — nothing needs to read it back.
pulumi config set --secret sessionKey "$(openssl rand -hex 32)"
```

`maxInstances` defaults to 5. Raise it only with a reason: ingress is public,
so unauthenticated requests start containers and this is the cost ceiling.

**Verify** — seven keys, two of them `[secret]`:

```bash
pulumi config
```

---

## 4. First deploy — `AUTO`

`pulumi up` builds `broker/` locally, pushes it to Artifact Registry, and
deploys. There is no CI job and no deploy-on-merge: redeploying the broker is a
deliberate act.

```bash
cd "$REPO_ROOT/infra"
pulumi up --yes
```

The image targets `linux/amd64`. On an Apple Silicon Mac that means an emulated
build — it works, but the first one takes minutes; don't assume it has hung.

**Verify — the computed URL must be one Cloud Run serves.** This is the whole
`aud` contract: the workflow's `broker_url` default, the OIDC audience, and the
address developers visit are one string.

```bash
pulumi stack output url
pulumi stack output deployedUrls
# Cloud Run serves a service on several URLs; the computed one must be among
# them. Equality against a single "main" URI would false-alarm on a good deploy.
pulumi stack output deployedUrls --json \
  | jq -e --arg u "$(pulumi stack output url)" 'index($u)' >/dev/null \
  && echo "computed URL is served" \
  || echo "MISMATCH — Cloud Run did not serve the computed URL. Stop; the audience cannot be computed and the design needs revisiting."
```

Then prove the routes answer:

```bash
BROKER_URL=$(pulumi stack output url)
# Signed out, the root page is the sign-in page.
curl -s "$BROKER_URL" | grep -q 'Sign in with GitHub' && echo "UI ok"
# The machine route rejects an unsigned caller with a bare 403.
curl -s -o /dev/null -w '%{http_code}\n' "$BROKER_URL/api/token"          # 403
curl -s -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer nope' \
  "$BROKER_URL/api/token"                                                  # 403
# Nothing leaks a route listing.
curl -s "$BROKER_URL/admin"                                                # Not found
```

---

## 5. Register the first token — `MANUAL`

```bash
claude setup-token          # run locally, against your Claude Team seat
```

Open `$BROKER_URL` in a browser, **Sign in with GitHub**, paste the token,
**Save**. The page must come back **Token registered ✓** with today's date.

The broker checks the **shape** only — it never calls Anthropic, so a
well-formed but wrong token is accepted here and fails at the next review
instead. A red *"That doesn't look like a token"* means the paste was empty,
truncated, or contains whitespace.

**Verify** — the secret exists, and its name is lowercase:

```bash
gcloud secrets list --project="$PROJECT_ID" --filter='name:claude-token-' \
  --format='table(name, createTime)'
```

That same command is the answer to *"who still needs to onboard?"*. There is no
admin endpoint on purpose — no route exposing who works here.

---

## 6. Smoke test the machine route *(needs PR 2 merged)*

`GET /api/token` only answers a GitHub Actions OIDC token minted with the
broker as its audience, which `pr-review.yml` does not request until PR 2. Once
it does, exercise **both** ref shapes — they are verified by the same prefix
check but arrive differently, and the dogfood shape is the one nothing else
covers.

**6a. `MANUAL` — a downstream consumer run** (`job_workflow_ref` ends `@refs/tags/v3`):
comment `/review code` on any PR in a consumer repo, as a developer who has
registered a token.

**6b. `MANUAL` — this repo's own dogfood run** (`uses: ./…`, so the ref is a branch):
comment `/review code` on a PR in `panenco/claude-review`.

**Verify — `AUTO`.** Name the run you just triggered, then read both sides:

```bash
export SMOKE_REPO=<owner>/<repo>          # the repo you commented on
SMOKE_RUN=$(gh run list --repo "$SMOKE_REPO" --workflow claude-review.yml \
  --limit 1 --json databaseId --jq '.[0].databaseId')
gh run view "$SMOKE_RUN" --repo "$SMOKE_REPO" --log | grep -i 'token broker\|/api/token'

gcloud logging read \
  'resource.type=cloud_run_revision AND jsonPayload.event="token_requested"' \
  --project="$PROJECT_ID" --limit=5 \
  --format='table(timestamp, jsonPayload.actor, jsonPayload.repository, jsonPayload.run_id)'
```

With no database, that log **is** the accountability record. If it shows the
actor, the repository and the run id, the machine path is working end to end.

---

## 7. Day-two ops

### Add an org — `AUTO` + `MANUAL`

`ALLOWED_ORGS` governs both halves: who may sign in, and which repos' runs may
request a token.

1. `MANUAL` — **install the reviewer App on the new org first.** Without the
   installation, `GET /user/memberships/orgs/{org}` returns nothing for its
   members and every one of them fails the login gate with a bare 403.
   <https://github.com/settings/apps> → the reviewer App → **Install App** →
   the new org.
2. `AUTO` —

   ```bash
   cd "$REPO_ROOT/infra"
   pulumi config set allowedOrgs "Panenco,Curewiki"    # the full list, not a delta
   pulumi up --yes
   ```

**Verify** — a member of the new org can sign in and reaches the paste box, and
the service env carries the new list:

```bash
gcloud run services describe "$SERVICE" --region="$REGION" --project="$PROJECT_ID" \
  --format='value(spec.template.spec.containers[0].env.filter("name:ALLOWED_ORGS").extract(value))'
```

### Redeploy — `AUTO`

Merging to `main` with changes under `broker/` or `infra/` deploys itself
(`.github/workflows/deploy-broker.yml`). The job authenticates by Workload
Identity Federation — there is no service-account key anywhere — and takes its
stack config from the last deployment's state, which is why the first deploy
in section 4 has to be run by a human.

To deploy without a merge, run the workflow by hand:

```bash
gh workflow run deploy-broker.yml --repo panenco/claude-review
```

**Verify**:

```bash
gh run list --workflow deploy-broker.yml --repo panenco/claude-review --limit 1
```

### Why deploys are gated on a GitHub environment

The deploy service account holds `projectIamAdmin` and `serviceAccountAdmin`,
so what may impersonate it is the security boundary — not what may merge.

Two independent gates, both set by `bootstrap.sh`:

- The WIF provider's attribute-condition requires `repository == panenco/claude-review`
  **and** `ref == refs/heads/main`.
- The service account's IAM binding trusts `attribute.environment/token-broker`,
  so only a job declaring `environment: token-broker` can assume it.

Repository alone would not be enough. This repo is public, and `pr-review.yml`
runs untrusted PR code in a job that (from PR 2) holds `id-token: write` — and
any code in such a job can mint an OIDC token for any audience. A repo-scoped
trust would therefore let a pull request impersonate the deploy account.
`pr-review.yml` declares no environment, so it cannot satisfy the binding.

If someone deletes the `token-broker` environment, deploys fail closed with an
auth error rather than falling back to something looser.

### Rotate the client secret — `MANUAL` + `AUTO`

1. `MANUAL` — generate a new client secret on the reviewer App (step 2b). Do
   **not** delete the old one yet.
2. `AUTO` —

   ```bash
   cd "$REPO_ROOT/infra"
   pulumi config set --secret githubClientSecret "<new value>"
   pulumi up --yes
   ```
3. `MANUAL` — sign in at `$BROKER_URL` to confirm the flow still completes, then
   delete the old secret on the App.

Existing sessions are unaffected: they are signed with `sessionKey`, not the
client secret.

**Verify**: a fresh sign-in reaches the status page.

### Rotate the session key — `AUTO`

Signs every session cookie out immediately; nobody loses a registered token.

```bash
cd "$REPO_ROOT/infra"
pulumi config set --secret sessionKey "$(openssl rand -hex 32)"
pulumi up --yes
```

**Verify**: reloading `$BROKER_URL` in a previously signed-in browser shows the
sign-in page again.

### Offboard a developer — `AUTO`

**Removing their Claude Team seat is what actually revokes the credential.**
`GET /api/token` trusts the signed `actor` claim and never re-checks org
membership, so deleting the secret is cleanup, not revocation. Do the seat
first; the exposure is the gap between the two.

```bash
gcloud secrets delete "claude-token-$(echo "<login>" | tr 'A-Z' 'a-z')" \
  --project="$PROJECT_ID" --quiet
```

**Verify** — gone from the list, and their next review fails with the
"no token registered" error rather than serving a stale credential:

```bash
gcloud secrets list --project="$PROJECT_ID" --filter='name:claude-token-' \
  --format='value(name)'
```

### Tear down — `AUTO`

Destroys the service, the registry, the service account and the two config
secrets. It does **not** touch `claude-token-*`: those are created by the
broker at runtime, are not Pulumi-managed, and are live credentials.

```bash
cd "$REPO_ROOT/infra"
pulumi destroy --yes
# Then, deliberately, the developer tokens:
gcloud secrets list --project="$PROJECT_ID" --filter='name:claude-token-' \
  --format='value(name)' \
  | xargs -n1 -I{} gcloud secrets delete {} --project="$PROJECT_ID" --quiet
```

**Verify**:

```bash
gcloud run services list --region="$REGION" --project="$PROJECT_ID" | grep -c "$SERVICE"   # 0
gcloud secrets list --project="$PROJECT_ID" --filter='name:claude-token-' --format='value(name)'  # empty
```

> **The one thing that is not re-runnable.** GCP *soft-deletes* custom IAM roles
> for 7 days, so a `pulumi up` within a week of a `pulumi destroy` fails on
> `claudeTokenBrokerSecretCreate` already existing in a deleted state. Undelete
> it rather than renaming:
>
> ```bash
> gcloud iam roles undelete claudeTokenBrokerSecretCreate --project="$PROJECT_ID"
> ```

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `pulumi up` fails binding `allUsers` | Org policy blocks domain-shared IAM — see 1d |
| Sign-in ends on a bare `403 Forbidden` | Not an active member of any `ALLOWED_ORGS` org, **or** the reviewer App is not installed on their org (step 2c) |
| Sign-in errors at GitHub with *redirect_uri MUST match* | Callback URL in step 2a doesn't equal `<BROKER_URL>/callback` exactly |
| `/api/token` returns 403 for a real review run | `aud` mismatch (a trailing slash counts), an org missing from `ALLOWED_ORGS`, or the run is not `pr-review.yml` from this repo. The broker logs the reason — `gcloud logging read 'jsonPayload.event="token_rejected"'` |
| `/api/token` returns 404 for a real review run | That `actor` has no registered token. They register at `$BROKER_URL`; 30 seconds |
| A save reports *"That doesn't look like a token"* | The paste was empty, truncated, or contains whitespace. Re-run `claude setup-token` and paste the whole value |
| A registered token still fails at review time | The broker checks shape, not validity — it never calls Anthropic. Re-run `claude setup-token` and Replace |
