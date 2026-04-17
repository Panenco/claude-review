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
jobs:
  review:
    # Track the v1 floating tag so pipeline fixes propagate automatically to
    # every consumer repo. Supply-chain acceptance is declared in bugbot.md
    # under "Accepted supply-chain trade-offs" so the reviewer does not
    # re-flag `@v1 + secrets: inherit` on every PR.
    uses: panenco/claude-review/.github/workflows/pr-review.yml@v1
    with:
      pr_number: ${{ inputs.pr_number || '' }}
    secrets: inherit
```

## Step 3: Create bugbot.md

Create `bugbot.md` at the repo root with project-specific review rules. Keep it short — under 15 items. Focus on patterns that are:
- Non-obvious (a reviewer wouldn't know without being told)
- Specific to this project (not generic good practices)
- Things that have caused bugs before

Include a "Verify before flagging" section AND an "Accepted supply-chain trade-offs" section:

```markdown
## Verify before flagging

Before reporting a finding that cites a library or component, confirm it exists:
- Check `context.md` → "Repo capabilities" for available exports and dependencies.
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

This section tells the pipeline how to start the dev environment for end-to-end testing. Use fenced bash code blocks — the pipeline extracts and executes them.

Structure as numbered steps:

**Step 1: Database** — If the project uses a database:
- Docker compose: `docker compose up -d` + wait for readiness **with an explicit timeout error**. Never use a silent `for ... && break; sleep ...; done` pattern — the reviewer flags it as a bug. Use this shape:
  ```bash
  docker compose up -d
  READY=false
  for i in $(seq 1 15); do
    if docker compose exec -T <service> pg_isready -U <user> > /dev/null 2>&1; then
      READY=true; break
    fi
    sleep 2
  done
  if [ "$READY" != "true" ]; then
    echo "::error::Database never became ready in 30s"; exit 1
  fi
  ```
- If no Docker: check for a cloud DB URL in `.env.example`, or note that functional testing requires a running DB
- If no DB at all: skip this step

**Step 2: Environment** — `.env` setup:
- **First, `ls` the repo to find where `.env.example` actually lives.** Monorepos frequently have it under `apps/<name>/.env.example` rather than repo-root. Document the real path.
- If `.env.example` exists at the repo root: `cp .env.example .env`
- If it lives elsewhere (e.g. `apps/api/.env.example`): `cp apps/api/.env.example .env`
- Do NOT write `cp .env.example .env` without checking — that is exactly the class of finding the review catches.
- Document what env vars are needed and what they should contain

**Step 3: Migrations / codegen** — ORM setup:
- Prisma: `npx prisma generate && npx prisma migrate deploy`
- Drizzle: `npx drizzle-kit push`
- TypeORM: `npx typeorm migration:run`
- Django: `python manage.py migrate`

**Step 4: Dev server** — How to start:
- `pnpm run dev`, `npm run dev`, `python manage.py runserver`, etc.
- Document which ports each service runs on

**Step 5: Test data provisioning** — IMPORTANT: The functional tester needs data to test against.
- If a seed script exists: document it (`npx prisma db seed`, `python manage.py loaddata fixtures.json`)
- If no seed exists, provide SQL or API calls to create minimal test data. Think about what the functional tester needs:
  - A user account to authenticate with
  - At least one record per entity that the diff touches
- If using psql directly: `docker compose exec -T postgres psql -U postgres -d <dbname> -c "INSERT INTO ..."`
- The functional tester can also create data via API calls if endpoints exist

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

Before committing, re-read your own `.github/review-config.md` and confirm:

- [ ] Every path appearing in a `cp`, `source`, or `cat` command exists at the stated path. Run `ls <path>` to prove it.
- [ ] Every readiness wait loop either exits non-zero on timeout OR logs a `::warning::`/`::error::`. No bare `for ... && break; sleep ...; done` patterns.
- [ ] `### Auth` and `### Known service ports` sit at the top level of the file, not nested inside `## Functional validation`.
- [ ] Sign-in line starts with one of: `Sign in:`, `Sign-in:`, `Signin:`, `Log in:`, `Log-in:`, `Login:`.
- [ ] Auth `Method:` is one of `cookie`, `bearer`, `header`, `none`.
- [ ] The caller workflow tracks `@v1` AND `bugbot.md` contains an "Accepted supply-chain trade-offs" section that names `panenco/claude-review@v1 + secrets: inherit` as accepted. Both are needed — the @v1 for auto-propagation, the bugbot note so the reviewer doesn't re-flag it.

If any check fails, fix before committing. The pipeline's reviewer will catch these on the first PR and block merge with `REQUEST_CHANGES`.

## Step 6: Verify secrets

Three secrets + one app install decision:

1. `CLAUDE_CODE_OAUTH_TOKEN` (required) — generate with `claude setup-token` and add as a repo or org secret.
2. `CLAUDE_REVIEW_APP_ID`, `CLAUDE_REVIEW_APP_PRIVATE_KEY`, `CLAUDE_REVIEW_APP_SLUG` (optional, recommended for orgs): install the `panenco-claude-reviewer` GitHub App on this repo (or org-wide), then add all three secrets. Without them, the workflow falls back to posting as `github-actions[bot]`; with them, it posts as `panenco-claude-reviewer[bot]` and can dismiss stale reviews on new pushes. Installing the App alone is not enough — the three secrets must be set too.

## Step 7: Test

Push the changes on a branch, open a PR, and verify the workflow triggers. Expected outcome:

- "Install review pipeline" step succeeds (composite action)
- "Validate review config" shows all six sections detected and no "references files that don't exist" warnings
- Context builder produces `context.md` and `test-plan.md`
- Dev env setup starts your services (look for `API ready at ...` in logs — not just `API=false`)
- All three reviewers (core, sweep, functional) produce output
- **Verdict: APPROVE** — because you followed Step 5's self-check. If you see findings here, read them and tighten the config; they're almost always real and point at something fixable.
