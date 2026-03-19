# ────────────────────────── private DNS ───────────────────────

resource "azurerm_private_dns_zone" "postgresql" {
  name                = "${var.project}${var.environment}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgresql" {
  name                  = "pg-dns-link"
  private_dns_zone_name = azurerm_private_dns_zone.postgresql.name
  virtual_network_id    = azurerm_virtual_network.main.id
  resource_group_name   = azurerm_resource_group.main.name
}

# ────────────────────────── flexible server ───────────────────

resource "azurerm_postgresql_flexible_server" "main" {
  name                          = "psql-${var.project}-${var.environment}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  version                       = var.pg_version
  delegated_subnet_id           = azurerm_subnet.postgresql.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgresql.id
  administrator_login           = var.pg_admin_login
  administrator_password        = var.pg_admin_password
  storage_mb                    = var.pg_storage_mb
  sku_name                      = var.pg_sku
  zone                          = "1"

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgresql]
}

# ────────────────────────── diagnostic settings ──────────────

resource "azurerm_monitor_diagnostic_setting" "postgresql" {
  name                       = "pg-diagnostics"
  target_resource_id         = azurerm_postgresql_flexible_server.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category_group = "allLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
