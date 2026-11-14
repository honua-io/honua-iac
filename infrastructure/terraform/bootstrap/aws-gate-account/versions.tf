terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
  }
}
provider "aws" {
  region              = "us-east-1"
  allowed_account_ids = [var.management_account_id]
  default_tags { tags = { ManagedBy = "Terraform", Owner = "Honua", Purpose = "gate-test" } }
}
