terraform {
  required_version = ">= 1.5, < 2.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0, < 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5, < 4.0"
    }
  }

  # Remote state — uncomment and fill in before first apply.
  # backend "azurerm" {
  #   resource_group_name  = "honua-tfstate-rg"
  #   storage_account_name = "honuatfstate<suffix>"
  #   container_name       = "tfstate"
  #   key                  = "cert/azure-cert/terraform.tfstate"
  # }
}

provider "azurerm" {
  features {}
}
