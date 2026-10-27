variable "enable_metrics_server" {
  description = "Install metrics-server. Set to false on clouds that already ship it (AKS, GKE)."
  type        = bool
  default     = true
}

variable "enable_ingress" {
  description = "Install the cloud-agnostic ingress controller (Traefik). See docs/decisions/0002-ingress-controller.md."
  type        = bool
  default     = true
}

variable "enable_cert_manager" {
  description = "Install cert-manager (CRDs included)."
  type        = bool
  default     = true
}

variable "ingress_service_annotations" {
  description = "Annotations for the ingress controller's LoadBalancer Service (cloud-specific, e.g. NLB type on AWS)."
  type        = map(string)
  default     = {}
}

variable "metrics_server_chart_version" {
  description = "Version of the metrics-server Helm chart."
  type        = string
  default     = "3.14.0"
}

variable "traefik_chart_version" {
  description = "Version of the Traefik Helm chart."
  type        = string
  default     = "42.1.3"
}

variable "cert_manager_chart_version" {
  description = "Version of the cert-manager Helm chart."
  type        = string
  default     = "v1.21.3"
}
