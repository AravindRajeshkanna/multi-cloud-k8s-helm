#!/usr/bin/env bash
# Phase 0: verify the local toolchain needed to work on this repo.
# Exits non-zero when a required tool is missing or too old.
set -u

missing=0

# first_line <command...>: print the first line of the command's output, giving
# up after ~10s (some CLIs, notably gcloud, can stall on update checks).
first_line() {
  local out pid waited=0
  out=$(mktemp)
  "$@" >"$out" 2>&1 </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    echo "(version check timed out)"
  else
    head -n1 "$out"
  fi
  rm -f "$out"
}

# check <name> <required|optional> <install hint> <version command...>
check() {
  local name=$1 level=$2 hint=$3
  shift 3
  if command -v "$name" >/dev/null 2>&1; then
    printf '  ok       %-10s %s\n' "$name" "$(first_line "$@")"
  elif [ "$level" = required ]; then
    printf '  MISSING  %-10s install: %s\n' "$name" "$hint"
    missing=1
  else
    printf '  absent   %-10s (optional) install: %s\n' "$name" "$hint"
  fi
}

# version_ge <have> <want>: true when have >= want (dotted versions)
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

echo "Core tools"
check git       required "https://git-scm.com/downloads"                git --version
check terraform required "brew install hashicorp/tap/terraform"         terraform version
check helm      required "brew install helm"                            helm version --short
check kubectl   required "brew install kubectl"                         kubectl version --client

echo "Cloud CLIs"
check aws       required "brew install awscli"                          aws --version
check az        required "brew install azure-cli"                       az version --query '"azure-cli"' -o tsv
check gcloud    required "brew install --cask gcloud-cli"               gcloud --version

echo "Helpers"
check gh        optional "brew install gh"                              gh --version
check jq        optional "brew install jq"                              jq --version

if command -v terraform >/dev/null 2>&1; then
  tf_version=$(terraform version | head -n1 | sed -E 's/^Terraform v([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
  if ! version_ge "$tf_version" "1.10.0"; then
    printf '  TOO OLD  terraform  %s found, >= 1.10.0 required (S3 native state locking)\n' "$tf_version"
    missing=1
  fi
fi

# Helm 4 is the client this repo targets (docs/decisions/0004-helm-client.md);
# .tool-versions holds the version CI installs.
if command -v helm >/dev/null 2>&1; then
  helm_version=$(helm version --template '{{.Version}}' 2>/dev/null | sed -E 's/^v//; s/[^0-9.].*$//')
  helm_pinned=$(awk '$1 == "helm" { print $2 }' "$(dirname "$0")/../.tool-versions" 2>/dev/null)
  if [ -n "$helm_version" ] && ! version_ge "$helm_version" "4.0.0"; then
    printf '  TOO OLD  helm       %s found, >= 4.0.0 required (Helm 3 is security-fixes-only until 2027-02-10)\n' "$helm_version"
    missing=1
  elif [ -n "$helm_version" ] && [ -n "$helm_pinned" ] && ! version_ge "$helm_version" "$helm_pinned"; then
    printf '  note     helm       CI uses %s, you have %s; each Helm supports a window of Kubernetes versions (docs/helm.md)\n' "$helm_pinned" "$helm_version"
  fi
fi

echo
if [ "$missing" -ne 0 ]; then
  echo "Some required tools are missing or too old. See docs/roadmap/phase-0-prerequisites.md."
  exit 1
fi
echo "All required tools are present."
