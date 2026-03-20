# ────────────────────────── infrastructure ────────────────────

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.main.id
}

output "log_analytics_workspace_name" {
  value = azurerm_log_analytics_workspace.main.name
}

# ────────────────────────── AKS ──────────────────────────────

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "aks_kube_config_command" {
  value = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.aks.name}"
}

# ────────────────────────── ACA ──────────────────────────────

output "aca_environment_name" {
  value = azurerm_container_app_environment.aca.name
}

output "aca_hello_korea_fqdn" {
  value = azurerm_container_app.hello_korea.ingress[0].fqdn
}

# ────────────────────────── ACR ──────────────────────────────

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

# ────────────────────────── PostgreSQL ────────────────────────

output "postgresql_fqdn" {
  value     = azurerm_postgresql_flexible_server.main.fqdn
  sensitive = true
}

output "postgresql_server_name" {
  value = azurerm_postgresql_flexible_server.main.name
}

# ────────────────────────── Key Vault ────────────────────────

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.main.vault_uri
}

# ────────────────────────── identities ───────────────────────

output "aks_controlplane_identity_id" {
  value = azurerm_user_assigned_identity.aks_controlplane.id
}

output "aks_kubelet_identity_client_id" {
  value = azurerm_user_assigned_identity.aks_kubelet.client_id
}

output "aca_identity_client_id" {
  value = azurerm_user_assigned_identity.aca.client_id
}

# ────────────────────────── policies ─────────────────────────

output "diagnostic_settings_policy_id" {
  value = azurerm_policy_definition.diagnostic_settings.id
}

output "deny_extra_law_policy_id" {
  value = azurerm_policy_definition.deny_extra_law.id
}
