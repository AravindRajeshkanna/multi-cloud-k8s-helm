#!/usr/bin/env bash
# Offline tests for scripts/deploy.sh. helm, kubectl and curl are replaced with
# stubs, so no cluster, credentials or network are needed.
# Run: scripts/test-deploy.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/deploy.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
export STUB_LOG="$work/calls.log"
export PATH="$work/bin:$PATH"
export POLL_INTERVAL=0 LB_TIMEOUT=1 SMOKE_TIMEOUT=1 CERT_TIMEOUT=1 HPA_TIMEOUT=1

# Stubs answer from STUB_* environment variables.
cat >"$work/bin/helm" <<'EOF'
#!/usr/bin/env bash
echo "helm $*" >>"$STUB_LOG"
case "$*" in
  *" test "*) [ -z "${STUB_HELM_TEST_FAIL:-}" ] || { echo "pod failed" >&2; exit 1; } ;;
esac
EOF
cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
case "$*" in
  *"get namespace"*) [ -z "${STUB_UNREACHABLE:-}" ] || exit 1 ;;
  *"get crd"*) [ -z "${STUB_NO_CERT_MANAGER:-}" ] || exit 1 ;;
  *"get ingress"*secretName*) printf 'web-webapp-tls' ;;
  *"get certificate"*) printf '%s' "${STUB_CERT_READY-True}" ;;
  *"get hpa"*metadata.name*) printf 'web-webapp' ;;
  *"get hpa"*currentMetrics*) printf '%s' "${STUB_HPA_METRICS-Resource}" ;;
  *"-n ingress get svc traefik"*) printf '%s' "${STUB_LB-203.0.113.50}" ;;
esac
EOF
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$STUB_LOG"
[ -z "${STUB_CURL_FAIL:-}" ] || { echo "connection refused" >&2; exit 7; }
printf '{"status":"OK"}'
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
    printf '%s\n' "$out" | tail -n 8 | while IFS= read -r line; do printf '        %s\n' "$line"; done
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

called_re() { # <description> <regex>   checks the stub call log, as an extended regex
  if grep -qE -- "$2" "$STUB_LOG"; then echo "ok    $1"; else
    echo "FAIL  $1 (no call matches: $2)"
    failures=$((failures + 1))
  fi
}
# Every helm / kubectl call must name the cluster explicitly.
always_explicit_context() {
  local bare
  bare=$(grep -E '^(helm|kubectl) ' "$STUB_LOG" | grep -vE '^helm --kube-context |^kubectl --context ' || true)
  if [ -z "$bare" ]; then echo "ok    $1"; else
    echo "FAIL  $1"
    printf '%s\n' "$bare" | while IFS= read -r line; do printf '        %s\n' "$line"; done
    failures=$((failures + 1))
  fi
}

echo "-- dev"
expect "dev on aws succeeds" 0 env KUBE_CONTEXT=mc-eks "$script" aws dev
called "  helm selects the cluster by context" "helm --kube-context mc-eks"
always_explicit_context "  no helm or kubectl call relies on the current context"
called "  issuers go to the cert-manager namespace" "upgrade --install issuers"
not_called "  no Let's Encrypt issuers without an email" "acme.email"
called "  app goes to web-dev" "-n web-dev --create-namespace"
called_re "  cloud values first, then environment values (later files win)" 'values-eks\.yaml .*-f .*values-dev\.yaml'
called "  host from cloud, environment and domain" "ingress.host=web-dev.aws.example.test"
called "  dev gets self-signed TLS" "ingress.tls.clusterIssuer=selfsigned"
called_re "  the app is rolled back if it fails to install" 'upgrade --install web .*--rollback-on-failure'
called_re "  and waits for it to be ready" 'upgrade --install web .*--wait'
called_re "  the issuers are too" 'upgrade --install issuers .*--rollback-on-failure'
called "  runs helm test" "test web -n web-dev"
called "  the request carries the host name and goes to the load balancer" "--connect-to web-dev.aws.example.test:443:203.0.113.50:443 https://web-dev.aws.example.test/healthz"
contains "  summary says what answered" 'answered: {"status":"OK"}'
contains "  summary names the context" "\`mc-eks\`"
summary_file=$work/summary.md
expect "the summary is also written to the job summary file" 0 env KUBE_CONTEXT=mc-eks GITHUB_STEP_SUMMARY="$summary_file" "$script" aws dev
if grep -qF 'answered: {"status":"OK"}' "$summary_file"; then echo "ok    job summary has the result"; else echo "FAIL  job summary has the result"; failures=$((failures + 1)); fi
expect "azure uses the AKS values" 0 env KUBE_CONTEXT=mc-aks "$script" azure dev
called "  values-aks.yaml" "values-aks.yaml"
called "  host has the cloud in it" "web-dev.azure.example.test"
expect "gcp uses the GKE values" 0 env KUBE_CONTEXT=mc-gke "$script" gcp dev
called "  values-gke.yaml" "values-gke.yaml"
expect "ingress address and port can be given" 0 env KUBE_CONTEXT=mc-eks INGRESS_ADDRESS=10.0.0.5 INGRESS_HTTPS_PORT=30443 "$script" aws dev
called "  uses them" "--connect-to web-dev.aws.example.test:443:10.0.0.5:30443"
not_called "  without asking for a load balancer" "get svc traefik"
expect "a custom domain is used" 0 env KUBE_CONTEXT=mc-eks APP_DOMAIN=apps.example.org "$script" aws dev
called "  in the host name" "ingress.host=web-dev.aws.apps.example.org"
expect "the request through the ingress can be skipped" 0 env KUBE_CONTEXT=mc-eks SKIP_INGRESS_SMOKE=1 "$script" aws dev
not_called "  no request is sent" "curl "
contains "  and the summary says so" "skipped"

echo "-- prod"
expect "prod needs a domain" 1 env KUBE_CONTEXT=mc-eks ACME_EMAIL=ops@example.com "$script" aws prod
contains "  and says so" "APP_DOMAIN"
expect "prod needs an email" 1 env KUBE_CONTEXT=mc-eks APP_DOMAIN=apps.example.org "$script" aws prod
contains "  and says so" "ACME_EMAIL"
expect "prod succeeds with both" 0 env KUBE_CONTEXT=mc-eks APP_DOMAIN=apps.example.org ACME_EMAIL=ops@example.com STUB_CERT_READY=False "$script" aws prod
called "  Let's Encrypt issuers are enabled" "acme.email=ops@example.com --set acme.staging.enabled=true --set acme.production.enabled=true"
called "  prod values" "values-prod.yaml"
called "  host" "ingress.host=web-prod.aws.apps.example.org"
not_called "  prod does not force self-signed TLS" "selfsigned"
called "  waits for the autoscaler's metrics" "get hpa web-webapp"
contains "  an unissued certificate is reported, not fatal" "not issued yet"
contains "  and the DNS record is asked for" "Create a DNS record for \`web-prod.aws.apps.example.org\`"

echo "-- failures are failures"
expect "an unreachable cluster fails" 1 env KUBE_CONTEXT=mc-eks STUB_UNREACHABLE=1 "$script" aws dev
contains "  and names the context" "mc-eks"
expect "a cluster without cert-manager fails" 1 env KUBE_CONTEXT=mc-eks STUB_NO_CERT_MANAGER=1 "$script" aws dev
contains "  and says to bring it up" "bring the cluster up first"
not_called "  before installing anything" "helm "
expect "a failing helm test fails the deploy" 1 env KUBE_CONTEXT=mc-eks STUB_HELM_TEST_FAIL=1 "$script" aws dev
expect "a dev certificate that never becomes ready fails" 1 env KUBE_CONTEXT=mc-eks STUB_CERT_READY=False "$script" aws dev
contains "  and says what it waited for" "to become Ready"
expect "no load balancer address fails" 1 env KUBE_CONTEXT=mc-eks STUB_LB= "$script" aws dev
contains "  and says what it waited for" "load balancer address"
expect "a request that never answers fails" 1 env KUBE_CONTEXT=mc-eks STUB_CURL_FAIL=1 "$script" aws dev
contains "  and says which URL" "https://web-dev.aws.example.test/healthz"
expect "an autoscaler without metrics fails prod" 1 env KUBE_CONTEXT=mc-eks APP_DOMAIN=apps.example.org ACME_EMAIL=ops@example.com STUB_HPA_METRICS= "$script" aws prod
contains "  and points at metrics-server" "metrics-server"
expect "a failure prints the namespace state" 1 env KUBE_CONTEXT=mc-eks STUB_HELM_TEST_FAIL=1 "$script" aws dev
contains "  so the log explains itself" "state of namespace web-dev"

echo "-- usage"
expect "a context is required" 1 env KUBE_CONTEXT= "$script" aws dev
expect "an unknown cloud is rejected" 2 env KUBE_CONTEXT=x "$script" mars dev
expect "an unknown environment is rejected" 2 env KUBE_CONTEXT=x "$script" aws staging
expect "no arguments prints usage" 2 "$script"
contains "  usage text" "deploy.sh <aws|azure|gcp> <dev|prod>"

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
