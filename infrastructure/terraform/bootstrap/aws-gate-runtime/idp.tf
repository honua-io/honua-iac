resource "aws_cognito_user_pool" "gate" {
  name = "honua-gate-idp"
  admin_create_user_config { allow_admin_create_user_only = true }
  password_policy {
    minimum_length    = 32
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }
}

resource "aws_cognito_user_pool_domain" "gate" {
  domain       = "honua-gate-idp-${var.member_account_id}"
  user_pool_id = aws_cognito_user_pool.gate.id
}

resource "aws_cognito_user_pool_client" "gate" {
  name                                 = "honua-gate-launch-stack"
  user_pool_id                         = aws_cognito_user_pool.gate.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "profile", "email"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = sort(tolist(var.idp_callback_urls))
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true
  # honua-gate-reaper-idp-callbacks owns the live list: idp_callback_urls plus each live gate stack's
  # callback. Terraform sets the initial list only; after changing idp_callback_urls, invoke the function.
  lifecycle { ignore_changes = [callback_urls] }
}

resource "random_password" "admin" {
  length           = 40
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
  override_special = "!#%+-_=?:"
}

resource "aws_cognito_user" "admin" {
  user_pool_id   = aws_cognito_user_pool.gate.id
  username       = "honua-gate-admin"
  password       = random_password.admin.result
  message_action = "SUPPRESS"
}

resource "aws_cognito_user_group" "admin" {
  user_pool_id = aws_cognito_user_pool.gate.id
  name         = "admin"
}

resource "aws_cognito_user_in_group" "admin" {
  user_pool_id = aws_cognito_user_pool.gate.id
  group_name   = aws_cognito_user_group.admin.name
  username     = aws_cognito_user.admin.username
}

resource "aws_secretsmanager_secret" "idp_client" {
  name                    = "honua-gate/idp/client-secret"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "idp_client" {
  secret_id     = aws_secretsmanager_secret.idp_client.id
  secret_string = aws_cognito_user_pool_client.gate.client_secret
}

resource "aws_secretsmanager_secret" "idp_admin" {
  name                    = "honua-gate/idp/admin"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "idp_admin" {
  secret_id = aws_secretsmanager_secret.idp_admin.id
  secret_string = jsonencode({
    username = aws_cognito_user.admin.username
    password = random_password.admin.result
  })
}

output "oidc_authority" {
  value     = "https://${aws_cognito_user_pool.gate.endpoint}"
  sensitive = true
}
output "oidc_client_id" {
  value     = aws_cognito_user_pool_client.gate.id
  sensitive = true
}
output "oidc_client_secret_arn" {
  value     = aws_secretsmanager_secret.idp_client.arn
  sensitive = true
}
output "oidc_admin_secret_arn" {
  value     = aws_secretsmanager_secret.idp_admin.arn
  sensitive = true
}
