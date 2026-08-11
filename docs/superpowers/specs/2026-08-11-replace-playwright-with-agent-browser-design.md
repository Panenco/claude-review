# Replace Playwright with agent-browser — design

**Status:** Draft
**Date:** 2026-08-11
**Scope:** Two repos, one rollout — `panenco/claude-review` (pipeline + skills) and `Panenco/github-action-runners` (image G + `versions.env`).
**Trigger case:** the browser stack for the functional tester is four coupled moving parts held together by two version pins that are *currently drifted* — `versions.env` says `1.60.0` / `0.0.75`, `pr-review.yml` says `1.62.1` / `0.0.79` (bumped in #82 with no image rebuild). Per `versions.env`'s own warning, that drift is silent: reviews do not fail, they just re-download both specs every run and the baked `/opt/google/chrome` no longer tracks the MCP that gets spawned.

## Problem

The functional tester needs one thing: a headless browser it can drive. Getting one currently costs:

1. **Four artifacts, not one.** The `playwright` npm package (for `install chromium`), the `~/.cache/ms-playwright` browser store, the `@playwright/mcp` npm package (spawned via `npx` per subagent), and — separately — **branded Google Chrome as a system apt install at `/opt/google/chrome`**, because `@playwright/mcp` launches `channel:"chrome"` and not a bundled chromium build. `--browser` accepts only `chrome|firefox|webkit|msedge`; there is no `chromium` value.

2. **Two pins that must match across two repos, with no enforcement.** `PLAYWRIGHT_VERSION` and `PLAYWRIGHT_MCP_VERSION` appear in both `pr-review.yml`'s `env:` block and `images/versions.env`. Nothing checks them. They are drifted today.

3. **A root/apt dependency for the browser.** `/opt/google/chrome` is a system install, so the pipeline carries a `sudo -EH` self-heal (`pr-review.yml:343-376`) whose `-H` flag is load-bearing — without it root inherits `HOME=/home/runner`, the Chrome postinstall creates a root-owned `~/.local/share/applications`, and the Claude CLI install two steps later dies with `EACCES`. That is a fix for a problem that only exists because the browser is a system package.

4. **An emptyDir fighting the browser store.** `claude-review.values.yaml` mounts scratch over `/home/runner/.cache`, masking anything baked beneath it. Image G works around this by repointing `PLAYWRIGHT_BROWSERS_PATH` to `~/pw-browsers`, seeding one symlink per baked build, `chown -Rh`'ing the tree, probing writability at build time, and adding a `~/.cache/ms-playwright` symlink purely so the pipeline's `actions/cache` path still resolves — into a directory that is masked at runtime anyway.

5. **An `npx` spawn on the subagent's critical path.** The tester's MCP server starts as `npx --yes @playwright/mcp@<ver>`. Because that is a version-pinned spec resolved through `~/.npm/_npx`, a pin mismatch silently re-downloads it, and the spawn is racy enough that the skill carries a **3-attempt, 5-seconds-apart retry loop** as its first turn before it is allowed to do any work.

6. **Runtime egress for the a11y audit.** The opt-in accessibility check loads axe-core from `cdnjs.cloudflare.com` inside `browser_evaluate` — exactly the egress a locked-down fleet blocks.

## Non-goals

- **Removing Playwright from the fleet.** Image B (`runner-node-e2e`) keeps it for consumers' own e2e suites (qiv). This change removes it from the *review* path only.
- **Re-basing image G from B down to A.** Shedding `/opt/ms-playwright` depends on whether any consumer's `dev-start.sh` launches Playwright during a review — unverified, and a separate change.
- **Changing what the functional tester tests.** Scenario selection, severity rules, the scope rule, evidence-integrity rules and both output contracts (`/tmp/functional-findings.json`, `/tmp/functional-meta.json`) are untouched.
- **Changing the orchestrator's gate logic.** `SKIP_NO_DEVENV` / `CRASH` / `FAIL` handling is unchanged; only the wording of the crash cause changes.
- **The `chat`, `dashboard`, provider (browserbase/kernel/…) and plugin surfaces of agent-browser.** Not used, not configured.

## Why agent-browser

[vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser), Apache-2.0. A single static Rust binary that downloads Chrome for Testing into `$HOME`. Verified against 0.34.0.

**Parity is complete.** Every capability the tester skill uses maps over, verified by driving a live app locally:

| Skill needs | Playwright MCP | agent-browser |
|---|---|---|
| navigate | `browser_navigate` | `open` |
| a11y tree with refs | `browser_snapshot` | `snapshot` — **identical `[ref=e1]` format**, plus `-i`/`-c`/`-d`/`-s` scoping |
| screenshot to an absolute path | `browser_take_screenshot` | `screenshot <path>` |
| console messages | `browser_console_messages` | `console` / `errors` |
| click / fill / select / press | ✓ | ✓ |
| multi-field form fill | `browser_fill_form` | `batch` (JSON array-of-arrays on stdin) |
| authenticated fetch | `browser_evaluate` | `eval` — verified 401 → login → 200 with `credentials:'include'` |
| axe-core audit | eval + **CDN fetch** | **built-in `a11y --tags`**, axe-core 4.12.1 bundled |

**The fleet's constraints favour it.**

- **amd64 only** — `versions.env`: *"Everything is amd64/linux only … GKE nodes are amd64"*, and image G hardcodes the `/x64` toolcache path. Chrome for Testing's `linux64` build is the right one. (Chrome for Testing publishes **no** linux-arm64 build; if the fleet ever moves to arm64, agent-browser needs a system Chromium via `--executable-path`. Recorded here because it is the one thing that would break.)
- **System libs already baked** — image B runs `playwright install --with-deps chromium firefox webkit` (`Dockerfile.e2e:34`), which apt-installs the same `libnss3`/`libatk`/`libgbm`/… set Chrome for Testing needs. `agent-browser install --with-deps` — the only step wanting root — is therefore **not needed on this fleet**. (The package list is recorded in the image below for the day image G stops inheriting from B.)
- **State lives outside the masked mount** — `~/.agent-browser/` holds browsers, daemon sockets and state. `/home/runner/.cache` is emptyDir; `~/.agent-browser` is not. The bake survives, and the cache path and the lookup path become the same directory.
- **Off the NAT path** — Chrome for Testing downloads from `storage.googleapis.com`, a Google API reachable over Private Google Access, unlike `registry.npmjs.org` (27–35% of the fleet's 4.85 TB/month NAT ingress). Dropping the `npx @playwright/mcp` spawn also removes an npmjs fetch from the review's critical path.

**Cost of adoption.** vercel-labs is Vercel's experimental org; the project is 7 months old with ~119 npm releases (roughly four a week). We pin exactly, as we already do for every other tool in `versions.env`, and accept a faster-moving upstream than Playwright.

## Design

### 1. Drive it from Bash — drop MCP entirely

**This is the load-bearing decision.** agent-browser is a CLI, and the tester already has `Bash`. Going MCP-to-MCP would be a regression: measured against the real servers, `@playwright/mcp` exposes 24 tools / ~4.6k tokens of schema, while agent-browser's `core` profile is 29 tools / ~13.7k, and `core,debug` — the profile needed for `console` — is 69 tools / **~32k tokens**. Bash costs zero.

Deleting MCP also deletes, in order:

- the `mcpServers:` block in `agents/review-functional-tester.md`, including the "must stay a YAML LIST of single-key mappings" trap;
- the whole reason that file must be installed to *user* scope with `envsubst`;
- the `npx` cold-spawn race, and therefore the skill's 3-attempt smoke-check retry loop;
- `mcp__playwright` from `--allowedTools` and from the subagent's `tools:` list;
- the "MCP unavailable → `overall: CRASH`" path discovered *mid-agent*, replaced by a deterministic workflow-step preflight that fails before any agent budget is spent.

The subagent file survives only to pin `model:` and point at the skill.

### 2. Pipeline (`pr-review.yml`)

Replace the two Playwright pins with one:

```yaml
env:
  AGENT_BROWSER_VERSION: "0.34.0"
```

**Cache step** — `~/.agent-browser/browsers`, keyed on `${{ runner.os }}-${{ runner.arch }}-ab-${{ env.AGENT_BROWSER_VERSION }}`. No `~/.npm/_npx` entry: nothing is fetched through npx any more. The Chrome build is determined by the pinned CLI version (`install` takes no `--version`), so one key covers both.

**Install step** — replaces the ~65-line Playwright block:

```bash
if ! command -v agent-browser >/dev/null 2>&1; then
  curl -sL "https://registry.npmjs.org/agent-browser/-/agent-browser-${AGENT_BROWSER_VERSION}.tgz" | \
    tar xz -C "$TMP" package/bin/agent-browser-linux-x64
  install -m755 "$TMP/package/bin/agent-browser-linux-x64" "$HOME/.local/bin/agent-browser"
fi
echo "$HOME/.local/bin" >> "$GITHUB_PATH"
agent-browser install          # idempotent no-op (~0.15s) when Chrome is baked
agent-browser doctor --json    # preflight, asserted below
```

No Node needed — the npm package's `engines: node>=24` gates only its JS launcher shim, which we bypass. `~/.local/bin` must be added to `GITHUB_PATH` explicitly: image G's own comment records that it is not otherwise on PATH.

**Preflight assertion.** `doctor --json` exposes `chrome.installed` and `launch.elapsed` (a real headless launch). Both must be `pass`, else `::warning::` — matching today's non-fatal posture, but discovered in the workflow step instead of six turns into the tester.

**Screenshot directory + daemon hygiene.** Export `AGENT_BROWSER_SCREENSHOT_DIR=/tmp/screenshots` so stray captures cannot land in the CWD (today's orchestrator has to sweep `/tmp/playwright-mcp-output`, `.playwright-mcp` and the repo root by basename). Add an `if: always()` cleanup step running `agent-browser close --all`: the daemon's default idle timeout is 1h, and a browser holding an 8Gi-request pod past the review's end feeds the saturation `alert-scaleset-at-max-runners` reports.

**Warm-cache job** — same replacement, minus the preflight (best-effort by design).

### 3. Tester skill (`skills/review-functional-tester.md`)

Tool-for-tool substitution, plus three structural simplifications:

- **Turn 1 smoke check** collapses from a 3-attempt retry loop to one `agent-browser open about:blank`. There is no stdio server to race.
- **Batching** moves from "several MCP calls in one assistant response" to `agent-browser batch` with a JSON array-of-arrays on stdin. *The string form splits on whitespace and mangles quoted JS* — verified; the JSON form is mandatory whenever an `eval` is in the batch.
- **The a11y section** drops the CDN loader entirely for `agent-browser a11y --tags wcag2a,wcag2aa --json`.

Unchanged: the scope rule, severity mapping, evidence-integrity rules, the deadline anchors, and both output files.

### 4. Orchestrator skill (`skills/review-orchestrator.md`)

Three edits. The tools line stops claiming "No Playwright — … owns its own inline MCP server". The dispatch note stops saying "never pass MCP config". The screenshot-publishing sweep drops the `/tmp/playwright-mcp-output` / `.playwright-mcp` basename hunt, since `AGENT_BROWSER_SCREENSHOT_DIR` makes `/tmp/screenshots` the only destination.

### 5. Image G (`Dockerfile.claude-review`) and `versions.env`

**Delete:** the `~/pw-browsers` writable-store block and its symlink seeding, the `PLAYWRIGHT_BROWSERS_PATH` override, the `~/.cache/ms-playwright` symlink, the npx-prewarm RUN, the root chrome-channel apt install, the `MCP_CHROME_CHANNEL_LAUNCH_OK` assertion, and the four Playwright-related lines in the pipeline-probe assertion block.

**Add:** extract `bin/agent-browser-linux-x64` from the pinned tarball to `~/.local/bin/agent-browser`, run `agent-browser install` as `runner`, and assert with `doctor --json` that `chrome.installed` and `launch.elapsed` both pass. That single assertion replaces the hand-rolled `chromium.launch({channel:"chrome"})` check — and it is stronger, because it is the exact code path the tester takes rather than a reconstruction of it.

`versions.env`: `PLAYWRIGHT_MCP_VERSION` is deleted (image G was its only consumer); `PLAYWRIGHT_VERSION` **stays** — image B still needs it. `AGENT_BROWSER_VERSION` is added to the image-G section with the same LOCKSTEP warning, now guarding one pin instead of two. `IMAGE_TAG` bumps.

**This also lands the drift fix.** The migration removes both drifted pins from image G's critical path, so the one rebuild it requires is the same rebuild the drift needed. No separate remediation.

### 6. Docs

`README.md`: the architecture diagram's `[Setup]` line, the fleet-prerequisites paragraph (which currently tells operators to bake Playwright's chromium), the component list, and the two `review-functional-tester` bullets.

## Rollout order

The pipeline is consumed at a tag, and image G's `imagePullPolicy: IfNotPresent` means a republished tag never reaches cached nodes — so the two repos must land in this order:

1. **Image G first**, with a **new** `IMAGE_TAG`, rolled to `panenco-claude-review`. The new image is backward-compatible with the current pipeline: it still inherits image B's Playwright browsers and system libs, and it *adds* agent-browser rather than replacing anything the old pipeline probes. A pipeline still on the old tag keeps working — it just re-installs the chrome channel at runtime, exactly as it already does today given the drift.
2. **Pipeline second**, released as a new tag. Consumers pick it up on their next bump.

Between the two, the fleet carries both browsers. That is the point: there is no window where a review has neither.

## Verification

1. `agent-browser doctor --json` passes `chrome.installed` + `launch.elapsed` inside image G, as the `runner` user — asserted at image build, so drift fails the build rather than production.
2. A real review on a UI-bearing PR produces `overall: PASS|FAIL|WARN` (not `CRASH`) with a non-empty `screenshots[]`, and the images render in the PR gallery.
3. The functional tester's first turn succeeds on attempt 1 (no retry loop).
4. Wall-clock for the functional phase is no worse than the Playwright baseline.
5. `grep -ri playwright` in `panenco/claude-review` returns only historical spec/notes files.

## Risks

- **Upstream churn.** ~4 releases/week. Mitigated by exact pinning in both repos; the lockstep comment moves with it.
- **Chrome sandbox in the dind pod.** Image G's existing assertion sets `chromiumSandbox:false` for buildkit while noting the real pod *does* launch Chrome sandboxed. If agent-browser's launch differs, `AGENT_BROWSER_ARGS="--no-sandbox"` is the escape hatch — and the `doctor` preflight is what surfaces it, at image-build time.
- **arm64.** Not a risk today (fleet is amd64). Recorded above as the one thing that would break.
- **`batch` string-form quoting.** A real sharp edge, mitigated by making the JSON form mandatory in the skill.
