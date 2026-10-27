# Cost control: take everything down, bring it back

Clusters bill by the hour whether or not anything runs on them. This repo lets you destroy all three from CI when you stop working, and recreate them when you need them.

## The two buttons

Actions → **Clusters (plan / up / down)** → *Run workflow*:

| Goal | `cloud` | `action` | `confirm` |
|------|---------|----------|-----------|
| Stop all charges | `all` (or one cloud) | `down` | `destroy` |
| Bring it back | `all` (or one cloud) | `up` | — (add `deploy` = `dev` to put the applications back too) |
| See what would change | any | `plan` | — |

From a terminal:

```sh
gh workflow run terraform.yml -f cloud=all -f action=down -f confirm=destroy
gh workflow run terraform.yml -f cloud=all -f action=up -f deploy=dev   # applications included
```

`up` and `down` only run from `main`. `down` refuses to start without `confirm=destroy`. With `cloud=all` the three clouds run in parallel and independently: one failing does not stop the others. `all` and the cost guard assume all three GitHub Environments are set up; if you only use some clouds, pick them individually and remove the others from `matrix.cloud` in [cost-guard.yml](../.github/workflows/cost-guard.yml).

## What `down` does

For each selected cloud, in order:

1. **Drain** (`scripts/cluster-ops.sh drain`): scales workloads in namespaces that own cloud-backed objects to zero, then deletes their Ingresses, `LoadBalancer` Services and PersistentVolumeClaims, waiting until the cloud confirms the load balancers and disks are gone. This is what Terraform cannot do: it does not know about load balancers and disks that Kubernetes created, they keep billing, and they block deletion of the network.
2. **`terraform plan -destroy`, then apply:** removes the add-on Helm releases, node pools, cluster, NAT, network and the IAM objects Terraform created.
3. **Verify** (`scripts/cluster-ops.sh audit --wait 300`): asks the cloud what billable resources still exist for the cluster and **fails the run if any do**. A failed check (bad credentials, API error) is a failure, never a pass.

| Cloud | The audit looks for |
|-------|---------------------|
| AWS | the EKS cluster; and, tagged `project=multi-cloud-k8s-helm` or `kubernetes.io/cluster/<name>`: EC2 instances, NAT gateways, EBS volumes and snapshots, Elastic IPs, load balancers |
| Azure | the `<name>-rg` resource group and the `MC_<name>-rg_*` node resource group (AKS puts everything it creates there) |
| GCP | the GKE cluster, node VMs and disks, volume disks, the Cloud NAT router, the VPC, and Kubernetes-created load-balancer forwarding rules |

### What stays, on purpose

| Item | Why | Cost |
|------|-----|------|
| Terraform state (S3 bucket / storage account / GCS bucket) | It records what exists. Deleting it would orphan the next `up`. | A few KB; cents per month at most |
| GitHub → cloud identities (IAM role + OIDC provider, Entra app, workload identity pool) | Needed to run `up` | Free |
| Enabled APIs, the state bucket's versioned history | — | Free / negligible |
| An EKS KMS key scheduled for deletion | AWS keeps it for its deletion window; keys pending deletion are not billed | Free |

### What is lost

Everything inside the clusters. **Data on volumes is deleted** (that is the point), and nothing is backed up. A new cluster starts with only the platform add-ons (Traefik, cert-manager, metrics-server, Cluster Autoscaler). The applications come back with `up` and its `deploy` input, or with the Deploy workflow ([deploying.md](deploying.md)). For `prod`, the DNS record has to be updated too: a new cluster has a new load balancer address.

## What `up` does

`terraform plan` and apply from scratch: network, cluster, node pools, add-ons. Roughly 10–20 minutes per cloud, in parallel. The run summary ends with the `kubeconfig` command for each cluster. The result is the same cluster as before, with the same names, but it is a **new** cluster: new endpoints, new load balancer address, nothing carried over. With `deploy` set, the run then deploys the applications and validates them ([deploying.md](deploying.md)).

## How the runner reaches the cluster

Terraform and the drain step talk to each cluster's API server. On the default GitHub-hosted runner, each run:

1. looks up its own public IP,
2. adds that `/32` to the cluster's allow-list (`up` creates the cluster with it; `down` and a repeat `up` add it first with `cluster-ops.sh allow-ip`, keeping existing entries),
3. runs Terraform with the allow-list set to `API_AUTHORIZED_CIDRS` plus that IP.

The [Helm check](helm.md#6-checking-helm-against-the-live-clusters) does the same first step. So no static IP is needed and `API_AUTHORIZED_CIDRS` is optional (use it for *your* workstation). The trade-off: the last run's runner IP stays on the allow-list until the next `up`/`down`. That IP belongs to GitHub's shared pool, and the API still demands valid credentials, but if that is not acceptable set `TF_RUNNER` to a self-hosted or static-IP runner. With `TF_RUNNER` set, no IP is added; put that runner's egress in `API_AUTHORIZED_CIDRS`, or for a private cluster use a runner inside the network.

`plan` never changes a running cluster, so against an existing cluster it can only refresh state if the runner's IP is already allowed.

## Cost guard: catching a forgotten cluster

[cost-guard.yml](../.github/workflows/cost-guard.yml) runs daily at 03:00 UTC (edit the `cron` line to change it) and audits all three clouds. If it finds billable resources:

| `AUTO_TEARDOWN` repo variable | Behavior |
|-------------------------------|----------|
| unset / anything but `true` | The run **fails** and shows what it found. GitHub emails you about the failed workflow. Nothing is touched. |
| `true` | It dispatches `down` for that cloud. **This destroys whatever is running at 03:00 UTC**, including something you started on purpose. |

Notes:

- Environments with **required reviewers** make each guard run wait for approval, so do not put reviewers on `aws` / `azure` / `gcp` if you rely on the guard.
- GitHub disables scheduled workflows in a **public** repository with no activity for 60 days; re-enable it under the Actions tab.
- If a teardown is still running when the guard fires, the guard's teardown queues behind it (one run per cloud at a time).

## The monitoring stack and cost

Prometheus and Grafana ([observability.md](observability.md)) request about 1.1 GiB of memory (up to 2.7 GiB at the limits), which can make a cluster add a node, but they create no load balancer, disk or other billable object of their own: their Services are `ClusterIP` and nothing is persisted. `down` needs no extra step for them.

## Know what this does not guarantee

This repo removes what it created and checks that it is gone. It cannot see:

- resources you or other tools created in the same accounts (the audit is scoped to this project's names and tags);
- charges still being **billed** for hours that already ran. Cloud billing lags by hours or days, so a bill can show a final partial day after teardown;
- anything the audit's resource lists do not cover, such as a `Retain` volume you configured to survive deletion on a storage class not used here.

The independent backstop is a **budget alert** in each account: AWS Budgets, Azure Cost Management → Budgets, Google Cloud Billing → Budgets & alerts. Set one at a small amount (for example the monthly state-storage cost plus a margin) with email alerts. If anything this audit misses starts billing, that is what tells you. Use a **dedicated project / subscription / account** per cloud for this repo so the audit has no neighbours to confuse it.

## Variables used

All set on the GitHub Environment (`aws`, `azure`, `gcp`) except where noted; see [github-secrets.md](github-secrets.md).

| Name | Effect |
|------|--------|
| `CLUSTER_NAME` | Overrides `mc-eks` / `mc-aks` / `mc-gke`. Keep teardown and the audit in agreement by setting it here, **not** in a `*.auto.tfvars` file, which would override CI's value. |
| `CLOUD_REGION` | Region (AWS, GCP) or location (Azure) |
| `API_AUTHORIZED_CIDRS` | Extra CIDRs allowed to the API, e.g. your own IP |
| `TF_RUNNER` (repository) | Use this runner instead of `ubuntu-latest` |
| `AUTO_TEARDOWN` (repository) | `true` lets the cost guard destroy clusters |

## When something goes wrong

| Symptom | Cause / fix |
|---------|-------------|
| Drain: `cannot list services` | The runner cannot reach the API (private cluster with a hosted runner, or the allow-list update failed). Use `TF_RUNNER` with a runner inside the network. |
| Drain times out on `delete pvc` | A pod outside any Deployment/StatefulSet (a bare pod or Job) still uses the claim. Delete it, then re-run `down`. |
| EKS: `Unauthorized` from kubectl/Helm | The cluster was created by a different identity (for example your SSO user), and only the creator gets admin. Create clusters with `up` in CI, or destroy the cluster locally. |
| GKE destroy: `deletion_protection` | The cluster was created locally with protection on. CI sets it off on the next `up`; or set `deletion_protection = false`, apply, then destroy. |
| Destroy hangs on the VPC / subnet / network | Something outside Terraform still uses it, typically a load balancer or ENI. Run the audit (below), delete what it lists, re-run `down`. |
| Audit fails right after a successful destroy | Cloud APIs lag. The audit already waits 5 minutes; re-run `down` (it is idempotent) or the audit locally. |
| `Error acquiring the state lock` | Another run is active, or one died. Wait, or clear the lock. |

Run the audit by hand (logged in to the cloud, in the repo root):

```sh
CLUSTER_NAME=mc-eks CLOUD_REGION=us-east-1 scripts/cluster-ops.sh audit aws
CLUSTER_NAME=mc-aks scripts/cluster-ops.sh audit azure
CLUSTER_NAME=mc-gke CLOUD_REGION=us-central1 GCP_PROJECT_ID=<project> scripts/cluster-ops.sh audit gcp
```

Exit code 0 means nothing billable was found, 1 means resources were found (listed), 2 means the check could not run.

## Tested how

`scripts/test-cluster-ops.sh` (also run in CI, and via `make test`) exercises the drain, audit and allow-list logic against stubbed cloud CLIs, including the failure modes above. The real cloud commands have not been run against real accounts; run `down` once with nothing important in it before depending on it.
