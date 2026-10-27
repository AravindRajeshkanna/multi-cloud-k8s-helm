# Phase 2: Install & Configure Helm

```bash
# Official install (Linux/macOS)
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
```

- Verify: `helm version`
- Add common repos: Bitnami, ingress-nginx, jetstack (cert-manager), etc.
- For multi-cloud: maintain separate kubecontexts and use `--kube-context` or switch contexts.

Helm works out-of-the-box on all three platforms.

---

## Implementation status

**Implemented, not yet run against real clusters:** nothing has been applied to a real account, so the live-cluster Helm check has not run. Usage guide: [helm.md](../helm.md).

| Roadmap item | What was done |
|--------------|---------------|
| Install Helm | **Helm 4**, pinned in [.tool-versions](../../.tool-versions) and installed in CI with `azure/setup-helm`. `make prereqs` rejects Helm 3 and flags a local Helm older than the pin. Decision and reasons: [ADR 0004](../decisions/0004-helm-client.md) |
| `helm version` | Printed by the [Helm check](../../.github/workflows/helm-check.yml) workflow and `make prereqs` |
| Add common repos | `make helm-repos` adds jetstack, traefik, metrics-server and autoscaler (the sources Terraform pins from). Their URLs and the pinned chart versions were checked against the live repositories. **ingress-nginx** is retired ([ADR 0002](../decisions/0002-ingress-controller.md)) and **Bitnami** stopped updating its free catalog ([ADR 0004](../decisions/0004-helm-client.md#why-not-bitnami)), so neither is added |
| Separate kubecontexts, `--kube-context` | One context per cluster, named after it (`mc-eks`, `mc-aks`, `mc-gke`). `scripts/cluster-ops.sh kubeconfig <cloud>` creates a separate kubeconfig file; the rule is to always pass `--kube-context` |
| Works on all three platforms | Unproven until the Helm check runs against real clusters: it lists releases and requires the Phase 1 add-ons to be `deployed` |

Phase 1 already installs Traefik, cert-manager and (on EKS) metrics-server and Cluster Autoscaler through Terraform's `helm_release`. Phase 2 is the Helm **client** used for workloads.

### Carried forward

- The open Helm 3 vs 4 question is closed: Helm 4.
- Keep Helm inside the supported Kubernetes window when the clusters' versions change ([ADR 0004](../decisions/0004-helm-client.md#consequences)). `.tool-versions` is not updated by Dependabot.
- Phase 4 reused the Helm check's steps. They now live in the `cluster-access` composite action (login, allow the runner, kubeconfig), used by `helm-check.yml` and `deploy.yml`; `terraform.yml` keeps its own because it needs the runner IP as a Terraform variable before the cluster exists.
