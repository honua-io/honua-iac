# AWS Marketplace Container Offer

This document is the current AWS-first submission plan for Honua Terraform marketplace work.

## Recommendation

Start with an AWS Marketplace **container product** that deploys Honua to **ECS/Fargate** using the
validated Terraform root at `infrastructure/terraform/examples/aws`.

Do **not** start with an Amazon EKS add-on for the first submission.

## Why ECS/Fargate First

- The repo already has a turnkey runtime target for ECS/Fargate:
  - Terraform root: `infrastructure/terraform/examples/aws`
  - Module: `infrastructure/terraform/modules/aws-ecs`
  - Bundle manifest: `infrastructure/terraform/marketplace/bundles/aws-ecs.v1.json`
- The EKS root in this repo is cluster-only and does not install Honua by itself.
- AWS Marketplace add-ons are aimed at cluster-operational software and carry extra packaging
  constraints that do not buy us much for the first release:
  - Helm chart packaging in Marketplace-managed ECR
  - image regionalization rules
  - add-on configuration schema constraints
  - AMD64 and ARM64 compatibility expectations

## Current Repo Boundary

`honua-terraform` remains the source of truth for:

- reusable Terraform modules
- operator-facing example stacks
- marketplace bundle metadata under `infrastructure/terraform/marketplace/`
- validation and smoke-test automation
- customer distribution packaging via `scripts/package-customer-dist.sh`

Seller-specific AWS Marketplace assets should live outside this repo in a private packaging repo.
That private repo should consume a pinned release artifact from this repo rather than duplicating
Terraform implementation.

## Recommended Delivery Shape

### Phase 1

- Product type: AWS Marketplace container product
- Runtime target: ECS/Fargate
- Deployment surface: seller-provided deployment instructions and/or deployment templates aligned
  to the `examples/aws` install contract
- Pricing: decide separately between BYOL and paid container product pricing

### Later, only if needed

- Amazon EKS add-on packaging
- cluster-native Helm delivery
- multi-architecture add-on support

## Hard Requirements Before Submission

### Packaging

- Publish the exact customer-facing image set to AWS Marketplace-managed ECR repositories.
- Keep the Terraform customer bundle clean: no local `terraform.tfstate`, secrets, backend config,
  or ad hoc operator files.
- Pin the Terraform release artifact consumed by the private Marketplace packaging repo.

### Security and runtime hardening

- Container images must be free of known vulnerabilities, malware, and EOL packages.
- Runtime access to AWS services must use IAM roles for tasks, not injected credentials.
- Images should run as non-root by default.
- Images and packaging must not contain hardcoded secrets.

### Listing and deployment

- Usage instructions must be complete and self-service.
- Any external dependencies or ongoing outbound requirements must be disclosed in the listing.
- Support, EULA, screenshots, and operator runbooks must exist before submission.
- End-to-end deployment from the customer bundle must succeed and pass readiness smoke checks.

## Repo Changes This Workstream Should Drive

- Keep `aws-ecs` as the primary marketplace target in bundle metadata and docs.
- Validate marketplace metadata and customer bundle packaging in `static-validate`.
- Align image publishing and release automation to produce AWS Marketplace-ready artifacts.
- Add submission-oriented docs and runbooks before moving seller packaging into the private repo.

## Explicit Non-Goals For This First Pass

- Microsoft Marketplace container submission work
- Amazon EKS add-on delivery
- SaaS fulfillment, entitlement, and metering integration

Those can follow once the first AWS container offer path is stable.

## Notes

- Azure container offers are a separate workstream. Current Microsoft container offer guidance is
  Kubernetes-app based, so do not treat the existing `azure-aca` runtime as automatically ready
  for Microsoft Marketplace container submission.
- This document is intentionally biased toward the smallest shippable AWS route, not the most
  feature-complete commercial packaging model.
