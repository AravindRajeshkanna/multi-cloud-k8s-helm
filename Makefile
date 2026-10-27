INFRA_DIRS := infra/aws-eks infra/azure-aks infra/gcp-gke

.PHONY: help prereqs hooks helm-repos fmt fmt-check validate lint test

help: ## List targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

prereqs: ## Check the local toolchain (Phase 0)
	@./scripts/check-prereqs.sh

hooks: ## Run CI's fast checks before every commit (git pre-commit hook)
	git config core.hooksPath .githooks
	@echo "pre-commit hook enabled: .githooks/pre-commit runs fmt-check, lint and test"

helm-repos: ## Add the Helm chart repositories the platform add-ons come from (Phase 2)
	helm repo add jetstack https://charts.jetstack.io --force-update
	helm repo add traefik https://traefik.github.io/charts --force-update
	helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server --force-update
	helm repo add autoscaler https://kubernetes.github.io/autoscaler --force-update
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo update

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

test: ## Offline tests: the cluster and deploy scripts (CLIs stubbed) and the Helm charts
	@./scripts/test-cluster-ops.sh
	@./scripts/test-deploy.sh
	@./scripts/test-scan-summary.sh
	@./scripts/test-charts.sh
