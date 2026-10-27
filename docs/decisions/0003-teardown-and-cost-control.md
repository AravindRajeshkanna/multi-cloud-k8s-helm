# ADR 0003: Teardown and cost control

- **Status:** Accepted
- **Date:** 2026-10-27

## Context

Three always-on managed clusters bill continuously: control plane fees, nodes, NAT gateways, load balancers and disks. The goal is to stop all charges when the clusters are not needed and recreate them from CI on demand, with some assurance that nothing was left running.

## Options considered

| Option | Verdict |
|--------|---------|
| Scale node pools to zero | Rejected. Control plane fees, NAT, load balancers and disks continue; EKS and GKE need a node pool to keep system pods anyway. |
| "Stop" the cluster | Rejected. Only AKS offers it, and NAT, public IPs, disks and load balancers keep billing. |
| **Destroy everything with Terraform, recreate with Terraform** | Chosen. The only option that reaches zero for the cluster itself, and the code already describes the full stack. |

## Decisions

1. **Cost control is `destroy`.** The workflow has `plan`, `up` and `down` actions and a `cloud = all` choice. `up` and `down` run from `main` only, and `down` needs `confirm=destroy`.
2. **Drain before destroy.** Load balancers and disks created by Kubernetes controllers are unknown to Terraform. Before destroying, CI removes Ingresses, `LoadBalancer` Services and PersistentVolumeClaims and waits for the cloud to finish. If it cannot (API unreachable, a claim in use), the run stops instead of leaking resources.
3. **Verify afterwards, fail closed.** An audit lists billable resources still tied to the cluster and fails the run if there are any. An audit that cannot run is an error, never "clean". Azure is checked by resource group, AWS by tagged resource types, GCP by name patterns and Kubernetes-created forwarding rules.
4. **Hosted runners get a per-run API allow-list entry.** A new IP every run would otherwise lock `down` out of the cluster that `up` created. The runner's `/32` is added for each `up`/`down` and left in place until the next run. Rejected alternatives: opening the API to `0.0.0.0/0` (weaker), and requiring a static-IP runner (impractical for one person). `TF_RUNNER` remains available for a tighter setup. This amends [ADR 0001 §7](0001-platform-decisions.md).
5. **GKE deletion protection is off in CI.** `down` is already gated by `confirm`; provider-level protection would force a second apply on every teardown. Local runs keep the safe default (`true`).
6. **State and identities are never destroyed.** They are free or cost cents, and they are what makes the next `up` possible.
7. **A nightly cost guard is opt-in for destruction.** By default it only fails (and so emails) when it finds running clusters. `AUTO_TEARDOWN=true` makes it dispatch `down`.

## Consequences

- Recreating costs time (10–20 minutes per cloud) and yields a new cluster: new endpoints, load balancer addresses and empty volumes.
- Workloads, including their data, do not survive `down`. Anything worth keeping must live outside the clusters (managed databases, object storage) or be backed up (Phase 6).
- The audit is best effort: it covers the resource types listed in [cost-control.md](../cost-control.md), not everything a cloud can bill. A budget alert per account is the independent backstop and is recommended there.
- The cloud-facing commands in `scripts/cluster-ops.sh` are tested offline with stubbed CLIs; they have not yet been run against real accounts.
