#!/usr/bin/env bash
# Tests the admission policies in policies/admission, the quota and limit range in
# policies/namespace, and the Pod Security Standard that scripts/deploy.sh also
# enforces, on a THROWAWAY local cluster (kind, minikube...).
# It installs the policies, creates two namespaces, and deletes them again; never
# point it at a cluster that matters.
#
#   kind create cluster --name charts
#   KUBE_CONTEXT=kind-charts scripts/test-policies-kind.sh
#
# Everything is a server-side dry run: the real API server evaluates the real
# policies, but nothing is scheduled and no image is pulled.
#
# Needs helm, kubectl and jq.
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
k get namespace >/dev/null || die "cannot reach the cluster behind context '$ctx'"
[ -z "$(k get namespace ingress --ignore-not-found -o name)" ] || die "namespace 'ingress' exists: this looks like a platform cluster, refusing"

on=policy-on
lim=policy-limits
off=policy-off
failures=0
pass() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1"
  [ -z "${2:-}" ] || printf '%s\n' "$2" | while IFS= read -r line; do printf '        %s\n' "$line"; done
  failures=$((failures + 1))
}

cleanup() {
  k delete -f "$root/policies/admission/" --ignore-not-found >/dev/null 2>&1 || true
  k delete namespace "$on" "$lim" "$off" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- fixtures -----------------------------------------------------------------

good_image=ghcr.io/stefanprodan/podinfo:6.17.0

# pod <image>: a pod that complies with everything, running that image
pod() {
  jq -n --arg image "$1" '{
    apiVersion: "v1", kind: "Pod", metadata: {name: "probe"},
    spec: {
      securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: "RuntimeDefault"}},
      containers: [{
        name: "c", image: $image,
        resources: {requests: {cpu: "10m", memory: "16Mi"}, limits: {memory: "32Mi"}},
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
      }]
    }}'
}

# ingress: an ingress that complies with everything
ingress() {
  jq -n '{
    apiVersion: "networking.k8s.io/v1", kind: "Ingress", metadata: {name: "probe"},
    spec: {
      ingressClassName: "traefik",
      tls: [{hosts: ["a.example.test"], secretName: "probe-tls"}],
      rules: [{host: "a.example.test", http: {paths: [{path: "/", pathType: "Prefix",
        backend: {service: {name: "probe", port: {name: "http"}}}}]}}]
    }}'
}

# dry <namespace> <json>: server-side dry-run create; the output is left in $out
dry() { out=$(printf '%s' "$2" | k apply --dry-run=server -n "$1" -f - 2>&1); }

admitted() { # <description> <namespace> <json>
  if dry "$2" "$3"; then pass "$1"; else fail "$1" "$out"; fi
}
denied() { # <description> <text the refusal must contain> <namespace> <json>
  if dry "$3" "$4"; then
    fail "$1" "was admitted"
  elif printf '%s' "$out" | grep -qF -- "$2"; then
    pass "$1"
  else
    fail "$1" "refused, but not with '$2': $out"
  fi
}

# --- install -----------------------------------------------------------------

log "installing the policies"
k apply -f "$root/policies/admission/" >/dev/null
for ns in "$on" "$lim" "$off"; do k create namespace "$ns" >/dev/null; done
for ns in "$on" "$lim"; do
  k label namespace "$ns" policy.multi-cloud-k8s-helm.io/enforce=true pod-security.kubernetes.io/enforce=restricted >/dev/null
done
# The limit range refuses a pod with no memory request or limit BEFORE the CEL rules
# get to see it (it is an earlier admission step), which would hide the rules' own
# messages. So the rules are tested in a namespace with the quota and network
# policies but no limit range, and the limit range in one with everything.
k apply -n "$on" -f "$root/policies/namespace/resource-quota.yaml" -f "$root/policies/namespace/network.yaml" >/dev/null
k apply -n "$lim" -f "$root/policies/namespace/" >/dev/null

# A policy takes a moment to start enforcing: wait until a violation is refused.
log "waiting for the policies to be enforced"
bad=$(pod docker.io/library/nginx:latest)
enforced=""
for _ in $(seq 1 40); do
  if ! dry "$on" "$bad"; then
    enforced=1
    break
  fi
  sleep 2
done
[ -n "$enforced" ] || die "the policies were not enforced after 80 seconds; last output: $out"

# --- pods ---------------------------------------------------------------------

echo "-- pods"
admitted "a compliant pod is admitted" "$on" "$(pod "$good_image")"

no_resources=$(pod "$good_image" | jq 'del(.spec.containers[0].resources)')
denied "no resources is refused" "workloads-require-resources" "$on" "$no_resources"
denied "no memory limit is refused" "workloads-require-resources" "$on" "$(pod "$good_image" | jq '.spec.containers[0].resources.limits = {cpu: "100m"}')"
denied "no cpu request is refused" "workloads-require-resources" "$on" "$(pod "$good_image" | jq '.spec.containers[0].resources.requests = {memory: "16Mi"}')"
init_no_resources=$(pod "$good_image" | jq --arg image "$good_image" '.spec.initContainers = [{name: "i", image: $image, command: ["true"], securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}}]')
denied "an init container without resources is refused too" "workloads-require-resources" "$on" "$init_no_resources"

denied "the latest tag is refused" "workloads-pin-image-tags" "$on" "$(pod ghcr.io/stefanprodan/podinfo:latest)"
denied "an untagged image is refused" "workloads-pin-image-tags" "$on" "$(pod ghcr.io/stefanprodan/podinfo)"
admitted "an image pinned by digest is admitted" "$on" "$(pod "ghcr.io/stefanprodan/podinfo@sha256:$(printf '0%.0s' $(seq 1 64))")"

denied "an image from an unlisted registry is refused" "workloads-allowed-registries" "$on" "$(pod docker.io/library/nginx:1.27)"
admitted "an image from ECR is admitted" "$on" "$(pod 123456789012.dkr.ecr.us-east-1.amazonaws.com/app:1.0.0)"
admitted "an image from ACR is admitted" "$on" "$(pod myregistry.azurecr.io/app:1.0.0)"
admitted "an image from Artifact Registry is admitted" "$on" "$(pod us-central1-docker.pkg.dev/proj/repo/app:1.0.0)"

privileged=$(pod "$good_image" | jq '.spec.containers[0].securityContext = {privileged: true}')
denied "a privileged pod is refused by the Pod Security Standard" "PodSecurity" "$on" "$privileged"

echo "-- namespace quota and limit range (policies/namespace)"
sized() { # <cpu request> <memory request> <memory limit>: the compliant pod with that sizing
  pod "$good_image" | jq --arg cr "$1" --arg mr "$2" --arg ml "$3" '.spec.containers[0].resources = {requests: {cpu: $cr, memory: $mr}, limits: {memory: $ml}}'
}
admitted "a modestly sized pod is admitted" "$on" "$(sized 100m 128Mi 256Mi)"
admitted "and in the namespace that also has the limit range" "$lim" "$(sized 100m 128Mi 256Mi)"
# 16Mi requested and 256Mi allowed is a ratio of 16; the limit range allows 4.
denied "a limit far above the request is refused by the limit range" "limit to request ratio" "$lim" "$(sized 100m 16Mi 256Mi)"
admitted "the same pod is admitted where there is no limit range" "$on" "$(sized 100m 16Mi 256Mi)"
# The limit range must not fill in what a pod left out: that would defeat the
# policy requiring pods to declare their resources. With min/max in the limit range
# this pod was ADMITTED, with a 2Gi limit it never asked for. Any refusal will do here.
denied "a pod that declares nothing is refused, not given defaults" "Forbidden" "$lim" "$(pod "$good_image" | jq 'del(.spec.containers[0].resources)')"
# Three containers of 1500Mi are each within the limit range, but 4.5Gi in total
# is over the namespace's 4Gi of requested memory.
over_quota=$(pod "$good_image" | jq --arg image "$good_image" '.spec.containers = [range(3) as $i | {
  name: "c\($i)", image: $image,
  resources: {requests: {cpu: "10m", memory: "1500Mi"}, limits: {memory: "1500Mi"}},
  securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}}]')
denied "a pod that would exceed the namespace's memory quota is refused" "exceeded quota: workload-quota" "$on" "$over_quota"
admitted "the same pod is admitted in a namespace with no quota" "$off" "$over_quota"

echo "-- scope"
admitted "the same violations are admitted in a namespace that is not labelled" "$off" "$bad"
solver=$(pod quay.io/jetstack/cert-manager-acmesolver:v1.21.3 | jq 'del(.spec.containers[0].resources) | .metadata.labels = {"acme.cert-manager.io/http01-solver": "true"}')
admitted "cert-manager's challenge pods are exempt from the workload policies" "$on" "$solver"
denied "the exemption is only for the label, not for the image" "workloads-" "$on" "$(printf '%s' "$solver" | jq 'del(.metadata.labels)')"

# --- ingresses ----------------------------------------------------------------

echo "-- ingresses"
admitted "a compliant ingress is admitted" "$on" "$(ingress)"
denied "no ingress class is refused" "ingress-requires-class-and-tls" "$on" "$(ingress | jq 'del(.spec.ingressClassName)')"
denied "another ingress class is refused" "ingress-requires-class-and-tls" "$on" "$(ingress | jq '.spec.ingressClassName = "nginx"')"
denied "an ingress without TLS is refused" "ingress-requires-class-and-tls" "$on" "$(ingress | jq 'del(.spec.tls)')"
admitted "an ingress without TLS is admitted in an unlabelled namespace" "$off" "$(ingress | jq 'del(.spec.tls)')"
admitted "cert-manager's challenge ingress (plain HTTP) is exempt" "$on" "$(ingress | jq 'del(.spec.tls) | .metadata.labels = {"acme.cert-manager.io/http01-solver": "true"}')"

# --- the charts, against the policies ------------------------------------------

echo "-- every pod and ingress the charts render"
for cloud in eks aks gke; do
  for env in dev prod; do
    json=$(helm template rel "$app" -f "$app/values-$cloud.yaml" -f "$app/values-$env.yaml" --set ingress.host=web.example.test |
      KUBECONFIG=/dev/null kubectl label --local -f - -o json test.local/render=1 |
      jq -s 'map(if type == "object" and has("items") then .items[] else . end)')
    # The Deployment's pod template as a Pod. The service account does not exist
    # in this namespace, and a dry-run pod would be refused for that alone.
    workload=$(printf '%s' "$json" | jq '.[] | select(.kind == "Deployment") |
      {apiVersion: "v1", kind: "Pod", metadata: {name: "probe", labels: .spec.template.metadata.labels},
       spec: (.spec.template.spec | del(.serviceAccountName))}')
    admitted "$cloud + $env: the application pod is admitted" "$on" "$workload"
    helm_test=$(printf '%s' "$json" | jq '.[] | select(.kind == "Pod") | .metadata.name = "probe"')
    admitted "$cloud + $env: the helm test pod is admitted" "$on" "$helm_test"
  done
done
prod_ingress=$(helm template rel "$app" -f "$app/values-prod.yaml" --set ingress.host=web.example.test --show-only templates/ingress.yaml |
  KUBECONFIG=/dev/null kubectl label --local -f - -o json test.local/render=1)
admitted "the production ingress is admitted" "$on" "$prod_ingress"

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
