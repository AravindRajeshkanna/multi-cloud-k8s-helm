output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider (for IRSA trust policies)."
  value       = module.eks.oidc_provider_arn
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets that host the nodes."
  value       = module.vpc.private_subnets
}

output "ingress_class_name" {
  description = "IngressClass that workload charts should reference."
  value       = module.core_addons.ingress_class_name
}

output "kubeconfig_command" {
  description = "Command that adds this cluster to your kubeconfig under a context named after the cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region} --alias ${module.eks.cluster_name}"
}
