---
type: index
title: "What the Terraform repository ships"
description: "The reusable cloud modules, deployment presets and operator contracts this repo ships, and which cloud each covers."
resource: "https://github.com/honua-io/honua-iac/tree/trunk/infrastructure/terraform/modules"
tags: [terraform, modules, cloud]
---
# What the Terraform repository ships

This repository owns reusable cloud modules, deployable examples, bootstrap templates, and validation assets for Honua deployments.

## Current Capabilities

- Deployable operator paths for AWS ECS/Fargate, Azure Container Apps, AWS Lambda, and Azure Functions.
- Reusable modules for AWS ECS, AWS EKS, AWS serverless, Azure Container Apps, Azure AKS, Azure Functions, and observability stack.
- Bootstrap templates for least-privilege identities across the supported runtime targets.
- Validation and platform QA scripts for live applies, policy gates, drift checks, and Kubernetes/serverless/container runtime validation.
- Disaster-recovery drill runbooks (backup/restore, failover) with RTO/RPO evidence capture for the validated AWS and Azure targets.
- CI workflows for Terraform formatting, validation, security checks, manual validation, and platform QA.

## Boundary

Kubernetes chart packaging belongs in [honua-helm](https://github.com/honua-io/honua-helm). This repository owns reusable infrastructure and validation paths.
