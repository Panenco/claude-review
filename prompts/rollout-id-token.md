# Add `id-token: write` to one repo's Claude review caller

You are adding **one line** to **one** consumer repo's caller workflow.

Upstream is moving off a shared pool of Claude OAuth tokens. Instead, the
reviewer will mint a GitHub Actions OIDC token and trade it at a broker for the
Claude seat of whoever typed `/review`. A reusable workflow's permissions are
**capped by the caller's**, so `pr-review.yml` cannot request `id-token: write`
until every caller grants it.

**This change is inert.** `id-token: write` on a caller does nothing while the
upstream workflow never requests an OIDC token. It has to land everywhere first,
because a missed caller fails with **GitHub's own startup error before any of
our code runs** — no `::error::`, no logs, no hint pointing at this.

Scope: **the caller workflow's `permissions:` block, and nothing else.** Do not
touch app code, other workflows, `with:` inputs, triggers, or repo config.

## 1. Work in a fresh clone

Never use an existing local checkout — they hold unrelated work in progress.

```bash
cd "$(mktemp -d)" && gh repo clone <owner>/<repo> . -- --depth=1
git checkout -b chore/claude-review-id-token
```

## 2. Edit `.github/workflows/claude-review.yml`

Add one line to the `permissions:` block of the job that calls
`panenco/claude-review/.github/workflows/pr-review.yml`:

```yaml
    permissions:
      contents: write
      pull-requests: write
      issues: write
      packages: read
      id-token: write # for the coming per-developer Claude seats; inert until then
```

Keep every other key exactly as it is, including an `actions: read` the repo
still grants. If the repo has **more than one** job calling the reusable
workflow, every one of them needs the line.

If the caller has no `permissions:` block at all, it is already broken upstream
(that is the #1 startup failure) — add the whole block above and say so in your
report.

## 3. Verify before committing

```bash
python3 - <<'PY'
import yaml, subprocess
new = yaml.safe_load(open('.github/workflows/claude-review.yml'))
old = yaml.safe_load(subprocess.run(['git','show','origin/HEAD:.github/workflows/claude-review.yml'],
                                    capture_output=True, text=True).stdout)
for job in new['jobs']:
    n, o = new['jobs'][job], old['jobs'][job]
    print(job, "id-token:", n.get('permissions', {}).get('id-token'))
    print("  other perms unchanged:",
          {k: v for k, v in n.get('permissions', {}).items() if k != 'id-token'} == o.get('permissions', {}))
    print("  with unchanged:", n.get('with') == o.get('with'))
    print("  uses unchanged:", n.get('uses') == o.get('uses'))
PY
git diff --stat   # expect exactly one file, +1 line (or +N for N calling jobs)
```

Every calling job must print `id-token: write` with all three `unchanged` lines
`True`. Anything else means you changed more than the one line.

## 4. Open a PR — do not merge

Title: `chore(review): grant id-token: write to the Claude review caller`

Body: one paragraph — the reviewer is moving to per-developer Claude seats via
an OIDC broker, a reusable workflow cannot request more permission than its
caller grants, and this line is inert until the upstream switch lands. Add a
**Testing** line: nothing to test on this PR; existing `/review` runs behave
identically before and after.

## Report back

One line: repo, PR URL, how many calling jobs got the line, and whether the
caller already had a complete `permissions:` block.

Stop and report instead of guessing if the caller does not match the shape above
— in particular if it pins a SHA rather than `@v3`, or calls the workflow from a
job you did not expect.

---

## The audit (upstream, not per-repo)

The upstream switch stays parked until this comes back clean on **every**
consumer. Run it from a machine with `gh` authenticated against all the orgs:

```bash
# One `owner/repo` per line. Keep this list OUT of the public repo.
while read -r repo; do
  perms=$(gh api "repos/$repo/contents/.github/workflows/claude-review.yml" \
            --jq '.content' 2>/dev/null | base64 -d \
          | grep -c 'id-token: *write' || true)
  printf '%-45s %s\n' "$repo" \
    "$([ "${perms:-0}" -gt 0 ] && echo OK || echo 'MISSING id-token: write')"
done < consumers.txt
```

A repo whose caller lives at another path, or that calls the reusable workflow
from more than one job, needs checking by hand — the grep counts occurrences in
one file and knows nothing about which job they belong to.
