resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-${var.project}-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = var.law_retention_days
  tags                = local.common_tags
}

# ────────────────────────── diagnostic settings (LAW consolidation) ──

resource "azurerm_monitor_diagnostic_setting" "vnet" {
  name                       = "vnet-diagnostics"
  target_resource_id         = azurerm_virtual_network.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category_group = "allLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# Note: AKS, ACR, and Key Vault diagnostic settings are managed by Azure Policy
# (DeployIfNotExists policy creates 'setByPolicy' diagnostic settings automatically)
