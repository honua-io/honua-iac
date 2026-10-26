terraform {
  required_version = ">= 1.5, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
  }
  # Partial S3 backend: supply bucket/key/region with -backend-config (see README).
  backend "s3" {}
}
provider "aws" { region = var.region }
