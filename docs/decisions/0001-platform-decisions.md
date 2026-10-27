# ADR 0001: Platform decisions

- **Status:** Accepted
- **Date:** 2026-10-27

## Context

The roadmap's Phase 0 lists the choices to make before building anything ("Decide early"). Phase 1 adds the tooling choice. This record fixes them so later phases do not reopen them by accident.

## Decisions

### 1. Cluster mode: Standard

We run **Standard** clusters on all three clouds: we define node pools, sizes and autoscaling bounds.

- EKS: managed node groups (not EKS Auto Mode).
- AKS: manual node provisioning (`node_provisioning_profile.mode = "Manual"`), system + user pools.
- GKE: **Standard**, not Autopilot.

The Phase 1 table says "prefer Autopilot" for GKE; the Phase 0 decision overrides it so that all three clouds behave alike (explicit node pools, taints, DaemonSets, node-level tuning).

### 2. Topology: one cluster per cloud, namespaces for environments

Three clusters total: `mc-eks`, `mc-aks`, `mc-gke`. Environments (dev, staging, prod) are separated by namespaces, quotas and RBAC inside each cluster, not by more clusters. The roadmap's "one cluster with namespaces" is read as "one cluster *per cloud*". Revisit if a hard isolation requirement for prod appears.

### 3. Delivery: plain Helm + CI

Workloads are installed with `helm upgrade --install` from GitHub Actions. No Argo CD / Flux until Phase 5 reopens the question. The Helm client version (Helm 4) and how it is pinned are in [ADR 0004](0004-helm-client.md).

### 4. Infrastructure as code: Terraform

Terraform, with one root module per cloud (`infra/aws-eks`, `infra/azure-aks`, `infra/gcp-gke`) and one shared module for cloud-agnostic add-ons (`infra/modules/core-addons`). Roots are separate so each cloud has its own state, blast radius and provider set.

Terraform ≥ 1.6 is licensed under BUSL-1.1 ([licenses.md](../licenses.md)). OpenTofu is a possible alternative if that matters to you; it has not been tested with these configurations.

### 5. State: remote, in each cloud's own object store

S3 (EKS), Azure Blob (AKS), GCS (GKE). Backend settings are not committed; they are passed with `-backend-config` (`backend.hcl` locally, GitHub variables in CI).

### 6. CI authentication: OIDC federation, no static cloud keys

GitHub Actions exchanges its OIDC token for short-lived cloud credentials (AWS IAM role, Entra federated credential, GCP Workload Identity Federation). Trust is bound to this repository and to one GitHub Environment per cloud. See [github-secrets.md](../github-secrets.md).

### 7. API endpoint exposure: private endpoint plus a CIDR-restricted public endpoint

Roadmap: "private API endpoint where possible". Terraform (and Helm) must reach the API server to install add-ons, and GitHub-hosted runners have no stable IPs, so a fully private control plane cannot be managed from them.

- Nodes are always private.
- By default the public endpoint stays on, but only for explicitly listed CIDRs (`api_authorized_cidrs`). An empty list or `0.0.0.0/0` is rejected by variable validation.
- `enable_public_endpoint = false` gives a fully private control plane; run Terraform from a runner inside the network (`TF_RUNNER`).
- On the default hosted runner, CI adds that run's public IP to the allow-list; see [ADR 0003](0003-teardown-and-cost-control.md).

## Consequences

- Same shape on every cloud, so Phase 3 values files differ only where the clouds genuinely differ.
- Whatever runs `apply` must have its egress IP in `api_authorized_cidrs`; CI arranges that for hosted runners ([ADR 0003](0003-teardown-and-cost-control.md)).
- Hardening deferred to Phase 6 is listed in [phase 6](../roadmap/phase-6-observability-security-operations.md).
