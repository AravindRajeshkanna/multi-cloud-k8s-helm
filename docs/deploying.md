# Deploying the workloads

[scripts/deploy.sh](../scripts/deploy.sh) puts the applications on a running cluster and checks that they work. Two workflows run it, and you can run it yourself. Why it is built this way: [ADR 0006](decisions/0006-deployment-model.md).

## Run it

The cluster has to be up first ([cost-control.md](cost-control.md)).

| How | When |
|-----|------|
| Actions → **Deploy workloads** → *cloud*, *environment* | Deploy or redeploy to clusters that are already up. Runs from `main` only. |
| Actions → **Clusters** → *action* `up`, *deploy* `dev` or `prod` | Bring a cluster up and put the applications on it in one run. This is what brings a torn-down setup fully back. |
| `KUBE_CONTEXT=mc-eks scripts/deploy.sh aws dev` | From your machine, with a kubeconfig that has the context ([helm.md](helm.md#2-contexts-one-per-cluster-named-after-it)). Needs `helm`, `kubectl`, `curl`. |

```sh
gh workflow run deploy.yml -f cloud=all -f environment=dev
gh workflow run terraform.yml -f cloud=all -f action=up -f deploy=dev     # cluster and apps
```

The `deploy` input of the Clusters workflow defaults to `none`, so a plain `up` stays infrastructure-only. That keeps the first real `up` easy to diagnose; add `deploy=dev` once it works.

## What it does

In the order the roadmap gives:

| Step | What happens |
|------|--------------|
| 1. Platform | Installs the `issuers` release ([cluster-issuers chart](../charts/cluster-issuers)). Ingress (Traefik), cert-manager, metrics-server and the autoscaler already came from Terraform. Fails with "bring the cluster up first" if cert-manager is missing. |
| 2. Shared services | None yet. Databases and caches arrive with the first workload that needs one. |
| 3. Application | `helm upgrade --install web charts/webapp` into namespace `web-<environment>`, with `values-<cloud>.yaml` then `values-<environment>.yaml` ([charts.md](charts.md)), `--wait` and `--rollback-on-failure`. |
| 4. Validate | `helm test`; the certificate; the autoscaler receiving metrics (prod); and an HTTPS request through the cluster's load balancer. |

### Environments

| | `dev` | `prod` |
|-|-------|--------|
| Namespace | `web-dev` | `web-prod` |
| Host | `web-dev.<cloud>.<domain>` | `web-prod.<cloud>.<domain>` |
| Replicas | 1, no autoscaler, no disruption budget | autoscaled 3-10, disruption budget keeps 2 up |
| TLS | Ingress with a **self-signed** certificate | Ingress with **Let's Encrypt** (`letsencrypt-prod`) |
| Needs | nothing: the host does not have to resolve | variables `APP_DOMAIN` and `ACME_EMAIL`, and a DNS record you create |

`<domain>` is `APP_DOMAIN`, or `example.test` (which never resolves, and does not need to) when unset.

### What each check proves

| Check | A failure means |
|-------|-----------------|
| `helm --wait` | The pods did not become ready. `--rollback-on-failure` removes a failed first install and rolls back a failed upgrade. |
| `helm test` | The Service answers its health endpoint from inside the cluster. |
| Certificate Ready (dev) | cert-manager works end to end and the issuer exists. For prod this is reported, not required: Let's Encrypt cannot issue until your DNS record points at the cluster. |
| Autoscaler receiving metrics (prod) | metrics-server is not working. The Phase 3 tests on a throwaway cluster could not check this. |
| HTTPS request through the load balancer | The cloud load balancer, Traefik, the Ingress, TLS and the Service work together. The request is sent from the runner with the right `Host` header straight to the load balancer's address (curl `--connect-to`), so no DNS is needed, and the certificate is not verified (dev's is self-signed). It retries for up to 10 minutes because a new load balancer takes a while to come up. |

A failed run prints the namespace's pods, ingress, certificate and recent events so the log explains itself.

## Variables

Set as repository variables, or per GitHub Environment ([github-secrets.md](github-secrets.md#repository-level-optional)).

| Name | Effect |
|------|--------|
| `APP_DOMAIN` | A domain whose DNS you control. Required for `prod`. |
| `ACME_EMAIL` | Email for Let's Encrypt. Required for `prod`; when set, the staging and production issuers are installed. |
| `SKIP_INGRESS_SMOKE` | `1` skips the request through the load balancer. For a custom runner (`TF_RUNNER`) that cannot reach it. |

## Production and DNS

1. Set `APP_DOMAIN` and `ACME_EMAIL`, then deploy `prod`.
2. The run summary ends with the load balancer address and the host name, for example `web-prod.aws.apps.example.org`. Create a DNS record for that name: an **A** record for an IP address (AKS, GKE), a **CNAME** for a name (EKS).
3. Once it resolves, Let's Encrypt can issue the certificate. Until then Traefik serves its own default certificate. Watch it with `kubectl --context mc-eks -n web-prod get certificate`.

Each rebuilt cluster has a **new** load balancer address, so the record has to be updated after every `up`. Automating that is ExternalDNS, deliberately left out until a real domain is chosen.

## Secrets

Nothing in this repository, in a values file or in a workflow holds an application secret. The `webapp` chart can consume them **by reference** (`envFrom`, `extraEnv` with `secretKeyRef`), so a Kubernetes Secret named in values is read at runtime and never written down.

The roadmap's preferred source for those Secrets is External Secrets Operator syncing from each cloud's secret manager. It is **not installed yet**: no workload needs a secret, and installing it requires an identity and a secret store per cloud that cannot be tested without real accounts. When the first workload needs one, the shape is:

| Cloud | Secret manager | Identity the operator uses |
|-------|----------------|----------------------------|
| AWS | Secrets Manager | EKS Pod Identity (or IRSA) role |
| Azure | Key Vault | Workload identity (federated managed identity) |
| GCP | Secret Manager | Workload Identity Federation (Google service account) |

All three clusters already have workload identity enabled (Phase 1). Until then, create a Secret by hand with `kubectl create secret` and reference it; remember it is deleted with the cluster by `down`.

## Rolling back and removing

```sh
helm --kube-context mc-eks -n web-dev history web
helm --kube-context mc-eks -n web-dev rollback web 1 --wait
helm --kube-context mc-eks -n web-dev uninstall web
```

`down` removes the cluster and everything on it, after deleting the load balancers and volumes Kubernetes created ([cost-control.md](cost-control.md)). The workloads cost nothing by themselves; the load balancer Traefik creates is the billable object, and `down` takes care of it.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `bring the cluster up first` | cert-manager's CRD is missing: the cluster is down, or `up` did not finish. |
| `cannot reach the cluster behind context` | The runner or your machine is not allowed through to the API ([helm.md](helm.md#troubleshooting)). |
| `timed out ... load balancer address` | Traefik's Service has no external address after 10 minutes. Check the cloud's quota or `kubectl -n ingress describe svc traefik`. |
| `timed out ... to answer through` | The load balancer exists but traffic does not arrive. Check security groups or firewall rules; on a runner that cannot reach it, set `SKIP_INGRESS_SMOKE=1`. |
| `timed out ... Ready` (dev) | cert-manager could not issue. `kubectl -n web-dev describe certificate,certificaterequest`. |
| `timed out ... receive metrics` | metrics-server is not running or cannot scrape the nodes. |
| Pods `Pending`, node selector | The `pool` label in `values-<cloud>.yaml` does not match the nodes ([charts.md](charts.md#troubleshooting)). |
| `prod needs APP_DOMAIN` / `ACME_EMAIL` | Set the variables, or deploy `dev`. |
