module "core_addons" {
  source = "../modules/core-addons"

  enable_monitoring = var.enable_monitoring

  # GKE ships and manages metrics-server itself; a second copy would conflict.
  enable_metrics_server = false

  depends_on = [google_container_node_pool.default]
}
