resource "azapi_resource" "aca_environment" {
  type      = "Microsoft.App/managedEnvironments@2024-03-01"
  name      = "cae-${var.project}-${var.environment}"
  location  = azurerm_resource_group.main.location
  parent_id = azurerm_resource_group.main.id

  body = {
    properties = {
      vnetConfiguration = {
        infrastructureSubnetId = azurerm_subnet.aca.id
        internal               = true
      }
      appLogsConfiguration = {
        destination = "log-analytics"
        logAnalyticsConfiguration = {
          customerId = azurerm_log_analytics_workspace.main.workspace_id
          sharedKey  = azurerm_log_analytics_workspace.main.primary_shared_key
        }
      }
      workloadProfiles = [
        {
          name                = "Consumption"
          workloadProfileType = "Consumption"
        }
      ]
      zoneRedundant       = false
      publicNetworkAccess = "Disabled"
    }
  }
}

resource "azurerm_container_app" "hello_korea" {
  name                         = "ca-hello-korea"
  container_app_environment_id = azapi_resource.aca_environment.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aca.id]
  }

  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.aca.id
  }

  ingress {
    external_enabled = true
    target_port      = 8080
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  template {
    container {
      name   = "hello-korea"
      image  = "mcr.microsoft.com/k8se/quickstart:latest"
      cpu    = 0.25
      memory = "0.5Gi"
    }
  }
}
