provider "azurerm" {
  subscription_id = var.subscription_id

  features {}
}

# Uses the cluster-admin client certificate from the (local-accounts-enabled)
# cluster. Switching to Entra ID RBAC + kubelogin is a Phase 6 hardening step.
provider "helm" {
  kubernetes = {
    host                   = azurerm_kubernetes_cluster.this.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)
  }
}
