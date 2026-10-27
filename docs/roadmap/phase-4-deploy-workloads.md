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

**Implemented; tested offline and against a throwaway kind cluster, not yet run on EKS, AKS or GKE.** Guide: [deploying.md](../deploying.md). Decisions: [ADR 0006](../decisions/0006-deployment-model.md).

| Roadmap item | What was done |
|--------------|---------------|
| `helm upgrade --install ... -f values -f values-<cloud> -f values-<env> --kube-context` | [scripts/deploy.sh](../../scripts/deploy.sh): the same command for every cloud, with the real context names (`mc-eks`, `mc-aks`, `mc-gke`), `--wait --rollback-on-failure`, namespace `web-<dev\|prod>` |
| 1. Platform add-ons | Ingress, cert-manager, metrics-server and the autoscaler come from Phase 1's Terraform. The deploy installs the cert-manager issuers on top (`charts/cluster-issuers`). Monitoring arrives with Phase 6 |
| 2. Shared services | **Deferred.** No workload needs a database or cache yet |
| 3. Application charts | The `webapp` chart, `dev` and `prod` |
| 4. Validate | `helm test`, certificate issuance, the autoscaler receiving metrics, and an HTTPS request through the cloud load balancer, in the script and so on every deployment |
| Secrets via External Secrets Operator | **Deferred.** The chart reads Secrets by reference (`envFrom`, `extraEnv`), nothing is stored in the repo, and the intended per-cloud design is in [deploying.md](../deploying.md#secrets). The operator needs identities and stores that cannot be tested without real accounts |
| Phase 1 gap: workloads return after `up` | The Clusters workflow has a `deploy` input; `up` with `deploy=dev` brings a torn-down setup fully back |

Workflows: [deploy.yml](../../.github/workflows/deploy.yml) (any time, from `main`), and the `deploy` input of [terraform.yml](../../.github/workflows/terraform.yml). Both use the new `cluster-access` composite action for login, runner access and the kubeconfig.

### How it is tested

- `scripts/test-deploy.sh` (CI, `make test`): stubbed `helm`, `kubectl` and `curl`; 64 checks of what is called with which arguments and of every failure path. I broke the script deliberately (rollback dropped, wrong values order, certificate and autoscaler checks removed, context not passed, helm test skipped, the ingress request removed) and every breakage is caught; the first round exposed one assertion that proved nothing about the app's install, which was tightened.
- The kind job in CI ends by running the real `deploy.sh` against the throwaway cluster, with a request sent from the runner through Traefik's node port.

### Not covered until a real `up`

The load balancer address lookup and the request through a real cloud load balancer; metrics-server on the real clusters; the node pool labels; Let's Encrypt (needs a domain); the cloud-specific parts of the `cluster-access` action (the same calls `helm-check.yml` already made).
