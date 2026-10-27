# Phase 3: Design Portable Helm Charts

**Goal**: One chart, multiple values files.

Recommended structure:

```
mychart/
├── Chart.yaml
├── values.yaml              # defaults
├── values-eks.yaml
├── values-aks.yaml
├── values-gke.yaml
├── values-prod.yaml
└── templates/
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    ├── serviceaccount.yaml
    └── _helpers.tpl
```

**Cloud-specific handling** (use `if` / `eq` in templates or separate values):

- **Service / Ingress annotations**
  - EKS: ALB/NLB annotations (`service.beta.kubernetes.io/aws-load-balancer-type`)
  - AKS: Azure-specific load balancer or Application Gateway annotations
  - GKE: `cloud.google.com/load-balancer-type` or Gateway API
- **StorageClass**
  - EKS: `gp3` / `ebs-sc`
  - AKS: `managed-csi` / `azurefile-csi`
  - GKE: `standard-rwo` / `pd-balanced`
- **Workload Identity** (critical for security)
  - EKS: IRSA or Pod Identity → ServiceAccount annotation `eks.amazonaws.com/role-arn`
  - AKS: Azure AD Workload Identity → labels + annotations
  - GKE: Workload Identity Federation → `iam.gke.io/gcp-service-account`
- **Node selectors / tolerations / affinity** for dedicated pools (GPU, memory, etc.)

Best practices:

- Keep application logic cloud-agnostic.
- Externalize all cloud-specific config into values.
- Use Helm dependencies for shared components (e.g., common library chart).
- Version charts with SemVer; store in OCI registry or ChartMuseum / Harbor.
- Always set resource requests/limits, probes, and PodDisruptionBudgets.

---

## Implementation status

Not started. Hooks already provided by Phase 1:

- `ingressClassName` to reference: Terraform output `ingress_class_name` (`traefik`).
- User node pools are labelled `pool=user` (AKS), `pool=default` (EKS, GKE). AKS system nodes are tainted for critical add-ons only.
- Workload identity is enabled on all three clusters; the OIDC issuer / pool outputs are in each root's `outputs.tf`.
- No default `gp3` StorageClass exists on EKS yet — the EBS CSI driver is installed, the class is a Phase 3 item.
