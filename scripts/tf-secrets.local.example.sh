#!/usr/bin/env bash

# Local credentials helper for Terraform integration scripts.
# Usage:
#   cp scripts/tf-secrets.local.example.sh scripts/tf-secrets.local.sh
#   chmod 600 scripts/tf-secrets.local.sh
#   # edit scripts/tf-secrets.local.sh with real values
#   source scripts/tf-secrets.local.sh
#   # or persist into pass:
#   #   scripts/tf-pass-secrets.sh import --env-file scripts/tf-secrets.local.sh --force
#   #   source <(scripts/tf-pass-secrets.sh export)
#
# The local file (scripts/tf-secrets.local.sh) is git-ignored.

# Shared secrets
# Used for both HONUA_ADMIN_PASSWORD and Security__ConnectionEncryption__MasterKey.
# Keep this at 32+ characters.
export HONUA_ADMIN_PASSWORD="<admin-password-at-least-32-chars>"
# Postgres admin password for live validation.
# Safe default: 32+ chars with mixed case, numbers, and a special from:
#   #%*()-_=+[]{}:?.
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

# Image refs are configuration, not secrets.
# For local runs, prefer CLI flags such as:
#   --aca-image
#   --functions-image
#   --ecs-image
#   --serverless-image
# For GitHub Actions, prefer repository variables such as:
#   HONUA_ACA_IMAGE
#   HONUA_FUNCTIONS_IMAGE
#   HONUA_AWS_ECS_IMAGE
#   HONUA_AWS_SERVERLESS_IMAGE

# Optional existing AWS data stack reuse
# export HONUA_AWS_EXISTING_DB_ENDPOINT="<rds-endpoint>"
# export HONUA_AWS_EXISTING_DB_CONNECTION_STRING="Host=...;Port=5432;Database=honua;Username=honua;Password=...;SSL Mode=Require;Trust Server Certificate=false"
# export HONUA_AWS_EXISTING_REDIS_CONNECTION_STRING="<host>:6379,password=...,ssl=true"
# export HONUA_AWS_EXISTING_VPC_ID="<vpc-id>"
# export HONUA_AWS_EXISTING_VPC_CIDR="<vpc-cidr>"
# export HONUA_AWS_EXISTING_PUBLIC_SUBNET_IDS='["subnet-...","subnet-..."]'
# export HONUA_AWS_EXISTING_PRIVATE_SUBNET_IDS='["subnet-...","subnet-..."]'
