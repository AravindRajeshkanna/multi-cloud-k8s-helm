output "cluster_name" {
  description = "GKE cluster name."
  value       = google_container_cluster.this.name
}

output "cluster_endpoint" {
  description = "Control plane endpoint (public IP, or private IP when the public endpoint is disabled)."
  value       = google_container_cluster.this.endpoint
}

output "workload_pool" {
  description = "Workload Identity pool; IAM bindings for Kubernetes service accounts use this as the principal prefix."
  value       = "${var.project_id}.svc.id.goog"
}

output "network_name" {
  description = "Name of the VPC network."
  value       = google_compute_network.this.name
}

output "ingress_class_name" {
  description = "IngressClass that workload charts should reference."
  value       = module.core_addons.ingress_class_name
}

output "kubeconfig_command" {
  description = "Command that adds this cluster to your kubeconfig under a context named after the cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --region ${var.region} --project ${var.project_id} && kubectl config rename-context gke_${var.project_id}_${var.region}_${google_container_cluster.this.name} ${google_container_cluster.this.name}"
}
