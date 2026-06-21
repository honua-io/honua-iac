# Honua Terraform Feature Map

This repository owns reusable cloud modules, deployable examples, bootstrap templates, and validation assets for Honua deployments.

## Current Capabilities

- Deployable operator paths for AWS ECS/Fargate, Azure Container Apps, AWS Lambda, and Azure Functions.
- Reusable modules for AWS ECS, AWS EKS, AWS serverless, Azure Container Apps, Azure AKS, Azure Functions, and observability stack.
- Bootstrap templates for least-privilege identities across the supported runtime targets.
- Validation and platform QA scripts for live applies, policy gates, drift checks, and Kubernetes/serverless/container runtime validation.
- Disaster-recovery drill runbooks (backup/restore, failover) with RTO/RPO evidence capture for the validated AWS and Azure targets.
- Module publishing decision docs and operator deployment guide.
- CI workflows for Terraform formatting, validation, security checks, manual validation, and platform QA.

## Source Evidence

- Modules and examples: `infrastructure/terraform/modules/`, `infrastructure/terraform/examples/`
- Bootstrap templates: `infrastructure/terraform/bootstrap/`
- Validation assets: `infrastructure/terraform/validation/`, `scripts/`
- Operator docs: `docs/operator-deployment.md`, `docs/devops/terraform-validation.md`, `docs/module-publishing-decision.md`
- DR drill runbooks: `docs/devops/backup-restore-runbook.md`, `docs/devops/failover-drill-runbook.md`, `docs/devops/dr-evidence-template.json`

## Boundary

Marketplace listing packages belong in `honua-marketplace`; Kubernetes chart packaging belongs in `honua-helm`. This repository owns reusable infrastructure and validation paths.
