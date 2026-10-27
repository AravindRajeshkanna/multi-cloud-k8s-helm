variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name. Also used as the kubectl context alias."
  type        = string
  default     = "mc-eks"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version. Keep var.cluster_autoscaler_chart_version in step with it."
  type        = string
  default     = "1.35"
}

variable "enable_public_endpoint" {
  description = "Expose the API server publicly, restricted to var.api_authorized_cidrs. The private endpoint is always enabled. Set false for a fully private cluster (then run Terraform from inside the VPC)."
  type        = bool
  default     = true
}

variable "api_authorized_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint (your workstation / CI runner egress). 0.0.0.0/0 is rejected on purpose."
  type        = list(string)
  default     = []

  validation {
    condition     = !var.enable_public_endpoint || length(var.api_authorized_cidrs) > 0
    error_message = "api_authorized_cidrs must list at least one CIDR while enable_public_endpoint is true (an empty list would open the endpoint to the world)."
  }

  validation {
    condition     = !contains(var.api_authorized_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not allowed for the API endpoint. List specific CIDRs, or disable the public endpoint."
  }
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread subnets and nodes across."
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway (cheaper) instead of one per AZ (resilient)."
  type        = bool
  default     = true
}

variable "node_instance_types" {
  description = "Instance types for the default managed node group."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_min_size" {
  description = "Minimum nodes in the default node group."
  type        = number
  default     = 2
}

variable "node_desired_size" {
  description = "Initial desired nodes in the default node group (the autoscaler manages it afterwards)."
  type        = number
  default     = 3
}

variable "node_max_size" {
  description = "Maximum nodes in the default node group."
  type        = number
  default     = 6
}

variable "cluster_autoscaler_chart_version" {
  description = "Version of the cluster-autoscaler Helm chart. Its minor version must match var.kubernetes_version, and so must var.cluster_autoscaler_image_tag."
  type        = string
  default     = "9.59.0"
}

variable "cluster_autoscaler_image_tag" {
  description = "Image tag of the Cluster Autoscaler. The chart's own default lags the upstream patch releases, so this is set explicitly: use the newest v<kubernetes_version>.x."
  type        = string
  default     = "v1.35.2"
}

variable "tags" {
  description = "Tags applied to every AWS resource."
  type        = map(string)
  default = {
    project    = "multi-cloud-k8s-helm"
    managed-by = "terraform"
  }
}

variable "enable_monitoring" {
  description = "Install Prometheus and Grafana as a platform add-on (docs/observability.md). Off by default."
  type        = bool
  default     = false
}
