resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

locals {
  common_tags = {
    environment = var.environment
    project     = var.project
    managed_by  = "terraform"
  }
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project}-${var.environment}"
  location = var.location
  tags     = local.common_tags
}

data "azurerm_client_config" "current" {}
