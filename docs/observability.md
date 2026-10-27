# Observability: Prometheus and Grafana

An **optional** platform add-on. Off by default, because it requests about 1.1 GiB of memory (up to 2.7 GiB at its limits) on a small cluster and the first real `up` is easier to debug without it. Decisions: [ADR 0009](decisions/0009-hardening-and-operations.md).

## Turn it on

Set the repository (or environment) variable `ENABLE_MONITORING` to `true` ([github-secrets.md](github-secrets.md)) and run the Clusters workflow with `up`. Terraform installs [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts) into the `monitoring` namespace, using one values file, [monitoring-values.yaml](../infra/modules/core-addons/monitoring-values.yaml), that the CI test also uses, so what is tested is what is deployed. Locally: `enable_monitoring = true` in `terraform.tfvars`.

`scripts/deploy.sh` notices the Prometheus Operator and turns on the `webapp` chart's `ServiceMonitor` and alert rules by itself; the deploy summary says whether it did.

## Look at it

Nothing is exposed outside the cluster. Use a port-forward:

```sh
kubectl --context mc-eks -n monitoring port-forward svc/monitoring-grafana 3000:80
# http://localhost:3000   user: admin
kubectl --context mc-eks -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d

kubectl --context mc-eks -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090
# http://localhost:9090   (Status > Targets, Alerts)
```

The Grafana password is generated at install time, so it is different on every new cluster. The chart's default dashboards cover nodes, pods, namespaces and workloads.

## What is configured

| Setting | Choice |
|---------|--------|
| Persistence | None. Metrics live in the pod and are lost with it. The clusters are disposable ([ADR 0003](decisions/0003-teardown-and-cost-control.md)), so this is a view of the current cluster, not an archive. Retention is 24 hours. |
| Alertmanager | Not installed. It needs a destination (email, chat) that only you can choose. Alerts are still evaluated, and show in Prometheus and in Grafana. |
| Control plane monitoring | Off: etcd, the scheduler, the controller manager and kube-proxy cannot be scraped on managed clusters, and leaving them on creates alerts that fire forever. |
| Grafana image | 13.2.5, not the chart's 13.2.4, for four CVE fixes. Grafana is AGPL-3.0, the rest Apache-2.0 ([licenses.md](licenses.md)). |
| Exposure | Services are `ClusterIP`; the stack creates no load balancer or disk, so `down` has nothing extra to clean up. |

## What the webapp ships

With scraping on, the chart adds a `ServiceMonitor` (it scrapes `/metrics` on the app's HTTP port) and three alerts:

| Alert | Fires when |
|-------|-----------|
| `WebappTargetDown` | Prometheus cannot scrape the app for 5 minutes |
| `WebappHighErrorRate` | More than 5% of requests answered with a 5xx for 10 minutes (`metrics.rules.errorRatePercent`) |
| `WebappPodRestarting` | A container restarted more than 3 times in 15 minutes |

The network policy admits Prometheus from the `monitoring` namespace only when scraping is on.

## How it is tested

[scripts/test-monitoring-kind.sh](../scripts/test-monitoring-kind.sh) runs in CI on a kind cluster with Cilium. It installs the stack from the shared values file, deploys the app into a namespace with default-deny network policies, and asks Prometheus (through the Kubernetes API proxy) whether the app's target is **up**, whether its own metrics arrive, and whether the three alert rules are loaded and evaluate without error. It also checks that Alertmanager is absent, Grafana is healthy with a generated password, nothing is exposed, and the control-plane monitors are off.

## Not done

- **OpenTelemetry and traces.** The sample app emits none.
- **Dashboards for the webapp.** The default dashboards are there; a custom one would be a guess until there is real traffic to look at.
- **Alert delivery.** Add Alertmanager receivers when you decide where alerts should go.
- **Real clusters.** The stack's resource requests, the managed-cluster scrape targets and the node exporter on EKS, AKS and GKE are expectations until a real `up` with `ENABLE_MONITORING=true`.
