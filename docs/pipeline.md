# The pipeline at a glance

Everything that runs in GitHub Actions, when, and what it needs. Decisions behind it: [ADR 0003](decisions/0003-teardown-and-cost-control.md) (teardown), [ADR 0006](decisions/0006-deployment-model.md) (deploying), [ADR 0007](decisions/0007-delivery-strategy.md) (delivery strategy).

## Workflows

| Workflow | Runs | Does | Needs cloud credentials |
|----------|------|------|:--:|
| [CI](../.github/workflows/ci.yml) | every pull request, and pushes to `main` | Terraform format and validate (3 roots), shellcheck, the offline test suites, chart lint/render/assertions, and on throwaway kind clusters: the charts, `deploy.sh`, admission policies, quota and network rules (on kind's default network plugin and on Cilium), and the optional monitoring stack | no |
| [Supply chain](../.github/workflows/supply-chain.yml) | weekly; on demand; pull requests touching charts or pinned versions | Scans every image the clusters run, records SBOMs ([supply-chain.md](supply-chain.md)) | no |
| [Clusters](../.github/workflows/terraform.yml) | on demand, `main` for `up`/`down` | `plan`, `up` (optionally `deploy`), `down` ([cost-control.md](cost-control.md)) | yes |
| [Deploy workloads](../.github/workflows/deploy.yml) | on demand, `main` only | Policies, issuers, the app, then validation ([deploying.md](deploying.md)) | yes |
| [Helm check](../.github/workflows/helm-check.yml) | on demand, `main` only | Read-only: Helm reaches each cluster and the platform add-ons are deployed ([helm.md](helm.md)) | yes |
| [Cost guard](../.github/workflows/cost-guard.yml) | nightly | Finds clusters left running; optionally tears them down | yes |

The workflows that touch a cloud run against a GitHub Environment per cloud (`aws`, `azure`, `gcp`) with short-lived OIDC credentials ([github-secrets.md](github-secrets.md)). Nothing in CI or the scheduled scans holds a cloud credential.

## From a change to production

```
local commit ─ pre-commit hook (make hooks): format, lint, offline tests, ~10 s
      │
pull request ─ CI + Supply chain (if it touches charts or versions)     review gate
      │
merge to main
      │
Clusters: up ─ (deploy=dev)                       cluster and platform add-ons, apps optional
      │
Helm check                                         Helm reaches the cluster; add-ons deployed
      │
Deploy workloads: dev                              policies, issuers, app, helm test, certificate,
      │                                            request through the load balancer
Deploy workloads: prod                             Let's Encrypt, autoscaler metrics; DNS record by hand
      │
Clusters: down                                     drain, destroy, audit; nothing left billing
```

A merge never deploys by itself, because the clusters are normally down. A specific image version can be rolled out or back with the Deploy workflow's `image_tag` input.

## What a person has to do

- Review and merge pull requests.
- Start `up`, and `deploy`, when the clusters are wanted; `down` when they are not (or let the cost guard).
- For `prod`: set `APP_DOMAIN` and `ACME_EMAIL` once, and update a DNS record after each `up`.
- Bump versions when the weekly scan fails on a fixable vulnerability ([supply-chain.md](supply-chain.md#responding-to-a-failure)), and renew or retire the time-limited exceptions in `supply-chain-exceptions.txt` before they expire.

## Local checks

```sh
make hooks     # once: run CI's fast checks before every commit
make test      # the offline suites
make lint      # shellcheck and actionlint
```
