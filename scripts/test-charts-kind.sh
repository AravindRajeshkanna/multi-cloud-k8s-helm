#!/usr/bin/env bash
# End-to-end test of the charts on a THROWAWAY local cluster (kind, minikube...).
# It installs real software and deletes what it installs; never point it at a
# cluster that matters.
#
#   kind create cluster --name charts
#   KUBE_CONTEXT=kind-charts scripts/test-charts-kind.sh
#
# What it proves that scripts/test-charts.sh cannot: the API server accepts the
# manifests, the pods start and pass their probes under the hardened security
# context, `helm test` passes, an upgrade from dev to prod values works, cert-manager
# issues the certificate, and Traefik routes a request to the app. The application
# namespaces enforce the admission policies in policies/admission, the restricted
# Pod Security Standard, and the quota and network rules in policies/namespace, as
# on the real clusters, so every install is also a policy test. It ends by running scripts/deploy.sh, the script the workflows use,
# against the cluster.
# CI runs it on a fresh kind cluster. On a machine where the node's address is
# not reachable from the host (Docker Desktop), set SKIP_INGRESS_SMOKE=1.
#
# Needs helm and kubectl. The cert-manager and Traefik versions are the ones
# Terraform installs (infra/modules/core-addons/variables.tf).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
app=$root/charts/webapp

log() { echo "==> $*" >&2; }
die() {
  echo "error: $*" >&2
  exit 1
}

ctx=${KUBE_CONTEXT:-}
[ -n "$ctx" ] || die "set KUBE_CONTEXT to the context of a throwaway cluster, for example kind-charts"
case $ctx in
  mc-*) die "refusing to run on '$ctx': that is one of the platform clusters" ;;
esac
k() { kubectl --context "$ctx" "$@"; }
h() { helm --kube-context "$ctx" "$@"; }

k get namespace >/dev/null || die "cannot reach the cluster behind context '$ctx'"
# Phase 1 creates this namespace; a throwaway cluster does not have it.
[ -z "$(k get namespace ingress --ignore-not-found -o name)" ] || die "namespace 'ingress' exists: this looks like a platform cluster, refusing"

# default of a Terraform variable
tf_default() {
  awk -v v="$1" '$0 ~ "variable \"" v "\"" { f = 1 } f && /^[ \t]*default[ \t]*=/ { gsub(/"/, "", $3); print $3; exit }' \
    "$root/infra/modules/core-addons/variables.tf"
}
cert_manager_version=$(tf_default cert_manager_chart_version)
traefik_version=$(tf_default traefik_chart_version)
if [ -z "$cert_manager_version" ] || [ -z "$traefik_version" ]; then
  die "cannot read the chart versions from infra/modules/core-addons/variables.tf"
fi

namespaces="cert-manager traefik-test web-eks web-aks web-gke web-prod web-dev web-http"
cleanup() {
  log "cleaning up"
  for ns in web-eks web-aks web-gke web-prod web-dev web-http; do h uninstall web -n "$ns" >/dev/null 2>&1 || true; done
  h uninstall issuers -n cert-manager >/dev/null 2>&1 || true
  h uninstall traefik -n traefik-test >/dev/null 2>&1 || true
  k delete -f "$root/policies/admission/" --ignore-not-found >/dev/null 2>&1 || true
  h uninstall cert-manager -n cert-manager >/dev/null 2>&1 || true
  # shellcheck disable=SC2086 # the list is words on purpose
  k delete namespace $namespaces --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

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

log "cert-manager $cert_manager_version"
h upgrade --install cert-manager cert-manager --repo https://charts.jetstack.io --version "$cert_manager_version" \
  -n cert-manager --create-namespace --set crds.enabled=true --wait --timeout 5m

log "cluster-issuers"
# The webhook can take a moment to start accepting requests after it reports Ready.
retry 6 10 h upgrade --install issuers "$root/charts/cluster-issuers" -n cert-manager --wait
k wait --for=condition=Ready clusterissuer/selfsigned --timeout=120s

log "admission policies (policies/admission)"
k apply -f "$root/policies/admission/" >/dev/null

# prepare_ns <namespace>: create it and set it up the way scripts/deploy.sh does:
# labelled so the policies and the restricted Pod Security Standard apply from the
# first pod, with the quota, limit range and network rules in place.
prepare_ns() {
  k create namespace "$1" --dry-run=client -o yaml | k apply -f - >/dev/null
  k label namespace "$1" --overwrite \
    policy.multi-cloud-k8s-helm.io/enforce=true \
    pod-security.kubernetes.io/enforce=restricted >/dev/null
  k apply -n "$1" -f "$root/policies/namespace/" >/dev/null
}

log "Traefik $traefik_version (the ingress controller Phase 1 installs)"
h upgrade --install traefik traefik --repo https://traefik.github.io/charts --version "$traefik_version" \
  -n traefik-test --create-namespace --set service.type=NodePort --set deployment.replicas=1 --wait --timeout 5m
[ -n "$(k get ingressclass traefik --ignore-not-found -o name)" ] || die "Traefik did not create the 'traefik' IngressClass the chart relies on"

# --- every cloud's values file, on a node labelled the way that cloud's nodes are
for cloud in eks aks gke; do
  pool=default
  [ "$cloud" != aks ] || pool=user
  ns=web-$cloud
  log "webapp with values-$cloud.yaml (node label pool=$pool)"
  k label nodes --all "pool=$pool" --overwrite >/dev/null
  prepare_ns "$ns"
  h upgrade --install web "$app" -n "$ns" --create-namespace -f "$app/values-$cloud.yaml" -f "$app/values-dev.yaml" \
    --set networkPolicy.ingressNamespace=traefik-test --wait --timeout 5m
  h test web -n "$ns" --timeout 5m
  ready=$(k -n "$ns" get deploy -o jsonpath='{.items[0].status.readyReplicas}')
  [ "$ready" = 1 ] || die "$cloud: expected 1 ready replica, got '${ready:-0}'"
  h uninstall web -n "$ns" --wait
done

# --- prod: upgrade from dev, with TLS from cert-manager and routing by Traefik
ns=web-prod
host=web.example.test
image=ghcr.io/stefanprodan/podinfo:$(awk -F'"' '/^appVersion:/ { print $2 }' "$app/Chart.yaml")
traefik_ip=$(k -n traefik-test get svc traefik -o jsonpath='{.spec.clusterIP}')
# probe <curl args...>: run curl inside the cluster, from the app's own image.
# In the Traefik namespace, which does not enforce the workload policies: this
# throwaway pod sets no resources or security context.
probe() {
  k -n traefik-test run ingress-probe --rm -i --restart=Never --quiet --image="$image" --command -- \
    curl -fsS --max-time 5 -H "Host: $host" "$@"
}

# Plain HTTP is refused in the enforcing namespaces (the ingress policy demands
# TLS), so this one check of Traefik's HTTP routing uses a namespace that does not enforce.
log "webapp: a plain-HTTP ingress, in a namespace that does not enforce the policies"
k label nodes --all pool=default --overwrite >/dev/null
h upgrade --install web "$app" -n web-http --create-namespace -f "$app/values-dev.yaml" \
  --set networkPolicy.ingressNamespace=traefik-test \
  --set ingress.enabled=true --set ingress.host=$host --wait --timeout 5m
log "routing an HTTP request through Traefik (Host: $host)"
retry 10 3 probe "http://$traefik_ip/healthz" >/dev/null || die "Traefik did not route http://$host/healthz to the app"
h uninstall web -n web-http --wait

log "webapp in the enforcing namespace: dev values, then an upgrade to prod values"
prepare_ns "$ns"
h upgrade --install web "$app" -n "$ns" --create-namespace -f "$app/values-dev.yaml" \
  --set networkPolicy.ingressNamespace=traefik-test --wait --timeout 5m
h upgrade web "$app" -n "$ns" -f "$app/values-prod.yaml" --set networkPolicy.ingressNamespace=traefik-test \
  --set ingress.host=$host --set ingress.tls.clusterIssuer=selfsigned --wait --timeout 5m
for kind in hpa pdb ingress; do
  [ -n "$(k -n "$ns" get "$kind" -o name)" ] || die "prod values should have created a $kind"
done

log "waiting for cert-manager to issue the certificate"
retry 20 3 k -n "$ns" get certificate web-webapp-tls >/dev/null 2>&1 || die "cert-manager never created the Certificate for the ingress"
k -n "$ns" wait --for=condition=Ready certificate/web-webapp-tls --timeout=120s
[ -n "$(k -n "$ns" get secret web-webapp-tls -o jsonpath='{.data.tls\.crt}')" ] || die "the TLS secret is empty"

log "routing an HTTPS request through Traefik (Host: $host)"
retry 5 3 probe -k --resolve "$host:443:$traefik_ip" "https://$host/healthz" >/dev/null || die "Traefik did not serve https://$host/healthz"
h test web -n "$ns" --timeout 5m

log "downgrade to dev values removes the prod-only objects"
h upgrade web "$app" -n "$ns" -f "$app/values-dev.yaml" --wait --timeout 5m
for kind in hpa pdb ingress; do
  [ -z "$(k -n "$ns" get "$kind" -o name)" ] || die "the $kind should be gone after going back to dev values"
done

# --- the deploy script, as the workflows run it
log "scripts/deploy.sh aws dev (the Deploy workflow's script)"
k label nodes --all pool=default --overwrite >/dev/null
node_ip=$(k get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
https_port=$(k -n traefik-test get svc traefik -o jsonpath='{.spec.ports[?(@.name=="websecure")].nodePort}')
if [ -z "$node_ip" ] || [ -z "$https_port" ]; then
  die "cannot find the node address and Traefik's HTTPS node port"
fi
KUBE_CONTEXT=$ctx INGRESS_NAMESPACE=traefik-test INGRESS_ADDRESS=$node_ip INGRESS_HTTPS_PORT=$https_port "$here/deploy.sh" aws dev

log "all chart tests passed"
