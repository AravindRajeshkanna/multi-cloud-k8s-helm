# Phase 1: Provision Clusters

Use Infrastructure-as-Code so clusters are reproducible.

| Cloud | Recommended Tooling | Key Notes |
|-------|----------------------|-----------|
| **EKS** | Terraform + AWS EKS module or `eksctl` | Enable OIDC for IRSA / Pod Identity; multi-AZ; Karpenter or Cluster Autoscaler |
| **AKS** | Terraform or Azure CLI / Bicep | Enable Azure AD Workload Identity; system + user node pools |
| **GKE** | Terraform or `gcloud` | Prefer Autopilot for most workloads; enable Workload Identity Federation; release channels |

Common steps for all:

1. Create VPC/VNet/network with private subnets.
2. Provision control plane + node pools.
3. Configure private API endpoint where possible.
4. Install core add-ons via Helm or Terraform `helm_release`:
   - Metrics Server
   - Ingress controller (nginx, ALB, Azure Application Gateway, GKE Ingress/Gateway)
   - cert-manager
   - ExternalDNS (optional)
5. Set up kubeconfig / context switching (`kubectl config use-context`).

---

## Implementation status

Code lives in [infra/](../../infra/); the step-by-step runbook is [infra/README.md](../../infra/README.md).

| Step | EKS | AKS | GKE |
|------|-----|-----|-----|
| Tooling | Terraform + `terraform-aws-modules/eks` | Terraform (`azurerm`) | Terraform (`google`) |
| Cluster mode | Managed node group | System + user node pools, manual provisioning | Standard, separate node pool |
| 1. Private network | VPC, private/public subnets, NAT, 3 AZs | VNet, node subnet, NAT gateway | VPC, subnet + pod/service ranges, Cloud NAT |
| 2. Control plane + nodes | Managed node group, autoscaling | Autoscaling system pool (critical add-ons only) + user pool, zones 1–3 | Regional node pool, autoscaling per zone |
| 3. API endpoint | Private on; public optional, CIDR-restricted | Private cluster, or public with authorized ranges | Private nodes; public endpoint optional, CIDR-restricted |
| 4. Add-ons | metrics-server, Traefik, cert-manager | Traefik, cert-manager (metrics-server is built in) | Traefik, cert-manager (metrics-server is built in) |
| 5. Kubeconfig | `kubeconfig_command` output | `kubeconfig_command` output | `kubeconfig_command` output |
| Workload identity | IRSA + Pod Identity enabled | OIDC issuer + Workload Identity enabled | Workload Identity pool enabled |
| Autoscaling | Cluster Autoscaler (Pod Identity role) | Node pool autoscaler | Node pool autoscaler |
| Storage | EBS CSI driver add-on | Built-in CSI drivers | Built-in CSI drivers |
| Network policy | VPC CNI (enforcement is a Phase 6 item) | Cilium | Dataplane V2 (Cilium) |

### Taking it down and up

The [Clusters workflow](../../.github/workflows/terraform.yml) has `plan`, `up` and `down` actions for one cloud or `all`. `down` also removes Kubernetes-created load balancers and disks and then verifies that nothing billable remains; an optional nightly cost guard catches forgotten clusters. See [cost-control.md](../cost-control.md) and [ADR 0003](../decisions/0003-teardown-and-cost-control.md).

### Deliberately not done yet

- **ExternalDNS** — marked optional in the roadmap; needs a DNS zone and per-cloud identity. Add when a real domain is chosen.
- **ClusterIssuers** — cert-manager is installed, but issuers depend on a domain/email. Now provided as a chart, [charts/cluster-issuers](../../charts/cluster-issuers) (Phase 3); installing it is a Phase 4 step.
- **StorageClass defaults** (`gp3`, `managed-csi`, `standard-rwo`) — the Phase 3 webapp is stateless, so these move to the first stateful chart. EKS still lacks a `gp3` class ([charts.md](../charts.md#storage)).
- **Cloud-native ingress** (ALB, Application Gateway, GKE Ingress/Gateway) — see [ADR 0002](../decisions/0002-ingress-controller.md); revisit in Phase 3.
- **Karpenter** — Cluster Autoscaler is used; Karpenter can replace it in Phase 6.
- **Entra ID RBAC for AKS** and **fully private API endpoints** — Phase 6 hardening.

### Not yet verified

`terraform validate` and `terraform fmt` pass for all three roots in CI, the Helm values were rendered against the pinned charts, the CIDR guard rails were exercised, and the drain / audit / allow-list scripts pass offline tests with stubbed cloud CLIs. **No `plan`, `apply` or `down` has been run against a real cloud account.** Expect to fix small provider-side issues on the first apply of each cloud.
