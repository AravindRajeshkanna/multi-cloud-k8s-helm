INFRA_DIRS := infra/aws-eks infra/azure-aks infra/gcp-gke

.PHONY: help prereqs fmt fmt-check validate lint test

help: ## List targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

prereqs: ## Check the local toolchain (Phase 0)
	@./scripts/check-prereqs.sh

fmt: ## Format Terraform files
	terraform fmt -recursive infra

fmt-check: ## Fail if Terraform files are not formatted
	terraform fmt -check -recursive -diff infra

validate: ## terraform validate every cluster root (no cloud credentials needed)
	@for d in $(INFRA_DIRS); do \
		echo "==> $$d"; \
		terraform -chdir=$$d init -backend=false -input=false -no-color >/dev/null && \
		terraform -chdir=$$d validate -no-color || exit 1; \
	done

lint: ## shellcheck the scripts and actionlint the workflows
	shellcheck scripts/*.sh
	actionlint

test: ## Offline tests for scripts/cluster-ops.sh (cloud CLIs are stubbed)
	@./scripts/test-cluster-ops.sh
