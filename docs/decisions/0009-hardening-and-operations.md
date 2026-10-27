# ADR 0009: Hardening, observability and operations

- **Status:** Accepted
- **Date:** 2026-10-27

## Context

Phase 6 asks for observability, security hardening, cost and scaling controls, and disaster recovery. Earlier phases left a list of hardening items for it. The constraints that shape every answer: the clusters are disposable and mostly down ([ADR 0003](0003-teardown-and-cost-control.md)); CI is the only deployer; nothing has run on a real cloud account; and the only way to test a Kubernetes behaviour here is a throwaway kind cluster in CI.

## Decisions

1. **Each workload namespace gets a quota, a limit range and default-deny network policies, applied before the first pod.** Applications open what they need with their own policy (the `webapp` chart does). The limit range uses only a memory limit/request ratio: its `min` and `max` would make Kubernetes default a pod's missing requests and limits, silently defeating the admission rule that requires pods to declare them. CI caught that in the first version.

2. **NetworkPolicy must be enforced, not just accepted.** AKS and GKE run Cilium already; on EKS the VPC CNI's network policy support is switched on in Terraform. CI tests the rules with real pods on two network plugins and *asserts* what each cluster should do, because a policy that is silently ignored looks identical to one that works. (That assertion corrected a belief of mine: kind's default plugin does enforce.)

3. **Monitoring is an optional, default-off add-on: kube-prometheus-stack, with no persistence, no Alertmanager and nothing exposed.** Off, because it requests about 1.1 GiB of memory (up to 2.7 GiB at its limits) on small node pools and the first real `up` should be easy to diagnose. No persistence, because metrics for a disposable cluster are a window, not an archive. No Alertmanager, because the destination is the owner's to choose. One values file serves Terraform and the CI test. The application ships its own `ServiceMonitor` and alerts, enabled automatically where the Prometheus Operator exists.

4. **Cloud-native monitoring (CloudWatch, Azure Monitor, Google Cloud Monitoring) is not used.** It would put a different tool, query language and bill on each cloud, against the point of one portable platform.

5. **Disaster recovery is "rebuild", and that is documented, not hidden.** Clusters hold nothing worth backing up while the only workload is stateless; recovery time is the time to `up` and `deploy`. There are no backups of workload data. Velero and multi-region are deferred to the first workload with data that matters, and the advice then is a managed database or object storage outside the cluster.

6. **The Phase 1 hardening items that cannot be done honestly without real accounts stay undone, each with its reason** in [hardening.md](../hardening.md): AKS Entra ID RBAC (changes how CI authenticates, tenant-specific), fully private endpoints (needs a runner in the network), the GKE public-address setting (it may be reset by `allow-ip`), cloud-level egress filtering (needs an allow-list learned from a running cluster), Karpenter, VPA, spot nodes, and Pod Security beyond the workload namespaces.

## Consequences

- Every deployment is now bounded by a quota, so a workload that outgrows it (more than 30 pods, 4 CPUs requested, 4 GiB requested) fails to schedule with a quota message; raise `policies/namespace/resource-quota.yaml` deliberately.
- A new application must ship a network policy for its own traffic, or it cannot be reached.
- Enabling monitoring is a Terraform variable, so it changes with the next `up`.
- The Grafana component is AGPL-3.0, the rest Apache-2.0. It is run unmodified from the upstream image; read the licence before modifying it.
- What is proven: the rules and the monitoring stack, on kind, in CI. What is not: any of it on EKS, AKS or GKE.

## Alternatives considered

- **Monitoring on by default.** Nicer to have, harder to debug a first `up`.
- **A service mesh for network policy and telemetry.** Far more machinery than one stateless app warrants.
- **Skipping the quota and limit range.** They are cheap, and the quota's side effect (every pod must declare resources) matches the admission rule's intent.
