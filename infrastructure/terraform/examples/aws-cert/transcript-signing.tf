variable "transcript_signing" {
  description = "Optional operator-owned model transcript signer. Supply an existing secret ARN containing a base64 32-byte Ed25519 seed; Terraform never reads the value. Pin version_id for certification and publish the matching public verification manifest separately. Null leaves signing unconfigured."
  type = object({
    key_id      = string
    secret_arn  = string
    version_id  = optional(string, "")
    kms_key_arn = optional(string, "")
  })
  default = null

  validation {
    condition = var.transcript_signing == null ? true : (
      can(regex("^[A-Za-z0-9._-]{1,128}$", var.transcript_signing.key_id)) &&
      can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", var.transcript_signing.secret_arn)) &&
      (var.transcript_signing.version_id == "" || can(regex("^[A-Za-z0-9-]{32,64}$", var.transcript_signing.version_id))) &&
      (var.transcript_signing.kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|mrk-[0-9a-fA-F]{32})$", var.transcript_signing.kms_key_arn)))
    )
    error_message = "transcript_signing requires a nonempty safe key ID and complete Secrets Manager ARN; optional version ID must be 32-64 letters/digits/hyphens and KMS must be an exact key ARN. Inline material, references, selectors and wildcards are not accepted."
  }
}
