terraform {
  required_version = ">= 1.5, < 2.0"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.13, < 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.29, < 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5, < 4.0"
    }
  }
}
