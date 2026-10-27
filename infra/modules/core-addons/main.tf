# Cloud-agnostic platform add-ons. The caller configures the `helm` provider
# against its own cluster; everything cloud-specific arrives through variables.

resource "helm_release" "metrics_server" {
  count = var.enable_metrics_server ? 1 : 0

  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"

  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  values = [yamlencode({
    replicas = 2
    podDisruptionBudget = {
      enabled      = true
      minAvailable = 1
    }
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "128Mi" }
    }
  })]
}

resource "helm_release" "traefik" {
  count = var.enable_ingress ? 1 : 0

  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.traefik_chart_version
  namespace        = "ingress"
  create_namespace = true

  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  values = [yamlencode({
    deployment = { replicas = 2 }
    podDisruptionBudget = {
      enabled      = true
      minAvailable = 1
    }
    service = {
      type        = "LoadBalancer"
      annotations = var.ingress_service_annotations
    }
    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { memory = "256Mi" }
    }
  })]
}

resource "helm_release" "cert_manager" {
  count = var.enable_cert_manager ? 1 : 0

  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  namespace        = "cert-manager"
  create_namespace = true

  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  values = [yamlencode({
    crds = { enabled = true }
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "256Mi" }
    }
  })]
}

resource "helm_release" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  name             = "monitoring"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.monitoring_chart_version
  namespace        = "monitoring"
  create_namespace = true

  atomic          = true
  cleanup_on_fail = true
  timeout         = 900

  values = [file("${path.module}/monitoring-values.yaml")]
}
