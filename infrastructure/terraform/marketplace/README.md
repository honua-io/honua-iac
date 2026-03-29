# Marketplace Bundle Metadata

This directory contains the machine-readable marketplace bundle contract for Honua Terraform
targets.

Use the files here as the packaging/install boundary:

- `targets.json` is the bundle index and support matrix.
- `bundles/*.json` are versioned per-target manifests with supported regions, required
  permissions, billable components, upgrade semantics, sample tfvars, and validation
  scenario references.
- `schemas/install-surface.v1.json` defines the provider-neutral `install` questionnaire
  surface used by deployable runtime roots.
- `schemas/deploy-contract.v2.json` defines the normalized `deploy_contract` output
  emitted by runtime targets.

Current policy:

- Turnkey marketplace bundles target container runtimes only.
- `examples/aws` and `examples/azure` are the preferred turnkey bundle roots in this repo.
- `examples/aws-serverless` and `examples/azure-functions` remain operator-only bundles.
- `examples/aws-eks` and `examples/azure-aks` remain cluster-only roots and do not install
  Honua by themselves.

Current submission focus:

- AWS Marketplace container-offer work starts with `aws-ecs` / `examples/aws`.
- Seller-specific packaging, listing assets, and release automation should live outside this repo
  and consume a pinned customer distribution artifact from `scripts/package-customer-dist.sh`.
- Do not infer current Microsoft Marketplace container-offer readiness from the `azure-aca` bundle
  metadata alone; the Microsoft seller path is a separate workstream.
