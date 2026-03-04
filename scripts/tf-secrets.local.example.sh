#!/usr/bin/env bash

# Local credentials helper for Terraform integration scripts.
# Usage:
#   cp scripts/tf-secrets.local.example.sh scripts/tf-secrets.local.sh
#   chmod 600 scripts/tf-secrets.local.sh
#   # edit scripts/tf-secrets.local.sh with real values
#   source scripts/tf-secrets.local.sh
#
# The local file (scripts/tf-secrets.local.sh) is git-ignored.

# Shared secrets
export HONUA_ADMIN_PASSWORD="<admin-password-at-least-32-chars>"
export HONUA_DB_PASSWORD="<postgres-admin-password>"

# Azure credentials (required for Azure/AKS live integration)
export ARM_CLIENT_ID="<service-principal-client-id>"
export ARM_CLIENT_SECRET="<service-principal-client-secret>"
export ARM_TENANT_ID="<tenant-id>"
export ARM_SUBSCRIPTION_ID="<subscription-id>"

# AWS credentials (required for AWS/EKS live integration)
export AWS_ACCESS_KEY_ID="<access-key-id>"
export AWS_SECRET_ACCESS_KEY="<secret-access-key>"
export AWS_SESSION_TOKEN="<session-token-if-applicable>"

# AWS serverless image (required when stack includes serverless)
export HONUA_AWS_SERVERLESS_IMAGE="<account>.dkr.ecr.<region>.amazonaws.com/honua-server:<tag>-lambda-aot"

# Optional existing AWS data stack reuse
# export HONUA_AWS_EXISTING_DB_ENDPOINT="<rds-endpoint>"
# export HONUA_AWS_EXISTING_DB_CONNECTION_STRING="Host=...;Port=5432;Database=honua;Username=honua;Password=...;SSL Mode=Require;Trust Server Certificate=false"
# export HONUA_AWS_EXISTING_REDIS_CONNECTION_STRING="<host>:6379,password=...,ssl=true"
# export HONUA_AWS_EXISTING_VPC_ID="<vpc-id>"
# export HONUA_AWS_EXISTING_VPC_CIDR="<vpc-cidr>"
# export HONUA_AWS_EXISTING_PUBLIC_SUBNET_IDS='["subnet-...","subnet-..."]'
# export HONUA_AWS_EXISTING_PRIVATE_SUBNET_IDS='["subnet-...","subnet-..."]'
