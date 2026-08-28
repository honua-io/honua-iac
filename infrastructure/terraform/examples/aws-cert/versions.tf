terraform {
  required_version = ">= 1.5, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4, < 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5, < 4.0"
    }
  }

  # Remote state is configured by copying backend.tf.example to backend.tf after
  # bootstrap/aws-tfstate has been applied. It is deliberately not declared here:
  # a tracked file that has to be edited to activate the backend cannot be the
  # copy-and-fill artifact the operator docs and the governed wrappers expect.
  # See docs/operator-state.md.
}

provider "aws" {
  region = var.region
}
