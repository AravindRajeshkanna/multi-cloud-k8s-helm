# ADR 0006: Deployment model

- **Status:** Accepted
- **Date:** 2026-10-27

## Context

Phase 4 puts the Phase 3 charts on the Phase 1 clusters. Phase 0 chose plain Helm driven from CI over GitOps ([ADR 0001](0001-platform-decisions.md)), and [ADR 0003](0003-teardown-and-cost-control.md) made clusters disposable: `down` destroys everything and `up` creates a new cluster, so a deployment has to be repeatable on demand, not a one-time act.

The roadmap's order is platform add-ons, then shared services, then applications, then validate, with secrets from a cloud secret manager through External Secrets Operator.

## Decisions

1. **One script, `scripts/deploy.sh`, runs the deployment.** The Deploy workflow, the `deploy` option of the Clusters workflow, the kind test and a person at a terminal all run the same script, so what CI tests is what runs. The workflows only handle login, runner access and the kubeconfig. The script has stub-based tests, and the kind test runs the real thing.

2. **Deploy from `main` only, with `--wait --rollback-on-failure`.** Reviewed code is what reaches clusters. A failed release removes itself or rolls back rather than being left half-installed.

3. **Two environments, as namespaces in the one cluster per cloud.** `dev` needs nothing from the outside world: an Ingress with a self-signed certificate, tested by sending requests to the load balancer's address with the right `Host` header. `prod` uses Let's Encrypt and so needs a domain, an email and a DNS record that only the owner can create. Keeping `dev` domain-free means the full path (load balancer, ingress controller, TLS, Service) can be validated on a first deployment without any DNS.

4. **Validation is part of deploying, and fails closed.** `helm test`, certificate issuance (dev), the autoscaler receiving metrics (prod), and a real HTTPS request through the cloud load balancer. The last two cover assumptions the Phase 3 tests on a throwaway cluster could not: metrics-server on the real clusters, and the real load balancers. A timeout is a failure, never a pass.

5. **`up` deploys only when asked.** The Clusters workflow has a `deploy` input (`none`, `dev`, `prod`), default `none`. A plain `up` stays infrastructure-only so the first real run of Phase 1 is easy to diagnose; `deploy=dev` makes `up` bring the applications back too. The default is a one-line change if you would rather it always redeploy.

6. **The connect steps are one composite action** (`.github/actions/cluster-access`: OIDC login, runner IP allowed, kubeconfig named after the cluster), used by the Deploy and Helm check workflows. `terraform.yml` keeps its own steps because it needs the runner IP as a Terraform variable before the cluster exists.

7. **Secrets are referenced, never stored.** The chart accepts `envFrom` and `extraEnv`, so an app reads a Kubernetes Secret by name. No secret is written in values, workflows or the repository. External Secrets Operator with each cloud's secret manager is the intended source, but it is **not installed yet**: no workload needs a secret, and the operator needs an identity and secret store per cloud that cannot be tested without real accounts.

8. **Shared services (databases, caches) are not deployed.** Nothing needs one. When one does, an operator or a managed cloud service is a decision for that workload.

## Consequences

- Rebuilding a torn-down environment is `up` with `deploy=dev`; `prod` additionally needs the DNS record updated, because a new cluster has a new load balancer address. ExternalDNS would automate that and is left out until a real domain is chosen.
- The first deployment is also the first time the charts meet the real clusters; expect to fix small issues (node pool labels, security group rules for the load balancer).
- A custom runner that cannot reach the load balancer sets `SKIP_INGRESS_SMOKE=1` and gives up that check.
- Environments are namespaces, but GitHub Environments are per cloud, so required reviewers gate every workflow for that cloud rather than only prod deploys.

## Alternatives considered

- **Deploy from a GitOps controller (Argo CD / Flux).** Reconsidered in Phase 5. A controller that reconciles from Git does not fit disposable clusters as simply as a script that is run after `up`.
- **Always deploy on `up`.** Convenient, but couples infrastructure success to application success on the one run that has never been tried against real accounts.
- **Validate prod with the real Let's Encrypt certificate.** Impossible without the DNS record, so prod reports the certificate state instead of requiring it.
