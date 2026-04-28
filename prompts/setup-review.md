# Setup Claude PR Review

You are setting up the Panenco Claude PR review pipeline in this repository. Follow these steps in order.

## Principles (read once, apply throughout)

Your output must pass the pipeline's own review on the first commit — **no findings, verdict `APPROVE`**. To achieve that:

1. **Verify every path you write.** Before referencing any file in `cp`, `source`, or `cat`, actually `ls` it. The validator step flags missing paths; don't let it.
2. **Prefer fail-fast patterns over silent timeouts.** Every readiness wait loop must explicitly log and warn (or exit) when it times out, not just `break` out. "Silently succeeds on timeout" is the #1 bug the reviewer catches in review-configs.
3. **Heading level is rigid: use `### Auth` and `### Known service ports` (level 3, with three `#`).** These sections must use the `###` heading level exactly — the "Validate review config" step greps for `^### Auth` and `^### Known service ports` to count detected sections, and getting the level wrong emits warnings and confuses readers. Place them *after* `## Functional validation` closes — i.e., after its last `### Step N` subsection — but keep the level at `###`. They are "sibling to `## Functional validation` in document flow" but "one level deeper in heading numbering"; when the prompt below says "peer to `## Functional validation`", read it as placement, not heading level.
4. **Track the `@v1` tag for the reusable workflow** so pipeline fixes auto-propagate, and declare the supply-chain trade-off as accepted in `bugbot.md` so the reviewer doesn't re-flag it on every PR (see Step 3 template).
5. **Match the exact phrasing the auto-extractor expects** for sign-in lines and auth methods (listed in Step 4 → `### Auth`).

## Step 1: Understand the repo

Before writing any config, gather context about this project:

1. **Package manager** — Check for `pnpm-lock.yaml`, `yarn.lock`, or `package-lock.json`
2. **Monorepo or single app** — Check for `pnpm-workspace.yaml`, `package.json` workspaces, or `turbo.json`
3. **Framework** — Read the main `package.json` (and sub-packages if monorepo) for: NestJS, Express, Fastify, Next.js, React, Vue, Django, FastAPI, etc.
4. **ORM / Database** — Look for: `prisma/schema.prisma`, `drizzle.config.ts`, `typeorm` in deps, `sequelize`, `knexfile`, `alembic.ini`, Django `models.py`
5. **Auth** — Search for auth-related files: `auth.module.ts`, `auth.controller.ts`, `passport`, `better-auth`, `next-auth`, JWT config. Find the sign-in endpoint and how sessions work (cookies, bearer tokens, etc.)
6. **Test data / seeding** — Check for: `prisma db seed`, seed scripts in `package.json`, SQL seed files, fixture files, factory patterns. If nothing exists, check if there's a `docker-compose.yml` with a database and look for migration files to understand the schema.
7. **Dev server** — Read `package.json` scripts for `dev`, `start:dev`, etc. Note the ports.
8. **Health check** — Find health endpoints: `/health`, `/api/health`, `/api`, root `GET /`
9. **Convention files** — Look for `.cursor/rules/`, `.eslintrc.*`, `CLAUDE.md`, `CONTRIBUTING.md`, coding standards docs
10. **Existing CI** — Read `.github/workflows/` to understand current CI setup, what checks already run

## Step 2: Create the caller workflow

Create `.github/workflows/claude-review.yml`:

```yaml
name: Claude PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  workflow_dispatch:
    inputs:
      pr_number:
        description: 'PR number to review'
        required: true
        type: string

# Cancel superseded review runs when a PR branch is repushed. Manual dispatch
# gets a per-invocation group so it never cancels concurrent PR runs.
concurrency:
  group: claude-review-${{ github.event.pull_request.number || github.run_id }}
  cancel-in-progress: true

jobs:
  review:
    # Skip drafts to avoid burning review budget on in-progress work. The
    # pipeline still re-runs automatically on `ready_for_review`. Manual
    # dispatch is always allowed.
    if: github.event_name == 'workflow_dispatch' || github.event.pull_request.draft == false
    # Track the v1 floating tag so pipeline fixes propagate automatically to
    # every consumer repo. Supply-chain acceptance is declared in bugbot.md
    # under "Accepted supply-chain trade-offs" so the reviewer does not
    # re-flag `@v1 + secrets: inherit` on every PR.
    uses: panenco/claude-review/.github/workflows/pr-review.yml@v1
    # Grant the reusable workflow the write scopes it needs. Reusable
    # workflows cannot elevate permissions above the caller, and GitHub's
    # default `GITHUB_TOKEN` since 2023 is read-only at both org and repo
    # level. Without this block the run fails at startup with `startup_failure`,
    # zero jobs, and no downloadable logs — extremely painful to debug.
    # Required scopes: `contents: write` (push screenshots to the
    # review-assets branch), `pull-requests: write` + `issues: write`
    # (post reviews and comments), `actions: read` (round-2 follow-up
    # reviews look up the prior run's review-state artifact by run-id —
    # omitting this means follow-up reviews silently degrade to a full
    # re-review on every push).
    permissions:
      contents: write
      pull-requests: write
      issues: write
      actions: read
    with:
      pr_number: ${{ inputs.pr_number || '' }}
    secrets: inherit
```

Note: the `concurrency:` block and the `if:` draft guard are required — omitting
either causes recurring reviewer noise (cursor-style bots flag missing concurrency
alongside all other repo workflows, and the pipeline re-runs on every `synchronize`
against draft PRs, wasting budget). The `permissions:` block is also required;
its omission is the #1 startup failure for repos in orgs with the GitHub-default
read-only `GITHUB_TOKEN` scope (see inline comment above).

**If `secrets: inherit` fails with `Secret CLAUDE_CODE_OAUTH_TOKEN is required, but not provided while calling`** — even though the secret is clearly set on the repo — swap `inherit` for the explicit form as a fallback:

```yaml
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      CLAUDE_REVIEW_APP_CLIENT_ID: ${{ secrets.CLAUDE_REVIEW_APP_CLIENT_ID }}
      CLAUDE_REVIEW_APP_PRIVATE_KEY: ${{ secrets.CLAUDE_REVIEW_APP_PRIVATE_KEY }}
      CLAUDE_REVIEW_APP_SLUG: ${{ secrets.CLAUDE_REVIEW_APP_SLUG }}
```

This has been observed on same-repo PRs in at least one external org and is likely caused by an org-level policy interacting with `inherit`. The explicit form unblocks the run; root cause can be investigated later.

## Step 3: Create bugbot.md

Create `bugbot.md` at the repo root with project-specific review rules. Keep it short — under 15 items. Focus on patterns that are:
- Non-obvious (a reviewer wouldn't know without being told)
- Specific to this project (not generic good practices)
- Things that have caused bugs before

Include a "Verify before flagging" section AND an "Accepted supply-chain trade-offs" section:

```markdown
## Verify before flagging

Before reporting a finding that cites a library or component, confirm it exists:
- Check `context.md` (generated at review runtime by the Context Builder agent; written to the workspace root during the run, not committed) → "Repo capabilities" for available exports and dependencies.
- If the artifact is not listed, drop the finding or move to `uncertain_observations`.

## Accepted supply-chain trade-offs

- `panenco/claude-review/.github/workflows/pr-review.yml@v1` with `secrets: inherit` is accepted. Upstream is first-party (Panenco org) and the mutable tag enables single-point propagation of pipeline fixes across every consumer repo. Do NOT flag this as a security finding — pinning to a SHA here was explicitly rejected in favor of easier upstream updates.
```

The "Accepted supply-chain trade-offs" line is what keeps the reviewer quiet about `@v1 + secrets: inherit`. Leave it in on every repo that uses `@v1`.

## Step 4: Create .github/review-config.md

Create `.github/review-config.md` with these sections. This is the most important file — it tells the review pipeline how to build, test, and validate your project.

### Build preparation

Commands that must run after `install` and before `typecheck`/`lint`. Typically codegen:
- Prisma: `npx prisma generate` or `pnpm --recursive exec prisma generate`
- GraphQL: `graphql-codegen` or equivalent
- OpenAPI: SDK generation
- Other codegen steps

### Convention files

Map changed file paths to convention/rule files the reviewers should read:

```markdown
| Changed path | Read |
|---|---|
| `src/api/**` | `.cursor/rules/api.mdc` |
| `src/web/**` | `.cursor/rules/web.mdc` |
```

If no convention files exist, omit this section.

### Stack-specific review focus

Write 3-5 bullet points per area about what reviewers should watch for. Be specific — reference actual patterns used in this codebase.

### Functional validation

**Prose only — no executable bash.** This section is read by the reviewer agents from `context.md` to understand what the functional tester should exercise. The *executable* side of dev-env bring-up lives in `.github/claude-review/dev-start.sh` (see Step 4.5). Describe, in prose, what the project needs at runtime:

- Database: which flavour (Postgres / MySQL / SQLite / none), whether it's dockerised, the default DB name, credentials for tests.
- Environment: where `.env` (or equivalent) actually lives (monorepo apps often have per-app `.env.example` files — `ls` to confirm), what vars matter.
- Migrations / codegen: Prisma / Drizzle / TypeORM / Django / etc., and whether they auto-run on boot or need an explicit step.
- Dev server: which processes start, which ports they bind. Reference the numbers, not the commands — commands live in `dev-start.sh`.
- Test data: what fixtures or seeders exist, which test users the seeders create, whether the functional tester should call a signup endpoint instead.

The reviewer needs the prose; the pipeline needs the script. Do not duplicate the commands in both places — the script is the source of truth.

## Step 4.5: Create .github/claude-review/dev-start.sh

This is the **first-class contract** the pipeline uses to bring up the dev environment. One file, one responsibility: install deps, start services, block until they respond. No heuristics, no stack guessing — just the commands this repo actually needs.

Create `.github/claude-review/dev-start.sh` and `chmod +x` it:

```bash
#!/usr/bin/env bash
set -uo pipefail

# dev-start.sh — Bring up the dev environment for the Claude Code review
# pipeline's functional tester. The pipeline runs this script (in a
# subshell) and then probes URLs from review-config.md's Known service
# ports table. Exit non-zero fails the Pre-start step hard — the whole
# review stops. Only commit a dev-start.sh you've verified locally.
# Repos with nothing to bring up (docs-only, lib-only) should not have
# this file at all; its absence is the signal for degraded-mode
# (core + sweep only, no functional tester).

# <Step 1 — e.g. Postgres>
docker compose up -d postgres
READY=false
for i in $(seq 1 30); do
  if docker compose exec -T postgres pg_isready -U <user> -d <db> > /dev/null 2>&1; then
    READY=true; break
  fi
  sleep 2
done
if [ "$READY" != "true" ]; then
  echo "::error::Postgres never became ready in 60s"
  docker compose logs postgres | tail -50
  exit 1
fi

# <Step 2 — install deps>
pnpm install --frozen-lockfile

# <Step 3 — migrations / codegen>
# Prisma:  pnpm exec prisma generate && pnpm exec prisma migrate deploy
# Drizzle: pnpm exec drizzle-kit push
# TypeORM: pnpm exec typeorm migration:run
# Django:  python manage.py migrate

# <Step 4 — start services>
pnpm run dev > /tmp/dev.log 2>&1 &
DEV_PID=$!

# <Step 5 — block until API is listening>
API_READY=false
for i in $(seq 1 60); do
  if curl -fsS http://localhost:<port>/<health-path> > /dev/null 2>&1; then
    API_READY=true; break
  fi
  sleep 2
done
if [ "$API_READY" != "true" ]; then
  echo "::error::API never became ready at http://localhost:<port>/<health-path> within 120s"
  tail -n 200 /tmp/dev.log || true
  kill "$DEV_PID" 2>/dev/null || true
  exit 1
fi
echo "API ready at http://localhost:<port>/<health-path>"
```

Rules:
- **Readiness loops must fail fast.** No bare `for ... && break; sleep ...; done` that silently falls through — always follow with `if [ "$READY" != "true" ]; then echo ::error:: ...; exit 1; fi`.
- **Failure is hard, not soft.** If `dev-start.sh` is present and exits non-zero, the pipeline fails the Pre-start step and the whole review stops. That is intentional — if you wrote a bring-up and it doesn't work, functional findings would be misleading. To run in degraded mode (core + sweep only), delete the file entirely.
- **No `set -e`** at the top. The subshell already propagates your explicit `exit N`; `set -e` adds surprise failures in idioms like `curl || true` or `grep` pipes that return 1 on no-match, without giving you anything back.
- **One place, not two.** If you put commands here, keep `review-config.md`'s `## Functional validation` section as prose only (see Step 4). The script is the source of truth for *how* to bring things up; the markdown is the source of truth for *what* the tester should expect.
- **Generated code matters.** If your tests import from a generated SDK / GraphQL client / `openapi-generator` output that isn't checked in, run the generator here *before* starting the dev server — otherwise `tsc --watch` / `nest start` floods the log with TS2307 noise (or, worse, the compile never settles). valcori's `dev-start.sh` runs `pnpm run generate-sdk` before `start:dev` for exactly this reason.
- **Test it locally.** Run `bash .github/claude-review/dev-start.sh` from a clean checkout before committing and confirm the services bind on the ports you list in `### Known service ports`. If it doesn't boot locally, it won't boot in CI — this is where circular imports, missing codegen, and misconfigured `DATABASE_URL` surface.

If the project has no services to start (pure-docs repo, lib-only package), do **not** create this file. Its absence triggers degraded mode (core + sweep reviewers run; no functional tester). An empty-but-present `dev-start.sh` will fail the step — either commit a real one or don't commit one at all.

## Step 4.6: External issue tracker (optional)

The default spec sources are the linked GitHub issue and any `docs/prds/*.md` referenced from it. Repos that track specs in Linear / Jira / Monday / Notion / etc. can opt into an extra hook that fetches the external spec and includes it in the reviewer's context. The pipeline ships **no provider-specific code** — the consumer owns the script and the API call.

Walk through this decision even if the project looks GitHub-only; confirm it explicitly so you don't leave a Linear-using repo silently missing spec context.

1. **Detect passively.** Look for tracker evidence without asking first:
   - `README.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `.github/PULL_REQUEST_TEMPLATE*`, `.github/ISSUE_TEMPLATE/*` — grep for `linear.app`, `*.atlassian.net`, `jira.`, `monday.com`, `notion.so`, `app.clickup.com`, `app.shortcut.com`, `app.asana.com`.
   - Recent PR bodies and branch names: `gh pr list --json body,headRefName --limit 20` — look for the same hosts plus any recurring `[A-Z]+-\d+` token convention in branch names.
   - Note what you found (or didn't) for the user.

2. **Confirm with the user.** Use `AskUserQuestion` to ask:
   > "Does this repo track specs in an external system (Linear / Jira / Monday / Notion / other)? If yes, which? If no, choose **GitHub only**."
   Ask this whether detection succeeded or not — a grep hit might be a one-off link, and a miss might just mean the history is sparse. The user's answer wins.

3. **If GitHub only** — print "No tracker integration needed. Skipping." and go to Step 5. Do not create `fetch-issue.sh` and do not list any extra secrets.

4. **If a tracker was chosen** — do NOT generate the hook script or any tracker code yourself. Output three concrete to-dos for the user to complete:

   - "**Add a repo secret named `TRACKER_SECRETS`** with your credentials in newline-separated `KEY=VALUE` form. For `<chosen tracker>`, a typical minimum is something like:
     ```
     <PROVIDER>_API_KEY=<your key>
     ```
     Get your key at `<the provider's API-key page URL>`."
   - "**Create `.github/claude-review/fetch-issue.sh`**. It reads `$ISSUE_CANDIDATES_FILE` (pre-extracted ticket references), calls your tracker, and prints markdown to stdout. See the README section **External issue trackers** (`.github/claude-review/fetch-issue.sh`) for the full contract, the candidates-file schema, and a provider-neutral skeleton to adapt."
   - "**Optional but recommended:** add a `Ticket: <url>` line to your PR template so authors paste the tracker URL into every PR — this gives the highest-confidence lookup (Tier-1 explicit marker)."

   Emphasize: `fetch-issue.sh` must be committed and `chmod +x`'d. Without `TRACKER_SECRETS` the hook runs but every env var the script references is empty, and the script will soft-fail on the first `curl` — the Actions log will show a `::warning::`.

### Auth

Document how to authenticate for testing:
- Sign-in endpoint (method, URL, body)
- Test user credentials (email/password or API key)
- Auth method: `cookie` (use `-c cookies.txt`), `bearer` (use `Authorization: Bearer <token>`), `header` (custom header like `x-auth`), or `none`

Use the exact endpoints, credentials, and auth method you discovered in Step 1. Format:

```markdown
### Auth
- Sign up: `<METHOD> <endpoint>` with `<JSON body>`
- Sign in: `<METHOD> <endpoint>` with `<JSON body>`
- Method: cookie | bearer | header | none
```

**Important — exact phrasing matters for the functional tester's auth auto-detection.** Start the sign-in line with one of `Sign in:`, `Sign-in:`, `Signin:`, `Log in:`, `Log-in:`, or `Login:`. The functional tester scans for these prefixes and for a `POST <endpoint>` + `{JSON body}` to pre-build a browser auth snippet. If your app uses a different phrasing, the snippet just won't be pre-built — the agent will fall back to reading this section directly from `context.md`, which is fine but less efficient.

For `header` or non-cookie auth (e.g., token in `x-auth` response header), document exactly how to capture and resend the token. Example:

```markdown
### Auth
- Sign in: `POST /api/auth/login` with `{"email":"<email>","password":"<password>"}`
- On success the token is returned in the `x-auth` response header. Subsequent requests must include `x-auth: <token>`.
- Method: header
```

If the app has no auth: write `### Auth` with `- Method: none`

### Known service ports

List the actual ports you found in Step 1 (from `package.json` scripts, framework config, or `.env` files). Do NOT guess ports — read the config.

```markdown
### Known service ports

| Service | URL | Notes |
|---------|-----|-------|
| <name> | <URL you discovered> | <health endpoint if known> |
```

**Section placement matters, and heading level is rigid.** `### Auth` and `### Known service ports` use **heading level 3 (three `#` — literally `###`)** and sit at **the root of the file, after `## Functional validation` has closed** (i.e., after its last `### Step N` subsection). They are placement-peers of `## Functional validation` — same depth in document flow — but **not** heading-peers: keep them at `###`, not `##`. The "Validate review config" step greps for `^### Auth` and `^### Known service ports` literally.

Correct file outline — note heading levels:

```
## Build preparation
## Convention files
## Stack-specific review focus
## Functional validation
  ### Step 1: Database
  ### Step 2: Environment
  ### Step 3: Migrations
  ### Step 4: Dev server
  ### Step 5: Test data
### Auth                     ← level 3, placed at file root after ## Functional validation
### Known service ports      ← level 3, placed at file root after ## Functional validation
```

Do **not** promote to `## Auth` / `## Known service ports` — the validator's `^### ` grep misses them and emits warnings. Do **not** nest them under `## Functional validation` either — when they live inside, the Functional-validation extractor picks up Auth code it shouldn't. Keep them exactly as **level-3 headings at the file's top level, immediately after the last `### Step N`**.

## Step 5: Verify self-check

Before committing, re-read your own `.github/review-config.md` and `.github/claude-review/dev-start.sh` and confirm:

- [ ] `dev-start.sh` exists, is executable (`chmod +x`), AND has been run locally from a clean checkout (fresh `pnpm install`, empty `./build`, no lingering dev-server processes on the target ports). The script must exit 0 and the service must actually respond on the health URL you listed in `### Known service ports`. If it doesn't boot locally, it won't boot in CI and v1's fail-hard contract will block every PR until fixed.
- [ ] If your repo generates code from an openapi spec / Prisma / Drizzle / GraphQL schema / etc. at dev-time, `dev-start.sh` runs that generator **before** the dev server. Missing codegen = TS errors = compile noise (and sometimes blocks boot outright — see valcori's historical `src/sdk` case).
- [ ] `review-config.md`'s `## Functional validation` section is **prose only** — no fenced `bash` blocks. Commands live in `dev-start.sh`.
- [ ] Every path appearing in a `cp`, `source`, or `cat` command (in either file) exists at the stated path. Run `ls <path>` to prove it.
- [ ] Every readiness wait loop in `dev-start.sh` either exits non-zero on timeout OR logs a `::warning::`/`::error::`. No bare `for ... && break; sleep ...; done` patterns.
- [ ] `### Auth` and `### Known service ports` sit at the top level of `review-config.md`, not nested inside `## Functional validation`.
- [ ] Sign-in line starts with one of: `Sign in:`, `Sign-in:`, `Signin:`, `Log in:`, `Log-in:`, `Login:`.
- [ ] Auth `Method:` is one of `cookie`, `bearer`, `header`, `none`.
- [ ] The caller workflow tracks `@v1` AND `bugbot.md` contains an "Accepted supply-chain trade-offs" section that names `panenco/claude-review@v1 + secrets: inherit` as accepted. Both are needed — the @v1 for auto-propagation, the bugbot note so the reviewer doesn't re-flag it.
- [ ] The caller workflow has a `concurrency:` block (`group: claude-review-${{ github.event.pull_request.number || github.run_id }}`, `cancel-in-progress: true`) AND a draft guard (`if: github.event_name == 'workflow_dispatch' || github.event.pull_request.draft == false`). Missing either is reviewer noise every PR.

If any check fails, fix before committing. The pipeline's reviewer will catch these on the first PR and block merge with `REQUEST_CHANGES`.

## Step 6: Verify secrets and App install

The OAuth token is required for every repo; the App-token path is how reviews get posted under a branded bot identity instead of `github-actions[bot]`. **Which track you follow depends on whether the repo is inside the Panenco org or external.** Pick one:

### Track A — Repos inside the Panenco org (short path)

1. `CLAUDE_CODE_OAUTH_TOKEN` (required) — generate with `claude setup-token` and add as a repo or org secret. Without it the workflow fails at the first step with `::error::CLAUDE_CODE_OAUTH_TOKEN secret is not configured.`

2. `CLAUDE_REVIEW_APP_CLIENT_ID`, `CLAUDE_REVIEW_APP_PRIVATE_KEY`, `CLAUDE_REVIEW_APP_SLUG` (recommended) — these are typically already set as **Panenco org secrets** with "All repositories" visibility, so `secrets: inherit` picks them up automatically for any new repo. If they're not, ask a Panenco org owner to add them once, org-wide.

3. **Install the `panenco-claude-reviewer` App on the repo** (already org-installed in most cases — the app lives inside Panenco). Go to `github.com/organizations/Panenco/settings/installations` → `panenco-claude-reviewer` → Configure → add the repo if not already covered by "All repositories".

Verify after the first PR run: the job log should contain `Review identity: panenco-claude-reviewer[bot]`.

### Track B — Repos outside the Panenco org (external-org path)

The shared Panenco app can't be installed on a different org (its visibility is typically private to Panenco). You create your own GitHub App in the external org, wire up the same four secrets pointing at *your* app, and install *your* app on the repo.

**Step B1 — Create your own GitHub App in the external org.**

Go to `github.com/organizations/<your-org>/settings/apps` → **New GitHub App**. Fill in:

- **GitHub App name** — anything, e.g. `<org>-claude-reviewer`. Must be globally unique across GitHub. The URL slug is auto-derived from this name (lowercased, spaces → hyphens, apostrophes stripped) — this slug becomes the value of `CLAUDE_REVIEW_APP_SLUG`.
- **Homepage URL** — anything; not used by the pipeline.
- **Webhook** — uncheck **Active**. The pipeline calls GitHub's API; it does not receive webhook events.
- **Repository permissions** — set exactly these:

  | Permission | Access |
  |---|---|
  | Contents | Read |
  | Pull requests | Read and write |
  | Issues | Read and write |
  | Metadata | Read (auto-selected) |

  A freshly-created App defaults to **No permissions**. The pipeline's "Create GitHub App token" call will succeed against a no-perms App (it just issues an empty-scope token), but subsequent API calls — posting reviews, pushing assets — silently fail. Set all four above before installing.

- **Where can this GitHub App be installed?** — "Only on this account".

Create, then on the App's settings page:

1. Note the **Client ID** (string starting with `Iv`, e.g. `Iv23li...`) — this is `CLAUDE_REVIEW_APP_CLIENT_ID`.
2. Click **Generate a private key** — downloads a `.pem` file. Its full contents (including `-----BEGIN RSA PRIVATE KEY-----` and `-----END RSA PRIVATE KEY-----` lines) become `CLAUDE_REVIEW_APP_PRIVATE_KEY`.
3. Record the slug from the App's settings URL (`github.com/organizations/<org>/settings/apps/<slug>`) — this becomes `CLAUDE_REVIEW_APP_SLUG`.

**Step B2 — Set the four secrets on the target repo (or external org).**

- `CLAUDE_CODE_OAUTH_TOKEN` — generate with `claude setup-token`.
- `CLAUDE_REVIEW_APP_CLIENT_ID`, `CLAUDE_REVIEW_APP_PRIVATE_KEY`, `CLAUDE_REVIEW_APP_SLUG` — from Step B1.

**Step B3 — Install your App on the target repo.**

In the App's left sidebar click **Install App** → choose the external org → pick "All repositories" or select the target repo.

**Then verify on the installation page (`github.com/organizations/<your-org>/settings/installations` → `<your-app>` → Configure) that BOTH fields are correctly populated:**

- **Repository access** — shows the target repo (or "All repositories"). If it says "No repositories", the App is technically "installed" but can't act on anything; the token call returns `Not Found`.
- **Permissions** — shows the four permissions from Step B1. If it says "No permissions", you created the App without setting them and need to go back to App settings → Permissions & events → add them → request/approve new permissions on the installation.

It is common to fix one and miss the other on a first setup; the installation page surfaces both in the same view. Check both before re-running.

### Symptom table (both tracks)

| Missing / misconfigured | Failure mode |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | First step fails: `::error::CLAUDE_CODE_OAUTH_TOKEN secret is not configured.` |
| `CLAUDE_REVIEW_APP_*` secrets | "Create GitHub App token" step is **skipped** → `github-actions[bot]` posts the review. Functionally OK, just the wrong identity. |
| `CLAUDE_REVIEW_APP_*` secrets set, App not installed on repo | "Create GitHub App token" step **fails** with `RequestError [HttpError]: Not Found` / `Failed to create token for "<repo>": Not Found`. Fix: add the repo under the installation's Repository access. |
| App installed but with "No repositories" | Same `Not Found` as above. Installation record exists but is empty. |
| App installed but with "No permissions" | Token creation **succeeds**, posting the review **fails** with 403s in later steps. Fix: add Contents R / Pull requests RW / Issues RW / Metadata R in App settings, then approve the updated permissions on the installation. |
| Caller workflow missing `permissions:` block | `startup_failure`, zero jobs, no logs. Happens when the org's default `GITHUB_TOKEN` is read-only. Fix: add the `permissions:` block from Step 2. |
| All correct | "Create GitHub App token" = `success`, "Resolve review identity" logs `Review identity: <your-app-slug>[bot]`. |

### `TRACKER_SECRETS` (optional, for Step 4.6 opt-in)

Single multiline secret with newline-separated `KEY=VALUE` pairs that your `fetch-issue.sh` reads as env vars. Without it, the hook runs but every referenced env var is empty — the Actions log will show a `::warning::` from `fetch-issue.sh`, and the review completes without external-spec context.

## Step 7: Test

Push the changes on a branch, open a PR, and verify the workflow triggers. Expected outcome:

- "Install review pipeline" step succeeds (composite action)
- "Validate review config" shows all six sections detected and no "references files that don't exist" warnings
- Context builder produces `context.md` and `test-plan.md`
- Dev env setup starts your services (look for `API ready at ...` in logs — not just `API=false`)
- All three reviewers (core, sweep, functional) produce output
- **Verdict: APPROVE** — because you followed Step 5's self-check. If you see findings here, read them and tighten the config; they're almost always real and point at something fixable.
