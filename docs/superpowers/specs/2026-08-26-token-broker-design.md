# Claude token broker — per-developer credentials for the review pipeline

Date: 2026-08-26
Status: proposed

## Context

The pipeline authenticates with a pool of OAuth tokens from **dedicated Claude accounts**, rotated by `scripts/pick-oauth-token.sh` on 5-hour-window probes. That has to go.

Two things changed the picture:

- **Panenco is on Claude Team → Commercial Terms.** No credential-sharing prohibition; the only account clause is *"Customer is responsible for all activity under its account."* On Team the **org is the Customer** and seats are Users under it, so the org holding a seat's token is not one person lending another their account.
- **Reviews are on-demand** (`b363939`) — a human comments `/review`, no auto-on-push. Pre-change load was ~6,340 runs/month at ~$3.56 each (~$22.6k/mo at API list rates), 68% re-reviews, 44% zero findings. On-demand removes most of that.

The broker replaces the pool: each developer registers their own Team-seat token once, and a review draws on the seat of whoever asked for it.

**Residual risk, accepted:** Anthropic's docs say OAuth is "designed to support ordinary use of Claude Code," and their secrets-manager safe harbour names **API keys, not OAuth tokens**. This sits outside every stated prohibition *and* outside the stated safe harbour. Worth a written answer from Anthropic sales, not a blocker.

## Non-goals

- Not a general-purpose secret manager. One credential type, one consumer.
- No database. Secret naming *is* the index.
- No rotation automation — `setup-token` credentials have no short-TTL story.
- Changes how the reviewer authenticates, not what it does.

## Prerequisite: `id-token: write` in every caller

A reusable workflow's permissions are **capped by the caller's**; requesting more than the caller grants is a `startup_failure`. `prompts/setup-review.md:170` currently tells consumers explicitly *not* to add `id-token: write`, so `pr-review.yml` cannot declare it until every caller does.

A missed caller fails with **GitHub's own startup error before any of our code runs** — no `::error::`, no hint pointing here. That is exactly what the pre-PR-2 audit prevents.

**Accepted: we edit all 23 callers.** `@v3` cannot propagate this one, so it ships in PR 1 and the switch stays parked until the audit is clean.

## Architecture

```
Developer (once)                        Review run (every /review)
─────────────────                       ──────────────────────────
  GET /login  (signed state)              workflow mints OIDC token
      │                                        │  (id-token: write)
      ▼                                        ▼
  GitHub App web flow                     GET /api/token
  (reuses reviewer App)                   Authorization: Bearer <OIDC JWT>
      │                                        │
      ▼                                        ▼
  GET /callback ─── signed cookie         verify iss / aud
      │                                        / repository_owner / job_workflow_ref
      ▼                                        │
  POST /token  (paste setup-token)             ▼
      │                                   read claude-token-<actor>
      ▼                                        │
  Secret Manager                               ▼
  claude-token-<login>  ◄────────────────  CLAUDE_CODE_OAUTH_TOKEN
```

Cloud Run, no database, no persistent disk. All state is Secret Manager. Scale-to-zero, so idle cost is ~nothing.

## Developer self-service UI

One page, server-rendered HTML: sign in with GitHub, paste your token, done. No account to create — the reviewer App already knows who you are. Plain HTML strings with inline CSS, no framework, no build step, no client-side JS; the paste box is a `<form method="post">`. A few dozen lines.

**No custom domain.** The deterministic Cloud Run URL is the address, for the UI and for the OIDC `aud` claim. It ships as the default of a `broker_url` input on `pr-review.yml` — *not* a GitHub org variable, which would have to be set in every allowed org (`Curewiki` can't read a `Panenco` variable) and is plumbing this repo uses nowhere today. Moving the broker is a release, which is the propagation mechanism consumers already have. `aud` is compared to that exact string, trailing slash included.

### Org gate: one list

Cloud Run ingress must be public — runners and browsers both reach it — so **every route authorises in-app**.

`ALLOWED_ORGS` (e.g. `Panenco,Curewiki`) governs both sides: who may sign in, and which repos' runs may request a token (`repository_owner`). One list, because the two would always match in practice. Adding an org is config plus a redeploy, no code.

After the web flow the broker calls `GET /user/memberships/orgs/{org}` with the user's token and requires **active membership in at least one allowed org**. The reviewer App already holds **Members: Read** — but a user-to-server token only reads memberships where the **App is installed**, so every org in `ALLOWED_ORGS` needs the reviewer App installed or its members silently fail the gate. Runbook checks this when adding an org.

A member of one org working in another's repo resolves cleanly: `repository_owner` must be allowed and `actor` must have a token. GitHub already governs who may comment `/review` where.

### Session hardening

Two attacks matter on a page whose whole purpose is pasting a credential.

**Login CSRF** — without a `state` parameter an attacker can walk a victim's browser through `/callback` with the attacker's `code`, pinning that browser to the *attacker's* session; the victim then pastes their token into the attacker's account. `/login` sets a short-lived nonce cookie and passes `state` = HMAC of that nonce under `broker-session-key`; `/callback` rejects any mismatch. This is the one place the HMAC is load-bearing.

**Form CSRF** — an attacker page POSTing `/token` to register a credential *they* control against a victim's login. Two layers, no JavaScript:

- **Cookie `HttpOnly; Secure; SameSite=Lax; Path=/`.** Lax alone blocks cross-site POST. Not `Strict`, so the `::error::` link from an Actions log still arrives authenticated.
- **Reject any POST whose `Origin` isn't the broker URL.** Every browser sends `Origin` on POST; a missing one is rejected too.

No hidden CSRF token: with Lax cookies plus an origin check it is a third layer against the same attack, and the same HMAC is better spent on `state` above.

Session TTL ≤12h: membership is checked at login only, so a long-lived cookie keeps an offboarded developer in the UI.

Non-members get a bare `403 Forbidden` — no login echoed, no org named. Unauthenticated requests get the sign-in page or a 403; never a stack trace, never a route listing.

### Page states

Status is the secret's `createTime` — free, no bookkeeping. No "last used": Secret Manager has no access timestamp, and faking one costs a write on the review hot path for a nice-to-have.

**Not registered:**
> **No token registered.** Reviews you request with `/review` will fail until you add one. Run `claude setup-token` locally and paste the output.
> `[ paste box ]` `[ Save ]`

**Registered:**
> **Token registered ✓** — added 12 Aug
> `[ Replace ]` `[ Remove ]`

**Malformed on save:**
> **That doesn't look like a token.** `claude setup-token` prints one long value with no spaces — paste all of it.

**Superseded during implementation — no Anthropic validation.** The original plan was a cheap Haiku probe before writing, reusing `pick-oauth-token.sh`'s shape. That shape is not portable: the picker shells out to the `claude` CLI, which supplies the Claude Code identity system prompt that `setup-token` credentials require, and a direct API call without it is expected to reject *valid* tokens — which would mean nobody could ever register. Shipping the CLI in the container to reproduce it was judged not worth the image weight and version lockstep. `POST /token` therefore checks **shape only** (non-empty, no whitespace, plausible length); a well-formed but wrong token surfaces at the next review instead. The "Invalid on save" state above covers a malformed paste, not a rejected one.

### No admin endpoint

Dropped deliberately. "Who still needs to onboard?" is `gcloud secrets list --filter="name:claude-token-"` — no route, no page exposing who works here.

## Components

### Cloud Run service

| Route | Purpose |
|---|---|
| `GET /login` | Redirect into the GitHub App user web flow, with signed `state` |
| `GET /callback` | Verify `state`, exchange code → identity, set signed cookie |
| `GET /` | Status + paste box |
| `POST /token` | Check the paste's shape, then write `claude-token-<login>` |
| `POST /token/delete` | Remove your own token (form post, no JS) |
| `GET`/`HEAD /api/token` | **Machine endpoint.** Verify OIDC JWT, return the caller's token; `HEAD` answers "is one registered?" with no body |

Six routes. TypeScript/Node, single container, no framework, no build step beyond `tsc`. Browser routes require cookie **and** active membership; the machine route ignores cookies and takes only a signed OIDC token. Different paths, so neither auth mode can be reached by the other's method.

### Secret Manager layout

```
claude-token-<github-login>     # one per developer, latest version wins
broker-session-key              # HMAC key for cookie and OAuth state
github-app-client-secret        # for the user web flow
```

The two config secrets mount as env vars at deploy. The GitHub login *is* the lookup key — no mapping table. Two details that bite:

- **Lowercase the login** on write *and* read. Secret Manager IDs are case-sensitive; the `actor` claim preserves the user's chosen casing, so `LeslieJobse` registering and `lesliejobse` requesting are two different secrets.
- **Replace and Remove must destroy prior versions**, not just add a newer one — an un-destroyed version is still a live credential.

### OIDC verification

Validated against `token.actions.githubusercontent.com` JWKS. The workflow requests the broker URL as `audience` explicitly.

| Claim | Requirement |
|---|---|
| `iss` | `https://token.actions.githubusercontent.com` |
| `aud` | broker URL, exact match |
| `repository_owner` | in `ALLOWED_ORGS` |
| `job_workflow_ref` | starts with `panenco/claude-review/.github/workflows/pr-review.yml@` |
| `actor` | the login whose token is returned |

**No SHA allowlist.** An earlier draft pinned `job_workflow_sha` to released SHAs maintained by `release.sh`. Dropped: the ref check already proves the run came from this repo's reviewer workflow, and only someone with push access here could point it elsewhere — the same person who can merge to `main`. It bought almost nothing and cost a Secret Manager write inside `release.sh`, GCP credentials for whoever cuts a release, a half-failed-release failure mode, and an opaque 403 for this repo's own runs. Without it, dogfood and `pipeline_ref` runs work like any other. (`job_workflow_ref` can't be SHA-pinned anyway: on an `@v3` consumer it reads `…/pr-review.yml@refs/tags/v3`.)

### Who pays: the commenter (`actor`)

The token belongs to **whoever typed `/review`**, from the signed `actor` claim.

PR-author billing is fairer but strictly more expensive: the author appears in no OIDC claim, so the broker would need the reviewer App's private key, an installation token, and an **unsigned PR number** in the request — which a review job with code execution could point at any PR to drain that author's seat. `actor` costs none of that: the claim is bound to the run, the broker needs **no GitHub API access at all**, and a compromised job reaches only the token already in its own env.

The trade: a reviewer who types `/review` on someone else's PR pays for it. In practice authors ask for their own reviews — and a bot PR always has a human commenter, which is what makes renovate/dependabot work with no special case. A re-run keeps the original `actor`, so it still bills the requester.

## Pulumi scope

**Automated**, into an existing project in our GCP org (no new project): Cloud Run service, Artifact Registry, service account, IAM; the two config secrets; `ALLOWED_ORGS` as env config.

**Which project — settled at deploy time: `panenco-actions` (187583468130), not `panenco`.** The `panenco` project has no billing account linked and nobody on the team can link one, so every API enable fails `UREQ_PROJECT_BILLING_NOT_FOUND`. `panenco-actions` is billed, already runs Artifact Registry, is the org's GitHub Actions infrastructure project — which is precisely what the broker serves — and holds no other secrets. The project number is part of the deterministic Cloud Run URL, so this choice fixes the OIDC `aud` and the GitHub App callback.

**The image ships with the infra.** `pulumi up` builds `broker/` locally and pushes to Artifact Registry — no separate CI job, no deploy-on-merge. Redeploying the broker is a deliberate `pulumi up`, decoupled from cutting a pipeline release.

**Set `max-instances` low** (a handful). Ingress is public, so unauthenticated requests start containers; this is the cost ceiling.

**No domain mapping, no load balancer, no Cloud Armor.** The `run.app` URL is the address and the OIDC `aud`.

**The `aud` chicken-and-egg.** That URL is both the service's address and a value the service must verify, but an env var referencing the service's own URI is a dependency cycle. New-format Cloud Run URLs are deterministic — `https://<service>-<project-number>.<region>.run.app` — so compute it from project number, service name and region and pass it in. The `<service>-<hash>` form is not computable.

**Manual, one-time:** add a **Callback URL** to the existing reviewer GitHub App; generate a **client secret** on it; put both into Pulumi config. GitHub OAuth Apps cannot be created via API, so first-deploy automation of the login App is impossible — reusing the reviewer App avoids needing a second one.

**No GitHub-side OIDC config** — the workflow requests `id-token: write` and the broker verifies.

## Deliverable: setup runbook

Implementation must also produce `docs/runbooks/token-broker-setup.md`, the deploy-from-nothing guide for everything Pulumi can't do. Written to be **executed by Claude Code**:

- **Every step labelled `AUTO` or `MANUAL`.** `AUTO` carries the exact `gh`/`gcloud`/`pulumi` command, no placeholders beyond named config. `MANUAL` carries the URL, what to click, what to copy out — GitHub App settings have no API, so an agent must be told to hand off rather than hunt for an endpoint that doesn't exist.
- **A verification command after every step.**
- **Idempotent throughout**, safe to re-run from the top.

| Section | Covers |
|---|---|
| GCP bootstrap | the existing **`panenco-actions`** project — enable APIs, Pulumi backend, auth, `allUsers` invoker binding |
| Reviewer App changes | callback URL, client secret — both `MANUAL` |
| Pulumi config | where each secret and `ALLOWED_ORGS` goes |
| First deploy | apply, confirm the live URL matches the computed `broker_url` default |
| Smoke test | register a token; prove `GET /api/token` returns it for a real run **and** for this repo's own dogfood run (`uses: ./…`), which is the one ref shape we don't otherwise exercise |
| Day-two ops | add an org (incl. installing the App there), rotate the client secret, offboard a developer, tear down |

## Pipeline change

`pick-oauth-token.sh` retires. The workflow mints an OIDC token for the broker audience and calls `GET /api/token`.

**Fetch late, and never into `$GITHUB_ENV`.** The job checks out PR head (`pr-review.yml:214`) and runs the PR's own `.github/claude-review/dev-start.sh` (`:723`) *before* the Claude step (`:879`). Today the picker writes the token to `$GITHUB_ENV`, so it sits in that untrusted step's environment. Instead: `HEAD /api/token` early (same route, same auth, 200/404, no body) to fail fast on an unregistered developer before a ten-minute build, then the real `GET` **after** `dev-start.sh`, into a step-scoped env var. Untrusted PR code then runs on a box where the credential does not yet exist.

**Retry the fetch** — three attempts, short timeout, exponential backoff. Covers cold start and transient 5xx; anything past that is a real outage and falls through to the error below.

**Keep both secret declarations.** `pr-review.yml:110-115` declares `CLAUDE_CODE_OAUTH_TOKEN` *and* `CLAUDE_CODE_OAUTH_TOKENS`, and `prompts/setup-review.md` tells consumers to pass them explicitly rather than via `inherit`. Deleting the plural input breaks those callers at startup. So: keep it declared, ignore its value, mark it deprecated in the description. Singular stays live as the fallback for repos not yet migrated, and permanently as break-glass.

**Mask it on receipt.** `secrets.*` is masked by GitHub automatically; a token fetched over HTTP is **not**. Without an `::add-mask::` the moment it lands, one `set -x`, one curl error dump or one debug echo prints a live Claude credential in a **public** repo's logs. `echo "::add-mask::$TOKEN"` before anything else touches it, and never pass it on a command line.

Failure modes as clean `::error::` lines, not crashes:

| Cause | Message |
|---|---|
| No registered token | `No Claude token registered for @<actor>. Add one at <broker-url> — takes 30 seconds.` |
| Token rejected by Claude | re-run `claude setup-token` and re-register |
| 5-hour window spent | `your seat's window is spent, resets HH:MM` |
| Broker unreachable after retries | fall back to the repo secret if one exists, else fail with the broker URL |

The URL in those messages comes from the `broker_url` default, so the error text and the OIDC audience can never drift apart.

**A spent window** loses `pick-oauth-token.sh`'s rotation, but the trade is favourable: a shared pool of 2 becomes ~30 individually-owned seats, so contention largely disappears and the window you burn is your own.

## Security model

**Removes:** a long-lived shared credential in every consumer's secrets, one developer drawing on another's seat, use from outside the reviewer workflow, use from outside the org.

**Does not remove, with what each is worth after mitigation:**

- **Token in the runner.** A PR achieving code execution steals the *requester's* seat. Fetching after `dev-start.sh` means untrusted code runs before the credential exists, so this now needs a foothold in a later step, not just a `printenv`. Blast radius was the whole pool; it is one seat, and harder to reach. The only fix that reaches zero is proxying Claude traffic through the broker so the runner never holds a token — a much larger design, deliberately out of scope.
- **Offboarding.** `GET /api/token` trusts the signed `actor` and never re-verifies membership, so a leaver's secret keeps serving. But removing their Claude Team seat is what actually revokes the credential, and that is already part of offboarding — deleting `claude-token-<login>` is cleanup, and the exposure is the gap between the two.
- **Any repo in an allowed org can request the commenter's token.** `checkClaims` constrains `repository_owner` and `job_workflow_ref` but not `repository`, and this repo is public — so an org member who can create a repo under `Panenco` or `Curewiki` can call `pr-review.yml`, put a payload in that repo's own `dev-start.sh`, and harvest the seat of any colleague who types `/review` there. Both claims are genuine, so nothing rejects it. **Accepted for now:** it needs an insider who can already create repos in the org, and the blast radius is one seat — the same bound the "token in the runner" risk already carries. Closing it means either a `repository` allowlist (a config change plus a redeploy for every new consumer, across ~23 repos) or constraining the ref suffix to released tags plus `main`. Revisit if the org opens repo creation more widely.

- **The ref check is a prefix, not a pin.** Everything after `pr-review.yml@` is unconstrained, so any branch of this repo satisfies it. The reasoning below — "only someone with push access here could point it elsewhere, the same person who can merge to `main`" — holds only while `main` is unprotected. Once the rollout's branch-protection precondition lands, pushing a branch becomes *easier* than merging to `main`, and this check buys less than it appears to.

- **Push access to this repo is push access to every registered token**, since the ref check is the only workflow binding. **`main` is currently unprotected and `v*` tags have no rule** — see Rollout; that is a precondition, not a footnote.
- **Broker or GCP-project compromise** exposes every token (long-lived, unrotated). Unmitigated and inherent to holding credentials at rest.
- **Nothing stops a developer registering a token that isn't theirs.** They'd be burning a seat they control; not worth code.

**Single point of failure, reduced not removed.** After migration most consumers hold no repo secret, so a broker outage stops reviews. Retries cover cold start and transient errors, a failed review is retryable by re-commenting `/review`, and the service is stateless with no dependency but Secret Manager. Residual: a regional Cloud Run outage.

With no database, the request log is the only accountability record — `GET /api/token` must log actor, repository and run_id.

## Settled

- **Seat headroom** — sufficient. Team *extra-usage* bills at standard API rates with no discount, so the saving lives entirely inside **included** quota; 2 shared tokens becoming ~30 owned seats is where the headroom comes from.
- **Claude Code is included** on our seats.
- **Bot PRs** — a bot's comment never clears the `author_association` gate, so every run has a human commenter and that seat pays. No special case.
- **Anthropic's "ordinary use" wording** — accepted residual risk, see Context.
- **No token rotation** — accepted; `setup-token` has no short-TTL story.
- **Volume re-measurement** — deferred. The $22.6k figure predates `/review`; treat it as a ceiling, not a forecast.

No open questions.

## Rollout

Two PRs, each independently mergeable:

1. **Broker + consumer prerequisite** — `broker/`, `infra/`, `docs/runbooks/token-broker-setup.md`; README and `prompts/setup-review.md` reverse the "do not add `id-token: write`" guidance, and the 23 callers get the line. Both halves are inert until PR 2: the broker is deployable and testable on its own, and `id-token: write` on a caller does nothing while `pr-review.yml` never requests it.
2. **Switch** — `pr-review.yml` declares `id-token: write`, gains the `broker_url` input, `HEAD`-checks early and fetches the token after `dev-start.sh`, `::add-mask::`s it into a step-scoped var; `pick-oauth-token.sh` and its test retire.

PR 2 stays parked until an audit — `gh` over the consumer list, grepping each caller workflow for `id-token` — comes back clean on all 23.

**Precondition — repo hardening.** `main` has no branch protection and `v*` has no tag rule today, so anyone with write access can push a workflow change or move `v3`, and after the switch that reaches every registered token. Before PR 2: require a PR plus one approval on `main`, and add a tag protection rule for `v*`. Config only, no code — but the switch should not land without it.

**Rollback** is the existing mechanism, nothing new: move `v3` back to the previous immutable `vX.Y.Z` anchor that `release.sh` cuts. Consumers pin the floating major, so they pick it up on the next run.

Note: `uses: panenco/claude-review@v3` downloads the whole repo tarball, so consumers fetch `broker/` and `infra/` too. A few hundred KB, never referenced by the install step. True exclusion would need a separate repo.
