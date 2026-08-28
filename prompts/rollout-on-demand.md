# Roll one repo onto the on-demand `/review` trigger

You are migrating **one** consumer repo's Claude review caller. Upstream
(`panenco/claude-review@v3`, v3.6.1+) no longer reviews on push — a reviewer asks
by commenting `/review …` on the PR. A caller still on `pull_request` reds the
check on every push, because that event carries no PR number.

Scope: **the caller workflow, and nothing else.** Do not touch app code, other
workflows, or repo config beyond what is listed here.

## 1. Work in a fresh clone

Never use an existing local checkout — they hold unrelated work in progress.

```bash
cd "$(mktemp -d)" && gh repo clone <owner>/<repo> . -- --depth=1
git checkout -b chore/claude-review-on-demand
```

## 2. Edit `.github/workflows/claude-review.yml`

Change exactly these, and keep every other input as-is (`runner`, `dev_cache_*`,
`dev_env_timeout_seconds`, `free_disk_space`, `native_review_scope`, …):

- **Trigger**: replace the `pull_request:` block with

  ```yaml
    issue_comment:
      types: [created]
  ```

- **Delete `pull_request_target`** if present. It used to run a cache-warm job,
  but that trigger only gets read-only access to the cache scope, so the warm
  stored nothing while claiming a runner on every PR. Never add it.

- **If the repo uses `/review functional`**, add
  `.github/workflows/claude-review-warm.yml` calling
  `panenco/claude-review/.github/workflows/warm-cache.yml@v3` on `push` to the
  default branch + a weekly `schedule` + `workflow_dispatch`, with the SAME
  `runner` (and the same `dev_cache_*` values) as the review caller. Those are
  the triggers that can write the default branch's cache scope; a read-only one
  makes the whole workflow a no-op. See `prompts/setup-review.md`.

- **`workflow_dispatch`**: add alongside `pr_number`

  ```yaml
        command:
          description: 'Passes to run, e.g. "/review code functional". Empty = judges only.'
          required: false
          type: string
  ```

- **`concurrency`**: `github.event.pull_request.number` → `github.event.issue.number`,
  and `cancel-in-progress: true` → `false`. Cancelling would throw away a review
  someone asked for.

- **Job `if:`**: delete the draft guard, replace with

  ```yaml
      if: >-
        github.event_name != 'issue_comment' ||
        (github.event.issue.pull_request != null &&
         startsWith(github.event.comment.body, '/review'))
  ```

- **`with:`**: add `command: ${{ inputs.command || '' }}`

- **Delete if present**: `allowed_bots`, `native_review`, `native_review_runner`,
  `core_max_turns`. All four are gone upstream and now fail with
  `startup_failure`. `native_review_scope` stays.

- **Pin**: if the caller is on `@v2`, move it (and any `pipeline_ref`) to `@v3`.

## 3. Reduce the comments

These files have accumulated long explanatory blocks. Keep only what would bite
someone editing the file — a hazard, or a constraint whose violation breaks a
run. Cut history, measurements and rationale that the code already shows.

Worth keeping where present: why `free_disk_space` must stay `off` on
self-hosted, why the `permissions:` block is required in full, why
`dev_cache_key_files` takes globs rather than a hash, why the cache warm needs
its own workflow with a write-capable trigger.

Aim well under half the comment lines you started with.

## 4. bugbot.md

If it has an "Accepted supply-chain trade-offs" section naming `@v2`, correct it
to `@v3` so the reviewer stops re-flagging the tag. Nothing else in that file.

## 5. Verify before committing

- `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/claude-review.yml'))"`
- Prove you only changed prose and the trigger — parse both revisions and diff
  the maps:

  ```bash
  python3 - <<'PY'
  import yaml, subprocess
  new = yaml.safe_load(open('.github/workflows/claude-review.yml'))
  old = yaml.safe_load(subprocess.run(['git','show','origin/HEAD:.github/workflows/claude-review.yml'],
                                      capture_output=True, text=True).stdout)
  n, o = new['jobs']['review'], old['jobs']['review']
  print("removed:", sorted(set(o['with']) - set(n['with'])))
  print("added  :", sorted(set(n['with']) - set(o['with'])))
  print("changed:", {k: (o['with'][k], n['with'][k])
                     for k in set(o['with']) & set(n['with']) if o['with'][k] != n['with'][k]})
  print("perms equal:", o.get('permissions') == n.get('permissions'))
  PY
  ```

  Expect `added: ['command']` and nothing else, apart from the deliberate
  deletions in step 2 and a `@v2`→`@v3` pin change.

## 6. Open a PR — do not merge

Title: `chore(review): move Claude review to the on-demand /review trigger`

Body: what changed and why (push no longer reviews), the command table, and a
**Testing** line saying to comment `/review code` once merged — the trigger
cannot be tested on the PR that introduces it, because `issue_comment` workflows
only ever run from the default branch.

## Report back

One short paragraph: repo, PR URL, whether it was `@v2` or `@v3`, comment lines
before → after, and anything you deliberately left alone. If the repo has no
`.github/claude-review/dev-start.sh`, say so — **do not write one**; runtime PRs
there are capped at `COMMENT` until someone builds it, and that is a separate
job needing repo knowledge you do not have.

Stop and report instead of guessing if the caller does not match the shape above.
