#!/usr/bin/env bash
# Tests the network rules (policies/namespace/network.yaml and the webapp chart's
# NetworkPolicy) with real pods on a THROWAWAY local cluster. Never point it at a
# cluster that matters.
#
#   scripts/kind-cluster.sh netpol cilium
#   NETWORK_POLICY=enforced KUBE_CONTEXT=kind-netpol scripts/test-network-kind.sh
#
# NetworkPolicy is only a request: whether anything happens depends on the
# cluster's network plugin. NETWORK_POLICY says what this cluster is expected to
# do (enforced or ignored), and the test asserts that the observed behaviour
# matches, so a plugin that silently failed to install makes an "enforced" run fail
# instead of passing without proving anything. (This is how CI found that kind's
# default plugin does enforce policy: a run declared "ignored" and traffic was
# blocked.)
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
[ -n "$ctx" ] || die "set KUBE_CONTEXT to the context of a throwaway cluster, for example kind-netpol"
case $ctx in
  mc-*) die "refusing to run on '$ctx': that is one of the platform clusters" ;;
esac
expect=${NETWORK_POLICY:-}
case $expect in enforced | ignored) ;; *) die "set NETWORK_POLICY to enforced or ignored" ;; esac
k() { kubectl --context "$ctx" "$@"; }
h() { helm --kube-context "$ctx" "$@"; }
k get namespace >/dev/null || die "cannot reach the cluster behind context '$ctx'"
[ -z "$(k get namespace ingress --ignore-not-found -o name)" ] || die "namespace 'ingress' exists: this looks like a platform cluster, refusing"

# Namespaces: the application's (set up like scripts/deploy.sh does), one that plays
# the ingress controller, one that is just somewhere else, and one hosting a control
# target that has no network policies at all.
srv=np-server ing=np-ingress other=np-other
failures=0
pass() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1"
  [ -z "${2:-}" ] || printf '%s\n' "$2" | while IFS= read -r line; do printf '        %s\n' "$line"; done
  failures=$((failures + 1))
}

cleanup() {
  h uninstall web -n "$srv" >/dev/null 2>&1 || true
  h uninstall control -n "$other" >/dev/null 2>&1 || true
  k delete namespace "$srv" "$ing" "$other" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "namespaces"
for ns in "$srv" "$ing" "$other"; do k create namespace "$ns" >/dev/null; done
k label namespace "$srv" policy.multi-cloud-k8s-helm.io/enforce=true pod-security.kubernetes.io/enforce=restricted >/dev/null
k apply -n "$srv" -f "$root/policies/namespace/" >/dev/null

log "the application (chart network policy on) and a control target with none"
h upgrade --install web "$app" -n "$srv" -f "$app/values-dev.yaml" --set networkPolicy.ingressNamespace="$ing" --wait --timeout 5m
h upgrade --install control "$app" -n "$other" -f "$app/values-dev.yaml" --set networkPolicy.enabled=false --wait --timeout 5m

# client <namespace>: a pod that complies with the admission rules and just waits;
# the application's own image is used because it has curl and nslookup.
client() {
  jq -n --arg image "ghcr.io/stefanprodan/podinfo:$(awk -F'"' '/^appVersion:/ { print $2 }' "$app/Chart.yaml")" '{
    apiVersion: "v1", kind: "Pod", metadata: {name: "client"},
    spec: {
      securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: "RuntimeDefault"}},
      containers: [{
        name: "c", image: $image, command: ["sleep", "3600"],
        resources: {requests: {cpu: "10m", memory: "16Mi"}, limits: {memory: "64Mi"}},
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
      }]
    }}' | k apply -n "$1" -f - >/dev/null
}
log "client pods"
for ns in "$srv" "$ing" "$other"; do client "$ns"; done
for ns in "$srv" "$ing" "$other"; do k -n "$ns" wait --for=condition=Ready pod/client --timeout=3m >/dev/null; done

# reaches <namespace> <pod or deploy/name> <url>: can that pod fetch the URL?
reaches() { k -n "$1" exec "$2" -- curl -fsS --max-time 4 -o /dev/null "$3" 2>/dev/null; }

# allowed <description> <namespace> <pod> <url>: must work whatever the plugin does
allowed() {
  if reaches "$2" "$3" "$4"; then pass "$1"; else fail "$1" "could not reach $4 from $2/$3"; fi
}
# closed <description> <namespace> <pod> <url>: refused when enforced, open when ignored
closed() {
  if reaches "$2" "$3" "$4"; then
    if [ "$expect" = ignored ]; then pass "$1 (not enforced here, as expected)"; else fail "$1" "reached $4 from $2/$3, but the policy should block it"; fi
  else
    if [ "$expect" = enforced ]; then pass "$1"; else fail "$1" "blocked, but this cluster was expected to ignore NetworkPolicy"; fi
  fi
}

web=http://web-webapp.$srv.svc/healthz
target=http://control-webapp.$other.svc/healthz

echo "-- the application"
allowed "the control target is reachable (so a blocked result below means something)" "$ing" client "$target"
allowed "the ingress controller's namespace reaches the application" "$ing" client "$web"
closed "another namespace does not" "$other" client "$web"
closed "nor does a pod in the application's own namespace" "$srv" client "$web"
if h test web -n "$srv" --timeout 3m >/dev/null; then pass "helm test reaches the application through its own policy"; else fail "helm test reaches the application through its own policy"; fi

echo "-- egress"
closed "the application cannot reach out to other namespaces" "$srv" deploy/web-webapp "$target"
closed "a pod in the application's namespace cannot reach out either" "$srv" client "$target"
# A fully qualified name: busybox's nslookup does not apply the search domains.
if k -n "$srv" exec deploy/web-webapp -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then pass "name resolution still works"; else fail "name resolution still works"; fi

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
