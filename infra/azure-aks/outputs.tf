output "cluster_name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.this.name
}

output "resource_group_name" {
  description = "Resource group holding the cluster and its network."
  value       = azurerm_resource_group.this.name
}

output "oidc_issuer_url" {
  description = "Cluster OIDC issuer URL, needed for Entra Workload ID federated credentials."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "nat_egress_ip" {
  description = "Public IP all node egress traffic leaves from (useful for allow-lists on external services)."
  value       = azurerm_public_ip.nat.ip_address
}

output "ingress_class_name" {
  description = "IngressClass that workload charts should reference."
  value       = module.core_addons.ingress_class_name
}

output "kubeconfig_command" {
  description = "Command that adds this cluster to your kubeconfig under a context named after the cluster."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.this.name} --name ${azurerm_kubernetes_cluster.this.name} --context ${azurerm_kubernetes_cluster.this.name} --overwrite-existing"
}
