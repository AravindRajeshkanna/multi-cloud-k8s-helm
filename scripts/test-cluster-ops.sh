#!/usr/bin/env bash
# Offline tests for scripts/cluster-ops.sh. The cloud CLIs and kubectl are replaced
# with stubs, so no credentials or network are needed. Run: scripts/test-cluster-ops.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/cluster-ops.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
export STUB_LOG="$work/calls.log"
export PATH="$work/bin:$PATH"
export RUNNER_TEMP="$work"
export AUDIT_INTERVAL=0
export POLL_INTERVAL=0

# Each stub answers from STUB_* environment variables and fails when STUB_FAIL is set.
cat >"$work/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >>"$STUB_LOG"
[ -z "${STUB_FAIL:-}" ] || { echo "AccessDenied" >&2; exit 254; }
case "$*" in
  "eks list-clusters"*) printf '%s' "${STUB_EKS:-}" ;;
  "eks update-cluster-config"*) echo "upd-1" ;;
  "eks describe-update"*) echo "Successful" ;;
  "eks describe-cluster"*endpointPublicAccess*) echo "${STUB_AWS_PUBLIC:-True}" ;;
  "eks describe-cluster"*publicAccessCidrs*) printf '%s' "${STUB_AWS_CIDRS:-198.51.100.7/32}" ;;
  "resourcegroupstaggingapi"*) printf '%s' "${STUB_ARNS:-}" ;;
esac
EOF
cat >"$work/bin/az" <<'EOF'
#!/usr/bin/env bash
echo "az $*" >>"$STUB_LOG"
[ -z "${STUB_FAIL:-}" ] || { echo "AuthorizationFailed" >&2; exit 1; }
case "$*" in
  "group exists"*) echo "${STUB_RG_EXISTS:-false}" ;;
  "group list"*) printf '%s' "${STUB_NODE_RG:-}" ;;
  "aks list"*) printf '%s' "${STUB_AKS:-}" ;;
  "aks show"*enablePrivateCluster*) echo "${STUB_AKS_PRIVATE:-false}" ;;
  "aks show"*authorizedIpRanges*) printf '%s\n' "${STUB_AKS_CIDRS:-198.51.100.7/32}" ;;
esac
EOF
cat >"$work/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud $*" >>"$STUB_LOG"
[ -z "${STUB_FAIL:-}" ] || { echo "PERMISSION_DENIED" >&2; exit 1; }
case "$*" in
  "container clusters list"*) printf '%s' "${STUB_GKE:-}" ;;
  "container clusters describe"*"--format json")
    default='{"masterAuthorizedNetworksConfig":{"cidrBlocks":[{"cidrBlock":"198.51.100.7/32"}]}}'
    printf '%s' "${STUB_GKE_JSON:-$default}"
    ;;
  "container clusters describe"*) printf '203.0.113.1\tQ0E=' ;;
  "compute instances list"*) printf '%s' "${STUB_VMS:-}" ;;
  "auth print-access-token"*) echo "token" ;;
esac
EOF
cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
[ -z "${STUB_KUBECTL_FAIL:-}" ] || { echo "connection refused" >&2; exit 1; }
case "$*" in
  "get svc -A"*) printf '%s' "${STUB_SVC_NS:-}" ;;
  "get pvc -A"*) printf '%s' "${STUB_PVC_NS:-}" ;;
  *"get deployment -o name"*) echo "deployment.apps/web" ;;
  *"get svc -o jsonpath"*) echo "web-lb" ;;
esac
EOF
chmod +x "$work/bin/"*

failures=0
# expect <description> <expected exit code> <command...>   (stdout+stderr kept in $out)
expect() {
  local desc=$1 want=$2 got
  shift 2
  : >"$STUB_LOG"
  out=$("$@" 2>&1)
  got=$?
  if [ "$got" -eq "$want" ]; then
    echo "ok    $desc"
  else
    echo "FAIL  $desc (exit $got, wanted $want)"
    printf '%s\n' "$out" | while IFS= read -r line; do printf '        %s\n' "$line"; done
    failures=$((failures + 1))
  fi
}
contains() { # <description> <needle>   checks $out
  if printf '%s' "$out" | grep -qF -- "$2"; then echo "ok    $1"; else
    echo "FAIL  $1 (missing: $2)"
    failures=$((failures + 1))
  fi
}
called() { # <description> <needle>   checks the stub call log
  if grep -qF -- "$2" "$STUB_LOG"; then echo "ok    $1"; else
    echo "FAIL  $1 (never called: $2)"
    failures=$((failures + 1))
  fi
}
not_called() {
  if grep -qF -- "$2" "$STUB_LOG"; then
    echo "FAIL  $1 (called: $2)"
    failures=$((failures + 1))
  else echo "ok    $1"; fi
}

nat="arn:aws:ec2:us-east-1:111122223333:natgateway/nat-0abc"
role="arn:aws:iam::111122223333:role/mc-eks-ebs-csi"
key="arn:aws:kms:us-east-1:111122223333:key/1234"

echo "-- audit: aws"
expect "clean account reports nothing" 0 env STUB_ARNS="" "$script" audit aws
expect "billable NAT gateway is reported" 1 env STUB_ARNS="$nat" "$script" audit aws
contains "  and names the resource" "$nat"
expect "IAM roles and KMS keys are ignored" 0 env STUB_ARNS="$role	$key" "$script" audit aws
expect "a live cluster is reported" 1 env STUB_EKS="mc-eks" "$script" audit aws
expect "CLI failure is never read as clean" 2 env STUB_FAIL=1 "$script" audit aws

echo "-- audit: azure"
expect "no resource groups left" 0 "$script" audit azure
expect "cluster resource group still exists" 1 env STUB_RG_EXISTS=true "$script" audit azure
expect "AKS node resource group still exists" 1 env STUB_NODE_RG="MC_mc-aks-rg_mc-aks_eastus" "$script" audit azure
expect "CLI failure is never read as clean" 2 env STUB_FAIL=1 "$script" audit azure

echo "-- audit: gcp"
expect "project id is required" 2 env GCP_PROJECT_ID="" "$script" audit gcp
expect "nothing left" 0 env GCP_PROJECT_ID=p "$script" audit gcp
expect "cluster still exists" 1 env GCP_PROJECT_ID=p STUB_GKE="mc-gke" "$script" audit gcp
expect "leftover node VM" 1 env GCP_PROJECT_ID=p STUB_VMS="gke-mc-gke-default-1" "$script" audit gcp
expect "CLI failure is never read as clean" 2 env GCP_PROJECT_ID=p STUB_FAIL=1 "$script" audit gcp

echo "-- audit: usage"
expect "unknown cloud is rejected" 2 "$script" audit mars
expect "custom cluster name is honoured" 1 env CLUSTER_NAME=other STUB_EKS="other" "$script" audit aws

echo "-- drain"
expect "absent cluster: nothing to do" 0 env STUB_EKS="" "$script" drain aws
not_called "  and kubectl is not touched" "kubectl"
expect "present cluster is drained" 0 env STUB_EKS="mc-eks" STUB_SVC_NS="web" STUB_PVC_NS="web" "$script" drain aws
called "  workloads scaled to zero" "scale deployment --all --replicas=0"
called "  load balancer service deleted" "delete svc web-lb"
called "  volume claims deleted" "delete pvc --all"
expect "empty cluster drains cleanly" 0 env STUB_EKS="mc-eks" "$script" drain aws
not_called "  with nothing deleted" "delete svc"
expect "unreachable API fails closed" 2 env STUB_EKS="mc-eks" STUB_KUBECTL_FAIL=1 "$script" drain aws
expect "auth failure is not mistaken for 'no cluster'" 2 env STUB_FAIL=1 "$script" drain aws
expect "azure drain" 0 env STUB_RG_EXISTS=true STUB_AKS="mc-aks" STUB_PVC_NS="data" "$script" drain azure
called "  uses admin credentials" "--admin"
expect "gcp drain" 0 env GCP_PROJECT_ID=p STUB_GKE="mc-gke" STUB_SVC_NS="web" "$script" drain gcp
called "  builds a kubeconfig from a token" "set-credentials mc-gke --token"

echo "-- allow-ip"
ip="203.0.113.9/32"
expect "aws: adds the runner and keeps existing entries" 0 env STUB_EKS="mc-eks" "$script" allow-ip aws "$ip"
called "  merged list sent" "publicAccessCidrs=198.51.100.7/32,$ip"
expect "aws: already allowed is a no-op" 0 env STUB_EKS="mc-eks" STUB_AWS_CIDRS="$ip" "$script" allow-ip aws "$ip"
not_called "  no update issued" "update-cluster-config"
expect "aws: no public endpoint is left alone" 0 env STUB_EKS="mc-eks" STUB_AWS_PUBLIC=False "$script" allow-ip aws "$ip"
not_called "  no update issued" "update-cluster-config"
expect "aws: absent cluster is skipped" 0 env STUB_EKS="" "$script" allow-ip aws "$ip"
not_called "  no update issued" "update-cluster-config"
expect "aws: API failure is an error" 2 env STUB_FAIL=1 "$script" allow-ip aws "$ip"
expect "a CIDR is required" 2 env STUB_EKS="mc-eks" "$script" allow-ip aws
expect "azure: adds the runner and keeps existing entries" 0 env STUB_RG_EXISTS=true STUB_AKS="mc-aks" STUB_AKS_CIDRS="198.51.100.7/32
20.1.2.3/32" "$script" allow-ip azure "$ip"
called "  merged list sent" "--api-server-authorized-ip-ranges 198.51.100.7/32,20.1.2.3/32,$ip"
expect "azure: unset list (None) becomes just the runner" 0 env STUB_RG_EXISTS=true STUB_AKS="mc-aks" STUB_AKS_CIDRS="None" "$script" allow-ip azure "$ip"
called "  list sent" "--api-server-authorized-ip-ranges $ip"
expect "azure: private cluster is left alone" 0 env STUB_RG_EXISTS=true STUB_AKS="mc-aks" STUB_AKS_PRIVATE=true "$script" allow-ip azure "$ip"
not_called "  no update issued" "aks update"
expect "gcp: adds the runner and keeps existing entries" 0 env GCP_PROJECT_ID=p STUB_GKE="mc-gke" "$script" allow-ip gcp "$ip"
called "  merged list sent" "--master-authorized-networks 198.51.100.7/32,$ip"
expect "gcp: private-only endpoint is left alone" 0 env GCP_PROJECT_ID=p STUB_GKE="mc-gke" STUB_GKE_JSON='{"privateClusterConfig":{"enablePrivateEndpoint":true}}' "$script" allow-ip gcp "$ip"
not_called "  no update issued" "clusters update"

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
