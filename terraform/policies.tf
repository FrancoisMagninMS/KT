locals {
  scope = "/subscriptions/${var.subscription_id}"

  # Policy resources are subscription-scoped and must be managed by a single
  # Terraform state to avoid conflicts.  Only the "prod" environment creates
  # and manages them.
  manage_policies = var.environment == "prod"

  # All valid LAW names across environments (used by the deny policy)
  allowed_law_names = [
    "law-${var.project}-dev",
    "law-${var.project}-test",
    "law-${var.project}-qa",
    "law-${var.project}-prod",
  ]

  supported_resource_types = [
    "Microsoft.Compute/virtualMachines",
    "Microsoft.Network/networkSecurityGroups",
    "Microsoft.Network/loadBalancers",
    "Microsoft.Network/publicIPAddresses",
    "Microsoft.Network/applicationGateways",
    "Microsoft.Network/azureFirewalls",
    "Microsoft.Network/virtualNetworkGateways",
    "Microsoft.Sql/servers/databases",
    "Microsoft.KeyVault/vaults",
    "Microsoft.Storage/storageAccounts",
    "Microsoft.Web/sites",
    "Microsoft.ContainerService/managedClusters",
    "Microsoft.EventHub/namespaces",
    "Microsoft.ServiceBus/namespaces",
    "Microsoft.Cdn/profiles",
    "Microsoft.DBforPostgreSQL/flexibleServers",
    "Microsoft.DBforMySQL/flexibleServers",
    "Microsoft.Cache/redis",
    "Microsoft.CognitiveServices/accounts",
    "Microsoft.ContainerRegistry/registries",
    "Microsoft.ApiManagement/service",
    "Microsoft.SignalRService/SignalR",
    "Microsoft.Batch/batchAccounts",
    "Microsoft.DocumentDB/databaseAccounts",
    "Microsoft.DataFactory/factories",
    "Microsoft.OperationalInsights/workspaces",
    "Microsoft.Automation/automationAccounts",
  ]

  monitoring_contributor_role_id    = "/providers/Microsoft.Authorization/roleDefinitions/749f88d5-cbae-40b8-bcfc-e573ddc772fa"
  log_analytics_contributor_role_id = "/providers/Microsoft.Authorization/roleDefinitions/92aaf0da-9dab-42b6-94a3-d43ce8d16293"
}

###############################################################################
# Policy 1: Enable Diagnostic Settings (DeployIfNotExists)
###############################################################################

resource "azurerm_policy_definition" "diagnostic_settings" {
  count        = local.manage_policies ? 1 : 0
  name         = "enable-diagnostic-settings"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Enable Diagnostic Settings to Log Analytics"
  description  = "Automatically deploys diagnostic settings on supported resource types, sending logs and metrics to the specified Log Analytics Workspace."

  metadata = jsonencode({ category = "Monitoring" })

  parameters = jsonencode({
    logAnalyticsWorkspaceId = {
      type = "String"
      metadata = {
        displayName = "Log Analytics Workspace ID"
        description = "Full resource ID of the Log Analytics Workspace to send diagnostics to."
      }
    }
    profileName = {
      type         = "String"
      defaultValue = "setByPolicy"
      metadata = {
        displayName = "Diagnostic Settings Profile Name"
        description = "Name of the diagnostic settings profile."
      }
    }
  })

  policy_rule = jsonencode({
    if = {
      field = "type"
      in    = local.supported_resource_types
    }
    then = {
      effect = "deployIfNotExists"
      details = {
        type = "Microsoft.Insights/diagnosticSettings"
        roleDefinitionIds = [
          local.monitoring_contributor_role_id,
          local.log_analytics_contributor_role_id,
        ]
        existenceCondition = {
          allOf = [{
            field  = "Microsoft.Insights/diagnosticSettings/workspaceId"
            equals = "[parameters('logAnalyticsWorkspaceId')]"
          }]
        }
        deployment = {
          properties = {
            mode = "incremental"
            parameters = {
              resourceId              = { value = "[field('id')]" }
              logAnalyticsWorkspaceId = { value = "[parameters('logAnalyticsWorkspaceId')]" }
              profileName             = { value = "[parameters('profileName')]" }
            }
            template = {
              "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
              contentVersion = "1.0.0.0"
              parameters = {
                resourceId              = { type = "string" }
                logAnalyticsWorkspaceId = { type = "string" }
                profileName             = { type = "string" }
              }
              resources = [{
                type       = "Microsoft.Insights/diagnosticSettings"
                apiVersion = "2021-05-01-preview"
                name       = "[parameters('profileName')]"
                scope      = "[parameters('resourceId')]"
                properties = {
                  workspaceId = "[parameters('logAnalyticsWorkspaceId')]"
                  logs        = [{ categoryGroup = "allLogs", enabled = true }]
                  metrics     = [{ category = "AllMetrics", enabled = true }]
                }
              }]
            }
          }
        }
      }
    }
  })
}

resource "azurerm_subscription_policy_assignment" "diagnostic_settings" {
  count                = local.manage_policies ? 1 : 0
  name                 = "assign-diagnostic-settings"
  display_name         = "Enable Diagnostic Settings to Log Analytics"
  policy_definition_id = azurerm_policy_definition.diagnostic_settings[0].id
  subscription_id      = local.scope
  location             = var.location

  identity {
    type = "SystemAssigned"
  }

  parameters = jsonencode({
    logAnalyticsWorkspaceId = { value = azurerm_log_analytics_workspace.main.id }
  })
}

# MI role assignments for diagnostic settings policy
resource "azurerm_role_assignment" "policy_monitoring_contributor" {
  count                            = local.manage_policies ? 1 : 0
  scope                            = local.scope
  role_definition_id               = "${local.scope}${local.monitoring_contributor_role_id}"
  principal_id                     = azurerm_subscription_policy_assignment.diagnostic_settings[0].identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "policy_la_contributor" {
  count                            = local.manage_policies ? 1 : 0
  scope                            = local.scope
  role_definition_id               = "${local.scope}${local.log_analytics_contributor_role_id}"
  principal_id                     = azurerm_subscription_policy_assignment.diagnostic_settings[0].identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_subscription_policy_remediation" "diagnostic_settings" {
  count                   = local.manage_policies ? 1 : 0
  name                    = "remediate-diagnostic-settings"
  subscription_id         = local.scope
  policy_assignment_id    = azurerm_subscription_policy_assignment.diagnostic_settings[0].id
  resource_discovery_mode = "ReEvaluateCompliance"

  depends_on = [
    azurerm_role_assignment.policy_monitoring_contributor,
    azurerm_role_assignment.policy_la_contributor,
  ]
}

###############################################################################
# Policy 2: Deny Multiple Log Analytics Workspaces
###############################################################################

resource "azurerm_policy_definition" "deny_extra_law" {
  count        = local.manage_policies ? 1 : 0
  name         = "deny-extra-law"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Deny Log Analytics Workspaces except approved workspaces"
  description  = "Prevents creation of Log Analytics Workspaces that do not match the approved workspace names (one per environment)."

  metadata = jsonencode({ category = "Monitoring" })

  parameters = jsonencode({
    allowedWorkspaceNames = {
      type = "Array"
      metadata = {
        displayName = "Allowed Workspace Names"
        description = "List of allowed Log Analytics Workspace names (one per environment)."
      }
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.OperationalInsights/workspaces" },
        { field = "name", notIn = "[parameters('allowedWorkspaceNames')]" },
      ]
    }
    then = { effect = "deny" }
  })
}

resource "azurerm_subscription_policy_assignment" "deny_extra_law" {
  count                = local.manage_policies ? 1 : 0
  name                 = "deny-extra-law-assignment"
  display_name         = "Deny Log Analytics Workspaces except approved names"
  policy_definition_id = azurerm_policy_definition.deny_extra_law[0].id
  subscription_id      = local.scope

  parameters = jsonencode({
    allowedWorkspaceNames = { value = local.allowed_law_names }
  })
}
