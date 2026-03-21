resource "azurerm_key_vault" "main" {
  name                          = "kv-${var.project}-${var.environment}-${random_string.suffix.result}"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 7
  public_network_access_enabled = true
  tags                          = local.common_tags
}

# Deploying identity gets Key Vault Administrator
resource "azurerm_role_assignment" "kv_deployer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# AKS kubelet MI — read secrets via CSI driver
resource "azurerm_role_assignment" "aks_kv_secrets" {
  scope                            = azurerm_key_vault.main.id
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = azurerm_user_assigned_identity.aks_kubelet.principal_id
  skip_service_principal_aad_check = true
}

# ACA MI — read secrets
resource "azurerm_role_assignment" "aca_kv_secrets" {
  scope                            = azurerm_key_vault.main.id
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = azurerm_user_assigned_identity.aca.principal_id
  skip_service_principal_aad_check = true
}

# Store PostgreSQL password in Key Vault
resource "azurerm_key_vault_secret" "pg_password" {
  name         = "pg-admin-password"
  value        = var.pg_admin_password
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_role_assignment.kv_deployer]
}

# Store PostgreSQL admin login in Key Vault
resource "azurerm_key_vault_secret" "pg_login" {
  name         = "pg-admin-login"
  value        = var.pg_admin_login
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_role_assignment.kv_deployer]
}

# Store PostgreSQL host in Key Vault
resource "azurerm_key_vault_secret" "pg_host" {
  name         = "pg-host"
  value        = azurerm_postgresql_flexible_server.main.fqdn
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_role_assignment.kv_deployer]
}
