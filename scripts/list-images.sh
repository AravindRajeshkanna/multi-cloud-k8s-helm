#!/usr/bin/env bash
# Print every container image the platform and the workloads run, one per line,
# sorted and de-duplicated. The input to the supply-chain workflow
# (.github/workflows/supply-chain.yml), which scans them and records their SBOMs.
#
# Sources:
#   - this repo's charts, rendered with their default values
#   - the platform add-ons, rendered at the chart versions Terraform pins
#     (infra/modules/core-addons/variables.tf, infra/aws-eks/variables.tf)
#
# Needs helm and network access to the chart repositories.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

die() {
  echo "error: $*" >&2
  exit 1
}

# tf_default <file> <variable>: the default of a Terraform variable
tf_default() {
  awk -v v="$2" '$0 ~ "variable \"" v "\"" { f = 1 } f && /default/ { gsub(/"/, "", $3); print $3; exit }' "$root/$1"
}

core=infra/modules/core-addons/variables.tf
cert_manager=$(tf_default "$core" cert_manager_chart_version)
traefik=$(tf_default "$core" traefik_chart_version)
metrics_server=$(tf_default "$core" metrics_server_chart_version)
autoscaler=$(tf_default infra/aws-eks/variables.tf cluster_autoscaler_chart_version)
for v in "$cert_manager" "$traefik" "$metrics_server" "$autoscaler"; do
  [ -n "$v" ] || die "cannot read a chart version from the Terraform variables"
done

# images_in: read manifests on stdin, print the images they name. Besides
# `image:` fields, cert-manager hands its challenge-solver image to its
# controller as a flag.
images_in() {
  grep -E '^[[:space:]-]*image:|--[a-z0-9-]*image=' |
    sed -E 's/^[[:space:]-]*image:[[:space:]]*//; s/^.*--[a-z0-9-]*image=//' |
    tr -d "\"'" | sed -E 's/[[:space:]]+$//' | sed '/^$/d'
}

{
  helm template web "$root/charts/webapp"
  helm template issuers "$root/charts/cluster-issuers"
  helm template cert-manager cert-manager --repo https://charts.jetstack.io --version "$cert_manager" --set crds.enabled=true
  helm template traefik traefik --repo https://traefik.github.io/charts --version "$traefik"
  helm template metrics-server metrics-server --repo https://kubernetes-sigs.github.io/metrics-server --version "$metrics_server"
  helm template cluster-autoscaler cluster-autoscaler --repo https://kubernetes.github.io/autoscaler --version "$autoscaler" \
    --set awsRegion=us-east-1 --set autoDiscovery.clusterName=mc-eks
} | images_in | sort -u
