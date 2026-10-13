# Honua on AWS ECS/Fargate (`examples/aws`)

Deployable root that wires [`modules/aws-ecs`](../../modules/aws-ecs/README.md)
to an operator backend. Copy `terraform.tfvars.example` to `terraform.tfvars`,
fill it in, then `terraform init`, `plan` and `apply`. `variables.tf` lists
every input; the module README documents the behaviour behind them.

## Selected variables

| Variable | Default | Description |
|----------|---------|-------------|
| `alb_certificate_arn` | `""` | ACM certificate for the ALB HTTPS listener. Empty (with no `domain_name` + `route53_zone_id`) serves plain HTTP. |
| `alb_enable_http_redirect` | `true` | On an HTTPS ALB, add a port 80 listener that redirects HTTP to HTTPS. With it off, an HTTPS ALB does not listen on port 80. Same name and default as the module input. |
| `cors_allowed_origins` | `[]` | Browser origins rendered as `Cors__AllowedOrigins__<n>`. API-only cells need none. |
| `operations_policy_rules` | `[]` | Ordered first-match-wins operation policy rules rendered as `Operations__Policy__Rules__<n>__<Field>`. The server runs in Production, where `Operations:Policy` denies every typed operation (for example `service.publish`) until a rule allows it. See the module README's [Operation policy rules](../../modules/aws-ecs/README.md#operation-policy-rules). |
| `studio_end_user_authorization` | `false` | Let any authenticated principal use the Studio authoring API, subject to the server's per-resource Studio authorization; rendered as `Studio__EndUserAuthorization__Enabled=true` only when `true`. Off keeps the server default: only admins can author Studio content. |
| `import_background_job_threshold_bytes` | `null` | Upload size in bytes above which honua-server runs an import as a background job instead of inline; rendered as `Import__Limits__BackgroundJobThresholdBytes` on the primary and canary task definitions. `null` keeps the server default (100 MiB). The release harness sets `67108864` (64 MiB) on Redis-on cells so the S10 large-import fixture has a background window under the 100 MiB staging cap. |

Example rule set:

```hcl
operations_policy_rules = [
  { operation_id = "service.publish", role = "admin", decision = "Allow" },
  { role = "admin", decision = "RequireApproval", approval_lane = "control-plane" },
]
```


### Optional static JWT issuer

`oidc_static_jwt` is an opt-in object containing `issuer` (HTTPS), `audience`,
`signing_key_secret_arn` and optional `signing_key_kms_key_arn`. The secret must
already exist and contain a signing key of at least 32 UTF-8 bytes. Create and
rotate its value outside Terraform: the module neither reads that value nor
manages a secret version. Omit the object to preserve the existing authentication
configuration. Configure Studio end-user authorization separately when needed.

ECS injects the secret through its task execution role. Lambda receives an
`aws:secretsmanager:` reference and requires a server version containing
[honua-server5980](https://github.com/honua-io/honua-server/issues/5980); older
servers cannot use that reference as a static signing key. Only the API Lambda
receives the issuer and signing-secret permission; event functions do not.
Issuer, audience, signature and lifetime validation remain enabled. A static
signing key is captured at process startup, so restart the deployment after
rotation. The Lambda environment remains subject to its unchanged 4096-byte
limit; do not remove security settings or raise that ceiling to fit a fixture.

Set optional `signing_key_secret_version_id` to bind the version the runtime actually
consumes. ECS renders the [version-specific secret reference](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html);
Lambda uses the server resolver's `?versionId=` option. IAM permissions remain scoped
to the bare secret ARN. An omitted version retains normal current-version behavior.

## Declared platform release identity

`platform_release` optionally passes the signed release's `version`, digest-pinned
`serving_artifact_reference`, and optional `workers` (each with
`artifact_reference` and optional `runtime_profile`) to the server's
`ControlPlane:PlatformRelease` configuration. Null is the default and preserves
existing environment configuration. Supplying the typed object replaces raw
settings in that configuration subtree, including stale worker entries.
This declares identity; it does not verify a lock signature or certify a deployment.
The release runner must verify the signed lock and the actual serving image.

`canary_platform_release` defaults to `platform_release`. Set it to the candidate
identity while the primary retains the prior identity during a staged update.
Changing this input updates task configuration; it does not promote ALB traffic.
