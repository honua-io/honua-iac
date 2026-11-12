terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.0 added the per-resource `region` argument this root uses instead of provider aliases.
      version = ">= 6.0, < 7.0"
    }
  }
}

provider "aws" {
  region = var.home_region
}
