# multi-cloud-k8s-helm

Deploy workloads on **EKS, AKS & GKE** using **Helm**, via **GitHub Actions**.

One set of Helm charts, three managed Kubernetes services. The clusters are provisioned with Terraform; the charts (later phases) stay cloud-agnostic and push the differences — identity, storage classes, load balancer annotations — into per-cloud values files.

## Status

| Phase | | |
|-------|--|--|
| 0 | Prerequisites & foundations | done |
| 1 | Provision clusters (Terraform, all three clouds) | implemented — validated, **not yet applied to real accounts** |
| 2–6 | Helm setup, portable charts, deployment, CI/CD & GitOps, operations | planned |

Full plan with per-phase status: [docs/roadmap](docs/roadmap/README.md).

## Layout

```
docs/
  roadmap/          the phased plan, one file per phase
  decisions/        architecture decision records
  github-secrets.md how to set up cloud credentials for GitHub Actions
  cost-control.md   taking clusters down and up from CI, and checking nothing keeps billing
  licenses.md       licensing of this repo and its dependencies
infra/              Phase 1: Terraform for EKS, AKS, GKE (+ runbook in infra/README.md)
scripts/            check-prereqs.sh, cluster-ops.sh (drain / audit / allow-ip) and its tests
.github/workflows/  ci.yml, terraform.yml (plan / up / down), cost-guard.yml (nightly check)
```

## Quick start

```sh
make prereqs     # check your toolchain
make validate    # terraform validate all three roots, no credentials needed
make test        # offline tests for the teardown scripts
```

Then, to build a cluster: set up credentials and state storage ([docs/github-secrets.md](docs/github-secrets.md)) and follow [infra/README.md](infra/README.md).

## Up and down on demand

Clusters bill by the hour, so tear them down when you stop and bring them back when you need them. Actions → **Clusters (plan / up / down)**, or:

```sh
gh workflow run terraform.yml -f cloud=all -f action=down -f confirm=destroy   # stop the charges
gh workflow run terraform.yml -f cloud=all -f action=up                         # bring everything back
```

`down` also removes the load balancers and disks Kubernetes created and then verifies that nothing billable remains. An optional nightly [cost guard](docs/cost-control.md#cost-guard-catching-a-forgotten-cluster) alerts you, or tears down automatically, if a cluster is left running. Details, limits and what is deliberately kept: [docs/cost-control.md](docs/cost-control.md).

## Decisions in one glance

- Standard clusters (you own the node pools), one cluster per cloud, namespaces for environments.
- Plain Helm driven from CI; GitOps is reconsidered in Phase 5.
- GitHub → cloud authentication through OIDC; no long-lived cloud keys in GitHub.
- Traefik as the common ingress controller, because ingress-nginx is retired ([ADR 0002](docs/decisions/0002-ingress-controller.md)).

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). Third-party components and their licenses: [docs/licenses.md](docs/licenses.md).
