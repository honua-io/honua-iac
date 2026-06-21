# Terraform Validation Assets

This folder contains maintainer-only Terraform validation automation.

- `scripts/aws`: AWS ECS + Lambda + data-stack integration validation
- `scripts/azure`: Azure ACA + Functions + data-stack integration validation
- `scripts/k8s`: local Kubernetes, AKS, and EKS integration validation helpers
- `scripts/shared`: policy gate, drift-detection, and DR drill evidence-capture scripts

For full run instructions, use:

- `docs/devops/terraform-validation.md`
- `.github/workflows/terraform-manual-validation.yml`

Disaster-recovery drill runbooks and the evidence-capture helper:

- `docs/devops/backup-restore-runbook.md` (AWS + Azure backup/restore drills)
- `docs/devops/failover-drill-runbook.md` (AWS + Azure failover + RTO/RPO drills)
- `docs/devops/dr-evidence-template.json` (evidence schema)
- `scripts/shared/capture-dr-drill-evidence.sh` (evidence capture; wrapped by `scripts/capture-dr-drill-evidence.sh`)
