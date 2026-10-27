# Using Helm with the three clusters

Helm is the client that deploys workloads (Phase 4). The platform add-ons (Traefik, cert-manager, metrics-server, Cluster Autoscaler) are installed by Terraform and are not managed with the CLI. Why Helm 4, and how it is pinned: [ADR 0004](decisions/0004-helm-client.md).

## 1. Install

Use your package manager or the [official install guide](https://helm.sh/docs/intro/install/); the roadmap's `get-helm-3` script installs Helm 3, which this repo does not use.

```sh
brew install helm        # macOS
make prereqs             # fails on Helm 3, notes if you are older than CI
```

CI installs the exact version in [.tool-versions](../.tool-versions). To match it locally with a version manager (asdf, mise) run its `install` command in the repo root; otherwise any current Helm 4 is fine.

Each Helm release supports a window of Kubernetes versions: the one it was built against and the three before it (4.1.x: 1.32–1.35, 4.3.x: 1.34–1.37). The clusters here run 1.35, so Helm 4.0.x, which stops at 1.34, is too old.

## 2. Contexts: one per cluster, named after it

| Cloud | Context | Cluster |
|-------|---------|---------|
| AWS | `mc-eks` | EKS |
| Azure | `mc-aks` | AKS |
| GCP | `mc-gke` | GKE |

Add them to your own kubeconfig with the command each Terraform root prints (the clusters must be up, and your IP must be in `api_authorized_cidrs`). If you only run Terraform through CI, copy the command from the summary of the `up` run instead; from a local checkout it needs `terraform init` first ([infra/README.md](../infra/README.md)):

```sh
terraform -chdir=infra/aws-eks output -raw kubeconfig_command | sh
terraform -chdir=infra/azure-aks output -raw kubeconfig_command | sh
terraform -chdir=infra/gcp-gke output -raw kubeconfig_command | sh
kubectl config get-contexts        # should list mc-eks, mc-aks, mc-gke
```

Then **always pass the context**; never rely on the current one:

```sh
helm --kube-context mc-eks list --all-namespaces
helm --kube-context mc-aks --namespace web upgrade --install web ./charts/web -f values/aks.yaml
```

A mistake with the "current" context deploys to the wrong cloud, and the three clusters look alike.

### A throwaway kubeconfig instead

`scripts/cluster-ops.sh kubeconfig <cloud>` writes credentials for one cluster to a file of its own, with the context named after the cluster, and prints the path. It never touches `~/.kube/config`. CI uses it.

```sh
export KUBECONFIG=$(CLUSTER_NAME=mc-eks scripts/cluster-ops.sh kubeconfig aws)
helm --kube-context mc-eks list -A
```

It needs the cloud CLI logged in (and `GCP_PROJECT_ID` for GCP). The AKS file holds the cluster's local admin credentials, and the GKE file holds a one-hour access token. Treat the file like a password and delete it when done.

## 3. Chart repositories

```sh
make helm-repos
```

| Repository | Used for |
|------------|----------|
| `jetstack` (`https://charts.jetstack.io`) | cert-manager |
| `traefik` (`https://traefik.github.io/charts`) | Traefik |
| `metrics-server` (`https://kubernetes-sigs.github.io/metrics-server`) | metrics-server (EKS) |
| `autoscaler` (`https://kubernetes.github.io/autoscaler`) | Cluster Autoscaler (EKS) |
| `prometheus-community` (`https://prometheus-community.github.io/helm-charts`) | The optional monitoring stack ([observability.md](observability.md)) |

These are the sources Terraform pins versions from, so `helm show values jetstack/cert-manager --version <pin>` shows what is deployed. OCI registries (`oci://…`) need no `repo add`; use `helm registry login <hostname>` for private ones.

Not added, on purpose: **ingress-nginx** (retired, [ADR 0002](decisions/0002-ingress-controller.md)) and **Bitnami** (stopped updating its free catalog, [ADR 0004](decisions/0004-helm-client.md#why-not-bitnami)).

## 4. Helm 4 differences that matter here

| Helm 3 | Helm 4 |
|--------|--------|
| `--atomic` | `--rollback-on-failure` |
| `--force` | `--force-replace` |
| client-side three-way merge for every install | server-side apply for **new** installs; upgrades and rollbacks keep the release's existing method |
| `--post-renderer <executable>` | a post-renderer plugin name |
| `helm registry login <url>` | `helm registry login <hostname>` |

The old flag names still work in Helm 4 with a deprecation warning, but scripts and docs in this repo use the new ones.

## 5. Deploying the charts

The charts, their values files and the exact `helm upgrade --install` commands per cloud and environment are in [charts.md](charts.md). Deploying them from CI, with validation, is in [deploying.md](deploying.md).

## 6. Checking Helm against the live clusters

Actions → **Helm check** → *Run workflow* → choose a cloud (or `all`), or:

```sh
gh workflow run helm-check.yml -f cloud=all
```

For each cloud it logs in with OIDC, installs the pinned Helm, lets the runner through to the cluster API, builds a kubeconfig with the cluster-named context, lists the releases with `helm --kube-context …`, and fails unless these are `deployed`:

| Cloud | Releases checked |
|-------|------------------|
| all | `traefik` (namespace `ingress`), `cert-manager` (`cert-manager`) |
| AWS, additionally | `metrics-server`, `cluster-autoscaler` (`kube-system`) |

It changes nothing in the cluster, but, like `up` and `down`, it adds the runner's IP to the cluster's API allow-list (see [cost-control.md](cost-control.md#how-the-runner-reaches-the-cluster)), so it only runs from `main`. Run it after `up` has finished. It uses the same environments, secrets and variables as the Clusters workflow ([github-secrets.md](github-secrets.md)); nothing new to configure. With `TF_RUNNER` set, the self-hosted runner needs `kubectl`, `jq` and the cloud CLI installed, and a route to the API.

This is also the first end-to-end check of Phase 1: the Terraform has only been validated, not applied to a real account. If `up` has never run, run it first.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `cluster … not found on … (bring it up first)` | The cluster is down. Run the Clusters workflow with action `up`. |
| `Kubernetes cluster unreachable` / `helm cannot list releases` | The API server does not accept this IP. In CI the runner is added automatically; locally, add yours to `api_authorized_cidrs` (or `scripts/cluster-ops.sh allow-ip <cloud> <your-ip>/32`). A private-only cluster needs a runner inside the network. |
| `Unauthorized` on EKS | The cluster was created by another identity (for example your SSO user); only its creator is admin. Create clusters with `up` in CI. |
| Add-on row says `missing` | `up` did not finish, or the cluster was created with the add-ons disabled. Re-run `up`; it is idempotent. |
| `(gcp)` the token stopped working after an hour | The GKE kubeconfig embeds a one-hour access token. Run `kubeconfig` again. |
