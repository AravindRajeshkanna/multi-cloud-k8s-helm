#!/usr/bin/env bash
# Tests the optional monitoring stack on a THROWAWAY local cluster: installs it
# from the same values file Terraform uses (infra/modules/core-addons/
# monitoring-values.yaml), deploys the webapp with scraping and alerts on, and asks
# Prometheus itself whether it is scraping the app and has loaded the alert rules.
# Never point it at a cluster that matters.
#
#   scripts/kind-cluster.sh monitoring cilium
#   KUBE_CONTEXT=kind-monitoring scripts/test-monitoring-kind.sh
#
# Run it on a cluster whose network plugin enforces NetworkPolicy (cilium) to prove
# Prometheus can reach the application through the chart's network policy.
#
# Needs helm, kubectl and jq.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
app=$root/charts/webapp
values=$root/infra/modules/core-addons/monitoring-values.yaml

log() { echo "==> $*" >&2; }
die() {
  echo "error: $*" >&2
  exit 1
}

ctx=${KUBE_CONTEXT:-}
[ -n "$ctx" ] || die "set KUBE_CONTEXT to the context of a throwaway cluster, for example kind-monitoring"
case $ctx in
  mc-*) die "refusing to run on '$ctx': that is one of the platform clusters" ;;
esac
k() { kubectl --context "$ctx" "$@"; }
h() { helm --kube-context "$ctx" "$@"; }
k get namespace >/dev/null || die "cannot reach the cluster behind context '$ctx'"
[ -z "$(k get namespace ingress --ignore-not-found -o name)" ] || die "namespace 'ingress' exists: this looks like a platform cluster, refusing"

# default of a Terraform variable
tf_default() {
  awk -v v="$1" '$0 ~ "variable \"" v "\"" { f = 1 } f && /^[ \t]*default[ \t]*=/ { gsub(/"/, "", $3); print $3; exit }' \
    "$root/infra/modules/core-addons/variables.tf"
}
chart_version=$(tf_default monitoring_chart_version)
[ -n "$chart_version" ] || die "cannot read monitoring_chart_version from infra/modules/core-addons/variables.tf"

ns=web-mon
failures=0
pass() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1"
  [ -z "${2:-}" ] || printf '%s\n' "$2" | while IFS= read -r line; do printf '        %s\n' "$line"; done
  failures=$((failures + 1))
}

cleanup() {
  h uninstall web -n "$ns" >/dev/null 2>&1 || true
  h uninstall monitoring -n monitoring >/dev/null 2>&1 || true
  k delete namespace "$ns" monitoring --ignore-not-found --wait=false >/dev/null 2>&1 || true
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

# prom <path and query>: Prometheus's HTTP API, through the API server's service proxy
prom() { k get --raw "/api/v1/namespaces/monitoring/services/http:monitoring-kube-prometheus-prometheus:9090/proxy/$1"; }
# query <PromQL>: the result vector as JSON
query() { prom "api/v1/query?query=$(jq -rn --arg q "$1" '$q | @uri')"; }

log "kube-prometheus-stack $chart_version, with the values Terraform uses"
h upgrade --install monitoring kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts \
  --version "$chart_version" -n monitoring --create-namespace -f "$values" --wait --timeout 10m

log "the webapp, with scraping and alerts on, in a namespace set up as scripts/deploy.sh does"
k create namespace "$ns" >/dev/null
k label namespace "$ns" policy.multi-cloud-k8s-helm.io/enforce=true pod-security.kubernetes.io/enforce=restricted >/dev/null
k apply -n "$ns" -f "$root/policies/namespace/" >/dev/null
h upgrade --install web "$app" -n "$ns" -f "$app/values-dev.yaml" \
  --set metrics.serviceMonitor.enabled=true --set metrics.rules.enabled=true --wait --timeout 5m

echo "-- the stack"
if [ -z "$(k get alertmanagers -A -o name 2>/dev/null)" ]; then pass "no Alertmanager is running"; else fail "no Alertmanager is running"; fi
pw=$(k -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
if [ "${#pw}" -ge 16 ] && [ "$pw" != "prom-operator" ]; then pass "Grafana's admin password is generated, not a well-known one"; else fail "Grafana's admin password is generated, not a well-known one"; fi
if k get --raw "/api/v1/namespaces/monitoring/services/http:monitoring-grafana:80/proxy/api/health" | jq -e '.database == "ok"' >/dev/null 2>&1; then pass "Grafana is healthy"; else fail "Grafana is healthy"; fi
if [ -z "$(k -n monitoring get svc -o jsonpath='{range .items[*]}{.spec.type}{"\n"}{end}' | grep -E 'LoadBalancer|NodePort' || true)" ]; then pass "nothing is exposed outside the cluster"; else fail "nothing is exposed outside the cluster"; fi
for sm in kubelet kube-state-metrics node-exporter; do
  if k -n monitoring get servicemonitors -o name | grep -q "$sm"; then pass "the stack monitors $sm"; else fail "the stack monitors $sm"; fi
done
for gone in kube-etcd kube-scheduler kube-controller-manager kube-proxy; do
  if k -n monitoring get servicemonitors -o name | grep -q "$gone"; then fail "$gone is not monitored (a managed control plane cannot be scraped)"; else pass "$gone is not monitored (a managed control plane cannot be scraped)"; fi
done

echo "-- the application"
scraped() { query "up{namespace=\"$ns\",service=\"web-webapp\"}" | jq -e '.data.result | length > 0 and all(.value[1] == "1")' >/dev/null 2>&1; }
if retry 36 5 scraped; then pass "Prometheus scrapes the application and the target is up"; else fail "Prometheus scrapes the application and the target is up" "$(query "up{namespace=\"$ns\"}" 2>&1 | head -c 600)"; fi

# The app exports http_requests_total, so the series exists once it has served a request.
has_metrics() { query "http_requests_total{namespace=\"$ns\",service=\"web-webapp\"}" | jq -e '.data.result | length > 0' >/dev/null 2>&1; }
if retry 24 5 has_metrics; then pass "the application's own metrics (http_requests_total) arrive"; else fail "the application's own metrics (http_requests_total) arrive"; fi

rules_ok() {
  prom "api/v1/rules" | jq -e --arg g web-webapp '
    [.data.groups[] | select(.name == $g) | .rules[] | select(.type == "alerting")] as $r
    | ($r | map(.name) | sort) == ["WebappHighErrorRate", "WebappPodRestarting", "WebappTargetDown"]
      and ($r | all(.health == "ok"))' >/dev/null 2>&1
}
if retry 24 5 rules_ok; then pass "the three alert rules are loaded and evaluate without error"; else fail "the three alert rules are loaded and evaluate without error" "$(prom api/v1/rules 2>&1 | jq -c '[.data.groups[] | select(.name == "web-webapp")]' 2>&1 | head -c 800)"; fi
if query 'ALERTS{alertstate="firing",alertname=~"Webapp.*"}' | jq -e '.data.result | length == 0' >/dev/null 2>&1; then pass "none of the application's alerts is firing"; else fail "none of the application's alerts is firing"; fi

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
