terraform {
  required_version = ">= 1.5, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5, < 4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2, < 4.0"
    }
  }

  # Remote state — uncomment and fill in before first apply.
  # backend "s3" {
  #   bucket         = "honua-tfstate-<account-id>"
  #   key            = "demo/aws-demo/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "honua-tfstate-lock"
  # }
}

provider "aws" {
  region = var.region
}
