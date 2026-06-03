# Convenience wrapper for the cost/metrics tooling (scripts/cost-snapshot.sh).
#
# Repo list and owner come from the environment or a local, git-ignored
# `.metrics.env` — so NO private repo names live in this PUBLIC repo.
#
#   make metrics                 # use .metrics.env (REPOS=... etc.) — fast, no Claude $ recovery
#   make metrics FULL_COST=1     # also recover Claude $ for pre-instrumentation runs (slow)
#   make metrics REPOS=o/a,o/b   # ad-hoc repo list (overrides .metrics.env)
#   make metrics OWNER=my-org    # discover an org's repos instead of listing them
#   make metrics SINCE=30d       # window (default 7d)
#
# Output is written to docs/metrics/<date>.md, which is git-ignored (it holds
# real per-repo spend — internal financial data). Never commit it.

SINCE ?= 7d
-include .metrics.env

.PHONY: release
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=vX.Y.Z"; exit 1; }
	@bash scripts/release.sh $(VERSION)

.PHONY: metrics
metrics:
	@bash scripts/cost-snapshot.sh \
	  --since $(SINCE) \
	  $(if $(REPOS),--repos $(REPOS)) \
	  $(if $(OWNER),--owner $(OWNER)) \
	  $(if $(FULL_COST),--full-cost) \
	  --write docs/metrics/$$(date +%F).md
	@echo "→ wrote docs/metrics/$$(date +%F).md (git-ignored — internal data)"
