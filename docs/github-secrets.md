# GitHub secrets & cloud credentials

You configure these by hand; nothing in this repo creates them. The goal is **no long-lived cloud keys in GitHub**: the workflows ([terraform.yml](../.github/workflows/terraform.yml), [helm-check.yml](../.github/workflows/helm-check.yml), [cost-guard.yml](../.github/workflows/cost-guard.yml)) trade a GitHub-issued OIDC token for short-lived cloud credentials. What you store in GitHub are identifiers (role ARN, client ID, provider name), not passwords.

Replace the placeholders:

| Placeholder | Meaning |
|-------------|---------|
| `OWNER/REPO` | `AravindRajeshkanna/multi-cloud-k8s-helm` |
| `<...>` | Values from your own accounts |

## 1. Create three GitHub Environments

Repo → **Settings → Environments → New environment**: `aws`, `azure`, `gcp`. The workflow picks the environment from its `cloud` input, and the cloud trusts only tokens issued for that environment.

Recommended on each: **Deployment branches** → *Selected branches* → `main`; optionally **Required reviewers** (this gates the whole run, including `plan`; do not add them if you use the [cost guard](cost-control.md#cost-guard-catching-a-forgotten-cluster), whose scheduled runs would wait for approval).

CLI equivalent:

```sh
for e in aws azure gcp; do gh api -X PUT "repos/OWNER/REPO/environments/$e" >/dev/null; done
```

## 2. What goes where

Set these as **environment** secrets / variables on the matching environment (Settings → Environments → *name*). Secrets are masked in logs; variables are not, so only genuinely sensitive values are secrets.

### Environment `aws`

| Kind | Name | Value |
|------|------|-------|
| secret | `AWS_ROLE_ARN` | ARN of the role from §3 |
| variable | `TF_STATE_BUCKET` | S3 bucket for state |
| variable | `CLOUD_REGION` | optional, default `us-east-1`; must also be the state bucket's region |
| variable | `API_AUTHORIZED_CIDRS` | optional, JSON list of *your* CIDRs, e.g. `["203.0.113.10/32"]`; the runner's own IP is added automatically |
| variable | `CLUSTER_NAME` | optional, default `mc-eks` |

### Environment `azure`

| Kind | Name | Value |
|------|------|-------|
| secret | `AZURE_CLIENT_ID` | App registration (client) ID |
| secret | `AZURE_TENANT_ID` | Directory (tenant) ID |
| secret | `AZURE_SUBSCRIPTION_ID` | Subscription ID |
| variable | `TF_STATE_RESOURCE_GROUP` | Resource group of the state storage account |
| variable | `TF_STATE_STORAGE_ACCOUNT` | Storage account name |
| variable | `TF_STATE_CONTAINER` | optional, default `tfstate` |
| variable | `CLOUD_REGION` | optional, default `eastus` |
| variable | `API_AUTHORIZED_CIDRS` | optional, JSON list of your CIDRs; the runner's own IP is added automatically |
| variable | `CLUSTER_NAME` | optional, default `mc-aks` |

### Environment `gcp`

| Kind | Name | Value |
|------|------|-------|
| secret | `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/<NUMBER>/locations/global/workloadIdentityPools/github/providers/github-oidc` |
| secret | `GCP_SERVICE_ACCOUNT` | `tf-deployer@<PROJECT_ID>.iam.gserviceaccount.com` |
| variable | `GCP_PROJECT_ID` | Project ID |
| variable | `TF_STATE_BUCKET` | GCS bucket for state |
| variable | `CLOUD_REGION` | optional, default `us-central1` |
| variable | `API_AUTHORIZED_CIDRS` | optional, JSON list of your CIDRs; the runner's own IP is added automatically |
| variable | `CLUSTER_NAME` | optional, default `mc-gke` |

### Repository-level (optional)

| Kind | Name | Value |
|------|------|-------|
| variable | `TF_RUNNER` | `runs-on` label of a static-IP or self-hosted runner. Default `ubuntu-latest`, whose IP is added to each cluster's API allow-list per run (see [cost-control.md](cost-control.md#how-the-runner-reaches-the-cluster)). |
| variable | `ENABLE_MONITORING` | `true` installs Prometheus and Grafana on the next `up` ([observability.md](observability.md)). Default off; a bool, so leave it unset rather than empty. Optional. |
| variable | `APP_DOMAIN` | A domain whose DNS you control, for `prod` deployments (hosts are `web-prod.<cloud>.<domain>`). Optional; can also be set per environment. See [deploying.md](deploying.md#variables). |
| variable | `ACME_EMAIL` | Email for Let's Encrypt; installs the staging and production issuers and is required for `prod`. Optional. |
| variable | `SCAN_FAIL_SEVERITY` | `critical` (default) or `high`: the severity at which the weekly [image scan](supply-chain.md#pass-or-fail) fails when a fix exists. Optional. |
| variable | `SKIP_INGRESS_SMOKE` | `1` skips the HTTPS request through the load balancer after a deploy, for a runner that cannot reach it. Optional. |
| variable | `AUTO_TEARDOWN` | `true` lets the nightly [cost guard](cost-control.md#cost-guard-catching-a-forgotten-cluster) destroy clusters it finds running. Leave unset to only get an alert. |

Setting values from the CLI:

```sh
gh secret set   AWS_ROLE_ARN     --env aws --repo OWNER/REPO --body 'arn:aws:iam::...:role/...'
gh variable set TF_STATE_BUCKET  --env aws --repo OWNER/REPO --body 'my-org-tfstate-aws'
```

## 3. AWS

**One-time, per account.** Requires an admin-capable CLI session.

```sh
# 3a. Let AWS trust GitHub's OIDC issuer
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com

# 3b. State bucket (add --create-bucket-configuration LocationConstraint=<region> outside us-east-1)
BUCKET=<globally-unique-name>
aws s3api create-bucket --bucket "$BUCKET" --region us-east-1
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

```sh
# 3c. Role that only this repo's `aws` environment can assume
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
cat > trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:OWNER/REPO:environment:aws"
      }
    }
  }]
}
EOF
aws iam create-role --role-name mc-k8s-helm-terraform --assume-role-policy-document file://trust.json
```

Permissions: the VPC and EKS modules create VPCs, subnets, NAT gateways, security groups, EKS clusters and add-ons, IAM roles and policies, a KMS key and a CloudWatch log group, and the root creates Pod Identity associations. In a **sandbox account**, attach `AdministratorAccess` to get going, then narrow it once a full apply works. The teardown audit also calls `eks:ListClusters` and `tag:GetResources`, and the drain step needs access to the cluster itself (the role that creates a cluster is made its admin, so create clusters with the `up` action). Also make sure the role can read and write your state bucket (`s3:ListBucket`, `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`; the lock file is written next to the state object).

```sh
aws iam attach-role-policy --role-name mc-k8s-helm-terraform \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

Then set `AWS_ROLE_ARN` (output of `aws iam get-role --role-name mc-k8s-helm-terraform --query Role.Arn --output text`).

## 4. Azure

```sh
az login
SUB=$(az account show --query id -o tsv)
TENANT=$(az account show --query tenantId -o tsv)

# 4a. App registration + service principal
APP_ID=$(az ad app create --display-name mc-k8s-helm-github --query appId -o tsv)
az ad sp create --id "$APP_ID"

# 4b. Federated credential: only this repo's `azure` environment
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "github-environment-azure",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:OWNER/REPO:environment:azure",
  "audiences": ["api://AzureADTokenExchange"]
}'

# 4c. Roles on the subscription
az role assignment create --assignee "$APP_ID" --role Contributor --scope "/subscriptions/$SUB"
az role assignment create --assignee "$APP_ID" --role "Role Based Access Control Administrator" --scope "/subscriptions/$SUB"

# 4d. State storage (names must be globally unique / lowercase for the account)
RG=<state-resource-group>; SA=<stateaccountname>
az group create --name "$RG" --location eastus
az storage account create --name "$SA" --resource-group "$RG" --sku Standard_LRS \
  --allow-blob-public-access false --min-tls-version TLS1_2
az storage container create --name tfstate --account-name "$SA" --auth-mode login
az role assignment create --assignee "$APP_ID" --role "Storage Blob Data Contributor" \
  --scope "$(az storage account show --name "$SA" --resource-group "$RG" --query id -o tsv)"
```

The AKS root creates a user-assigned identity and grants it *Network Contributor* on the node subnet, which is why the app needs permission to write role assignments (4c, second line). Scope that role down with a condition once things work.

Set `AZURE_CLIENT_ID` = `$APP_ID`, `AZURE_TENANT_ID` = `$TENANT`, `AZURE_SUBSCRIPTION_ID` = `$SUB`. If your signed-in user cannot create app registrations, ask a directory admin for 4a–4b.

## 5. Google Cloud

```sh
PROJECT_ID=<project-id>
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')

# 5a. APIs
gcloud services enable --project "$PROJECT_ID" \
  container.googleapis.com compute.googleapis.com iam.googleapis.com \
  iamcredentials.googleapis.com sts.googleapis.com cloudresourcemanager.googleapis.com

# 5b. Workload Identity Federation for GitHub, locked to this repo
gcloud iam workload-identity-pools create github --project "$PROJECT_ID" \
  --location global --display-name "GitHub Actions"
gcloud iam workload-identity-pools providers create-oidc github-oidc --project "$PROJECT_ID" \
  --location global --workload-identity-pool github \
  --issuer-uri https://token.actions.githubusercontent.com \
  --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.environment=assertion.environment" \
  --attribute-condition "assertion.repository == 'OWNER/REPO'"

# 5c. Deployer service account, impersonable only from the `gcp` environment
gcloud iam service-accounts create tf-deployer --project "$PROJECT_ID"
SA="tf-deployer@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud iam service-accounts add-iam-policy-binding "$SA" --project "$PROJECT_ID" \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.environment/gcp"

# 5d. What the deployer may do (sandbox project: roles/owner is the shortcut).
#     compute.viewer lets the teardown audit list VMs and disks.
for role in roles/container.admin roles/compute.networkAdmin roles/compute.viewer roles/iam.serviceAccountAdmin \
            roles/iam.serviceAccountUser roles/resourcemanager.projectIamAdmin; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" --member "serviceAccount:$SA" --role "$role"
done

# 5e. State bucket
BUCKET=<globally-unique-name>
gcloud storage buckets create "gs://$BUCKET" --project "$PROJECT_ID" --location US \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update "gs://$BUCKET" --versioning
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member "serviceAccount:$SA" --role roles/storage.objectAdmin
```

Set `GCP_WORKLOAD_IDENTITY_PROVIDER` = `projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/providers/github-oidc` and `GCP_SERVICE_ACCOUNT` = `$SA`.

## 6. Local runs (no GitHub involved)

Log in with each cloud's CLI (`aws sso login` / `az login` / `gcloud auth application-default login`), copy `backend.hcl.example` to `backend.hcl` in the cluster root, then follow [infra/README.md](../infra/README.md).

## 7. Check it works

Actions → **Clusters (plan / up / down)** → *Run workflow* → pick a cloud, action `plan`. The first failure you are likely to see, and its cause:

| Symptom | Cause |
|---------|-------|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust `sub` doesn't match `repo:OWNER/REPO:environment:aws` exactly (check case and environment name) |
| `AADSTS700213` / no matching federated identity | Federated credential subject differs from `repo:OWNER/REPO:environment:azure` |
| `unauthorized_client` / `The given credential is rejected by the attribute condition` | Provider attribute condition or `principalSet` member doesn't match the repo / environment |
| `Error acquiring the state lock` | A previous run is still going, or died; wait or remove the lock |
| Terraform cannot reach the cluster | With a custom `TF_RUNNER`: its egress isn't in `API_AUTHORIZED_CIDRS`, or the cluster is private. See [infra/README.md](../infra/README.md#where-terraform-runs-from) |

## Security notes

- On the default hosted runner, each `up`/`down` adds that run's public IP to the cluster's API allow-list and leaves it there until the next run ([details](cost-control.md#how-the-runner-reaches-the-cluster)). The API still needs valid credentials; use `TF_RUNNER` if you want this closed.
- The `down` action destroys infrastructure. It only runs from `main` and needs `confirm=destroy`; restricting the environments' deployment branches to `main` (above) backs that up.
- Never commit `backend.hcl`, `terraform.tfvars` or kubeconfigs (they are git-ignored). Terraform state holds secrets (e.g. the AKS admin certificate); keep state buckets private and versioned.
- The permission sets above are deliberately broad for first-time setup. Tightening them is part of Phase 6.
- If you later add `pull_request` workflows that use cloud credentials, remember forks cannot receive them and the OIDC `sub` claim for PRs differs (`...:pull_request`).
