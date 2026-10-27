# Phase 5: CI/CD & GitOps

**Recommended modern path**:

1. Build & push images (ECR / ACR / Artifact Registry).
2. Update image tag in values or use Helm with `--set image.tag=...`.
3. GitOps with **Argo CD** or **Flux**:
   - One Git repo (or monorepo) holding charts + environment overlays.
   - Argo CD ApplicationSets or Flux Kustomizations that target multiple clusters.
   - Promotion path: PR → dev → staging → prod.

Alternative: CI pipeline (GitHub Actions, GitLab CI, Azure DevOps, CodePipeline) that runs `helm upgrade --install` against each cluster.

Add:

- Pre-commit / CI validation (`helm lint`, `helm template`, policy checks with Kyverno or OPA)
- Image scanning & SBOM
- Canary / progressive delivery (Argo Rollouts or Flagger)

---

## Implementation status

Not started. The Phase 0 decision is **plain Helm + CI** (GitHub Actions); GitOps is the alternative to revisit here.

Already in place from Phase 1:

- [ci.yml](../../.github/workflows/ci.yml): `terraform fmt`, `terraform validate` per cloud, `shellcheck`.
- [terraform.yml](../../.github/workflows/terraform.yml): manual `plan` / `up` / `down` per cloud or all clouds, over OIDC; [cost-guard.yml](../../.github/workflows/cost-guard.yml): nightly check for forgotten clusters ([cost-control.md](../cost-control.md)).
- Dependabot for GitHub Actions and Terraform.
- [helm-check.yml](../../.github/workflows/helm-check.yml): read-only check that the pinned Helm 4 reaches each live cluster and the platform add-ons are `deployed` ([helm.md](../helm.md)). Phase 4's deploy job can reuse its login / kubeconfig steps.

Phase 4 added [deploy.yml](../../.github/workflows/deploy.yml) and a `deploy` input on `up`, so a brought-up cluster can come back with its applications ([deploying.md](../deploying.md)). It deploys the repository's charts from a checkout of `main`; promotion across environments from versioned artifacts is the part left for this phase.

Also from Phase 3: the `charts` and `charts-kind` jobs in [ci.yml](../../.github/workflows/ci.yml) lint and render every chart (`helm lint --strict`, `helm template`) and install them on a throwaway kind cluster.

Gaps to close in this phase: policy checks (Kyverno / OPA), image scanning, plan-on-pull-request, and an approval gate between `plan` and `apply` (today approval, if any, comes from environment reviewers *before* the plan runs). `tflint` was left out of Phase 1 because it could not be run locally to confirm a clean baseline.
