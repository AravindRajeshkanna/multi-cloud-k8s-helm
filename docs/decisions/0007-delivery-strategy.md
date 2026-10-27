# ADR 0007: Delivery strategy

- **Status:** Accepted
- **Date:** 2026-10-27

## Context

Phase 5 of the roadmap recommends: build and push images to each cloud's registry, update the image tag, deliver with a GitOps controller (Argo CD or Flux) that targets several clusters, promote through pull requests, and add progressive delivery. The alternative it names is a CI pipeline running `helm upgrade --install`, which is what ADR 0001 chose and ADR 0006 built. Phase 5 is where to reopen that choice, on evidence.

The facts that shape it: clusters are **disposable** (`down` destroys everything, `up` makes new ones, [ADR 0003](0003-teardown-and-cost-control.md)); the cluster APIs are public but restricted to listed CIDRs, so CI adds the runner's address ([ADR 0001](0001-platform-decisions.md)); there is one application, which is a third-party image; and one person operates it.

## Decisions

1. **Delivery stays CI-driven; GitOps is not adopted now.** Concrete reasons:
   - **It fights the teardown.** `down` first drains: it deletes the Services, Ingresses and volume claims Kubernetes created so the cloud's load balancers and disks do not outlive the cluster. A controller reconciling from Git re-creates exactly those objects within seconds, so the drain would race it. It would have to be taught to suspend reconciliation first, and that step cannot be tested without real accounts.
   - **The validation is the deploy.** `scripts/deploy.sh` ends by sending a real request through the cloud load balancer and checking the autoscaler. A pull-based controller reports "synced", not "answering"; those checks would still need CI.
   - **A bootstrap race on every `up`.** Terraform installs the controller, which then installs the apps; a failure in the middle has no single place to look.
   - **Cost.** Controllers take memory on node pools sized for the workload.
   - **What GitOps would give is real but small here:** no runner address on the API allow-list for deploys, drift correction, and an audit trail in Git. With one app and one operator, none is pressing.
   - **Revisit when:** there are more than a handful of applications or several teams; drift becomes a problem; or the API endpoints go fully private so CI can no longer reach them. Then prefer Flux (lighter), have `HelmRelease` objects consume the same charts and values files, and make `down` suspend reconciliation before draining.

2. **Promotion is: pull request, then dev, then prod, each a deliberate step.** A change reaches `main` only through a reviewed pull request whose checks pass. `dev` is deployed from `main` with the Deploy workflow (or `up` with `deploy=dev`), and `prod` the same way with `environment=prod`. There is **no automatic deploy on merge**, because the clusters are normally down and a merge would fail against nothing. A specific image version can be rolled out or rolled back with the Deploy workflow's `image_tag` input. There is no `staging`: the third environment adds a namespace and a values file when it has a reason.

3. **Images are not built here, and registries are not created.** There is no first-party application to build: the workload is a public image. A registry per cloud is also a standing cost that contradicts zero idle cost: Azure Container Registry bills a daily fee for the registry itself, whether or not anything pulls from it, and the other two charge for stored images. When an application of our own exists, the first step is GHCR (free, public or private, reachable from every cloud), with versioned immutable tags; per-cloud registries come when pull latency or egress cost shows up. The admission policy already allows each cloud's registry for that day.

4. **No `terraform plan` on pull requests, and no approval between plan and apply.** The cloud identities trust GitHub only for specific Environments on `main` ([github-secrets.md](../github-secrets.md)). A plan on a pull request needs a second, read-only identity per cloud trusted for pull requests, and an approval *between* plan and apply needs separate Environments such as `aws-apply`: manual changes in three clouds, and a change to what the CI role is trusted for. Today, required reviewers on the `aws`, `azure` and `gcp` Environments approve a run *before* it starts, and the workflow's own `plan` action shows what would change. **Revisit** when more than one person can merge.

5. **Progressive delivery (Argo Rollouts, Flagger) is deferred.** It needs a controller, weighted routing through Traefik's CRDs, a metrics source to judge a canary, and an application with traffic. The chart's rolling update (`maxUnavailable: 0`, readiness-gated) is the safeguard until then.

## Consequences

- One path to a cluster, one script, one place its checks live.
- Operators must remember that `up` does not deploy unless asked (`deploy=dev`), and that `prod` needs the DNS record updated after every `up`.
- Everything deferred here is deferred for a stated reason, so the reason can be checked later against what changed.

## Alternatives considered

- **Flux or Argo CD now.** See decision 1; the teardown interaction is the decisive point.
- **Auto-deploy `main` to `dev`.** Fails whenever the clusters are down, which is by design most of the time.
- **A registry per cloud now.** Standing cost with nothing to put in it.
