resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project}-${var.environment}"
  location = var.location

  tags = {
    environment = var.environment
    project     = var.project
    managed_by  = "terraform"
  }
}

data "azurerm_client_config" "current" {}
