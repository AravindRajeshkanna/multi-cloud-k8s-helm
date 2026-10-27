variable "project_id" {
  description = "Google Cloud project ID to deploy into."
  type        = string
}

variable "region" {
  description = "Region for the regional (multi-zone) cluster and its network."
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "GKE cluster name. Also used as the kubectl context name and as a prefix for related resources."
  type        = string
  default     = "mc-gke"
}

variable "release_channel" {
  description = "GKE release channel (RAPID, REGULAR, STABLE or EXTENDED). The channel picks and upgrades the Kubernetes version."
  type        = string
  default     = "REGULAR"
}

variable "deletion_protection" {
  description = "Block terraform destroy of the cluster. Set false (and apply) before tearing a cluster down."
  type        = bool
  default     = true
}

variable "enable_public_endpoint" {
  description = "Expose the control plane's public endpoint, restricted to var.api_authorized_cidrs. Nodes are always private. Set false for a private-endpoint-only cluster (then run Terraform from inside the VPC)."
  type        = bool
  default     = true
}

variable "api_authorized_cidrs" {
  description = "CIDRs allowed to reach the control plane (your workstation / CI runner egress). 0.0.0.0/0 is rejected on purpose."
  type        = list(string)
  default     = []

  validation {
    condition     = !var.enable_public_endpoint || length(var.api_authorized_cidrs) > 0
    error_message = "api_authorized_cidrs must list at least one CIDR while enable_public_endpoint is true (an empty list would leave the endpoint open to the world)."
  }

  validation {
    condition     = !contains(var.api_authorized_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not allowed for the API endpoint. List specific CIDRs, or disable the public endpoint."
  }
}

variable "subnet_cidr" {
  description = "Primary CIDR of the node subnet."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary range for pod IPs."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary range for Service cluster IPs."
  type        = string
  default     = "10.30.0.0/20"
}

variable "master_cidr" {
  description = "/28 reserved for the control plane's private endpoint. Must not overlap any other range."
  type        = string
  default     = "172.16.0.0/28"
}

variable "machine_type" {
  description = "Machine type of the default node pool."
  type        = string
  default     = "e2-standard-2"
}

variable "node_min_count_per_zone" {
  description = "Minimum nodes per zone in the default node pool (a regional cluster spans three zones)."
  type        = number
  default     = 1
}

variable "node_max_count_per_zone" {
  description = "Maximum nodes per zone in the default node pool."
  type        = number
  default     = 3
}

variable "labels" {
  description = "Labels applied to the cluster and nodes."
  type        = map(string)
  default = {
    project    = "multi-cloud-k8s-helm"
    managed-by = "terraform"
  }
}
