# AWS serverless root (Lambda + optional GP on Batch)

Deployable root for the `modules/aws-serverless` module: Honua on AWS Lambda
behind API Gateway, with RDS PostgreSQL/PostGIS, optional ElastiCache Redis and,
when `enable_gp_batch = true`, geoprocessing/import jobs on a scale-to-zero AWS
Batch (Fargate Spot) queue. Lambda plus Batch is the 2026.1 Lambda+Batch cell.

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in image + secrets
terraform init
terraform plan -var-file=presets/small.tfvars.example
```

## Architecture defaults

`lambda_architectures` defaults to `["x86_64"]` and `gp_batch_cpu_architecture`
to `X86_64`, matching the 2026.1 platform manifest (`awsLambdaArchitecture:
x86_64`, `awsEcsArchitecture: x86_64`). Use arm64 only with images verified for
it.

## GP on AWS Batch (the Lambda+Batch cell)

| Variable | Default | Notes |
|----------|---------|-------|
| `enable_gp_batch` | `false` | Provisions the Batch compute environment, queue and job-definition pool and wires them into the server's ControlPlane execution-workload catalog. |
| `gp_batch_image` | `""` | Digest-pinned **generic (ECS) server image**. The job definitions set no `command` or `entryPoint`, so the container runs the image's own entrypoint; the Lambda AOT image's entrypoint is built for the Lambda runtime. Empty falls back to `honua_image_uri`, and a plan check warns. |
| `gp_batch_cpu_architecture` | `X86_64` | Must match `gp_batch_image`. |
| `gp_batch_max_vcpus` | `16` | Caps concurrent jobs and cost; scales to zero between jobs. |
| `gp_batch_data_bucket_arn` / `gp_batch_data_bucket_enabled` | `""` / `false` | Optional S3 read/write grant for the job role; set both together. |
| `use_batch_service_linked_role` | `false` | Use the operator-precreated AWS Batch service-linked role (certification cells). |

Outputs (all `null` when Batch is off): `gp_batch_enabled`, `gp_batch_image`
(the effective image), `gp_batch_cpu_architecture`, `gp_job_queue_name`,
`gp_job_queue_arn`, `gp_job_definition_names` and `gp_job_definition_arns`
(maps keyed `s`, `m`, `l`, `xl`), `gp_compute_environment_name`,
`gp_compute_environment_arn`.

## Browser origins (CORS)

`cors_allowed_origins` (default `[]`) lists the browser origins, such as the
Honua Console or Studio, that may call the API. Each entry becomes
`Cors__AllowedOrigins__<n>` on the server and an API Gateway CORS origin. API-only
cells called by SDKs, the CLI or server-side clients need none.

## Migrations on the serverless root

`skip_migrations` defaults to `true`: concurrent Lambda cold starts must not race
to migrate the schema, so the Lambda never migrates the database. **Until
honua-server ships a `HONUA_MIGRATE_ONLY` exit mode (planned for 2026.1.x), the
release harness (or the operator) runs migrations out-of-band after `apply` and
before the cell serves traffic**:

1. Start the digest-pinned generic (ECS) honua-server image once, with
   `ConnectionStrings__DefaultConnection`, `HONUA_ADMIN_PASSWORD` and
   `Security__ConnectionEncryption__MasterKey` set from the secrets named by
   `migrate_db_connection_secret_arn`, `migrate_admin_password_secret_arn` and
   `migrate_master_key_secret_arn` (as `aws:secretsmanager:<arn>` references or
   resolved values).
2. Run it where the database is reachable: as an in-VPC task in
   `migrate_private_subnet_ids` with `migrate_security_group_id`, or from a
   runner admitted with `db_publicly_accessible = true` and
   `db_additional_ingress_cidrs`.
3. Wait for `GET /healthz/ready` to return 200 (the server migrates on startup),
   then stop it. The Lambda can now serve.

`migrate_required` is `true` while `skip_migrations` is on, and
`migrate_guidance` repeats these steps. When `HONUA_MIGRATE_ONLY` exists, step 3
becomes a run-to-completion exit and this section will be updated. Outputs carry
ARNs and IDs only, never secret values.
