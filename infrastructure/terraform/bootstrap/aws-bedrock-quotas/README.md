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
