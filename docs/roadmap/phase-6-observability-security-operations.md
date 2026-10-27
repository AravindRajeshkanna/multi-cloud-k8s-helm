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

Not started. Phase 1 leaves these hardening items for here:

- AKS uses local (cluster-admin certificate) accounts; move to Entra ID RBAC + `kubelogin`.
- Public API endpoints are CIDR-restricted but still public; move to private endpoints with a runner inside the network.
- EKS: enforce NetworkPolicy (VPC CNI network policy or Cilium); GKE and AKS already run Cilium.
- GKE `master_authorized_networks_config` still admits Google-owned public IPs by default; consider disabling.
- Cluster Autoscaler on EKS → evaluate Karpenter.
- NAT egress is open; add restricted egress.
