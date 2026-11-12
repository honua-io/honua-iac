variable "region" {
  description = "Region of the receiver and queue; the lane host (bootstrap/aws-lane-host) runs here too."
  type        = string
  default     = "eu-north-1"
}

variable "name" {
  description = "Name prefix for the function, queues, role and log group."
  type        = string
  default     = "honua-ci-events"
}

variable "webhook_secret_parameter" {
  description = "SSM SecureString holding the GitHub webhook secret. Created out of band (never in state); see README."
  type        = string
  default     = "/honua/ci-events/webhook-secret"
}

variable "webhook_secret_kms_key_arn" {
  description = "Customer-managed KMS key of the secret parameter, if any. Empty: the AWS-managed aws/ssm key."
  type        = string
  default     = ""
}

variable "allowed_repos" {
  description = "Repository names to forward (rollout control). Empty: every repository in the organisation."
  type        = list(string)
  default     = []
}

variable "ignore_senders" {
  description = "GitHub logins whose review/comment events are dropped (the lane account's own replies). CI and PR events are always kept."
  type        = list(string)
  default     = []
}

variable "message_retention_seconds" {
  description = "Retention of the queue and its dead-letter queue."
  type        = number
  default     = 345600 # 4 days
}

variable "max_receive_count" {
  description = "Receives before a message moves to the dead-letter queue."
  type        = number
  default     = 5
}

variable "reserved_concurrency" {
  description = "Concurrency cap of the receiver (bounds cost if the URL is flooded; GitHub retries are not automatic, so keep headroom)."
  type        = number
  default     = 20
}

variable "log_retention_days" {
  description = "CloudWatch retention of the receiver's logs."
  type        = number
  default     = 14
}
