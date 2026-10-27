#!/usr/bin/env bash
# Offline tests for the Helm charts in charts/. Nothing here talks to a cluster:
# it lints and renders every cloud x environment combination and asserts on the
# manifests. Needs helm, jq and kubectl (kubectl only turns YAML into JSON).
# Run: scripts/test-charts.sh        (also run in CI, and by `make test`)
#
# What is proven here is that the charts render correctly. That they install and
# run is proven by scripts/test-charts-kind.sh.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
app=$root/charts/webapp
issuers=$root/charts/cluster-issuers
host=web.example.com
failures=0

pass() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1"
  [ -z "${2:-}" ] || printf '%s\n' "$2" | while IFS= read -r line; do printf '        %s\n' "$line"; done
  failures=$((failures + 1))
}

# render <helm template args...>: the manifests as one JSON array on stdout.
render() {
  local yaml
  yaml=$(helm template rel "$@") || return 1
  printf '%s\n' "$yaml" | KUBECONFIG=/dev/null kubectl label --local -f - -o json test.local/render=1 |
    jq -s 'map(if type == "object" and has("items") then .items[] else . end)'
}

# check <description> <json> <jq filter that must be true>
check() {
  if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then pass "$1"; else fail "$1" "jq: $3"; fi
}

# rejects <description> <message fragment> <helm template args...>
rejects() {
  local desc=$1 want=$2 out
  shift 2
  if out=$(helm template rel "$@" 2>&1); then
    fail "$desc" "rendered without an error"
  elif printf '%s' "$out" | grep -qF -- "$want"; then
    pass "$desc"
  else
    fail "$desc" "wanted '$want' in: $(printf '%s' "$out" | head -n 3)"
  fi
}

cloud_file() { echo "$app/values-$1.yaml"; }

echo "-- files"
if jq empty "$app/values.schema.json" 2>/dev/null; then pass "values.schema.json is valid JSON"; else fail "values.schema.json is valid JSON"; fi

echo "-- lint and render: every cloud x environment"
for cloud in "" eks aks gke; do
  for env in "" dev prod; do
    args=()
    [ -z "$cloud" ] || args+=(-f "$(cloud_file "$cloud")")
    [ -z "$env" ] || args+=(-f "$(cloud_file "$env")")
    label="${cloud:-base}+${env:-base}"
    # ${args[@]+...}: an empty array is an error under `set -u` in bash 3.2 (macOS).
    if out=$(helm lint --strict "$app" ${args[@]+"${args[@]}"} --set ingress.host=$host 2>&1) && render "$app" ${args[@]+"${args[@]}"} --set ingress.host=$host >/dev/null; then
      pass "lint and render: $label"
    else
      fail "lint and render: $label" "$out"
    fi
  done
done
if out=$(helm lint --strict "$issuers" 2>&1); then pass "lint: cluster-issuers"; else fail "lint: cluster-issuers" "$out"; fi

echo "-- portability: the clouds differ in values only"
hits=$(grep -rniwE 'eks|aks|gke|aws|amazonaws|azure|gcp|google' "$app/templates" "$issuers/templates" || true)
if [ -z "$hits" ]; then pass "templates name no cloud"; else fail "templates name no cloud" "$hits"; fi

for cloud in eks aks gke; do
  keys=$(grep -E '^[A-Za-z]' "$(cloud_file "$cloud")" | cut -d: -f1 | sort -u | tr '\n' ' ')
  bad=""
  for k in $keys; do
    case $k in nodeSelector | env | serviceAccount | podLabels | tolerations | affinity) ;; *) bad="$bad $k" ;; esac
  done
  if [ -z "$bad" ]; then pass "values-$cloud.yaml only sets placement, identity and labels"; else fail "values-$cloud.yaml only sets placement, identity and labels" "also sets:$bad (environment settings belong in values-dev/prod.yaml)"; fi
done

eks=$(render "$app" -f "$(cloud_file eks)")
aks=$(render "$app" -f "$(cloud_file aks)")
gke=$(render "$app" -f "$(cloud_file gke)")
objects() { printf '%s' "$1" | jq -c '[.[] | "\(.kind)/\(.metadata.name)"] | sort'; }
# The Deployment minus the two fields that legitimately differ.
core() { printf '%s' "$1" | jq -S -c '.[] | select(.kind == "Deployment") | del(.spec.template.spec.nodeSelector, .spec.template.spec.containers[].env)'; }
# same <description> <a> <b> <c>: all three values are equal
same() {
  if [ "$2" = "$3" ] && [ "$3" = "$4" ]; then pass "$1"; else fail "$1" "$(printf '%s\n%s\n%s' "$2" "$3" "$4")"; fi
}
same "the same objects are created on every cloud" "$(objects "$eks")" "$(objects "$aks")" "$(objects "$gke")"
same "the Deployment differs between clouds only in nodeSelector and env" "$(core "$eks")" "$(core "$aks")" "$(core "$gke")"
check "EKS selects the pool=default nodes" "$eks" '.[] | select(.kind == "Deployment") | .spec.template.spec.nodeSelector.pool == "default"'
check "GKE selects the pool=default nodes" "$gke" '.[] | select(.kind == "Deployment") | .spec.template.spec.nodeSelector.pool == "default"'
check "AKS selects the pool=user nodes" "$aks" '.[] | select(.kind == "Deployment") | .spec.template.spec.nodeSelector.pool == "user"'
for cloud in eks aks gke; do
  json=$(render "$app" -f "$(cloud_file $cloud)")
  check "$cloud: each cloud announces itself" "$json" '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].env | map(select(.name == "PODINFO_UI_MESSAGE")) | length == 1'
done

echo "-- security and good practice (every cloud x environment)"
for cloud in eks aks gke; do
  for env in "" dev prod; do
    json=$(render "$app" -f "$(cloud_file $cloud)" ${env:+-f "$(cloud_file $env)"} --set ingress.host=$host)
    label="$cloud+${env:-base}"
    check "$label: requests and limits on every container" "$json" '[.[] | select(.kind == "Deployment" or .kind == "Pod") | (.spec.template.spec // .spec).containers[] | .resources | (.requests.cpu and .requests.memory and .limits.cpu and .limits.memory)] | all'
    check "$label: startup, liveness and readiness probes" "$json" '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[] | (.startupProbe and .livenessProbe and .readinessProbe)'
    check "$label: non-root with a numeric user, seccomp on, no API token" "$json" '[.[] | select(.kind == "Deployment" or .kind == "Pod") | (.spec.template.spec // .spec) | (.securityContext.runAsNonRoot == true and (.securityContext.runAsUser | type) == "number" and .securityContext.seccompProfile.type == "RuntimeDefault" and .automountServiceAccountToken == false)] | all'
    check "$label: read-only root, no privilege escalation, all capabilities dropped" "$json" '[.[] | select(.kind == "Deployment" or .kind == "Pod") | (.spec.template.spec // .spec).containers[] | .securityContext | (.readOnlyRootFilesystem == true and .allowPrivilegeEscalation == false and .capabilities.drop == ["ALL"])] | all'
    check "$label: images carry a tag that is not latest" "$json" '[.[] | select(.kind == "Deployment" or .kind == "Pod") | (.spec.template.spec // .spec).containers[].image | (test(":[^:/]+$") and (endswith(":latest") | not))] | all'
  done
done

echo "-- environments"
base=$(render "$app")
check "base: 2 replicas, a disruption budget, no autoscaler, no ingress" "$base" '([.[]|select(.kind=="Deployment")|.spec.replicas] == [2]) and ([.[]|select(.kind=="PodDisruptionBudget")]|length==1) and ([.[]|select(.kind=="HorizontalPodAutoscaler" or .kind=="Ingress")]|length==0)'
dev=$(render "$app" -f "$(cloud_file dev)")
check "dev: 1 replica, no disruption budget, no autoscaler, no spreading" "$dev" '([.[]|select(.kind=="Deployment")|.spec.replicas] == [1]) and ([.[]|select(.kind=="PodDisruptionBudget" or .kind=="HorizontalPodAutoscaler")]|length==0) and ([.[]|select(.kind=="Deployment")|.spec.template.spec.topologySpreadConstraints]==[null])'
prod=$(render "$app" -f "$(cloud_file prod)" --set ingress.host=$host)
check "prod: the autoscaler owns the replica count" "$prod" '([.[]|select(.kind=="Deployment")|.spec|has("replicas")]==[false]) and ([.[]|select(.kind=="HorizontalPodAutoscaler")|.spec|[.minReplicas,.maxReplicas]]==[[3,10]])'
check "prod: at least 2 pods stay up during a drain" "$prod" '[.[]|select(.kind=="PodDisruptionBudget")|.spec.minAvailable]==[2]'
check "prod: HTTPS ingress on the traefik class with a certificate issuer" "$prod" '.[]|select(.kind=="Ingress")|(.spec.ingressClassName=="traefik") and (.spec.tls[0].hosts==["'$host'"]) and (.metadata.annotations["cert-manager.io/cluster-issuer"]=="letsencrypt-prod") and (.spec.rules[0].host=="'$host'") and (.spec.rules[0].http.paths[0].backend.service.port.name=="http")'
check "the ingress points at the Service, which exposes the named port" "$prod" '([.[]|select(.kind=="Ingress")|.spec.rules[0].http.paths[0].backend.service.name]==[.[]|select(.kind=="Service")|.metadata.name]) and ([.[]|select(.kind=="Service")|.spec.ports[0].name]==["http"])'

echo "-- guards"
rejects "ingress without a host is refused" "ingress.host is required" "$app" --set ingress.enabled=true
rejects "prod without a host is refused" "ingress.host is required" "$app" -f "$(cloud_file prod)"
rejects "a mistyped key is refused" "additional properties 'replicas' not allowed" "$app" --set replicas=3
rejects "the latest tag is refused" "/image/tag" "$app" --set image.tag=latest
rejects "missing limits are refused" "missing property 'limits'" "$app" --set resources.limits=null
rejects "autoscaling max below min is refused" "must not be lower" "$app" --set autoscaling.enabled=true --set autoscaling.minReplicas=5 --set autoscaling.maxReplicas=2
rejects "an unknown service type is refused" "must be one of" "$app" --set service.type=Bogus
rejects "an ACME issuer without an email is refused" "acme.email is required" "$issuers" --set acme.staging.enabled=true

echo "-- knobs"
check "the image tag defaults to the chart's appVersion" "$base" '[.[]|select(.kind=="Deployment")|.spec.template.spec.containers[0].image]==["ghcr.io/stefanprodan/podinfo:'"$(grep '^appVersion:' "$app/Chart.yaml" | cut -d'"' -f2)"'"]'
check "the image tag can be overridden" "$(render "$app" --set image.tag=1.2.3)" '[.[]|select(.kind=="Deployment")|.spec.template.spec.containers[0].image|endswith(":1.2.3")]==[true]'
check "a probe can be left out" "$(render "$app" --set probes.startup=null)" '[.[]|select(.kind=="Deployment")|.spec.template.spec.containers[0]|has("startupProbe")]==[false]'
secrets=$(render "$app" --set 'extraEnv[0].name=DB_PASSWORD' --set 'extraEnv[0].valueFrom.secretKeyRef.name=app-db' --set 'extraEnv[0].valueFrom.secretKeyRef.key=password' --set 'envFrom[0].secretRef.name=app-secrets')
check "secrets are referenced by name, next to the plain env entries" "$secrets" '.[]|select(.kind=="Deployment")|.spec.template.spec.containers[0]|(.env|map(.name)|index("PODINFO_LEVEL") != null) and (.env|map(select(.name=="DB_PASSWORD"))[0].valueFrom.secretKeyRef == {"name":"app-db","key":"password"}) and (.envFrom==[{"secretRef":{"name":"app-secrets"}}])'
check "the helm test pod is a test hook" "$base" '[.[]|select(.kind=="Pod")|.metadata.annotations["helm.sh/hook"]]==["test"]'
check "the helm test can be turned off" "$(render "$app" --set test.enabled=false)" '[.[]|select(.kind=="Pod")]|length==0'

echo "-- workload identity: the same chart carries each cloud's mechanism"
irsa=$(render "$app" --set-string 'serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::123456789012:role/app')
check "EKS (IRSA): role annotation lands on the service account" "$irsa" '.[]|select(.kind=="ServiceAccount")|.metadata.annotations["eks.amazonaws.com/role-arn"]=="arn:aws:iam::123456789012:role/app"'
azwi=$(render "$app" --set-string 'serviceAccount.annotations.azure\.workload\.identity/client-id=0000' --set-string 'podLabels.azure\.workload\.identity/use=true')
check "AKS: client-id annotation on the service account and use label on the pods" "$azwi" '(.[]|select(.kind=="ServiceAccount")|.metadata.annotations["azure.workload.identity/client-id"]=="0000") and (.[]|select(.kind=="Deployment")|.spec.template.metadata.labels["azure.workload.identity/use"]=="true")'
gkewi=$(render "$app" --set-string 'serviceAccount.annotations.iam\.gke\.io/gcp-service-account=app@proj.iam.gserviceaccount.com')
check "GKE: Google service account annotation lands on the service account" "$gkewi" '.[]|select(.kind=="ServiceAccount")|.metadata.annotations["iam.gke.io/gcp-service-account"]=="app@proj.iam.gserviceaccount.com"'
check "the service account is not mounted by default" "$irsa" '.[]|select(.kind=="ServiceAccount")|.automountServiceAccountToken==false'

echo "-- network policy and monitoring"
# shellcheck disable=SC2016 # the $ signs are jq variables
check "the Service does not select the helm test pod" "$base" '(.[]|select(.kind=="Service")|.spec.selector) as $sel | (.[]|select(.kind=="Pod")|.metadata.labels) as $l | ($sel|to_entries|all(. as $e | $l[$e.key] == $e.value)) | not'
check "the application is closed to all but the ingress controller and the helm test pod" "$base" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="rel-webapp")|(.spec.policyTypes==["Ingress"]) and (.spec.ingress[0].from|length==2) and (.spec.ingress[0].from[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]=="ingress") and (.spec.ingress[0].from[1].podSelector.matchLabels["app.kubernetes.io/component"]=="test") and (.spec.ingress[0].ports==[{"port":"http","protocol":"TCP"}])'
check "the application policy selects exactly the application pods" "$base" '(.[]|select(.kind=="NetworkPolicy" and .metadata.name=="rel-webapp")|.spec.podSelector.matchLabels) == (.[]|select(.kind=="Service")|.spec.selector)'
check "the helm test pod may only reach the application" "$base" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="rel-webapp-test")|(.spec.policyTypes==["Egress"]) and (.spec.egress|length==1) and (.spec.egress[0].to[0].podSelector.matchLabels["app.kubernetes.io/name"]=="webapp") and (.spec.egress[0].ports==[{"port":"http","protocol":"TCP"}])'
check "the ingress namespace is a value" "$(render "$app" --set networkPolicy.ingressNamespace=traefik)" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="rel-webapp")|.spec.ingress[0].from[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]=="traefik"'
check "the network policy can be turned off" "$(render "$app" --set networkPolicy.enabled=false)" '[.[]|select(.kind=="NetworkPolicy")]|length==0'
check "no helm test pod, no test policy" "$(render "$app" --set test.enabled=false)" '[.[]|select(.kind=="NetworkPolicy")|.metadata.name]==["rel-webapp"] and (.[]|select(.kind=="NetworkPolicy")|.spec.ingress[0].from|length==1)'
check "monitoring objects are off by default" "$base" '[.[]|select(.kind=="ServiceMonitor" or .kind=="PrometheusRule")]|length==0'
mon=$(render "$app" --set metrics.serviceMonitor.enabled=true --set metrics.rules.enabled=true)
check "Prometheus may reach the application once it is scraped" "$mon" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="rel-webapp")|.spec.ingress[0].from|map(.namespaceSelector.matchLabels["kubernetes.io/metadata.name"])|index("monitoring") != null'
# shellcheck disable=SC2016 # the $ signs are jq variables
check "the ServiceMonitor selects the Service and its named port" "$mon" '(.[]|select(.kind=="ServiceMonitor")) as $m | (.[]|select(.kind=="Service")) as $svc | ($m.spec.selector.matchLabels|to_entries|all(. as $e | $svc.metadata.labels[$e.key]==$e.value)) and ($m.spec.endpoints[0].port==$svc.spec.ports[0].name) and ($m.spec.endpoints[0].path=="/metrics")'
check "three alerts, scoped to this release's namespace and service" "$mon" '.[]|select(.kind=="PrometheusRule")|.spec.groups[0].rules|(map(.alert)==["WebappTargetDown","WebappHighErrorRate","WebappPodRestarting"]) and all(.expr|contains("namespace=\"default\""))'
check "the error-rate threshold is a value, in percent" "$(render "$app" --set metrics.rules.enabled=true --set metrics.rules.errorRatePercent=20)" '.[]|select(.kind=="PrometheusRule")|.spec.groups[0].rules[1].expr|contains("> 20")'
rejects "an error-rate above 100 percent is refused" "errorRatePercent" "$app" --set metrics.rules.errorRatePercent=150
rejects "a mistyped network policy key is refused" "additional properties" "$app" --set networkPolicy.ingressNamespaces=x

echo "-- cluster-issuers"
ci=$(render "$issuers")
check "default: one self-signed issuer, no ACME" "$ci" '([.[]|.kind]==["ClusterIssuer"]) and ([.[]|.metadata.name]==["selfsigned"]) and (.[0].spec.selfSigned=={})'
acme=$(render "$issuers" --set acme.email=ops@example.com --set acme.staging.enabled=true --set acme.production.enabled=true)
check "staging and production issuers use HTTP-01 through traefik" "$acme" '[.[]|select(.spec.acme)|{n:.metadata.name,s:.spec.acme.server,c:.spec.acme.solvers[0].http01.ingress.ingressClassName,e:.spec.acme.email}]|sort_by(.n)==[{"n":"letsencrypt-prod","s":"https://acme-v02.api.letsencrypt.org/directory","c":"traefik","e":"ops@example.com"},{"n":"letsencrypt-staging","s":"https://acme-staging-v02.api.letsencrypt.org/directory","c":"traefik","e":"ops@example.com"}]'
check "the issuer names match what values-prod.yaml references" "$acme" '[.[].metadata.name]|index("letsencrypt-prod") != null'

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
