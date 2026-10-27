# infra — Phase 1: provision clusters

One Terraform root per cloud, plus a shared module for the add-ons that are identical everywhere.

```
infra/
├── aws-eks/            VPC + EKS (managed node group) + Cluster Autoscaler + add-ons
├── azure-aks/          VNet + NAT + AKS (system + user pools) + add-ons
├── gcp-gke/            VPC + Cloud NAT + GKE Standard (regional) + add-ons
└── modules/core-addons/  metrics-server (optional), Traefik, cert-manager
```

Each root has the same file layout: `versions.tf` (providers), `backend.tf` (remote state, configured at init), `providers.tf`, `variables.tf`, `main.tf` (network + cluster), `addons.tf`, `outputs.tf`, `terraform.tfvars.example`, `backend.hcl.example`. Provider versions are pinned in the committed `.terraform.lock.hcl` files.

What gets built, in terms of the roadmap: [phase-1-provision-clusters.md](../docs/roadmap/phase-1-provision-clusters.md).

> **Cost.** Every cluster here bills continuously (control plane, nodes, NAT gateway / Cloud NAT). Destroy what you are not using.

## Before you start

1. `make prereqs` from the repo root.
2. Cloud accounts, state storage and (for CI) OIDC trust: [github-secrets.md](../docs/github-secrets.md).
3. Your public IP in CIDR form — it must go in `api_authorized_cidrs`:
   `echo "$(curl -s https://checkip.amazonaws.com)/32"`

## Where Terraform runs from

Terraform installs the add-ons through the Kubernetes API, so whatever runs `apply` must be able to reach the API server. That drives how the endpoint is configured ([ADR 0001 §7](../docs/decisions/0001-platform-decisions.md)):

| Setting | Effect |
|---------|--------|
| `enable_public_endpoint = true` (default) | Public API endpoint, reachable only from `api_authorized_cidrs`. The list is required; empty or `0.0.0.0/0` is rejected. |
| `enable_public_endpoint = false` | Private endpoint only. Run Terraform from a machine inside (or peered with) the VPC/VNet. |

Practical options:

- **GitHub Actions (recommended).** The [Clusters workflow](../.github/workflows/terraform.yml) (`up` / `down` / `plan`) works on the default `ubuntu-latest` runner: each run adds its own public IP to the cluster's API allow-list, so no static IP is needed. Details and trade-offs: [docs/cost-control.md](../docs/cost-control.md#how-the-runner-reaches-the-cluster). For a tighter setup use a static-IP or self-hosted runner, set the repo variable `TF_RUNNER` to its label and list its egress in `API_AUTHORIZED_CIDRS`. A self-hosted runner needs the tools in [Phase 0](../docs/roadmap/phase-0-prerequisites.md), plus `jq` and `gh`, and for EKS the `aws` CLI on `PATH`.
- **Your workstation**, with your IP in `api_authorized_cidrs`. Good for experiments. A cluster made this way is owned by *your* identity: on EKS only the creator gets admin, so the CI role will be refused (`Unauthorized`) until you destroy it locally or create it again with `up`.

## Apply from your workstation (optional)

All clouds follow the same pattern; only the login and the required variable differ.

```sh
cd infra/<aws-eks | azure-aks | gcp-gke>
cp backend.hcl.example backend.hcl            # fill in your state bucket / storage account
cp terraform.tfvars.example terraform.tfvars  # at least api_authorized_cidrs
terraform init -backend-config=backend.hcl
terraform plan -out tfplan
terraform apply tfplan
```

| | AWS | Azure | GCP |
|-|-----|-------|-----|
| Log in | `aws sso login` (or any credentials the SDK finds) | `az login` | `gcloud auth application-default login` |
| Extra input | — | `export TF_VAR_subscription_id=$(az account show --query id -o tsv)` | `export TF_VAR_project_id=<project-id>` |
| Needs on `PATH` | `aws` (token for the Helm provider) | — | — |

First applies take roughly 10–20 minutes (the control plane dominates).

## Connect and verify

Each root prints a ready-made command. It adds the cluster to your kubeconfig with a context named after the cluster (`mc-eks`, `mc-aks`, `mc-gke`):

```sh
eval "$(terraform output -raw kubeconfig_command)"
kubectl config get-contexts

kubectl --context mc-eks get nodes -o wide                 # nodes Ready, spread across zones
kubectl --context mc-eks get pods -A                       # everything Running
kubectl --context mc-eks top nodes                         # metrics-server works
kubectl --context mc-eks -n ingress get svc traefik        # EXTERNAL-IP / hostname assigned
kubectl --context mc-eks -n cert-manager get pods          # 3 pods Ready
helm --kube-context mc-eks list -A                         # traefik, cert-manager (+ metrics-server, cluster-autoscaler on EKS)
kubectl config use-context mc-aks                          # switch clusters
```

## Per-cloud notes

### EKS

- Kubernetes 1.35, managed node group in private subnets across 3 AZs; a single NAT gateway by default (`single_nat_gateway = false` for one per AZ).
- Both IRSA (OIDC provider) and Pod Identity are enabled. The EBS CSI driver and Cluster Autoscaler use Pod Identity.
- The Cluster Autoscaler's chart version and image tag (`cluster_autoscaler_chart_version`, `cluster_autoscaler_image_tag`) must match `kubernetes_version`'s minor; bump them together. The image tag is set explicitly because the chart's default lags upstream's patch releases ([supply-chain.md](../docs/supply-chain.md)).
- Traefik's Service is annotated for an in-tree NLB, so the AWS Load Balancer Controller isn't required yet.

### AKS

- Kubernetes 1.35 (patch managed by AKS, `patch` upgrade channel), Azure CNI Overlay with Cilium, egress through a NAT gateway.
- The system pool is tainted for critical add-ons only; workloads land on the `user` pool.
- Public mode adds the cluster's own NAT IP to the authorized ranges automatically (nodes need it to reach the API).
- A user-assigned identity with *Network Contributor* on the node subnet is created first, so the deploying principal needs rights to write role assignments. If the first apply fails with a subnet-authorization error, role propagation lagged: wait a minute and apply again.
- Uses local (certificate) admin credentials for Helm; Entra ID RBAC is a Phase 6 item.
- metrics-server is built in, so the module skips it.

### GKE

- Standard mode, regional (3 zones), release channel `REGULAR` (Kubernetes 1.35 at the time of writing; the channel chooses and upgrades the version). Private nodes; Cloud NAT for egress; Dataplane V2.
- Per-zone autoscaling: `node_min_count_per_zone = 1` means at least 3 nodes in a regional cluster.
- A dedicated least-privilege node service account is created; the deployer therefore needs IAM admin rights on the project.
- `deletion_protection` defaults to `true`. Set it to `false` and apply before `terraform destroy`.
- metrics-server is built in, so the module skips it.
- Enable the required APIs once per project: see [github-secrets.md §5](../docs/github-secrets.md#5-google-cloud).

## Destroy

Use the **down** action ([docs/cost-control.md](../docs/cost-control.md)): it removes load balancers and volumes that Kubernetes created, destroys everything Terraform manages, and then verifies that nothing billable is left.

From a workstation instead:

```sh
scripts/cluster-ops.sh drain <aws|azure|gcp>   # with CLUSTER_NAME / CLOUD_REGION / GCP_PROJECT_ID set
terraform destroy                               # GKE: set deletion_protection = false and apply first
scripts/cluster-ops.sh audit <aws|azure|gcp>   # exit 0 = nothing billable left
```

Add-on Helm releases are removed before the cluster. If a destroy fails halfway, re-run it.

## Changing versions

- **Kubernetes:** change `kubernetes_version` (EKS, AKS) or the release channel (GKE). Upgrade one minor at a time.
- **Charts:** the add-on chart versions are variables with pinned defaults in [modules/core-addons](modules/core-addons/variables.tf). Dependabot proposes provider and module updates; chart versions are updated by hand.
