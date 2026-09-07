###############################################################################
# PostGIS bootstrap — one-shot in-VPC Lambda (honua-server#2164 / #2166).
#
# Honua's migration 001 creates GEOMETRY columns, so postgis must exist BEFORE
# the server's startup migrations run. Without it the Lambda aborts startup
# ("PostGIS preflight check failed: PostGIS extension is not installed.") and
# every request returns HTTP 500. The module's `enable_postgis` local-exec
# needs psql plus a network path to the (private) RDS instance, which the apply
# host does not have. Instead, a tiny Python Lambda inside the VPC enables
# postgis + postgis_raster as the RDS master user. Terraform invokes it exactly
# once after the database is created (idempotent: CREATE EXTENSION IF NOT
# EXISTS), and before the server Lambda is exercised.
#
# This mirrors examples/aws-demo, with one network difference: the cert stack
# keeps the module's NAT gateway (enable_nat_gateway default = true), so the
# bootstrap Lambda reaches Secrets Manager over the VPC's NAT path. The demo
# runs with no NAT and therefore needs a Secrets Manager interface endpoint;
# cert does not.
#
# Build prerequisites on the apply host: python3 + pip (replaces the module's
# psql + network-path requirement). The pure-Python pg8000 driver is vendored
# into the deployment zip at apply time; nothing is compiled.
###############################################################################

locals {
  postgis_bootstrap_dir       = "${path.module}/postgis-bootstrap"
  postgis_bootstrap_pg8000    = "1.31.2" # pure-Python PostgreSQL driver, pinned
  postgis_bootstrap_func_name = "${var.name_prefix}-${var.environment}-postgis-bootstrap"
  # Amazon RDS global CA bundle, vendored into the zip so the Lambda can verify
  # the RDS server certificate (chain + hostname) instead of trusting any cert.
  # https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html
  postgis_bootstrap_rds_ca_url      = "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
  postgis_bootstrap_rds_ca_filename = "rds-global-bundle.pem"
}

resource "terraform_data" "postgis_bootstrap_build" {
  triggers_replace = {
    handler        = filesha256("${local.postgis_bootstrap_dir}/handler.py")
    pg8000_version = local.postgis_bootstrap_pg8000
    rds_ca_url     = local.postgis_bootstrap_rds_ca_url
  }

  provisioner "local-exec" {
    interpreter = ["python", "-c"]
    command     = <<-EOT
      import pathlib, shutil, subprocess, sys, urllib.request
      root = pathlib.Path(r"${local.postgis_bootstrap_dir}")
      build = root / "build"
      shutil.rmtree(build, ignore_errors=True)
      build.mkdir(parents=True, exist_ok=True)
      subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet",
                             "--target", str(build), "pg8000==${local.postgis_bootstrap_pg8000}"])
      shutil.copy(root / "handler.py", build / "handler.py")
      # Vendor the Amazon RDS global CA bundle so the Lambda can verify the RDS
      # server certificate. The build host already requires internet for pip.
      ca = build / "${local.postgis_bootstrap_rds_ca_filename}"
      with urllib.request.urlopen("${local.postgis_bootstrap_rds_ca_url}", timeout=30) as r:
          data = r.read()
      if b"BEGIN CERTIFICATE" not in data:
          raise SystemExit("downloaded RDS CA bundle is not a PEM certificate file")
      ca.write_bytes(data)
    EOT
  }
}

data "archive_file" "postgis_bootstrap" {
  type        = "zip"
  source_dir  = "${local.postgis_bootstrap_dir}/build"
  output_path = "${local.postgis_bootstrap_dir}/bootstrap.zip"

  depends_on = [terraform_data.postgis_bootstrap_build]
}

#checkov:skip=CKV2_AWS_5: Security group is attached to the bootstrap Lambda function.
resource "aws_security_group" "postgis_bootstrap" {
  #checkov:skip=CKV2_AWS_5: Security group is attached to the bootstrap Lambda function.
  name_prefix = "${var.name_prefix}-${var.environment}-pgboot-"
  description = "PostGIS bootstrap Lambda security group"
  vpc_id      = module.honua.vpc_id

  egress {
    description = "PostgreSQL access to the in-VPC RDS instance"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [module.honua.vpc_cidr_block]
  }

  egress {
    description = "HTTPS to Secrets Manager via the VPC NAT gateway"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

data "aws_iam_policy_document" "postgis_bootstrap_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "postgis_bootstrap" {
  name_prefix        = "${var.name_prefix}-${var.environment}-pgboot-"
  assume_role_policy = data.aws_iam_policy_document.postgis_bootstrap_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "postgis_bootstrap_basic" {
  role       = aws_iam_role.postgis_bootstrap.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "postgis_bootstrap_vpc" {
  role       = aws_iam_role.postgis_bootstrap.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "postgis_bootstrap_secret" {
  name = "read-db-connection-secret"
  role = aws_iam_role.postgis_bootstrap.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [module.honua.db_connection_secret_arn]
      }
    ]
  })
}

#checkov:skip=CKV_AWS_50: One-shot bootstrap helper; X-Ray adds no value.
#checkov:skip=CKV_AWS_115: One-shot bootstrap helper; concurrent execution limit set to 1 explicitly below.
#checkov:skip=CKV_AWS_116: Invoked synchronously by Terraform; a DLQ is meaningless.
#checkov:skip=CKV_AWS_173: The env var holds a secret ARN, not secret material.
#checkov:skip=CKV_AWS_272: Code signing is unnecessary for a Terraform-built helper zip.
resource "aws_lambda_function" "postgis_bootstrap" {
  #checkov:skip=CKV_AWS_50: One-shot bootstrap helper; X-Ray adds no value.
  #checkov:skip=CKV_AWS_115: One-shot bootstrap helper; concurrent execution limit set to 1 explicitly below.
  #checkov:skip=CKV_AWS_116: Invoked synchronously by Terraform; a DLQ is meaningless.
  #checkov:skip=CKV_AWS_173: The env var holds a secret ARN, not secret material.
  #checkov:skip=CKV_AWS_272: Code signing is unnecessary for a Terraform-built helper zip.
  function_name                  = local.postgis_bootstrap_func_name
  role                           = aws_iam_role.postgis_bootstrap.arn
  runtime                        = "python3.13"
  handler                        = "handler.handler"
  architectures                  = ["arm64"]
  filename                       = data.archive_file.postgis_bootstrap.output_path
  source_code_hash               = data.archive_file.postgis_bootstrap.output_base64sha256
  timeout                        = 120
  memory_size                    = 256
  reserved_concurrent_executions = 1

  vpc_config {
    subnet_ids = module.honua.private_subnet_ids
    security_group_ids = [
      # The bootstrap SG carries the egress rules; the module's Lambda SG is the
      # one the RDS security group admits on 5432, so the bootstrap function must
      # carry it too or the in-VPC connection times out.
      aws_security_group.postgis_bootstrap.id,
      module.honua.lambda_security_group_id,
    ]
  }

  environment {
    variables = {
      DB_SECRET_ARN = module.honua.db_connection_secret_arn
    }
  }

  tags = local.tags
}

# Runs during apply, after the module (and therefore RDS + the connection
# secret + NAT gateway) is fully created. The server Lambda is created by
# module.honua but not invoked until after apply completes, so enabling postgis
# here guarantees the extension exists before the server runs its startup
# migrations / PostGIS preflight check.
resource "aws_lambda_invocation" "postgis_bootstrap" {
  function_name = aws_lambda_function.postgis_bootstrap.function_name
  input         = jsonencode({})

  depends_on = [
    module.honua,
    aws_iam_role_policy.postgis_bootstrap_secret,
    aws_iam_role_policy_attachment.postgis_bootstrap_basic,
    aws_iam_role_policy_attachment.postgis_bootstrap_vpc,
  ]
}

output "postgis_bootstrap_result" {
  description = "Extensions reported by the one-shot PostGIS bootstrap Lambda."
  value       = aws_lambda_invocation.postgis_bootstrap.result
}

###############################################################################
# Certification serving fixture apply (release#282).
#
# The Lambda GA certification lane asserts ten named rows on `test_service/0`
# and writes its run-owned row to the scratch layer `test_service/10`
# (scripts/cloud/lambda-certification.md), so the cert database has to carry
# honua-server's client-compat snapshot before the lane runs. Neither
# real-aws-certification.tf's control-plane tests nor ecs-alb-cert.tf's nginx
# seeds a Honua serving fixture, and the database is reachable only from inside
# the VPC — so the snapshot goes in through the same in-VPC bootstrap Lambda,
# in `script` mode: it fetches the file from a commit-pinned https URL over the
# VPC's NAT egress, verifies the sha256, splits it (dollar-quote/string/comment
# aware) and applies every statement in ONE transaction. All-or-nothing: a
# partially applied fixture would fail the lane's exact-count assertions in a
# way that looks like a server defect.
#
# Recorded, not hand-run: the URL, its digest, the statement count and the
# transaction outcome all land in state and in the outputs below, so the
# evidence says which honua-server revision's seed this cert database carries.
#
# Terraform re-invokes the Lambda whenever `input` changes, so bumping either
# variable re-applies the seed. Every statement in client-compat-v1.sql is
# idempotent (CREATE ... IF NOT EXISTS / ON CONFLICT DO UPDATE), so re-applying
# converges the fixture; it does not reset unrelated standing data.
###############################################################################

resource "aws_lambda_invocation" "cert_fixture_seed" {
  # Stopping the seed drops this invocation from state; destroying it performs no
  # API call, so it cannot undo SQL already committed to RDS. Prefer
  # `cert_fixture_seed_enabled = false`, which stops future applies while the
  # pinned inputs — and so `cert_fixture_seed_source` below — keep naming the
  # fixture the database carries; emptying the URL stops seeding too, but
  # discards that record (see README, "Turning seeding off").
  count = var.cert_fixture_seed_enabled && var.cert_fixture_seed_url != "" ? 1 : 0

  function_name = aws_lambda_function.postgis_bootstrap.function_name
  input = jsonencode({
    script_url    = var.cert_fixture_seed_url
    script_sha256 = var.cert_fixture_seed_sha256
  })

  # postgis must exist before the snapshot's GEOMETRY columns are created, and
  # the two invocations share one reserved concurrent execution.
  depends_on = [aws_lambda_invocation.postgis_bootstrap]

  lifecycle {
    precondition {
      condition     = can(regex("^[0-9a-f]{64}$", var.cert_fixture_seed_sha256))
      error_message = "cert_fixture_seed_sha256 must be set to the 64-hex sha256 of the file at cert_fixture_seed_url; the bootstrap Lambda will not apply an unverified script."
    }
  }
}

# Warn (rather than fail) on the harmless-but-wrong half-configuration: a digest
# with no URL seeds nothing at all.
check "cert_fixture_seed_inputs_agree" {
  assert {
    condition     = var.cert_fixture_seed_sha256 == "" || var.cert_fixture_seed_url != ""
    error_message = "cert_fixture_seed_sha256 is set but cert_fixture_seed_url is empty, so no certification fixture is applied."
  }
}

# A stack that has pinned a fixture but is not applying it is a legitimate state
# — it is how seeding is turned off without losing provenance — but it is one
# the evidence has to be read against, so say it out loud at plan time rather
# than leaving it to be inferred from a null output.
check "cert_fixture_seed_disabled_is_stated" {
  assert {
    condition     = var.cert_fixture_seed_enabled || var.cert_fixture_seed_url == ""
    error_message = "cert_fixture_seed_enabled is false with a fixture still pinned: this apply does not seed, and the database may still carry the fixture named by cert_fixture_seed_source."
  }
}

output "cert_fixture_seed_applied" {
  description = "What the certification serving fixture apply recorded: the pinned source, its verified sha256, how many statements committed, and the rows they touched. Null when fixture seeding is disabled, which does not imply the database is unseeded — read cert_fixture_seed_source for the revision it carries."
  value = one([
    for invocation in aws_lambda_invocation.cert_fixture_seed : {
      url             = var.cert_fixture_seed_url
      sha256          = jsondecode(invocation.result).source.sha256
      bytes           = jsondecode(invocation.result).source.bytes
      committed       = jsondecode(invocation.result).committed
      statement_count = jsondecode(invocation.result).statement_count
      rows_affected   = jsondecode(invocation.result).rows_affected
    }
  ])
}

# Provenance that outlives the invocation. `cert_fixture_seed_applied` reports
# the apply that ran and is necessarily null once the invocation leaves state;
# this reports what the stack has pinned, so disabling seeding does not erase
# which fixture revision the certification database was last seeded with.
output "cert_fixture_seed_source" {
  description = "The commit-pinned certification fixture this stack carries, reported whether or not this apply invoked the seed: `url`, its `sha256`, and `seeding_enabled`. Null only when no fixture has ever been pinned here (an emptied cert_fixture_seed_url also reads null, which is why disabling seeding should use cert_fixture_seed_enabled)."
  value = var.cert_fixture_seed_url == "" ? null : {
    url             = var.cert_fixture_seed_url
    sha256          = var.cert_fixture_seed_sha256
    seeding_enabled = var.cert_fixture_seed_enabled
  }
}

output "cert_fixture_seed_result" {
  description = "Full per-statement result returned by the bootstrap Lambda's script mode. Null when fixture seeding is disabled, which does not imply the database is unseeded — read cert_fixture_seed_source for the revision it carries."
  value       = one(aws_lambda_invocation.cert_fixture_seed[*].result)
}
