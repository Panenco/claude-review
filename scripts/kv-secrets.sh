#!/usr/bin/env bash
# kv-secrets.sh — the ONE parser for the pipeline's `KEY=VALUE` secret blobs.
#
# Two callers pass the same shape and must not drift: DEV_ENV_SECRETS (read by
# setup-dev-env.sh for dev-start.sh) and TRACKER_SECRETS (read by build-spec.sh
# for the fetch-issue.sh hook). Blank lines and `# comments` are skipped; only
# the FIRST `=` separates, so tokens containing `=` survive verbatim.
#
# Sourced, never executed. Covered by tests/dev_env_secrets_test.sh.

# export_kv_secrets <ENV_VAR_NAME> — export each KEY=VALUE line of that var.
export_kv_secrets() {
  local payload="${!1:-}" line
  [ -z "$payload" ] && return 0
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" != *=* ]] && continue
    export "${line%%=*}=${line#*=}"
  done <<< "$payload"
}
