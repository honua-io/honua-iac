# aws-bedrock-quotas

Raises the Bedrock tokens-per-minute (TPM) quotas for the models that the release harness, the model canaries, the operate-stage eval and the cloud cells' Studio AI proxy call.

| Model | Quota | Code | Default request |
|---|---|---|---|
| Claude Opus 5.5 | cross-region TPM (`us.anthropic.claude-opus-5-5`) | L-A4430697 | 2,000,000 |
| Claude Opus 5.5 | global cross-region TPM | L-A103A344 | 2,000,000 |
| Claude Sonnet 5.5 | cross-region TPM (`us.anthropic.claude-sonnet-5-5`) | L-94A31E46 | 2,000,000 |
| Claude Sonnet 5.5 | global cross-region TPM | L-31AB82D0 | 2,000,000 |

GPT-6.1 Sol (2,000,000 TPM, L-8C5F762B / L-B5C023CA) and GPT-6.1 Terra (2,000,000 cross-region, L-993B3F8D; 4,000,000 global, L-AFFB7581) already have enough quota, so this stack doesn't manage them. The harness models are Claude Opus 5.5, Claude Sonnet 5.5, GPT-6.1 Sol and GPT-6.1 Terra.

## Why 2,000,000

For recent Claude models, Bedrock reserves each request's `max_tokens` against TPM when the request starts, and output tokens count about five times. A call with about 30k input tokens and an 8,192-token output budget reserves about 70k TPM. About six agent sessions in parallel (five canary runs and the operate eval) at about four calls a minute each peak near 1.7M TPM. 2M covers that, and it matches what the account already has for GPT-6.1 Sol.

## Apply (operator, account admin)

```bash
cd infrastructure/terraform/bootstrap/aws-bedrock-quotas
terraform init
terraform apply
```

Applying files a Service Quotas increase request, and AWS may hold it for review. Check `terraform output requests`, or Service Quotas → Amazon Bedrock in the console. Model access is a separate one-time step: send one message to the model in the Bedrock playground.

**Account 585192672263 (2026-10-31):** this root can't raise these quotas there. The applied value of all four is 0, which is an account-level override below the AWS defaults (30,000,000 for Opus 5.5 and 6,000,000 for Sonnet 5.5). `RequestServiceQuotaIncrease` refuses any value at or below the default (`IllegalArgumentException: You must provide a quota value greater than the default quota value`), so neither 2,000,000 nor the default can be requested. Only AWS Support can lift the override; the request goes on the account's Bedrock support case, citing the four quota codes. The root is applied with both inputs at 0 (unmanaged) and empty state, and drift-roots.json records it that way. Once Support restores the defaults, which already exceed the sizing above, no apply is needed.
