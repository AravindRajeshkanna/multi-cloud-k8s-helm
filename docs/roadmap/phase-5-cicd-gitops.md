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

**Partly built, partly decided.** The pipeline map is [pipeline.md](../pipeline.md); decisions are [ADR 0007](../decisions/0007-delivery-strategy.md) (delivery) and [ADR 0008](../decisions/0008-policy-and-supply-chain.md) (policy and supply chain). Nothing here has run against EKS, AKS or GKE; the policy tests and the chart installs run on a throwaway kind cluster in CI.

| Roadmap item | Status |
|--------------|--------|
| 1. Build and push images to ECR / ACR / Artifact Registry | **Deferred.** No first-party image to build, and a registry per cloud is a standing cost (ACR bills daily). First step when one exists: GHCR. Admission policy already allows each cloud's registry |
| 2. Update the image tag | **Done.** `IMAGE_TAG` in `deploy.sh` and the Deploy workflow's `image_tag` input (`--set-string image.tag=`) |
| 3. GitOps (Argo CD / Flux), promotion PR to prod | **Reconsidered, not adopted.** A reconciling controller would fight the teardown drain, and the deploy's validation would still need CI. Promotion is PR, then dev, then prod, each deliberate; revisit triggers are in ADR 0007 |
| Alternative: CI pipeline with `helm upgrade --install` | **This is the delivery path** (Phase 4), now with policies enforced at the API |
| Pre-commit / CI validation | **Done.** `helm lint`, `helm template` and chart assertions (Phase 3), plus a git pre-commit hook (`make hooks`) running the same checks locally |
| Policy checks (Kyverno or OPA) | **Done, natively.** Four ValidatingAdmissionPolicies and Pod Security `restricted`, enforced in the workload namespaces and tested on kind ([policies.md](../policies.md)). Not Kyverno/OPA, and why is in ADR 0008 |
| Image scanning and SBOM | **Done.** Weekly and on-PR scan of all 9 images the clusters ran then (17 now that the optional monitoring stack is included), CycloneDX SBOMs as artifacts ([supply-chain.md](../supply-chain.md)); actions pinned to commit SHAs after the March 2026 Trivy incident. **The first scan found real issues:** the Cluster Autoscaler chart's default image lagged two upstream patch releases (now pinned to v1.35.2, cutting High findings from 38 to 26), and three critical findings in the autoscaler and two in metrics-server have no upstream fix released yet, so they are accepted with an expiry of 2026-12-11 ([how](../supply-chain.md#findings-nobody-has-fixed-yet)) |
| Canary / progressive delivery | **Deferred.** Needs a controller, weighted routing and an app with traffic; ADR 0007 |
| Phase 1 gaps: plan-on-PR, approval between plan and apply | **Not adopted.** Both need new cloud-side trust (a PR-scoped identity, separate approval environments); options and the revisit trigger are in ADR 0007 |

### Carried forward

- `tflint` is still not in CI. It could not be run locally to confirm a clean baseline when Phase 1 was written.
- Pod Security, network policies and RBAC hardening beyond the workload namespaces are Phase 6.
- **Exceptions expire 2026-12-11.** The weekly scan fails again then unless the entries in `supply-chain-exceptions.txt` are renewed or the images updated.
- Not proved until a real deploy: the policies on the real clusters, and the Let's Encrypt challenge exemption (needs a domain).
