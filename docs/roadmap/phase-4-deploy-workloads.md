# Phase 4: Deploy Workloads

Typical flow:

```bash
# Example for EKS
helm upgrade --install myapp ./mychart \
  -f values.yaml \
  -f values-eks.yaml \
  -f values-prod.yaml \
  --namespace myapp --create-namespace \
  --kube-context eks-prod
```

Repeat for AKS and GKE with the corresponding values files.

Order of operations:

1. Deploy platform add-ons (ingress, cert-manager, monitoring).
2. Deploy shared services (databases via operators or managed cloud services + External Secrets).
3. Deploy application charts.
4. Validate: `helm list`, `kubectl get all -n <ns>`, smoke tests, HPA behavior.

Secrets: Prefer External Secrets Operator + cloud secret managers (AWS Secrets Manager, Azure Key Vault, GCP Secret Manager) over plain Kubernetes Secrets.

---

## Implementation status

Not started. Step 1 (platform add-ons: ingress, cert-manager) is done by Phase 1's Terraform; monitoring arrives with Phase 6. Replace `eks-prod` in examples with the real context name (`mc-eks`, `mc-aks`, `mc-gke`).
