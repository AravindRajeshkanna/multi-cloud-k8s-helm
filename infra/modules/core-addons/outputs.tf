output "ingress_class_name" {
  description = "IngressClass name that workload charts should reference (null when the ingress controller is disabled)."
  value       = var.enable_ingress ? "traefik" : null
}

output "installed_releases" {
  description = "Helm release name => chart version for every add-on this module installed."
  value = merge(
    { for r in helm_release.metrics_server : r.name => r.version },
    { for r in helm_release.traefik : r.name => r.version },
    { for r in helm_release.cert_manager : r.name => r.version },
  )
}
