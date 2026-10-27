module "core_addons" {
  source = "../modules/core-addons"

  enable_monitoring = var.enable_monitoring

  # AKS ships and manages metrics-server itself; a second copy would conflict.
  enable_metrics_server = false

  depends_on = [azurerm_kubernetes_cluster_node_pool.user]
}
