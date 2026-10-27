# Prerequisite APIs (enable once per project, see docs/github-secrets.md):
#   container.googleapis.com compute.googleapis.com iam.googleapis.com

# --- Network: custom VPC, private nodes, Cloud NAT for egress ---

resource "google_compute_network" "this" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "nodes" {
  name                     = "${var.cluster_name}-nodes"
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}

resource "google_compute_router" "this" {
  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.this.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# --- Node identity: least-privilege service account instead of the default compute SA ---

resource "google_service_account" "nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE nodes for ${var.cluster_name}"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

# --- Control plane (Standard mode: we own the node pools) ---

resource "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.region

  network    = google_compute_network.this.id
  subnetwork = google_compute_subnetwork.nodes.id

  # Node pools are managed separately; the throwaway default pool is dropped.
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = var.deletion_protection
  resource_labels     = var.labels

  networking_mode   = "VPC_NATIVE"
  datapath_provider = "ADVANCED_DATAPATH" # Dataplane V2 (Cilium): enforces NetworkPolicy

  release_channel {
    channel = var.release_channel
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = !var.enable_public_endpoint
    master_ipv4_cidr_block  = var.master_cidr
  }

  dynamic "master_authorized_networks_config" {
    for_each = length(var.api_authorized_cidrs) > 0 ? [1] : []

    content {
      dynamic "cidr_blocks" {
        for_each = var.api_authorized_cidrs

        content {
          cidr_block   = cidr_blocks.value
          display_name = "authorized-${cidr_blocks.key}"
        }
      }
    }
  }

  # Workload Identity Federation: pods map to IAM principals, no node SA keys.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }
}

resource "google_container_node_pool" "default" {
  name     = "default"
  cluster  = google_container_cluster.this.name
  location = var.region

  autoscaling {
    min_node_count = var.node_min_count_per_zone
    max_node_count = var.node_max_count_per_zone
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type    = var.machine_type
    disk_type       = "pd-balanced"
    disk_size_gb    = 100
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = merge(var.labels, { pool = "default" })

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  depends_on = [google_project_iam_member.nodes, google_compute_router_nat.this]
}
