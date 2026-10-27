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

Not started. Notes carried forward from earlier phases:

- Phase 1 already installs Traefik, cert-manager and (on EKS) metrics-server through Terraform's `helm_release`. Phase 2 covers the Helm **client** used for workloads.
- `ingress-nginx` was retired in March 2026 and should not be added as a repo ([ADR 0002](../decisions/0002-ingress-controller.md)).
- Decide Helm 3 vs Helm 4 here (see the [open questions](README.md#open-questions)) and pin it in CI.
- The kubecontext names are the cluster names: `mc-eks`, `mc-aks`, `mc-gke`.
