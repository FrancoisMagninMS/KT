# ────────────────────────── AKS identities ───────────────────

resource "azurerm_user_assigned_identity" "aks_controlplane" {
  name                = "mi-aks-cp-${var.project}-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_user_assigned_identity" "aks_kubelet" {
  name                = "mi-aks-kubelet-${var.project}-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

# ────────────────────────── ACA identity ─────────────────────

resource "azurerm_user_assigned_identity" "aca" {
  name                = "mi-aca-${var.project}-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

# ────────────────────────── AKS control plane role assignments ─

# Network Contributor on VNet — required for Azure CNI
resource "azurerm_role_assignment" "aks_cp_network" {
  scope                            = azurerm_virtual_network.main.id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_user_assigned_identity.aks_controlplane.principal_id
  skip_service_principal_aad_check = true
}

# Managed Identity Operator on kubelet MI — required to assign it to VMSS
resource "azurerm_role_assignment" "aks_cp_mi_operator" {
  scope                            = azurerm_user_assigned_identity.aks_kubelet.id
  role_definition_name             = "Managed Identity Operator"
  principal_id                     = azurerm_user_assigned_identity.aks_controlplane.principal_id
  skip_service_principal_aad_check = true
}
