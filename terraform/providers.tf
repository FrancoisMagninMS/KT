terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.80"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-kt-tfstate"
    storage_account_name = "stkttfstate"
    container_name       = "tfstate"
    key                  = "kt-infrastructure.tfstate"
    use_azuread_auth     = true
    use_cli              = true
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
  subscription_id      = var.subscription_id
  storage_use_azuread  = true
}
