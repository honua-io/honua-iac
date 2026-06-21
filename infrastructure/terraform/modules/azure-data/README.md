# Azure Data Module (internal)

> Internal-only; not part of the published module surface. See
> [`docs/module-versioning.md`](../../../../docs/module-versioning.md).

Building block that provisions the Azure data plane (PostgreSQL Flexible Server
and supporting resources) used by
`infrastructure/terraform/examples/azure-data`. It has no stabilised public
contract. External consumers should depend on a Tier 1 runtime module
(`azure-aca` or `azure-functions`) instead of pinning this module by Git source.
