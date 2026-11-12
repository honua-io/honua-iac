terraform {
  required_version = ">= 1.5, < 2.0"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.28 added invoked_via_function_url, needed for the InvokeFunction grant new function URLs require.
      version = ">= 6.28, < 7.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4, < 3.0"
    }
  }
}
