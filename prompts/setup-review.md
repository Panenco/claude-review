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
    with:
      pr_number: ${{ inputs.pr_number || '' }}
    secrets: inherit
```

Note: the `concurrency:` block and the `if:` draft guard are required — omitting
either causes recurring reviewer noise (cursor-style bots flag missing concurrency
alongside all other repo workflows, and the pipeline re-runs on every `synchronize`
against draft PRs, wasting budget).

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
# ports table. Exit non-zero to signal "dev env unavailable" — the
# pipeline downgrades to a warning and still runs core+sweep reviewers.

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
- **No `set -e`** at the top. The pipeline wraps the script in a subshell that tolerates non-zero exits; `set -e` adds surprise failures in things like `curl || true` idioms without giving you anything back.
- **One place, not two.** If you put commands here, delete the equivalent fenced bash blocks from `review-config.md`'s `## Functional validation` section (that section becomes prose-only — see Step 4 above).
- **Test it locally** before committing: run `bash .github/claude-review/dev-start.sh` and confirm the services actually come up on the ports you list in `### Known service ports`.

If the project has no services to start (pure-docs repo, lib-only package), skip this step entirely. The pipeline warns once and falls back to degraded mode (core + sweep reviewers run; no functional tester).

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

- [ ] `dev-start.sh` exists, is executable (`chmod +x`), and brings the env up when you run it locally.
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

Three secrets + one app install decision. **The install and the secrets are independent — miss either and the workflow breaks in a different way.** Walk through all four:

1. `CLAUDE_CODE_OAUTH_TOKEN` (required) — generate with `claude setup-token` and add as a repo or org secret. Without it the workflow fails at the first step with `::error::CLAUDE_CODE_OAUTH_TOKEN secret is not configured.`

2. `CLAUDE_REVIEW_APP_ID`, `CLAUDE_REVIEW_APP_PRIVATE_KEY`, `CLAUDE_REVIEW_APP_SLUG` (optional, recommended for orgs) — set all three as org secrets with "All repositories" visibility so new repos inherit them automatically via `secrets: inherit`. Without them the workflow still runs but posts as `github-actions[bot]`.

3. **Install the `panenco-claude-reviewer` GitHub App on the target repo (or org-wide, matching #2)**. This is separate from the secrets and both are required. Symptoms when each is missing:

   | Missing | Failure mode |
   |---|---|
   | Secrets only | "Create GitHub App token" step is **skipped** → `github-actions[bot]` posts the review. |
   | Secrets set, App not installed on repo | "Create GitHub App token" step **fails** with `RequestError [HttpError]: Not Found` / `Failed to create token for "<repo>": Not Found`. Downstream steps skip or abort. Fix: go to `github.com/organizations/<org>/settings/installations` → `panenco-claude-reviewer` → Configure → add the repo (or switch to "All repositories"). |
   | Both set correctly | "Create GitHub App token" = `success`, "Resolve review identity" logs `Review identity: panenco-claude-reviewer[bot]`. |

   Verify after the first PR run by opening the job log and grepping for `Review identity:` — it should print the App slug, not `github-actions`.

## Step 7: Test

Push the changes on a branch, open a PR, and verify the workflow triggers. Expected outcome:

- "Install review pipeline" step succeeds (composite action)
- "Validate review config" shows all six sections detected and no "references files that don't exist" warnings
- Context builder produces `context.md` and `test-plan.md`
- Dev env setup starts your services (look for `API ready at ...` in logs — not just `API=false`)
- All three reviewers (core, sweep, functional) produce output
- **Verdict: APPROVE** — because you followed Step 5's self-check. If you see findings here, read them and tighten the config; they're almost always real and point at something fixable.
