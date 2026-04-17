# Setup Claude PR Review

You are setting up the Panenco Claude PR review pipeline in this repository. Follow these steps in order.

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

Include a "Verify before flagging" section:

```markdown
## Verify before flagging

Before reporting a finding that cites a library or component, confirm it exists:
- Check `context.md` → "Repo capabilities" for available exports and dependencies.
- If the artifact is not listed, drop the finding or move to `uncertain_observations`.
```

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
- Docker compose: `docker compose up -d` + wait for readiness
- If no Docker: check for a cloud DB URL in `.env.example`, or note that functional testing requires a running DB
- If no DB at all: skip this step

**Step 2: Environment** — `.env` setup:
- If `.env.example` exists: `cp .env.example .env`
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

## Step 5: Verify secrets

Check if `CLAUDE_CODE_OAUTH_TOKEN` is configured as a repo or org secret. If not, instruct the user to run:
```
claude setup-token
```
and add the output as a repo secret named `CLAUDE_CODE_OAUTH_TOKEN`.

## Step 6: Test

Push the changes on a branch, open a PR, and verify the workflow triggers. Check:
- "Install review pipeline" step succeeds (composite action)
- "Validate review config" shows your sections detected
- Context builder produces `context.md`
- Dev env setup starts your services
- At least one reviewer produces findings or approves
