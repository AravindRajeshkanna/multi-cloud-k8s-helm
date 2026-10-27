variable "subscription_id" {
  description = "Azure subscription ID to deploy into."
  type        = string
}

variable "location" {
  description = "Azure region to deploy into."
  type        = string
  default     = "eastus"
}

variable "cluster_name" {
  description = "AKS cluster name. Also used as the kubectl context name and as a prefix for related resources."
  type        = string
  default     = "mc-aks"
}

variable "kubernetes_version" {
  description = "AKS Kubernetes minor version (the patch is chosen by AKS and kept current by the patch upgrade channel)."
  type        = string
  default     = "1.35"
}

variable "enable_public_endpoint" {
  description = "Expose the API server publicly, restricted to var.api_authorized_cidrs. Set false for a private cluster (then run Terraform from a network that can resolve and reach the private endpoint)."
  type        = bool
  default     = true
}

variable "api_authorized_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint (your workstation / CI runner egress). The cluster's own NAT egress IP is added automatically. 0.0.0.0/0 is rejected on purpose."
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

variable "vnet_cidr" {
  description = "Address space of the virtual network."
  type        = string
  default     = "10.1.0.0/16"
}

variable "nodes_subnet_cidr" {
  description = "CIDR of the node subnet (must sit inside var.vnet_cidr). Pods use the overlay network and do not consume these addresses."
  type        = string
  default     = "10.1.0.0/20"
}

variable "pod_cidr" {
  description = "Overlay CIDR for pods. Must not overlap the VNet or var.service_cidr."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "CIDR for Kubernetes Services. Must not overlap the VNet or var.pod_cidr."
  type        = string
  default     = "10.0.0.0/16"
}

variable "dns_service_ip" {
  description = "IP of the cluster DNS Service; must be inside var.service_cidr."
  type        = string
  default     = "10.0.0.10"
}

variable "zones" {
  description = "Availability zones for node pools. Use [] in regions without zones."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "system_vm_size" {
  description = "VM size of the system node pool (runs only critical add-ons)."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "system_min_count" {
  description = "Minimum nodes in the system pool."
  type        = number
  default     = 2
}

variable "system_max_count" {
  description = "Maximum nodes in the system pool."
  type        = number
  default     = 4
}

variable "user_vm_size" {
  description = "VM size of the user node pool (runs workloads)."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "user_min_count" {
  description = "Minimum nodes in the user pool."
  type        = number
  default     = 1
}

variable "user_max_count" {
  description = "Maximum nodes in the user pool."
  type        = number
  default     = 5
}

variable "tags" {
  description = "Tags applied to every Azure resource."
  type        = map(string)
  default = {
    project    = "multi-cloud-k8s-helm"
    managed-by = "terraform"
  }
}
