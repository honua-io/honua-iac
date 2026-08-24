terraform {
  required_version = ">= 1.5, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.3.1"
    }
  }
}
