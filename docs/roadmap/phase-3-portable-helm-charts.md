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

**Implemented; tested by rendering and on a throwaway kind cluster, not yet on EKS, AKS or GKE.** Usage: [charts.md](../charts.md). Decisions: [ADR 0005](../decisions/0005-chart-portability.md).

Code is in [charts/](../../charts/): `webapp` (a stateless service, podinfo by default) and `cluster-issuers`. The layout follows the roadmap, plus a `values.schema.json`, `values-dev.yaml`, a `helm test` pod and `NOTES.txt`.

| Roadmap item | What was done |
|--------------|---------------|
| One chart, multiple values files | `values.yaml`, `values-{eks,aks,gke}.yaml`, `values-{dev,prod}.yaml`, layered with `-f`. Tests render all 12 cloud x environment combinations |
| Service / Ingress annotations | None needed per cloud: with Traefik the app is `ClusterIP` behind one ingress class. Cloud load-balancer annotations stay on Traefik's Service (Phase 1). The reasoning is in ADR 0005 |
| StorageClass (`gp3` / `managed-csi` / `standard-rwo`) | **Deferred to the first stateful chart.** The webapp is stateless; the classes and the missing EKS `gp3` class are listed in [charts.md](../charts.md#storage) |
| Workload identity | `serviceAccount.annotations` and `podLabels` carry IRSA, Azure Workload Identity and GKE Workload Identity; the per-cloud files show each, and tests prove the wiring. EKS Pod Identity needs nothing in the chart |
| Node selectors / tolerations / affinity | Pass-through values; the per-cloud files select the pool labels Terraform sets (`pool=default` on EKS and GKE, `pool=user` on AKS) |
| Keep logic cloud-agnostic, externalize config | Templates name no cloud (a test enforces it); cloud files may only set placement, identity and labels (also enforced) |
| Shared library chart | **Deferred** until a second application shows what to share |
| SemVer; store in OCI registry / ChartMuseum / Harbor | SemVer in `Chart.yaml`. **Registry publishing deferred to Phase 5** (needs a registry and credentials chosen); charts deploy from the repo checkout |
| Always set requests/limits, probes, PDBs | All three, plus restricted security context, soft zone/node spreading and an optional HPA. The schema refuses a chart without requests and limits |
| Phase 1 deferral: ClusterIssuers | `charts/cluster-issuers`: `selfsigned`, `letsencrypt-staging`, `letsencrypt-prod` |

### How it is tested

- `scripts/test-charts.sh` (`make test`, CI): lint and render every combination and assert on the manifests with `jq` (97 checks), including negative tests for the guards. Six deliberate breakages of the chart were each caught.
- `scripts/test-charts-kind.sh` (CI, on a fresh kind cluster): installs cert-manager, the issuers and Traefik at the versions Terraform pins, then installs the chart with each cloud's values file, runs `helm test`, upgrades dev to prod values, waits for the issued certificate and sends requests through Traefik.
- cert-manager's `ClusterIssuer` fields were checked against the CRD at the pinned version.

Not covered: the real clusters. Node pool labels, the metrics-server dependency of the HPA, and the storage class names are expectations taken from the Terraform code, to be confirmed in Phase 4.

### Hooks from Phase 1 the charts use

- `ingressClassName: traefik` (Terraform output `ingress_class_name`).
- Node pool labels `pool=default` (EKS, GKE) and `pool=user` (AKS); AKS system nodes are tainted for critical add-ons only.
- Workload identity enabled on all three clusters; the OIDC issuer / pool outputs are in each root's `outputs.tf`.
- cert-manager and its CRDs.
