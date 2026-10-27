#!/usr/bin/env bash
# Cluster helpers for the up / down actions in .github/workflows/terraform.yml
# and for the nightly cost guard (.github/workflows/cost-guard.yml).
#
#   cluster-ops.sh allow-ip <aws|azure|gcp> <cidr>
#       Add a CIDR (the runner's own /32) to the cluster's public API allow-list,
#       keeping the existing entries. Needed because GitHub-hosted runners get a
#       new IP every run. Does nothing if the cluster is absent, the CIDR is
#       already listed, or the cluster has no public endpoint.
#
#   cluster-ops.sh kubeconfig <aws|azure|gcp>
#       Write credentials for the cluster to a kubeconfig file of its own (never
#       ~/.kube/config) and print the file's path. The context is named after the
#       cluster (mc-eks / mc-aks / mc-gke), so Helm can be pointed at it with
#       --kube-context. Fails if the cluster does not exist.
#
#   cluster-ops.sh addons <aws|azure|gcp>
#       Use Helm to list the platform releases Terraform installed (Traefik,
#       cert-manager, plus metrics-server and Cluster Autoscaler on EKS) and
#       print a Markdown table. Exit 0: all deployed. Exit 1: one is missing or
#       not "deployed". Exit 2: could not check. Needs helm and jq.
#
#   cluster-ops.sh drain <aws|azure|gcp>
#       Run BEFORE `terraform destroy`. Removes what Kubernetes controllers
#       created in the cloud on their own (load balancers, disks). Terraform does
#       not know about these; left behind they keep billing and block deletion
#       of the network.
#
#   cluster-ops.sh audit [--wait SECONDS] <aws|azure|gcp>
#       Lists billable resources that still exist for the cluster.
#       Exit 0: none. Exit 1: some (listed on stdout). Exit 2: could not check.
#       A failed check is never reported as "clean".
#
# Environment:
#   CLUSTER_NAME    cluster to act on (default mc-eks / mc-aks / mc-gke)
#   CLOUD_REGION    AWS or GCP region (default us-east-1 / us-central1)
#   GCP_PROJECT_ID  required for gcp
#
# The cloud CLIs must already be authenticated. drain needs kubectl, kubeconfig
# needs kubectl for gcp, addons needs helm and jq.
set -euo pipefail
umask 077

PROJECT_TAG="multi-cloud-k8s-helm" # the `project` tag set by infra/aws-eks

# ARNs of resource types that bill while they exist (everything else tagged with
# the project, such as IAM roles or KMS keys pending deletion, is free).
AWS_BILLABLE=':(eks:[^:]*:[^:]*:cluster/|ec2:[^:]*:[^:]*:(instance|natgateway|volume|snapshot|elastic-ip)/|elasticloadbalancing:)'

log() { echo "==> $*" >&2; }
die() {
  echo "error: $*" >&2
  exit 2
}

usage() {
  # the leading comment block, minus the shebang and the comment markers
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2
  exit 2
}

# --- shared setup -----------------------------------------------------------

init_cloud() {
  case $cloud in
    aws)
      name=${CLUSTER_NAME:-mc-eks}
      region=${CLOUD_REGION:-us-east-1}
      ;;
    azure)
      name=${CLUSTER_NAME:-mc-aks}
      rg="${name}-rg"
      ;;
    gcp)
      name=${CLUSTER_NAME:-mc-gke}
      region=${CLOUD_REGION:-us-central1}
      project=${GCP_PROJECT_ID:-}
      [ -n "$project" ] || die "GCP_PROJECT_ID is required for gcp"
      ;;
    *) usage ;;
  esac
}

# Does the cluster exist? Returns 1 when it does not; exits 2 if the CLI fails,
# so an authentication problem can never be mistaken for "already gone".
cluster_exists() {
  local out
  case $cloud in
    aws)
      out=$(aws eks list-clusters --region "$region" --query "clusters[?@=='$name']" --output text) || die "aws eks list-clusters failed"
      ;;
    azure)
      out=$(az group exists --name "$rg" --output tsv) || die "az group exists failed"
      [ "$out" = true ] || return 1
      out=$(az aks list --resource-group "$rg" --query "[?name=='$name'].name" --output tsv) || die "az aks list failed"
      ;;
    gcp)
      out=$(gcloud container clusters list --project "$project" --filter "name=$name" --format 'value(name)') || die "gcloud container clusters list failed"
      ;;
  esac
  [ -n "$out" ]
}

# --- allow-ip ---------------------------------------------------------------

# add_cidr <newline-separated current list>: print the list plus $cidr, comma-joined.
# Returns 1 (printing nothing) when $cidr is already in the list.
add_cidr() {
  if printf '%s\n' "$1" | grep -qxF -- "$cidr"; then
    return 1
  fi
  printf '%s\n%s\n' "$1" "$cidr" | sed '/^$/d; /^None$/d' | paste -sd, -
}

allow_ip() {
  [ -n "$cidr" ] || usage
  if ! cluster_exists; then
    log "cluster $name not found on $cloud; nothing to open"
    return 0
  fi

  local current merged public update_id status info
  case $cloud in
    aws)
      public=$(aws eks describe-cluster --name "$name" --region "$region" \
        --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text) || die "aws eks describe-cluster failed"
      if [ "$public" != True ]; then
        log "$name has no public endpoint; run Terraform from a runner inside its network instead"
        return 0
      fi
      current=$(aws eks describe-cluster --name "$name" --region "$region" \
        --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text) || die "aws eks describe-cluster failed"
      current=$(printf '%s' "$current" | tr '\t' '\n')
      merged=$(add_cidr "$current") || {
        log "$cidr is already allowed on $name"
        return 0
      }
      log "allowing $cidr on $name (takes a few minutes)"
      update_id=$(aws eks update-cluster-config --name "$name" --region "$region" \
        --resources-vpc-config "publicAccessCidrs=$merged" --query 'update.id' --output text) || die "aws eks update-cluster-config failed"
      while :; do
        status=$(aws eks describe-update --name "$name" --region "$region" --update-id "$update_id" \
          --query 'update.status' --output text) || die "aws eks describe-update failed"
        case $status in
          Successful) break ;;
          Failed | Cancelled) die "endpoint update $status" ;;
        esac
        sleep "${POLL_INTERVAL:-15}"
      done
      ;;
    azure)
      public=$(az aks show --resource-group "$rg" --name "$name" --query 'apiServerAccessProfile.enablePrivateCluster' --output tsv) || die "az aks show failed"
      if [ "$public" = true ] || [ "$public" = True ]; then
        log "$name is a private cluster; run Terraform from a runner inside its network instead"
        return 0
      fi
      current=$(az aks show --resource-group "$rg" --name "$name" --query 'apiServerAccessProfile.authorizedIpRanges' --output tsv) || die "az aks show failed"
      merged=$(add_cidr "$current") || {
        log "$cidr is already allowed on $name"
        return 0
      }
      log "allowing $cidr on $name"
      az aks update --resource-group "$rg" --name "$name" --api-server-authorized-ip-ranges "$merged" >/dev/null || die "az aks update failed"
      ;;
    gcp)
      command -v jq >/dev/null 2>&1 || die "jq is required for gcp allow-ip"
      info=$(gcloud container clusters describe "$name" --region "$region" --project "$project" --format json) || die "gcloud container clusters describe failed"
      if [ "$(printf '%s' "$info" | jq -r '.privateClusterConfig.enablePrivateEndpoint // false')" = true ]; then
        log "$name has a private-only endpoint; run Terraform from a runner inside its network instead"
        return 0
      fi
      current=$(printf '%s' "$info" | jq -r '.masterAuthorizedNetworksConfig.cidrBlocks[]?.cidrBlock') || die "cannot read authorized networks"
      merged=$(add_cidr "$current") || {
        log "$cidr is already allowed on $name"
        return 0
      }
      log "allowing $cidr on $name"
      gcloud container clusters update "$name" --region "$region" --project "$project" \
        --enable-master-authorized-networks --master-authorized-networks "$merged" >/dev/null || die "gcloud container clusters update failed"
      ;;
  esac
  log "$cidr can now reach the API of $name"
}

# --- drain ------------------------------------------------------------------

# use_cluster <label>: point KUBECONFIG at a fresh file holding this cluster's
# credentials, under a context named after the cluster.
use_cluster() {
  export KUBECONFIG="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/kubeconfig-$1-$cloud"
  rm -f "$KUBECONFIG"
  case $cloud in
    aws)
      aws eks update-kubeconfig --name "$name" --region "$region" --alias "$name" >/dev/null || die "cannot fetch EKS credentials"
      ;;
    azure)
      az aks get-credentials --resource-group "$rg" --name "$name" --admin --context "$name" \
        --file "$KUBECONFIG" --overwrite-existing >/dev/null || die "cannot fetch AKS credentials"
      ;;
    gcp)
      # Built by hand with a bearer token so the gke-gcloud-auth-plugin is not required.
      local info endpoint ca token
      info=$(gcloud container clusters describe "$name" --region "$region" --project "$project" \
        --format 'value(endpoint,masterAuth.clusterCaCertificate)') || die "cannot describe GKE cluster"
      endpoint=$(printf '%s' "$info" | cut -f1)
      ca=$(printf '%s' "$info" | cut -f2)
      token=$(gcloud auth print-access-token) || die "cannot get a Google access token"
      printf '%s' "$ca" | base64 -d >"$KUBECONFIG.ca"
      kubectl config set-cluster "$name" --server "https://$endpoint" \
        --certificate-authority "$KUBECONFIG.ca" --embed-certs=true >/dev/null
      kubectl config set-credentials "$name" --token "$token" >/dev/null
      kubectl config set-context "$name" --cluster "$name" --user "$name" >/dev/null
      kubectl config use-context "$name" >/dev/null
      ;;
  esac
}

kubeconfig() {
  cluster_exists || die "cluster $name not found on $cloud (bring it up first)"
  use_cluster helm
  printf '%s\n' "$KUBECONFIG"
}

# --- addons -----------------------------------------------------------------

# Releases the Terraform roots install, as release/namespace. Keep in step with
# infra/modules/core-addons and infra/aws-eks/addons.tf.
expected_addons() {
  echo "traefik/ingress cert-manager/cert-manager"
  [ "$cloud" != aws ] || echo "metrics-server/kube-system cluster-autoscaler/kube-system"
}

addons() {
  command -v jq >/dev/null 2>&1 || die "jq is required for addons"
  cluster_exists || die "cluster $name not found on $cloud (bring it up first)"
  use_cluster helm

  local releases item rel ns row bad=0
  releases=$(helm --kube-context "$name" list --all-namespaces --output json) ||
    die "helm cannot list releases (is the API server reachable from this runner?)"

  echo "| release | namespace | status | chart |"
  echo "|---|---|---|---|"
  for item in $(expected_addons); do
    rel=${item%%/*}
    ns=${item#*/}
    row=$(printf '%s' "$releases" | jq -r --arg r "$rel" --arg n "$ns" \
      '.[] | select(.name == $r and .namespace == $n) | "\(.status) | \(.chart)"') || die "cannot read helm output"
    if [ -z "$row" ]; then
      row="missing | -"
      bad=1
    elif [ "${row%% *}" != deployed ]; then
      bad=1
    fi
    echo "| $rel | $ns | $row |"
  done
  [ "$bad" -eq 0 ] || return 1
}

# scale_down <namespace> <kind>: scale every object of a kind to zero, if any exist.
scale_down() {
  local objs
  objs=$(kubectl -n "$1" get "$2" -o name) || die "cannot list $2 in $1"
  [ -z "$objs" ] || kubectl -n "$1" scale "$2" --all --replicas=0
}

drain() {
  if ! cluster_exists; then
    log "cluster $name not found on $cloud; nothing to drain"
    return 0
  fi
  use_cluster teardown

  local lb_filter='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{"\n"}{end}'
  local all_ns='{range .items[*]}{.metadata.namespace}{"\n"}{end}'
  local svc_ns ing_ns pvc_ns namespaces ns svcs svc
  svc_ns=$(kubectl get svc -A -o jsonpath="$lb_filter") || die "cannot list services (is the API server reachable from this runner?)"
  ing_ns=$(kubectl get ingress -A -o jsonpath="$all_ns") || die "cannot list ingresses"
  pvc_ns=$(kubectl get pvc -A -o jsonpath="$all_ns") || die "cannot list persistent volume claims"
  namespaces=$(printf '%s\n%s\n%s\n' "$svc_ns" "$ing_ns" "$pvc_ns" | sort -u | sed '/^$/d')

  if [ -z "$namespaces" ]; then
    log "no load balancers, ingresses or volume claims in $name"
  fi

  for ns in $namespaces; do
    log "draining namespace $ns"
    # Stop pods first so volume claims are released and can be deleted.
    scale_down "$ns" deployment
    scale_down "$ns" statefulset
    kubectl -n "$ns" delete ingress --all --wait=true --timeout=10m
    svcs=$(kubectl -n "$ns" get svc -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}') || die "cannot list services in $ns"
    for svc in $svcs; do
      # --wait returns once the cloud load balancer is gone (the cleanup finalizer clears).
      kubectl -n "$ns" delete svc "$svc" --wait=true --timeout=10m
    done
    kubectl -n "$ns" delete pvc --all --wait=true --timeout=10m
  done
  log "drain complete"
}

# --- audit ------------------------------------------------------------------

# gcp_list <label> <gcloud args...>: print "<label> <name>" per match.
gcp_list() {
  local label=$1 out
  shift
  out=$(gcloud "$@" --project "$project" --format 'value(name)') || die "gcloud $1 $2 $3 failed"
  [ -z "$out" ] || printf '%s\n' "$out" | sed "s/^/$label /"
}

# Prints one finding per line. Runs in a subshell, so `die` aborts the lookup.
audit_findings() {
  local out arns filter
  case $cloud in
    aws)
      out=$(aws eks list-clusters --region "$region" --query "clusters[?@=='$name']" --output text) || die "aws eks list-clusters failed"
      [ -z "$out" ] || echo "eks cluster $out"
      # Terraform-created resources carry the project tag; resources made by
      # Kubernetes controllers (load balancers, volumes) carry the cluster tag.
      for filter in "Key=project,Values=$PROJECT_TAG" "Key=kubernetes.io/cluster/$name"; do
        arns=$(aws resourcegroupstaggingapi get-resources --region "$region" --tag-filters "$filter" \
          --query 'ResourceTagMappingList[].ResourceARN' --output text) || die "aws resourcegroupstaggingapi failed"
        printf '%s\n' "$arns" | tr '\t' '\n' | grep -E "$AWS_BILLABLE" || true
      done
      ;;
    azure)
      # Everything, including what Kubernetes creates, lives in these two groups.
      out=$(az group exists --name "$rg" --output tsv) || die "az group exists failed"
      [ "$out" != true ] || echo "resource group $rg"
      out=$(az group list --query "[?starts_with(name, 'MC_${rg}_')].name" --output tsv) || die "az group list failed"
      [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/node resource group /'
      ;;
    gcp)
      gcp_list "gke cluster" container clusters list --filter "name=$name"
      gcp_list "vm" compute instances list --filter "name~^gke-${name}-"
      gcp_list "node disk" compute disks list --filter "name~^gke-${name}-"
      gcp_list "volume disk" compute disks list --filter "labels.kubernetes_io_created-for_pvc_name:*"
      gcp_list "cloud nat router" compute routers list --filter "name=${name}-router"
      gcp_list "network" compute networks list --filter "name=${name}-vpc"
      gcp_list "load balancer rule" compute forwarding-rules list --filter "description~kubernetes.io/service-name"
      ;;
  esac
}

audit() {
  local wait=$1 deadline findings
  deadline=$(($(date +%s) + wait))
  while :; do
    findings=$(audit_findings) || exit 2
    findings=$(printf '%s\n' "$findings" | sort -u | sed '/^$/d')
    if [ -z "$findings" ]; then
      log "no billable resources remain for $name on $cloud"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "billable resources still exist for $name on $cloud:"
      printf '%s\n' "$findings"
      return 1
    fi
    log "found $(printf '%s\n' "$findings" | wc -l | tr -d ' ') resource(s); cloud APIs lag after deletes, rechecking in ${AUDIT_INTERVAL:-20}s"
    sleep "${AUDIT_INTERVAL:-20}"
  done
}

# --- main -------------------------------------------------------------------

[ $# -ge 2 ] || usage
command=$1
shift
wait_seconds=0
if [ "${1:-}" = "--wait" ]; then
  [ $# -ge 3 ] || usage
  wait_seconds=$2
  shift 2
fi
cloud=${1:-}
cidr=${2:-}
name=""
region=""
rg=""
project=""
init_cloud

case $command in
  allow-ip) allow_ip ;;
  kubeconfig) kubeconfig ;;
  addons) addons ;;
  drain) drain ;;
  audit) audit "$wait_seconds" ;;
  *) usage ;;
esac
