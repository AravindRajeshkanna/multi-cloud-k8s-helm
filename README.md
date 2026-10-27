# multi-cloud-k8s-helm

Deploy workloads on **EKS, AKS & GKE** using **Helm**, via **GitHub Actions**.

One set of Helm charts, three managed Kubernetes services. The clusters are provisioned with Terraform; the charts (later phases) stay cloud-agnostic and push the differences — identity, storage classes, load balancer annotations — into per-cloud values files.

## Status

| Phase | | |
|-------|--|--|
| 0 | Prerequisites & foundations | done |
| 1 | Provision clusters (Terraform, all three clouds) | implemented — validated, **not yet applied to real accounts** |
| 2 | Install & configure Helm (Helm 4 pinned, contexts, repos, live-cluster check) | implemented — **check not yet run against real clusters** |
| 3 | Portable Helm charts (`webapp`, `cluster-issuers`) | implemented — tested by rendering and on a kind cluster, **not yet deployed to real clusters** |
| 4 | Deploy workloads (`deploy.sh`, Deploy workflow, redeploy after `up`) | implemented — tested offline and on kind, **not yet run on real clusters** |
| 5 | CI/CD, policy and supply chain (GitOps reconsidered) | partly built, partly decided — admission policies and image scanning tested in CI, **not yet on real clusters** |
| 6 | Observability, security hardening, operations | partly built, partly deliberately left — quota and network rules in every workload namespace, optional Prometheus + Grafana, operations guide; tested on kind, **not yet on real clusters** |

Full plan with per-phase status: [docs/roadmap](docs/roadmap/README.md).

## Layout

```
docs/
  roadmap/          the phased plan, one file per phase
  decisions/        architecture decision records
  github-secrets.md how to set up cloud credentials for GitHub Actions
  cost-control.md   taking clusters down and up from CI, and checking nothing keeps billing
  helm.md           using Helm 4 with the three clusters (contexts, repos, the Helm check)
  charts.md         the charts: values layering, what differs per cloud, TLS, tests
  deploying.md      deploying the workloads: environments, validation, DNS, secrets
  policies.md       the admission policies the workload namespaces enforce
  supply-chain.md   image scanning and SBOMs
  pipeline.md       every workflow, when it runs, and the path from a change to production
  hardening.md      quota, limit range and network rules per namespace; what is not done
  observability.md  the optional Prometheus and Grafana stack
  operations.md     the routine, disaster recovery and where to look when something breaks
  licenses.md       licensing of this repo and its dependencies
infra/              Phase 1: Terraform for EKS, AKS, GKE (+ runbook in infra/README.md)
charts/             Phase 3: Helm charts - webapp (one chart, per-cloud values files), cluster-issuers
policies/           admission/ (Phase 5, ValidatingAdmissionPolicy) and namespace/ (Phase 6, quota, limit range, network rules)
scripts/            check-prereqs.sh, cluster-ops.sh (drain / audit / allow-ip / kubeconfig / addons), deploy.sh, list-images.sh, scan-summary.sh, and their tests
.github/workflows/  ci.yml, terraform.yml (plan / up / down), deploy.yml, cost-guard.yml (nightly check), helm-check.yml, supply-chain.yml
.githooks/          pre-commit hook (make hooks)
.github/actions/    cloud-login, cluster-access (login + runner access + kubeconfig)
.tool-versions      the pinned Helm version CI installs
```

## Quick start

```sh
make prereqs     # check your toolchain
make hooks       # run CI's fast checks before every commit
make validate    # terraform validate all three roots, no credentials needed
make test        # offline tests: the cluster scripts and the Helm charts (all cloud x environment combinations)
make helm-repos  # add the chart repositories the platform add-ons come from
```

Then, to build a cluster: set up credentials and state storage ([docs/github-secrets.md](docs/github-secrets.md)) and follow [infra/README.md](infra/README.md).

## Up and down on demand

Clusters bill by the hour, so tear them down when you stop and bring them back when you need them. Actions → **Clusters (plan / up / down)**, or:

```sh
gh workflow run terraform.yml -f cloud=all -f action=down -f confirm=destroy   # stop the charges
gh workflow run terraform.yml -f cloud=all -f action=up -f deploy=dev           # bring everything back, applications included
```

`down` also removes the load balancers and disks Kubernetes created and then verifies that nothing billable remains. An optional nightly [cost guard](docs/cost-control.md#cost-guard-catching-a-forgotten-cluster) alerts you, or tears down automatically, if a cluster is left running. Details, limits and what is deliberately kept: [docs/cost-control.md](docs/cost-control.md).

## Decisions in one glance

- Standard clusters (you own the node pools), one cluster per cloud, namespaces for environments.
- Plain Helm driven from CI; GitOps is reconsidered in Phase 5.
- Helm 4, pinned in `.tool-versions`; the cluster is always chosen with `--kube-context` ([ADR 0004](docs/decisions/0004-helm-client.md), [docs/helm.md](docs/helm.md)).
- Workload namespaces also get a resource quota and default-deny network rules; Prometheus and Grafana are an optional, default-off add-on ([ADR 0009](docs/decisions/0009-hardening-and-operations.md), [docs/hardening.md](docs/hardening.md)).
- Workload namespaces enforce native admission policies and the restricted Pod Security Standard; every image the clusters run is scanned weekly ([ADR 0008](docs/decisions/0008-policy-and-supply-chain.md)).
- Delivery stays CI-driven: GitOps was reconsidered and a reconciling controller would fight the teardown ([ADR 0007](docs/decisions/0007-delivery-strategy.md)).
- Deployments come from one script run from `main` and are validated against the real load balancer ([ADR 0006](docs/decisions/0006-deployment-model.md), [docs/deploying.md](docs/deploying.md)).
- One chart, three clouds: differences live in values files, never in templates ([ADR 0005](docs/decisions/0005-chart-portability.md), [docs/charts.md](docs/charts.md)).
- GitHub → cloud authentication through OIDC; no long-lived cloud keys in GitHub.
- Traefik as the common ingress controller, because ingress-nginx is retired ([ADR 0002](docs/decisions/0002-ingress-controller.md)).

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). Third-party components and their licenses: [docs/licenses.md](docs/licenses.md).
