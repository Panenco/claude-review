# Claude token broker

Per-developer Claude credentials for the review pipeline. A developer registers
their own Claude Team seat token once; a review run draws on the seat of
whoever typed `/review`.

Design: `docs/superpowers/specs/2026-08-26-token-broker-design.md`.
Deploy: `docs/runbooks/token-broker-setup.md` (the runbook is the only place
that knows the manual GitHub App steps).

```
npm install
npm test          # builds, then runs node --test over dist/test
npm run build
```

Six routes, no database, no framework:

| Route | Auth | Purpose |
|---|---|---|
| `GET /login` | none | Into the GitHub App web flow with a signed `state` |
| `GET /callback` | signed `state` | Verify, check org membership, set the session cookie |
| `GET /` | session cookie | Status + paste box |
| `POST /token` | cookie + `Origin` | Probe against Anthropic, then store |
| `POST /token/delete` | cookie + `Origin` | Remove your own token |
| `GET`/`HEAD /api/token` | GitHub Actions OIDC | The review run's token; `HEAD` = "is one registered?" |

All state is Secret Manager. `claude-token-<github-login>` (lowercased) is the
index — there is no mapping table.
