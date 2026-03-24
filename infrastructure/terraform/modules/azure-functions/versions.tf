terraform {
  required_version = ">= 1.5, < 2.0"
  required_providers {
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.4"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.58"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.17"
    }
  }
}
