resource "azurerm_container_registry" "acr" {
  name                = "acr${var.project}${var.environment}${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = var.acr_sku
  admin_enabled       = false
}

# AKS kubelet MI — pull images
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = azurerm_container_registry.acr.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.aks_kubelet.principal_id
  skip_service_principal_aad_check = true
}

# ACA MI — pull images
resource "azurerm_role_assignment" "aca_acr_pull" {
  scope                            = azurerm_container_registry.acr.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_user_assigned_identity.aca.principal_id
  skip_service_principal_aad_check = true
}
