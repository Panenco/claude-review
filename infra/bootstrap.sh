#!/usr/bin/env bash
# bootstrap.sh — everything the token broker needs that Pulumi cannot create
# itself: enabled APIs, the Pulumi state bucket and its KMS key, the deploy
# service account, and Workload Identity Federation so GitHub Actions can
# deploy without a service-account key.
#
# Idempotent: safe to re-run from the top. Anything that already exists is
# reported and left alone.
#
# What it deliberately does NOT do: the GitHub App callback URL and client
# secret. Those have no API — see docs/runbooks/token-broker-setup.md §2.
#
# Usage:  PROJECT_ID=panenco-actions bash infra/bootstrap.sh

set -uo pipefail

PROJECT_ID="${PROJECT_ID:-panenco-actions}"
REGION="${REGION:-europe-west1}"
SERVICE="${SERVICE:-claude-token-broker}"
GITHUB_REPO="${GITHUB_REPO:-panenco/claude-review}"

STATE_BUCKET="${PROJECT_ID}-pulumi-state"
KEYRING="pulumi"
KEY="stack-secrets"
DEPLOY_SA="${SERVICE}-deploy"
POOL="github-actions"
PROVIDER="claude-review"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { printf '\n\033[1m> %s\033[0m\n' "$*"; }
ok() { echo "  [ok] $*"; }

command -v gcloud >/dev/null || die "gcloud is not installed"
gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1 \
  || die "cannot read project '$PROJECT_ID' — run 'gcloud auth login' first"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
BROKER_URL="https://${SERVICE}-${PROJECT_NUMBER}.${REGION}.run.app"
SA_EMAIL="${DEPLOY_SA}@${PROJECT_ID}.iam.gserviceaccount.com"

step "Project"
ok "$PROJECT_ID (number $PROJECT_NUMBER), region $REGION"

# ── Billing ───────────────────────────────────────────────────────────────
# Checked first, because without it `services enable` fails with a raw
# UREQ_PROJECT_BILLING_NOT_FOUND that reads like a permissions problem.
step "Billing"
if [ "$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null)" = "True" ]; then
  ok "billing is linked"
else
  die "project '$PROJECT_ID' has no billing account linked, so no API can be enabled.
  Link one with:
    gcloud billing projects link $PROJECT_ID --billing-account=<ACCOUNT_ID>
  If 'gcloud billing accounts list' shows nothing, you lack Billing Account
  Administrator and need someone who has it — or pick a project that is
  already billed."
fi

# ── APIs ──────────────────────────────────────────────────────────────────
step "Enabling APIs"
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com \
  cloudkms.googleapis.com \
  sts.googleapis.com \
  --project="$PROJECT_ID" || die "could not enable APIs"
for api in run artifactregistry secretmanager iam iamcredentials cloudresourcemanager cloudkms sts; do
  gcloud services list --enabled --project="$PROJECT_ID" \
    --filter="config.name=${api}.googleapis.com" --format='value(config.name)' \
    | grep -q . && ok "$api" || die "$api did not enable"
done

# ── Pulumi state: bucket + KMS ────────────────────────────────────────────
# KMS rather than a passphrase, so neither CI nor a laptop needs a shared
# secret to decrypt stack config — both authenticate as themselves.
step "Pulumi state bucket"
if gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="$PROJECT_ID" >/dev/null 2>&1; then
  ok "gs://${STATE_BUCKET} exists"
else
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --project="$PROJECT_ID" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention \
    || die "could not create the state bucket"
  ok "created gs://${STATE_BUCKET}"
fi
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning --project="$PROJECT_ID" >/dev/null 2>&1 \
  && ok "object versioning on (state history is recoverable)"

step "KMS key for stack secrets"
gcloud kms keyrings describe "$KEYRING" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1 \
  || gcloud kms keyrings create "$KEYRING" --location="$REGION" --project="$PROJECT_ID" \
  || die "could not create the keyring"
ok "keyring $KEYRING"
gcloud kms keys describe "$KEY" --keyring="$KEYRING" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1 \
  || gcloud kms keys create "$KEY" --keyring="$KEYRING" --location="$REGION" \
       --purpose=encryption --project="$PROJECT_ID" \
  || die "could not create the key"
ok "key $KEY"

# ── Deploy service account ────────────────────────────────────────────────
step "Deploy service account"
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  ok "$SA_EMAIL exists"
else
  gcloud iam service-accounts create "$DEPLOY_SA" \
    --display-name="Claude token broker — Pulumi deploy" --project="$PROJECT_ID" \
    || die "could not create the deploy service account"
  ok "created $SA_EMAIL"
fi

# Targeted rather than roles/owner. This account can still create service
# accounts and edit project IAM, so it is powerful — it is what deploys the
# broker, and anyone who can merge to main can make it run.
step "Granting deploy roles"
for role in \
  roles/run.admin \
  roles/artifactregistry.admin \
  roles/secretmanager.admin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountUser \
  roles/iam.roleAdmin \
  roles/resourcemanager.projectIamAdmin
do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$role" \
    --condition=None --quiet >/dev/null 2>&1 \
    && ok "$role" || die "could not grant $role"
done

gcloud storage buckets add-iam-policy-binding "gs://${STATE_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" --role=roles/storage.objectAdmin \
  --project="$PROJECT_ID" >/dev/null 2>&1 && ok "state bucket objectAdmin"

gcloud kms keys add-iam-policy-binding "$KEY" \
  --keyring="$KEYRING" --location="$REGION" --project="$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter >/dev/null 2>&1 && ok "KMS encrypt/decrypt"

# ── Workload Identity Federation ──────────────────────────────────────────
# Keyless: no service-account JSON to leak, rotate, or store in GitHub.
step "Workload Identity Federation"
gcloud iam workload-identity-pools describe "$POOL" \
  --location=global --project="$PROJECT_ID" >/dev/null 2>&1 \
  || gcloud iam workload-identity-pools create "$POOL" \
       --location=global --display-name="GitHub Actions" --project="$PROJECT_ID" \
  || die "could not create the WIF pool"
ok "pool $POOL"

# The attribute-condition is the security boundary. Repository alone is NOT
# enough here: this repo is public, and `pr-review.yml` runs untrusted PR code
# in a job that holds `id-token: write`. Any code in such a job can mint an
# OIDC token for any audience — so a repo-scoped trust would let a PR
# impersonate an account holding projectIamAdmin. Require the ref as well.
WIF_MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.environment=assertion.environment"
WIF_CONDITION="assertion.repository == '${GITHUB_REPO}' && assertion.ref == 'refs/heads/main'"

if gcloud iam workload-identity-pools providers describe "$PROVIDER" \
     --workload-identity-pool="$POOL" --location=global \
     --project="$PROJECT_ID" >/dev/null 2>&1; then
  # Update rather than skip, so re-running repairs a provider created with a
  # looser condition by an earlier version of this script.
  gcloud iam workload-identity-pools providers update-oidc "$PROVIDER" \
    --workload-identity-pool="$POOL" --location=global --project="$PROJECT_ID" \
    --attribute-mapping="$WIF_MAPPING" \
    --attribute-condition="$WIF_CONDITION" \
    || die "could not update the WIF provider"
else
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
    --workload-identity-pool="$POOL" --location=global --project="$PROJECT_ID" \
    --display-name="panenco/claude-review" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="$WIF_MAPPING" \
    --attribute-condition="$WIF_CONDITION" \
    || die "could not create the WIF provider"
fi
ok "provider $PROVIDER (locked to ${GITHUB_REPO} @ refs/heads/main)"

POOL_ID=$(gcloud iam workload-identity-pools describe "$POOL" \
  --location=global --project="$PROJECT_ID" --format='value(name)')

# Second, independent gate: bind on the GitHub *environment*, not the repo.
# Only a job declaring `environment: token-broker` gets that claim, so
# pr-review.yml cannot satisfy this even from main — and the environment can
# carry required reviewers and a branch policy on the GitHub side.
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/${POOL_ID}/attribute.environment/token-broker" \
  --quiet >/dev/null 2>&1 && ok "only the token-broker environment may impersonate the deploy account"

# Remove the repo-wide binding an earlier version of this script may have left:
# it would let ANY workflow on ANY branch assume the deploy account.
if gcloud iam service-accounts get-iam-policy "$SA_EMAIL" --project="$PROJECT_ID" \
     --format=json 2>/dev/null | grep -q "attribute.repository/${GITHUB_REPO}"; then
  gcloud iam service-accounts remove-iam-policy-binding "$SA_EMAIL" \
    --project="$PROJECT_ID" --role=roles/iam.workloadIdentityUser \
    --member="principalSet://iam.googleapis.com/${POOL_ID}/attribute.repository/${GITHUB_REPO}" \
    --quiet >/dev/null 2>&1 && ok "removed the older repo-wide impersonation binding"
fi

PROVIDER_RESOURCE="${POOL_ID}/providers/${PROVIDER}"

# ── Public invoker check ──────────────────────────────────────────────────
step "Checking org policy for public invoker"
# The EFFECTIVE policy is what matters: a policy object usually exists and
# often allows everything, so testing for its presence is a false alarm.
EFFECTIVE_POLICY=$(gcloud resource-manager org-policies describe \
  constraints/iam.allowedPolicyMemberDomains --project="$PROJECT_ID" \
  --effective 2>/dev/null)
if [ -z "$EFFECTIVE_POLICY" ] || printf '%s' "$EFFECTIVE_POLICY" | grep -q 'allValues: ALLOW'; then
  ok "no effective restriction — the allUsers binding will work"
else
  echo "  ! Domain-restricted IAM is in effect on this project:"
  printf '%s\n' "$EFFECTIVE_POLICY" | sed 's/^/      /'
  echo "    Cloud Run ingress must be public, so 'pulumi up' will fail binding"
  echo "    allUsers. Ask a GCP org admin to exempt ${PROJECT_ID} first."
fi

# ── What the caller still has to do ───────────────────────────────────────
cat <<SUMMARY

------------------------------------------------------------------------
Bootstrap complete.

FIRST — create the deploy environment. The WIF trust is bound to it, so the
deploy job cannot authenticate without it, and nothing else in the repo can
borrow the deploy account:

  gh api -X PUT repos/${GITHUB_REPO}/environments/token-broker \\
    --input - <<'ENV'
  {"deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}}
  ENV

Then, in the repo's Settings > Environments > token-broker, consider adding
required reviewers — that turns every production deploy into a human approval.

GitHub repository variables — set them with:

  gh variable set GCP_PROJECT        --body '${PROJECT_ID}'        --repo ${GITHUB_REPO}
  gh variable set GCP_REGION         --body '${REGION}'            --repo ${GITHUB_REPO}
  gh variable set GCP_DEPLOY_SA      --body '${SA_EMAIL}'          --repo ${GITHUB_REPO}
  gh variable set GCP_WIF_PROVIDER   --body '${PROVIDER_RESOURCE}' --repo ${GITHUB_REPO}
  gh variable set PULUMI_BACKEND_URL --body 'gs://${STATE_BUCKET}' --repo ${GITHUB_REPO}

The broker will be served at:
  ${BROKER_URL}

STILL MANUAL — no API exists for these (runbook section 2):
  1. Reviewer GitHub App -> Callback URL = ${BROKER_URL}/callback
  2. Reviewer GitHub App -> generate a client secret
  3. Confirm the App has Members: Read and is installed on every allowed org

Then the first deploy, which a human runs once so CI has state to refresh
its config from:

  cd infra
  pulumi login gs://${STATE_BUCKET}
  pulumi stack init prod --secrets-provider="gcpkms://projects/${PROJECT_ID}/locations/${REGION}/keyRings/${KEYRING}/cryptoKeys/${KEY}"
  pulumi config set project '${PROJECT_ID}'
  pulumi config set region '${REGION}'
  pulumi config set serviceName '${SERVICE}'
  pulumi config set allowedOrgs 'Panenco'
  pulumi config set githubClientId '<from step 2>'
  pulumi config set --secret githubClientSecret '<from step 2>'
  pulumi config set --secret sessionKey "\$(openssl rand -hex 32)"
  pulumi up --yes

After that, merges to main touching broker/ or infra/ deploy themselves.
------------------------------------------------------------------------
SUMMARY
