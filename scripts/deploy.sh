#!/usr/bin/env bash
# Deploy the workloads to one cluster and check that they work. Used by the
# Deploy workflow, by the "deploy" option of the Clusters workflow, and by the
# kind test (scripts/test-charts-kind.sh). Details: docs/deploying.md.
#
#   deploy.sh <aws|azure|gcp> <dev|prod>
#
# In the roadmap's order: 1. the platform pieces that depend on the cluster
# (the admission policies in policies/, and the cert-manager issuers;
# cert-manager and the ingress controller themselves come from Terraform),
# 2. shared services (none yet), 3. the application chart in a namespace that
# enforces those policies, 4. validation: helm test, the certificate, the HPA
# receiving metrics, and a real HTTPS request through the ingress controller's
# load balancer.
#
# dev gets an ingress with a self-signed certificate, so it needs no domain.
# prod uses Let's Encrypt, so it needs APP_DOMAIN and ACME_EMAIL, and a DNS
# record for the printed host name once the load balancer has an address.
#
# Environment:
#   KUBE_CONTEXT         required: kubeconfig context of the cluster (its name)
#   APP_DOMAIN           base domain; hosts are web-<env>.<cloud>.<domain>
#                        (default example.test; required for prod)
#   ACME_EMAIL           enables the Let's Encrypt issuers (required for prod)
#   IMAGE_TAG            deploy this image tag instead of the chart's appVersion
#   INGRESS_ADDRESS      address (IP or name) of the ingress controller;
#                        default: the load balancer of Service ingress/traefik
#   INGRESS_HTTPS_PORT   default 443
#   SKIP_INGRESS_SMOKE   1: do not send a request through the ingress (for a
#                        runner that cannot reach the load balancer)
#   LB_TIMEOUT SMOKE_TIMEOUT CERT_TIMEOUT HPA_TIMEOUT   seconds; default 600 600 180 180
#   POLL_INTERVAL        seconds between checks; default 10
#
# Progress goes to stderr; a Markdown summary goes to stdout and, in GitHub
# Actions, to the job summary.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

log() { echo "==> $*" >&2; }
die() {
  echo "error: $*" >&2
  exit 1
}
usage() {
  # the leading comment block, minus the shebang and the comment markers
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2
  exit 2
}

[ $# -eq 2 ] || usage
cloud=$1
env=$2
case $cloud in
  aws) values_cloud=eks ;;
  azure) values_cloud=aks ;;
  gcp) values_cloud=gke ;;
  *) usage ;;
esac
case $env in dev | prod) ;; *) usage ;; esac

ctx=${KUBE_CONTEXT:-}
[ -n "$ctx" ] || die "set KUBE_CONTEXT to the cluster's kubeconfig context (mc-eks, mc-aks or mc-gke)"
if [ "$env" = prod ]; then
  [ -n "${APP_DOMAIN:-}" ] || die "prod needs APP_DOMAIN, the domain whose DNS you control"
  [ -n "${ACME_EMAIL:-}" ] || die "prod needs ACME_EMAIL for Let's Encrypt"
fi

domain=${APP_DOMAIN:-example.test}
release=web
ns=web-$env
host=web-$env.$cloud.$domain
poll=${POLL_INTERVAL:-10}
lb_timeout=${LB_TIMEOUT:-600}
smoke_timeout=${SMOKE_TIMEOUT:-600}
cert_timeout=${CERT_TIMEOUT:-180}
hpa_timeout=${HPA_TIMEOUT:-180}

k() { kubectl --context "$ctx" "$@"; }
h() { helm --kube-context "$ctx" "$@"; }

# On failure, show what the cluster says about the app, so the log explains itself.
diagnostics() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "--- state of namespace $ns ---" >&2
    k -n "$ns" get pods,ingress,certificate 2>&1 | tail -n 30 >&2 || true
    k -n "$ns" get events --sort-by=.lastTimestamp 2>&1 | tail -n 20 >&2 || true
  fi
  exit "$rc"
}
trap diagnostics EXIT

# retry <attempts> <seconds between> <command...>
retry() {
  local n=$1 delay=$2 i
  shift 2
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    sleep "$delay"
  done
  return 1
}

# wait_for <timeout seconds> <what> <command...>: run until it succeeds.
wait_for() {
  local limit=$1 what=$2 waited=0 step=$poll
  shift 2
  [ "$step" -gt 0 ] || step=1
  until "$@"; do
    [ "$waited" -lt "$limit" ] || die "timed out after ${limit}s waiting for $what"
    sleep "$poll"
    waited=$((waited + step))
  done
}

# --- 0. the cluster ----------------------------------------------------------

k get namespace >/dev/null 2>&1 || die "cannot reach the cluster behind context '$ctx'"
k get crd clusterissuers.cert-manager.io >/dev/null 2>&1 ||
  die "cert-manager's ClusterIssuer CRD is missing on '$ctx': bring the cluster up first (Clusters workflow, action up)"

# --- 1. platform -------------------------------------------------------------

log "platform: admission policies (policies/admission)"
k apply -f "$root/policies/admission/" >/dev/null ||
  die "cannot apply the admission policies (ValidatingAdmissionPolicy needs Kubernetes 1.30 or newer)"

log "platform: cert-manager issuers"
issuer_args=()
if [ -n "${ACME_EMAIL:-}" ]; then
  issuer_args+=(--set "acme.email=$ACME_EMAIL" --set acme.staging.enabled=true --set acme.production.enabled=true)
fi
# The cert-manager webhook can take a moment to accept requests after it reports Ready.
retry 6 "$poll" h upgrade --install issuers "$root/charts/cluster-issuers" -n cert-manager \
  --wait --rollback-on-failure --timeout 5m ${issuer_args[@]+"${issuer_args[@]}"}

# --- 2. shared services: none yet (docs/deploying.md) ------------------------

# --- 3. the application ------------------------------------------------------

log "application: $release in $ns on $cloud ($env), host $host"
app_args=(-f "$root/charts/webapp/values-$values_cloud.yaml" -f "$root/charts/webapp/values-$env.yaml" --set "ingress.host=$host")
if [ -n "${IMAGE_TAG:-}" ]; then
  app_args+=(--set-string "image.tag=$IMAGE_TAG")
fi
if [ "$env" = dev ]; then
  # No domain needed: self-signed TLS, and requests carry the Host header.
  app_args+=(--set ingress.enabled=true --set ingress.tls.enabled=true --set ingress.tls.clusterIssuer=selfsigned)
fi
# Created and labelled first, so the policies and the restricted Pod Security
# Standard apply from the first pod (Helm's --create-namespace cannot label).
k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
k label namespace "$ns" --overwrite \
  policy.multi-cloud-k8s-helm.io/enforce=true \
  pod-security.kubernetes.io/enforce=restricted >/dev/null
h upgrade --install "$release" "$root/charts/webapp" -n "$ns" "${app_args[@]}" \
  --wait --rollback-on-failure --timeout 10m

# --- 4. validate -------------------------------------------------------------

log "validate: helm test"
h test "$release" -n "$ns" --timeout 5m

secret=$(k -n "$ns" get ingress -o jsonpath='{.items[0].spec.tls[0].secretName}')
[ -n "$secret" ] || die "the ingress in $ns has no TLS secret name"
cert_ready() {
  [ "$(k -n "$ns" get certificate "$secret" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]
}
cert_state="issued"
if [ "$env" = dev ]; then
  log "validate: waiting for cert-manager to issue the self-signed certificate"
  wait_for "$cert_timeout" "the certificate $secret to become Ready" cert_ready
else
  # Let's Encrypt can only issue once the DNS record points here, which is yours to create.
  cert_ready || cert_state="not issued yet (needs the DNS record)"
fi

hpa_state="none"
if [ "$env" = prod ]; then
  log "validate: waiting for the autoscaler to receive metrics"
  hpa=$(k -n "$ns" get hpa -o jsonpath='{.items[0].metadata.name}')
  [ -n "$hpa" ] || die "prod values should have created a HorizontalPodAutoscaler"
  hpa_has_metrics() {
    [ -n "$(k -n "$ns" get hpa "$hpa" -o jsonpath='{.status.currentMetrics[0].type}' 2>/dev/null)" ]
  }
  wait_for "$hpa_timeout" "the autoscaler to receive metrics (is metrics-server running?)" hpa_has_metrics
  hpa_state="receiving metrics"
fi

addr=""
smoke_state="skipped (SKIP_INGRESS_SMOKE)"
if [ "${SKIP_INGRESS_SMOKE:-0}" != 1 ]; then
  port=${INGRESS_HTTPS_PORT:-443}
  have_address() {
    if [ -n "${INGRESS_ADDRESS:-}" ]; then
      addr=$INGRESS_ADDRESS
    else
      addr=$(k -n ingress get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null) || addr=""
    fi
    [ -n "$addr" ]
  }
  log "validate: waiting for the ingress controller's address"
  wait_for "$lb_timeout" "the ingress controller (Service ingress/traefik) to get a load balancer address" have_address
  smoke_body=""
  smoke() {
    smoke_body=$(curl -fsSk --max-time 10 --connect-to "$host:443:$addr:$port" "https://$host/healthz")
  }
  log "validate: GET https://$host/healthz via $addr:$port"
  wait_for "$smoke_timeout" "https://$host/healthz to answer through $addr:$port" smoke
  smoke_state="answered: $smoke_body"
fi

log "done"

# --- summary -----------------------------------------------------------------

summary() {
  echo "### $cloud: $release ($env)"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| context | \`$ctx\` |"
  echo "| namespace | \`$ns\` |"
  echo "| host | \`$host\` |"
  echo "| helm test | passed |"
  echo "| certificate | $cert_state |"
  echo "| autoscaler | $hpa_state |"
  echo "| request through the ingress | $smoke_state |"
  if [ "$env" = prod ] && [ -n "$addr" ]; then
    echo
    echo "Create a DNS record for \`$host\` pointing at \`$addr\` (an A record for an IP, a CNAME for a name). Until it resolves, Let's Encrypt cannot issue the certificate and Traefik serves its default one."
  fi
  echo
  echo '```'
  h list -n "$ns" 2>&1 || true
  k -n "$ns" get pods,svc,ingress,hpa,pdb,certificate 2>&1 || true
  echo '```'
}

# To stdout, and to the job summary when running in GitHub Actions.
summary | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
