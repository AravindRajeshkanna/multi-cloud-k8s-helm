resource "azurerm_resource_group" "this" {
  name     = "${var.cluster_name}-rg"
  location = var.location
  tags     = var.tags
}

# --- Network: nodes live in a subnet with no public IPs; egress goes through NAT ---

resource "azurerm_virtual_network" "this" {
  name                = "${var.cluster_name}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "nodes"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.nodes_subnet_cidr]
}

resource "azurerm_public_ip" "nat" {
  name                = "${var.cluster_name}-nat-ip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  name                = "${var.cluster_name}-nat"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "nodes" {
  subnet_id      = azurerm_subnet.nodes.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

# --- Cluster identity: created up front so it can hold rights on the subnet ---
# The identity running Terraform therefore needs permission to write role
# assignments (see docs/github-secrets.md).

resource "azurerm_user_assigned_identity" "cluster" {
  name                = "${var.cluster_name}-identity"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_role_assignment" "cluster_network" {
  scope                = azurerm_subnet.nodes.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
}

# --- Control plane + system node pool ---

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Standard"

  # Workload identity: pods authenticate to Entra ID with federated tokens.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  private_cluster_enabled   = !var.enable_public_endpoint
  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_vm_size
    vnet_subnet_id               = azurerm_subnet.nodes.id
    zones                        = var.zones
    auto_scaling_enabled         = true
    min_count                    = var.system_min_count
    max_count                    = var.system_max_count
    only_critical_addons_enabled = true
    temporary_name_for_rotation  = "systemtmp"

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cluster.id]
  }

  # Manual = we own the node pools (the "Standard" cluster mode from Phase 0),
  # as opposed to Auto, where AKS provisions nodes itself.
  node_provisioning_profile {
    mode = "Manual"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    outbound_type       = "userAssignedNATGateway"
    load_balancer_sku   = "standard"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
  }

  # authorized_ip_ranges is not supported on private clusters.
  dynamic "api_server_access_profile" {
    for_each = var.enable_public_endpoint ? [1] : []

    content {
      authorized_ip_ranges = concat(var.api_authorized_cidrs, ["${azurerm_public_ip.nat.ip_address}/32"])
    }
  }

  tags = var.tags

  # Nodes need their NAT egress path in place before they try to join.
  depends_on = [
    azurerm_subnet_nat_gateway_association.nodes,
    azurerm_nat_gateway_public_ip_association.this,
    azurerm_role_assignment.cluster_network,
  ]
}

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  mode                  = "User"
  vm_size               = var.user_vm_size
  vnet_subnet_id        = azurerm_subnet.nodes.id
  zones                 = var.zones
  auto_scaling_enabled  = true
  min_count             = var.user_min_count
  max_count             = var.user_max_count

  node_labels = {
    pool = "user"
  }

  upgrade_settings {
    max_surge = "10%"
  }

  tags = var.tags
}
