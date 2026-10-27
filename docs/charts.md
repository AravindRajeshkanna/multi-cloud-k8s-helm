# Helm charts

Two charts live in [charts/](../charts/):

| Chart | What it is |
|-------|-----------|
| [webapp](../charts/webapp) | A portable, stateless web service. It runs [podinfo](https://github.com/stefanprodan/podinfo) by default; image, command, port and probe paths are values, so any HTTP service can replace it. |
| [cluster-issuers](../charts/cluster-issuers) | cert-manager `ClusterIssuer`s, installed once per cluster: `selfsigned` (works anywhere), `letsencrypt-staging` and `letsencrypt-prod` (need a domain). |

Why the charts are shaped this way: [ADR 0005](decisions/0005-chart-portability.md). How they get onto the clusters, in CI: [deploying.md](deploying.md).

## One chart, three clouds

The same chart deploys unchanged to EKS, AKS and GKE. What differs lives in values files, layered with repeated `-f` flags (later files win; maps merge, lists replace):

```
values.yaml        defaults, cloud-agnostic
values-<cloud>.yaml   eks | aks | gke
values-<env>.yaml     dev | prod
--set ...             deployment inputs, such as the host name
```

```sh
# Development on EKS
helm --kube-context mc-eks --namespace web-dev upgrade --install web charts/webapp --create-namespace \
  -f charts/webapp/values-eks.yaml -f charts/webapp/values-dev.yaml

# Production on GKE, behind HTTPS (needs the issuer and a domain, see below)
helm --kube-context mc-gke --namespace web-prod upgrade --install web charts/webapp --create-namespace \
  -f charts/webapp/values-gke.yaml -f charts/webapp/values-prod.yaml \
  --set ingress.host=web.gke.example.com
```

Environments are namespaces in the one cluster per cloud ([ADR 0001](decisions/0001-platform-decisions.md)). `helm test web -n web-dev` runs a pod that calls the service's health endpoint.

### What differs per cloud, and what does not

With Traefik as the common ingress controller ([ADR 0002](decisions/0002-ingress-controller.md)), an application's Service and Ingress are the same everywhere: no load-balancer or Application Gateway annotations are needed on them. (Cloud-specific load-balancer annotations belong to the controller's own Service, which Terraform configures.) That leaves little to vary, and the per-cloud files are limited to:

| Setting | EKS | AKS | GKE |
|---------|-----|-----|-----|
| Node pool label (`nodeSelector`) | `pool=default` | `pool=user` | `pool=default` |
| Workload identity (only if the app calls cloud APIs) | Pod Identity needs nothing on the service account; IRSA: `eks.amazonaws.com/role-arn` | `azure.workload.identity/client-id` annotation and `azure.workload.identity/use: "true"` pod label | `iam.gke.io/gcp-service-account` annotation |
| Marker so you can see which cloud answered | `PODINFO_UI_MESSAGE`, `PODINFO_UI_COLOR` | same | same |
| Ingress host | per deployment | per deployment | per deployment |

The workload identity rows are commented examples in the files because this app does not call any cloud API. The identity itself (IAM role, managed identity, Google service account) is created outside the chart; it is a Terraform concern when an app needs one.

A test fails if a template mentions a cloud, if a cloud file sets anything other than `nodeSelector`, `env`, `serviceAccount`, `podLabels`, `tolerations` or `affinity`, or if the rendered Deployments differ between clouds in anything but `nodeSelector` and `env`.

### Host names are inputs

Each cloud's load balancer has its own address, so the host is chosen per deployment (`--set ingress.host=...`), never in the chart. Rendering with the ingress enabled and no host fails with a message. Find the controller's address with `kubectl --context mc-eks -n ingress get svc traefik`, and point a DNS name at it.

## TLS with cert-manager

cert-manager is installed by Phase 1. Install the issuers once per cluster, before any chart that names one:

```sh
helm --kube-context mc-eks --namespace cert-manager upgrade --install issuers charts/cluster-issuers --wait
```

That creates `selfsigned`: TLS works, browsers do not trust the certificate, and no domain is needed. For real certificates you need a domain whose name resolves to the controller's address, and an email for expiry notices. Try staging first, because production rate-limits failures:

```sh
helm ... upgrade --install issuers charts/cluster-issuers -n cert-manager \
  --set acme.email=you@example.com --set acme.staging.enabled=true --set acme.production.enabled=true
```

`values-prod.yaml` asks for `letsencrypt-prod`. To try TLS without a domain, deploy with `--set ingress.tls.clusterIssuer=selfsigned`. The Ingress carries the `cert-manager.io/cluster-issuer` annotation and a `tls` section, and cert-manager creates the Certificate and the secret.

Plain HTTP on an Ingress that has a `tls` section, and HTTP-to-HTTPS redirects, are controller behaviour and are not set up here; add them with `ingress.annotations` once you decide how you want them.

## Secrets

No secret goes in a values file. The chart reads Secrets by reference: `envFrom` (`secretRef`) and `extraEnv` (`valueFrom.secretKeyRef`) name a Kubernetes Secret that exists in the namespace. Where that Secret comes from is in [deploying.md](deploying.md#secrets).

## Policies

The workload namespaces refuse pods and ingresses that break a few rules (resources, version-pinned images from approved registries, HTTPS ingress, the restricted Pod Security Standard). The chart is built to pass them and a test proves it for every cloud and environment: [policies.md](policies.md). If you point `image.repository` at another registry, add it to the allow-list there.

## What the chart sets for you

Every rendered workload has resource requests and limits (the schema refuses a chart without them), startup, liveness and readiness probes, a PodDisruptionBudget, soft zone and node spreading, and the Kubernetes "restricted" security profile: non-root with a numeric user, read-only root filesystem, no privilege escalation, all capabilities dropped, the runtime's default seccomp profile, and no service account token unless asked for. `values.schema.json` rejects mistyped keys, a `latest` image tag, and a wrong type. Autoscaling uses metrics-server, which is present on all three platform clusters.

## Storage

The webapp is stateless and has no volume claim. Phase 1 deferred StorageClass defaults to "chart values in Phase 3"; they belong to the first stateful chart, because an unused claim in this one could not be tested honestly. For reference, the classes each cloud provides (check with `kubectl get storageclass` after `up`; these names have not been confirmed on the clusters from this repo):

| Cloud | Default / recommended | Notes |
|-------|----------------------|-------|
| EKS | `gp2` is the default; `gp3` is cheaper and faster | The EBS CSI driver is installed (Phase 1) but a `gp3` StorageClass does not exist yet. Create it before a chart names it. |
| AKS | `managed-csi` (Azure Disk), `azurefile-csi` for shared volumes | Built in. |
| GKE | `standard-rwo`, `premium-rwo` | Built in. |

A chart should take `storageClass` as a value with an empty default (use the cluster's default), set per cloud only if needed.

## Testing

| Level | Command | What it proves | Needs |
|-------|---------|----------------|-------|
| Render | `make test` (runs `scripts/test-charts.sh`) | Lints and renders every cloud x environment; asserts on the manifests (security settings, environment behaviour, guards, workload-identity wiring, no cloud logic in templates) | helm, kubectl, jq; no cluster |
| Install | CI job `helm charts (install on a throwaway kind cluster)`, or `KUBE_CONTEXT=<ctx> scripts/test-charts-kind.sh` | The API server accepts the manifests; pods pass their probes under the hardened settings; `helm test`; a dev-to-prod upgrade; cert-manager issues a certificate; Traefik routes a request | A **throwaway** cluster such as kind. The script refuses contexts named `mc-*` and clusters with an `ingress` namespace. |

Neither level runs against the EKS, AKS or GKE clusters; that comes with the Phase 4 deployment.

## Versioning and publishing

Charts are versioned with SemVer in `Chart.yaml` (bump `version` when anything in the chart changes) and deployed from this repository's checkout. Pushing them to an OCI registry (GHCR, ECR, ACR, Artifact Registry) is deferred to Phase 5, where promotion across environments needs versioned artifacts; it adds a registry and credentials to decide on. A shared library chart is deferred until a second application shows what is worth sharing. Dependabot does not track the `podinfo` image tag in `appVersion`; bump it by hand.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `ingress.host is required` | The ingress is enabled (`values-prod.yaml` does) and no host was given. Add `--set ingress.host=...`. |
| `additional properties '...' not allowed` | A mistyped value name. The schema lists the valid ones. |
| Pods `Pending` with "didn't match Pod's node affinity/selector" | The node pool label in `values-<cloud>.yaml` does not match your nodes. Check `kubectl get nodes --show-labels`, or remove `nodeSelector`. |
| `no matches for kind "ClusterIssuer"` | cert-manager's CRDs are missing: Phase 1 `up` has not run, or cert-manager is disabled. |
| Certificate stays `False` | `kubectl describe certificate,order,challenge -n <ns>`. For Let's Encrypt the name must resolve to the controller and port 80 must be reachable. |
| HPA shows `<unknown>` | metrics-server is not running. It is installed by Phase 1 on EKS and built in on AKS and GKE. |
