variable "region" {
  description = "Only region where certification cells may operate."
  type        = string
  default     = "us-east-1"
}
variable "name" {
  description = "Operator-owned role namespace, outside honuar*, honuan*, and honuaeks*."
  type        = string
  default     = "honua-release-cell"
  validation {
    condition     = can(regex("^honua-release-[a-z0-9-]+$", var.name))
    error_message = "Keep the bootstrap outside the agent-managed cell namespaces."
  }
}
variable "oidc_provider_arn" {
  description = "Existing GitHub OIDC provider; only the operator can change it."
  type        = string
}
variable "oidc_subjects" {
  description = "Exact GitHub environment subjects. Protect these three environments separately."
  type        = map(string)
  default = {
    provision = "repo:honua-io/honua-release:environment:aws-cell-provision"
    reaper    = "repo:honua-io/honua-release:environment:aws-cell-reaper"
    mirror    = "repo:honua-io/honua-release:environment:aws-cell-mirror"
  }
  validation {
    condition     = alltrue([for lane in ["provision", "reaper", "mirror"] : can(regex("^repo:honua-io/[A-Za-z0-9_.-]+:environment:[A-Za-z0-9_-]+$", var.oidc_subjects[lane]))]) && length(distinct(values(var.oidc_subjects))) == 3
    error_message = "Each lane needs a distinct, exact GitHub environment subject (no wildcard)."
  }
}
variable "mirror_repository_arn" {
  description = "Single existing operator-owned ECR mirror repository."
  type        = string
}

variable "enable_workload_role_passing" {
  description = "Activate PassRole only after the operator has inventoried every cell-namespace role and verified its boundary. Off prevents legacy unbounded roles from escaping containment."
  type        = bool
  default     = false
}

variable "workload_vpc_arns" {
  description = "Operator-verified ephemeral VPC ARNs where Lambda may manage ENIs. Empty grants no ENI creation. Plan reads each VPC and verifies cell ownership and protected tags."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for arn in var.workload_vpc_arns : can(regex("^arn:aws:ec2:[a-z0-9-]+:[0-9]{12}:vpc/vpc-[a-f0-9]+$", arn))])
    error_message = "workload_vpc_arns must contain exact VPC ARNs, not wildcards."
  }
}

variable "runtime_bedrock_model_arns" {
  description = "Exact approved Bedrock model/profile ARNs for workload boundaries; match the module model and include every inference-profile destination. Empty grants no invocation."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for arn in var.runtime_bedrock_model_arns : can(regex("^arn:aws:bedrock:[a-z0-9-]+:([0-9]{12})?:(foundation-model|inference-profile)/[a-zA-Z0-9.:-]+$", arn))])
    error_message = "Supply exact foundation-model or inference-profile ARNs, never wildcards."
  }
}

variable "runtime_operation_key_ring_certificate_secret_arns" {
  description = "Exact operator-owned Secrets Manager ARNs holding the Redis operation key-ring certificate (operation_key_ring_certificate_secret_arn on examples/aws and examples/aws-serverless). Workload boundaries otherwise admit only cell-namespaced secrets. Empty grants no read."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for arn in var.runtime_operation_key_ring_certificate_secret_arns : can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", arn))])
    error_message = "Supply complete Secrets Manager secret ARNs (including the six-character suffix), never wildcards."
  }
}

variable "runtime_operation_key_ring_certificate_kms_key_arns" {
  description = "Exact customer-managed KMS key ARNs encrypting those certificate secrets. Leave empty for the AWS-managed aws/secretsmanager key."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for arn in var.runtime_operation_key_ring_certificate_kms_key_arns : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", arn))])
    error_message = "Supply exact KMS key ARNs, never aliases or wildcards."
  }
}

variable "runtime_audit_chain_key_secret_arns" {
  description = "Exact operator-owned Secrets Manager ARNs holding the audit hash-chain key (audit_chain_key_secret_arn on examples/aws and examples/aws-serverless). A customer-managed key for it goes in runtime_operation_key_ring_certificate_kms_key_arns. Empty grants no read."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for arn in var.runtime_audit_chain_key_secret_arns : can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", arn))])
    error_message = "Supply complete Secrets Manager secret ARNs (including the six-character suffix), never wildcards."
  }
}

variable "approver_role_name" {
  description = "Role that issues honua-devops provision-approval receipts (kms:GenerateMac only). Pass it to aws-exec-identity approval_signer_role_names."
  type        = string
  default     = "honua-release-approver"
  validation {
    condition     = can(regex("^honua-release-[a-z0-9-]+$", var.approver_role_name)) && !can(regex("^(honuar|honuan|honuaeks)", var.approver_role_name))
    error_message = "Keep the approver outside the agent-managed cell namespaces."
  }
}

variable "approver_oidc_subject" {
  description = "Exact GitHub environment subject allowed to assume the approver. Protect that environment with required reviewers; it is the human approval gate."
  type        = string
  default     = "repo:honua-io/honua-release:environment:terraform-live-approval"
  validation {
    condition     = can(regex("^repo:honua-io/[A-Za-z0-9_.-]+:environment:[A-Za-z0-9_-]+$", var.approver_oidc_subject))
    error_message = "The approver needs an exact GitHub environment subject (no wildcard, no branch ref)."
  }
}

variable "approval_verifier_lane" {
  description = "Cell lane whose role runs the honua-devops agent that verifies approval receipts (kms:VerifyMac only). Pass that role name to aws-exec-identity approval_verifier_role_names."
  type        = string
  default     = "provision"
  validation {
    condition     = contains(["provision", "reaper", "mirror"], var.approval_verifier_lane)
    error_message = "approval_verifier_lane must be a cell lane."
  }
}
