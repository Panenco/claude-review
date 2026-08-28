# Setup Claude PR Review

You are setting up the Panenco Claude PR review pipeline in this repository. Follow these steps in order.

## Principles (read once, apply throughout)

Your output must pass the pipeline's own review on the first commit — **no findings**. Aim for that, not for a green `APPROVE`: v4 approves only when the scan can argue a human pass over the diff changes nothing, on a diff that touches no sensitive path — and `.github/` is a sensitive path, so a setup PR essentially can't get there. A `COMMENT` with zero findings is the good outcome. To achieve it:

1. **Verify every path you write.** Before referencing any file in `cp`, `source`, or `cat`, actually `ls` it. A broken path fails the bring-up hard or feeds the reviewer wrong context; don't ship one.
2. **Prefer fail-fast patterns over silent timeouts.** Every readiness wait loop must explicitly log and warn (or exit) when it times out, not just `break` out. "Silently succeeds on timeout" is the #1 bug the reviewer catches in review-configs.
3. **Heading level is rigid: use `### Auth` and `### Known service ports` (level 3, with three `#`).** These sections must use the `###` heading level exactly — the dev-env pre-start (`scripts/setup-dev-env.sh`) greps for them literally: it evals any bash block under `### Auth` and pulls the API/Web URLs out of the ports table. Get the level or the placement wrong and the dev env comes up unprobed, so `/review functional` drives nothing. Place them *after* `## Functional validation` closes — i.e., after its last `### Step N` subsection — but keep the level at `###`. They are "sibling to `## Functional validation` in document flow" but "one level deeper in heading numbering"; when the prompt below says "peer to `## Functional validation`", read it as placement, not heading level.
4. **Track the `@v3` tag for the reusable workflow** so pipeline fixes auto-propagate, and declare the supply-chain trade-off as accepted in `bugbot.md` so the reviewer doesn't re-flag it on every PR (see Step 3 template). `@v1` is frozen and no longer receives fixes — new repos use `@v3`.
5. **Write `### Auth` in the canonical shape** — a `Sign in:` line with `<METHOD> <endpoint>` + JSON body, and `Method:` one of `cookie`/`bearer`/`header`/`none` (Step 4 → `### Auth`). Nothing greps that phrasing any more; the section is handed to the functional tester as prose, and the canonical shape is what it is built to read.
6. **A runtime repo should ship a working `dev-start.sh` — it is the only thing that makes `/review functional` real.** No verdict depends on it: a missing or broken bring-up never blocks a PR, never withholds `APPROVE`, and produces no nag. What it decides is whether the browser tester has a running app to drive — without it, `/review functional` quietly degrades to a plain code review. If this repo runs an app, build the bring-up, make it cache-efficient, and prove it via the local loop + council review in Step 4.5 before committing. (Only genuinely non-runtime repos — pure-docs, lib-only — omit the file.)

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

**Reviews are on demand.** Nothing runs on push: a reviewer comments `/review …`
on the PR and the comment names the passes to run — `code` (the code review),
`functional` (the browser tester) or `all`. Depth is not a command option:
`review-scan` scales itself from the diff. The command chooses which passes run.

Create `.github/workflows/claude-review.yml`:

```yaml
name: Claude PR Review
on:
  issue_comment:
    types: [created]
  pull_request_target: # warms the browser cache in main scope
  workflow_dispatch:
    inputs:
      pr_number:
        description: 'PR number to review'
        required: true
        type: string
      command:
        description: 'Passes to run, e.g. "/review code functional". Empty = code review only.'
        required: false
        type: string

# A second request QUEUES; it is never cancelled, because a human asked for it.
concurrency:
  group: claude-review-${{ github.event_name }}-${{ github.event.issue.number || github.run_id }}
  cancel-in-progress: false

jobs:
  review:
    # Filter, not security: without it every comment opens a run that only skips
    # itself. Authorization is the author_association gate in the called workflow.
    if: >-
      github.event_name != 'issue_comment' ||
      (github.event.issue.pull_request != null &&
       startsWith(github.event.comment.body, '/review'))
    uses: panenco/claude-review/.github/workflows/pr-review.yml@v3
    permissions:
      contents: write
      pull-requests: write
      issues: write
      packages: read
      id-token: write # for the coming per-developer Claude seats; inert until then
    with:
      pr_number: ${{ inputs.pr_number || '' }}
      command: ${{ inputs.command || '' }}
    secrets: inherit
```

Do **not** try to forward the comment body — a reusable workflow sees the
caller's `github` context and reads `github.event.comment.body` itself. The
`command` input exists only for `workflow_dispatch`, which has no comment.

Two things people get wrong here:

- **`pull_request` must be gone.** It no longer reviews — a push carries no PR
  number, so the run dies at "Resolve PR head SHA" with a red check on every
  push. There is no draft guard any more either: a draft PR is reviewed if
  someone asks.
- **`pull_request_target` is not a review trigger.** It runs the warm-cache job
  only. Keep it if the team uses `/review functional` regularly; drop it
  otherwise.

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

### Self-hosted runners: the `runner` input (omit unless the user asks for it)

**Default: do not set `runner`.** Reviews run on GitHub-hosted `ubuntu-latest`, which is right for almost every repo. Only wire this input if the user explicitly tells you they have a self-hosted fleet (an ARC scale set, for example) and want reviews on it. Don't infer it from the presence of other self-hosted workflows in the repo — ask.

```yaml
    with:
      pr_number: ${{ inputs.pr_number || '' }}
      runner: arc-gar-review   # the user's self-hosted scale-set label
```

One input sets `runs-on` for **both** the review job and the warm-cache job, and that is deliberate: the Actions cache is a repo-scoped remote service, so a self-hosted job can restore what a hosted job saved, but the keys are scoped by `runner.os` **and** `runner.arch` — a hosted x64 warm-cache with an arm64 review fleet would never match keys and every review would run cold. Never try to split the two.

If the user does opt in, tell them their fleet needs **network egress to the GitHub Actions cache service** (without it, caching silently degrades to always-cold — reviews still work, just slower), and that the runner image should carry **Chrome's shared libraries** (`libnss3`, `libatk1.0-0t64`, `libgbm1`, `libasound2t64`, …): the browser binary unpacks into `$HOME` and needs no root, but those libs do, and a non-root container cannot apt-install them at review time. The warm-cache job is `pull_request_target`-triggered but PR-code-free by construction (checkout on the base ref, `pnpm fetch` reads only the lockfile, `dev_cache_warm_command` is trusted caller config), so it is safe on their own fleet.

Note: the `concurrency:` block and the job-level `if:` filter are required —
omitting either causes recurring noise (cursor-style bots flag missing concurrency
alongside all other repo workflows, and without the filter every comment on every
issue opens a run that exists only to skip itself). The `permissions:` block is also required;
its omission is the #1 startup failure for repos in orgs with the GitHub-default
read-only `GITHUB_TOKEN` scope (see inline comment above). `actions: read` is
**not** needed: round-2 state comes from the PR's own review history, not from
workflow artifacts — existing callers that still grant it are unaffected.

Include `id-token: write` even though nothing requests it yet. The reviewer is
moving to per-developer Claude seats: it will mint a GitHub Actions OIDC token
and trade it for the seat of whoever typed `/review`. A reusable workflow's
permissions are capped by the caller's, so the line has to be in place across
every consumer *before* that switch — a caller missing it then fails at startup
with no logs. Until then it is inert, and it grants the caller nothing else: an
OIDC token is only a signed statement of which workflow ran and who asked.

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

### The `native` pass is removed — do not wire it

`/review native` used to run Anthropic's official `code-review` plugin in-session as a second opinion. It is **deleted** (see `docs/adr/0003-two-call-review.md`), along with the `plugin_marketplaces` / `plugins` action inputs. The review is now one self-scaling reviewer plus a refutation pass.

Do **not** add `native_review_scope` to a caller workflow you are setting up: it is accepted and ignored. It is kept only so an existing caller that passes it does not break — a reusable workflow errors on an undefined input. If the repo you are setting up already passes `native_review_scope` or `model_standard`, you may delete both. `native_review` and `native_review_runner` never existed in v3 and still do not; passing either fails the run with `startup_failure`.


## Step 3: Create bugbot.md

Create `bugbot.md` at the repo root with project-specific review rules. Keep it short — under 15 items. Focus on patterns that are:
- Non-obvious (a reviewer wouldn't know without being told)
- Specific to this project (not generic good practices)
- Things that have caused bugs before

Include a "Verify before flagging" section AND an "Accepted supply-chain trade-offs" section:

```markdown
## Verify before flagging

Before reporting a finding that cites a library or component, confirm it exists:
- Check the repo itself: `git ls-files`, the manifest (`package.json` / `pyproject.toml` / …), and the module's real exports.
- If it doesn't exist, drop the finding. There is no lower bucket to park it in.

## Accepted supply-chain trade-offs

- `panenco/claude-review/.github/workflows/pr-review.yml@v3` with `secrets: inherit` is accepted. Upstream is first-party (Panenco org) and the mutable tag enables single-point propagation of pipeline fixes across every consumer repo. Do NOT flag this as a security finding — pinning to a SHA here was explicitly rejected in favor of easier upstream updates.
```

The "Accepted supply-chain trade-offs" line is what keeps the reviewer quiet about `@v3 + secrets: inherit`. Leave it in on every repo that uses `@v3`.

### Optional: opt back into test-coverage / a11y emphasis

By default the reviewer stays quiet about both. `review-scan` lists "missing tests you cannot tie to a broken behavior" as permanently out of scope, and the functional tester takes its whole test plan from the linked issue's acceptance criteria — it never derives one from the diff. If your project genuinely wants these looked at, add a section to `bugbot.md` describing your project's convention:

```markdown
## Test-coverage convention

Every non-trivial changed handler/hook/util/service in `src/api/**` or `src/services/**`
must have a sibling spec at `<filename>.spec.ts` or `<filename>.test.ts`. PRs that
add such files without a sibling spec should be flagged as a `minor` finding on the
topmost added line of the new module. Out of scope: tests, generated code, config
files.

## Accessibility focus

Frontend changes that touch form labels, ARIA attributes, semantic markup, or
keyboard handlers should be checked against WCAG 2.1 AA on the changed page.
```

There is no `a11y` flag and no diff-derived test plan any more, so this only shapes
what the code review is willing to say. To get accessibility actually *exercised* in
a browser, write it into the linked issue's acceptance criteria — that is the
functional tester's only source. Without these sections the bot stays quiet about
test/a11y: the perimeter is the diff, and the conventions are yours to declare.

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

**Prose only — no executable bash.** No agent reads this section any more — `context.md` and the context builder are deleted, and `review-scan` reads the PR and the repo directly. It survives for two reasons: humans need the runtime description, and it is still the *legacy* bring-up path — with no `dev-start.sh` present, `scripts/setup-dev-env.sh` evals bash blocks found here and warns that it did. Keeping it prose is what stops that from firing. The *executable* side of dev-env bring-up lives in `.github/claude-review/dev-start.sh` (see Step 4.5). Describe, in prose, what the project needs at runtime:

- Database: which flavour (Postgres / MySQL / SQLite / none), whether it's dockerised, the default DB name, credentials for tests.
- Environment: where `.env` (or equivalent) actually lives (monorepo apps often have per-app `.env.example` files — `ls` to confirm), what vars matter.
- Migrations / codegen: Prisma / Drizzle / TypeORM / Django / etc., and whether they auto-run on boot or need an explicit step.
- Dev server: which processes start, which ports they bind. Reference the numbers, not the commands — commands live in `dev-start.sh`.
- Test data: what fixtures or seeders exist, which test users the seeders create, whether the functional tester should call a signup endpoint instead.

The humans need the prose; the pipeline needs the script. Do not duplicate the commands in both places — the script is the source of truth.

## Step 4.5: Determine the runtime surface, then build dev-start.sh

Every repo with a runnable app should ship `.github/claude-review/dev-start.sh` — the first-class contract the pipeline uses to bring up the dev environment (install deps, start services, block until they respond). **No verdict depends on it** — a missing or failed bring-up never blocks and never withholds `APPROVE` — but it is the difference between `/review functional` driving the real app and driving nothing at all. Build one that is **efficient (cache-enabled), locally verified, and council-reviewed** for THIS project.

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
- **Truly nothing runnable** (case 3, pure-docs/pure-library) → do NOT create `dev-start.sh`, and document explicitly in your handoff: "This repo has no runnable surface, so `/review functional` has nothing to drive. `/review code` reviews it normally and no verdict is affected. If a runnable surface is added later, add a `dev-start.sh` then."

An empty-but-present `dev-start.sh` is the worst option: it exits 0, starts nothing, and the port probes then time out with no app to test. Commit a real one (cases 1/2) or none (case 3).

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

**Be explicit and literal.** `scripts/setup-dev-env.sh` reads this section during bring-up — it evals any bash block here and reports `auth_ready` — and the orchestrator hands it, plus the dev-env outputs, to the functional tester as a ready-made auth recipe, so the tester spends zero budget rediscovering auth: exact endpoints, exact seeded credentials, exact method. A `Sign in:` line with a `POST <endpoint>` + `{JSON body}` is the canonical shape.

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

If the dev environment has known failure modes no PR causes — seed-data gaps, SPA route 404s, flaky auth paths — list them under a `### Known dev-env quirks` section (same level-3, file-root placement as `### Auth`). It is passed verbatim to the functional tester, so a matching failure is treated as expected instead of reported as an observation.

**Section placement matters, and heading level is rigid.** `### Auth` and `### Known service ports` use **heading level 3 (three `#` — literally `###`)** and sit at **the root of the file, after `## Functional validation` has closed** (i.e., after its last `### Step N` subsection). They are placement-peers of `## Functional validation` — same depth in document flow — but **not** heading-peers: keep them at `###`, not `##`. `scripts/setup-dev-env.sh` greps for these headings literally when it brings the dev env up and probes it.

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

Do **not** promote to `## Auth` / `## Known service ports` — the dev-env probe's section matcher is heading-level aware, so at `##` the Auth section swallows every `###` subsection below it and evals whatever it finds there. Do **not** nest them under `## Functional validation` either — when they live inside, the Functional-validation extractor picks up Auth code it shouldn't. Keep them exactly as **level-3 headings at the file's top level, immediately after the last `### Step N`**.

## Step 5: Verify self-check

Before committing, re-read your own `.github/review-config.md` and `.github/claude-review/dev-start.sh` and confirm:

- [ ] `dev-start.sh` exists, is executable (`chmod +x`), boots from a clean checkout (exit 0, services answer on every `### Known service ports` URL), AND has passed a council-consensus round per Step 4.5 (no reviewer raised a blocking flaw, or the 3-round cap was hit with remaining flaws documented in the PR). If it doesn't boot locally it won't boot in CI, and a broken bring-up costs you the functional pass entirely. It never costs you a verdict — nothing blocks or withholds `APPROVE` over a dev env. (Exception: an app that boots only with creds you lack locally — verified by inspection + council, with a `DEV_ENV_SECRETS` to-do emitted, per Step 4.5.2.)
- [ ] If bring-up rebuilds heavy non-PR artefacts cold (Gradle/Maven, Go modules, Rust `target`, an SDK generator), the `dev_cache_*` inputs are wired in the caller workflow and a warm re-run is measurably faster — cache key is your lockfile globs, cached paths are dependency dirs (not whole build trees).
- [ ] If your repo generates code from an openapi spec / Prisma / Drizzle / GraphQL schema / etc. at dev-time, `dev-start.sh` runs that generator **before** the dev server. Missing codegen = TS errors = compile noise (and sometimes blocks boot outright — see valcori's historical `src/sdk` case).
- [ ] `review-config.md`'s `## Functional validation` section is **prose only** — no fenced `bash` blocks. Commands live in `dev-start.sh`.
- [ ] Every path appearing in a `cp`, `source`, or `cat` command (in either file) exists at the stated path. Run `ls <path>` to prove it.
- [ ] Every readiness wait loop in `dev-start.sh` either exits non-zero on timeout OR logs a `::warning::`/`::error::`. No bare `for ... && break; sleep ...; done` patterns.
- [ ] `### Auth` and `### Known service ports` sit at the top level of `review-config.md`, not nested inside `## Functional validation`.
- [ ] `### Auth` documents the sign-in endpoint, seeded credentials, and method verbatim — a `Sign in:` line with `POST <endpoint>` + JSON body is the canonical shape.
- [ ] Auth `Method:` is one of `cookie`, `bearer`, `header`, `none`.
- [ ] The caller workflow tracks `@v3` AND `bugbot.md` contains an "Accepted supply-chain trade-offs" section that names `panenco/claude-review@v3 + secrets: inherit` as accepted. Both are needed — the @v3 for auto-propagation, the bugbot note so the reviewer doesn't re-flag it.
- [ ] The caller workflow triggers on `issue_comment`, NOT `pull_request`. A leftover `pull_request:` trigger reds the check on every push (no PR number on that event).
- [ ] The caller's job has the `startsWith(github.event.comment.body, '/review')` filter, so an ordinary comment does not open a workflow run that exists only to skip itself.
- [ ] The caller workflow has a `concurrency:` block (`group: claude-review-${{ github.event_name }}-${{ github.event.issue.number || github.run_id }}`, `cancel-in-progress: false`) — cancelling would throw away a review someone asked for. `github.event_name` keeps the comment run and the warm-cache run in separate groups.

If any check fails, fix before committing. A misconfiguration that produces a concrete wrong behaviour is exactly what the reviewer flags on the first PR.

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
| Caller workflow missing `id-token: write` | Nothing today — the reviewer does not request it yet. Once it does, this is `startup_failure`, zero jobs, no logs, because GitHub refuses the run before any pipeline code executes. Fix: add `id-token: write` to the caller's `permissions:` block. |
| All correct | "Create GitHub App token" = `success`, "Resolve review identity" logs `Review identity: <your-app-slug>[bot]`. |

### `TRACKER_SECRETS` (optional, for Step 4.6 opt-in)

Single multiline secret with newline-separated `KEY=VALUE` pairs that your `fetch-issue.sh` reads as env vars. Without it, the hook runs but every referenced env var is empty — the Actions log will show a `::warning::` from `fetch-issue.sh`, and the review completes without external-spec context.

### `DEV_ENV_SECRETS` (optional, for Step 4.5 when dev-start.sh needs creds)

Single multiline secret with newline-separated `KEY=VALUE` pairs exposed as env vars to `.github/claude-review/dev-start.sh` (and to the legacy `## Functional validation` bash blocks + `### Auth` eval). Use it for registry tokens, cloud SDK keys, or third-party API creds your bring-up needs at boot. Without it, references in `dev-start.sh` to these env vars are empty — the script will fail hard at the first command that depends on them, and the whole review stops (same fail-hard semantics as any other `dev-start.sh` error). Skip if your bring-up is self-contained.

## What blocks a PR

`REQUEST_CHANGES` comes from exactly two places: a surviving `critical`/`major` finding, or the oversized gate. It **never** comes from a missing spec, a missing dev env, a failed or skipped smoke run, or an unanswered question — those gates are deleted (see `docs/adr/0003-two-call-review.md`), and they were 76% of the old pipeline's blocks.

`scripts/guard.sh` is the whole structural layer: pure bash, four exits, decided before any model reads the diff.
- **`label`** (skips, posts nothing) — the `skip-review` label is present. It is checked first, so it wins over both size-ceiling overrides (`/review deep` and the `deep-review` label) and over the size ceiling itself. `skip-review` is deliberately label-only: "never review this PR" is persistent state, so there is no `/review skip`.
- **`unchanged`** (skips, posts nothing) — round 2+ and nothing non-generated changed since the last judged review. It suppresses *automatic* re-runs only: an explicit `/review …` is never answered with silence.
- **`oversized`** (blocks) — > 3000 non-generated lines or > 60 files: no model reads anything, the bot posts a canned "split this PR" `REQUEST_CHANGES`. Two equivalent overrides force a real review: commenting `/review deep` (composes with any pass — `/review code deep`, `/review all deep`) covers the run it starts, and the `deep-review` label covers every push, so a PR that genuinely cannot be split needs no re-typing. Either alone is enough. `skip-review` bypasses it entirely.
- **`empty`** (skips, posts nothing) — nothing reviewable left once generated files (lockfiles, snapshots, `dist/`, `*.min.*`, `*.generated.*`) are excluded.

Anything else runs. And `APPROVE` is the rare verdict, not the target: it needs zero surviving findings **plus** an argued case that a human pass over this diff changes nothing, with no sensitive path touched (auth, payments, migrations, `.github/`, `.claude/`, `infra/`) and low review effort. Everything short of that is `COMMENT` — and a `COMMENT` listing what a human should look at is a good review, not a failure.

All of this resolves fresh each round — fix the cause and the next run re-evaluates.

## Step 7: Test

Push the changes on a branch, open a PR, and verify the workflow triggers. Expected outcome:

- "Install review pipeline" step succeeds (composite action)
- The review body is short — ~600 bytes, hard-capped at 1200 — with no banners, no "Spec sources" and no setup-health section; v4 deleted all of them
- Dev env setup starts your services (look for `API ready at ...` in logs — not just `API=false`)
- "Install review subagents" copies the pipeline's static `agents/review-scan.md`, `agents/review-verify.md` and `agents/review-functional-tester.md` to `~/.claude/agents/` on the runner, templated with `inputs.model_high` / `inputs.model_functional` (each pins its model and its reasoning effort and points at its skill — don't commit such files to your repo)
- Orchestrator dispatches `review-scan` (opus-5, effort `medium`) — and, in the same response, the functional tester when it is eligible — then `review-verify` (opus-5, effort `low`), whose only mandate is to refute scan's candidates against the source at HEAD. Uncertain counts as refuted. There are no judges, no debate and no tiers: `review-scan` picks light vs full from the diff itself and records which it chose and why.
- Functional testing is **advisory and opt-in**. It runs only when all three hold: the comment asked for it (`/review functional` or `/review all`), the dev env came up, and the PR's linked issue carries explicit acceptance criteria. Those criteria are its entire test plan — it never derives one from the diff, the title or the PR body. It can neither raise nor lower the verdict: a reproduced failure reaches the review only if `review-verify` can tie it to a changed line and restate the failure itself, otherwise it becomes a human-review item or nothing. It is bounded by a wall-clock budget (`functional_budget_seconds`, default 8 min) so it always writes its file rather than being cancelled mid-run.
- A heavy `dev-start.sh` (Docker images + JDK/Gradle + a large monorepo's `node_modules`) can exhaust the hosted runner's ~14 GB free disk and fail the job with `No space left on device` after the review already ran. The workflow reclaims disk before the bring-up via the `free_disk_space` input: `safe` (default) clears tooling no Linux app needs (CodeQL/Haskell/Swift, ~12 GB) and is safe for every repo; set it to `aggressive` (also drops Android SDK + .NET, ~25 GB) **only if your `dev-start.sh` doesn't build Android or .NET**; `off` disables it.
- PRs opened by bots (renovate, dependabot) need no configuration: nothing reviews them until a human comments `/review`, and there is no `allowed_bots` input any more. A bot's own *comment* never triggers a review — it cannot clear the `author_association` gate.
- For PRs with UI surface, the functional tester's Turn 1 is a browser smoke check (`agent-browser open about:blank`). If Chrome can't launch, the tester writes `overall: CRASH` and stops. That never lowers the verdict on its own — `review-verify` discards everything in a crashed run. Silent fallback to curl/psql is forbidden: a curl-only PASS on a UI fix is the bug we're guarding against.
- **Verdict: `COMMENT`, with no findings** — that is the expected good outcome. A setup PR touches `.github/`, which is a sensitive path, so `APPROVE` is off the table by construction; don't chase it. Findings are worth chasing: read them and tighten the config, they're almost always real and point at something fixable.
- The workflow check is **green whenever a review posted**, even on `REQUEST_CHANGES` — the verdict lives in the PR review (use branch protection's required reviews to make it block merges). A red check means the pipeline itself failed.

## Round 2 — no ladder

When you push follow-up commits and ask for another review, the bot runs a round-2 pass scoped to the diff since its previous review. The previously-reviewed commit comes straight from the PR's own review history (no artifacts, no extra permissions), and that scoping is what makes follow-up rounds cheap. Two things happen, and deliberately only two:

- **Scope.** `review-scan` reads only `git diff <prior_head_sha>..HEAD`. It reads the wider file for context, but it does not hunt for new findings outside that delta — the previous round already read the rest.
- **Carry.** It re-checks each finding the previous review raised against the code at HEAD and decides *fixed* or *unresolved* **from the code**, never from a reply. Unresolved ones are carried and then refuted by `review-verify` like any other candidate. Fixed ones are never mentioned again, and nothing already raised is re-raised under a new title.

**The verdict is recomputed from scratch every round, from surviving findings alone.** A prior `REQUEST_CHANGES` does not force another one, and a prior `APPROVE` does not protect this round. There is no ladder, no ratchet and no pinning — pinning each round to its predecessor is what once produced twelve rounds of flip-flopping on a single PR.

Thread adjudication is gone with it: no `DISPUTED` state, no in-thread replies from the bot, no "Dropped after author rebuttal" / "Still present after your reply" bookkeeping. Dismissing the review or arguing in a thread changes nothing by itself — a finding survives because the code at HEAD still shows it, or it doesn't. Fix the code and the next round stops raising it. `/review deep` and the `deep-review` label both still override the size ceiling (comment = this run, label = every push); a `skip-review` label still skips everything.

Severities: three levels. `critical` (security, data loss, broken build) and `major` (a user-reachable logic bug) block; `minor` is real but non-blocking and never gates the verdict. There is no `note` level any more — a finding that can't name a concrete failure scenario is deleted by the model that found it, not parked at the bottom of the scale. At most **5** findings post as inline comments, filled strictly critical → major → minor, each ≤700 bytes and each carrying a committable `suggestion` block; the rest become bullets in the review body, which is itself capped at 1200 bytes (aim ~600). Every finding appears exactly once — inline **or** in the body, never both.
