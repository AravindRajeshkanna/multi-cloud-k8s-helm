# Roadmap: Deploy Workloads on EKS, AKS & GKE Using Helm via GitHub Actions

This is a practical, phased path that works across all three managed Kubernetes services. Helm charts are largely portable because EKS, AKS, and GKE are CNCF-conformant. The main differences appear in identity, storage classes, load balancers/ingress, and networking annotations — handle these with values files and templating rather than separate charts.

> **Credentials.** Cloud credentials are configured by the repository owner as GitHub secrets, manually. This repo only ships guidance: [github-secrets.md](../github-secrets.md).

## Status

| Phase | Title | Status |
|-------|-------|--------|
| [0](phase-0-prerequisites.md) | Prerequisites & Foundations | **Done** (decisions recorded, tooling check, CI auth guidance) |
| [1](phase-1-provision-clusters.md) | Provision Clusters | **Implemented, not yet applied** — Terraform validates for all three clouds, with CI `plan` / `up` / `down`; nothing has been run against a real account |
| [2](phase-2-install-configure-helm.md) | Install & Configure Helm | **Implemented, not yet run against real clusters** — Helm 4 pinned, contexts, repos, and a live-cluster Helm check workflow |
| [3](phase-3-portable-helm-charts.md) | Design Portable Helm Charts | **Implemented, not yet deployed to real clusters** — `webapp` and `cluster-issuers` charts, tested by rendering and on a kind cluster |
| [4](phase-4-deploy-workloads.md) | Deploy Workloads | **Implemented, not yet run on real clusters** — `deploy.sh`, Deploy workflow, `deploy` option on `up`; shared services and External Secrets deferred |
| [5](phase-5-cicd-gitops.md) | CI/CD & GitOps | Not started (basic validation CI exists from Phase 1) |
| [6](phase-6-observability-security-operations.md) | Observability, Security & Operations | Not started |

## Decisions that shape every phase

Recorded in [ADR 0001](../decisions/0001-platform-decisions.md), [ADR 0002](../decisions/0002-ingress-controller.md), [ADR 0003](../decisions/0003-teardown-and-cost-control.md), [ADR 0004](../decisions/0004-helm-client.md), [ADR 0005](../decisions/0005-chart-portability.md) and [ADR 0006](../decisions/0006-deployment-model.md):

- **Cluster mode:** Standard (we own the node pools) on all three clouds.
- **Topology:** one cluster per cloud, with namespaces separating environments.
- **Delivery:** plain Helm driven from CI (GitHub Actions). No GitOps controller until Phase 5.
- **Helm:** Helm 4, pinned in `.tool-versions` (the roadmap says Helm 3, which is in its end-of-life window).
- **Charts:** one chart per workload; clouds differ in values files only, and templates name no cloud.
- **Deployment:** one script (`scripts/deploy.sh`) from `main`, validated against the real load balancer; `dev` needs no domain, `prod` does.
- **Ingress:** Traefik, because ingress-nginx was retired in March 2026.
- **Cost:** destroy and recreate from CI rather than idle; see [ADR 0003](../decisions/0003-teardown-and-cost-control.md) and [cost-control.md](../cost-control.md).

## Open questions

- **GKE Autopilot.** The Phase 1 table prefers Autopilot, but the Phase 0 decision is Standard. This repo follows the Phase 0 decision.

## Starting point

Start with one simple stateless app (e.g., a web service + ingress + cert-manager) on all three clusters using the same chart and different values files. Once that works reliably, expand to stateful workloads, GitOps, and production hardening.

This path gives a single source of truth (Helm charts + values) while respecting the unique strengths and identity models of each cloud.
