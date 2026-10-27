# Phase 6: Observability, Security & Operations

- **Observability**: Prometheus + Grafana (or cloud-native: CloudWatch, Azure Monitor, Google Cloud Monitoring) + OpenTelemetry. Deploy via Helm.
- **Security hardening**
  - Workload Identity everywhere (no node instance profiles)
  - NetworkPolicies / Cilium
  - Pod Security Standards
  - Private clusters + restricted egress
  - Regular image + chart vulnerability scanning
- **Cost & scaling**
  - HPA + VPA (recommendation mode first)
  - Cluster Autoscaler / Karpenter (EKS) / node auto-provisioning
  - Spot/preemptible nodes where appropriate
  - Resource quotas & LimitRanges per namespace
- **Disaster recovery**
  - Backup with Velero
  - Multi-region / multi-cluster strategies if required

## Quick Reference – Cloud Differences to Handle in Values

- Identity: IRSA / Pod Identity (EKS) vs Entra Workload ID (AKS) vs Workload Identity (GKE)
- Load balancing / Ingress annotations
- StorageClass names
- ServiceAccount annotations/labels
- Node selectors & taints for specialized pools

---

## Implementation status

**Partly built, partly deliberately left.** Tested on throwaway kind clusters in CI; nothing has run on EKS, AKS or GKE. Guides: [observability.md](../observability.md), [hardening.md](../hardening.md), [operations.md](../operations.md). Decisions and the reasons for what was left: [ADR 0009](../decisions/0009-hardening-and-operations.md).

| Roadmap item | Status |
|--------------|--------|
| Observability: Prometheus + Grafana, deployed with Helm | **Done, optional and off by default.** kube-prometheus-stack via Terraform (`enable_monitoring` / the `ENABLE_MONITORING` variable); the app ships a `ServiceMonitor` and three alerts. CI checks that Prometheus scrapes the app through its network policy and loads the rules |
| Cloud-native monitoring, OpenTelemetry | **Not done.** One portable stack rather than three clouds' tools; the sample app emits no traces |
| Workload Identity everywhere, no node instance profiles | **Done / already so.** Pods use Pod Identity or Workload Identity; EKS nodes allow only IMDSv2 with a hop limit of 1, now set explicitly |
| NetworkPolicies / Cilium | **Done.** Default-deny, DNS, ACME and per-app policies in every workload namespace; enforced by Cilium (AKS, GKE) and by the VPC CNI on EKS (switched on). Tested with real pods on two network plugins |
| Pod Security Standards | **Done in the workload namespaces** (Phase 5); not extended to platform namespaces, which need privileges |
| Private clusters + restricted egress | **Not done.** Fully private endpoints need a runner in the network; cloud-level egress filtering needs an allow-list learned from a running cluster. Namespaces do deny egress by default |
| Regular image + chart vulnerability scanning | **Done for images** (Phase 5, now 17 including the monitoring stack). Chart scanning is not done |
| HPA | **Done** (Phase 3) |
| VPA (recommendation mode) | **Not done.** Needs hours of real load to recommend anything |
| Cluster Autoscaler / Karpenter / node auto-provisioning | Autoscaler **done** (Phase 1); Karpenter **not done** |
| Spot / preemptible nodes | **Not done** |
| Resource quotas & LimitRanges per namespace | **Done** (with a lesson in [hardening.md](../hardening.md#a-trap-worth-knowing-limitrange-defaults)) |
| Disaster recovery: Velero, multi-region | **Not done, by design.** Recovery is a rebuild ([operations.md](../operations.md#disaster-recovery)); nothing stateful exists to back up |
| Phase 1 items: Entra ID RBAC, GKE public addresses, Karpenter | **Not done**, each with its reason in [hardening.md](../hardening.md#what-was-not-done-and-why) |

### What the CI runs found in this phase

The new tests found six real problems in the first versions of the work, which is the case for having them:
1. A `LimitRange` with `min` / `max` silently **defaulted** missing requests and limits, so pods declaring no resources were admitted with a 2 GiB limit and the admission policy was defeated.
2. A CPU ratio in that LimitRange forced a CPU limit on every pod, contradicting the admission policy.
3. The `helm test` pod carried the app's own labels, so the Service would have routed traffic to it (a Phase 3 bug, found while writing the network policy).
4. Helm's `--set` leaves decimals as strings, so a fractional alert threshold could not be set; it is a whole percentage now.
5. Grafana was **OOM-killed** by a 300 MiB limit while importing its default dashboards, on some runs and not others.
6. I believed kind's default network plugin ignores NetworkPolicy; the test that asserts the expected behaviour showed it does not. The advice I had read was out of date.

### Not proved until a real `up`

Everything above on EKS, AKS and GKE: that the VPC CNI enforces the policies, that the monitoring stack fits and scrapes the managed clusters, and that the resource sizes hold on real node pools.
