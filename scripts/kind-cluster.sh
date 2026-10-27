#!/usr/bin/env bash
# Create a throwaway kind cluster for the chart, policy, network and monitoring
# tests (the kind-based jobs in .github/workflows/ci.yml use this script).
#
#   kind-cluster.sh <name> <kindnet|cilium>
#
#   kindnet  kind's default network plugin. It does NOT enforce NetworkPolicy: a
#            policy is accepted and silently ignored.
#   cilium   enforces NetworkPolicy, as AKS and GKE (Dataplane V2) do.
#
# The context is kind-<name>. Needs kind, kubectl and helm.
set -euo pipefail

# Pinned: the plugin under test should not change without a commit.
CILIUM_VERSION=1.20.4

die() {
  echo "error: $*" >&2
  exit 2
}
[ $# -eq 2 ] || die "usage: kind-cluster.sh <name> <kindnet|cilium>"
name=$1
cni=$2
ctx=kind-$name

case $cni in
  kindnet)
    kind create cluster --name "$name" --wait 180s
    ;;
  cilium)
    # No default plugin: nodes stay NotReady until Cilium is installed.
    kind create cluster --name "$name" --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
EOF
    helm --kube-context "$ctx" upgrade --install cilium cilium --repo https://helm.cilium.io \
      --version "$CILIUM_VERSION" -n kube-system \
      --set image.pullPolicy=IfNotPresent --set ipam.mode=kubernetes --set operator.replicas=1 \
      --wait --timeout 8m
    kubectl --context "$ctx" wait --for=condition=Ready nodes --all --timeout=5m
    kubectl --context "$ctx" -n kube-system rollout status deployment/coredns --timeout=5m
    ;;
  *) die "the network plugin must be kindnet or cilium" ;;
esac

kubectl --context "$ctx" get nodes
