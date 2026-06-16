# Setup Claude PR Review

You are setting up the Panenco Claude PR review pipeline in this repository. Follow these steps in order.

## Principles (read once, apply throughout)

Your output must pass the pipeline's own review on the first commit — **no findings, verdict `APPROVE`**. To achieve that:

1. **Verify every path you write.** Before referencing any file in `cp`, `source`, or `cat`, actually `ls` it. A broken path fails the bring-up hard or feeds the reviewer wrong context; don't ship one.
2. **Prefer fail-fast patterns over silent timeouts.** Every readiness wait loop must explicitly log and warn (or exit) when it times out, not just `break` out. "Silently succeeds on timeout" is the #1 bug the reviewer catches in review-configs.
3. **Heading level is rigid: use `### Auth` and `### Known service ports` (level 3, with three `#`).** These sections must use the `###` heading level exactly — the pipeline greps for them literally (the context builder's config-gap check looks for `^### Auth`, and the dev-env probe reads the ports table), and getting the level wrong surfaces a "Setup notes" line in every review body. Place them *after* `## Functional validation` closes — i.e., after its last `### Step N` subsection — but keep the level at `###`. They are "sibling to `## Functional validation` in document flow" but "one level deeper in heading numbering"; when the prompt below says "peer to `## Functional validation`", read it as placement, not heading level.
4. **Track the `@v3` tag for the reusable workflow** so pipeline fixes auto-propagate, and declare the supply-chain trade-off as accepted in `bugbot.md` so the reviewer doesn't re-flag it on every PR (see Step 3 template). `@v1` is frozen and no longer receives fixes — new repos use `@v3`.
5. **Match the exact phrasing the auto-extractor expects** for sign-in lines and auth methods (listed in Step 4 → `### Auth`).
6. **A runtime repo must ship a working `dev-start.sh` — there is no degraded/judges-only fallback.** If this repo runs an app, the bring-up is mandatory: a runtime PR with no smoke evidence is blocked `REQUEST_CHANGES` by the runtime-evidence gate. Don't treat "skip the script" as an escape hatch. Build the bring-up, make it cache-efficient, and prove it via the local loop + council review in Step 4.5 before committing. (Only genuinely non-runtime repos — pure-docs, lib-only — omit the file.)

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
  pull_request_target: # warms Playwright cache in main scope
  workflow_dispatch:
    inputs:
      pr_number:
        description: 'PR number to review'
        required: true
        type: string

concurrency:
  group: claude-review-${{ github.event_name }}-${{ github.event.pull_request.number || github.run_id }}
  cancel-in-progress: true

jobs:
  review:
    if: github.event_name == 'workflow_dispatch' || github.event.pull_request.draft == false
    uses: panenco/claude-review/.github/workflows/pr-review.yml@v3
    permissions:
      contents: write
      pull-requests: write
      issues: write
      packages: read
    with:
      pr_number: ${{ inputs.pr_number || '' }}
    secrets: inherit
```

### Speeding up bring-up: the `dev_cache_*` inputs (wire these for repos with a runnable app)

The functional tester runs `dev-start.sh` on a fresh runner every review, so any compiled/downloaded artefacts (a Gradle/Maven build, a Go module cache, a Rust `target`, a pip wheel cache) rebuild cold — often the single biggest chunk of bring-up wall-time. The pnpm/npm store is already cached for you; everything else is opt-in and stack-agnostic via four `with:` inputs. Wire them whenever Step 4.5 produced a `dev-start.sh` that compiles or downloads anything beyond the pnpm/npm store:

```yaml
    with:
      pr_number: ${{ inputs.pr_number || '' }}
      dev_cache_paths: |          # what to cache (newline-separated). Cache the dependency dir, NOT whole build trees.
        ~/.gradle/caches/modules-2
        ~/.gradle/wrapper
      dev_cache_key_files: |      # files whose contents key the cache (globs, ** ok) — NOT a pre-hashed key
        **/gradle/libs.versions.toml
        **/*.gradle*
        **/gradle-wrapper.properties
      dev_cache_key_prefix: gradle
      dev_cache_warm_command: cd backend/java && JAVA_HOME=$JAVA_HOME_21_X64 ./gradlew :api:dependencies --no-daemon
```

**Pass globs, not a pre-hashed key.** A reusable-workflow caller's `with:` has no runner or checkout, so `${{ runner.os }}` / `${{ hashFiles() }}` aren't available there (they fail at startup). The workflow computes the key — `<RUNNER_OS>-<prefix>-<hash of dev_cache_key_files>`, restore-keys `<RUNNER_OS>-<prefix>-` — inside the jobs, where a checkout exists.

**Derive all four from the stack you detected in Step 1.** Point `dev_cache_paths` at the dependency dir your `dev-start.sh` cold-builds; point `dev_cache_key_files` (globs) at the lockfiles/build descriptors that should rotate the cache; set `dev_cache_key_prefix` per stack so unrelated caches don't collide; make `dev_cache_warm_command` a cheap, PR-code-free dependency *resolve/prefetch* (not a full build) — it runs in `main` scope against the trusted base ref, only on a cache miss, and is what makes the cache available to *every* PR, not just re-pushes of the same branch. The warm-cache job is a vanilla `ubuntu-latest` with only Node set up, so the warm command owns its toolchain (`$JAVA_HOME_21_X64`, `$GOROOT_1_22_X64`, … or install what it needs).

| Stack | `dev_cache_paths` | `dev_cache_key_files` | `dev_cache_key_prefix` | `dev_cache_warm_command` |
|---|---|---|---|---|
| Gradle | `~/.gradle/caches/modules-2`, `~/.gradle/wrapper` | `**/gradle/libs.versions.toml`, `**/*.gradle*`, `**/gradle-wrapper.properties` | `gradle` | `./gradlew :api:dependencies --no-daemon` |
| Maven | `~/.m2/repository` | `**/pom.xml` | `maven` | `mvn -q dependency:go-offline` |
| Go | `~/.cache/go-build`, `~/go/pkg/mod` | `**/go.sum` | `go` | `go mod download` |
| Rust | `~/.cargo`, `target` | `**/Cargo.lock` | `rust` | `cargo fetch` |
| pip | `~/.cache/pip` | `**/requirements*.txt`, `**/poetry.lock` | `pip` | `pip download -r requirements.txt -d /tmp/whl` |

**Keep it short-lived.** The repo shares a 10 GB Actions-cache budget (LRU + 7-day idle eviction). Cache the dependency dir, not whole build trees, and let the key rotate via the lockfile globs so entries churn only when dependencies change. Omit `dev_cache_warm_command` (keep the other two) if your own main CI already writes a cache under the same prefix — caches are repo-scoped, so the functional job's restore reuses it. Leave all four unset to disable caching entirely.

Note: the `concurrency:` block and the `if:` draft guard are required — omitting
either causes recurring reviewer noise (cursor-style bots flag missing concurrency
alongside all other repo workflows, and the pipeline re-runs on every `synchronize`
against draft PRs, wasting budget). The `permissions:` block is also required;
its omission is the #1 startup failure for repos in orgs with the GitHub-default
read-only `GITHUB_TOKEN` scope (see inline comment above). `actions: read` is
**not** needed: round-2 state comes from the PR's own review history, not from
workflow artifacts — existing callers that still grant it are unaffected.

**If `secrets: inherit` fails with `Secret CLAUDE_CODE_OAUTH_TOKEN is required, but not provided while calling`** — even though the secret is clearly set on the repo — swap `inherit` for the explicit form as a fallback:

```yaml
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      # Optional pool — see Step 6. Either CLAUDE_CODE_OAUTH_TOKEN or
      # CLAUDE_CODE_OAUTH_TOKENS must be set; the explicit form requires
      # listing every secret you want forwarded.
      CLAUDE_CODE_OAUTH_TOKENS: ${{ secrets.CLAUDE_CODE_OAUTH_TOKENS }}
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

- `panenco/claude-review/.github/workflows/pr-review.yml@v3` with `secrets: inherit` is accepted. Upstream is first-party (Panenco org) and the mutable tag enables single-point propagation of pipeline fixes across every consumer repo. Do NOT flag this as a security finding — pinning to a SHA here was explicitly rejected in favor of easier upstream updates.
```

The "Accepted supply-chain trade-offs" line is what keeps the reviewer quiet about `@v3 + secrets: inherit`. Leave it in on every repo that uses `@v3`.

### Optional: opt back into test-coverage / a11y emphasis

By default, the shipped skills do **not** emit `missing-test`, `weak-test`, or `a11y-violation` findings — they're project-opt-in. This keeps reviews quiet on routine PRs (a sibling-spec convention from one project shouldn't fire false positives on another, and axe-core on every page surfaces violations on shared components the PR didn't touch). If your project genuinely wants these enforced, add a section to `bugbot.md` describing your project's convention:

```markdown
## Test-coverage convention

Every non-trivial changed handler/hook/util/service in `src/api/**` or `src/services/**`
must have a sibling spec at `<filename>.spec.ts` or `<filename>.test.ts`. PRs that
add such files without a sibling spec should get a `missing-test` finding pointing
at the topmost added line of the new module. Out of scope: tests, generated code,
config files.

## Accessibility focus

Frontend changes that touch form labels, ARIA attributes, semantic markup, or
keyboard handlers should run an axe-core WCAG 2.1 AA audit on the changed page.
The functional tester picks this up via the test-plan's `a11y: true` flag — the
context builder already sets it when the diff matches those triggers; no action
needed here unless you want it ALWAYS on (in which case add: "Always treat the
test plan as `a11y: true` regardless of diff").
```

Without these sections, the bot stays quiet about test/a11y — the perimeter is the diff, and the conventions are yours to declare.

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

## Step 4.5: Determine the runtime surface, then build dev-start.sh

Every repo with a runnable app **must** ship `.github/claude-review/dev-start.sh` — the first-class contract the pipeline uses to bring up the dev environment (install deps, start services, block until they respond). There is **no opt-out for app-bearing repos**: a runtime PR with no smoke evidence is blocked `REQUEST_CHANGES` by the runtime-evidence gate. Build one that is **efficient (cache-enabled), locally verified, and council-reviewed** for THIS project.

### 4.5.0 — Determine the runtime surface (evidence-based, not a guess)

Decide which of three cases this repo is in. Gather evidence, don't assume:
- `ls` the repo root + app/package dirs. Read every `package.json` (root + sub-packages) for `dev` / `start` / `start:dev` / `serve` scripts. Check for `docker-compose.yml`, `Dockerfile`, `main.go`/`cmd/`, `manage.py`, `*.csproj`, `Cargo.toml` with a `[[bin]]`, or any long-running HTTP entrypoint.
- Check for a bound port / health endpoint (NestJS, Express, Next.js, Django, FastAPI, Spring, Go net/http, …) or a service in compose.
- Check `tests/` for executable `*.sh`.

Classify:
1. **Runnable app** (binds a port / serves requests) → 4.5.1 is MANDATORY. Case 1 takes precedence: if the repo BOTH binds a port AND has `tests/*.sh`, build the dev-start (case 1) — the tests are supplementary, not a substitute.
2. **App-less but has executable `tests/*.sh`** → pipeline-self-test path, see 4.5.3.
3. **Genuinely nothing runnable** (pure-docs / pure-library) → document explicitly, see 4.5.3. Do not invent an app.

"I didn't find a dev script" is NOT a determination — prove there is no runnable surface before choosing case 2/3. Record the determination + evidence in your handoff.

### 4.5.1 — Build an efficient, cache-enabled dev-start (mandatory for case 1)

Create `.github/claude-review/dev-start.sh` and `chmod +x` it — the commands this repo actually needs, no stack guessing. The template below is Node/compose-shaped; **delete the steps your stack doesn't use** and substitute the real ones (a Go/Python/JVM repo won't have `corepack`/`pnpm`):

```bash
#!/usr/bin/env bash
set -uo pipefail

# dev-start.sh — Bring up the dev environment for the Claude review pipeline's
# functional tester. The pipeline runs this in a subshell, then probes the URLs
# in review-config.md's ### Known service ports table. Non-zero exit fails the
# Pre-start step hard and stops the whole review. Build it to boot CLEANLY and
# FAST from a clean checkout — the dev_cache_* inputs you wire in Step 2 restore
# your build/dependency cache before this runs, so compile/install against it.

# <Step 1 — services, e.g. Postgres> — start, then block until ready with an
# explicit fail-fast (no bare retry loop that silently falls through):
docker compose up -d postgres
READY=false
for i in $(seq 1 30); do
  if docker compose exec -T postgres pg_isready -U <user> -d <db> >/dev/null 2>&1; then READY=true; break; fi
  sleep 2
done
[ "$READY" = true ] || { echo "::error::Postgres never became ready in 60s"; docker compose logs postgres | tail -50; exit 1; }

# <Step 2 — install deps> — pin the package manager (pnpm/yarn: set
# packageManager in root package.json + corepack enable so lockfile semantics
# match local). The pnpm/npm store is cached for you.
corepack enable
pnpm install --frozen-lockfile

# <Step 3 — migrations / codegen BEFORE the server> (else tsc/nest floods TS2307):
# Prisma: pnpm exec prisma generate && pnpm exec prisma migrate deploy | Drizzle: drizzle-kit push
# TypeORM: typeorm migration:run | Django: python manage.py migrate

# <Step 4 — start services>
pnpm run dev > /tmp/dev.log 2>&1 &

# <Step 5 — block until API listens, fail fast>
API_READY=false
for i in $(seq 1 60); do
  if curl -fsS http://localhost:<port>/<health> >/dev/null 2>&1; then API_READY=true; break; fi
  sleep 2
done
[ "$API_READY" = true ] || { echo "::error::API never came up at http://localhost:<port>/<health> in 120s"; tail -200 /tmp/dev.log; exit 1; }
echo "API ready at http://localhost:<port>/<health>"
```

Rules:
- **Readiness loops fail fast** — every wait loop ends in `[ "$X" = true ] || { echo ::error:: …; exit 1; }`. No bare `for … && break; sleep; done` that silently falls through.
- **No `set -e`** — the subshell propagates your explicit `exit N`; `set -e` adds surprise failures in `curl || true` / `grep` pipes.
- **Generated code first** — if tests import a generated SDK/GraphQL client/`openapi-generator` output not checked in, run the generator before the server (valcori runs `pnpm run generate-sdk` before `start:dev` for this reason).
- **One place** — commands live here; `review-config.md`'s `## Functional validation` stays prose only (Step 4).
- **Make it FAST, not just correct** — cold Gradle/Maven/Go/Rust/pip builds are the biggest bring-up cost. You MUST wire the `dev_cache_*` inputs (Step 2) for this repo's stack so the build/dependency cache is restored before this runs. A dev-start that boots cold every run is not done.

### 4.5.2 — Iterate to the optimal bring-up (local loop → council review until consensus)

A `dev-start.sh` that merely boots is not the bar — the bar is the *optimal* bring-up for THIS project: correct, and as fast as the cache config makes it. Do not commit until both the loop and the council pass.

**Loop locally until satisfied.** From a clean checkout (fresh install, empty build dir, no dev-server processes on the target ports), run `bash .github/claude-review/dev-start.sh`. It must exit 0 and the service must answer on every `### Known service ports` URL, and auth must come up (you can hit the sign-in path you documented in `### Auth`). Time it; if the slow part is dependency download or a non-PR compile, wire/confirm the `dev_cache_*` inputs (Step 2) cover those artefacts, then re-run and confirm the warm path is fast. Fix what breaks (circular imports, missing codegen, bad `DATABASE_URL`, unpinned package manager) and re-run from clean. Repeat until correctness AND speed satisfy you. If it doesn't boot locally it won't boot in CI.

**The one sanctioned exception to local exit-0:** if the app boots only with credentials you don't have locally (a private registry token, cloud keys, a third-party API key), you cannot complete the local boot. Do NOT hardcode a placeholder to force a green run. Instead: write and statically verify the script, run the council on it, emit the `DEV_ENV_SECRETS` to-do listing the exact vars (see Secrets below), and document in your handoff "local boot blocked on secrets — validated by inspection + council only." Commit on that basis. This is the only case where committing without a green local boot is allowed.

**Then convene a council.** Once it passes locally, dispatch **3 independent reviewers in parallel** (Task tool, `subagent_type: general-purpose`), each given the drafted `dev-start.sh`, the `dev_cache_*` block, `review-config.md`'s `## Functional validation` + `### Known service ports`, and the repo. One lens each:
- **Correctness** — every readiness loop fails fast; codegen before the server; all `cp`/`source`/`cat` paths real (`ls` to prove); probed ports match what services bind; `set -e` absent; package manager pinned.
- **Efficiency** — `dev_cache_paths` are dependency dirs not whole build trees; `dev_cache_key_files` globs cover the lockfiles/descriptors; the warm command is a cheap PR-code-free prefetch matching the stack; nothing the cache should carry is rebuilt cold.
- **Project fit** — this is the bring-up THIS repo needs (right pm pin, migrations, seed/auth), no leftover stack-guessing or dead steps.

Each reviewer returns **blocking flaws** (file:line) + optional notes. A **blocking flaw** is one that would make the bring-up fail, hang, silently pass, or rebuild a cacheable artefact cold — everything else (style, "could be marginally cheaper") is a note. **Consensus = a round where no reviewer raises a blocking flaw.** If any does, fix it and run another round. **Cap at 3 rounds**; if blocking flaws remain after the third, commit the best version and write the unresolved flaws into the PR description as known limitations (don't silently ship a worse script). Notes never hold a round. Only after a consensus round (or the cap) do you proceed to Step 5 and commit.

### 4.5.3 — App-less repos (cases 2 and 3)

Only after 4.5.0 PROVES no runnable app:
- **Executable `tests/*.sh`** (case 2) → the pipeline runs them as a self-test; point `## Functional validation` prose at those tests; do not fabricate a server.
- **Truly nothing runnable** (case 3, pure-docs/pure-library) → do NOT create `dev-start.sh`, and document explicitly in your handoff: "This repo has no runnable surface; its non-runtime PRs review cleanly, but any PR the planner judges to have runtime behaviour is blocked by the runtime-evidence gate — the intended forcing function. If a runnable surface is added later, a `dev-start.sh` becomes mandatory."

An empty-but-present `dev-start.sh` always fails the step — commit a real one (cases 1/2) or none (case 3).

### Secrets for dev-start.sh

If bring-up needs creds that aren't checked-in defaults (private registry token, cloud SDK keys, a third-party API key the dev server needs at boot), don't hardcode them — emit a to-do:

> "**Add a repo secret named `DEV_ENV_SECRETS`** with newline-separated `KEY=VALUE` pairs. The pipeline exports each line as an env var to `dev-start.sh` (and the legacy `## Functional validation` bash blocks + `### Auth` eval). Example:
> ```
> NPM_TOKEN=npm_xxxxx
> AWS_ACCESS_KEY_ID=AKIA...
> AWS_SECRET_ACCESS_KEY=...
> # values exposed verbatim — do not wrap in quotes
> ```
> Without it, `$VAR` references in `dev-start.sh` are empty and the script fails at the first command that needs them — same fail-hard semantics as any other dev-start error."

Detect this passively: grep the `dev-start.sh` you drafted for `$VAR` references that aren't shell built-ins or values you set inside the script. If any look external (anything ending `_TOKEN`/`_KEY`/`_SECRET`, registry/cloud creds), surface the to-do. If self-contained (compose-defined creds, no external API), skip it.

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
   - "**Create `.github/claude-review/fetch-issue.sh`**. It reads the pre-extracted ticket references at `/tmp/external-issue-candidates.json`, calls your tracker, and prints markdown to stdout. See the README section **External issue trackers** (`.github/claude-review/fetch-issue.sh`) for the full contract, the candidates-file schema, and a provider-neutral skeleton to adapt."
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

**Be explicit and literal.** The context builder turns this section (plus the dev-env outputs) into a ready-made auth recipe so the functional tester spends zero budget rediscovering auth — exact endpoints, exact seeded credentials, exact method. A `Sign in:` line with a `POST <endpoint>` + `{JSON body}` is the canonical shape.

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

### Known dev-env quirks (optional)

If the dev environment has known failure modes no PR causes — seed-data gaps, SPA route 404s, flaky auth paths — list them under a `### Known dev-env quirks` section (same level-3, file-root placement as `### Auth`). The pipeline copies it verbatim into the functional tester's test plan, so matching failures are treated as expected instead of reported as findings.

**Section placement matters, and heading level is rigid.** `### Auth` and `### Known service ports` use **heading level 3 (three `#` — literally `###`)** and sit at **the root of the file, after `## Functional validation` has closed** (i.e., after its last `### Step N` subsection). They are placement-peers of `## Functional validation` — same depth in document flow — but **not** heading-peers: keep them at `###`, not `##`. The pipeline greps for these headings literally (the context builder's config-gap check and the dev-env probe).

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

Do **not** promote to `## Auth` / `## Known service ports` — the pipeline's `^### ` greps miss them and a "Setup notes" line lands in every review body. Do **not** nest them under `## Functional validation` either — when they live inside, the Functional-validation extractor picks up Auth code it shouldn't. Keep them exactly as **level-3 headings at the file's top level, immediately after the last `### Step N`**.

## Step 5: Verify self-check

Before committing, re-read your own `.github/review-config.md` and `.github/claude-review/dev-start.sh` and confirm:

- [ ] `dev-start.sh` exists, is executable (`chmod +x`), boots from a clean checkout (exit 0, services answer on every `### Known service ports` URL), AND has passed a council-consensus round per Step 4.5 (no reviewer raised a blocking flaw, or the 3-round cap was hit with remaining flaws documented in the PR). If it doesn't boot locally it won't boot in CI, and a runtime PR with no working bring-up is blocked `REQUEST_CHANGES` by the runtime-evidence gate. (Exception: an app that boots only with creds you lack locally — verified by inspection + council, with a `DEV_ENV_SECRETS` to-do emitted, per Step 4.5.2.)
- [ ] If bring-up rebuilds heavy non-PR artefacts cold (Gradle/Maven, Go modules, Rust `target`, an SDK generator), the `dev_cache_*` inputs are wired in the caller workflow and a warm re-run is measurably faster — cache key is your lockfile globs, cached paths are dependency dirs (not whole build trees).
- [ ] If your repo generates code from an openapi spec / Prisma / Drizzle / GraphQL schema / etc. at dev-time, `dev-start.sh` runs that generator **before** the dev server. Missing codegen = TS errors = compile noise (and sometimes blocks boot outright — see valcori's historical `src/sdk` case).
- [ ] `review-config.md`'s `## Functional validation` section is **prose only** — no fenced `bash` blocks. Commands live in `dev-start.sh`.
- [ ] Every path appearing in a `cp`, `source`, or `cat` command (in either file) exists at the stated path. Run `ls <path>` to prove it.
- [ ] Every readiness wait loop in `dev-start.sh` either exits non-zero on timeout OR logs a `::warning::`/`::error::`. No bare `for ... && break; sleep ...; done` patterns.
- [ ] `### Auth` and `### Known service ports` sit at the top level of `review-config.md`, not nested inside `## Functional validation`.
- [ ] `### Auth` documents the sign-in endpoint, seeded credentials, and method verbatim — a `Sign in:` line with `POST <endpoint>` + JSON body is the canonical shape.
- [ ] Auth `Method:` is one of `cookie`, `bearer`, `header`, `none`.
- [ ] The caller workflow tracks `@v3` AND `bugbot.md` contains an "Accepted supply-chain trade-offs" section that names `panenco/claude-review@v3 + secrets: inherit` as accepted. Both are needed — the @v3 for auto-propagation, the bugbot note so the reviewer doesn't re-flag it.
- [ ] The caller workflow has a `concurrency:` block (`group: claude-review-${{ github.event_name }}-${{ github.event.pull_request.number || github.run_id }}`, `cancel-in-progress: true`) AND a draft guard (`if: github.event_name == 'workflow_dispatch' || github.event.pull_request.draft == false`). Missing either is reviewer noise every PR. `github.event_name` in the group key keeps `pull_request` and `pull_request_target` in separate groups so the warm-cache run doesn't cancel the review (or vice versa).

If any check fails, fix before committing. The pipeline's reviewer will catch these on the first PR and block merge with `REQUEST_CHANGES`.

## Step 6: Verify secrets and App install

The OAuth token is required for every repo; the App-token path is how reviews get posted under a branded bot identity instead of `github-actions[bot]`. **Which track you follow depends on whether the repo is inside the Panenco org or external.** Pick one:

### Track A — Repos inside the Panenco org (short path)

1. **One of these two secrets is required** — without either, the workflow's `Pick Claude OAuth token` step fails with `::error::No Claude OAuth token configured.`

   - `CLAUDE_CODE_OAUTH_TOKEN` — single token. Generate with `claude setup-token` and add as a repo or org secret. The simple/default setup.
   - `CLAUDE_CODE_OAUTH_TOKENS` — newline-separated pool. Use when one Claude.ai subscription's 5-hour rate-limit window keeps blocking reviews: run `claude setup-token` against each of several accounts and put the resulting tokens (one per line) in a single multi-line secret. The picker probes each at job start with a cheap Haiku call, filters to tokens whose 5-hour window still has capacity, and randomly picks one. The pool wins when both secrets are set.

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

- `CLAUDE_CODE_OAUTH_TOKEN` — generate with `claude setup-token`. (Or set `CLAUDE_CODE_OAUTH_TOKENS` instead — newline-separated pool of tokens, one per Claude.ai subscription. See Track A's note for when to prefer the pool form.)
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
| `CLAUDE_CODE_OAUTH_TOKEN` (and no `CLAUDE_CODE_OAUTH_TOKENS`) | `Pick Claude OAuth token` step fails: `::error::No Claude OAuth token configured.` |
| `CLAUDE_CODE_OAUTH_TOKENS` set but every token exhausted | `Pick Claude OAuth token` step fails with a per-token status table (`status=blocked` / `status=warning` / `status=invalid` plus `resetsAt`). Wait for a window to reset, or rotate one of the tokens with `claude setup-token` against a different Claude.ai account. |
| `CLAUDE_REVIEW_APP_*` secrets | "Create GitHub App token" step is **skipped** → `github-actions[bot]` posts the review. Functionally OK, just the wrong identity. |
| `CLAUDE_REVIEW_APP_*` secrets set, App not installed on repo | "Create GitHub App token" step **fails** with `RequestError [HttpError]: Not Found` / `Failed to create token for "<repo>": Not Found`. Fix: add the repo under the installation's Repository access. |
| App installed but with "No repositories" | Same `Not Found` as above. Installation record exists but is empty. |
| App installed but with "No permissions" | Token creation **succeeds**, posting the review **fails** with 403s in later steps. Fix: add Contents R / Pull requests RW / Issues RW / Metadata R in App settings, then approve the updated permissions on the installation. |
| Caller workflow missing `permissions:` block | `startup_failure`, zero jobs, no logs. Happens when the org's default `GITHUB_TOKEN` is read-only. Fix: add the `permissions:` block from Step 2. |
| All correct | "Create GitHub App token" = `success`, "Resolve review identity" logs `Review identity: <your-app-slug>[bot]`. |

### `TRACKER_SECRETS` (optional, for Step 4.6 opt-in)

Single multiline secret with newline-separated `KEY=VALUE` pairs that your `fetch-issue.sh` reads as env vars. Without it, the hook runs but every referenced env var is empty — the Actions log will show a `::warning::` from `fetch-issue.sh`, and the review completes without external-spec context.

### `DEV_ENV_SECRETS` (optional, for Step 4.5 when dev-start.sh needs creds)

Single multiline secret with newline-separated `KEY=VALUE` pairs exposed as env vars to `.github/claude-review/dev-start.sh` (and to the legacy `## Functional validation` bash blocks + `### Auth` eval). Use it for registry tokens, cloud SDK keys, or third-party API creds your bring-up needs at boot. Without it, references in `dev-start.sh` to these env vars are empty — the script will fail hard at the first command that depends on them, and the whole review stops (same fail-hard semantics as any other `dev-start.sh` error). Skip if your bring-up is self-contained.

## What blocks a PR (v3 forcing-functions)

Beyond a judge finding a `critical`/`major`, three structural gates can post a blocking `REQUEST_CHANGES` on their own — knowing them up front avoids surprise on a repo's first PRs:
- **Oversized** — > 3000 non-generated lines or > 60 files: no judges run, the bot returns a canned "split this PR" `REQUEST_CHANGES`. Override per-PR with the `deep-review` label; bypass a known-bundled PR with `skip-review`. Re-evaluated each push — split it and the block clears.
- **No runtime evidence** — a PR the planner judged has runtime behaviour to exercise, with no passing smoke run (no `dev-start.sh`, or bring-up failed/crashed): blocking `REQUEST_CHANGES`. This is why a repo shipping a running app MUST commit a working `dev-start.sh` (Step 4.5). Docs-only / non-runtime PRs are exempt; bots are NOT.
- **No spec** — no linked issue, PRD, external-tracker spec, or substantive PR-body prose: APPROVE is withheld → `COMMENT` (not a hard block). Bot-authored PRs waive this. Link an issue or paste acceptance criteria to clear it.

All three resolve fresh each round — fix the cause and the next push re-evaluates.

## Step 7: Test

Push the changes on a branch, open a PR, and verify the workflow triggers. Expected outcome:

- "Install review pipeline" step succeeds (composite action)
- The review body carries **no "Setup notes" line** — the context builder emits one when it detects config gaps (missing `dev-start.sh`, missing `### Auth`); a correct config stays silent
- Context builder produces `context.md` and `test-plan.md`
- Dev env setup starts your services (look for `API ready at ...` in logs — not just `API=false`)
- "Install functional-tester subagent" copies the pipeline's static `agents/review-functional-tester.md` to `~/.claude/agents/` on the runner, templated with `inputs.model_functional` (this is what gives the functional tester its own scoped Playwright MCP server — don't commit such a file to your repo)
- Orchestrator runs the judges in parallel and (when applicable) the functional tester. A **full** review runs two judges (Opus + Haiku) that debate to a single deduped findings list. A **light** review runs ONE judge: **Opus** on a small runtime PR, Sonnet on a release/promotion PR — light is not a weaker review.
- Functional testing runs on **every runtime diff**, including small PRs (a small runtime PR gets the single-judge `light` tier — one **Opus** judge plus a quick functional smoke; the test planner picks `skip`/`quick` per surface). Oversized PRs (> 3000 non-generated lines or > 60 files) are different — they aren't lightly reviewed any more: the orchestrator returns a canned `REQUEST_CHANGES` asking to split the PR and runs no judges (add the `deep-review` label to force a full review instead). This is why `dev-start.sh` matters even for repos that mostly ship small PRs — without it, a runtime PR carries no smoke evidence and the runtime-evidence gate blocks it with `REQUEST_CHANGES` (docs-only / non-runtime PRs are exempt). The tester is bounded by a wall-clock budget (`functional_budget_seconds`, default 8 min) so it always writes findings before the job's time ceiling rather than getting cancelled mid-run.
- A heavy `dev-start.sh` (Docker images + JDK/Gradle + a large monorepo's `node_modules`) can exhaust the hosted runner's ~14 GB free disk and fail the job with `No space left on device` after the review already ran. The workflow reclaims disk before the bring-up via the `free_disk_space` input: `safe` (default) clears tooling no Linux app needs (CodeQL/Haskell/Swift, ~12 GB) and is safe for every repo; set it to `aggressive` (also drops Android SDK + .NET, ~25 GB) **only if your `dev-start.sh` doesn't build Android or .NET**; `off` disables it.
- PRs opened by bots (renovate, dependabot) are skipped cleanly by default — green check, no review, no crash banner. To review a bot's PRs, pass `allowed_bots: <login>` (without the `[bot]` suffix) on the caller's `with:` block; for dependabot also add the OAuth token to *Dependabot secrets*. Bot-authored PRs waive the manual-spec gate.
- For PRs with UI surface, the functional tester's Turn 1 is an MCP smoke check (`mcp__playwright__browser_navigate` to `about:blank`). If MCP is unavailable, the run hard-fails with `overall: CRASH` and the review is flagged `requires_human_review`. Silent fallback to curl/psql is forbidden — a curl-only PASS on a UI fix is the bug we're guarding against.
- **Verdict: APPROVE** — because you followed Step 5's self-check. If you see findings here, read them and tighten the config; they're almost always real and point at something fixable.
- The workflow check is **green whenever a review posted**, even on `REQUEST_CHANGES` — the verdict lives in the PR review (use branch protection's required reviews to make it block merges). A red check means the pipeline itself failed.

## Verdict ladder (round 2)

When you push follow-up commits to the same PR, the bot runs a round-2 review that looks at the diff since its previous review. The previous round's verdict and reviewed commit come straight from the PR's own review history (no artifacts, no extra permissions), and the round-2 pass is scoped to what changed since — that scoping is what makes follow-up rounds cheap. The review plan itself resolves fresh each round from the PR's overall shape, and the `deep-review` label still forces a full review. Verdict rules:

- New `critical` or `major` finding → `REQUEST_CHANGES`.
- Prior `REQUEST_CHANGES` blocker still present → `REQUEST_CHANGES` (keeps until you actually fix it).
- A prior block that carried **no findings** — an oversized "split this PR" or a no-runtime-evidence block — is re-evaluated from scratch each round, not pinned. Split the PR (or wire up `dev-start.sh` and get a passing smoke run) and the next push reaches its real verdict.
- Prior `REQUEST_CHANGES` resolved + no new blockers → per-PR verdict (APPROVE if clean, COMMENT if minor findings remain).
- Prior `COMMENT` + per-PR verdict APPROVE → `APPROVE`. The bot does NOT pin a follow-up to COMMENT just because the prior round was COMMENT — fixing the one issue the bot flagged should land you on green.
- You dismissed the prior review → the bot drops its **minor/note** findings (your call on low-severity) but does NOT wave off a **critical/major**: those re-block if they still hold at HEAD unless the bot agrees they were wrong.
- You disputed a finding with a reason (a thread reply, a general PR comment, or a review body) and didn't change the code → the bot **evaluates your explanation against the code at HEAD** rather than just accepting or ignoring it. A **minor/note** is dropped on any reasonable explanation; a **critical/major** is dropped only if the bot agrees it's actually wrong (a plausible-but-unverified claim, or "fixed in another PR" without the code, keeps it blocking). Either way the bot replies in-thread with its reasoning, and the next review lists the outcome under "Dropped after author rebuttal" or "Still present after your reply" — never silently disappearing or nagging forever.

Severities matter: `critical` and `major` block and are the only judge findings posted as inline comments (max 12, plus functional failures); `minor` and `note` appear as bullets in the review body and never gate APPROVE. A doc-only nit (typo, wrong package name in a paragraph) is `note` — it shows up in the review but won't hold the PR at COMMENT. If the bot grades a doc nit as `minor` or higher, that's a calibration bug worth flagging in feedback.
